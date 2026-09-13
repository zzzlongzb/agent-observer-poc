# Daily-use Local Package v0.1 R3 Safety Repair 2 - OFFLINE SAFETY SUPERVISOR.
#
# Single supervised entry point for the offline safety self-test. One worker,
# one attempt per evidence root, no -Force / -Retry / -IgnoreGate /
# -ResetAttempt / -OverwriteEvidence.
#
# Order:
#   1. After param parse, set started_at and absolute_deadline_at once.
#   2. Atomically create the attempt marker.
#   3. Atomically start and Job-own the worker.
#   4. Update the marker to RUNNING.
#   5. Create the one-shot start gate LAST.
# The worker may begin fixtures only after consuming the start gate.
#
# final-summary.json is written only from the single terminal path at the
# bottom of this script, and only when worker_start_count == 1. If this
# process dies first, the marker and incremental events remain; the status
# is INCOMPLETE; this script will not backfill a summary.
#
# Supervisor-process-level hard cutoff is UNPROVEN under PowerShell: this
# process can still block inside Add-Type. The worker tree is Job-owned.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$EvidenceRoot = '',
    [string]$WorkerScript = '',
    [ValidateRange(5, 300)][int]$OuterDeadlineSeconds = 110,
    [ValidateRange(5, 300)][int]$WorkerDeadlineSeconds = 90,
    [string]$RunId = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# First moment after param parse: the only full deadline this run will ever get.
$startedAt = [DateTimeOffset]::UtcNow
$absoluteDeadlineAt = $startedAt.AddSeconds($OuterDeadlineSeconds)

. (Join-Path $PSScriptRoot 'local-package-harness.ps1')

