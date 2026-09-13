param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('codex', 'claude')]
    [string]$Family,

    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [string]$ObserverExe = (Join-Path $PSScriptRoot '..\target\debug\agent-observer-poc.exe'),

    [string]$OutputRoot = (Join-Path $Workspace ("smoke-{0}-{1}" -f $Family, [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path
$ObserverExe = (Resolve-Path -LiteralPath $ObserverExe).Path
[System.IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
$bindingRoot = Join-Path $OutputRoot 'runtime-bindings'
$hookRoot = Join-Path $OutputRoot 'claude-hooks'
$emptyRoot = Join-Path $OutputRoot 'empty'
[System.IO.Directory]::CreateDirectory($bindingRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($hookRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($emptyRoot) | Out-Null

$runnerStdout = Join-Path $OutputRoot 'runner.stdout.jsonl'
$runnerStderr = Join-Path $OutputRoot 'runner.stderr.txt'
$arguments = @(
    'run', $Family,
    '--cwd', $Workspace,
    '--runtime-binding-root', $bindingRoot,
    '--claude-hook-root', $hookRoot,
    '--'
)
if ($Family -eq 'claude') {
    $arguments += @('-p', 'Use PowerShell to run Start-Sleep -Seconds 120, then reply with exactly DONE.')
} else {
    $arguments += 'Use PowerShell to run Start-Sleep -Seconds 120, then reply with exactly DONE.'
}

$runnerStart = [System.Diagnostics.ProcessStartInfo]::new()
$runnerStart.FileName = $ObserverExe
$runnerStart.WorkingDirectory = $Workspace
$runnerStart.UseShellExecute = $false
$runnerStart.CreateNoWindow = $true
$runnerStart.RedirectStandardOutput = $true
$runnerStart.RedirectStandardError = $true
foreach ($argument in $arguments) {
    $runnerStart.ArgumentList.Add($argument)
}
$runner = [System.Diagnostics.Process]::Start($runnerStart)
$runnerStdoutTask = $runner.StandardOutput.ReadToEndAsync()
$runnerStderrTask = $runner.StandardError.ReadToEndAsync()

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $record = $null
    $recordPath = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $candidate = Get-ChildItem -LiteralPath $bindingRoot -Filter '*.json' -File |
            Select-Object -First 1
        if ($null -ne $candidate) {
            try {
                $parsed = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace($parsed.native_session_id) -and
                    -not [string]::IsNullOrWhiteSpace($parsed.active_runtime_id)) {
                    $record = $parsed
                    $recordPath = $candidate.FullName
                    break
                }
            } catch {
                # A read can race the Observer rewriting this small JSON file; retry it.
            }
        }
        if ($runner.HasExited) {
            throw "Observer runner exited before an exact active binding was recorded."
        }
        Start-Sleep -Milliseconds 200
        $runner.Refresh()
    }
    if ($null -eq $record) {
        throw "Timed out waiting for an exact active $Family runtime binding."
    }

    $child = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $record.process_id)
    if ($null -eq $child) {
        throw "Bound child PID $($record.process_id) disappeared before the crash step."
    }
    if ([uint32]$child.ParentProcessId -ne [uint32]$runner.Id) {
        throw "Safety check failed: bound child PID is not owned by runner PID $($runner.Id)."
    }
    $live = Get-Process -Id ([int]$record.process_id) -ErrorAction Stop
    $liveStart = [DateTimeOffset]$live.StartTime
    if ([int64]$liveStart.ToUnixTimeMilliseconds() -ne [int64]$record.process_started_at_unix_ms) {
        throw "Safety check failed: PID creation time no longer matches the binding record."
    }
    if ($record.cwd -ne $Workspace) {
        throw "Safety check failed: binding cwd is not the disposable workspace."
    }

    # Give the owning monitor at least one complete poll after exact identity appeared.
    Start-Sleep -Seconds 1
    Stop-Process -Id ([int]$record.process_id) -Force
    if (-not $runner.WaitForExit(30000)) {
        throw "Observer runner did not exit after its owned child was killed."
    }
    [System.IO.File]::WriteAllText($runnerStdout, $runnerStdoutTask.GetAwaiter().GetResult())
    [System.IO.File]::WriteAllText($runnerStderr, $runnerStderrTask.GetAwaiter().GetResult())

    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    if ($null -eq $record.abnormal_exit_observed_at_unix_ms) {
        throw "The owning Observer did not persist an abnormal exact-runtime exit."
    }

    $scanStdout = Join-Path $OutputRoot 'restart-scan.jsonl'
    $scanStderr = Join-Path $OutputRoot 'restart-scan.stderr.txt'
    $scan = [System.Diagnostics.ProcessStartInfo]::new()
    $scan.FileName = $ObserverExe
    $scan.UseShellExecute = $false
    $scan.CreateNoWindow = $true
    foreach ($argument in @(
        'observe', '--all', '--json', '--cwd', $Workspace,
        '--runtime-binding-root', $bindingRoot
    )) {
        $scan.ArgumentList.Add($argument)
    }
    $scan.Environment['AGENT_OBSERVER_CODEX_ROOT'] = $emptyRoot
    $scan.Environment['AGENT_OBSERVER_CLAUDE_ROOT'] = $emptyRoot
    $scan.Environment['AGENT_OBSERVER_CLAUDE_SESSION_ROOT'] = $emptyRoot
    $scan.Environment['AGENT_OBSERVER_CLAUDE_HOOK_ROOT'] = $hookRoot
    $scan.RedirectStandardOutput = $true
    $scan.RedirectStandardError = $true
    $scanProcess = [System.Diagnostics.Process]::Start($scan)
    $scanOutput = $scanProcess.StandardOutput.ReadToEnd()
    $scanError = $scanProcess.StandardError.ReadToEnd()
    $scanProcess.WaitForExit()
    [System.IO.File]::WriteAllText($scanStdout, $scanOutput)
    [System.IO.File]::WriteAllText($scanStderr, $scanError)
    if ($scanProcess.ExitCode -ne 0) {
        throw "Restart scan failed with exit code $($scanProcess.ExitCode)."
    }

    $scanRecord = $scanOutput.Trim() | ConvertFrom-Json
    $session = @($scanRecord.sessions) |
        Where-Object { $_.native_session_id -eq $record.native_session_id } |
        Select-Object -First 1
    if ($null -eq $session) {
        throw "Restart scan did not retain native session $($record.native_session_id)."
    }
    if ($session.attention_state -ne 'WORKING' -or
        $session.host_liveness -ne 'DEAD' -or
        $session.session_liveness -ne 'LOST') {
        throw "Unexpected crash state: $($session.attention_state)/$($session.host_liveness)/$($session.session_liveness)."
    }
    if ($session.attention_state -eq 'RESULT_READY') {
        throw 'False green: crash was reported as RESULT_READY.'
    }

    $summary = [ordered]@{
        family = $Family
        runtime_binding_id = $record.runtime_binding_id
        native_session_id = $record.native_session_id
        active_runtime_id = $record.active_runtime_id
        process_id = $record.process_id
        process_started_at_unix_ms = $record.process_started_at_unix_ms
        attention_state = $session.attention_state
        evidence_freshness = $session.evidence_freshness
        host_liveness = $session.host_liveness
        session_liveness = $session.session_liveness
        false_green = $false
        restart_identity_preserved = $true
    }
    $summaryPath = Join-Path $OutputRoot 'summary.json'
    [System.IO.File]::WriteAllText(
        $summaryPath,
        (($summary | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    )
    $summary | ConvertTo-Json -Depth 8
} finally {
    $runner.Refresh()
    if (-not $runner.HasExited) {
        Get-CimInstance Win32_Process -Filter ("ParentProcessId={0}" -f $runner.Id) |
            ForEach-Object {
                Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        Stop-Process -Id $runner.Id -Force -ErrorAction SilentlyContinue
    }
}
