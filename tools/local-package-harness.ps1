# Shared production implementation for the Daily-use Local Package v0.1 tooling.
#
# This file is dot-sourced by tools/build-local-hud-package.ps1,
# tools/daily-use-local-package-acceptance.ps1 and the regression tests under
# tools/test-*.ps1. It has NO side effects at dot-source time (the Win32 job
# type is added lazily by New-HarnessLifecycle).
#
# It layers the accepted Windows Background Process Hardening lifecycle
# (tools/harness-lifecycle.ps1) with local-package specific pieces so that
# build, acceptance and regression tests all execute the SAME production code:
#
#   - Start-LocalHarnessProcess / Invoke-LocalHarnessCommand
#       bounded process launch + wait (kill-on-close Job Object, PID +
#       process creation time records, hard deadline clipping, full owned
#       process tree termination at cleanup). Never a bare parent-PID-only
#       kill as the last resort and never Process.Kill($true), which is
#       unreliable on PowerShell 5.1.
#   - Get-LocalHarness*Arguments
#       single source of truth for the real offline cargo/dotnet command
#       lines (reports must be generated from these definitions).
#   - Invoke-LocalPackageAtomicPromotion
#       production atomic directory promotion with explicit test-only failure
#       injection points. A failed restore NEVER deletes the backup.
#   - Test-ScreenshotObserverBinding
#       production predicate for the screenshot-run Observer child binding.
#   - Wait-LocalHarnessConditionResult
#       condition wait that returns $false on condition timeout but keeps
#       overall-deadline exceptions fatal.
#   - Close-LocalHarnessRun
#       final cleanup: dispose the Job Object (terminates the entire owned
#       tree), then verify every recorded PID + creation time is gone. Any
#       cleanup failure is reported and MUST make the run FAIL.

#Requires -Version 5.1
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'harness-lifecycle.ps1')

# ---------------------------------------------------------------------------
# PowerShell 5.1 collection helpers
#
# `@($genericList[object])` and `return @($genericList[object])` throw
# "Cannot convert List`1[System.Object] to Object[]" under Windows
# PowerShell 5.1. Empty HashSet/List pipeline enumeration can also collapse
# to $null (see windows-background-process-hardening v1.1-r1). These helpers
# never use `@()` on a generic List[object]: they copy via ToArray() and
# return with the unary comma so 0- and 1-element results stay arrays.
# ---------------------------------------------------------------------------

function ConvertTo-LocalObjectArray {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value) {
        return ,[object[]]@()
    }
    if ($Value -is [object[]]) {
        if ($Value.Length -eq 1 -and $null -ne $Value[0] -and $Value[0] -is [object[]]) {
            return ,[object[]]$Value[0]
        }
        return ,[object[]]$Value
    }
    if ($Value -is [System.Array]) {
        $copy = New-Object object[] $Value.Length
        [Array]::Copy($Value, $copy, $Value.Length)
        return ,$copy
    }
    $hasToArray = $false
    try { $hasToArray = $null -ne $Value.PSObject.Methods['ToArray'] } catch { $hasToArray = $false }
    if ($hasToArray) {
        return ,[object[]]$Value.ToArray()
    }
    $list = New-Object System.Collections.Generic.List[object]
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            [void]$list.Add($item)
        }
        return ,$list.ToArray()
    }
    [void]$list.Add($Value)
    return ,$list.ToArray()
}

function ConvertTo-LocalInt32IdArray {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    $ids = New-Object System.Collections.Generic.List[int]
    $pending = New-Object System.Collections.Queue
    $pending.Enqueue($Value)
    $guard = 0
    while ($pending.Count -gt 0 -and $guard -lt 100000) {
        $guard++
        $node = $pending.Dequeue()
        if ($null -eq $node) { continue }
        if ($node -is [string]) {
            [void]$ids.Add([int]$node)
            continue
        }
        if ($node -is [System.Collections.IEnumerable]) {
            foreach ($inner in $node) {
                $pending.Enqueue($inner)
            }
            continue
        }
        [void]$ids.Add([int]$node)
    }
    return ,$ids.ToArray()
}

# ---------------------------------------------------------------------------
# Offline command argument definitions (single source of truth)
# ---------------------------------------------------------------------------

function Get-LocalHarnessCargoBuildArguments {
    # cargo build --release --locked --offline --bin agent-observer-poc
    return ,@('build', '--release', '--locked', '--offline', '--bin', 'agent-observer-poc')
}

function Get-LocalHarnessCargoTestArguments {
    # cargo test --bin agent-observer-poc --locked --offline -- --test-threads=4
    return ,@('test', '--bin', 'agent-observer-poc', '--locked', '--offline', '--', '--test-threads=4')
}

function Get-LocalHarnessCargoFmtArguments {
    # cargo fmt --check (formatter only; never touches the network)
    return ,@('fmt', '--check')
}

function Get-LocalHarnessDotnetListRuntimesArguments {
    return ,@('--list-runtimes')
}

function Get-LocalHarnessDotnetPublishArguments {
    # dotnet publish <project> -c Release --no-restore -o <unique staging output>
    # Repair 3 (rule 9): the publish output goes to a unique staging directory,
    # never to a shared bin path a running process could hold open.
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$OutputPath = ''
    )
    $arguments = @('publish', $ProjectPath, '-c', 'Release', '--no-restore')
    if ($OutputPath) {
        $arguments += @('-o', $OutputPath)
    }
    return , $arguments
}

function Get-LocalHarnessDotnetBuildArguments {
    param([Parameter(Mandatory)][string]$ProjectPath)
    # dotnet build <project> -warnaserror --no-restore
    return ,@('build', $ProjectPath, '-warnaserror', '--no-restore')
}

# ---------------------------------------------------------------------------
# Bounded process launch / wait
# ---------------------------------------------------------------------------

function ConvertTo-LocalHarnessArgumentString {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList)
    return (ConvertTo-HarnessArgumentString -ArgumentList $ArgumentList)
}

function Start-LocalHarnessProcess {
    # Starts a process through the shared SafeProcessLauncher
    # (CREATE_SUSPENDED -> AssignProcessToJobObject -> PID + creation time ->
    # ResumeThread). The child is provably inside the kill-on-close Job Object
    # before it executes any user code, so any descendant it spawns is
    # job-owned; an exited parent can never again be treated as "left nothing
    # behind". stdout AND stderr are always drained concurrently from process
    # start into a bounded capture plus optional bounded incremental logs.
    # There is no post-exit ReadToEnd and no unbounded in-memory capture.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$Scenario = 'local-package',
        # Console children (cargo/dotnet/powershell) must be created hidden.
        # GUI children (AgentObserver.Hud.exe) pass -ShowWindow so the HUD
        # window shows normally.
        [switch]$HideConsoleWindow,
        [switch]$ShowWindow,
        # Bounded incremental log files. Draining continues past the cap.
        [string]$StdoutLogPath = '',
        [string]$StderrLogPath = '',
        [int]$MaxCaptureBytes = 262144,
        [int]$MaxLogBytes = 2097152
    )

    if ($ShowWindow -and $HideConsoleWindow) {
        throw "Start-LocalHarnessProcess: -ShowWindow and -HideConsoleWindow are mutually exclusive"
    }

    Start-HarnessProcess -Context $Context -FilePath $FilePath -ArgumentList $ArgumentList `
        -Kind $Kind -Scenario $Scenario -WorkingDirectory $WorkingDirectory `
        -RedirectStandardOutput:$StdoutLogPath -RedirectStandardError:$StderrLogPath `
        -MaxCaptureBytes $MaxCaptureBytes -MaxLogBytes $MaxLogBytes `
        -ShowWindow:$ShowWindow
}