$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $EvidenceRoot) {
    throw 'EvidenceRoot is required; this runner will not default to a sealed evidence root'
}
if (-not $WorkerScript) {
    $WorkerScript = Join-Path $PSScriptRoot 'local-package-safety-worker.ps1'
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
$WorkerScript = [IO.Path]::GetFullPath($WorkerScript)

if (-not $RunId) {
    $RunId = ("{0:yyyyMMddTHHmmssfffZ}-{1}" -f $startedAt.UtcDateTime, ([Guid]::NewGuid().ToString('n')))
}

$markerPath = Join-Path $EvidenceRoot 'attempt.json'
$finalSummaryPath = Join-Path $EvidenceRoot 'final-summary.json'
$startGatePath = Join-Path $EvidenceRoot 'start-gate.json'
$startGateConsumedPath = Join-Path $EvidenceRoot 'start-gate.consumed.json'
$runDirectory = Join-Path $EvidenceRoot $RunId
$windowHelperScript = Join-Path $PSScriptRoot 'local-package-window-probe-helper.ps1'
$utf8 = New-Object System.Text.UTF8Encoding $false

$supervisorPid = [int]$PID
$supervisorCreationTimeUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
$startGateToken = [Guid]::NewGuid().ToString('n')

$markerCreated = $false
$workerStartCount = 0
$startGateCreated = $false
$summaryWritten = $false
$emergencyCleanupBudgetMs = 5000
$emergencyCleanupUsedMs = 0

$context = $null
$workerRun = $null
$workerExitCode = $null
$workerSummary = $null
$timeoutDetected = $false
$failureReason = $null
$cleanupMeasure = $null
$workerOwnedRemaining = 0
$ownedRecords = [object[]]@()
$baselineConsoleIds = [int[]]@()
$finalConsoleIds = [int[]]@()
$visibleWindowsObservation = 'UNKNOWN'
$visibleWindowsCreated = $true
$newConsoleWindows = New-Object System.Collections.Generic.List[int]
$windowProbeError = $null

function Get-LocalSupervisorRemainingMilliseconds {
    [int][math]::Max(0, [math]::Floor(($absoluteDeadlineAt - [DateTimeOffset]::UtcNow).TotalMilliseconds))
}

function Assert-LocalSupervisorDeadline {
    param([Parameter(Mandatory)][string]$Stage)
    if ([DateTimeOffset]::UtcNow -ge $absoluteDeadlineAt) {
        throw "SUPERVISOR TIMEOUT during ${Stage}: absolute_deadline_at $($absoluteDeadlineAt.ToString('o')) exceeded"
    }
}

function Invoke-LocalWindowProbeHelper {
    param(
        [Parameter(Mandatory)]$Lifecycle,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$Stage
    )
    $result = [pscustomobject][ordered]@{
        status = 'UNKNOWN'
        ids = [int[]]@()
        error = $null
    }
    if (-not (Test-Path -LiteralPath $windowHelperScript)) {
        $result.error = "window probe helper missing: $windowHelperScript"
        return $result
    }
    try {
        Assert-HarnessDeadline -Context $Lifecycle -Stage $Stage
        $timeoutSeconds = 3
        $remainMs = Get-HarnessRemainingMilliseconds -Context $Lifecycle
        if ($remainMs -lt 200) {
            $result.error = 'insufficient remaining time for window probe helper'
            return $result
        }
        if ($remainMs -lt 3000) {
            $timeoutSeconds = [int][math]::Max(1, [math]::Floor($remainMs / 1000.0))
            if ($timeoutSeconds -gt 3) { $timeoutSeconds = 3 }
        }
        $helper = Start-HarnessProcess -Context $Lifecycle -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $windowHelperScript, `
                '-OutputPath', $OutputPath, '-DeadlineSeconds', [string]$timeoutSeconds) `
            -Kind ("window-probe-" + $Stage) -Scenario 'offline-safety-selftest' `
            -WorkingDirectory $script:RepoRoot
        try {
            $null = Wait-HarnessProcess -Context $Lifecycle -Record $helper.Record -Stage $Stage -TimeoutSeconds $timeoutSeconds
        } catch {
            $result.error = [string]$_.Exception.Message
            return $result
        }
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            $result.error = "window probe helper produced no output at $OutputPath"
            return $result
        }
        $parsed = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
        if ($null -eq $parsed -or [string]$parsed.status -ne 'ok') {
            $result.error = [string](Get-HarnessProperty $parsed 'error')
            if (-not $result.error) { $result.error = 'window probe helper status not ok' }
            return $result
        }
        $result.status = 'ok'
        $result.ids = ConvertTo-LocalInt32IdArray -Value (Get-HarnessProperty $parsed 'ids')
        return $result
    } catch {
        $result.error = [string]$_.Exception.Message
        return $result
    }
}

# ---------------------------------------------------------------------------
# 1. One-shot attempt marker. Duplicate / create failure: no summary.
# ---------------------------------------------------------------------------
try {
    Assert-LocalSupervisorDeadline -Stage 'attempt-marker'
    [IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null
    New-LocalSafetyAttemptMarker -Path $markerPath -RunId $RunId `
        -SupervisorPid $supervisorPid `
        -SupervisorCreationTimeUtc $supervisorCreationTimeUtc | Out-Null
    $markerCreated = $true
}
catch {
    Write-Warning $_.Exception.Message
    exit 3
}

try {
    Assert-LocalSupervisorDeadline -Stage 'stale-evidence-check'
    # Phase SupervisorPreLaunch: BEFORE the worker is launched, prove that none
    # of the six official output files exist. The two transport logs are then
    # created by SafeProcessLauncher with FileMode.CreateNew before the worker
    # can execute any code (an existing file refuses the launch).
    Assert-LocalSafetyEvidenceRootHasNoStaleFiles -EvidenceRoot $EvidenceRoot -RunDirectory $runDirectory -Phase SupervisorPreLaunch
    if (Test-Path -LiteralPath $runDirectory) {
        throw "unique run directory already exists: $runDirectory"
    }
    if (Test-Path -LiteralPath $startGatePath) {
        throw "start gate already exists: $startGatePath"
    }
    if (Test-Path -LiteralPath $startGateConsumedPath) {
        throw "start gate already consumed: $startGateConsumedPath"
    }
    [IO.Directory]::CreateDirectory($runDirectory) | Out-Null

    $context = New-HarnessLifecycle -Name 'offline-safety-supervisor' -RunRoot $runDirectory `
        -Scenario 'offline-safety-selftest' -OverallTimeoutSeconds $OuterDeadlineSeconds -HeartbeatSeconds 5 `
        -StartedAt $startedAt -AbsoluteDeadlineAt $absoluteDeadlineAt

    $baselineProbe = Invoke-LocalWindowProbeHelper -Lifecycle $context `
        -OutputPath (Join-Path $runDirectory 'window-probe-baseline.json') `
        -Stage 'window-probe-baseline'
    if ([string]$baselineProbe.status -ne 'ok') {
        $visibleWindowsObservation = 'UNKNOWN'
        $windowProbeError = [string]$baselineProbe.error
        $failureReason = "visible-window baseline probe UNKNOWN: $windowProbeError"
        $visibleWindowsCreated = $true
        $baselineConsoleIds = [int[]]@()
    } else {
        $baselineConsoleIds = [int[]]$baselineProbe.ids
        $visibleWindowsObservation = 'ok'
    }

    Assert-HarnessDeadline -Context $context -Stage 'start-worker'
    $workerStdoutLog = Join-Path $runDirectory 'worker-stdout.log'
    $workerStderrLog = Join-Path $runDirectory 'worker-stderr.log'
    $workerRun = Start-HarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $WorkerScript,
            '-Supervised',
            '-RunId', $RunId,
            '-SupervisorPid', [string]$supervisorPid,
            '-SupervisorCreationTimeUtc', $supervisorCreationTimeUtc,
            '-AttemptMarkerPath', $markerPath,
            '-StartGatePath', $startGatePath,
            '-StartGateToken', $startGateToken,
            '-EvidenceRoot', $EvidenceRoot,
            '-RunDirectory', $runDirectory,
            '-OverallDeadlineSeconds', [string]$WorkerDeadlineSeconds) `
        -Kind 'offline-safety-worker' -Scenario 'offline-safety-selftest' `
        -WorkingDirectory $script:RepoRoot `
        -RedirectStandardOutput $workerStdoutLog `
        -RedirectStandardError $workerStderrLog
    $workerStartCount = 1

    Update-LocalSafetyAttemptMarker -Path $markerPath -Status 'RUNNING' | Out-Null

    New-LocalSafetyStartGate -Path $startGatePath -RunId $RunId -Token $startGateToken `
        -SupervisorPid $supervisorPid -SupervisorCreationTimeUtc $supervisorCreationTimeUtc | Out-Null
    $startGateCreated = $true

    # Bounded supervisor wait against the SAME absolute deadline. Never
    # recompute a fresh OuterDeadlineSeconds budget here.
    while (-not $workerRun.Launcher.WaitForExit(200)) {
        if ([DateTimeOffset]::UtcNow -ge $absoluteDeadlineAt) {
            $timeoutDetected = $true
            break
        }
        Write-HarnessHeartbeat -Context $context -Stage 'supervisor-wait' `
            -Detail ("worker_pid=$($workerRun.Record.ProcessId)") -Force:$false
    }

    if ($timeoutDetected) {
        $failureReason = "SUPERVISOR TIMEOUT: worker PID $($workerRun.Record.ProcessId) exceeded absolute_deadline_at $($absoluteDeadlineAt.ToString('o')) and its owned tree will be terminated via the kill-on-close Job Object"
    }
    else {
        $workerExitCode = Get-HarnessProcessExitCode -Record $workerRun.Record -Stage 'offline-safety-worker'
        $drainMs = 1
        try {
            $drainMs = Get-HarnessClippedTimeoutMilliseconds -Context $context -RequestedMilliseconds 10000 -Stage 'worker-drains'
        } catch {
            $drainMs = [int][math]::Max(1, (Get-LocalSupervisorRemainingMilliseconds))
        }
        if (-not $workerRun.Launcher.WaitDrains($drainMs)) {
            $failureReason = 'worker exited but stdout/stderr drains did not complete'
        }
        $workerSummaryPath = Join-Path $runDirectory 'worker-summary.json'
        if (Test-Path -LiteralPath $workerSummaryPath) {
            try { $workerSummary = Get-Content -LiteralPath $workerSummaryPath -Raw | ConvertFrom-Json } catch { $workerSummary = $null }
        }
        if ($null -eq $workerSummary) {
            if (-not $failureReason) {
                $failureReason = "worker exited with code $workerExitCode but produced no parsable worker-summary.json"
            }
        }
    }

    if ($null -ne $context -and $null -ne $context.Job) {
        $finalProbe = Invoke-LocalWindowProbeHelper -Lifecycle $context `
            -OutputPath (Join-Path $runDirectory 'window-probe-final.json') `
            -Stage 'window-probe-final'
        if ([string]$finalProbe.status -ne 'ok') {
            $visibleWindowsObservation = 'UNKNOWN'
            $windowProbeError = [string]$finalProbe.error
            $visibleWindowsCreated = $true
            if (-not $failureReason) {
                $failureReason = "visible-window final probe UNKNOWN: $windowProbeError"
            }
        } else {
            $finalConsoleIds = [int[]]$finalProbe.ids
            $baselineSet = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($id in $baselineConsoleIds) { [void]$baselineSet.Add([int]$id) }
            foreach ($id in $finalConsoleIds) {
                $intId = [int]$id
                if (-not $baselineSet.Contains($intId)) { [void]$newConsoleWindows.Add($intId) }
            }
            $visibleWindowsCreated = ($newConsoleWindows.Count -gt 0)
            if ($visibleWindowsObservation -ne 'UNKNOWN') { $visibleWindowsObservation = 'ok' }
        }
    }
}
catch {
    $message = [string]$_.Exception.Message
    if ($message -like '*SUPERVISOR TIMEOUT*' -or $message -like '*deadline exceeded*') {
        $timeoutDetected = $true
    }
    if (-not $failureReason) { $failureReason = "supervisor error: $message" }
}
finally {
    $emergencyStarted = [DateTimeOffset]::UtcNow
    $cleanupFailure = $null
    if ($null -ne $context) {
        try {
            $context.EmergencyCleanupBudgetMs = [int]$emergencyCleanupBudgetMs
            Close-HarnessLifecycle -Context $context -Reason $(if ($timeoutDetected) { 'supervisor-timeout' } else { 'worker-finished' })
        } catch {
            $cleanupFailure = $_.Exception.Message
        }
    }
    $cleanupMeasure = Measure-HarnessCleanup -Contexts @($context) -CleanupFailure $cleanupFailure

    $ownedRecordsPath = Join-Path $runDirectory 'owned-processes.jsonl'
    $ownedRecords = ConvertTo-LocalObjectArray -Value (Read-LocalOwnedProcessRecords -Path $ownedRecordsPath)
    if ($ownedRecords.Count -gt 0) {
        $residualBudgetMs = [int][math]::Max(0, $emergencyCleanupBudgetMs - [int]([DateTimeOffset]::UtcNow - $emergencyStarted).TotalMilliseconds)
        $residualDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds($residualBudgetMs)
        do {
            $alive = New-Object System.Collections.Generic.List[object]
            foreach ($record in $ownedRecords) {
                if (Test-HarnessProcessRecordAlive -Record $record) { [void]$alive.Add($record) }
            }
            $workerOwnedRemaining = $alive.Count
            if ($workerOwnedRemaining -eq 0) { break }
            $now = [DateTimeOffset]::UtcNow
            if ($now -ge $residualDeadline) { break }
            $slice = [math]::Min(100, ($residualDeadline - $now).TotalMilliseconds)
            if ($slice -le 0) { break }
            Start-Sleep -Milliseconds ([int][math]::Max(1, $slice))
        } while ([DateTimeOffset]::UtcNow -lt $residualDeadline)
        $alive = New-Object System.Collections.Generic.List[object]
        foreach ($record in $ownedRecords) {
            if (Test-HarnessProcessRecordAlive -Record $record) { [void]$alive.Add($record) }
        }
        $workerOwnedRemaining = $alive.Count
    }
    $emergencyCleanupUsedMs = [int][math]::Max(0, [int]([DateTimeOffset]::UtcNow - $emergencyStarted).TotalMilliseconds)
    if ($null -ne $context) {
        try { $context.EmergencyCleanupUsedMs = [int]$emergencyCleanupUsedMs } catch { }
    }
}

# ---------------------------------------------------------------------------
# 2. Single terminal verdict path. The only writer of final-summary.json.
# ---------------------------------------------------------------------------
$finishedAt = [DateTimeOffset]::UtcNow
$actualDurationMs = [int][Math]::Round(($finishedAt - $startedAt).TotalMilliseconds)

# Deadline overrun verdict (frozen acceptance criterion): finished_at must be
# at or before the ORIGINAL absolute deadline. Main-flow, window-check or
# cleanup overruns force TIMEOUT and can never PASS/OFFLINE, even though up to
# 5 seconds of emergency cleanup were tolerated while performing them.
$deadlineVerdict = Get-LocalSafetyDeadlineVerdict -FinishedAt $finishedAt -AbsoluteDeadlineAt $absoluteDeadlineAt -BaseTimeoutDetected ([bool]$timeoutDetected)
if ($deadlineVerdict.timeout_detected) {
    $timeoutDetected = $true
    $overrunText = if ($deadlineVerdict.deadline_respected) {
        'worker/supervisor timeout was detected'
    } else {
        ("finished_at {0} exceeded absolute_deadline_at {1}" -f $finishedAt.ToString('o'), $absoluteDeadlineAt.ToString('o'))
    }
    $failureReason = "DEADLINE VERDICT TIMEOUT: $overrunText"
}

$workerPassed = $false
$fixtures = [object[]]@()
if ($null -ne $workerSummary) {
    $workerPassed = [bool](Get-HarnessProperty $workerSummary 'offline_selftest_passed')
    $fixtures = ConvertTo-LocalObjectArray -Value (Get-HarnessProperty $workerSummary 'fixtures')
    $workerCleanupSuccess = Get-HarnessProperty $workerSummary 'cleanup_success'
    $workerOwnedRemainingFromSummary = Get-HarnessProperty $workerSummary 'owned_processes_remaining'
    if (-not $workerCleanupSuccess) {
        $failureReason = "worker cleanup failed (owned remaining: $workerOwnedRemainingFromSummary)"
        $workerPassed = $false
    }
    if ([int]$workerOwnedRemainingFromSummary -ne 0) {
        $failureReason = "worker reported owned processes remaining: $workerOwnedRemainingFromSummary"
        $workerPassed = $false
    }
    $workerTimeoutFlag = Get-HarnessProperty $workerSummary 'timeout_detected'
    if ($workerTimeoutFlag) {
        $timeoutDetected = $true
        $failureReason = "worker summary reported timeout_detected=true (real worker deadline anomaly)"
        $workerPassed = $false
    }
}

$cleanupSuccess = $false
$ownedRemaining = -1
if ($null -ne $cleanupMeasure) {
    $cleanupSuccess = [bool]$cleanupMeasure.cleanup_success
    $ownedRemaining = [int]$cleanupMeasure.owned_processes_remaining + [int]$workerOwnedRemaining
} else {
    $cleanupSuccess = $false
    $ownedRemaining = [int]$workerOwnedRemaining
}

$startGateConsumed = (Test-Path -LiteralPath $startGateConsumedPath)

$offlineSelftestPassed = (
    $workerPassed -and
    -not $timeoutDetected -and
    $deadlineVerdict.deadline_respected -and
    $cleanupSuccess -and
    $ownedRemaining -eq 0 -and
    ($visibleWindowsObservation -eq 'ok') -and
    -not $visibleWindowsCreated -and
    -not $failureReason -and
    $workerStartCount -eq 1 -and
    $startGateConsumed
)

$status = if ($timeoutDetected) { 'TIMEOUT' } elseif ($offlineSelftestPassed) { 'OFFLINE' } else { 'FAIL' }
if (-not $offlineSelftestPassed -and -not $failureReason) {
    $failureReason = 'offline self-test did not pass'
}

$acceptanceClaim = Resolve-HarnessAcceptanceClaim -LiveAttempted $false -Status $(if ($status -eq 'TIMEOUT') { 'FAIL' } else { $status }) -AcceptancePass $false
$finalStatus = $status
if ($status -eq 'TIMEOUT') { $finalStatus = 'TIMEOUT' }
elseif ($acceptanceClaim.status -eq 'OFFLINE') { $finalStatus = 'OFFLINE' }
else { $finalStatus = 'FAIL' }

# Terminal-state protocol (frozen):
#   1. build and validate the summary object (pure consistency check);
#   2. marker -> FINISHED with final_status still empty;
#   3. final-summary.json via FileMode.CreateNew;
#   4. marker -> FINISHED with the final final_status;
#   5. re-read marker and summary and verify run_id, status, final_status and
#      duration agree;
#   6. exit 0 only when EVERY step succeeded. Any marker update failure or
#      marker/summary mismatch means INCOMPLETE and a non-zero exit; a warning
#      alone never allows success.
$summaryWritten = $false
if ($markerCreated -and $workerStartCount -eq 1) {
    $summary = [pscustomobject][ordered]@{
        schema_version = 'local-package-safety-summary/v2'
        generated_by = 'run-local-package-regressions.ps1'
        run_id = $RunId
        supervisor = 'offline-safety-selftest'
        supervisor_pid = [int]$supervisorPid
        supervisor_creation_time = $supervisorCreationTimeUtc
        started_at = $startedAt.ToString('o')
        finished_at = $finishedAt.ToString('o')
        actual_duration_ms = [int]$actualDurationMs
        absolute_deadline_at = $absoluteDeadlineAt.ToString('o')
        deadline_respected = [bool]$deadlineVerdict.deadline_respected
        attempt_count = 1
        worker_start_count = [int]$workerStartCount
        start_gate_consumed = [bool]$startGateConsumed
        automatic_retries = 0
        worker_script = $WorkerScript
        worker_exit_code = $workerExitCode
        status = $acceptanceClaim.status
        final_status = $finalStatus
        acceptance_pass = [bool]$acceptanceClaim.acceptance_pass
        offline_selftest_passed = [bool]$offlineSelftestPassed
        live_scenario_attempted = $false
        outer_deadline_seconds = [int]$OuterDeadlineSeconds
        worker_deadline_seconds = [int]$WorkerDeadlineSeconds
        timeout_detected = [bool]$timeoutDetected
        failure_reason = $failureReason
        cleanup_success = [bool]$cleanupSuccess
        owned_processes_remaining = [int]$ownedRemaining
        supervisor_cleanup = $cleanupMeasure
        worker_owned_records_verified = [int]$ownedRecords.Count
        visible_console_windows_created = $(if ($visibleWindowsObservation -eq 'UNKNOWN') { $null } else { [bool]$visibleWindowsCreated })
        visible_console_windows_observation = $visibleWindowsObservation
        window_probe_error = $windowProbeError
        new_visible_console_window_pids = [int[]]$newConsoleWindows.ToArray()
        network_model_calls = 0
        cargo_commands_started = 0
        dotnet_build_commands_started = 0
        fixtures = [object[]]$fixtures
        worker_summary = $workerSummary
        evidence_root = $EvidenceRoot
        run_directory = $runDirectory
        emergency_cleanup_budget_ms = [int]$emergencyCleanupBudgetMs
        emergency_cleanup_used_ms = [int]$emergencyCleanupUsedMs
        supervisor_process_hard_deadline = 'UNPROVEN'
        start_gate_created = [bool]$startGateCreated
    }
    try {
        # Step 1: validate the summary object before touching the marker.
        $markerBefore = Read-LocalSafetyAttemptMarker -Path $markerPath
        Assert-LocalSafetyFinalSummaryConsistency -Summary $summary -Marker $markerBefore
        # Step 2: marker FINISHED, final_status still empty.
        $null = Update-LocalSafetyAttemptMarker -Path $markerPath -Status 'FINISHED'
        # Step 3: final-summary.json, CreateNew only (never overwrite/append).
        Write-LocalSafetyEvidenceJson -Path $finalSummaryPath -Object $summary
        # Step 4: marker FINISHED with the final final_status.
        $null = Update-LocalSafetyAttemptMarker -Path $markerPath -Status 'FINISHED' -FinalStatus $finalStatus
        # Step 5: re-read both artifacts and verify agreement.
        $markerAfter = Read-LocalSafetyAttemptMarker -Path $markerPath
        $summaryRead = $null
        try { $summaryRead = Get-Content -LiteralPath $finalSummaryPath -Raw | ConvertFrom-Json } catch { $summaryRead = $null }
        Assert-LocalSafetyMarkerSummaryAgreement -Summary $summaryRead -Marker $markerAfter
        # Step 6: every step succeeded.
        $summaryWritten = $true
    }
    catch {
        # Marker/summary inconsistency or any update failure: the attempt can
        # only be INCOMPLETE, never a silent success. Best-effort marker
        # repair, then a non-zero exit regardless.
        Write-Warning ("TERMINAL-STATE PROTOCOL FAILURE (INCOMPLETE): {0}" -f $_.Exception.Message)
        try {
            $null = Update-LocalSafetyAttemptMarker -Path $markerPath -Status 'FINISHED' -FinalStatus 'INCOMPLETE'
        } catch {
            Write-Warning ("attempt marker INCOMPLETE update failed: {0}" -f $_.Exception.Message)
        }
    }
} elseif ($markerCreated) {
    # The worker was not started exactly once: no summary may be forged.
    try {
        $null = Update-LocalSafetyAttemptMarker -Path $markerPath -Status 'FINISHED' -FinalStatus 'INCOMPLETE'
    } catch {
        Write-Warning ("attempt marker INCOMPLETE update failed: {0}" -f $_.Exception.Message)
    }
}

if (-not $summaryWritten) {
    Write-Warning ("OFFLINE SAFETY SELF-TEST INCOMPLETE (no verified final-summary.json): {0}" -f $(if ($failureReason) { $failureReason } else { 'worker was not started exactly once' }))
    exit 1
}

if (-not $offlineSelftestPassed) {
    Write-Warning ("OFFLINE SAFETY SELF-TEST FAILED (final_status=$finalStatus): {0}" -f $failureReason)
    exit 1
}
Write-Output ("OFFLINE SAFETY SELF-TEST PASSED (status=OFFLINE, acceptance_pass=false): {0}" -f $RunId)
exit 0
