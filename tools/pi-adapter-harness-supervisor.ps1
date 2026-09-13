[CmdletBinding()]
param(
    [string]$BaseRoot = '',
    [string]$Binary = '',
    [string]$Provider = 'xai',
    [string]$Model = 'xai/grok-4.3',
    [string]$Thinking = 'off',
    [int]$StaleAfterSecs = 32,
    [ValidateRange(5, 60)][int]$HeartbeatSeconds = 10,
    [string]$DiagnosticsRoot = '',
    [switch]$AllowLiveScenario,
    [string]$Scenario = '',
    [int]$ConfirmModelCallBudget = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'harness-lifecycle.ps1')

# Zero-side-effect validation. No directories, lifecycle, or processes yet.
$liveCfg = Assert-HarnessSupervisorInvocation -AllowLiveScenario:$AllowLiveScenario `
    -Scenario $Scenario -ConfirmModelCallBudget $ConfirmModelCallBudget

$expectedBudget = 0
$scenarioTimeout = 0
if ($liveCfg) {
    $expectedBudget = [int]$liveCfg.ModelCallBudget
    $scenarioTimeout = [int]$liveCfg.DefaultTimeoutSeconds
}

if (-not $BaseRoot) {
    $BaseRoot = Join-Path $PSScriptRoot '..\.tmp\pi-adapter-harness'
}
if (-not $DiagnosticsRoot) {
    $DiagnosticsRoot = Join-Path $PSScriptRoot '..\.tmp\pi-adapter-harness-diagnostics'
}

$runId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runRoot = Join-Path ([System.IO.Path]::GetFullPath($BaseRoot)) "supervised\$runId"
$DiagnosticsRoot = [System.IO.Path]::GetFullPath($DiagnosticsRoot)
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

$offlineContext = $null
$liveContext = $null
$failure = $null
$cleanupFailure = $null
$selfTestPassed = $false
$selfTestSummary = $null
$liveAttempted = $false
$liveExitCode = $null
$blockedByProvider = $false
$timedOut = $false
$stage = 'initializing'
$progressPath = Join-Path $runRoot 'harness-progress.json'
$workerSummaryPath = $null
$scenarioStatus = 'OFFLINE'
$acceptancePass = $false
$failureReason = $null
$selfTestRoot = Join-Path $runRoot 'selftest'
$cleanupMeasurement = $null
$cleanupSuccess = $false
$cleanupFailureMessage = $null
$ownedRemaining = 0

function Find-HarnessWorkerSummaryPath {
    param([Parameter(Mandatory)][string]$RunRoot)
    $direct = Join-Path $RunRoot 'scenario-summary.json'
    if (Test-Path -LiteralPath $direct) { return $direct }
    Get-ChildItem -LiteralPath $RunRoot -Recurse -File -Filter 'scenario-summary.json' -ErrorAction SilentlyContinue |
        Select-Object -First 1 |
        ForEach-Object { $_.FullName }
}

function Read-HarnessWorkerSummary {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Read-HarnessSelfTestSummary {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = [string](Get-Content -LiteralPath $Path -Raw)
        $marker = $raw.LastIndexOf('"suite"')
        if ($marker -lt 0) { return $null }
        $brace = $raw.LastIndexOf('{', $marker)
        if ($brace -lt 0) { return $null }
        return $raw.Substring($brace) | ConvertFrom-Json
    } catch {
        return $null
    }
}

try {
    $stage = 'offline-harness-selftest'
    $offlineContext = New-HarnessLifecycle -Name 'Pi Adapter offline self-test' -RunRoot $selfTestRoot `
        -Scenario 'offline-selftest' -OverallTimeoutSeconds 120 -HeartbeatSeconds $HeartbeatSeconds `
        -ProgressFile $progressPath
    Write-HarnessProgress -Path $progressPath -Scenario 'offline-selftest' -Stage $stage `
        -ModelCallBudget 0 -ModelCallsStarted 0
    Write-HarnessHeartbeat -Context $offlineContext -Stage $stage -Scenario 'offline-safety' `
        -ModelCallsStarted 0 -Detail 'network_model_calls=0 independent_lifecycle=120s' -Force

    $selfTestStdout = Join-Path $runRoot 'selftest.stdout.log'
    $selfTestStderr = Join-Path $runRoot 'selftest.stderr.log'
    $selfTestScript = Join-Path $PSScriptRoot 'pi-adapter-harness-selftest.ps1'
    $selfTestArgs = "-NoProfile -NonInteractive -File `"$selfTestScript`" -Root `"$selfTestRoot`" -MaximumRuntimeSeconds 120"
    $selfTest = Start-HarnessProcess -Context $offlineContext -FilePath (Join-Path $PSHOME 'pwsh.exe') `
        -ArgumentList $selfTestArgs -Kind 'harness-selftest' -Scenario 'offline-safety' `
        -RedirectStandardOutput $selfTestStdout -RedirectStandardError $selfTestStderr
    $selfTestExit = Wait-HarnessProcess -Context $offlineContext -Record $selfTest.Record `
        -Stage $stage -TimeoutSeconds 0
    $selfTestSummary = Read-HarnessSelfTestSummary -Path $selfTestStdout
    if ($selfTestExit -ne 0) {
        $stderr = if (Test-Path -LiteralPath $selfTestStderr) { Get-Content -LiteralPath $selfTestStderr -Raw } else { '' }
        throw "Offline harness self-test failed with exit code $selfTestExit. $stderr"
    }
    if ($selfTestSummary -and $selfTestSummary.passed -ne $true) {
        throw 'Offline harness self-test exited 0 but summary.passed was not true.'
    }
    $selfTestPassed = $true

    if (-not $AllowLiveScenario) {
        $stage = 'offline-complete'
        Write-HarnessHeartbeat -Context $offlineContext -Stage $stage -Scenario 'offline-complete' `
            -ModelCallsStarted 0 `
            -Detail 'live scenario disabled; pass -AllowLiveScenario, -Scenario <name> and -ConfirmModelCallBudget <budget> only after review' `
            -Force
        $scenarioStatus = 'OFFLINE'
        $acceptancePass = $false
    } else {
        $stage = "live-scenario-$Scenario"
        $liveAttempted = $true
        $gate = Join-Path $runRoot 'worker.start-gate'
        $workerStdout = Join-Path $runRoot 'worker.stdout.log'
        $workerStderr = Join-Path $runRoot 'worker.stderr.log'
        $workerScript = Join-Path $PSScriptRoot 'pi-adapter-poc-v1.1.ps1'
        if (-not $Binary) {
            $Binary = Join-Path $PSScriptRoot '..\target\debug\agent-observer-poc.exe'
        }
        $workerArgs = @(
            '-NoProfile', '-NonInteractive', '-File', "`"$workerScript`"",
            '-Scenario', $Scenario,
            '-ModelCallBudget', $expectedBudget,
            '-Root', "`"$runRoot`"",
            '-Binary', "`"$Binary`"",
            '-Provider', "`"$Provider`"",
            '-Model', "`"$Model`"",
            '-Thinking', "`"$Thinking`"",
            '-StaleAfterSecs', $StaleAfterSecs,
            '-TimeoutSeconds', $scenarioTimeout,
            '-Supervised',
            '-StartGate', "`"$gate`"",
            '-ProgressFile', "`"$progressPath`""
        ) -join ' '

        $liveContext = New-HarnessLifecycle -Name 'Pi Adapter live scenario' -RunRoot $runRoot `
            -Scenario $Scenario -OverallTimeoutSeconds $scenarioTimeout -HeartbeatSeconds $HeartbeatSeconds `
            -ProgressFile $progressPath
        Write-HarnessProgress -Path $progressPath -Scenario $Scenario -Stage $stage `
            -ModelCallBudget $expectedBudget -ModelCallsStarted 0

        $worker = Start-HarnessProcess -Context $liveContext -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList $workerArgs -Kind 'live-scenario-worker' -Scenario $Scenario `
            -BindingRoot $runRoot -RedirectStandardOutput $workerStdout -RedirectStandardError $workerStderr

        # Absolute scenario deadline starts when the start gate opens.
        Set-Content -LiteralPath $gate -Value 'go' -Encoding ascii
        Set-HarnessDeadline -Context $liveContext -TimeoutSeconds $scenarioTimeout -FromNow
        Write-HarnessHeartbeat -Context $liveContext -Stage $stage -Scenario $Scenario `
            -Detail "deadline=${scenarioTimeout}s model_call_budget=$expectedBudget retries=0 gate=open" -Force

        $liveExitCode = Wait-HarnessProcess -Context $liveContext -Record $worker.Record `
            -Stage $stage -TimeoutSeconds 0 -ProgressFile $progressPath
        $workerSummaryPath = Find-HarnessWorkerSummaryPath -RunRoot $runRoot
        $workerSummary = Read-HarnessWorkerSummary -Path $workerSummaryPath
        $blockedExit = Get-HarnessBlockedExitCode
        if ($liveExitCode -eq $blockedExit -or ($workerSummary -and $workerSummary.status -eq 'BLOCKED')) {
            $blockedByProvider = $true
            $scenarioStatus = 'BLOCKED'
            $acceptancePass = $false
            $timedOut = $false
            $failureReason = if ($workerSummary) { [string]$workerSummary.failure_reason } else { 'BLOCKED_BY_PROVIDER: worker reported provider failure' }
            if ($failureReason -notlike 'BLOCKED_BY_PROVIDER:*') {
                $failureReason = "BLOCKED_BY_PROVIDER: $failureReason"
            }
        } elseif ($liveExitCode -ne 0) {
            $stderr = if (Test-Path -LiteralPath $workerStderr) { Get-Content -LiteralPath $workerStderr -Tail 20 | Out-String } else { '' }
            throw "Live scenario '$Scenario' failed with exit code $liveExitCode. $stderr"
        } else {
            $scenarioStatus = 'PASS'
            $acceptancePass = $true
            if ($workerSummary) {
                $scenarioStatus = [string]$workerSummary.status
                $acceptancePass = [bool]$workerSummary.acceptance_pass
                $timedOut = [bool]$workerSummary.timed_out
                $failureReason = $workerSummary.failure_reason
            }
        }
    }
} catch {
    $failure = $_.Exception
    $failureReason = $failure.Message
    # Shared classification, timeout checked first as before. Only an explicit
    # BLOCKED_BY_PROVIDER message is BLOCKED; a generic harness exception stays FAIL.
    $classification = Resolve-HarnessFailureClassification -Message $failureReason
    if ($classification.timed_out) {
        $timedOut = $true
        $scenarioStatus = 'FAIL'
        $acceptancePass = $false
    } elseif ($classification.blocked) {
        $blockedByProvider = $true
        $scenarioStatus = 'BLOCKED'
        $acceptancePass = $false
        $timedOut = $false
    } else {
        $scenarioStatus = 'FAIL'
        $acceptancePass = $false
    }
} finally {
    try {
        if ($timedOut -and $liveContext) {
            Stop-HarnessOwnedProcesses -Context $liveContext -Reason 'scenario-deadline'
        }
        if ($liveContext) {
            Close-HarnessLifecycle -Context $liveContext -Reason "supervisor-live-finally stage=$stage"
            Assert-NoHarnessProcesses -Context $liveContext
        }
        if ($offlineContext) {
            Close-HarnessLifecycle -Context $offlineContext -Reason "supervisor-offline-finally stage=$stage"
            Assert-NoHarnessProcesses -Context $offlineContext
        }
    } catch {
        $cleanupFailure = $_.Exception
    }
    # Measure cleanup only after the cleanup attempt has finished. The timeout summary
    # below must report these measured values instead of a hardcoded success.
    $cleanupMeasurement = Measure-HarnessCleanup -Contexts @($liveContext, $offlineContext) -CleanupFailure $cleanupFailure
    $cleanupSuccess = [bool]$cleanupMeasurement.cleanup_success
    $cleanupFailureMessage = $cleanupMeasurement.cleanup_failure
    $ownedRemaining = [int]$cleanupMeasurement.owned_processes_remaining
}