function Invoke-LocalHarnessCommand {
    # Bounded external command: start + register as owned process + wait with
    # a hard-deadline-clipped timeout. Returns a step object carrying the exit
    # code. Throws on wait timeout (the record is terminated first) and on
    # overall deadline violation (the whole owned process tree is terminated
    # via the kill-on-close Job Object). Callers MUST treat any throw as a
    # FAIL and route cleanup through Close-LocalHarnessRun.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 0,
        [string]$Scenario = 'local-package',
        [switch]$CaptureOutput,
        [switch]$HideConsoleWindow,
        [string]$StdoutLogPath = '',
        [string]$StderrLogPath = ''
    )

    $started = [DateTimeOffset]::UtcNow
    $owned = Start-LocalHarnessProcess -Context $Context -FilePath $FilePath -ArgumentList $Arguments `
        -Kind $Name -WorkingDirectory $WorkingDirectory -Scenario $Scenario `
        -HideConsoleWindow:$HideConsoleWindow `
        -StdoutLogPath $StdoutLogPath -StderrLogPath $StderrLogPath

    $exitCode = Wait-HarnessProcess -Context $Context -Record $owned.Record -Stage $Name -TimeoutSeconds $TimeoutSeconds

    # The drains ran concurrently from process start; wait for their completion
    # with a deadline-clipped bound so the total deadline is always respected.
    $drainTimeoutMs = Get-HarnessClippedTimeoutMilliseconds -Context $Context -RequestedMilliseconds 5000 -Stage "${Name}-drains"
    if (-not $owned.Launcher.WaitDrains($drainTimeoutMs)) {
        throw "${Name}: process exited but stdout/stderr drains did not complete within ${drainTimeoutMs}ms"
    }

    $stdout = $null
    if ($CaptureOutput) {
        $stdout = $owned.Launcher.Stdout
    }
    $stderr = $owned.Launcher.Stderr

    [pscustomobject][ordered]@{
        name = $Name
        exit_code = [int]$exitCode
        duration_ms = [int]([DateTimeOffset]::UtcNow - $started).TotalMilliseconds
        timeout_detected = $false
        stdout = $stdout
        stderr = $stderr
        stdout_truncated = [bool]$owned.Launcher.StdoutTruncated
        stderr_truncated = [bool]$owned.Launcher.StderrTruncated
        stdout_total_bytes = [int64]$owned.Launcher.StdoutTotalBytes
        stderr_total_bytes = [int64]$owned.Launcher.StderrTotalBytes
    }
}

function Wait-LocalHarnessConditionResult {
    # Wraps Wait-HarnessCondition for steps whose timeout is a step FAIL, not a
    # run-level abort: returns $false when the condition times out, but keeps
    # overall-deadline exceptions fatal.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$Stage,
        [int]$TimeoutSeconds = 0
    )
    try {
        $result = Wait-HarnessCondition -Context $Context -Condition $Condition -Stage $Stage -TimeoutSeconds $TimeoutSeconds
        return $true
    } catch {
        $message = $_.Exception.Message
        if ($message -like '*deadline exceeded*') { throw }
        if ($message -like "*Timed out after*waiting for $Stage*") { return $false }
        throw
    }
}

# ---------------------------------------------------------------------------
# Atomic package promotion (production implementation with test injection)
# ---------------------------------------------------------------------------

function Invoke-LocalPackageAtomicPromotion {
    <#
    .SYNOPSIS
        Atomically promotes a fully built staging directory onto PackageRoot.

    .DESCRIPTION
        Contract (Daily-use Local Package v0.1 Repair 2):
        1. The existing package stays in place during build/staging/sanity.
        2. Only after staging fully passed, the existing package is renamed to
           a unique backup.
        3. Staging is renamed to PackageRoot.
        4. The backup is deleted only AFTER a successful promote.
        5. On promote failure the backup is restored.
        6. If the restore fails: keep the backup, record its absolute path,
           return FAIL. The backup is NEVER deleted in this state.
        7. If the backup delete fails: keep the backup, do NOT delete the
           promoted package, record a warning; FAIL unless package integrity
           can be proven by the VerifyPackage scriptblock.

        InjectFailure is TEST-ONLY and simulates failures at explicit points:
        - BeforePromotion      : failure detected before anything moves
                                 (early build failure / staging sanity failure)
        - AfterBackupMove      : promote move fails after the backup was moved
        - BeforeBackupRestore  : the backup restore itself fails
        - BackupCleanupFailure : deleting the backup after promote fails

        RETURN CONTRACT (Candidate Package Build v1 Repair 1): the function
        emits EXACTLY ONE promotion result object. Every internal call used
        only for validation has its success-stream output suppressed
        ($null = / [void]); callers MUST capture with @(...) and assert
        Count -eq 1. A caller must never mask pollution by taking the last
        array element.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StagingPath,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$BackupRoot,
        [ValidateSet('None', 'BeforePromotion', 'AfterBackupMove', 'BeforeBackupRestore', 'BackupCleanupFailure')]
        [string]$InjectFailure = 'None',
        [scriptblock]$VerifyPackage,
        [Parameter(Mandatory)][string]$AllowedRoot,
        [string]$RepoRoot = ''
    )

    $result = [pscustomobject][ordered]@{
        promoted = $false
        status = 'FAIL'
        error = $null
        warning = $null
        backup_path = $null
        backup_retained = $false
        package_restored = $false
        package_integrity_verified = $false
    }

    if (-not (Test-Path -LiteralPath $StagingPath)) {
        $result.error = "staging directory missing: $StagingPath"
        return $result
    }

    # Path safety (AGENTS.md rule 13): AllowedRoot is mandatory and must be
    # supplied by the caller. It is NEVER derived from PackageRoot's parent.
    # The validator's own return value is validation-only data: it is
    # suppressed here so it can never pollute the promotion result stream.
    if ([string]::IsNullOrWhiteSpace($AllowedRoot)) {
        $result.error = 'path safety validation failed: AllowedRoot is required and must not be inferred from PackageRoot'
        return $result
    }
    try {
        $null = Assert-LocalPackageSafeOperationRoots -StagingPath $StagingPath -PackageRoot $PackageRoot `
            -BackupRoot $BackupRoot -AllowedRoots @($AllowedRoot) -RepoRoot $RepoRoot
    } catch {
        $result.error = "path safety validation failed: $($_.Exception.Message)"
        return $result
    }

    if ($InjectFailure -eq 'BeforePromotion') {
        # Nothing has moved yet: the existing package stays exactly in place.
        $result.error = 'INJECTED FAILURE: BeforePromotion (build/staging/sanity failed before any move)'
        return $result
    }

    $hadOriginal = Test-Path -LiteralPath $PackageRoot
    if ($hadOriginal) {
        if (Test-Path -LiteralPath $BackupRoot) {
            $result.error = "backup path already exists: $BackupRoot"
            return $result
        }
        Move-Item -LiteralPath $PackageRoot -Destination $BackupRoot
    }

    $promoteError = $null
    if ($InjectFailure -eq 'AfterBackupMove' -or $InjectFailure -eq 'BeforeBackupRestore') {
        # AfterBackupMove: the promote itself fails after the backup was moved.
        # BeforeBackupRestore: compound scenario — the promote fails AND the
        # subsequent backup restore fails, exercising the "restore failure"
        # branch of the contract.
        $promoteError = "INJECTED FAILURE: $InjectFailure"
    } else {
        try {
            Move-Item -LiteralPath $StagingPath -Destination $PackageRoot
        } catch {
            $promoteError = "promote failed: $($_.Exception.Message)"
        }
    }

    if ($promoteError) {
        # Promote failed: restore the original package from the backup.
        if (-not $hadOriginal) {
            $result.error = $promoteError
            return $result
        }
        if (-not (Test-Path -LiteralPath $BackupRoot)) {
            $result.error = "$promoteError; backup directory missing, original package could not be restored"
            return $result
        }
        if (Test-Path -LiteralPath $PackageRoot) {
            $result.error = "$promoteError; promote target exists, backup retained at $BackupRoot"
            $result.backup_path = [IO.Path]::GetFullPath($BackupRoot)
            $result.backup_retained = $true
            return $result
        }
        if ($InjectFailure -eq 'BeforeBackupRestore') {
            # Simulated restore failure: keep the backup, record its absolute
            # path, FAIL. The backup must NEVER be deleted in this state.
            $result.error = "INJECTED FAILURE: BeforeBackupRestore (promote failed and backup restore failed); backup retained at $BackupRoot"
            $result.backup_path = [IO.Path]::GetFullPath($BackupRoot)
            $result.backup_retained = $true
            return $result
        }
        try {
            Move-Item -LiteralPath $BackupRoot -Destination $PackageRoot
            $result.package_restored = $true
            $result.error = "$promoteError; original package restored from backup"
            return $result
        } catch {
            $result.error = "$promoteError; backup restore failed: $($_.Exception.Message); backup retained at $BackupRoot"
            $result.backup_path = [IO.Path]::GetFullPath($BackupRoot)
            $result.backup_retained = $true
            return $result
        }
    }

    # Promote succeeded.
    $result.promoted = $true

    if (-not $hadOriginal -or -not (Test-Path -LiteralPath $BackupRoot)) {
        $result.status = 'PASS'
        return $result
    }

    # Delete the backup only now. If deletion fails, keep the backup and prove
    # the newly promoted package is intact.
    $cleanupFailed = $false
    if ($InjectFailure -eq 'BackupCleanupFailure') {
        $cleanupFailed = $true
    } else {
        try {
            $null = Remove-LocalPackageDirectorySafely -Path $BackupRoot -AllowedRoots @($AllowedRoot) -RepoRoot $RepoRoot
        } catch {
            $cleanupFailed = $true
        }
    }

    if (-not $cleanupFailed) {
        $result.status = 'PASS'
        return $result
    }

    $integrity = $false
    if ($VerifyPackage) {
        try { $integrity = [bool](& $VerifyPackage) } catch { $integrity = $false }
    }
    $result.backup_path = [IO.Path]::GetFullPath($BackupRoot)
    $result.backup_retained = $true
    $result.package_integrity_verified = $integrity
    if ($integrity) {
        $result.status = 'PASS'
        $result.warning = "backup cleanup failed; backup retained at $BackupRoot; promoted package integrity verified"
    } else {
        $result.status = 'FAIL'
        $result.error = "backup cleanup failed and promoted package integrity could not be verified; backup retained at $BackupRoot"
    }
    return $result
}

