[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Pi', 'Grok', 'All')]
    [string]$Scope = 'All',
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$UpdateManaged,
    # Offline tests may point Pi/Grok at TEMP targets. The defaults remain the
    # user's configuration paths; no test or production path is inferred by name.
    [string]$PiTargetPath = '',
    [string]$GrokTargetPath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$actions = @()
if ($Install -and $Uninstall) {
    throw 'Parameters -Install and -Uninstall are mutually exclusive.'
}

$isDryRun = [bool]$WhatIfPreference -or (-not $Install -and -not $Uninstall)
$mode = if ($Install -and $WhatIfPreference) {
    'INSTALL_PREVIEW'
} elseif ($Install) {
    'INSTALL'
} elseif ($Uninstall -and $isDryRun) {
    'UNINSTALL_PREVIEW'
} elseif ($Uninstall) {
    'UNINSTALL'
} else {
    'DRY_RUN'
}

# This is the SHA-256 of the bridge that the previous installer reported as
# CURRENT on this machine on 2026-08-31. It was independently checked before
# being allow-listed: it has the expected agent-observer-poc extension shape,
# emits pi-extension records, and is the installed file from the prior
# installer evidence. No filename-only match is accepted.
$KnownManagedPiBridgeHashes = @(
    '5D460657D02E784A6CFC0DD943F3D8ADC3C9363A77EF1AD0E74D8571A7E1558B'
)

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
        return [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-KnownPiBridgeShape {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $text = [IO.File]::ReadAllText($Path)
    return $text.Contains('export default function') -and
        $text.Contains('observer_schema: 1') -and
        $text.Contains('source: "pi-extension"') -and
        $text.Contains('appendFileSync') -and
        $text.Contains('session_id')
}

function Build-GrokHookExpectedCommand {
    param([Parameter(Mandatory)][string]$CollectorPath)
    $norm = [IO.Path]::GetFullPath($CollectorPath)
    return 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $norm + '"'
}

function Get-KnownGrokEvents {
    return @(
        'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
        'PostToolUseFailure', 'PermissionDenied', 'Stop', 'StopFailure',
        'StopCancelled', 'Notification', 'SessionEnd'
    )
}

function Compare-DeepJsonObject($Expected, $Actual) {
    if ($null -eq $Expected -and $null -eq $Actual) { return $true }
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }

    if ($Expected -is [string] -or $Expected -is [ValueType]) {
        if ($Expected.GetType() -ne $Actual.GetType()) { return $false }
        return ($Expected -eq $Actual)
    }

    if ($Expected -is [System.Collections.IEnumerable] -and -not ($Expected -is [string])) {
        if (-not ($Actual -is [System.Collections.IEnumerable]) -or ($Actual -is [string])) { return $false }
        $expList = @($Expected)
        $actList = @($Actual)
        if ($expList.Count -ne $actList.Count) { return $false }
        for ($i = 0; $i -lt $expList.Count; $i++) {
            if (-not (Compare-DeepJsonObject $expList[$i] $actList[$i])) { return $false }
        }
        return $true
    }

    $expProps = @($Expected.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' })
    $actProps = @($Actual.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' })

    if ($expProps.Count -ne $actProps.Count) { return $false }

    foreach ($p in $expProps) {
        $actProp = $Actual.PSObject.Properties[$p.Name]
        if ($null -eq $actProp) { return $false }
        if (-not (Compare-DeepJsonObject $p.Value $actProp.Value)) { return $false }
    }

    return $true
}

function Build-GrokHookJsonContent {
    param([Parameter(Mandatory)][string]$CollectorPath)

    $command = Build-GrokHookExpectedCommand -CollectorPath $CollectorPath
    $escapedCommand = ($command | ConvertTo-Json -Compress)
    $escapedCommand = $escapedCommand.Substring(1, $escapedCommand.Length - 2)

    $events = Get-KnownGrokEvents

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    $lines.Add('  "hooks": {')
    for ($i = 0; $i -lt $events.Count; $i++) {
        $event = $events[$i]
        $tail = if ($i -lt $events.Count - 1) { ',' } else { '' }
        $lines.Add('    "' + $event + '": [')
        $lines.Add('      {')
        $lines.Add('        "hooks": [')
        $lines.Add('          {')
        $lines.Add('            "type": "command",')
        $lines.Add('            "command": "' + $escapedCommand + '",')
        $lines.Add('            "timeout": 3')
        $lines.Add('          }')
        if ($event -eq 'Notification') {
            $lines.Add('        ],')
            $lines.Add('        "matcher": "*"')
        } else {
            $lines.Add('        ]')
        }
        $lines.Add('      }')
        $lines.Add('    ]' + $tail)
    }
    $lines.Add('  }')
    $lines.Add('}')
    return ($lines -join "`r`n") + "`r`n"
}

function Test-IsExactManagedGrokEntry {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$ExpectedCommand,
        [Parameter(Mandatory)][string[]]$KnownEvents
    )
    if (-not $KnownEvents.Contains($EventName)) { return $false }
    if (-not $Entry) { return $false }
    $innerHooks = $Entry.hooks
    if (-not $innerHooks -or $innerHooks.Count -ne 1) { return $false }
    $h = $innerHooks[0]
    if (-not $h) { return $false }

    $hProps = @($h.PSObject.Properties.Name)
    if ($hProps.Count -ne 3) { return $false }
    if ($h.type -ne 'command') { return $false }
    if ($h.command -ne $ExpectedCommand) { return $false }
    if ($h.timeout -ne 3) { return $false }

    $entryProps = @($Entry.PSObject.Properties.Name)
    if ($EventName -eq 'Notification') {
        if ($entryProps.Count -ne 2) { return $false }
        if ($Entry.matcher -ne '*') { return $false }
    } else {
        if ($entryProps.Count -ne 1) { return $false }
    }
    return $true
}

function Test-IsTaintedGrokEntry {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$ExpectedCommand,
        [Parameter(Mandatory)][string[]]$KnownEvents
    )
    if (-not $Entry) { return $false }
    # Entries in unknown events are outside managed scope and must not be touched or treated as managed conflicts
    if (-not $KnownEvents.Contains($EventName)) { return $false }
    $innerHooks = $Entry.hooks
    if (-not $innerHooks) { return $false }
    foreach ($h in $innerHooks) {
        $cmd = [string]$h.command
        if ($cmd -and ($cmd.Contains('grok-observer-hook.ps1') -or $cmd -eq $ExpectedCommand)) {
            return $true
        }
    }
    return $false
}

function Get-PiState {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { return 'MISSING' }
    $targetHash = Get-Sha256 $Target
    $sourceHash = Get-Sha256 $Source
    if ($targetHash -eq $sourceHash) { return 'CURRENT' }
    if ($KnownManagedPiBridgeHashes -contains $targetHash -and (Test-KnownPiBridgeShape $Target)) {
        return 'UPDATE_AVAILABLE'
    }
    return 'CONFLICT'
}

function Publish-PiBridgeBytes {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    $parent = Split-Path -Parent $Target
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $sourceBytes = [IO.File]::ReadAllBytes($Source)
    $sourceHash = Get-Sha256 $Source
    $temp = Join-Path $parent ((Split-Path -Leaf $Target) + '.tmp.' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllBytes($temp, $sourceBytes)
        if ((Get-Sha256 $temp) -ne $sourceHash) { throw 'Temporary Pi bridge hash did not match source' }
        [IO.File]::Move($temp, $Target)
        if ((Get-Sha256 $Target) -ne $sourceHash) { throw 'Pi bridge publish did not produce source bytes' }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Update-KnownPiBridge {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$OldHash
    )
    $parent = Split-Path -Parent $Target
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $sourceBytes = [IO.File]::ReadAllBytes($Source)
    $sourceHash = Get-Sha256 $Source
    $currentHash = Get-Sha256 $Target
    if ($currentHash -ne $OldHash) {
        throw "Pi bridge changed before update; expected $OldHash, found $currentHash"
    }

    $backup = Join-Path $parent ((Split-Path -Leaf $Target) + '.backup.' + $OldHash.Substring(0, 12).ToLowerInvariant())
    if (Test-Path -LiteralPath $backup -PathType Leaf) {
        if ((Get-Sha256 $backup) -ne $OldHash) {
            throw "Refusing to overwrite a different managed backup: $backup"
        }
    } else {
        [IO.File]::Copy($Target, $backup, $false)
        if ((Get-Sha256 $backup) -ne $OldHash) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            throw "Managed backup hash did not match old target: $backup"
        }
    }

    $temp = Join-Path $parent ((Split-Path -Leaf $Target) + '.tmp.' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllBytes($temp, $sourceBytes)
        if ((Get-Sha256 $temp) -ne $sourceHash) {
            throw 'Temporary Pi bridge hash did not match source'
        }
        if ($env:AGENT_OBSERVER_INSTALL_TEST_MUTATE_TARGET -eq '1') {
            [IO.File]::WriteAllText($Target, 'test mutation', [Text.UTF8Encoding]::new($false))
        }
        $currentHash = Get-Sha256 $Target
        if ($currentHash -ne $OldHash) {
            throw "Pi bridge changed before atomic replacement; expected $OldHash, found $currentHash"
        }
        $replaceBackup = Join-Path $parent ((Split-Path -Leaf $Target) + '.replace-backup.' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::Replace($temp, $Target, $replaceBackup)
        if ((Get-Sha256 $Target) -ne $sourceHash) {
            throw 'Pi bridge replacement did not produce source bytes'
        }
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        if ($replaceBackup -and (Test-Path -LiteralPath $replaceBackup)) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-PiBridge {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    $state = Get-PiState -Source $Source -Target $Target
    if ($state -eq 'MISSING') {
        $script:actions += [pscustomobject]@{ source = $Source; target = $Target; state = 'ALREADY_ABSENT' }
        return
    }
    if ($state -in @('CURRENT', 'UPDATE_AVAILABLE')) {
        $outcomeState = if ($script:isDryRun) { 'WOULD_REMOVE' } else { 'REMOVED' }
        $script:actions += [pscustomobject]@{ source = $Source; target = $Target; state = $outcomeState }
        if (-not $script:isDryRun) {
            Remove-Item -LiteralPath $Target -Force
        }
        return
    }
    $script:actions += [pscustomobject]@{ source = $Source; target = $Target; state = 'CONFLICT' }
    throw "Refusing to uninstall unowned or modified Pi bridge: $Target (state: $state)"
}

function Remove-GrokBridge {
    param(
        [Parameter(Mandatory)][string]$CollectorPath,
        [Parameter(Mandatory)][string]$Target
    )
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        $script:actions += [pscustomobject]@{ source = $CollectorPath; target = $Target; state = 'ALREADY_ABSENT' }
        return
    }

    $expectedContent = Build-GrokHookJsonContent -CollectorPath $CollectorPath
    $expectedCommand = Build-GrokHookExpectedCommand -CollectorPath $CollectorPath

    $raw = [IO.File]::ReadAllText($Target)
    $isExactFileMatch = ($expectedContent -eq $raw)

    if ($isExactFileMatch) {
        $outcomeState = if ($script:isDryRun) { 'WOULD_REMOVE' } else { 'REMOVED' }
        $script:actions += [pscustomobject]@{ source = $CollectorPath; target = $Target; state = $outcomeState }
        if (-not $script:isDryRun) {
            Remove-Item -LiteralPath $Target -Force
        }
        return
    }

    # Not an exact file match. We MUST NOT delete the whole file.
    # Parse JSON to inspect user settings and hook entries.
    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        $script:actions += [pscustomobject]@{ source = $CollectorPath; target = $Target; state = 'CONFLICT' }
        throw "Refusing to modify invalid Grok hooks configuration: $Target"
    }

    if (-not $parsed -or -not $parsed.hooks) {
        $script:actions += [pscustomobject]@{ source = $CollectorPath; target = $Target; state = 'CONFLICT' }
        throw "Refusing to modify Grok configuration without hooks structure: $Target"
    }

    $knownEvents = Get-KnownGrokEvents

    $hasManaged = $false
    $hasConflict = $false

    $newOrderedHooks = [ordered]@{}
    foreach ($prop in $parsed.hooks.PSObject.Properties) {
        $eventName = $prop.Name
        $entries = @($prop.Value)
        $keptEntries = @()
        foreach ($e in $entries) {
            $isManaged = Test-IsExactManagedGrokEntry -Entry $e -EventName $eventName -ExpectedCommand $expectedCommand -KnownEvents $knownEvents
            if ($isManaged) {
                $hasManaged = $true
            } else {
                if (Test-IsTaintedGrokEntry -Entry $e -EventName $eventName -ExpectedCommand $expectedCommand -KnownEvents $knownEvents) {
                    $hasConflict = $true
                }
                $keptEntries += $e
            }
        }
        # If the event was known and became empty after pruning managed entries, omit the key.
        # But if the event was unknown, or originally empty, or still has entries, preserve it.
        $wasKnown = $knownEvents.Contains($eventName)
        if ($keptEntries.Count -gt 0) {
            $newOrderedHooks[$eventName] = $keptEntries
        } elseif (-not $wasKnown -or $entries.Count -eq 0) {
            $newOrderedHooks[$eventName] = @()
        }
    }

    if ($hasConflict) {
        $script:actions += [pscustomobject]@{ source = $CollectorPath; target = $Target; state = 'CONFLICT' }
        throw "Refusing to modify Grok configuration with modified or ambiguous hook entry: $Target"
    }

    if (-not $hasManaged) {
        $script:actions += [pscustomobject]@{ source = $CollectorPath; target = $Target; state = 'ALREADY_ABSENT' }
        return
    }

    # We have managed entries to prune.
    $outcomeState = if ($script:isDryRun) { 'WOULD_PRUNE' } else { 'PRUNED' }
    $script:actions += [pscustomobject]@{ source = $CollectorPath; target = $Target; state = $outcomeState }

    if (-not $script:isDryRun) {
        $orderedRoot = [ordered]@{}
        foreach ($prop in $parsed.PSObject.Properties) {
            if ($prop.Name -eq 'hooks') { continue }
            $orderedRoot[$prop.Name] = $prop.Value
        }
        $orderedRoot['hooks'] = $newOrderedHooks

        # Construct expected retained object structure: root settings, preserved hooks, empty arrays
        $expectedRetained = [pscustomobject]@{}
        foreach ($prop in $parsed.PSObject.Properties) {
            if ($prop.Name -eq 'hooks') { continue }
            $expectedRetained | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
        }
        $expectedHooks = [pscustomobject]@{}
        foreach ($entry in $newOrderedHooks.GetEnumerator()) {
            $expectedHooks | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
        }
        $expectedRetained | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $expectedHooks

        # Format JSON with deep serialization (depth 100)
        $newJson = ($orderedRoot | ConvertTo-Json -Depth 100) + "`r`n"

        # Verify complete retained object structure, types, and values are preserved losslessly
        try {
            $roundTrip = $newJson | ConvertFrom-Json
            if (-not (Compare-DeepJsonObject $expectedRetained $roundTrip)) {
                throw "Round-trip structural or type divergence detected"
            }
        } catch {
            $script:actions += [pscustomobject]@{ source = $CollectorPath; target = $Target; state = 'CONFLICT' }
            throw "Refusing to write Grok configuration: lossless verification failed ($($_.Exception.Message)): $Target"
        }

        [IO.File]::WriteAllText($Target, $newJson, [Text.UTF8Encoding]::new($false))
    }
}

function Add-BridgeFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Content,
        [switch]$PiBridge
    )

    $state = if ($PiBridge) {
        Get-PiState -Source $Source -Target $Target
    } elseif (-not (Test-Path -LiteralPath $Target)) {
        'MISSING'
    } elseif ((Get-Sha256 $Source) -eq (Get-Sha256 $Target)) {
        'CURRENT'
    } else {
        'CONFLICT'
    }
    $script:actions += [pscustomobject]@{ source = $Source; target = $Target; state = $state }
    if ($script:isDryRun -or $state -eq 'CURRENT') { return }
    if ($PiBridge) {
        if ($state -eq 'MISSING') {
            Publish-PiBridgeBytes -Source $Source -Target $Target
            return
        }
        if ($state -ne 'UPDATE_AVAILABLE' -or -not $UpdateManaged) {
            throw "Refusing Pi bridge update without -Install -UpdateManaged for state ${state}: $Target"
        }
        $oldHash = Get-Sha256 $Target
        Update-KnownPiBridge -Source $Source -Target $Target -OldHash $oldHash
        return
    }
    if ($state -eq 'CONFLICT') {
        throw "Refusing to overwrite an existing different bridge: $Target"
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Target)) | Out-Null
    [IO.File]::WriteAllText($Target, $Content, [Text.UTF8Encoding]::new($false))
}

