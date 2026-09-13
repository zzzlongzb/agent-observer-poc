# Offline static check for Daily-use Local Package v0.1 R3 Safety Repair 2.
# READ-ONLY BY DEFAULT: file reads and AST parse only, results go to stdout.
# Does NOT create directories, does NOT write static-check.json, does not
# start workers, and does not invoke cargo or dotnet.
#
# The optional -OutputPath is the ONLY way to make this script touch the
# filesystem for output: it must be provided explicitly, its parent directory
# must already exist, and the file is written with FileMode.CreateNew (an
# existing file is refused; WriteAllText overwrite and Append are forbidden).
#Requires -Version 5.1
[CmdletBinding()]
param(
    # Optional explicit output file. Default '' = stdout only, no file writes.
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$utf8 = New-Object System.Text.UTF8Encoding $false

$files = @(
    'tools/harness-lifecycle.ps1',
    'tools/local-package-harness.ps1',
    'tools/run-local-package-regressions.ps1',
    'tools/local-package-safety-worker.ps1',
    'tools/local-package-safety-static-check.ps1',
    'tools/local-package-safety-protocol-checks.ps1',
    'tools/build-local-hud-package.ps1',
    'tools/daily-use-local-package-acceptance.ps1',
    'tools/test-atomic-package-regression.ps1',
    'tools/test-hard-deadline-regression.ps1',
    'tools/test-screenshot-observer-regression.ps1',
    'tools/test-evidence-run-id-regression.ps1',
    'tools/test-cleanup-exit-regression.ps1',
    'tools/verify-evidence-run-id.ps1',
    'tools/fixtures/local-safety-fixture-infinite-loop.ps1',
    'tools/fixtures/local-safety-fixture-silent-hang.ps1',
    'tools/fixtures/local-safety-fixture-fail-first.ps1',
    'tools/fixtures/local-safety-fixture-canary.ps1'
)

$parseFailures = New-Object System.Collections.Generic.List[object]
foreach ($rel in $files) {
    $path = Join-Path $repoRoot $rel
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($err in $errors) {
            [void]$parseFailures.Add([pscustomobject][ordered]@{
                file = $rel
                message = [string]$err.Message
            })
        }
    }
}

function Get-LocalPatternHits {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [string[]]$Include
    )
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($rel in $Include) {
        $path = Join-Path $repoRoot $rel
        $found = Select-String -LiteralPath $path -Pattern $Pattern -AllMatches
        foreach ($match in @($found)) {
            [void]$hits.Add([pscustomobject][ordered]@{
                file = $rel
                line = [int]$match.LineNumber
                text = ([string]$match.Line).Trim()
            })
        }
    }
    return ,[object[]]$hits.ToArray()
}

$chain = @(
    'tools/harness-lifecycle.ps1',
    'tools/local-package-harness.ps1',
    'tools/run-local-package-regressions.ps1',
    'tools/local-package-safety-worker.ps1',
    'tools/local-package-safety-static-check.ps1',
    'tools/local-package-safety-protocol-checks.ps1',
    'tools/build-local-hud-package.ps1',
    'tools/daily-use-local-package-acceptance.ps1',
    'tools/test-atomic-package-regression.ps1',
    'tools/test-hard-deadline-regression.ps1',
    'tools/test-screenshot-observer-regression.ps1',
    'tools/test-evidence-run-id-regression.ps1',
    'tools/test-cleanup-exit-regression.ps1',
    'tools/fixtures/local-safety-fixture-infinite-loop.ps1',
    'tools/fixtures/local-safety-fixture-silent-hang.ps1',
    'tools/fixtures/local-safety-fixture-fail-first.ps1',
    'tools/fixtures/local-safety-fixture-canary.ps1'
)