# ---------------------------------------------------------------------------
# Promotion result contract (Candidate Package Build v1 Repair 1)
# ---------------------------------------------------------------------------

function Get-LocalPackagePromotionRequiredProperties {
    # Pure single source of truth for the promotion result contract.
    [CmdletBinding()]
    param()
    return [string[]]@(
        'promoted',
        'status',
        'error',
        'warning',
        'backup_path',
        'backup_retained',
        'package_restored',
        'package_integrity_verified'
    )
}

function Test-LocalPackagePromotionResultContract {
    <#
    .SYNOPSIS
        Pure promotion-result contract check: returns $true iff $Value is a
        single non-null, non-array object carrying EVERY required property.

    .DESCRIPTION
        Used by the build caller before any property dereference, and by the
        regression tests after every promotion call. A polluted promotion
        (array of result + helper output) or an incomplete result object
        fails this check so no caller ever dereferences an unverified object.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Array]) { return $false }
    foreach ($name in (Get-LocalPackagePromotionRequiredProperties)) {
        $present = $false
        try { $present = ($null -ne $Value.PSObject.Properties[$name]) } catch { $present = $false }
        if (-not $present) { return $false }
    }
    return $true
}

function Get-LocalPackagePromotionDiagnostic {
    <#
    .SYNOPSIS
        Safe promotion diagnostic for a top-level build catch block: NEVER
        throws and NEVER dereferences backup_retained / backup_path before
        the promotion result contract has been proven.

    .DESCRIPTION
        Returns a human-readable BACKUP RETAINED warning string for a
        contract-valid result with backup_retained=true and a non-empty
        backup_path; returns $null for anything else (null, array, missing
        properties, no retained backup). Callers use this inside a nested
        try/catch so a diagnostic failure can only append to, never
        overwrite, the original failure reason.
    #>
    [CmdletBinding()]
    param([AllowNull()]$PromotionResult)
    try {
        if (-not (Test-LocalPackagePromotionResultContract -Value $PromotionResult)) { return $null }
        if (-not [bool]$PromotionResult.backup_retained) { return $null }
        $backupPath = $PromotionResult.backup_path
        if ($null -eq $backupPath -or [string]::IsNullOrWhiteSpace([string]$backupPath)) { return $null }
        return ("BACKUP RETAINED at {0}; original package recoverable from there" -f $backupPath)
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Screenshot Observer binding predicate (production)
# ---------------------------------------------------------------------------

function Test-ScreenshotObserverBinding {
    <#
    .SYNOPSIS
        Production predicate: a screenshot-run HUD is correctly bound to its
        Observer child iff exactly one Observer child exists, its parent is the
        screenshot HUD, and its MainWindowHandle is 0 (no visible window).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ObserverDetails,
        [Parameter(Mandatory)][int]$HudPid
    )
    $details = @($ObserverDetails)
    if ($details.Count -ne 1) { return $false }
    $observer = $details[0]
    $parentPid = 0
    $handle = -1L
    try { $parentPid = [int]$observer.parent_process_id } catch { return $false }
    try { $handle = [int64]$observer.main_window_handle } catch { return $false }
    return (($parentPid -eq $HudPid) -and ($handle -eq 0))
}

# ---------------------------------------------------------------------------
# Final cleanup with verification
# ---------------------------------------------------------------------------

function Close-LocalHarnessRun {
    # Disposes the kill-on-close Job Object (terminating the entire owned
    # process tree), then verifies that every recorded PID + process creation
    # time is gone. The returned measurement MUST be checked by callers: any
    # cleanup failure makes the run FAIL.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Reason = 'final'
    )
    $failure = $null
    try {
        Close-HarnessLifecycle -Context $Context -Reason $Reason
    } catch {
        $failure = $_.Exception.Message
    }
    try {
        Assert-NoHarnessProcesses -Context $Context
    } catch {
        $message = $_.Exception.Message
        $failure = if ($failure) { "$failure; $message" } else { $message }
    }
    return (Measure-HarnessCleanup -Contexts @($Context) -CleanupFailure $failure)
}