if ($Scope -in @('Pi', 'All')) {
    $source = Join-Path $repoRoot 'integrations\pi-agent-observer.ts'
    $target = if ($PiTargetPath) { [IO.Path]::GetFullPath($PiTargetPath) } else {
        Join-Path $env:USERPROFILE '.pi\agent\extensions\agent-observer-bridge.ts'
    }
    if ($Uninstall) {
        Remove-PiBridge -Source $source -Target $target
    } else {
        Add-BridgeFile -Source $source -Target $target -Content ([IO.File]::ReadAllText($source)) -PiBridge
    }
}

if ($Scope -in @('Grok', 'All')) {
    $collector = Join-Path $repoRoot 'integrations\grok-observer-hook.ps1'
    $target = if ($GrokTargetPath) { [IO.Path]::GetFullPath($GrokTargetPath) } else {
        Join-Path $env:USERPROFILE '.grok\hooks\agent-observer.json'
    }
    if ($Uninstall) {
        Remove-GrokBridge -CollectorPath $collector -Target $target
    } else {
        $content = Build-GrokHookJsonContent -CollectorPath $collector
        $tempSource = $null
        try {
            if (-not $script:isDryRun) {
                $tempSource = Join-Path $env:TEMP ('agent-observer-grok-hook-config-' + [Guid]::NewGuid().ToString('N') + '.json')
                [IO.File]::WriteAllText($tempSource, $content, [Text.UTF8Encoding]::new($false))
                Add-BridgeFile -Source $tempSource -Target $target -Content $content
            } else {
                # In dry run, check state directly without writing temp file
                $state = if (-not (Test-Path -LiteralPath $target)) {
                    'MISSING'
                } else {
                    $raw = [IO.File]::ReadAllText($target)
                    if ($raw -eq $content) { 'CURRENT' } else { 'CONFLICT' }
                }
                $dummySource = 'synthetic:grok-hook-config'
                $script:actions += [pscustomobject]@{ source = $dummySource; target = $target; state = $state }
            }
        } finally {
            if ($tempSource -and (Test-Path -LiteralPath $tempSource)) {
                Remove-Item -LiteralPath $tempSource -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

[pscustomobject]@{
    mode = $mode
    scope = $Scope
    update_managed = [bool]$UpdateManaged
    actions = $actions
    restart_required = $true
    note = if ($Uninstall) { 'Restart Pi/Grok or reload Grok hooks after uninstallation.' } else { 'Restart Pi/Grok or reload Grok hooks after installation.' }
} | ConvertTo-Json -Depth 5
