# Daily-use Local Package v0.1 R3 Safety Repair 2 - OFFLINE SAFETY WORKER.
#
# Default-refuses direct execution. Required supervision parameters must be
# supplied by run-local-package-regressions.ps1. The start gate is consumed
# before TEMP, Job Object, logs, or child processes are created.
#
# All side effects sit inside a top-level try/catch/finally. Cleanup failure
# forces FAIL. Job Object close is explicit and does not rely on process-exit
# handle teardown.

#Requires -Version 5.1
[CmdletBinding()]
param(
    # No prompt-triggering required bindings: a missing supervision parameter must fail
    # loudly and non-interactively, never trigger an interactive prompt.
    [switch]$Supervised,
    [string]$RunId = '',
    [int]$SupervisorPid = 0,
    [string]$SupervisorCreationTimeUtc = '',
    [string]$AttemptMarkerPath = '',
    [string]$StartGatePath = '',
    [string]$StartGateToken = '',
    [string]$EvidenceRoot = '',
    [ValidateRange(5, 300)][int]$OverallDeadlineSeconds = 90,
    [string]$RunDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# FIRST check of the script body: non-interactive refusal of direct execution.
# This runs before TEMP, Job Object, logs, evidence files or any child process
# can be created; the refusal path creates nothing.
if (-not $Supervised) {
    [Console]::Error.WriteLine('REFUSING TO START: worker must be launched by the supervisor with -Supervised; direct execution is forbidden')
    exit 1
}

# Explicit per-parameter supervision checks (each missing item is reported by
# name; still no side effects on this refusal path).
$missingSupervisionParams = New-Object System.Collections.Generic.List[string]
if ([string]::IsNullOrWhiteSpace($RunId)) { [void]$missingSupervisionParams.Add('-RunId') }
if ($SupervisorPid -le 0) { [void]$missingSupervisionParams.Add('-SupervisorPid') }
if ([string]::IsNullOrWhiteSpace($SupervisorCreationTimeUtc)) { [void]$missingSupervisionParams.Add('-SupervisorCreationTimeUtc') }
if ([string]::IsNullOrWhiteSpace($AttemptMarkerPath)) { [void]$missingSupervisionParams.Add('-AttemptMarkerPath') }
if ([string]::IsNullOrWhiteSpace($StartGatePath)) { [void]$missingSupervisionParams.Add('-StartGatePath') }
if ([string]::IsNullOrWhiteSpace($StartGateToken)) { [void]$missingSupervisionParams.Add('-StartGateToken') }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { [void]$missingSupervisionParams.Add('-EvidenceRoot') }
if ($missingSupervisionParams.Count -gt 0) {
    [Console]::Error.WriteLine(("REFUSING TO START: missing required supervision parameter(s): {0}" -f ($missingSupervisionParams -join ', ')))
    exit 1
}

$workerStartedAt = [DateTimeOffset]::UtcNow
$workerDeadline = $workerStartedAt.AddSeconds($OverallDeadlineSeconds)
$script:DeadlineAnomalyDetected = $false

. (Join-Path $PSScriptRoot 'local-package-harness.ps1')

$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$utf8 = New-Object System.Text.UTF8Encoding $false
$fixtures = New-Object System.Collections.Generic.List[object]
$global:FixturesStopped = $false
$script:StreamStdoutTruncated = $false
$script:StreamStderrTruncated = $false
$script:StreamStdoutPersistedLogBytes = [int64]0
$script:StreamStderrPersistedLogBytes = [int64]0
$script:StreamStdoutLogTruncated = $false
$script:StreamStderrLogTruncated = $false

$preflight = $null
try {
    $preflight = Invoke-LocalSafetyWorkerPreflight -BoundParameters $PSBoundParameters `
        -Supervised:([bool]$Supervised) -RunId $RunId -SupervisorPid $SupervisorPid `
        -SupervisorCreationTimeUtc $SupervisorCreationTimeUtc `
        -AttemptMarkerPath $AttemptMarkerPath -StartGatePath $StartGatePath `
        -StartGateToken $StartGateToken -EvidenceRoot $EvidenceRoot `
        -Deadline $workerDeadline -RunDirectory $RunDirectory
} catch {
    Write-Warning $_.Exception.Message
    exit 2
}

$runDirectory = [string]$preflight.run_directory
$ownedRecordsPath = Join-Path $runDirectory 'owned-processes.jsonl'
$tempRoot = $null
$context = $null
$anyFailed = $false
$stoppedAt = ''
$failureDetail = ''
$cleanupMeasure = $null
$cleanupSuccess = $false
$ownedRemaining = -1
$cleanupFailureText = $null

function Write-LocalWorkerJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [System.IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 12), $utf8)
}

function Add-LocalFixtureRecord {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$DeadlineSeconds,
        [Parameter(Mandatory)][bool]$Pass,
        [int]$DurationMs,
        [string]$Detail = '',
        [bool]$TimeoutDetected = $false
    )
    $record = [pscustomobject][ordered]@{
        fixture = $Name
        deadline_seconds = [int]$DeadlineSeconds
        pass = [bool]$Pass
        duration_ms = [int]$DurationMs
        timeout_detected = [bool]$TimeoutDetected
        detail = $Detail
    }
    [void]$fixtures.Add($record)
}

# ---------------------------------------------------------------------------
# owned-processes.jsonl: single-writer, create-once, append-only protocol.
# The file is opened ONCE with FileMode.CreateNew (never Append, never a
# re-open/overwrite). Every newly observed PID + creation time is appended to
# the already-open stream, flushed (and flushed to disk) per record, and
# deduplicated via an identity HashSet. The writer is closed in the worker's
# finally path; already-flushed records survive a worker crash.
# ---------------------------------------------------------------------------
$script:OwnedRecordsStream = $null
$script:OwnedRecordsWriter = $null
$script:OwnedRecordsSeen = New-Object 'System.Collections.Generic.HashSet[string]'

function Initialize-LocalOwnedRecordsWriter {
    if ($null -ne $script:OwnedRecordsWriter) { return }
    $stream = $null
    try {
        # CreateNew only: an existing owned-processes.jsonl refuses the run
        # before TEMP, Job Object, logs or children are created.
        $stream = [System.IO.File]::Open($ownedRecordsPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    } catch [System.IO.IOException] {
        if ($null -ne $stream) { $stream.Dispose() }
        throw "REFUSING TO START: owned-processes.jsonl already exists at $ownedRecordsPath (single writer, create-once; will not append to or overwrite existing content)"
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
    $script:OwnedRecordsStream = $stream
    $script:OwnedRecordsWriter = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding $false))
}

function Add-LocalOwnedRecordsFromContext {
    param([Parameter(Mandatory)]$Context)
    if ($null -eq $script:OwnedRecordsWriter) { return }
    foreach ($record in @($Context.OwnedProcesses)) {
        $key = ("{0}:{1}" -f [int]$record.ProcessId, [int64]$record.ProcessStartedAtUnixMs)
        if ($script:OwnedRecordsSeen.Contains($key)) { continue }
        [void]$script:OwnedRecordsSeen.Add($key)
        $obj = [ordered]@{
            process_id = [int]$record.ProcessId
            process_started_at_unix_ms = [int64]$record.ProcessStartedAtUnixMs
            kind = [string]$record.Kind
        }
        $script:OwnedRecordsWriter.WriteLine(($obj | ConvertTo-Json -Compress))
        $script:OwnedRecordsWriter.Flush()
        $script:OwnedRecordsStream.Flush($true)
    }
}

function Close-LocalOwnedRecordsWriter {
    if ($null -ne $script:OwnedRecordsWriter) {
        try { $script:OwnedRecordsWriter.Dispose() } catch { }
        $script:OwnedRecordsWriter = $null
    }
    if ($null -ne $script:OwnedRecordsStream) {
        try { $script:OwnedRecordsStream.Dispose() } catch { }
        $script:OwnedRecordsStream = $null
    }
}

function Remove-LocalWorkerDisposableTree {
    param([Parameter(Mandatory)][string]$Path)
    $tempAllowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $null = Remove-LocalPackageDirectorySafely -Path $Path -AllowedRoots @($tempAllowed) -RepoRoot $script:RepoRoot
}

# ---------------------------------------------------------------------------
# Fixture 1: watcher that never exits is terminated by its lifecycle owner
# ---------------------------------------------------------------------------
function Invoke-FixtureWatcherNeverExits {
    $deadlineSeconds = 10
    $fixtureStart = [DateTimeOffset]::UtcNow
    $watcher = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'while ($true) { Start-Sleep -Seconds 1 }') `
        -Kind 'synthetic-watcher' -WorkingDirectory $tempRoot -HideConsoleWindow
    Add-LocalOwnedRecordsFromContext -Context $context
    Start-Sleep -Milliseconds 300
    if (-not (Test-HarnessProcessRecordAlive -Record $watcher.Record)) {
        Add-LocalFixtureRecord -Name 'watcher-never-exits' -DeadlineSeconds $deadlineSeconds -Pass $false -DurationMs 0 -Detail 'watcher exited on its own; fixture invalid'
        return $false
    }
    $closed = Stop-HarnessProcessRecord -Record $watcher.Record -Reason 'owner-stop-watch'
    Add-LocalOwnedRecordsFromContext -Context $context
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    Add-LocalFixtureRecord -Name 'watcher-never-exits' -DeadlineSeconds $deadlineSeconds -Pass ([bool]$closed) `
        -DurationMs $duration -Detail ("watcher_pid=$($watcher.Record.ProcessId) terminated_by_owner=$closed")
    return $closed
}

# ---------------------------------------------------------------------------
# Fixture 2: RESULT_READY wait receives INTERRUPTED -> fail fast within 2s
# ---------------------------------------------------------------------------
function Invoke-FixtureResultReadyInterrupted {
    $deadlineSeconds = 5
    $fixtureStart = [DateTimeOffset]::UtcNow
    $statePath = Join-Path $tempRoot 'fixture2-state.txt'
    [IO.File]::WriteAllText($statePath, 'WORKING', $utf8)
    $observerChild = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "Start-Sleep -Milliseconds 500; Set-Content -LiteralPath '$statePath' -Value 'INTERRUPTED'; Start-Sleep -Seconds 60") `
        -Kind 'synthetic-observer' -WorkingDirectory $tempRoot -HideConsoleWindow
    Add-LocalOwnedRecordsFromContext -Context $context
    $outcome = $null
    try {
        Wait-LocalResultReady -Context $context -StatePath $statePath -Stage 'fixture-result-ready' `
            -TimeoutSeconds 2 -Record $observerChild.Record
        $outcome = 'unexpected-RESULT_READY'
    } catch {
        $outcome = [string]$_.Exception.Message
    }
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    $failFast = ($outcome -like '*terminal state INTERRUPTED*')
    Add-LocalFixtureRecord -Name 'result-ready-interrupted' -DeadlineSeconds $deadlineSeconds -Pass $failFast `
        -DurationMs $duration -Detail "outcome=$outcome fail_fast_ms=$duration"
    return $failFast
}

# ---------------------------------------------------------------------------
# Fixture 3+4: stuck children terminated by deadline + Job Object
# ---------------------------------------------------------------------------
function Invoke-FixtureStuckChildren {
    $deadlineSeconds = 15
    $fixtureStart = [DateTimeOffset]::UtcNow
    $loopChild = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', '$null = 1; for (;;) { }') `
        -Kind 'synthetic-infinite-loop' -WorkingDirectory $tempRoot -HideConsoleWindow
    $noHeartChild = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Get-CimInstance -ClassName Win32_Process | Out-Null; Start-Sleep -Seconds 120') `
        -Kind 'synthetic-no-heartbeat' -WorkingDirectory $tempRoot -HideConsoleWindow
    Add-LocalOwnedRecordsFromContext -Context $context
    Start-Sleep -Milliseconds 300

    Assert-HarnessDeadline -Context $context -Stage 'stuck-children-local'
    $remain = Get-HarnessRemainingSeconds -Context $context
    $localTimeout = [int][math]::Min(3, [math]::Max(1, $remain))
    $localLifecycle = New-HarnessLifecycle -Name 'stuck-children-local' -RunRoot $tempRoot `
        -Scenario 'offline-safety-worker' -OverallTimeoutSeconds $localTimeout -HeartbeatSeconds 1
    try {
        $adopted = [pscustomobject]@{
            ProcessId = [int]$loopChild.Record.ProcessId
            ProcessStartedAtUnixMs = [int64]$loopChild.Record.ProcessStartedAtUnixMs
            Kind = 'synthetic-infinite-loop'
            Scenario = 'offline-safety-worker'
            BindingRoot = ''
            Process = $null
            Launcher = $null
            RegisteredAt = [DateTimeOffset]::UtcNow
            JobAssigned = $false
        }
        [void]$localLifecycle.OwnedProcesses.Add($adopted)
        $terminatedByDeadline = $false
        try {
            $null = Wait-HarnessProcess -Context $localLifecycle -Record $adopted -Stage 'infinite-loop-child' -TimeoutSeconds 2
        } catch {
            $message = [string]$_.Exception.Message
            if ($message -like '*deadline exceeded*' -or $message -like '*Timed out*') { $terminatedByDeadline = $true }
        }
        $loopGone = -not (Test-HarnessProcessRecordAlive -Record $loopChild.Record)
    }
    finally {
        if ($localLifecycle.Job) { $localLifecycle.Job.Dispose(); $localLifecycle.Job = $null }
    }
    $noHeartAlive = Test-HarnessProcessRecordAlive -Record $noHeartChild.Record
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    $pass = ($terminatedByDeadline -and $loopGone -and $noHeartAlive)
    Add-LocalFixtureRecord -Name 'stuck-children-terminated' -DeadlineSeconds $deadlineSeconds -Pass $pass `
        -DurationMs $duration -Detail "loop_child=$($loopChild.Record.ProcessId) deadline_kill=$terminatedByDeadline gone=$loopGone no_heartbeat_child_alive=$noHeartAlive"
    return $pass
}

# ---------------------------------------------------------------------------
# Fixture 5: simultaneous stdout + stderr pressure
# ---------------------------------------------------------------------------
function Invoke-FixtureStreamPressure {
    $deadlineSeconds = 10
    $fixtureStart = [DateTimeOffset]::UtcNow
    $payload = ('x' * 64)
    $command = ''
    $command += "for (`$i = 0; `$i -lt 6144; `$i++) { "
    $command += "[Console]::Out.WriteLine('$payload'); [Console]::Error.WriteLine('$payload') } ; exit 0"
    $stdoutLog = Join-Path $runDirectory 'fixture-stream-stdout.log'
    $stderrLog = Join-Path $runDirectory 'fixture-stream-stderr.log'
    $maxLogBytes = 524288
    $run = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $command) `
        -Kind 'stream-pressure' -WorkingDirectory $tempRoot -HideConsoleWindow `
        -StdoutLogPath $stdoutLog -StderrLogPath $stderrLog `
        -MaxCaptureBytes 262144 -MaxLogBytes $maxLogBytes
    Add-LocalOwnedRecordsFromContext -Context $context
    $exit = Wait-HarnessProcess -Context $context -Record $run.Record -Stage 'stream-pressure' -TimeoutSeconds 9
    $drainMs = Get-HarnessClippedTimeoutMilliseconds -Context $context -RequestedMilliseconds 8000 -Stage 'stream-pressure-drains'
    $drainsDone = $run.Launcher.WaitDrains($drainMs)
    $stdoutTruncated = [bool]$run.Launcher.StdoutCaptureTruncated
    $stderrTruncated = [bool]$run.Launcher.StderrCaptureTruncated
    $stdoutBytes = [int64]$run.Launcher.StdoutTotalBytes
    $stderrBytes = [int64]$run.Launcher.StderrTotalBytes
    $stdoutPersisted = [int64]$run.Launcher.StdoutPersistedLogBytes
    $stderrPersisted = [int64]$run.Launcher.StderrPersistedLogBytes
    $stdoutLogTrunc = [bool]$run.Launcher.StdoutLogTruncated
    $stderrLogTrunc = [bool]$run.Launcher.StderrLogTruncated
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    $pass = ($exit -eq 0 -and $drainsDone -and $stdoutBytes -gt 300000 -and $stderrBytes -gt 300000 `
        -and $stdoutTruncated -and $stderrTruncated -and $duration -lt 10000 `
        -and $stdoutPersisted -le $maxLogBytes -and $stderrPersisted -le $maxLogBytes)
    Add-LocalFixtureRecord -Name 'stream-pressure' -DeadlineSeconds $deadlineSeconds -Pass $pass `
        -DurationMs $duration -TimeoutDetected ($exit -ne 0) `
        -Detail ("exit=$exit drains_done=$drainsDone stdout_bytes=$stdoutBytes stderr_bytes=$stderrBytes stdout_truncated=$stdoutTruncated stderr_truncated=$stderrTruncated persisted_stdout=$stdoutPersisted persisted_stderr=$stderrPersisted log_truncated_stdout=$stdoutLogTrunc log_truncated_stderr=$stderrLogTrunc")
    $script:StreamStdoutTruncated = $stdoutTruncated
    $script:StreamStderrTruncated = $stderrTruncated
    $script:StreamStdoutPersistedLogBytes = $stdoutPersisted
    $script:StreamStderrPersistedLogBytes = $stderrPersisted
    $script:StreamStdoutLogTruncated = $stdoutLogTrunc
    $script:StreamStderrLogTruncated = $stderrLogTrunc
    return $pass
}

# ---------------------------------------------------------------------------
# Fixture 6: parent exits after spawning a grandchild. Prove Job inheritance
# by closing ONLY this fixture's Job Object (no Stop-Process, no
# Stop-HarnessProcessRecord on the grandchild).
# ---------------------------------------------------------------------------
function Invoke-FixtureParentExitsAfterChildren {
    $deadlineSeconds = 15
    $fixtureStart = [DateTimeOffset]::UtcNow
    $grandChildIdentity = Join-Path $tempRoot 'fixture6-grandchild.json'
    $childScript = Join-Path $tempRoot 'fixture6-child.ps1'
    $childSource = @'
$ErrorActionPreference = 'Stop'
$g = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60' -PassThru -WindowStyle Hidden
@{
    process_id = [int]$g.Id
    process_started_at_unix_ms = [int64]([DateTimeOffset]($g.StartTime).ToUniversalTime()).ToUnixTimeMilliseconds()
} | ConvertTo-Json -Compress | Set-Content -LiteralPath '__IDENTITY__' -Encoding utf8
exit 0
'@
    $childSource = $childSource.Replace('__IDENTITY__', $grandChildIdentity.Replace("'", "''"))
    [IO.File]::WriteAllText($childScript, $childSource, $utf8)

    Assert-HarnessDeadline -Context $context -Stage 'parent-exits-job'
    $remain = Get-HarnessRemainingSeconds -Context $context
    $localTimeout = [int][math]::Min(12, [math]::Max(2, $remain))
    $localLifecycle = New-HarnessLifecycle -Name 'parent-exits-job' -RunRoot $tempRoot `
        -Scenario 'offline-safety-worker' -OverallTimeoutSeconds $localTimeout -HeartbeatSeconds 1
    $parentExit = -1
    $grandchild = $null
    $grandchildAliveAfterParentExit = $false
    $parentAliveAfterExit = $true
    $grandchildRemovedByJobClose = $false
    $jobClosedWithoutDirectKill = $false
    try {
        $parent = Start-LocalHarnessProcess -Context $localLifecycle -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childScript) `
            -Kind 'parent-exits-fast' -WorkingDirectory $tempRoot -HideConsoleWindow
        # The parent lives on the fixture-local lifecycle: append its exact
        # PID + creation time to the single owned-processes writer.
        Add-LocalOwnedRecordsFromContext -Context $localLifecycle
        $parentExit = Wait-HarnessProcess -Context $localLifecycle -Record $parent.Record -Stage 'fixture6-parent' -TimeoutSeconds 10
        $parentAliveAfterExit = Test-HarnessProcessRecordAlive -Record $parent.Record

        $searchDeadline = [DateTimeOffset]::UtcNow.AddSeconds(3)
        $remainSearch = Get-HarnessRemainingMilliseconds -Context $context
        if ($remainSearch -lt 3000) {
            $searchDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds([math]::Max(1, $remainSearch))
        }
        while ([DateTimeOffset]::UtcNow -lt $searchDeadline -and -not (Test-Path -LiteralPath $grandChildIdentity)) {
            $now = [DateTimeOffset]::UtcNow
            $slice = [math]::Min(100, ($searchDeadline - $now).TotalMilliseconds)
            if ($slice -le 0) { break }
            Start-Sleep -Milliseconds ([int][math]::Max(1, $slice))
        }
        if (Test-Path -LiteralPath $grandChildIdentity) {
            $identity = Get-Content -LiteralPath $grandChildIdentity -Raw | ConvertFrom-Json
            $grandchild = [pscustomobject]@{
                ProcessId = [int]$identity.process_id
                ProcessStartedAtUnixMs = [int64]$identity.process_started_at_unix_ms
                Kind = 'fixture6-grandchild'
                Scenario = 'offline-safety-worker'
                Launcher = $null
                Process = $null
            }
        }
        if ($grandchild) {
            $grandchildAliveAfterParentExit = Test-HarnessProcessRecordAlive -Record $grandchild
        }

        # Close ONLY this fixture Job Object. Do not Stop-Process the grandchild
        # and do not call Stop-HarnessProcessRecord on it.
        if ($localLifecycle.Job) {
            $localLifecycle.Job.Dispose()
            $localLifecycle.Job = $null
            $jobClosedWithoutDirectKill = $true
        }
        $goneDeadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        $remainGone = Get-HarnessRemainingMilliseconds -Context $context
        if ($remainGone -lt 5000) {
            $goneDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds([math]::Max(1, $remainGone))
        }
        if ($grandchild -and $grandchildAliveAfterParentExit) {
            while ((Test-HarnessProcessRecordAlive -Record $grandchild) -and [DateTimeOffset]::UtcNow -lt $goneDeadline) {
                $now = [DateTimeOffset]::UtcNow
                $slice = [math]::Min(50, ($goneDeadline - $now).TotalMilliseconds)
                if ($slice -le 0) { break }
                Start-Sleep -Milliseconds ([int][math]::Max(1, $slice))
            }
            $grandchildRemovedByJobClose = -not (Test-HarnessProcessRecordAlive -Record $grandchild)
        }
    }
    finally {
        if ($localLifecycle.Job) {
            $localLifecycle.Job.Dispose()
            $localLifecycle.Job = $null
        }
        try { $localLifecycle.Closed = $true } catch { }
    }

    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    $pass = ($parentExit -eq 0 -and -not $parentAliveAfterExit -and $grandchildAliveAfterParentExit `
        -and $jobClosedWithoutDirectKill -and $grandchildRemovedByJobClose)
    Add-LocalFixtureRecord -Name 'parent-exits-after-children' -DeadlineSeconds $deadlineSeconds -Pass $pass `
        -DurationMs $duration -Detail ("parent_exit=$parentExit parent_alive=$parentAliveAfterExit grandchild_alive_after_parent_exit=$grandchildAliveAfterParentExit job_close_only=$jobClosedWithoutDirectKill grandchild_gone_after_job_close=$grandchildRemovedByJobClose")
    return $pass
}

# ---------------------------------------------------------------------------
# Fixture 7: build success + cleanup failure -> non-zero final verdict
# ---------------------------------------------------------------------------
function Invoke-FixtureBuildCleanupFailure {
    $deadlineSeconds = 15
    $fixtureStart = [DateTimeOffset]::UtcNow
    $regression = Join-Path $PSScriptRoot 'test-cleanup-exit-regression.ps1'
    $run = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $regression) `
        -Kind 'build-cleanup-exit-regression' -WorkingDirectory $script:RepoRoot -HideConsoleWindow
    Add-LocalOwnedRecordsFromContext -Context $context
    $exit = Wait-HarnessProcess -Context $context -Record $run.Record -Stage 'build-cleanup-exit-regression' -TimeoutSeconds 12
    $inProcess = Get-LocalBuildFinalVerdict -BuildStepsSucceeded $true -PromotionSucceeded $true -CleanupSucceeded $false -OwnedProcessesRemaining 0
    $pass = (($exit -ne 0) -and (-not $inProcess.success) -and ($inProcess.exit_code -ne 0) -and ($inProcess.failures -contains 'cleanup failed'))
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    Add-LocalFixtureRecord -Name 'build-cleanup-failure-nonzero' -DeadlineSeconds $deadlineSeconds -Pass $pass `
        -DurationMs $duration -Detail "process_exit=$exit verdict_exit=$($inProcess.exit_code) failures=$($inProcess.failures -join ',')"
    return $pass
}

# ---------------------------------------------------------------------------
# Fixture 8: exclusive TEMP file lock -> immediate FAIL within 5s
# ---------------------------------------------------------------------------
function Invoke-FixtureFileLock {
    $deadlineSeconds = 5
    $fixtureStart = [DateTimeOffset]::UtcNow
    $lockPath = Join-Path $tempRoot 'fixture8-locked.bin'
    [IO.File]::WriteAllBytes($lockPath, (New-Object byte[] 16))
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $writable = Test-LocalPackageTargetWritable -TargetPaths @($lockPath)
        $elapsed = [DateTimeOffset]::UtcNow - $fixtureStart
        $pass = ((-not $writable.writable) -and ($elapsed.TotalSeconds -lt 5) -and ($writable.reason -match 'locked or access denied'))
    } finally {
        $lockStream.Dispose()
    }
    $writableAfter = Test-LocalPackageTargetWritable -TargetPaths @($lockPath)
    $pass = ($pass -and $writableAfter.writable)
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    Add-LocalFixtureRecord -Name 'file-lock-immediate-fail' -DeadlineSeconds $deadlineSeconds -Pass $pass `
        -DurationMs $duration -Detail ("locked_rejected_ms=$duration reason=$($writable.reason) writable_after_release=$($writableAfter.writable)")
    return $pass
}