# ---------------------------------------------------------------------------
# Path safety (AGENTS.md rule 13)
# ---------------------------------------------------------------------------

function Get-LocalPackageFixedAllowedRoot {
    <#
    .SYNOPSIS
        Production build's only default allowed root: Join-Path $RepoRoot 'artifacts'.
        Never derived from PackageRoot's parent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw 'UNSAFE PATH REJECTED: RepoRoot is required to compute the fixed artifacts allowed root'
    }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot 'artifacts'))
}

function Assert-LocalPackageUnderFixedArtifactsRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $allowed = Get-LocalPackageFixedAllowedRoot -RepoRoot $RepoRoot
    return (Assert-LocalPackageSafePath -Path $PackageRoot -AllowedRoots @($allowed) -RepoRoot $RepoRoot)
}

function Test-LocalPackageSafePath {
    <#
    .SYNOPSIS
        Validates that a path is a canonical, non-root path strictly inside one
        of the explicitly allowed roots, and not the repository root.

    .DESCRIPTION
        Rules enforced before ANY recursive Remove-Item / Move-Item:
          1. non-empty
          2. canonical absolute path
          3. not a drive root
          4. not the repository root
          5. not equal to an allowed root itself (must be strictly INSIDE)
          6. does not escape the allowed root via .. segments
        Returns $true/$false plus a reason for diagnostics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedRoots,
        [string]$RepoRoot = ''
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ safe = $false; reason = 'empty path'; canonical_path = '' }
    }
    $canonical = [IO.Path]::GetFullPath(([string]$Path).Trim())
    $driveRoot = [IO.Path]::GetPathRoot($canonical)
    if ($driveRoot -and $canonical.TrimEnd('\', '/') -ieq $driveRoot.TrimEnd('\', '/')) {
        return [pscustomobject]@{ safe = $false; reason = "drive root is not deletable: $canonical"; canonical_path = $canonical }
    }
    if ($RepoRoot) {
        $repoCanonical = [IO.Path]::GetFullPath($RepoRoot)
        if ($canonical -ieq $repoCanonical) {
            return [pscustomobject]@{ safe = $false; reason = "repository root is not deletable: $canonical"; canonical_path = $canonical }
        }
    }
    $insideAllowed = $false
    foreach ($root in @($AllowedRoots)) {
        if ([string]::IsNullOrWhiteSpace([string]$root)) { continue }
        $rootBare = [IO.Path]::GetFullPath(([string]$root).Trim()).TrimEnd('\', '/')
        if ($canonical.TrimEnd('\', '/') -ieq $rootBare) {
            return [pscustomobject]@{ safe = $false; reason = "allowed root itself is not deletable: $canonical"; canonical_path = $canonical }
        }
        $rootCanonical = $rootBare + '\'
        if ($canonical.StartsWith($rootCanonical, [StringComparison]::OrdinalIgnoreCase)) {
            $insideAllowed = $true
            break
        }
    }
    if (-not $insideAllowed) {
        return [pscustomobject]@{ safe = $false; reason = "path is outside every allowed root: $canonical"; canonical_path = $canonical }
    }
    [pscustomobject]@{ safe = $true; reason = ''; canonical_path = $canonical }
}

function Assert-LocalPackageSafePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedRoots,
        [string]$RepoRoot = ''
    )
    $check = Test-LocalPackageSafePath -Path $Path -AllowedRoots $AllowedRoots -RepoRoot $RepoRoot
    if (-not $check.safe) {
        throw "UNSAFE PATH REJECTED: $($check.reason)"
    }
    return $check.canonical_path
}

function Assert-LocalPackageSafeOperationRoots {
    <#
    .SYNOPSIS
        Validates the staging / backup / package triple before any recursive
        move or delete: all three safe, pairwise distinct, none containing
        another.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$StagingPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PackageRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BackupRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedRoots,
        [string]$RepoRoot = ''
    )
    $staging = Assert-LocalPackageSafePath -Path $StagingPath -AllowedRoots $AllowedRoots -RepoRoot $RepoRoot
    $package = Assert-LocalPackageSafePath -Path $PackageRoot -AllowedRoots $AllowedRoots -RepoRoot $RepoRoot
    $backup = Assert-LocalPackageSafePath -Path $BackupRoot -AllowedRoots $AllowedRoots -RepoRoot $RepoRoot
    $paths = @(
        [pscustomobject]@{ role = 'staging'; value = $staging },
        [pscustomobject]@{ role = 'package'; value = $package },
        [pscustomobject]@{ role = 'backup'; value = $backup }
    )
    for ($i = 0; $i -lt $paths.Count; $i++) {
        for ($j = 0; $j -lt $paths.Count; $j++) {
            if ($i -eq $j) { continue }
            if ($paths[$i].value -ieq $paths[$j].value) {
                throw "UNSAFE PATH REJECTED: $($paths[$i].role) equals $($paths[$j].role): $($paths[$i].value)"
            }
            $prefix = $paths[$j].value.TrimEnd('\', '/') + '\'
            if ($paths[$i].value.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "UNSAFE PATH REJECTED: $($paths[$i].role) contains $($paths[$j].role): $($paths[$i].value) contains $($paths[$j].value)"
            }
        }
    }
    return [pscustomobject]@{ staging = $staging; package = $package; backup = $backup }
}

function Remove-LocalPackageDirectorySafely {
    <#
    .SYNOPSIS
        Recursive directory removal that PROVES the path is a canonical path
        inside an allowed root before touching the filesystem. Validation
        failure throws and nothing is deleted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedRoots,
        [string]$RepoRoot = ''
    )
    $canonical = Assert-LocalPackageSafePath -Path $Path -AllowedRoots $AllowedRoots -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $canonical) {
        Remove-Item -LiteralPath $canonical -Recurse -Force -ErrorAction Stop
    }
    return $canonical
}

# ---------------------------------------------------------------------------
# Binary replacement / file lock safety (AGENTS.md rule 9)
# ---------------------------------------------------------------------------