if ($timedOut) {
    $workerSummaryPath = Find-HarnessWorkerSummaryPath -RunRoot $runRoot
    $workerSummary = Read-HarnessWorkerSummary -Path $workerSummaryPath
    $needTimeoutSummary = -not $workerSummary -or -not [bool]$workerSummary.timed_out
    if ($needTimeoutSummary) {
        $calls = 0
        $progress = Read-HarnessProgress -Path $progressPath -Fallback $null
        if ($progress) { try { $calls = [int]$progress.model_calls_started } catch { $calls = 0 } }
        $elapsed = 0
        if ($liveContext) {
            $elapsed = [math]::Round(([DateTimeOffset]::UtcNow - $liveContext.StartedAt).TotalSeconds, 3)
        }
        $timeoutPath = Join-Path $runRoot 'scenario-summary.json'
        Write-HarnessTimeoutSummaryFile -Path $timeoutPath -ScenarioName $(if ($Scenario) { $Scenario } else { 'offline-safety' }) `
            -TimeoutSeconds $scenarioTimeout -Budget $expectedBudget -CallsStarted $calls `
            -Root $runRoot -ElapsedSeconds $elapsed -Reason $failureReason `
            -CleanupSuccess:$cleanupSuccess -OwnedProcessesRemaining $ownedRemaining `
            -CleanupFailure $cleanupFailureMessage | Out-Null
        $workerSummaryPath = $timeoutPath
    }
}