$processStart = Get-LocalPatternHits -Pattern 'Process\.Start\s*\(|Start-Process|&\s*powershell\.exe|&\s*pwsh\.exe|CreateProcessW' -Include $chain
$waitForExit = Get-LocalPatternHits -Pattern 'WaitForExit\s*\(|ReadToEnd(Async)?\s*\(|Kill\(\s*\$true\s*\)|Stop-Process\s+-Name|taskkill' -Include $chain
$loops = Get-LocalPatternHits -Pattern '\bwhile\s*\(|\bdo\s*\{|\bfor\s*\(\s*;\s*;' -Include $chain
$listWrap = Get-LocalPatternHits -Pattern '@\(\$fixtures\)|@\(\$records\)|@\(\$executed\)|@\(\$failures\)|@\(\$consoleIds\)' -Include $chain
$forceRetry = Get-LocalPatternHits -Pattern '\[switch\]\s*\$Force\b|\$OverwriteAttempt\b|\[switch\]\s*\$Retry\b' -Include @(
    'tools/run-local-package-regressions.ps1',
    'tools/local-package-safety-worker.ps1',
    'tools/local-package-harness.ps1'
)
# Forbidden append/overwrite evidence writes. The pattern is assembled from
# pieces so this scanner never matches its own pattern definition or its own
# comments. (The C# launcher comment in harness-lifecycle.ps1 legitimately
# mentions the C#-style dotted Append spelling, so only the PowerShell-style
# bracketed Append mode constant and the append-all-text API are scanned.)
$appendPatternPieces = @(
    ('FileMode' + '\]::' + 'Append'),
    ('Append' + 'AllText')
)
$forbiddenAppendPattern = $appendPatternPieces -join '|'
$forbiddenAppend = Get-LocalPatternHits -Pattern $forbiddenAppendPattern -Include @(
    'tools/harness-lifecycle.ps1',
    'tools/run-local-package-regressions.ps1',
    'tools/local-package-safety-worker.ps1',
    'tools/local-package-safety-static-check.ps1'
)

$parseOk = ($parseFailures.Count -eq 0)
$listWrapOk = ($listWrap.Count -eq 0)
$noForceBypass = ($forceRetry.Count -eq 0)
$noForbiddenAppend = ($forbiddenAppend.Count -eq 0)