function Test-LocalPackageTargetWritable {
    <#
    .SYNOPSIS
        Proves that a target binary file can be replaced (no user process holds
        it) by attempting an exclusive open. Locked / access denied means an
        immediate FAIL: no retry, no wait, never a 30-minute stall.

    .DESCRIPTION
        Returns $true when the file is absent (nothing to lock) or can be
        opened with FileShare.None. Returns $false immediately on any
        IOException / UnauthorizedAccessException. This function never waits
        and never retries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetPaths
    )
    foreach ($path in @($TargetPaths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            return [pscustomobject]@{ writable = $false; locked_path = $path; reason = "target is locked or access denied: $($_.Exception.Message)" }
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    return [pscustomobject]@{ writable = $true; locked_path = $null; reason = '' }
}

# ---------------------------------------------------------------------------
# RESULT_READY wait with fail-fast terminal states
# ---------------------------------------------------------------------------

function Get-LocalResultTerminalFailure {
    # Terminal provider states that must abort any RESULT_READY wait
    # immediately. Waiting for RESULT_READY after one of these is forbidden.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$State)
    switch ($State) {
        'INTERRUPTED' { return 'attention state INTERRUPTED' }
        'ERROR' { return 'explicit error state' }
        'PROVIDER_FAILED' { return 'provider failed' }
        'PROVIDER_UNAVAILABLE' { return 'provider unavailable' }
        default { return $null }
    }
}

function Wait-LocalResultReady {
    <#
    .SYNOPSIS
        Bounded wait for RESULT_READY that fail-fasts on every terminal
        incompatible state: INTERRUPTED, ERROR, PROVIDER_FAILED,
        PROVIDER_UNAVAILABLE, unexpected exit of the observed process, and the
        overall deadline. On any of these it aborts immediately (throwing a
        FAIL/BLOCKED classification), never keeps waiting for RESULT_READY,
        and the caller's finally cleanup owns the entire process tree.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$Stage,
        [int]$TimeoutSeconds = 0,
        $Record = $null
    )
    $effectiveTimeout = Get-HarnessClippedTimeoutSeconds -Context $Context -RequestedSeconds $TimeoutSeconds -Stage $Stage
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($effectiveTimeout)
    while ($true) {
        Assert-HarnessDeadline -Context $Context -Stage $Stage
        if ($null -ne $Record -and -not (Test-HarnessProcessRecordAlive -Record $Record)) {
            throw "Fail-fast during ${Stage}: observed process PID $($Record.ProcessId) exited before RESULT_READY"
        }
        $state = ''
        if (Test-Path -LiteralPath $StatePath) {
            try { $state = ([string]([IO.File]::ReadAllText($StatePath))).Trim() } catch { $state = '' }
        }
        $terminal = Get-LocalResultTerminalFailure -State $state
        if ($terminal) {
            throw "Fail-fast during ${Stage}: terminal state $state ($terminal); aborting RESULT_READY wait"
        }
        if ($state -eq 'RESULT_READY') { return $true }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw "Timed out after ${effectiveTimeout}s waiting for $Stage RESULT_READY (last state '$state')"
        }
        Write-HarnessHeartbeat -Context $Context -Stage $Stage -Detail "state=$state"
        $now = [DateTimeOffset]::UtcNow
        $remainMs = [math]::Min(100, ($deadline - $now).TotalMilliseconds)
        $deadlineRemainMs = ($Context.Deadline - $now).TotalMilliseconds
        $slice = [math]::Min($remainMs, $deadlineRemainMs)
        if ($slice -le 0) { continue }
        Start-Sleep -Milliseconds ([int][math]::Max(1, $slice))
    }
}

# ---------------------------------------------------------------------------
# Build final verdict (single source of truth for the build exit code)
# ---------------------------------------------------------------------------

function Get-LocalBuildFinalVerdict {
    <#
    .SYNOPSIS
        Single terminal verdict for the package build. The process exit code is
        non-zero unless ALL of: build steps succeeded, promotion succeeded,
        cleanup succeeded, owned processes remaining == 0.

    .DESCRIPTION
        Replaces the historical "cleanup failed -> exitCode=1, then
        buildSucceeded -> exitCode=0" override. Write-Error side effects under
        ErrorActionPreference=Stop are never relied upon for the exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$BuildStepsSucceeded,
        [Parameter(Mandatory)][bool]$PromotionSucceeded,
        [Parameter(Mandatory)][bool]$CleanupSucceeded,
        [Parameter(Mandatory)][int]$OwnedProcessesRemaining
    )
    $failures = New-Object System.Collections.Generic.List[string]
    if (-not $BuildStepsSucceeded) { [void]$failures.Add('build steps failed') }
    if (-not $PromotionSucceeded) { [void]$failures.Add('promotion failed') }
    if (-not $CleanupSucceeded) { [void]$failures.Add('cleanup failed') }
    if ($OwnedProcessesRemaining -ne 0) { [void]$failures.Add("owned processes remaining: $OwnedProcessesRemaining") }
    [pscustomobject][ordered]@{
        success = ($failures.Count -eq 0)
        exit_code = if ($failures.Count -eq 0) { 0 } else { 1 }
        failures = [string[]]$failures.ToArray()
    }
}

# ---------------------------------------------------------------------------
# One-shot attempt marker (AGENTS.md rule 11)
# ---------------------------------------------------------------------------

function New-LocalSafetyAttemptMarker {
    <#
    .SYNOPSIS
        Atomically creates the one-shot attempt marker for an evidence root
        using [System.IO.FileMode]::CreateNew BEFORE any worker starts.

    .DESCRIPTION
        If the marker already exists the creation fails and the run must be
        refused: one attempt per evidence root, no -Force, no retry, no
        overwrite. The marker is never deleted after PASS, FAIL, BLOCKED,
        TIMEOUT or a supervisor crash; only its status fields may be updated
        atomically afterwards (Update-LocalSafetyAttemptMarker).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$SupervisorPid,
        [Parameter(Mandatory)][string]$SupervisorCreationTimeUtc
    )
    $payload = [ordered]@{
        run_id = $RunId
        attempt_number = 1
        created_at = [DateTimeOffset]::UtcNow.ToString('o')
        supervisor_pid = $SupervisorPid
        supervisor_creation_time = $SupervisorCreationTimeUtc
        status = 'STARTING'
        finished_at = $null
        final_status = $null
    }
    $json = $payload | ConvertTo-Json -Compress
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch [System.IO.IOException] {
        throw "REFUSING TO START: attempt marker already exists at $Path (one attempt per evidence root; there is no force/retry override)"
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    # Prove the marker is durable and readable before returning.
    $readBack = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$readBack.attempt_number -ne 1 -or [string]$readBack.status -ne 'STARTING') {
        throw "attempt marker verification failed at $Path"
    }
    return $readBack
}

function Update-LocalSafetyAttemptMarker {
    <#
    .SYNOPSIS
        Atomically updates ONLY the status fields of an existing attempt
        marker. run_id, attempt_number, created_at, supervisor_pid and
        supervisor_creation_time are never rewritten or reset; the marker is
        never deleted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('STARTING', 'RUNNING', 'FINISHED')][string]$Status,
        [ValidateSet('', 'OFFLINE', 'FAIL', 'BLOCKED', 'TIMEOUT', 'INCOMPLETE')][string]$FinalStatus = ''
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "attempt marker missing: $Path"
    }
    $existing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $existing.status = $Status
    if ($FinalStatus) { $existing.final_status = $FinalStatus }
    if ($Status -eq 'FINISHED') { $existing.finished_at = [DateTimeOffset]::UtcNow.ToString('o') }
    $dir = Split-Path -Parent $Path
    $id = [Guid]::NewGuid().ToString('N')
    $tmp = Join-Path $dir ('.attempt-' + $id + '.tmp')
    $backup = Join-Path $dir ('.attempt-' + $id + '.bak')
    $json = $existing | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    # .NET Framework (Windows PowerShell 5.1) File.Replace rejects a null
    # destinationBackupFileName with "The path is not of a legal form".
    # .NET Core allows null. Always pass a same-directory backup, then delete it.
    [System.IO.File]::Replace($tmp, $Path, $backup)
    try { [System.IO.File]::Delete($backup) } catch { }
    return $existing
}