$passed = $selfTestPassed -and -not $failure -and -not $cleanupFailure -and $cleanupSuccess -and
    (-not $liveAttempted -or ($liveExitCode -eq 0 -and -not $blockedByProvider -and -not $timedOut))
if ($blockedByProvider -or $timedOut) { $passed = $false; $acceptancePass = $false }
if ($ownedRemaining -ne 0) { $passed = $false }

$acceptanceClaim = Resolve-HarnessAcceptanceClaim -LiveAttempted:$liveAttempted `
    -Status $scenarioStatus -AcceptancePass:$acceptancePass
$scenarioStatus = [string]$acceptanceClaim.status
$acceptancePass = [bool]$acceptanceClaim.acceptance_pass

$modelCallsStarted = 0
$progress = Read-HarnessProgress -Path $progressPath -Fallback $null
if ($progress) {
    try { $modelCallsStarted = [int]$progress.model_calls_started } catch { $modelCallsStarted = 0 }
}

$selfTestResults = $null
$supervisorRejectionValidation = $null
if ($selfTestSummary -and $selfTestSummary.results) {
    $selfTestResults = $selfTestSummary.results
    $supervisorRejectionValidation = [bool](Get-HarnessProperty $selfTestResults 'supervisor_rejection_validation')
}

$summary = [ordered]@{
    supervisor = 'Pi Adapter harness supervisor v1.2'
    passed = $passed
    status = $scenarioStatus
    acceptance_pass = [bool]$acceptancePass
    timed_out = [bool]$timedOut
    run_id = $runId
    run_root = $runRoot
    stage = $stage
    scenario = if ($liveAttempted) { $Scenario } else { 'none' }
    offline_selftest_passed = $selfTestPassed
    live_scenario_attempted = $liveAttempted
    live_model_call_budget = if ($liveAttempted) { $expectedBudget } else { 0 }
    model_calls_started = $modelCallsStarted
    automatic_retries = 0
    scenario_timeout_seconds = if ($liveAttempted) { $scenarioTimeout } else { 0 }
    heartbeat_seconds = $HeartbeatSeconds
    live_exit_code = $liveExitCode
    failure = if ($failure) { $failure.Message } else { $failureReason }
    failure_reason = $failureReason
    cleanup_success = [bool]$cleanupSuccess
    cleanup_failure = $cleanupFailureMessage
    owned_processes_remaining = $ownedRemaining
    worker_summary_path = $workerSummaryPath
    supervisor_rejection_validation = $supervisorRejectionValidation
    selftest_results = $selfTestResults
}
$summaryPath = Join-Path $runRoot 'supervisor-summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
$summary | ConvertTo-Json -Depth 8

if (-not $passed) {
    $diagnosticRoot = Join-Path $DiagnosticsRoot $runId
    New-Item -ItemType Directory -Force -Path $diagnosticRoot | Out-Null
    Copy-Item -LiteralPath $summaryPath -Destination (Join-Path $diagnosticRoot 'supervisor-summary.json') -Force
    if ($workerSummaryPath -and (Test-Path -LiteralPath $workerSummaryPath)) {
        Copy-Item -LiteralPath $workerSummaryPath -Destination (Join-Path $diagnosticRoot 'scenario-summary.json') -Force
    }
    throw "Pi Adapter harness supervisor failed during $stage. See $diagnosticRoot"
}