# ---------------------------------------------------------------------------
# Fixture 9: unsafe recursive paths rejected, original files untouched
# ---------------------------------------------------------------------------
function Invoke-FixtureUnsafePaths {
    $deadlineSeconds = 5
    $fixtureStart = [DateTimeOffset]::UtcNow
    $allowedRoot = Join-Path $tempRoot 'fixture9-allowed'
    $nested = Join-Path $allowedRoot 'nested'
    [IO.Directory]::CreateDirectory($nested) | Out-Null
    $sentinel = Join-Path $nested 'sentinel.txt'
    $content = 'fixture9-sentinel-' + [Guid]::NewGuid().ToString('n')
    [IO.File]::WriteAllText($sentinel, $content, $utf8)
    $repoRoot = $script:RepoRoot

    $dangerous = @(
        [pscustomobject]@{ path = $repoRoot; label = 'repo-root' },
        [pscustomobject]@{ path = 'C:\'; label = 'drive-root' },
        [pscustomobject]@{ path = 'C:\Windows\System32'; label = 'outside-allowed' },
        [pscustomobject]@{ path = (Join-Path $allowedRoot '..\..\..\..'); label = 'escape' },
        [pscustomobject]@{ path = ''; label = 'empty' },
        [pscustomobject]@{ path = $allowedRoot; label = 'allowed-root-itself' }
    )
    $rejectedAll = $true
    $rejections = @()
    foreach ($case in $dangerous) {
        try {
            $canonical = Assert-LocalPackageSafePath -Path ([string]$case.path) -AllowedRoots @($allowedRoot) -RepoRoot $repoRoot
            $rejectedAll = $false
            $rejections += ("{0}=ACCEPTED({1})" -f $case.label, $canonical)
        } catch {
            $rejections += ("{0}=REJECTED" -f $case.label)
        }
    }
    $tripleRejected = $false
    try {
        $null = Assert-LocalPackageSafeOperationRoots -StagingPath $nested -PackageRoot $nested -BackupRoot $allowedRoot -AllowedRoots @($allowedRoot)
    } catch {
        $tripleRejected = $true
    }
    $tripleRejected2 = $false
    try {
        $null = Assert-LocalPackageSafeOperationRoots -StagingPath $allowedRoot -PackageRoot $nested -BackupRoot (Join-Path $allowedRoot 'backup') -AllowedRoots @($allowedRoot)
    } catch {
        $tripleRejected2 = $true
    }
    $sentinelUntouched = ((Test-Path -LiteralPath $sentinel) -and (([string]([IO.File]::ReadAllText($sentinel))) -eq $content))
    $safeDeleted = $false
    try {
        $null = Remove-LocalPackageDirectorySafely -Path $nested -AllowedRoots @($allowedRoot) -RepoRoot $repoRoot
        $safeDeleted = -not (Test-Path -LiteralPath $sentinel)
    } catch { }

    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    $pass = ($rejectedAll -and $tripleRejected -and $tripleRejected2 -and $sentinelUntouched -and $safeDeleted)
    Add-LocalFixtureRecord -Name 'unsafe-paths-rejected' -DeadlineSeconds $deadlineSeconds -Pass $pass `
        -DurationMs $duration -Detail ("rejections=$($rejections -join ';') triple_equal_rejected=$tripleRejected triple_container_rejected=$tripleRejected2 sentinel_untouched=$sentinelUntouched safe_delete_worked=$safeDeleted")
    return $pass
}

# ---------------------------------------------------------------------------
# Fixture 13: OFFLINE result can never claim acceptance_pass=true
# ---------------------------------------------------------------------------
function Invoke-FixtureOfflineNotAcceptance {
    $deadlineSeconds = 5
    $fixtureStart = [DateTimeOffset]::UtcNow
    $claim = Resolve-HarnessAcceptanceClaim -LiveAttempted $false -Status 'OFFLINE' -AcceptancePass $true
    $claim2 = Resolve-HarnessAcceptanceClaim -LiveAttempted $false -Status 'PASS' -AcceptancePass $true
    $pass = ($claim.status -eq 'OFFLINE' -and (-not $claim.acceptance_pass) `
        -and $claim2.status -eq 'OFFLINE' -and (-not $claim2.acceptance_pass))
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    Add-LocalFixtureRecord -Name 'offline-not-acceptance-pass' -DeadlineSeconds $deadlineSeconds -Pass $pass `
        -DurationMs $duration -Detail ("forced_pass_claim=$($claim.status)/$($claim.acceptance_pass) pass_claim=$($claim2.status)/$($claim2.acceptance_pass)")
    return $pass
}

function Test-LocalMiniWorkerSummaryExists {
    param([Parameter(Mandatory)][string]$MiniRoot)
    if (Test-Path -LiteralPath (Join-Path $MiniRoot 'worker-summary.json')) { return $true }
    $markerFile = Join-Path $MiniRoot 'attempt.json'
    if (Test-Path -LiteralPath $markerFile) {
        try {
            $marker = Get-Content -LiteralPath $markerFile -Raw | ConvertFrom-Json
            $nested = Join-Path $MiniRoot ([string]$marker.run_id)
            if (Test-Path -LiteralPath (Join-Path $nested 'worker-summary.json')) { return $true }
        } catch { }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Fixtures 3/4 (supervisor authority)
# ---------------------------------------------------------------------------
function Invoke-FixtureSupervisorCutsWorker {
    param(
        [Parameter(Mandatory)][string]$FixtureWorkerName,
        [Parameter(Mandatory)][int]$SupervisorDeadlineSeconds,
        [Parameter(Mandatory)][int]$FixtureDeadlineSeconds
    )
    $fixtureStart = [DateTimeOffset]::UtcNow
    $miniRoot = Join-Path ([IO.Path]::GetTempPath()) ("r3r1-mini-supervisor-" + [Guid]::NewGuid().ToString('n'))
    [IO.Directory]::CreateDirectory($miniRoot) | Out-Null
    $runnerScript = Join-Path $PSScriptRoot 'run-local-package-regressions.ps1'
    $fixtureWorker = Join-Path $PSScriptRoot ("fixtures\$FixtureWorkerName")
    $miniRun = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runnerScript, `
            '-EvidenceRoot', $miniRoot, '-WorkerScript', $fixtureWorker, `
            '-OuterDeadlineSeconds', [string]$SupervisorDeadlineSeconds, `
            '-WorkerDeadlineSeconds', [string]([int][Math]::Max(5, $SupervisorDeadlineSeconds - 2)), `
            '-RunId', ('mini-' + $FixtureWorkerName)) `
        -Kind ("mini-supervisor-" + $FixtureWorkerName) -WorkingDirectory $script:RepoRoot -HideConsoleWindow `
        -StdoutLogPath (Join-Path $runDirectory "mini-$FixtureWorkerName-stdout.log") `
        -StderrLogPath (Join-Path $runDirectory "mini-$FixtureWorkerName-stderr.log")
    Add-LocalOwnedRecordsFromContext -Context $context
    $miniExit = Wait-HarnessProcess -Context $context -Record $miniRun.Record -Stage ("mini-supervisor-" + $FixtureWorkerName) -TimeoutSeconds ($FixtureDeadlineSeconds - 2)
    $miniSummary = $null
    $miniSummaryPath = Join-Path $miniRoot 'final-summary.json'
    if (Test-Path -LiteralPath $miniSummaryPath) {
        try { $miniSummary = Get-Content -LiteralPath $miniSummaryPath -Raw | ConvertFrom-Json } catch { $miniSummary = $null }
    }
    $attempt = $null
    if (Test-Path -LiteralPath (Join-Path $miniRoot 'attempt.json')) {
        try { $attempt = Get-Content -LiteralPath (Join-Path $miniRoot 'attempt.json') -Raw | ConvertFrom-Json } catch { $attempt = $null }
    }
    $stuckWorkerWroteSummary = Test-LocalMiniWorkerSummaryExists -MiniRoot $miniRoot
    $pass = $false
    $detail = ''
    if ($null -ne $miniSummary -and $null -ne $attempt) {
        $pass = ($miniExit -ne 0 `
            -and [string]$miniSummary.status -eq 'FAIL' `
            -and [bool]$miniSummary.timeout_detected `
            -and [int]$miniSummary.owned_processes_remaining -eq 0 `
            -and [bool]$miniSummary.cleanup_success `
            -and [int]$attempt.attempt_number -eq 1 `
            -and -not $stuckWorkerWroteSummary)
        $detail = "mini_exit=$miniExit status=$($miniSummary.status) timeout=$($miniSummary.timeout_detected) residual=$($miniSummary.owned_processes_remaining) cleanup=$($miniSummary.cleanup_success) attempt=$($attempt.attempt_number) stuck_worker_summary=$stuckWorkerWroteSummary"
    }
    else {
        $detail = "mini_exit=$miniExit missing summary/attempt"
    }
    try { Remove-LocalWorkerDisposableTree -Path $miniRoot } catch { }
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    Add-LocalFixtureRecord -Name ("supervisor-cuts-" + $FixtureWorkerName) -DeadlineSeconds $FixtureDeadlineSeconds -Pass $pass `
        -DurationMs $duration -TimeoutDetected ($null -ne $miniSummary -and [bool]$miniSummary.timeout_detected) -Detail $detail
    return $pass
}

# ---------------------------------------------------------------------------
# Fixture 12: a failing fixture stops all subsequent fixtures
# ---------------------------------------------------------------------------
function Invoke-FixtureSingleFailureStops {
    $fixtureStart = [DateTimeOffset]::UtcNow
    $miniRoot = Join-Path ([IO.Path]::GetTempPath()) ("r3r1-mini-failfirst-" + [Guid]::NewGuid().ToString('n'))
    [IO.Directory]::CreateDirectory($miniRoot) | Out-Null
    $runnerScript = Join-Path $PSScriptRoot 'run-local-package-regressions.ps1'
    $fixtureWorker = Join-Path $PSScriptRoot 'fixtures\local-safety-fixture-fail-first.ps1'
    $miniRun = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runnerScript, `
            '-EvidenceRoot', $miniRoot, '-WorkerScript', $fixtureWorker, `
            '-OuterDeadlineSeconds', '20', '-WorkerDeadlineSeconds', '15', '-RunId', 'mini-fail-first') `
        -Kind 'mini-supervisor-fail-first' -WorkingDirectory $script:RepoRoot -HideConsoleWindow
    Add-LocalOwnedRecordsFromContext -Context $context
    $miniExit = Wait-HarnessProcess -Context $context -Record $miniRun.Record -Stage 'mini-fail-first' -TimeoutSeconds 18
    $miniSummary = $null
    if (Test-Path -LiteralPath (Join-Path $miniRoot 'final-summary.json')) {
        try { $miniSummary = Get-Content -LiteralPath (Join-Path $miniRoot 'final-summary.json') -Raw | ConvertFrom-Json } catch { $miniSummary = $null }
    }
    $canaryExists = (Test-Path -LiteralPath (Join-Path $miniRoot 'canary.txt'))
    $attempt = $null
    if (Test-Path -LiteralPath (Join-Path $miniRoot 'attempt.json')) {
        try { $attempt = Get-Content -LiteralPath (Join-Path $miniRoot 'attempt.json') -Raw | ConvertFrom-Json } catch { $attempt = $null }
    }
    $fixturesExecuted = [object[]]@()
    if ($null -ne $miniSummary -and $null -ne (Get-HarnessProperty $miniSummary 'worker_summary')) {
        $fixturesExecuted = ConvertTo-LocalObjectArray -Value (Get-HarnessProperty (Get-HarnessProperty $miniSummary 'worker_summary') 'fixtures')
    }
    $pass = ($miniExit -ne 0 `
        -and $null -ne $miniSummary `
        -and [bool](Get-HarnessProperty $miniSummary 'offline_selftest_passed') -eq $false `
        -and -not $canaryExists `
        -and $fixturesExecuted.Count -eq 1 `
        -and [string]$fixturesExecuted[0].fixture -eq 'fixture-a' `
        -and $null -ne $attempt -and [int]$attempt.attempt_number -eq 1)
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    Add-LocalFixtureRecord -Name 'single-failure-stops-subsequent' -DeadlineSeconds 20 -Pass $pass -DurationMs $duration `
        -Detail "mini_exit=$miniExit canary_absent=$(-not $canaryExists) fixtures_executed=$($fixturesExecuted.Count) attempt=$($attempt.attempt_number)"
    try { Remove-LocalWorkerDisposableTree -Path $miniRoot } catch { }
    return $pass
}

# ---------------------------------------------------------------------------
# Fixture 14: pre-existing attempt.json refuses a second run; no summary forge
# ---------------------------------------------------------------------------
function Invoke-FixtureDuplicateAttemptRefused {
    $fixtureStart = [DateTimeOffset]::UtcNow
    $miniRoot = Join-Path ([IO.Path]::GetTempPath()) ("r3r1-mini-duplicate-" + [Guid]::NewGuid().ToString('n'))
    [IO.Directory]::CreateDirectory($miniRoot) | Out-Null
    $markerPath = Join-Path $miniRoot 'attempt.json'
    $null = New-LocalSafetyAttemptMarker -Path $markerPath -RunId 'dup-fixture-original' `
        -SupervisorPid $PID -SupervisorCreationTimeUtc ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o'))
    $runnerScript = Join-Path $PSScriptRoot 'run-local-package-regressions.ps1'
    $fixtureWorker = Join-Path $PSScriptRoot 'fixtures\local-safety-fixture-canary.ps1'
    $miniRun = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runnerScript, `
            '-EvidenceRoot', $miniRoot, '-WorkerScript', $fixtureWorker, `
            '-OuterDeadlineSeconds', '15', '-WorkerDeadlineSeconds', '10', '-RunId', 'dup-fixture-second') `
        -Kind 'mini-supervisor-duplicate' -WorkingDirectory $script:RepoRoot -HideConsoleWindow
    Add-LocalOwnedRecordsFromContext -Context $context
    $miniExit = Wait-HarnessProcess -Context $context -Record $miniRun.Record -Stage 'mini-duplicate' -TimeoutSeconds 15
    $canaryExists = (Test-Path -LiteralPath (Join-Path $miniRoot 'canary.txt'))
    $attempt = $null
    if (Test-Path -LiteralPath $markerPath) {
        try { $attempt = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json } catch { $attempt = $null }
    }
    $summaryExists = (Test-Path -LiteralPath (Join-Path $miniRoot 'final-summary.json'))
    $pass = ($miniExit -ne 0 `
        -and -not $canaryExists `
        -and $null -ne $attempt `
        -and [int]$attempt.attempt_number -eq 1 `
        -and [string]$attempt.run_id -eq 'dup-fixture-original' `
        -and [string]$attempt.status -eq 'STARTING' `
        -and -not $summaryExists)
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    Add-LocalFixtureRecord -Name 'duplicate-attempt-refused' -DeadlineSeconds 15 -Pass $pass -DurationMs $duration `
        -Detail "mini_exit=$miniExit canary_absent=$(-not $canaryExists) marker_run_id=$($attempt.run_id) marker_attempt=$($attempt.attempt_number) marker_status=$($attempt.status) summary_absent=$(-not $summaryExists)"
    try { Remove-LocalWorkerDisposableTree -Path $miniRoot } catch { }
    return $pass
}