function Read-LocalOwnedProcessRecords {
    <#
    .SYNOPSIS
        Reads the incremental owned-process records (PID + creation time) an
        offline worker flushed to a JSONL file, so an outer supervisor can
        verify exact residuals even after killing the worker.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return ,[object[]]@() }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            if ($null -ne $obj.process_id -and $null -ne $obj.process_started_at_unix_ms) {
                [void]$records.Add([pscustomobject]@{
                    ProcessId = [int]$obj.process_id
                    ProcessStartedAtUnixMs = [int64]$obj.process_started_at_unix_ms
                    Kind = [string]$obj.kind
                })
            }
        } catch { continue }
    }
    # Unary comma + ToArray: never `@($List[object])`, which throws in PS 5.1.
    return ,[object[]]$records.ToArray()
}

function Read-LocalSafetyAttemptMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "attempt marker missing: $Path"
    }
    $marker = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $marker) {
        throw "attempt marker unreadable: $Path"
    }
    return $marker
}

function Get-LocalSafetyStartGateConsumedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StartGatePath)
    $dir = Split-Path -Parent $StartGatePath
    return (Join-Path $dir 'start-gate.consumed.json')
}

function New-LocalSafetyStartGate {
    <#
    .SYNOPSIS
        Atomically creates the one-shot start gate AFTER the worker is Job-owned
        and the attempt marker is RUNNING. CreateNew: refuse if the file exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][int]$SupervisorPid,
        [Parameter(Mandatory)][string]$SupervisorCreationTimeUtc
    )
    $consumed = Get-LocalSafetyStartGateConsumedPath -StartGatePath $Path
    if (Test-Path -LiteralPath $consumed) {
        throw "REFUSING: start gate already consumed at $consumed"
    }
    $payload = [ordered]@{
        run_id = $RunId
        token = $Token
        supervisor_pid = [int]$SupervisorPid
        supervisor_creation_time = $SupervisorCreationTimeUtc
        created_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $json = $payload | ConvertTo-Json -Compress
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch [System.IO.IOException] {
        throw "REFUSING: start gate already exists at $Path"
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return $payload
}

function Test-LocalExactProcessAlive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$CreationTimeUtc
    )
    $ctime = [DateTimeOffset]::Parse($CreationTimeUtc)
    $record = [pscustomobject]@{
        ProcessId = [int]$ProcessId
        ProcessStartedAtUnixMs = [int64]$ctime.ToUnixTimeMilliseconds()
        Kind = 'supervisor-identity'
        Scenario = 'supervision-check'
        Launcher = $null
        Process = $null
    }
    return (Test-HarnessProcessRecordAlive -Record $record)
}

function Get-LocalSafetyStaleFileNames {
    <#
    .SYNOPSIS
        Pure single source of truth for the two-phase log-ownership protocol.

    .DESCRIPTION
        SupervisorPreLaunch: before the worker is launched, NONE of the six
        official output files may exist. The supervisor itself then creates
        the two transport logs (worker-stdout.log / worker-stderr.log) with
        FileMode.CreateNew inside SafeProcessLauncher, before the worker can
        execute any code.
        WorkerPostLaunch: the worker runs after that launch flow, so the two
        transport logs legitimately exist and belong to the CURRENT run; they
        must not be treated as stale evidence. The remaining four official
        outputs must still be absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('SupervisorPreLaunch', 'WorkerPostLaunch')][string]$Phase
    )
    $all = @(
        'worker-stdout.log',
        'worker-stderr.log',
        'worker-summary.json',
        'fixture-stream-stdout.log',
        'fixture-stream-stderr.log',
        'final-summary.json'
    )
    if ($Phase -eq 'SupervisorPreLaunch') { return [string[]]$all }
    $transport = @('worker-stdout.log', 'worker-stderr.log')
    $rest = New-Object System.Collections.Generic.List[string]
    foreach ($name in $all) {
        if ($transport -notcontains $name) { [void]$rest.Add($name) }
    }
    return [string[]]$rest.ToArray()
}

function Assert-LocalSafetyEvidenceRootHasNoStaleFiles {
    <#
    .SYNOPSIS
        Refuses stale official evidence files, phase-aware.

    .DESCRIPTION
        Phase SupervisorPreLaunch (used by the supervisor before launching the
        worker): all six official outputs must be absent.
        Phase WorkerPostLaunch (used inside the worker preflight): the two
        transport logs created by the CURRENT supervisor launch flow are
        allowed; the other four official outputs must still be absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][ValidateSet('SupervisorPreLaunch', 'WorkerPostLaunch')][string]$Phase,
        [string]$RunDirectory = ''
    )
    $names = Get-LocalSafetyStaleFileNames -Phase $Phase
    $roots = New-Object System.Collections.Generic.List[string]
    [void]$roots.Add($EvidenceRoot)
    if ($RunDirectory -and ($RunDirectory -ne $EvidenceRoot)) {
        [void]$roots.Add($RunDirectory)
    }
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($name in $names) {
            $candidate = Join-Path $root $name
            if (Test-Path -LiteralPath $candidate) {
                throw "REFUSING TO START ($Phase): stale evidence file already exists at $candidate (unique run directory required; will not append or overwrite)"
            }
        }
    }
}

function Get-LocalSafetyDeadlineVerdict {
    <#
    .SYNOPSIS
        Pure deadline verdict. Success is only allowed when the run finished
        at or before its ORIGINAL absolute deadline.

    .DESCRIPTION
        finished_at &gt; absolute_deadline_at (main flow, window checks or
        cleanup overrunning the outer deadline) forces timeout_detected=true,
        final_status=TIMEOUT and success_allowed=false, even when no other
        timeout was observed. The verdict is computed against the deadline
        fixed once after parameter parse; it is never recomputed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTimeOffset]$FinishedAt,
        [Parameter(Mandatory)][DateTimeOffset]$AbsoluteDeadlineAt,
        [Parameter(Mandatory)][bool]$BaseTimeoutDetected
    )
    $deadlineRespected = ($FinishedAt -le $AbsoluteDeadlineAt)
    $timeout = ([bool]$BaseTimeoutDetected) -or (-not $deadlineRespected)
    [pscustomobject][ordered]@{
        finished_at = $FinishedAt
        absolute_deadline_at = $AbsoluteDeadlineAt
        deadline_respected = [bool]$deadlineRespected
        timeout_detected = [bool]$timeout
        success_allowed = (-not $timeout)
        final_status = if ($timeout) { 'TIMEOUT' } else { 'OK' }
    }
}