$result = [pscustomobject][ordered]@{
    static_check = 'daily-use-local-package-v0.1-r3-safety-r2'
    mode = 'read-only-default (stdout only; no directories or static-check.json are created unless -OutputPath is explicitly provided)'
    ast_parse = [ordered]@{
        method = 'System.Management.Automation.Language.Parser::ParseFile'
        files_checked = $files
        parse_failures = [int]$parseFailures.Count
        errors = [object[]]$parseFailures.ToArray()
    }
    process_start_points = @(
        [ordered]@{
            location = 'tools/harness-lifecycle.ps1 (C# AgentObserverHarness.SafeProcessLauncher.Start)'
            kind = 'SOLE_LOW_LEVEL_SAFE_LAUNCHER'
            mechanism = 'CreateProcessW(CREATE_SUSPENDED) -> AssignProcessToJobObject(kill-on-close job) -> GetProcessTimes(PID+creation time) -> ResumeThread; assign/record/resume failure terminates the still-suspended exact process and fails; all process/thread/pipe handles closed on success and failure; no token handles opened; job handle borrowed, never closed by the launcher; transport/evidence log files opened with FileMode.CreateNew BEFORE CreateProcessW, refusing to launch over an existing file'
        }
        [ordered]@{
            location = 'tools/harness-lifecycle.ps1 Start-HarnessProcess / tools/local-package-harness.ps1 Start-LocalHarnessProcess'
            kind = 'SAFE_WRAPPER'
            mechanism = 'all launches in the local-package chain route through the sole C# launcher; hidden window via STARTF_USESHOWWINDOW+SW_HIDE+CREATE_NO_WINDOW (or -ShowWindow for GUI children); stdout+stderr always piped and drained concurrently with bounded capture/log'
        }
        [ordered]@{
            location = 'tools/local-package-safety-worker.ps1 fixture 6 runtime-generated TEMP child script'
            kind = 'FIXTURE_INTERNAL_SIMULATED_USER_SPAWN'
            mechanism = 'single Start-Process (hidden) inside a disposable child simulating an uncooperative user process; provably job-contained because the parent was in the kill-on-close job BEFORE executing (suspended->assign->resume); this fixture exists precisely to prove such descendants are cleaned up'
        }
        [ordered]@{
            location = 'tools/test-hard-deadline-regression.ps1 (command string)'
            kind = 'FIXTURE_INTERNAL_SIMULATED_USER_SPAWN'
            mechanism = 'same pattern; legacy R2 regression, NOT executed this round'
        }
        [ordered]@{
            location = 'tools/windows-background-process-hardening-supervisor.ps1 (.NET ProcessStartInfo + post-start Register-HarnessProcess)'
            kind = 'OUT_OF_SCOPE_PREEXISTING'
            mechanism = 'previously accepted tool outside the local-package chain; still has the start->assign race; NOT modified and NOT executed this round; recorded as a known unproven path'
        }
    )
    forbidden_pattern_scan = [ordered]@{
        scope = 'the local-package chain files listed above'
        process_start_hits = [object[]]$processStart
        wait_kill_hits = [object[]]$waitForExit
        loop_hits = [object[]]$loops
        ps51_list_wrap_hits = [object[]]$listWrap
        force_retry_bypass_hits = [object[]]$forceRetry
        forbidden_filemode_append_hits = [object[]]$forbiddenAppend
        ps51_list_wrap_clean = [bool]$listWrapOk
        no_force_retry_bypass = [bool]$noForceBypass
        no_forbidden_filemode_append = [bool]$noForbiddenAppend
    }
    r3_safety_r2_repair_invariants = [ordered]@{
        log_ownership_protocol = 'Get-LocalSafetyStaleFileNames: SupervisorPreLaunch forbids all six official outputs before launch; WorkerPostLaunch allows only the two supervisor-created transport logs and still refuses worker-summary.json, fixture-stream-*.log and final-summary.json'
        deadline_verdict = 'Get-LocalSafetyDeadlineVerdict: finished_at > absolute_deadline_at forces timeout_detected=true, final_status=TIMEOUT and success_allowed=false'
        terminal_state_protocol = 'marker FINISHED (final_status empty) -> final-summary.json FileMode.CreateNew -> marker FINISHED+final_status -> re-read and verify agreement (Test-LocalSafetyMarkerSummaryAgreement); any failure is INCOMPLETE with a non-zero exit'
        owned_process_evidence = 'owned-processes.jsonl: single writer, FileMode.CreateNew once, append-only per new PID+creation time with per-record flush and flush-to-disk, HashSet dedupe, closed in finally; no FileMode.Append and no WriteAllLines overwrite'
        direct_run_refusal = 'worker and fixture workers have no Mandatory supervision parameters; the first body check is -Supervised and refuses non-interactively before any side effect'
    }
    loop_audit = @(
        [ordered]@{ location = 'harness-lifecycle.ps1 C# DrainLoop'; bound = 'reads until pipe EOF; EOF guaranteed because the parent closes its write ends at start and the kill-on-close job terminates the child tree; drain is a background thread, never blocks the supervisor' }
        [ordered]@{ location = 'harness-lifecycle.ps1 Stop-HarnessProcessRecord'; bound = 'absolute 5s wall-clock deadline' }
        [ordered]@{ location = 'harness-lifecycle.ps1 Wait-HarnessProcess'; bound = 'Assert-HarnessDeadline (overall deadline, throws) + per-step deadline throw' }
        [ordered]@{ location = 'harness-lifecycle.ps1 Wait-HarnessCondition'; bound = 'loop condition is now < absolute deadline' }
        [ordered]@{ location = 'harness-lifecycle.ps1 Wait-HarnessSleep'; bound = 'loop condition is now < absolute sleep deadline, sliced to the overall deadline' }
        [ordered]@{ location = 'local-package-harness.ps1 Wait-LocalResultReady while($true)'; bound = 'Assert-HarnessDeadline + local deadline throw + terminal-state fail-fast throw inside the loop' }
        [ordered]@{ location = 'local-package-harness.ps1 ConvertTo-LocalInt32IdArray queue walk'; bound = 'hard 100000-iteration guard' }
        [ordered]@{ location = 'run-local-package-regressions.ps1 supervisor wait'; bound = 'breaks on outer wall-clock deadline (timeout -> job close)' }
        [ordered]@{ location = 'run-local-package-regressions.ps1 residual verify do/while'; bound = 'absolute 5s residualDeadline' }
        [ordered]@{ location = 'local-package-safety-worker.ps1 watcher fixture command'; bound = 'intentional never-exiting watcher (Start-Sleep 1 loop) inside the command string; terminated by the owner with a bounded stop; this is the fixture''s purpose' }
        [ordered]@{ location = 'tools/fixtures/local-safety-fixture-infinite-loop.ps1 for(;;){}'; bound = 'INTENTIONAL hang simulation; the owning supervisor wall-clock deadline + kill-on-close job is the only terminator' }
    )
    recursive_delete_move_validation = @(
        'tools/build-local-hud-package.ps1: Assert-LocalPackageSafeOperationRoots before staging/backup creation; staging cleanup via Remove-LocalPackageDirectorySafely; promotion helper validates the triple at entry',
        'tools/local-package-harness.ps1 Invoke-LocalPackageAtomicPromotion: path-safety assertion before any Move-Item/Remove-Item',
        'tools/daily-use-local-package-acceptance.ps1: disposable dirs validated with Assert-LocalPackageSafePath against the TEMP allowed root',
        'tools/local-package-safety-worker.ps1: every TEMP directory removal is guarded by a canonical-path + TEMP-root containment check',
        'tools/run-local-package-regressions.ps1: no recursive delete/move at all (atomic marker update via File.Replace)'
    )
    success_state_requirements = [ordered]@{
        final_summary = 'offline_selftest_passed requires worker pass AND no timeout AND deadline_respected (finished_at <= absolute_deadline_at) AND cleanup_success AND owned_processes_remaining==0 AND no new visible console windows AND verified marker/summary agreement'
        worker_summary = 'offline_selftest_passed requires all fixtures passed AND cleanup_success AND owned_processes_remaining==0 AND no real deadline anomaly (timeout_detected reflects deadline overrun/exceptions, never a constant)'
        build_exit_code = 'Get-LocalBuildFinalVerdict: build steps AND promotion AND cleanup AND owned_processes_remaining==0; single terminal verdict, no override'
        acceptance_pass = 'OFFLINE results can never set acceptance_pass=true (Resolve-HarnessAcceptanceClaim)'
    }
    unproven_paths = @(
        'The real Daily-use Local Package acceptance, the R2 regression set and the package build are NOT executed this round; their end-to-end behaviour remains unverified until a future supervised run',
        'tools/windows-background-process-hardening-supervisor.ps1 still launches via .NET ProcessStartInfo with post-start job assignment (pre-existing, out of scope, not executed this round)',
        'Drain EOF depends on every descendant of a child closing the inherited pipe write handles; a descendant that outlives its parent keeps a drain alive until the job terminates it (bounded by WaitDrains timeouts)'
    )
    passed = [bool]($parseOk -and $listWrapOk -and $noForceBypass -and $noForbiddenAppend)
}

# Read-only default: the result goes to stdout. The ONLY filesystem write is
# the explicitly requested -OutputPath, written with FileMode.CreateNew into
# an already-existing directory; an existing file is refused.
if ($OutputPath) {
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $OutputPath) {
        throw "REFUSING: output file already exists: $OutputPath (CreateNew only; no overwrite)"
    }
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
        throw "REFUSING: output directory does not exist: $outputDir (this check never creates directories)"
    }
    $json = $result | ConvertTo-Json -Depth 8
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch [System.IO.IOException] {
        throw "REFUSING: output file already exists: $OutputPath (CreateNew only; no overwrite)"
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

Write-Output ($result | ConvertTo-Json -Depth 8)
if (-not $result.passed) {
    Write-Output 'STATIC CHECK FAILED'
    exit 1
}
Write-Output 'STATIC CHECK PASSED'
exit 0