# ---------------------------------------------------------------------------
# Fixture 15: PowerShell 5.1 List[object] / nested-int[] conversion
# ---------------------------------------------------------------------------
function Invoke-FixturePs51CollectionConversion {
    $deadlineSeconds = 5
    $fixtureStart = [DateTimeOffset]::UtcNow
    $jsonl = Join-Path $tempRoot 'ps51-owned.jsonl'
    $details = New-Object System.Collections.Generic.List[string]

    [IO.File]::WriteAllText($jsonl, '', $utf8)
    $zero = ConvertTo-LocalObjectArray -Value (Read-LocalOwnedProcessRecords -Path $jsonl)
    if ($zero.Count -ne 0) { [void]$details.Add("empty-count=$($zero.Count)") }

    $oneLine = '{"process_id":4242,"process_started_at_unix_ms":1,"kind":"one"}'
    [IO.File]::WriteAllText($jsonl, $oneLine, $utf8)
    $one = ConvertTo-LocalObjectArray -Value (Read-LocalOwnedProcessRecords -Path $jsonl)
    if ($one.Count -ne 1) { [void]$details.Add("one-count=$($one.Count)") }
    elseif ([int]$one[0].ProcessId -ne 4242) { [void]$details.Add('one-pid') }

    $nLines = New-Object System.Collections.Generic.List[string]
    foreach ($n in 1..11) {
        [void]$nLines.Add(('{"process_id":' + $n + ',"process_started_at_unix_ms":' + $n + ',"kind":"n"}'))
    }
    [IO.File]::WriteAllLines($jsonl, $nLines.ToArray(), $utf8)
    $many = ConvertTo-LocalObjectArray -Value (Read-LocalOwnedProcessRecords -Path $jsonl)
    if ($many.Count -ne 11) { [void]$details.Add("n-count=$($many.Count)") }

    $list = New-Object System.Collections.Generic.List[object]
    [void]$list.Add([pscustomobject]@{ fixture = 'a'; pass = $true })
    [void]$list.Add([pscustomobject]@{ fixture = 'b'; pass = $true })
    [void]$list.Add([pscustomobject]@{ fixture = 'c'; pass = $true })
    $payload = [pscustomobject][ordered]@{ fixtures = [object[]]$list.ToArray() }
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $round = $json | ConvertFrom-Json
    $roundFixtures = ConvertTo-LocalObjectArray -Value $round.fixtures
    if ($roundFixtures.Count -ne 3) { [void]$details.Add("roundtrip-count=$($roundFixtures.Count)") }

    $inner = [int[]](10, 20, 30)
    $outer = New-Object object[] 1
    $outer[0] = $inner
    $nested = ConvertTo-LocalInt32IdArray -Value $outer
    $sum = 0
    foreach ($id in $nested) { $sum += [int]$id }
    if ($nested.Count -ne 3 -or $sum -ne 60) { [void]$details.Add("nested-ids count=$($nested.Count) sum=$sum") }

    $verdict = Get-LocalBuildFinalVerdict -BuildStepsSucceeded $true -PromotionSucceeded $true -CleanupSucceeded $false -OwnedProcessesRemaining 0
    if ($verdict.success -or $verdict.exit_code -eq 0 -or $verdict.failures -notcontains 'cleanup failed') {
        [void]$details.Add('verdict')
    }

    $pass = ($details.Count -eq 0)
    $duration = [int]([DateTimeOffset]::UtcNow - $fixtureStart).TotalMilliseconds
    $detailText = 'ok'
    if (-not $pass) { $detailText = [string]::Join(';', $details.ToArray()) }
    Add-LocalFixtureRecord -Name 'ps51-collection-conversion' -DeadlineSeconds $deadlineSeconds -Pass $pass `
        -DurationMs $duration -Detail $detailText
    return $pass
}

# ---------------------------------------------------------------------------
# Top-level try / catch / finally wrapping every side effect after the gate.
# ---------------------------------------------------------------------------
function Assert-LocalWorkerDeadline {
    param([Parameter(Mandatory)][string]$Stage)
    if ([DateTimeOffset]::UtcNow -ge $workerDeadline) {
        throw "Harness overall deadline exceeded during $Stage"
    }
}

# Create the single owned-processes.jsonl writer exactly once, after the
# start gate was consumed and before TEMP / Job Object / fixtures exist.
try {
    Initialize-LocalOwnedRecordsWriter
} catch {
    Write-Warning $_.Exception.Message
    exit 2
}

try {
    Assert-LocalWorkerDeadline -Stage 'create-temp'
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("local-safety-worker-" + [Guid]::NewGuid().ToString('n'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null

    $context = New-HarnessLifecycle -Name 'offline-safety-worker' -RunRoot $tempRoot `
        -Scenario 'offline-safety-worker' -OverallTimeoutSeconds $OverallDeadlineSeconds -HeartbeatSeconds 5 `
        -StartedAt $workerStartedAt -AbsoluteDeadlineAt $workerDeadline

    $fixtureOrder = @(
        'Invoke-FixturePs51CollectionConversion',
        'Invoke-FixtureOfflineNotAcceptance',
        'Invoke-FixtureBuildCleanupFailure',
        'Invoke-FixtureUnsafePaths',
        'Invoke-FixtureFileLock',
        'Invoke-FixtureWatcherNeverExits',
        'Invoke-FixtureResultReadyInterrupted',
        'Invoke-FixtureStuckChildren',
        'Invoke-FixtureStreamPressure',
        'Invoke-FixtureParentExitsAfterChildren',
        'Invoke-FixtureDuplicateAttemptRefused',
        'Invoke-FixtureSingleFailureStops'
    )
    foreach ($fixture in $fixtureOrder) {
        if ($anyFailed) { break }
        Assert-HarnessDeadline -Context $context -Stage "fixture:$fixture"
        $fixtureResult = $null
        try {
            $fixtureResult = & $fixture
        } catch {
            $failureDetail = [string]$_.Exception.Message
            $fixtureResult = $false
        }
        if (-not $fixtureResult) {
            $anyFailed = $true
            $stoppedAt = $fixture
            if (-not $failureDetail) { $failureDetail = 'fixture returned failure' }
        }
    }

    if (-not $anyFailed) {
        Assert-HarnessDeadline -Context $context -Stage 'fixture:supervisor-cuts-infinite-loop'
        $fixtureResult = $false
        try {
            $fixtureResult = Invoke-FixtureSupervisorCutsWorker -FixtureWorkerName 'local-safety-fixture-infinite-loop.ps1' -SupervisorDeadlineSeconds 5 -FixtureDeadlineSeconds 15
        } catch {
            $failureDetail = [string]$_.Exception.Message
        }
        if (-not $fixtureResult) {
            $anyFailed = $true
            $stoppedAt = 'supervisor-cuts-infinite-loop'
            if (-not $failureDetail) { $failureDetail = 'fixture returned failure' }
        }
    }
    if (-not $anyFailed) {
        Assert-HarnessDeadline -Context $context -Stage 'fixture:supervisor-cuts-silent-hang'
        $fixtureResult = $false
        try {
            $fixtureResult = Invoke-FixtureSupervisorCutsWorker -FixtureWorkerName 'local-safety-fixture-silent-hang.ps1' -SupervisorDeadlineSeconds 5 -FixtureDeadlineSeconds 15
        } catch {
            $failureDetail = [string]$_.Exception.Message
        }
        if (-not $fixtureResult) {
            $anyFailed = $true
            $stoppedAt = 'supervisor-cuts-silent-hang'
            if (-not $failureDetail) { $failureDetail = 'fixture returned failure' }
        }
    }
}
catch {
    $anyFailed = $true
    if (-not $failureDetail) { $failureDetail = [string]$_.Exception.Message }
    if (-not $stoppedAt) { $stoppedAt = 'worker-top-level' }
    # A real deadline anomaly (overall deadline exceeded / supervisor cutoff)
    # must be reflected in timeout_detected, never silently swallowed.
    if ($failureDetail -like '*overall deadline exceeded*' -or $failureDetail -like '*SUPERVISOR TIMEOUT*') {
        $script:DeadlineAnomalyDetected = $true
    }
}
finally {
    # 1. Flush every not-yet-recorded owned process into the single writer and
    #    close it BEFORE any other cleanup, so the records are durable and the
    #    residual read below observes a closed, complete file.
    if ($null -ne $context) {
        try { Add-LocalOwnedRecordsFromContext -Context $context } catch { }
    }
    Close-LocalOwnedRecordsWriter

    # 2. Cleanup: Job Object close + exact owned-process verification.
    try {
        if ($null -ne $context) {
            $cleanupMeasure = Close-LocalHarnessRun -Context $context -Reason 'worker-finished'
            $cleanupSuccess = [bool]$cleanupMeasure.cleanup_success
            $ownedRemaining = [int]$cleanupMeasure.owned_processes_remaining
            if (-not $cleanupSuccess) {
                $anyFailed = $true
                if (-not $failureDetail) { $failureDetail = "cleanup failed: $($cleanupMeasure.cleanup_failure)" }
            }
        } else {
            $cleanupMeasure = [pscustomobject]@{ cleanup_success = $true; owned_processes_remaining = 0; cleanup_failure = $null }
            $cleanupSuccess = $true
            $ownedRemaining = 0
        }
    } catch {
        $cleanupMeasure = [pscustomobject]@{ cleanup_success = $false; owned_processes_remaining = -1; cleanup_failure = [string]$_.Exception.Message }
        $cleanupSuccess = $false
        $ownedRemaining = -1
        $anyFailed = $true
        if (-not $failureDetail) { $failureDetail = "cleanup failed: $($_.Exception.Message)" }
    }

    # 3. Residual check from the durable owned-processes.jsonl records.
    $flushedRecords = [object[]]@()
    if ($ownedRecordsPath -and (Test-Path -LiteralPath $ownedRecordsPath)) {
        $flushedRecords = ConvertTo-LocalObjectArray -Value (Read-LocalOwnedProcessRecords -Path $ownedRecordsPath)
    }
    $flushedRemaining = 0
    foreach ($record in $flushedRecords) {
        if (Test-HarnessProcessRecordAlive -Record $record) { $flushedRemaining++ }
    }
    $ownedRemaining = [int]$ownedRemaining + [int]$flushedRemaining
    if ($flushedRemaining -gt 0) {
        $cleanupSuccess = $false
        $anyFailed = $true
    }
    if ($null -ne $cleanupMeasure) {
        try { $cleanupFailureText = $cleanupMeasure.cleanup_failure } catch { $cleanupFailureText = $null }
    }

    if ($tempRoot) {
        try { Remove-LocalWorkerDisposableTree -Path $tempRoot } catch { }
    }
}

$workerFinishedAt = [DateTimeOffset]::UtcNow
$durationMs = [int]($workerFinishedAt - $workerStartedAt).TotalMilliseconds
# Real deadline-anomaly verdict: the worker's own overall deadline overrun and
# any deadline exception observed during the run. Never a hardcoded false.
$workerTimeoutDetected = ([bool]$script:DeadlineAnomalyDetected) -or ($workerFinishedAt -gt $workerDeadline)
if ($workerTimeoutDetected) { $anyFailed = $true }
$workerPass = ((-not $anyFailed) -and $cleanupSuccess -and ($ownedRemaining -eq 0) -and (-not $workerTimeoutDetected))

try {
    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        test = 'Daily-use Local Package v0.1 R3 Safety Repair 2 offline safety worker'
        status = if ($workerPass) { 'OFFLINE' } elseif ($workerTimeoutDetected) { 'TIMEOUT' } else { 'FAIL' }
        acceptance_pass = $false
        offline_selftest_passed = [bool]$workerPass
        overall_deadline_seconds = [int]$OverallDeadlineSeconds
        started_at = $workerStartedAt.ToString('o')
        finished_at = $workerFinishedAt.ToString('o')
        actual_duration_ms = $durationMs
        timeout_detected = [bool]$workerTimeoutDetected
        failure_reason = if ($workerTimeoutDetected) { "worker deadline anomaly: finished_at $($workerFinishedAt.ToString('o')) vs deadline $($workerDeadline.ToString('o')) (detail: $failureDetail)" }
            elseif ($anyFailed) { "first failing fixture: $stoppedAt ($failureDetail)" }
            elseif (-not $cleanupSuccess) { "cleanup failed: $cleanupFailureText" }
            elseif ($ownedRemaining -ne 0) { "owned processes remaining: $ownedRemaining" } else { $null }
        cleanup_success = [bool]$cleanupSuccess
        owned_processes_remaining = [int]$ownedRemaining
        cleanup_failure = $cleanupFailureText
        stopped_at_fixture = $stoppedAt
        automatic_retries = 0
        network_model_calls = 0
        cargo_commands_started = 0
        dotnet_build_commands_started = 0
        fixtures = [object[]]$fixtures.ToArray()
        stream_stdout_truncated = [bool]$script:StreamStdoutTruncated
        stream_stderr_truncated = [bool]$script:StreamStderrTruncated
        stream_stdout_persisted_log_bytes = [int64]$script:StreamStdoutPersistedLogBytes
        stream_stderr_persisted_log_bytes = [int64]$script:StreamStderrPersistedLogBytes
        stream_stdout_log_truncated = [bool]$script:StreamStdoutLogTruncated
        stream_stderr_log_truncated = [bool]$script:StreamStderrLogTruncated
        start_gate_consumed = $true
    }
    Write-LocalWorkerJson -Path (Join-Path $runDirectory 'worker-summary.json') -Object $summary
} catch {
    $workerPass = $false
    $fallback = [ordered]@{
        run_id = $RunId
        status = 'FAIL'
        acceptance_pass = $false
        offline_selftest_passed = $false
        failure_reason = "worker-summary write failed: $($_.Exception.Message)"
        cleanup_success = [bool]$cleanupSuccess
        owned_processes_remaining = [int]$ownedRemaining
        automatic_retries = 0
    }
    try {
        [System.IO.File]::WriteAllText(
            (Join-Path $runDirectory 'worker-summary.json'),
            ($fallback | ConvertTo-Json -Compress),
            $utf8)
    } catch { }
}

if (-not $workerPass) { exit 1 }
exit 0