function Invoke-LocalSafetyStartGateConsume {
    <#
    .SYNOPSIS
        Atomically consumes start-gate.json by renaming it to
        start-gate.consumed.json. If the consumed file already exists or the
        rename fails, refuse immediately.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StartGatePath,
        [Parameter(Mandatory)][string]$ExpectedToken,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][int]$ExpectedSupervisorPid,
        [Parameter(Mandatory)][string]$ExpectedSupervisorCreationTimeUtc
    )
    $consumedPath = Get-LocalSafetyStartGateConsumedPath -StartGatePath $StartGatePath
    if (Test-Path -LiteralPath $consumedPath) {
        throw "REFUSING: start gate already consumed at $consumedPath"
    }
    if (-not (Test-Path -LiteralPath $StartGatePath)) {
        throw "REFUSING: start gate missing at $StartGatePath"
    }
    try {
        [System.IO.File]::Move($StartGatePath, $consumedPath)
    } catch {
        throw "REFUSING: start gate consume failed (rename start-gate.json -> start-gate.consumed.json): $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $consumedPath)) {
        throw 'REFUSING: start gate consume did not produce start-gate.consumed.json'
    }
    if (Test-Path -LiteralPath $StartGatePath) {
        throw 'REFUSING: start gate source still exists after consume'
    }
    $gate = Get-Content -LiteralPath $consumedPath -Raw | ConvertFrom-Json
    if ($null -eq $gate) {
        throw 'REFUSING: consumed start gate is unreadable'
    }
    if ([string]$gate.token -cne [string]$ExpectedToken) {
        throw 'REFUSING: start gate token mismatch'
    }
    if ([string]$gate.run_id -cne [string]$ExpectedRunId) {
        throw 'REFUSING: start gate run_id mismatch'
    }
    if ([int]$gate.supervisor_pid -ne [int]$ExpectedSupervisorPid) {
        throw 'REFUSING: start gate supervisor pid mismatch'
    }
    if ([string]$gate.supervisor_creation_time -cne [string]$ExpectedSupervisorCreationTimeUtc) {
        throw 'REFUSING: start gate supervisor creation time mismatch'
    }
    return $gate
}

function Wait-LocalBoundedCondition {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][DateTimeOffset]$Deadline,
        [Parameter(Mandatory)][string]$Stage,
        [int]$SliceMilliseconds = 50
    )
    while (-not (& $Condition)) {
        $now = [DateTimeOffset]::UtcNow
        if ($now -ge $Deadline) {
            throw "Timed out waiting for $Stage"
        }
        $remainMs = ($Deadline - $now).TotalMilliseconds
        $slice = [math]::Min($SliceMilliseconds, $remainMs)
        if ($slice -le 0) {
            throw "Timed out waiting for $Stage"
        }
        Start-Sleep -Milliseconds ([int][math]::Max(1, $slice))
    }
}

