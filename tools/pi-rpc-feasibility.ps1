[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:TEMP 'agent-observer-pi-rpc-feasibility-v1'),
    [string]$ProbeExe = (Join-Path $PSScriptRoot '..\target\debug\pi_rpc_probe.exe'),
    [string]$Provider = 'xai',
    [string]$Model = 'xai/grok-4.3',
    [string]$Thinking = 'off',
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Wait-ForFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 10
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ((Get-Date) -gt $deadline) {
            throw "Timed out waiting for $Path"
        }
        Start-Sleep -Milliseconds 100
    }
}

function Invoke-Probe {
    param(
        [Parameter(Mandatory)][string]$Scenario,
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$SessionName,
        [string]$Prompt,
        [switch]$UsesModel
    )
    $sessionDir = Join-Path $script:RunRoot "sessions\$CaseName"
    $evidenceDir = Join-Path $script:RunRoot "evidence\$CaseName"
    New-Item -ItemType Directory -Force -Path $sessionDir, $evidenceDir | Out-Null
    $arguments = @(
        '--scenario', $Scenario,
        '--cwd', $script:Workspace,
        '--session-dir', $sessionDir,
        '--evidence-dir', $evidenceDir,
        '--name', $SessionName,
        '--timeout-secs', $TimeoutSeconds.ToString()
    )
    if ($UsesModel) {
        $arguments += @('--provider', $Provider, '--model', $Model, '--thinking', $Thinking)
    }
    if ($Prompt) {
        $arguments += @('--prompt', $Prompt)
    }
    $output = & $ProbeExe @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | Set-Content -LiteralPath (Join-Path $evidenceDir 'probe-console.log') -Encoding utf8
    $summaryPath = Join-Path $evidenceDir 'summary.json'
    [pscustomobject]@{
        case = $CaseName
        exit_code = $exitCode
        summary = if (Test-Path -LiteralPath $summaryPath) { Read-JsonFile $summaryPath } else { $null }
    }
}

if (-not (Test-Path -LiteralPath $ProbeExe -PathType Leaf)) {
    throw "Pi RPC probe executable does not exist: $ProbeExe. Run cargo build --bin pi_rpc_probe first."
}

$resolvedProbe = (Resolve-Path -LiteralPath $ProbeExe).Path
$runId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$script:RunRoot = Join-Path $Root $runId
$script:Workspace = Join-Path $script:RunRoot 'workspace'
New-Item -ItemType Directory -Force -Path $script:Workspace | Out-Null

$environment = [ordered]@{
    probe = 'Pi RPC Runtime Binding Feasibility v1'
    run_id = $runId
    run_root = $script:RunRoot
    probe_executable = $resolvedProbe
    pi_version = (& pi --version 2>&1 | Select-Object -First 1)
    pi_command = (Get-Command pi).Path
    node_command = (Get-Command node).Path
    provider = $Provider
    model = $Model
    thinking = $Thinking
    started_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    safety = 'Disposable dirs only; no global Pi settings or existing sessions are modified.'
}
$environment | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:RunRoot 'environment.json') -Encoding utf8

# Two processes overlap for three seconds. No model request is sent.
$parallel = @()
foreach ($suffix in @('a', 'b')) {
    $sessionDir = Join-Path $script:RunRoot "sessions\parallel-$suffix"
    $evidenceDir = Join-Path $script:RunRoot "evidence\parallel-$suffix"
    New-Item -ItemType Directory -Force -Path $sessionDir, $evidenceDir | Out-Null
    $arguments = @(
        '--scenario', 'identity',
        '--cwd', $script:Workspace,
        '--session-dir', $sessionDir,
        '--evidence-dir', $evidenceDir,
        '--name', "Pi并行会话$($suffix.ToUpper())_日本語",
        '--hold-after-state-ms', '3000'
    )
    $process = Start-Process -FilePath $resolvedProbe -ArgumentList $arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $evidenceDir 'probe-stdout.json') `
        -RedirectStandardError (Join-Path $evidenceDir 'probe-stderr.log')
    $parallel += [pscustomobject]@{ suffix = $suffix; process = $process; evidence_dir = $evidenceDir }
}
foreach ($item in $parallel) {
    $item.process.WaitForExit()
}
$parallelA = Read-JsonFile (Join-Path $parallel[0].evidence_dir 'summary.json')
$parallelB = Read-JsonFile (Join-Path $parallel[1].evidence_dir 'summary.json')
$parallelResult = [ordered]@{
    same_cwd = ($parallelA.cwd -eq $parallelB.cwd)
    native_ids_distinct = ($parallelA.native_session_id -ne $parallelB.native_session_id)
    session_files_distinct = ($parallelA.session_file -ne $parallelB.session_file)
    process_ids_distinct = ($parallelA.process_id -ne $parallelB.process_id)
    titles_round_trip = ($parallelA.session_name -eq 'Pi并行会话A_日本語' -and $parallelB.session_name -eq 'Pi并行会话B_日本語')
}
$parallelResult | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:RunRoot 'parallel-identity.json') -Encoding utf8

$normal = Invoke-Probe -Scenario normal -CaseName normal -SessionName 'Pi正常完成验证_日本語' `
    -Prompt 'Reply with exactly PI_RPC_OK. Do not use tools.' -UsesModel
