# TEMP-only offline tests for the managed Pi bridge installer.
# Never targets %USERPROFILE%/.pi; all target/source copies are synthetic.
[CmdletBinding()]
param(
    [string]$Installer = '',
    [string]$Runner = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Installer) { $Installer = Join-Path $repoRoot 'tools\install-native-agent-bridges.ps1' }
$installer = [IO.Path]::GetFullPath($Installer)
$source = Join-Path $repoRoot 'integrations\pi-agent-observer.ts'
if (-not $Runner) {
    $Runner = if ($PSVersionTable.PSEdition -eq 'Desktop') { Join-Path $PSHOME 'powershell.exe' } else { Join-Path $PSHOME 'pwsh.exe' }
}
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('agent-observer-installer-test-' + [Guid]::NewGuid().ToString('N'))))
$old = Join-Path $root 'old-bridge.ts'
$unknown = Join-Path $root 'unknown-bridge.ts'
$target = Join-Path $root 'target\agent-observer-bridge.ts'
$results = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()
$knownHash = '5D460657D02E784A6CFC0DD943F3D8ADC3C9363A77EF1AD0E74D8571A7E1558B'
function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function Invoke-Installer([string[]]$Arguments, [hashtable]$Environment = @{}) {
    $oldValues = @{}
    foreach ($name in $Environment.Keys) {
        $oldValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $Environment[$name], 'Process')
    }
    try {
        $raw = @(& $Runner -NoProfile -File $installer @Arguments 2>&1)
        $exit = $LASTEXITCODE
    } catch {
        # Windows PowerShell promotes the child script's terminating throw into
        # this caller because ErrorActionPreference is Stop. Preserve it as a
        # normal non-zero result so refusal cases can be asserted portably.
        $raw = @($_)
        $exit = 1
    }
    try {
        $text = ($raw -join "`n")
        $json = $null
        if ($text.Trim()) {
            try { $json = $text | ConvertFrom-Json } catch { $json = $null }
        }
        [pscustomobject]@{
            exit_code = $exit
            output = $text
            json = $json
        }
    } finally {
        foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable($name, $oldValues[$name], 'Process') }
    }
}
function Assert-Condition([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Run-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; [void]$results.Add([pscustomobject]@{ name = $Name; pass = $true }) }
    catch { [void]$results.Add([pscustomobject]@{ name = $Name; pass = $false; error = $_.Exception.Message }); [void]$failures.Add("${Name}: $($_.Exception.Message)") }
}
try {
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    $sourceBytes = [IO.File]::ReadAllBytes($source)
    # The verified old managed bridge is stored in tests/fixtures to ensure self-test is 100% self-contained.
    $repoOldFixture = Join-Path $repoRoot 'tests\fixtures\managed-old-pi-bridge.ts'
    if (Test-Path -LiteralPath $repoOldFixture) {
        $installed = $repoOldFixture
    } else {
        $installed = Join-Path $env:USERPROFILE '.pi\agent\extensions\agent-observer-bridge.ts'
    }
    Assert-Condition (Test-Path -LiteralPath $installed -PathType Leaf) 'verified old bridge fixture is missing'
    Assert-Condition ((Get-Hash $installed) -eq $knownHash) 'installed old bridge hash no longer matches allow-list'
    $installedText = [IO.File]::ReadAllText($installed)
    foreach ($marker in @('export default function', 'observer_schema: 1', 'source: "pi-extension"', 'appendFileSync', 'session_id')) {
        Assert-Condition $installedText.Contains($marker) "old bridge shape missing $marker"
    }
    [IO.File]::WriteAllBytes($old, [IO.File]::ReadAllBytes($installed))
    [IO.File]::WriteAllText($unknown, 'unknown bridge content', [Text.UTF8Encoding]::new($false))

    Run-Case 'missing -> MISSING' {
        Remove-Item $target -Force -ErrorAction SilentlyContinue
        $r = Invoke-Installer -Arguments @('-Scope','Pi','-PiTargetPath',$target)
        Assert-Condition ($r.exit_code -eq 0) 'missing dry-run failed'
        Assert-Condition ($r.json.actions[0].state -eq 'MISSING') 'missing state mismatch'
        Assert-Condition (-not (Test-Path -LiteralPath $target)) 'missing dry-run wrote target'
    }
    Run-Case 'same bytes -> CURRENT' {
        [IO.File]::WriteAllBytes($target, $sourceBytes)
        $before = Get-Hash $target
        $r = Invoke-Installer -Arguments @('-Scope','Pi','-PiTargetPath',$target)
        Assert-Condition ($r.json.actions[0].state -eq 'CURRENT') 'current state mismatch'
        Assert-Condition ((Get-Hash $target) -eq $before) 'current dry-run changed target'
    }
    Run-Case 'known old -> UPDATE_AVAILABLE' {
        [IO.File]::Copy($old, $target, $true)
        $r = Invoke-Installer -Arguments @('-Scope','Pi','-PiTargetPath',$target)
        Assert-Condition ($r.json.actions[0].state -eq 'UPDATE_AVAILABLE') 'known old state mismatch'
    }
    Run-Case 'unknown -> CONFLICT' {
        [IO.File]::Copy($unknown, $target, $true)
        $r = Invoke-Installer -Arguments @('-Scope','Pi','-PiTargetPath',$target)
        Assert-Condition ($r.json.actions[0].state -eq 'CONFLICT') 'unknown state mismatch'
    }
    Run-Case 'Install without UpdateManaged rejects known old' {
        [IO.File]::Copy($old, $target, $true)
        $r = Invoke-Installer -Arguments @('-Scope','Pi','-Install','-PiTargetPath',$target)
        Assert-Condition ($r.exit_code -ne 0) 'unsafe install unexpectedly succeeded'
        Assert-Condition ((Get-Hash $target) -eq $knownHash) 'unsafe install changed target'
    }
    Run-Case 'Install UpdateManaged updates and backs up' {
        [IO.File]::Copy($old, $target, $true)
        $r = Invoke-Installer -Arguments @('-Scope','Pi','-Install','-UpdateManaged','-PiTargetPath',$target)
        $backup = Get-ChildItem (Split-Path $target) -Filter '*.backup.*' | Select-Object -First 1
        Assert-Condition ($r.exit_code -eq 0) 'managed update failed'
        Assert-Condition ((Get-Hash $target) -eq (Get-Hash $source)) 'updated bytes differ from source'
        Assert-Condition ($null -ne $backup) 'managed backup missing'
        Assert-Condition ((Get-Hash $backup.FullName) -eq $knownHash) 'backup bytes differ from old bridge'
    }
    Run-Case 'unknown with UpdateManaged rejects' {
        [IO.File]::Copy($unknown, $target, $true)
        $before = Get-Hash $target
        $r = Invoke-Installer -Arguments @('-Scope','Pi','-Install','-UpdateManaged','-PiTargetPath',$target)
        Assert-Condition ($r.exit_code -ne 0) 'unknown update unexpectedly succeeded'
        Assert-Condition ((Get-Hash $target) -eq $before) 'unknown update changed target'
    }
    Run-Case 'TOCTOU hash change rejects and cleans temp' {
        [IO.File]::Copy($old, $target, $true)
        $r = Invoke-Installer -Arguments @('-Scope','Pi','-Install','-UpdateManaged','-PiTargetPath',$target) -Environment @{ AGENT_OBSERVER_INSTALL_TEST_MUTATE_TARGET = '1' }
        Assert-Condition ($r.exit_code -ne 0) 'TOCTOU update unexpectedly succeeded'
        Assert-Condition ((Get-Hash $target) -ne (Get-Hash $source)) 'TOCTOU target was not protected'
        Assert-Condition (@(Get-ChildItem (Split-Path $target) -Filter '*.tmp.*').Count -eq 0) 'TOCTOU temp file remains'
    }
    Run-Case 'dry-run does not write' {
        [IO.File]::Copy($old, $target, $true)
        $before = Get-Hash $target
        $backupBefore = @(Get-ChildItem (Split-Path $target) -Filter '*.backup.*').Count
        $r = Invoke-Installer -Arguments @('-Scope','Pi','-UpdateManaged','-PiTargetPath',$target)
        Assert-Condition ($r.json.actions[0].state -eq 'UPDATE_AVAILABLE') 'dry-run state mismatch'
        Assert-Condition ((Get-Hash $target) -eq $before) 'dry-run changed target'
        Assert-Condition (@(Get-ChildItem (Split-Path $target) -Filter '*.backup.*').Count -eq $backupBefore) 'dry-run wrote backup'
    }
} catch { [void]$failures.Add($_.Exception.Message) }
finally {
    try { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } } catch { [void]$failures.Add("scratch cleanup: $($_.Exception.Message)") }
}
$summary = [ordered]@{
    test = 'Pi managed installer TEMP self-test'
    powershell = $PSVersionTable.PSVersion.ToString()
    runner = $Runner
    pass = ($failures.Count -eq 0)
    cases = $results
    failures = $failures
    scratch_remaining = (Test-Path -LiteralPath $root)
    real_user_extension_touched = $false
    known_managed_old_hash = $knownHash
}
$summary | ConvertTo-Json -Depth 8
if (-not $summary.pass) { exit 1 }