function Invoke-LocalSafetyWorkerPreflight {
    <#
    .SYNOPSIS
        Worker entry gate. Must run before TEMP, Job Object, logs, or children.
        Refuses direct/unsupervised launch. Consumes the one-shot start gate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters,
        [Parameter(Mandatory)][bool]$Supervised,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$SupervisorPid,
        [Parameter(Mandatory)][string]$SupervisorCreationTimeUtc,
        [Parameter(Mandatory)][string]$AttemptMarkerPath,
        [Parameter(Mandatory)][string]$StartGatePath,
        [Parameter(Mandatory)][string]$StartGateToken,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][DateTimeOffset]$Deadline,
        [string]$RunDirectory = ''
    )

    if (-not $BoundParameters.ContainsKey('Supervised') -or -not $Supervised) {
        throw 'REFUSING TO START: worker must be launched by the supervisor with -Supervised; direct execution is forbidden'
    }
    foreach ($name in @('RunId', 'SupervisorPid', 'SupervisorCreationTimeUtc', 'AttemptMarkerPath', 'StartGatePath', 'StartGateToken', 'EvidenceRoot')) {
        if (-not $BoundParameters.ContainsKey($name)) {
            throw "REFUSING TO START: required supervision parameter -$name was not provided"
        }
    }
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'REFUSING TO START: RunId is empty' }
    if ([string]::IsNullOrWhiteSpace($StartGateToken)) { throw 'REFUSING TO START: StartGateToken is empty' }
    if (-not (Test-Path -LiteralPath $AttemptMarkerPath)) {
        throw "REFUSING TO START: attempt marker missing at $AttemptMarkerPath"
    }

    $marker = Read-LocalSafetyAttemptMarker -Path $AttemptMarkerPath
    if ([string]$marker.run_id -cne [string]$RunId) {
        throw 'REFUSING TO START: marker.run_id does not match -RunId'
    }
    if ([int]$marker.attempt_number -ne 1) {
        throw 'REFUSING TO START: marker.attempt_number must be 1'
    }
    if ([int]$marker.supervisor_pid -ne [int]$SupervisorPid) {
        throw 'REFUSING TO START: marker supervisor pid does not match -SupervisorPid'
    }
    if ([string]$marker.supervisor_creation_time -cne [string]$SupervisorCreationTimeUtc) {
        throw 'REFUSING TO START: marker supervisor creation time does not match'
    }
    if (-not (Test-LocalExactProcessAlive -ProcessId $SupervisorPid -CreationTimeUtc $SupervisorCreationTimeUtc)) {
        throw 'REFUSING TO START: supervisor PID+creation time is not alive'
    }

    $resolvedRunDirectory = $RunDirectory
    if ([string]::IsNullOrWhiteSpace($resolvedRunDirectory)) {
        $resolvedRunDirectory = Join-Path $EvidenceRoot $RunId
    }
    $resolvedRunDirectory = [IO.Path]::GetFullPath($resolvedRunDirectory)
    $evidenceCanonical = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/') + '\'
    if (-not $resolvedRunDirectory.StartsWith($evidenceCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        throw "REFUSING TO START: RunDirectory is outside EvidenceRoot: $resolvedRunDirectory"
    }

    # Phase WorkerPostLaunch: the two transport logs were created by THIS
    # supervisor launch flow (SafeProcessLauncher, FileMode.CreateNew) before
    # this worker executed any code; they are the worker's own live logs and
    # must not be mistaken for stale evidence.
    Assert-LocalSafetyEvidenceRootHasNoStaleFiles -EvidenceRoot $EvidenceRoot -RunDirectory $resolvedRunDirectory -Phase WorkerPostLaunch

    $consumedPath = Get-LocalSafetyStartGateConsumedPath -StartGatePath $StartGatePath
    while ($true) {
        if (Test-Path -LiteralPath $consumedPath) {
            throw "REFUSING TO START: start gate already consumed at $consumedPath"
        }
        if (Test-Path -LiteralPath $StartGatePath) { break }
        $latest = $null
        try { $latest = Read-LocalSafetyAttemptMarker -Path $AttemptMarkerPath } catch { $latest = $null }
        if ($null -ne $latest -and [string]$latest.status -eq 'FINISHED') {
            throw 'REFUSING TO START: attempt marker finished before start gate was created'
        }
        $now = [DateTimeOffset]::UtcNow
        if ($now -ge $Deadline) {
            throw 'REFUSING TO START: timed out waiting for supervisor start gate'
        }
        $remainMs = ($Deadline - $now).TotalMilliseconds
        $slice = [math]::Min(50, $remainMs)
        if ($slice -le 0) {
            throw 'REFUSING TO START: timed out waiting for supervisor start gate'
        }
        Start-Sleep -Milliseconds ([int][math]::Max(1, $slice))
    }
    $marker = Read-LocalSafetyAttemptMarker -Path $AttemptMarkerPath
    if ([string]$marker.status -ne 'RUNNING') {
        throw "REFUSING TO START: marker.status must be RUNNING before fixtures (was '$($marker.status)')"
    }
    if (-not (Test-LocalExactProcessAlive -ProcessId $SupervisorPid -CreationTimeUtc $SupervisorCreationTimeUtc)) {
        throw 'REFUSING TO START: supervisor PID+creation time died before start-gate consume'
    }

    $null = Invoke-LocalSafetyStartGateConsume -StartGatePath $StartGatePath `
        -ExpectedToken $StartGateToken -ExpectedRunId $RunId `
        -ExpectedSupervisorPid $SupervisorPid `
        -ExpectedSupervisorCreationTimeUtc $SupervisorCreationTimeUtc

    [pscustomobject][ordered]@{
        run_directory = $resolvedRunDirectory
        marker = $marker
        start_gate_consumed = $true
    }
}

function Test-LocalSafetyFinalSummaryConsistency {
    <#
    .SYNOPSIS
        Pure validation of a runner final-summary object. Returns a reason
        string on failure, or $null when the summary is internally consistent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Summary,
        $Marker = $null
    )
    if ($null -eq $Summary) { return 'summary is null' }
    $required = @(
        'schema_version',
        'generated_by',
        'run_id',
        'supervisor_pid',
        'supervisor_creation_time',
        'started_at',
        'finished_at',
        'actual_duration_ms',
        'absolute_deadline_at',
        'attempt_count',
        'worker_start_count',
        'start_gate_consumed',
        'automatic_retries'
    )
    foreach ($name in $required) {
        $prop = $Summary.PSObject.Properties[$name]
        if ($null -eq $prop) { return "missing field $name" }
    }
    if ([string]$Summary.generated_by -cne 'run-local-package-regressions.ps1') {
        return 'generated_by must be run-local-package-regressions.ps1'
    }
    try {
        $started = [DateTimeOffset]::Parse([string]$Summary.started_at)
        $finished = [DateTimeOffset]::Parse([string]$Summary.finished_at)
    } catch {
        return 'started_at/finished_at are not parseable timestamps'
    }
    $computed = [int][Math]::Round(($finished - $started).TotalMilliseconds)
    if ([int]$Summary.actual_duration_ms -ne $computed) {
        return "actual_duration_ms $($Summary.actual_duration_ms) != finished_at-started_at $computed"
    }
    if ([int]$Summary.attempt_count -ne 1) {
        return "attempt_count must be 1 (was $($Summary.attempt_count))"
    }
    if ([int]$Summary.worker_start_count -ne 1) {
        return "worker_start_count must be 1 (was $($Summary.worker_start_count))"
    }
    if ([int]$Summary.automatic_retries -ne 0) {
        return 'automatic_retries must be 0'
    }
    if ($null -ne $Marker) {
        if ([string]$Marker.run_id -cne [string]$Summary.run_id) {
            return 'marker run_id does not match summary run_id'
        }
    }
    return $null
}

function Assert-LocalSafetyFinalSummaryConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Summary,
        $Marker = $null
    )
    $reason = Test-LocalSafetyFinalSummaryConsistency -Summary $Summary -Marker $Marker
    if ($reason) {
        throw "REFUSING TO WRITE final-summary.json: $reason"
    }
}

function Write-LocalSafetyEvidenceJson {
    <#
    .SYNOPSIS
        Writes an official evidence JSON file with [System.IO.FileMode]::CreateNew.

    .DESCRIPTION
        Official evidence files (final-summary.json) must never be appended to
        or overwritten. If the target already exists the write is refused with
        an exception; FileMode.Append is never used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $json = $Object | ConvertTo-Json -Depth 12
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch [System.IO.IOException] {
        throw "REFUSING TO WRITE: evidence file already exists at $Path (CreateNew only; no overwrite, no append)"
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-LocalSafetyMarkerSummaryAgreement {
    <#
    .SYNOPSIS
        Pure terminal-state validation that the attempt marker and the final
        summary agree. Returns a reason string on failure, or $null when the
        terminal state is consistent.

    .DESCRIPTION
        A consumer may only trust a run when BOTH the marker and the summary
        agree: same run_id, marker.status=FINISHED, marker.final_status equal
        to summary.final_status, and summary duration consistent with its own
        timestamps. Any mismatch means the run can only be treated as
        INCOMPLETE.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Summary,
        [AllowNull()]$Marker = $null
    )
    if ($null -eq $Summary) { return 'summary is null' }
    if ($null -eq $Marker) { return 'marker is null' }
    if ([string]$Marker.run_id -cne [string]$Summary.run_id) {
        return ("marker run_id '{0}' does not match summary run_id '{1}'" -f $Marker.run_id, $Summary.run_id)
    }
    if ([string]$Marker.status -cne 'FINISHED') {
        return ("marker.status must be FINISHED (was '{0}')" -f $Marker.status)
    }
    if ([string]::IsNullOrWhiteSpace([string]$Marker.final_status)) {
        return 'marker.final_status is empty'
    }
    if ([string]$Marker.final_status -cne [string]$Summary.final_status) {
        return ("marker.final_status '{0}' does not match summary.final_status '{1}'" -f $Marker.final_status, $Summary.final_status)
    }
    try {
        $started = [DateTimeOffset]::Parse([string]$Summary.started_at)
        $finished = [DateTimeOffset]::Parse([string]$Summary.finished_at)
        $markerFinished = [DateTimeOffset]::Parse([string]$Marker.finished_at)
    } catch {
        return 'marker/summary timestamps are not parseable'
    }
    $computed = [int][Math]::Round(($finished - $started).TotalMilliseconds)
    if ([int]$Summary.actual_duration_ms -ne $computed) {
        return ("actual_duration_ms {0} != finished_at-started_at {1}" -f $Summary.actual_duration_ms, $computed)
    }
    if ($markerFinished -lt $started) {
        return 'marker.finished_at is earlier than summary.started_at'
    }
    $now = [DateTimeOffset]::UtcNow
    if ($markerFinished -gt $now.AddSeconds(5)) {
        return 'marker.finished_at is in the future beyond clock skew'
    }
    return $null
}

function Assert-LocalSafetyMarkerSummaryAgreement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Summary,
        [AllowNull()]$Marker = $null
    )
    $reason = Test-LocalSafetyMarkerSummaryAgreement -Summary $Summary -Marker $Marker
    if ($reason) {
        throw "MARKER/SUMMARY TERMINAL STATE INCONSISTENT (run may only be treated as INCOMPLETE): $reason"
    }
}
