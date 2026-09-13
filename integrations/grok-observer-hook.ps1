param()

$ErrorActionPreference = 'Stop'

function Test-EnumerableCollection {
    param([object]$InputObject, [string]$Name)

    if ($null -eq $InputObject) { return $false }
    if ($InputObject.PSObject.Properties.Name -notcontains $Name) { return $false }
    $value = $InputObject.$Name
    if ($null -eq $value) { return $false }
    # A JSON object or a bare string is never background-work evidence.
    if ($value -is [string]) { return $false }
    if ($value -is [System.Collections.IDictionary]) { return $false }
    return $value -is [System.Collections.IEnumerable]
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $inputEvent = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace([string]$inputEvent.subagentType)) { exit 0 }

    $eventNames = @{
        'session_start' = 'SessionStart'
        'user_prompt_submit' = 'UserPromptSubmit'
        'pre_tool_use' = 'PreToolUse'
        'post_tool_use' = 'PostToolUse'
        'post_tool_use_failure' = 'PostToolUseFailure'
        'permission_denied' = 'PermissionDenied'
        'stop' = 'Stop'
        'stop_failure' = 'StopFailure'
        'stop_cancelled' = 'StopCancelled'
        'notification' = 'Notification'
        'session_end' = 'SessionEnd'
    }
    $rawEventName = [string]$inputEvent.hookEventName
    $canonicalEvent = $eventNames[$rawEventName.ToLowerInvariant()]
    if ([string]::IsNullOrWhiteSpace($canonicalEvent)) { exit 0 }
    $sessionId = [string]$inputEvent.sessionId
    if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

    # Only a real, enumerable collection may become an array.
    # Fixed semantics:
    # - If explicitly empty array `[]` -> serialize as `[]`
    # - If non-empty array with valid items -> serialize as sanitized metadata array
    # - If non-empty array but all items are null/empty/invalid -> serialize as `$null` (NEVER `[]`)
    # - If missing, null, string, dictionary, or non-array -> serialize as `$null`
    $background = $null
    if (Test-EnumerableCollection $inputEvent 'backgroundTasks') {
        $rawItems = @($inputEvent.backgroundTasks)
        if ($rawItems.Count -eq 0) {
            $background = @()
        } else {
            $valid = @()
            foreach ($item in $rawItems) {
                if ($null -eq $item) { continue }
                if ([string]::IsNullOrWhiteSpace([string]$item.id) -and
                    [string]::IsNullOrWhiteSpace([string]$item.type) -and
                    [string]::IsNullOrWhiteSpace([string]$item.status)) { continue }
                $valid += [ordered]@{
                    id = [string]$item.id
                    type = [string]$item.type
                    status = [string]$item.status
                }
            }
            if ($valid.Count -gt 0) {
                $background = $valid
            }
        }
    }
    $crons = $null
    if (Test-EnumerableCollection $inputEvent 'sessionCrons') {
        $rawItems = @($inputEvent.sessionCrons)
        if ($rawItems.Count -eq 0) {
            $crons = @()
        } else {
            $valid = @()
            foreach ($item in $rawItems) {
                if ($null -eq $item) { continue }
                if ([string]::IsNullOrWhiteSpace([string]$item.id) -and
                    [string]::IsNullOrWhiteSpace([string]$item.schedule)) { continue }
                $valid += [ordered]@{
                    id = [string]$item.id
                    schedule = [string]$item.schedule
                    recurring = [bool]$item.recurring
                }
            }
            if ($valid.Count -gt 0) {
                $crons = $valid
            }
        }
    }

    $observedAt = [DateTimeOffset]::UtcNow
    if (-not [string]::IsNullOrWhiteSpace([string]$inputEvent.timestamp)) {
        try { $observedAt = [DateTimeOffset]::Parse([string]$inputEvent.timestamp) } catch {}
    }
    $record = [ordered]@{
        observer_schema = 1
        source = 'grok-hook'
        surface = 'cli'
        event = $canonicalEvent
        session_id = $sessionId
        cwd = [string]$inputEvent.cwd
        prompt_id = [string]$inputEvent.promptId
        observed_at_utc = $observedAt.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        reason = [string]$inputEvent.reason
        notification_type = [string]$inputEvent.notificationType
        background_tasks = $background
        session_crons = $crons
    }

    $root = if ([string]::IsNullOrWhiteSpace($env:AGENT_OBSERVER_GROK_HOOK_ROOT)) {
        Join-Path $env:LOCALAPPDATA 'agent-observer-poc\grok-hooks'
    } else {
        $env:AGENT_OBSERVER_GROK_HOOK_ROOT
    }
    $safeId = $sessionId -replace '[^A-Za-z0-9._-]', '_'
    $sessionRoot = Join-Path $root $safeId
    [IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $name = '{0}-{1}.json' -f $stamp, [Guid]::NewGuid().ToString('N')
    $target = Join-Path $sessionRoot $name
    $temp = "$target.tmp"
    $json = $record | ConvertTo-Json -Compress -Depth 6
    [IO.File]::WriteAllText($temp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $target)
} catch {
    # Grok hooks are observation-only and must always fail open.
}

exit 0
