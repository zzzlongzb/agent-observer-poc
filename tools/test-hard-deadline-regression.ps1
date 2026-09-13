# Regression test for hard deadline enforcement (Daily-use Local Package
# v0.1 Repair 2).
#
# This test does NOT re-implement deadline math. It exercises the REAL
# production lifecycle from tools/harness-lifecycle.ps1 (via
# tools/local-package-harness.ps1) used by build and acceptance:
#
#   - starts a hidden disposable sleep child that plans to run much longer
#     than the deadline (and spawns a grandchild so a real process tree
#     exists)
#   - sets the overall deadline to 2 seconds
#   - waits with a generous 60s step budget that MUST be clipped to the
#     remaining time by the production deadline logic
#   - asserts the wait actually terminates near the deadline with a TIMEOUT
#     (never a normal exit / PASS)
#   - asserts the full owned process tree (child + grandchild) is terminated
#     and that every recorded PID + creation time is gone after cleanup
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'local-package-harness.ps1')

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("deadline-test-" + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$context = $null
try {
    $context = New-HarnessLifecycle -Name 'hard-deadline-regression' -RunRoot $tempDir `
        -Scenario 'regression' -OverallTimeoutSeconds 2 -HeartbeatSeconds 1

    # Hidden disposable child: spawns a grandchild sleeping 120s, then sleeps
    # 60s itself. Both are in the kill-on-close Job Object because the child
    # is registered (the grandchild inherits job membership).
    $childCommand = 'Start-Process powershell.exe -ArgumentList @(''-NoProfile'',''-Command'',''Start-Sleep -Seconds 120'') -WindowStyle Hidden | Out-Null; Start-Sleep -Seconds 60'
    $owned = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $childCommand) `
        -Kind 'disposable-sleep-child' -WorkingDirectory $tempDir -Scenario 'regression' -HideConsoleWindow
    $childPid = $owned.Record.ProcessId

    # Give the child a moment to spawn its grandchild, then record the
    # grandchild's PID + creation time so the residue check is exact.
    $grandchildPid = 0
    $grandchildCreation = $null
    $searchDeadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while ([DateTimeOffset]::UtcNow -lt $searchDeadline) {
        $rows = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $childPid" -ErrorAction SilentlyContinue)
        if ($rows.Count -gt 0) {
            $grandchildPid = [int]$rows[0].ProcessId
            $grandchildCreation = ([DateTime]$rows[0].CreationDate).ToUniversalTime().ToString('o')
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if ($grandchildPid -eq 0) { throw 'hard deadline regression FAILED: grandchild sleep process never appeared' }

    # Wait with a 60s step budget: the production deadline logic must clip it
    # to the ~2s overall deadline and terminate the wait with a TIMEOUT.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $normalExit = $false
    $exitCode = $null
    try {
        $exitCode = Wait-HarnessProcess -Context $context -Record $owned.Record `
            -Stage 'disposable-sleep-child' -TimeoutSeconds 60
        $normalExit = $true
    } catch {
        $message = $_.Exception.Message
        if ($message -like '*Timed out*' -or $message -like '*deadline exceeded*') {
            $timedOut = $true
        } else {
            throw
        }
    }
    $watch.Stop()

    if ($normalExit) {
        throw "hard deadline regression FAILED: child exited normally (code=$exitCode); the deadline must force a TIMEOUT, never a PASS"
    }
    if (-not $timedOut) {
        throw 'hard deadline regression FAILED: wait did not end in a TIMEOUT/FAIL'
    }
    if ($watch.Elapsed.TotalSeconds -lt 1.0 -or $watch.Elapsed.TotalSeconds -gt 20.0) {
        throw ("hard deadline regression FAILED: termination happened at {0:N1}s, not near the 2s deadline" -f $watch.Elapsed.TotalSeconds)
    }

    # Full owned-tree cleanup through the production path (Job Object dispose).
    $cleanup = Close-LocalHarnessRun -Context $context -Reason 'regression-end'
    if (-not $cleanup.cleanup_success) {
        throw "hard deadline regression FAILED: cleanup failed: $($cleanup.cleanup_failure) (remaining=$($cleanup.owned_processes_remaining))"
    }

    # PID + creation time residue checks: child AND grandchild must be gone.
    $childAlive = Test-HarnessProcessRecordAlive -Record $owned.Record
    if ($childAlive) { throw "hard deadline regression FAILED: child PID $childPid still alive after cleanup" }
    $grandchildAlive = $false
    try {
        $candidate = [Diagnostics.Process]::GetProcessById($grandchildPid)
        try {
            $candidate.Refresh()
            $grandchildAlive = ($candidate.StartTime.ToUniversalTime().ToString('o') -eq $grandchildCreation)
        } finally { $candidate.Dispose() }
    } catch { }
    if ($grandchildAlive) { throw "hard deadline regression FAILED: grandchild PID $grandchildPid still alive after cleanup (owned tree residue)" }

    Write-Host ("Hard deadline regression PASS: terminated at {0:N1}s (deadline 2s), result=TIMEOUT/FAIL, owned tree fully cleaned" -f $watch.Elapsed.TotalSeconds)
    exit 0
}
finally {
    if ($null -ne $context -and -not $context.Closed) {
        Close-LocalHarnessRun -Context $context -Reason 'regression-finally' | Out-Null
    }
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
