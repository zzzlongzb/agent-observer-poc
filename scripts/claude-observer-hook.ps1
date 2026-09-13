param(
    [string]$RawJson,
    [ValidateSet('cli', 'desktop', 'unknown')]
    [string]$Surface = 'unknown',
    [string]$RuntimeBindingId = ''
)

$raw = $RawJson
if ([string]::IsNullOrWhiteSpace($raw)) {
    $raw = $input | Out-String
}
if ([string]::IsNullOrWhiteSpace($raw)) {
    $raw = [Console]::In.ReadToEnd()
}
if ([string]::IsNullOrWhiteSpace($raw)) {
    if ($env:AGENT_OBSERVER_HOOK_DEBUG -eq '1') {
        Write-Error 'Hook received no JSON input.'
    }
    exit 0
}

try {
    $inputEvent = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    if ($env:AGENT_OBSERVER_HOOK_DEBUG -eq '1') {
        Write-Error 'Hook received malformed JSON.'
    }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($inputEvent.session_id)) {
    if ($env:AGENT_OBSERVER_HOOK_DEBUG -eq '1') {
        Write-Error 'Hook event did not contain session_id.'
    }
    exit 0
}

$root = $env:AGENT_OBSERVER_CLAUDE_HOOK_ROOT
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Join-Path $env:LOCALAPPDATA 'agent-observer-poc\claude-hooks'
}

try {
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    $backgroundTasksProperty = $inputEvent.PSObject.Properties['background_tasks']
    $sessionCronsProperty = $inputEvent.PSObject.Properties['session_crons']
    $backgroundTasks = $null
    if ($null -ne $backgroundTasksProperty) {
        $backgroundTasks = @(foreach ($item in @($backgroundTasksProperty.Value)) {
            if ($null -eq $item) { continue }
            [ordered]@{
                id = $item.id
                type = $item.type
                status = $item.status
            }
        })
    }
    $sessionCrons = $null
    if ($null -ne $sessionCronsProperty) {
        $sessionCrons = @(foreach ($item in @($sessionCronsProperty.Value)) {
            if ($null -eq $item) { continue }
            [ordered]@{
                id = $item.id
                schedule = $item.schedule
                recurring = $item.recurring
            }
        })
    }
    $runtimeBindingId = $RuntimeBindingId
    if ([string]::IsNullOrWhiteSpace($runtimeBindingId)) {
        $runtimeBindingId = $env:AGENT_OBSERVER_RUNTIME_BINDING_ID
    }
    $record = [ordered]@{
        observer_schema = 2
        source = 'claude-code-hook'
        hook_event_name = [string]$inputEvent.hook_event_name
        surface = $Surface
        runtime_binding_id = if ([string]::IsNullOrWhiteSpace($runtimeBindingId)) { $null } else { [string]$runtimeBindingId }
        session_id = [string]$inputEvent.session_id
        cwd = [string]$inputEvent.cwd
        prompt_id = $inputEvent.prompt_id
        tool_name = $inputEvent.tool_name
        tool_use_id = $inputEvent.tool_use_id
        tool_id = $inputEvent.tool_id
        task_id = $inputEvent.task_id
        background_task_id = $inputEvent.background_task_id
        background_tasks_present = ($null -ne $backgroundTasksProperty)
        background_tasks = $backgroundTasks
        session_crons_present = ($null -ne $sessionCronsProperty)
        session_crons = $sessionCrons
        observed_at_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress -Depth 16
    $path = Join-Path $root ("{0}.jsonl" -f $inputEvent.session_id)
    [System.IO.File]::AppendAllText($path, $record + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
} catch {
    # Hooks must be observational and never alter Claude Code's decision path.
    if ($env:AGENT_OBSERVER_HOOK_DEBUG -eq '1') {
        Write-Error $_
    }
}

exit 0