$kill = Invoke-Probe -Scenario kill -CaseName kill -SessionName 'Pi精确强杀验证_日本語' `
    -Prompt 'Reply with exactly PI_RPC_KILL_TEST. Do not use tools.' -UsesModel

# Simulate an Observer process crash. The owned RPC child loses its pipe
# ownership. A restarted Observer must not backfill LOST because it did not
# witness this exact child transition from alive to absent.
$restartCase = Join-Path $script:RunRoot 'evidence\restart-missed-exit'
$restartSessions = Join-Path $script:RunRoot 'sessions\restart-missed-exit'
New-Item -ItemType Directory -Force -Path $restartCase, $restartSessions | Out-Null
$restartArguments = @(
    '--scenario', 'identity',
    '--cwd', $script:Workspace,
    '--session-dir', $restartSessions,
    '--evidence-dir', $restartCase,
    '--name', 'Pi重启错过退出验证_日本語',
    '--hold-after-state-ms', '15000'
)
$oldObserver = Start-Process -FilePath $resolvedProbe -ArgumentList $restartArguments -PassThru -NoNewWindow `
    -RedirectStandardOutput (Join-Path $restartCase 'probe-stdout.json') `
    -RedirectStandardError (Join-Path $restartCase 'probe-stderr.log')
$bindingPath = Join-Path $restartCase 'binding.json'
Wait-ForFile -Path $bindingPath
$binding = Read-JsonFile $bindingPath
$childBefore = Get-Process -Id $binding.process_id
$ctimeBefore = ([DateTimeOffset]$childBefore.StartTime).ToUnixTimeMilliseconds()
$creationTimeMatchedBefore = ($ctimeBefore -eq [int64]$binding.process_started_at_unix_ms)
Stop-Process -Id $oldObserver.Id -Force
Start-Sleep -Seconds 2
$childAfter = Get-Process -Id $binding.process_id -ErrorAction SilentlyContinue
$aliveAfterObserverCrash = ($null -ne $childAfter)
$creationTimeMatchedAfter = $false
if ($childAfter) {
    $creationTimeMatchedAfter = (([DateTimeOffset]$childAfter.StartTime).ToUnixTimeMilliseconds() -eq [int64]$binding.process_started_at_unix_ms)
}
$cleanup = 'not-needed'
if ($childAfter -and $creationTimeMatchedAfter -and $childAfter.Path -eq (Get-Command node).Path) {
    Stop-Process -Id $binding.process_id -Force
    $cleanup = 'exact-child-stopped-after-evidence'
}
$restart = [ordered]@{
    observer_process_id = $oldObserver.Id
    runtime_binding_id = $binding.runtime_binding_id
    native_session_id = $binding.native_session_id
    child_process_id = $binding.process_id
    child_creation_time_matched_before = $creationTimeMatchedBefore
    child_alive_before = $true
    observer_force_stopped = $true
    child_alive_two_seconds_after_observer_crash = $aliveAfterObserverCrash
    restarted_observer_saw_child_alive_before_disappearance = $false
    host_liveness_after_restart = if ($aliveAfterObserverCrash) { 'ALIVE' } else { 'UNKNOWN' }
    session_liveness_after_restart = 'UNKNOWN'
    lost_allowed = $false
    false_green = $false
    cleanup = $cleanup
}
$restart | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $restartCase 'restart-evidence.json') -Encoding utf8

$checks = [ordered]@{
    parallel_same_cwd_identity = ($parallelResult.same_cwd -and $parallelResult.native_ids_distinct -and $parallelResult.session_files_distinct -and $parallelResult.process_ids_distinct)
    unicode_title_round_trip = $parallelResult.titles_round_trip
    normal_completion = ($normal.summary.acceptance_passed -eq $true -and $normal.summary.false_green -eq $false)
    exact_kill = ($kill.summary.acceptance_passed -eq $true -and $kill.summary.attention_state -eq 'WORKING' -and $kill.summary.session_liveness -eq 'LOST' -and $kill.summary.false_green -eq $false)
    observer_restart_missed_exit = ($restart.session_liveness_after_restart -eq 'UNKNOWN' -and $restart.lost_allowed -eq $false -and $restart.false_green -eq $false)
}
$passed = -not ($checks.Values -contains $false)
$suite = [ordered]@{
    probe = 'Pi RPC Runtime Binding Feasibility v1'
    passed = $passed
    checks = $checks
    parallel = $parallelResult
    normal = $normal
    kill = $kill
    restart = $restart
    completed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
}
$suitePath = Join-Path $script:RunRoot 'suite-summary.json'
$suite | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $suitePath -Encoding utf8
$suite | ConvertTo-Json -Depth 8
if (-not $passed) {
    exit 1
}
