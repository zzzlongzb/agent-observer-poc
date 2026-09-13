# Daily-use Local Package v0.1 Repair 2 acceptance supervisor.
#
# Runs the real, from-disk package acceptance for artifacts\agent-observer-hud-poc:
#   - manifest integrity against a fresh disposable copy outside the repository
#   - cargo fmt --check,
#     cargo test --bin agent-observer-poc --locked --offline -- --test-threads=4,
#     dotnet build hud\AgentObserver.Hud\AgentObserver.Hud.csproj -warnaserror --no-restore,
#     HUD self-tests from the packaged exe
#   - double-click-equivalent direct exe launch (no launcher scripts)
#   - exactly one Observer child with MainWindowHandle = 0 and no visible terminals
#   - single-instance: second launch exits quietly within 5s, no second Observer
#   - graceful close terminates the owned Observer
#   - missing agent-observer-poc.exe keeps the HUD alive on the Observer
#     unavailable state
#   - final residual process / visible window check
#
# Repair 2 changes:
#   - every external process (cargo, dotnet, HUD self-test, main HUD, screenshot
#     HUD, missing-observer HUD, second instance) is launched, bounded and
#     terminated through the shared production helper
#     tools/local-package-harness.ps1 -> tools/harness-lifecycle.ps1:
#     kill-on-close Job Object, PID + process creation time ownership records,
#     a 180s overall hard deadline and per-step clipped timeouts. There is no
#     Process.Kill($true) anywhere and no parent-PID-only kill as the last
#     action; the Job Object guarantees full owned-tree termination, and the
#     final cleanup verifies every recorded PID + creation time is gone. Any
#     cleanup failure forces FAIL.
#   - evidence no longer hardcodes network_requests=0. The offline facts that
#     are actually enforceable are recorded (network_access_permitted=false,
#     cargo_offline_enforced=true, dotnet_restore_disabled=true) and
#     network_requests_observed stays null because no network monitoring ran.
#
# Window auditing reuses the accepted visibility-audit method (EnumWindows
# baseline vs observed diff, attribution restricted to the owned PID tree).
# Process cleanup only ever touches PIDs recorded by this run together with
# their creation times; it never ends processes by name.

[CmdletBinding()]
param(
    [string]$RunId = '',
    [string]$PackageRoot = '',
    [string]$EvidenceRoot = '',
    [ValidateRange(30, 300)][int]$OverallDeadlineSeconds = 180,

    # ------------------------------------------------------------------
    # Targeted candidate ZIP verification mode (package-only, no build).
    # Full acceptance mode is the default and completely unchanged.
    # ------------------------------------------------------------------
    [ValidateSet('Full', 'TargetedZip')][string]$Mode = 'Full',
    [string]$CandidateZip = '',
    [string]$ExpectedZipSha256 = '',
    [long]$ExpectedZipSizeBytes = 0,
    [ValidateRange(30, 300)][int]$TargetedOuterDeadlineSeconds = 240,
    [ValidateRange(30, 300)][int]$TargetedWorkerDeadlineSeconds = 210,
    # Worker-role parameters. They are only ever passed by the TargetedZip
    # supervisor below (same script, relaunched with -Supervised); the worker
    # preflight refuses any execution without a consumed one-shot start gate.
    [switch]$Supervised,
    [int]$SupervisorPid = 0,
    [string]$SupervisorCreationTimeUtc = '',
    [string]$AttemptMarkerPath = '',
    [string]$StartGatePath = '',
    [string]$StartGateToken = '',
    [string]$RunDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$startedAt = [DateTimeOffset]::UtcNow
if (-not $RunId) {
    $RunId = ("{0:yyyyMMddTHHmmssfffZ}-{1}" -f $startedAt.UtcDateTime, ([Guid]::NewGuid().ToString('n')))
}

# ---------------------------------------------------------------------------
# Targeted candidate ZIP verification mode (acceptance attempt 2).
#
# Package-only re-verification of an existing candidate ZIP; it never builds,
# downloads, or modifies product code, snapshots, the ZIP, or historical
# evidence. The Full acceptance path below this block is unchanged.
#
# Roles:
#   -Mode TargetedZip (operator entry, no -Supervised): outer supervisor.
#       Refuses to start while any AgentObserver.Hud instance is running
#       (the operator must close it normally first). Creates a unique
#       evidence root with a one-shot attempt marker (CreateNew), launches
#       THIS script as a hidden, Job-owned, bounded worker child, creates the
#       one-shot start gate only after the worker is Job-owned and the marker
#       is RUNNING, waits against a single absolute outer deadline, runs
#       baseline/final visible-console probes, verifies residuals by exact
#       PID + creation time, and writes final-summary.json from one single
#       terminal path (marker/summary agreement protocol). Supervisor-level
#       hard process cutoff is UNPROVEN under PowerShell, which is why the
#       outer deadline is also enforced by how this script is invoked.
#
#   -Mode TargetedZip -Supervised ... (worker, supervisor-launched only):
#       Preflight refuses direct execution and consumes the start gate. Then:
#       ZIP identity (SHA-256 + size) -> extraction into a unique TEMP
#       directory outside the repository whose name contains spaces and
#       Chinese characters -> package-manifest.json path + hash verification
#       -> packaged Observer `doctor --json` hidden and bounded (30s) -> ONE
#       30s HUD smoke (--close-after-ms 30000) launched directly from the
#       extracted EXE with AGENT_OBSERVER_EXE cleared in the child
#       environment only, with visible-window and foreground sampling
#       restricted to this run's process tree -> proof that the exact
#       Observer child (PID + creation time) exits after the HUD close BEFORE
#       the final kill-on-close Job cleanup. The kill-on-close Job cleanup is
#       only a backstop and can never be presented as the graceful-close
#       proof. First visible console window owned by this run stops the run
#       immediately.
# ---------------------------------------------------------------------------
if ($Mode -eq 'TargetedZip') {
    . (Join-Path $PSScriptRoot 'local-package-harness.ps1')
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:TargetedUtf8 = [Text.UTF8Encoding]::new($false)
    $script:TargetedConsoleHostNames = @('conhost.exe', 'openterminal.exe', 'windowsterminal.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe')

    function Write-TargetedJson {
        # Official evidence writer: FileMode.CreateNew ONLY. Overwriting or
        # appending an existing evidence file is refused (rule 16); every
        # evidence file must live in its unique run directory and be written
        # exactly once.
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
        $json = $Object | ConvertTo-Json -Depth 12
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        catch [System.IO.IOException] {
            throw "REFUSING TO WRITE: evidence file already exists at $Path (CreateNew only; no overwrite, no append)"
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    function Get-TargetedFileSha256 {
        # .NET hashing on purpose: Get-FileHash depends on module auto-loading
        # that a polluted PSModulePath can break in nested worker processes.
        param([Parameter(Mandatory)][string]$Path)
        $provider = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stream = [System.IO.File]::OpenRead($Path)
            try { $hashBytes = $provider.ComputeHash($stream) } finally { $stream.Dispose() }
        }
        finally { $provider.Dispose() }
        $builder = New-Object System.Text.StringBuilder
        foreach ($byte in $hashBytes) { [void]$builder.Append($byte.ToString('x2')) }
        return $builder.ToString()
    }

    function Add-TargetedStep {
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Pass, [string]$Detail = '', [long]$DurationMs = 0)
        [void]$script:TargetedSteps.Add([pscustomobject][ordered]@{
            name = $Name; pass = $Pass; detail = $Detail; duration_ms = $DurationMs
        })
        if (-not $Pass) { [void]$script:TargetedFailures.Add($Name) }
    }

    function Get-TargetedProcessRows {
        return @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, CreationDate, Name, ExecutablePath)
    }

    function Get-TargetedTreePids {
        param([Parameter(Mandatory)][int]$RootPid, [Parameter(Mandatory)][AllowEmptyCollection()]$Rows)
        $wanted = New-Object 'System.Collections.Generic.HashSet[int]'
        [void]$wanted.Add($RootPid)
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($row in @($Rows)) {
                $procId = [int]$row.ProcessId
                $parent = [int]$row.ParentProcessId
                if ($wanted.Contains($parent) -and -not $wanted.Contains($procId)) {
                    [void]$wanted.Add($procId)
                    $changed = $true
                }
            }
        }
        return , ([int[]]$wanted)
    }

    function Get-TargetedProcessNameById {
        param([Parameter(Mandatory)][int]$PidValue, $Rows = $null)
        if ($null -ne $Rows) {
            foreach ($row in @($Rows)) {
                if ([int]$row.ProcessId -eq $PidValue) { return (([string]$row.Name).ToLowerInvariant()) }
            }
        }
        try {
            $p = [Diagnostics.Process]::GetProcessById($PidValue)
            try { return $p.ProcessName.ToLowerInvariant() } finally { $p.Dispose() }
        }
        catch { return '' }
    }

    function Get-TargetedProcessLiveness {
        # Tri-state liveness by exact PID + process creation time (unix ms) for
        # processes this run DISCOVERED but did not launch (the Observer child
        # of the HUD). A query failure must never be turned into an exit proof:
        #   'exited' : the OS reports no such PID, the handle reports HasExited,
        #              or the PID now belongs to a different creation instance
        #              (PID reuse) - the ONLY states that prove OUR process is
        #              gone and may be used as exit evidence.
        #   'alive'  : PID exists and the creation time matches exactly.
        #   'unknown': the process was found but its exit state / creation time
        #              could not be read, or the query itself failed. Callers
        #              must treat 'unknown' as UNPROVEN and fail closed (never
        #              as an exit, never as success).
        # This deliberately does NOT delegate to Test-HarnessProcessRecordAlive:
        # that shared predicate returns $false both for a dead process and for
        # a failed creation-time read, which is fine for launcher-backed
        # records but ambiguous for exit PROOFS.
        param(
            [Parameter(Mandatory)][int]$PidValue,
            [Parameter(Mandatory)][long]$StartedAtUnixMs
        )
        $process = $null
        try {
            $process = [Diagnostics.Process]::GetProcessById($PidValue)
        }
        catch [System.ArgumentException] {
            # GetProcessById explicitly reports that no such PID exists.
            return 'exited'
        }
        catch {
            return 'unknown'
        }
        try {
            $process.Refresh()
            if ($process.HasExited) { return 'exited' }
            $actual = [int64](([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds())
            if ($actual -ne $StartedAtUnixMs) { return 'exited' }
            return 'alive'
        }
        catch {
            return 'unknown'
        }
        finally {
            $process.Dispose()
        }
    }

    function Get-TargetedVisibleWindowIds {
        try { return , @([AgentObserverTargeted.WindowProbe]::VisibleWindowProcessIds() | Sort-Object -Unique) }
        catch {
            $script:TargetedWindowProbeFailure = [string]$_.Exception.Message
            return $null
        }
    }

    function Get-TargetedForegroundWindowProcessId {
        try { return [int][AgentObserverTargeted.WindowProbe]::ForegroundWindowProcessId() }
        catch {
            $script:TargetedWindowProbeFailure = [string]$_.Exception.Message
            return -1
        }
    }

    function Remove-TargetedTempDirectory {
        # Canonical containment + reparse-point rejection before ANY recursive
        # delete. SINGLE attempt, no retry loop: an access denied, a sharing
        # violation (file lock, surfaced as IOException) or any other delete
        # failure is an immediate cleanup failure that FAILS the run. Never
        # retried, never waited out.
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AllowedRoot)
        $canonical = Assert-LocalPackageSafePath -Path $Path -AllowedRoots @($AllowedRoot) -RepoRoot $script:RepoRoot
        if (-not (Test-Path -LiteralPath $canonical)) { return $true }
        $rootItem = Get-Item -LiteralPath $canonical -Force
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "reparse point refused: $canonical"
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $canonical -Recurse -Force)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ("reparse point refused: " + $item.FullName)
            }
        }
        Remove-Item -LiteralPath $canonical -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $canonical) {
            throw "temp directory removal did not complete: $canonical"
        }
        return $true
    }

    function Invoke-TargetedWindowProbeHelper {
        # Job-owned, bounded helper child that enumerates visible console-host
        # window PIDs (reuses tools/local-package-window-probe-helper.ps1).
        param([Parameter(Mandatory)]$Lifecycle, [Parameter(Mandatory)][string]$OutputPath, [Parameter(Mandatory)][string]$Stage)
        $result = [pscustomobject][ordered]@{ status = 'UNKNOWN'; ids = [int[]]@(); error = $null }
        $helperScript = Join-Path $PSScriptRoot 'local-package-window-probe-helper.ps1'
        if (-not (Test-Path -LiteralPath $helperScript)) {
            $result.error = "window probe helper missing: $helperScript"
            return $result
        }
        try {
            Assert-HarnessDeadline -Context $Lifecycle -Stage $Stage
            $remainMs = Get-HarnessRemainingMilliseconds -Context $Lifecycle
            if ($remainMs -lt 200) { $result.error = 'insufficient remaining time for window probe helper'; return $result }
            $timeoutSeconds = 3
            if ($remainMs -lt 3000) { $timeoutSeconds = [int][Math]::Max(1, [int][Math]::Floor($remainMs / 1000.0)) }
            $helper = Start-HarnessProcess -Context $Lifecycle -FilePath (Join-Path $PSHOME 'powershell.exe') `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $helperScript, `
                    '-OutputPath', $OutputPath, '-DeadlineSeconds', [string]$timeoutSeconds) `
                -Kind ("window-probe-" + $Stage) -Scenario 'targeted-zip-verification' `
                -WorkingDirectory $script:RepoRoot
            try { $null = Wait-HarnessProcess -Context $Lifecycle -Record $helper.Record -Stage $Stage -TimeoutSeconds $timeoutSeconds }
            catch { $result.error = [string]$_.Exception.Message; return $result }
            if (-not (Test-Path -LiteralPath $OutputPath)) { $result.error = 'window probe helper produced no output'; return $result }
            $parsed = $null
            try { $parsed = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $parsed = $null }
            if ($null -eq $parsed -or [string]$parsed.status -ne 'ok') {
                $result.error = 'window probe helper status not ok'
                return $result
            }
            $result.status = 'ok'
            $result.ids = ConvertTo-LocalInt32IdArray -Value $parsed.ids
            return $result
        }
        catch {
            $result.error = [string]$_.Exception.Message
            return $result
        }
    }

    if ($Supervised) {
        # =================================================================
        # WORKER ROLE (supervisor-launched only; direct execution refused)
        # =================================================================
        $workerStartedAt = [DateTimeOffset]::UtcNow
        $workerDeadline = $workerStartedAt.AddSeconds($TargetedWorkerDeadlineSeconds)
        $script:TargetedSteps = New-Object System.Collections.Generic.List[object]
        $script:TargetedFailures = New-Object System.Collections.Generic.List[string]
        $script:TargetedExecutedCommands = New-Object System.Collections.Generic.List[object]
        $script:TargetedVisibleObservations = New-Object System.Collections.Generic.List[object]
        $script:TargetedForegroundSamples = New-Object System.Collections.Generic.List[object]
        $script:TargetedObserverExitSamples = New-Object System.Collections.Generic.List[object]
        $script:TargetedWindowProbeFailure = $null
        $workerTimeoutDetected = $false

        # Non-interactive refusal BEFORE any side effect.
        $missingWorkerParams = New-Object System.Collections.Generic.List[string]
        if ([string]::IsNullOrWhiteSpace($RunId)) { [void]$missingWorkerParams.Add('-RunId') }
        if ($SupervisorPid -le 0) { [void]$missingWorkerParams.Add('-SupervisorPid') }
        if ([string]::IsNullOrWhiteSpace($SupervisorCreationTimeUtc)) { [void]$missingWorkerParams.Add('-SupervisorCreationTimeUtc') }
        if ([string]::IsNullOrWhiteSpace($AttemptMarkerPath)) { [void]$missingWorkerParams.Add('-AttemptMarkerPath') }
        if ([string]::IsNullOrWhiteSpace($StartGatePath)) { [void]$missingWorkerParams.Add('-StartGatePath') }
        if ([string]::IsNullOrWhiteSpace($StartGateToken)) { [void]$missingWorkerParams.Add('-StartGateToken') }
        if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { [void]$missingWorkerParams.Add('-EvidenceRoot') }
        if ([string]::IsNullOrWhiteSpace($CandidateZip)) { [void]$missingWorkerParams.Add('-CandidateZip') }
        if ($missingWorkerParams.Count -gt 0) {
            [Console]::Error.WriteLine(("REFUSING TO START: missing parameter(s): {0}" -f ($missingWorkerParams -join ', ')))
            exit 2
        }

        try {
            $preflight = Invoke-LocalSafetyWorkerPreflight -BoundParameters $PSBoundParameters `
                -Supervised:([bool]$Supervised) -RunId $RunId -SupervisorPid $SupervisorPid `
                -SupervisorCreationTimeUtc $SupervisorCreationTimeUtc `
                -AttemptMarkerPath $AttemptMarkerPath -StartGatePath $StartGatePath `
                -StartGateToken $StartGateToken -EvidenceRoot $EvidenceRoot `
                -Deadline $workerDeadline -RunDirectory $RunDirectory
        }
        catch {
            [Console]::Error.WriteLine(("REFUSING TO START: {0}" -f [string]$_.Exception.Message))
            exit 2
        }
        $workerRunDir = [string]$preflight.run_directory

        # Child-scoped environment override ONLY: clear AGENT_OBSERVER_EXE in
        # THIS worker process so every child it launches (HUD -> Observer)
        # resolves the packaged exe. The user/machine environments are never
        # touched; the supervisor process environment is not affected either.
        $agentObserverExeBefore = [string]$env:AGENT_OBSERVER_EXE
        $agentObserverExeCleared = $false
        if (-not [string]::IsNullOrWhiteSpace($agentObserverExeBefore)) {
            Remove-Item Env:AGENT_OBSERVER_EXE -ErrorAction Stop
            $agentObserverExeCleared = $true
        }

        # Window probe with foreground sampling (added only after the start
        # gate was consumed, so no TEMP artifact exists before verification).
        if (-not ('AgentObserverTargeted.WindowProbe' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AgentObserverTargeted
{
    public static class WindowProbe
    {
        private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        public static int[] VisibleWindowProcessIds()
        {
            var ids = new HashSet<int>();
            var succeeded = EnumWindows((window, parameter) =>
            {
                if (IsWindowVisible(window))
                {
                    uint processId;
                    GetWindowThreadProcessId(window, out processId);
                    if (processId != 0)
                        ids.Add((int)processId);
                }
                return true;
            }, IntPtr.Zero);
            if (!succeeded)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed");
            var result = new int[ids.Count];
            ids.CopyTo(result);
            return result;
        }

        public static int ForegroundWindowProcessId()
        {
            IntPtr window = GetForegroundWindow();
            if (window == IntPtr.Zero) return 0;
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            return (int)processId;
        }
    }
}
'@
        }

        $context = New-HarnessLifecycle -Name 'targeted-zip-worker' -RunRoot $workerRunDir `
            -Scenario 'targeted-zip-verification' -OverallTimeoutSeconds $TargetedWorkerDeadlineSeconds `
            -HeartbeatSeconds 10 -StartedAt $workerStartedAt -AbsoluteDeadlineAt $workerDeadline

        # Executed-script version record (this exact file + parameters).
        $script:TargetedScriptSha256 = Get-TargetedFileSha256 -Path $PSCommandPath
        Write-TargetedJson -Path (Join-Path $workerRunDir 'worker-invocation.json') -Object ([ordered]@{
            run_id = $RunId
            mode = 'TargetedZip'
            role = 'worker'
            script_path = $PSCommandPath
            script_sha256 = $script:TargetedScriptSha256
            parameters = [ordered]@{
                candidate_zip = $CandidateZip
                expected_zip_sha256 = $ExpectedZipSha256
                expected_zip_size_bytes = $ExpectedZipSizeBytes
                worker_deadline_seconds = $TargetedWorkerDeadlineSeconds
                evidence_root = $EvidenceRoot
                run_directory = $workerRunDir
            }
            agent_observer_exe_before = $agentObserverExeBefore
            agent_observer_exe_cleared_for_children = $agentObserverExeCleared
            started_at = $workerStartedAt.ToString('o')
            absolute_deadline_at = $workerDeadline.ToString('o')
        })

        $extractDir = $null
        $tempRootPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $zipStageStartedAt = [DateTimeOffset]::UtcNow
        $zipIdentity = $null
        $extractionInfo = $null
        $manifestInfo = $null
        $doctorInfo = $null
        $hudInfo = $null
        $observerInfo = $null
        $windowObservationSummary = $null
        $anyFailed = $false
        $failureDetail = ''
        $stoppedAt = 'worker-top-level'

        try {
            # ---------------------------------------------------------------
            # 1. Candidate ZIP identity (SHA-256 + exact byte size)
            # ---------------------------------------------------------------
            Assert-HarnessDeadline -Context $context -Stage 'zip-identity'
            $stoppedAt = 'zip-identity'
            $zipItem = Get-Item -LiteralPath $CandidateZip
            $zipHash = Get-TargetedFileSha256 -Path $CandidateZip
            $zipSizeOk = ([long]$zipItem.Length -eq [long]$ExpectedZipSizeBytes)
            $zipHashOk = ($zipHash -ieq ([string]$ExpectedZipSha256).Trim())
            $zipIdentity = [ordered]@{
                path = [string]$CandidateZip
                size_bytes = [long]$zipItem.Length
                expected_size_bytes = [long]$ExpectedZipSizeBytes
                sha256 = $zipHash
                expected_sha256 = ([string]$ExpectedZipSha256).Trim()
                size_match = $zipSizeOk
                sha256_match = $zipHashOk
            }
            Add-TargetedStep -Name 'candidate ZIP identity (SHA-256 + size)' -Pass ($zipSizeOk -and $zipHashOk) `
                -Detail ("sha256_match=$zipHashOk size_match=$zipSizeOk") `
                -DurationMs ([int]([DateTimeOffset]::UtcNow - $zipStageStartedAt).TotalMilliseconds)
            if (-not ($zipSizeOk -and $zipHashOk)) {
                throw ("candidate ZIP identity mismatch (hash_match=$zipHashOk size_match=$zipSizeOk); refusing to continue")
            }

            # ---------------------------------------------------------------
            # 2. Extraction into a unique TEMP directory outside the repository,
            #    whose name contains spaces and Chinese characters.
            # ---------------------------------------------------------------
            Assert-HarnessDeadline -Context $context -Stage 'extraction'
            $stoppedAt = 'extraction'
            $extractStartedAt = [DateTimeOffset]::UtcNow
            $drive = New-Object System.IO.DriveInfo ($tempRootPath.Substring(0, 3))
            if ($drive.AvailableFreeSpace -lt 600MB) {
                throw ("insufficient free disk space for the 500 MiB temp budget: {0} bytes free at {1}" -f $drive.AvailableFreeSpace, $tempRootPath)
            }
            # Directory name built from char codes so it stays correct regardless
            # of the script file's encoding: the codes spell "yan shou du li hou xuan
            # bao" (acceptance standalone candidate package) in Chinese, plus a space.
            $extractDirName = ((-join @([char]0x9A8C, [char]0x6536, [char]0x72EC, [char]0x7ACB, [char]0x5019, [char]0x9009, [char]0x5305)) + ' ' + $RunId)
            $extractDir = Join-Path $tempRootPath $extractDirName
            $extractDir = Assert-LocalPackageSafePath -Path $extractDir -AllowedRoots @($tempRootPath) -RepoRoot $script:RepoRoot
            if (Test-Path -LiteralPath $extractDir) { throw "extract directory already exists: $extractDir" }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zipEntryCount = 0
            $zipBackslashEntryCount = 0
            $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($CandidateZip)
            try {
                foreach ($entry in $zipArchive.Entries) {
                    $zipEntryCount++
                    $fullName = [string]$entry.FullName
                    if ($fullName.Contains('..')) { throw ("unsafe ZIP entry refused: " + $fullName) }
                    if ($fullName.Contains('\')) { $zipBackslashEntryCount++ }
                }
            }
            finally { $zipArchive.Dispose() }
            [System.IO.Compression.ZipFile]::ExtractToDirectory($CandidateZip, $extractDir)
            $extractedFileCount = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File).Count
            $extractedDirCount = @(Get-ChildItem -LiteralPath $extractDir -Recurse -Directory).Count
            $outsideRepo = -not ($extractDir.StartsWith($script:RepoRoot, [StringComparison]::OrdinalIgnoreCase))
            $extractionInfo = [ordered]@{
                temp_root = $tempRootPath
                extract_dir = $extractDir
                extract_dir_name = $extractDirName
                dir_name_contains_chinese = $true
                dir_name_contains_space = $true
                outside_repository = $outsideRepo
                free_disk_bytes_before = [long]$drive.AvailableFreeSpace
                zip_entry_count = $zipEntryCount
                zip_backslash_entry_count = $zipBackslashEntryCount
                extracted_file_count = $extractedFileCount
                extracted_directory_count = $extractedDirCount
                duration_ms = [int]([DateTimeOffset]::UtcNow - $extractStartedAt).TotalMilliseconds
            }
            Add-TargetedStep -Name 'extraction to unique TEMP dir (Chinese + spaces, outside repo)' -Pass ($outsideRepo) `
                -Detail ("entries=$zipEntryCount backslash_entries=$zipBackslashEntryCount files=$extractedFileCount dirs=$extractedDirCount") `
                -DurationMs ([int]([DateTimeOffset]::UtcNow - $extractStartedAt).TotalMilliseconds)
            if (-not $outsideRepo) { throw "extract directory is not outside the repository: $extractDir" }

            # ---------------------------------------------------------------
            # 3. package-manifest.json path + hash verification
            # ---------------------------------------------------------------
            Assert-HarnessDeadline -Context $context -Stage 'manifest'
            $stoppedAt = 'manifest'
            $manifestStartedAt = [DateTimeOffset]::UtcNow
            $manifestPath = Join-Path $extractDir 'package-manifest.json'
            if (-not (Test-Path -LiteralPath $manifestPath)) { throw "package manifest missing: $manifestPath" }
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifestFiles = @($manifest.files)
            $manifestMissing = New-Object System.Collections.Generic.List[string]
            $manifestMismatch = New-Object System.Collections.Generic.List[string]
            foreach ($entry in $manifestFiles) {
                $entryPath = Join-Path $extractDir ([string]$entry.path)
                if (-not (Test-Path -LiteralPath $entryPath)) { [void]$manifestMissing.Add([string]$entry.path); continue }
                $actual = Get-TargetedFileSha256 -Path $entryPath
                if ($actual -ine [string]$entry.sha256) { [void]$manifestMismatch.Add([string]$entry.path) }
            }
            $manifestAllMatch = (($manifestMissing.Count -eq 0) -and ($manifestMismatch.Count -eq 0))
            $manifestInfo = [ordered]@{
                manifest_path = $manifestPath
                listed_file_count = $manifestFiles.Count
                verified_file_count = ($manifestFiles.Count - $manifestMissing.Count - $manifestMismatch.Count)
                missing_files = @($manifestMissing.ToArray())
                hash_mismatch_files = @($manifestMismatch.ToArray())
                all_match = $manifestAllMatch
                duration_ms = [int]([DateTimeOffset]::UtcNow - $manifestStartedAt).TotalMilliseconds
            }
            Add-TargetedStep -Name ('manifest integrity ({0} files)' -f $manifestFiles.Count) -Pass $manifestAllMatch `
                -Detail ("missing={0} mismatched={1}" -f $manifestMissing.Count, $manifestMismatch.Count) `
                -DurationMs $manifestInfo.duration_ms
            if (-not $manifestAllMatch) {
                throw ("manifest verification failed: missing={0} mismatched={1}" -f $manifestMissing.Count, $manifestMismatch.Count)
            }
            $zipStageMs = [int]([DateTimeOffset]::UtcNow - $zipStageStartedAt).TotalMilliseconds
            $zipBudgetRespected = ($zipStageMs -le 60000)
            Add-TargetedStep -Name 'zip identity+extraction+manifest within 60s budget' -Pass $zipBudgetRespected -Detail "stage_ms=$zipStageMs"

            # ---------------------------------------------------------------
            # 4. Packaged Observer doctor --json (hidden, bounded 30s)
            # ---------------------------------------------------------------
            Assert-HarnessDeadline -Context $context -Stage 'doctor'
            $stoppedAt = 'doctor'
            $observerExe = Join-Path $extractDir 'agent-observer-poc.exe'
            if (-not (Test-Path -LiteralPath $observerExe)) { throw "packaged observer exe missing: $observerExe" }
            $visibleBeforeDoctor = Get-TargetedVisibleWindowIds
            [void]$script:TargetedExecutedCommands.Add([pscustomobject][ordered]@{
                tool = $observerExe; arguments = @('doctor', '--json'); kind = 'observer-doctor'; hidden = $true; timeout_seconds = 30
            })
            $doctorStartedAt = [DateTimeOffset]::UtcNow
            $doctorRun = Start-LocalHarnessProcess -Context $context -FilePath $observerExe `
                -ArgumentList @('doctor', '--json') -Kind 'observer-doctor' -WorkingDirectory $extractDir `
                -Scenario 'targeted-zip-verification' -HideConsoleWindow `
                -StdoutLogPath (Join-Path $workerRunDir 'doctor-stdout.log') `
                -StderrLogPath (Join-Path $workerRunDir 'doctor-stderr.log')
            $doctorPid = [int]$doctorRun.Record.ProcessId
            $doctorExitCode = Wait-HarnessProcess -Context $context -Record $doctorRun.Record -Stage 'observer-doctor' -TimeoutSeconds 30
            $drainMs = Get-HarnessClippedTimeoutMilliseconds -Context $context -RequestedMilliseconds 5000 -Stage 'observer-doctor-drains'
            if (-not $doctorRun.Launcher.WaitDrains($drainMs)) {
                throw 'observer doctor exited but stdout/stderr drains did not complete'
            }
            if ([int]$doctorExitCode -ne 0) {
                throw ("Observer doctor exited with code {0} (expected 0); stopping immediately" -f [int]$doctorExitCode)
            }
            $visibleAfterDoctor = Get-TargetedVisibleWindowIds
            $doctorNewConsoleOwned = [int[]]@()
            $doctorNewConsoleUnowned = [int[]]@()
            if ($null -ne $visibleBeforeDoctor -and $null -ne $visibleAfterDoctor) {
                $doctorRows = Get-TargetedProcessRows
                $doctorTree = Get-TargetedTreePids -RootPid $doctorPid -Rows $doctorRows
                foreach ($vid in @($visibleAfterDoctor)) {
                    if (@($visibleBeforeDoctor) -notcontains [int]$vid) {
                        $vname = Get-TargetedProcessNameById -PidValue ([int]$vid) -Rows $doctorRows
                        if ($script:TargetedConsoleHostNames -contains $vname) {
                            if ($doctorTree -contains [int]$vid) { $doctorNewConsoleOwned += [int]$vid }
                            else { $doctorNewConsoleUnowned += [int]$vid }
                        }
                    }
                }
            }
            $doctorJson = $null
            try { $doctorJson = ([string]$doctorRun.Launcher.Stdout) | ConvertFrom-Json } catch { $doctorJson = $null }
            $desktopHosts = $null
            $doctorHostAnomaly = $false
            $doctorAnomalyEvidence = $null
            if ($null -ne $doctorJson) {
                Write-TargetedJson -Path (Join-Path $workerRunDir 'doctor-report.json') -Object ([ordered]@{
                    run_id = $RunId; doctor_report = $doctorJson
                    stderr_raw = [string]$doctorRun.Launcher.Stderr
                    stdout_truncated = [bool]$doctorRun.Launcher.StdoutTruncated
                    stderr_truncated = [bool]$doctorRun.Launcher.StderrTruncated
                })
                $desktopHosts = $doctorJson.desktop_hosts
                if ($null -ne $desktopHosts) {
                    $doctorHostAnomaly = (([string]$desktopHosts.claude_family -eq 'UNREACHABLE') -or ([string]$desktopHosts.codex_family -eq 'UNREACHABLE'))
                    $doctorAnomalyEvidence = [string]$desktopHosts.evidence
                }
            }
            $doctorInfo = [ordered]@{
                executed = $true
                exit_code = [int]$doctorExitCode
                duration_ms = [int]([DateTimeOffset]::UtcNow - $doctorStartedAt).TotalMilliseconds
                timeout_seconds = 30
                stdout_log = (Join-Path $workerRunDir 'doctor-stdout.log')
                stderr_log = (Join-Path $workerRunDir 'doctor-stderr.log')
                stdout_truncated = [bool]$doctorRun.Launcher.StdoutTruncated
                stderr_truncated = [bool]$doctorRun.Launcher.StderrTruncated
                desktop_hosts = $desktopHosts
                desktop_hosts_anomaly_unreachable = $doctorHostAnomaly
                desktop_hosts_anomaly_evidence = $doctorAnomalyEvidence
                new_visible_console_host_pids_owned_by_doctor = @($doctorNewConsoleOwned)
                new_visible_console_host_pids_unowned = @($doctorNewConsoleUnowned)
            }
            Add-TargetedStep -Name 'Observer doctor --json exits 0 (hidden, 30s budget)' -Pass $true `
                -Detail ("exit_code=$doctorExitCode desktop_host_anomaly=$doctorHostAnomaly") `
                -DurationMs $doctorInfo.duration_ms
            if ($doctorNewConsoleOwned.Count -gt 0) {
                throw ("visible console window owned by the doctor process tree: pids=({0}); stopping immediately" -f ($doctorNewConsoleOwned -join ','))
            }
            if ($doctorHostAnomaly) {
                # Recorded anomaly, not a failure and NOT investigated or fixed
                # in this run: preserved raw stderr/JSON evidence only.
                Write-Host ("doctor desktop-host anomaly recorded (UNREACHABLE): {0}" -f $doctorAnomalyEvidence)
            }

            # ---------------------------------------------------------------
            # 5. ONE 30s HUD smoke from the extracted EXE (visible window),
            #    visible-window + foreground sampling restricted to this run.
            # ---------------------------------------------------------------
            Assert-HarnessDeadline -Context $context -Stage 'hud-smoke'
            $stoppedAt = 'hud-smoke'
            $hudExe = Join-Path $extractDir 'AgentObserver.Hud.exe'
            if (-not (Test-Path -LiteralPath $hudExe)) { throw "packaged HUD exe missing: $hudExe" }
            $smokeLog = Join-Path $workerRunDir 'hud-smoke-diagnostic.log'
            $baselineVisibleIds = Get-TargetedVisibleWindowIds
            if ($null -eq $baselineVisibleIds) {
                throw "visibility probe failed at HUD baseline: $script:TargetedWindowProbeFailure"
            }
            [void]$script:TargetedExecutedCommands.Add([pscustomobject][ordered]@{
                tool = $hudExe
                arguments = @('--diagnostic-log', $smokeLog, '--close-after-ms', '30000')
                kind = 'hud-smoke-30s'
                visible_window = $true
                working_directory = $extractDir
                agent_observer_exe_cleared = $agentObserverExeCleared
            })
            $hudStartedAt = [DateTimeOffset]::UtcNow
            $hudRun = Start-LocalHarnessProcess -Context $context -FilePath $hudExe `
                -ArgumentList @('--diagnostic-log', $smokeLog, '--close-after-ms', '30000') `
                -Kind 'hud-smoke-30s' -WorkingDirectory $extractDir `
                -Scenario 'targeted-zip-verification' -ShowWindow `
                -StdoutLogPath (Join-Path $workerRunDir 'hud-smoke-stdout.log') `
                -StderrLogPath (Join-Path $workerRunDir 'hud-smoke-stderr.log')
            $hudPid = [int]$hudRun.Record.ProcessId
            $hudStartUnixMs = [int64]$hudRun.Record.ProcessStartedAtUnixMs

            $hudWindowShown = Wait-LocalHarnessConditionResult -Context $context -Stage 'hud-window-visible' -TimeoutSeconds 15 -Condition {
                $ids = [AgentObserverTargeted.WindowProbe]::VisibleWindowProcessIds()
                return (@($ids) -contains $hudPid)
            }
            Add-TargetedStep -Name 'HUD window becomes visible (direct exe, no launcher)' -Pass ([bool]$hudWindowShown) -Detail "hud_pid=$hudPid"

            # Observer child discovery: exactly one, parent = HUD PID,
            # adjacent packaged path, MainWindowHandle = 0.
            $script:TargetedObserverRow = $null
            $observerFound = Wait-LocalHarnessConditionResult -Context $context -Stage 'observer-discovery' -TimeoutSeconds 15 -Condition {
                $rows = @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId=" + $hudPid) -Property ProcessId, ParentProcessId, CreationDate, Name, ExecutablePath)
                $obs = @($rows | Where-Object { ([string]$_.Name) -ieq 'agent-observer-poc.exe' })
                if ($obs.Count -eq 1) { $script:TargetedObserverRow = $obs[0]; return $true }
                return $false
            }
            $observerPid = 0
            $observerStartUnixMs = [int64]0
            $observerPath = ''
            $observerCreationUtc = ''
            $observerMainWindowHandle = -1L
            $observerAdjacent = $false
            if ($observerFound) {
                $observerPid = [int]$script:TargetedObserverRow.ProcessId
                $observerPath = [string]$script:TargetedObserverRow.ExecutablePath
                $observerCreationUtc = ([DateTimeOffset](([DateTime]$script:TargetedObserverRow.CreationDate).ToUniversalTime())).ToString('o')
                try {
                    $obsProcess = [Diagnostics.Process]::GetProcessById($observerPid)
                    try {
                        $observerStartUnixMs = [int64](([DateTimeOffset]$obsProcess.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds())
                        $observerMainWindowHandle = $obsProcess.MainWindowHandle.ToInt64()
                    }
                    finally { $obsProcess.Dispose() }
                }
                catch { $observerStartUnixMs = [int64]0 }
                $observerAdjacent = ($observerPath -ieq (Join-Path $extractDir 'agent-observer-poc.exe'))
            }
            $observerInfo = [ordered]@{
                discovered = [bool]$observerFound
                pid = $observerPid
                started_at_unix_ms = $observerStartUnixMs
                creation_time_utc = $observerCreationUtc
                executable_path = $observerPath
                expected_adjacent_path = (Join-Path $extractDir 'agent-observer-poc.exe')
                adjacent_path_match = $observerAdjacent
                main_window_handle = $observerMainWindowHandle
                parent_pid = $hudPid
                exited_before_final_job_cleanup = $false
                exit_query_state_last = 'unknown'
                exit_observed_at = $null
                observer_children_after_close = -1
            }
            Add-TargetedStep -Name 'exactly one Observer child, adjacent path, MainWindowHandle = 0' `
                -Pass ($observerFound -and $observerAdjacent -and ($observerMainWindowHandle -eq 0)) `
                -Detail ("found=$observerFound adjacent=$observerAdjacent handle=$observerMainWindowHandle pid=$observerPid")
            if (-not ($observerFound -and $observerAdjacent)) {
                throw 'HUD Observer child was not discovered with the exact adjacent packaged path; stopping'
            }

            # Sampling loop: visible windows + foreground + owned tree.
            $samplingDeadline = [DateTimeOffset]::UtcNow.AddSeconds(45)
            $sampleCount = 0
            $hudForegroundSampleCount = 0
            $ownedUnexpectedVisibleEvents = 0
            $newConsoleUnowned = New-Object 'System.Collections.Generic.HashSet[int]'
            $unattributedNewVisible = New-Object 'System.Collections.Generic.HashSet[int]'
            while ($true) {
                Assert-HarnessDeadline -Context $context -Stage 'hud-sampling'
                # HUD liveness via the launcher-backed record (authoritative
                # process handle), not the query-based tri-state.
                $hudAliveNow = Test-HarnessProcessRecordAlive -Record $hudRun.Record
                if (-not $hudAliveNow) { break }
                if ([DateTimeOffset]::UtcNow -ge $samplingDeadline) { break }
                $rows = Get-TargetedProcessRows
                $ownedPids = Get-TargetedTreePids -RootPid $hudPid -Rows $rows
                if ($null -eq $ownedPids) { $ownedPids = [int[]]@() }
                $visible = Get-TargetedVisibleWindowIds
                if ($null -ne $visible) {
                    $newVisible = @($visible | Where-Object { $baselineVisibleIds -notcontains [int]$_ })
                    foreach ($vid in $newVisible) {
                        $vname = Get-TargetedProcessNameById -PidValue ([int]$vid) -Rows $rows
                        if ($script:TargetedConsoleHostNames -contains $vname) {
                            if ($ownedPids -contains [int]$vid) {
                                throw ("visible console window owned by this run (pid={0} name={1}); stopping immediately" -f $vid, $vname)
                            }
                            [void]$newConsoleUnowned.Add([int]$vid)
                        }
                        if ($ownedPids -notcontains [int]$vid) { [void]$unattributedNewVisible.Add([int]$vid) }
                    }
                    $ownedVisible = @($visible | Where-Object { $ownedPids -contains [int]$_ })
                    foreach ($opid in $ownedVisible) {
                        if ([int]$opid -ne $hudPid) { $ownedUnexpectedVisibleEvents++ }
                    }
                    [void]$script:TargetedVisibleObservations.Add([pscustomobject][ordered]@{
                        observed_at = [DateTimeOffset]::UtcNow.ToString('o')
                        stage = 'hud-smoke-sampling'
                        hud_alive = $true
                        total_visible_window_processes = @($visible).Count
                        new_visible_process_ids_vs_baseline = @($newVisible)
                        owned_process_ids = @($ownedPids)
                        owned_visible_process_ids = @($ownedVisible)
                    })
                }
                $fgPid = Get-TargetedForegroundWindowProcessId
                $fgName = Get-TargetedProcessNameById -PidValue $fgPid -Rows $rows
                $isHudFg = ($fgPid -eq $hudPid)
                if ($isHudFg) { $hudForegroundSampleCount++ }
                [void]$script:TargetedForegroundSamples.Add([pscustomobject][ordered]@{
                    observed_at = [DateTimeOffset]::UtcNow.ToString('o')
                    foreground_pid = $fgPid
                    foreground_process_name = $fgName
                    hud_pid = $hudPid
                    hud_is_foreground = $isHudFg
                    observer_is_foreground = ($observerPid -gt 0 -and $fgPid -eq $observerPid)
                })
                $sampleCount++
                Wait-HarnessSleep -Context $context -Stage 'hud-sampling' -Milliseconds 1000
            }
            Add-TargetedStep -Name 'no visible console window owned by this run during HUD smoke' -Pass ($ownedUnexpectedVisibleEvents -eq 0) `
                -Detail ("owned_unexpected_visible_events=$ownedUnexpectedVisibleEvents samples=$sampleCount")

            # HUD must exit on its own via --close-after-ms 30000.
            $hudExitCode = Wait-HarnessProcess -Context $context -Record $hudRun.Record -Stage 'hud-smoke-exit' -TimeoutSeconds 45
            $hudExitOk = ([int]$hudExitCode -eq 0)

            # ---------------------------------------------------------------
            # 6. Observer exit proof BEFORE the final kill-on-close Job cleanup:
            #    at most 15s, exact PID + creation time.
            # ---------------------------------------------------------------
            Assert-HarnessDeadline -Context $context -Stage 'observer-exit-proof'
            $stoppedAt = 'observer-exit-proof'
            $observerExitDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            if ($observerExitDeadline -gt $context.Deadline) { $observerExitDeadline = $context.Deadline }
            $observerExitedBeforeCleanup = $false
            $observerExitObservedAt = $null
            $observerLastQueryState = 'unknown'
            while ($true) {
                Assert-HarnessDeadline -Context $context -Stage 'observer-exit-proof'
                $observerQueryState = 'unknown'
                if ($observerPid -gt 0) {
                    $observerQueryState = Get-TargetedProcessLiveness -PidValue $observerPid -StartedAtUnixMs $observerStartUnixMs
                }
                $observerLastQueryState = $observerQueryState
                [void]$script:TargetedObserverExitSamples.Add([pscustomobject][ordered]@{
                    observed_at = [DateTimeOffset]::UtcNow.ToString('o')
                    observer_query_state = $observerQueryState
                    observer_alive = ($observerQueryState -eq 'alive')
                    hud_alive = (Test-HarnessProcessRecordAlive -Record $hudRun.Record)
                    before_final_job_cleanup = $true
                })
                if ($observerQueryState -eq 'exited') {
                    # ONLY an explicit 'exited' answer (no such PID / HasExited /
                    # PID reused with a different creation time) is an exit
                    # proof. 'unknown' (query failure) never proves an exit.
                    $observerExitedBeforeCleanup = $true
                    $observerExitObservedAt = [DateTimeOffset]::UtcNow.ToString('o')
                    break
                }
                if ([DateTimeOffset]::UtcNow -ge $observerExitDeadline) { break }
                Wait-HarnessSleep -Context $context -Stage 'observer-exit-proof' -Milliseconds 200
            }
            $observerChildrenAfterClose = @()
            if ($observerPid -gt 0) {
                $observerChildrenAfterClose = @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId=" + $hudPid) -Property ProcessId, Name | Where-Object { ([string]$_.Name) -ieq 'agent-observer-poc.exe' })
            }
            $observerInfo.exited_before_final_job_cleanup = [bool]$observerExitedBeforeCleanup
            $observerInfo.exit_observed_at = $observerExitObservedAt
            $observerInfo.exit_query_state_last = $observerLastQueryState
            $observerInfo.observer_children_after_close = @($observerChildrenAfterClose).Count
            Add-TargetedStep -Name 'exact Observer exits after HUD close before final Job cleanup (<=15s)' `
                -Pass ($observerExitedBeforeCleanup -and (@($observerChildrenAfterClose).Count -eq 0)) `
                -Detail ("exited_before_cleanup=$observerExitedBeforeCleanup last_query_state=$observerLastQueryState children_after_close=$(@($observerChildrenAfterClose).Count) pid=$observerPid")

            # HUD diagnostic log analysis.
            $hudClosingLine = $false
            $hudRunSummaryLine = $false
            $hudScanLines = 0
            $hudObserverStartLine = ''
            if (Test-Path -LiteralPath $smokeLog) {
                foreach ($line in @([IO.File]::ReadAllLines($smokeLog))) {
                    if ($line -like '*HUD closing*') { $hudClosingLine = $true }
                    if ($line -like '*run summary scans=*') { $hudRunSummaryLine = $true }
                    if ($line -like '*observer scan sessions=*') { $hudScanLines++ }
                    if ($line -like '*observer started pid=*') { $hudObserverStartLine = $line }
                }
            }
            $hudInfo = [ordered]@{
                launched = $true
                hud_exe = $hudExe
                working_directory = $extractDir
                hud_pid = $hudPid
                hud_started_at_unix_ms = $hudStartUnixMs
                close_after_ms = 30000
                window_shown = [bool]$hudWindowShown
                exit_code = [int]$hudExitCode
                exit_ok = $hudExitOk
                duration_ms = [int]([DateTimeOffset]::UtcNow - $hudStartedAt).TotalMilliseconds
                diagnostic_log = $smokeLog
                diagnostic_log_exists = (Test-Path -LiteralPath $smokeLog)
                hud_closing_line_present = $hudClosingLine
                run_summary_line_present = $hudRunSummaryLine
                observer_scan_log_lines = $hudScanLines
                observer_started_log_line = $hudObserverStartLine
            }
            Add-TargetedStep -Name 'HUD smoke exits 0 via --close-after-ms' -Pass $hudExitOk -Detail "exit_code=$hudExitCode"

            $windowObservationSummary = [ordered]@{
                sample_count = $sampleCount
                sampling_interval_ms = 1000
                baseline_visible_window_processes = @($baselineVisibleIds).Count
                new_visible_console_host_pids_owned_by_run = [int[]]@()
                new_visible_console_host_pids_unowned = [int[]]$newConsoleUnowned
                unattributed_new_visible_process_ids = [int[]]$unattributedNewVisible
                owned_unexpected_visible_events = $ownedUnexpectedVisibleEvents
                hud_foreground_sample_count = $hudForegroundSampleCount
                window_probe_failure = $script:TargetedWindowProbeFailure
                limitation = 'Discrete sampling cannot prove the absence of windows between samples; user-initiated window switches are not failures.'
            }
        }
        catch {
            $anyFailed = $true
            $failureDetail = [string]$_.Exception.Message
            if ($failureDetail -like '*deadline exceeded*' -or $failureDetail -like '*Timed out after*') {
                $workerTimeoutDetected = $true
            }
        }
        finally {
            # The Observer-exit proof above was recorded BEFORE this cleanup.
            # The kill-on-close Job disposal below is only the backstop and is
            # never presented as the graceful-close evidence.
            $cleanupMeasure = $null
            if ($null -ne $context) {
                try { $cleanupMeasure = Close-LocalHarnessRun -Context $context -Reason 'targeted-zip-worker-end' }
                catch {
                    $cleanupMeasure = [pscustomobject]@{ cleanup_success = $false; owned_processes_remaining = -1; cleanup_failure = [string]$_.Exception.Message }
                }
            }
            if ($null -eq $cleanupMeasure) {
                $cleanupMeasure = [pscustomobject]@{ cleanup_success = $true; owned_processes_remaining = 0; cleanup_failure = $null }
            }
            $tempDirCleaned = $true
            $tempCleanupNote = ''
            if ($extractDir) {
                try { $null = Remove-TargetedTempDirectory -Path $extractDir -AllowedRoot $tempRootPath }
                catch {
                    $tempDirCleaned = $false
                    $tempCleanupNote = [string]$_.Exception.Message
                    $anyFailed = $true
                }
            }
            try {
                Write-TargetedJson -Path (Join-Path $workerRunDir 'visible-window-observations.json') -Object ([ordered]@{
                    run_id = $RunId; observations = @($script:TargetedVisibleObservations.ToArray())
                })
                Write-TargetedJson -Path (Join-Path $workerRunDir 'foreground-samples.json') -Object ([ordered]@{
                    run_id = $RunId; samples = @($script:TargetedForegroundSamples.ToArray())
                })
                Write-TargetedJson -Path (Join-Path $workerRunDir 'observer-exit-samples.json') -Object ([ordered]@{
                    run_id = $RunId; samples = @($script:TargetedObserverExitSamples.ToArray())
                })
                Write-TargetedJson -Path (Join-Path $workerRunDir 'executed-commands.json') -Object ([ordered]@{
                    run_id = $RunId; commands = @($script:TargetedExecutedCommands.ToArray())
                })
            }
            catch {
                $anyFailed = $true
                if (-not $failureDetail) { $failureDetail = "evidence write failed: $([string]$_.Exception.Message)" }
            }
        }

        $workerFinishedAt = [DateTimeOffset]::UtcNow
        $workerDurationMs = [int]($workerFinishedAt - $workerStartedAt).TotalMilliseconds
        if ($workerFinishedAt -gt $workerDeadline) { $workerTimeoutDetected = $true; $anyFailed = $true }
        if ($null -ne $script:TargetedWindowProbeFailure) { $anyFailed = $true }
        if (-not $cleanupMeasure.cleanup_success) { $anyFailed = $true }
        if ([int]$cleanupMeasure.owned_processes_remaining -ne 0) { $anyFailed = $true }
        if (-not $tempDirCleaned) { $anyFailed = $true }
        # A FAILING STEP IS A FAILED RUN: step failures (HUD exit code, budget
        # overrun, owned visible window, missing observer exit proof, ...) must
        # never be outvoted by an otherwise clean catch-free path.
        if ($script:TargetedFailures.Count -gt 0) { $anyFailed = $true }
        $workerPass = ((-not $anyFailed) -and (-not $workerTimeoutDetected))
        $workerStatus = if ($workerTimeoutDetected) { 'TIMEOUT' } elseif ($workerPass) { 'OFFLINE' } else { 'FAIL' }

        $workerSummary = [pscustomobject][ordered]@{
            run_id = $RunId
            test = 'Targeted candidate ZIP standalone verification (worker)'
            mode = 'TargetedZip'
            role = 'worker'
            status = $workerStatus
            pass = [bool]$workerPass
            failure_reasons = @($script:TargetedFailures.ToArray())
            failure_detail = $failureDetail
            stopped_at = $stoppedAt
            script_sha256 = $script:TargetedScriptSha256
            started_at = $workerStartedAt.ToString('o')
            finished_at = $workerFinishedAt.ToString('o')
            actual_duration_ms = $workerDurationMs
            absolute_deadline_at = $workerDeadline.ToString('o')
            timeout_detected = [bool]$workerTimeoutDetected
            candidate_zip = $zipIdentity
            extraction = $extractionInfo
            manifest = $manifestInfo
            zip_stage_budget_ms = 60000
            doctor = $doctorInfo
            hud_smoke = $hudInfo
            observer_child = $observerInfo
            window_foreground_observation = $windowObservationSummary
            environment = [ordered]@{
                agent_observer_exe_present_before = (-not [string]::IsNullOrWhiteSpace($agentObserverExeBefore))
                agent_observer_exe_value_before = $agentObserverExeBefore
                cleared_for_children_only = [bool]$agentObserverExeCleared
            }
            cleanup = [ordered]@{
                cleanup_success = [bool]$cleanupMeasure.cleanup_success
                owned_processes_remaining = [int]$cleanupMeasure.owned_processes_remaining
                cleanup_failure = $cleanupMeasure.cleanup_failure
                temp_dir = $extractDir
                temp_dir_cleaned = [bool]$tempDirCleaned
                temp_dir_cleanup_note = $tempCleanupNote
            }
            visibility_probe_reliable = ($null -eq $script:TargetedWindowProbeFailure)
            steps = @($script:TargetedSteps.ToArray())
            network_access_permitted = $false
            network_requests_observed = $null
            model_calls = 0
            start_gate_consumed = $true
        }
        try {
            Write-TargetedJson -Path (Join-Path $workerRunDir 'worker-summary.json') -Object $workerSummary
        }
        catch {
            [Console]::Error.WriteLine(("worker-summary.json write failed: {0}" -f [string]$_.Exception.Message))
            exit 1
        }
        if (-not $workerPass) { exit 1 }
        exit 0
    }

    # =====================================================================
    # SUPERVISOR ROLE: -Mode TargetedZip (operator entry point)
    # =====================================================================
    $supStartedAt = [DateTimeOffset]::UtcNow
    $supAbsoluteDeadline = $supStartedAt.AddSeconds($TargetedOuterDeadlineSeconds)
    $supPid = [int]$PID
    $supCreation = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
    $gateToken = [Guid]::NewGuid().ToString('n')

    if ([string]::IsNullOrWhiteSpace($CandidateZip)) {
        [Console]::Error.WriteLine('REFUSING TO START: -CandidateZip is required in TargetedZip mode')
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedZipSha256) -or $ExpectedZipSizeBytes -le 0) {
        [Console]::Error.WriteLine('REFUSING TO START: -ExpectedZipSha256 and -ExpectedZipSizeBytes are required in TargetedZip mode')
        exit 2
    }
    $CandidateZip = [IO.Path]::GetFullPath($CandidateZip)
    if (-not (Test-Path -LiteralPath $CandidateZip)) {
        [Console]::Error.WriteLine("REFUSING TO START: candidate ZIP not found: $CandidateZip")
        exit 2
    }
    if (-not $EvidenceRoot) {
        $EvidenceRoot = Join-Path $script:RepoRoot ("artifacts\package-acceptance\" + $RunId)
    }
    $EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
    $null = Assert-LocalPackageUnderFixedArtifactsRoot -PackageRoot $EvidenceRoot -RepoRoot $script:RepoRoot
    if (Test-Path -LiteralPath $EvidenceRoot) {
        [Console]::Error.WriteLine("REFUSING TO START: evidence root already exists (one attempt per evidence root): $EvidenceRoot")
        exit 2
    }

    # A running HUD would hold the single-instance lock and pollute window
    # attribution: refuse (BLOCKED) before creating any evidence.
    $existingHud = @(Get-Process -Name 'AgentObserver.Hud' -ErrorAction SilentlyContinue)
    if ($existingHud.Count -gt 0) {
        $ids = ($existingHud | ForEach-Object { [string]$_.Id }) -join ','
        [Console]::Error.WriteLine("BLOCKED: an AgentObserver.Hud instance is already running (PID $ids). Close it normally, then start a NEW run with a new run id.")
        exit 3
    }

    [IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null
    $markerPath = Join-Path $EvidenceRoot 'attempt.json'
    $startGatePath = Join-Path $EvidenceRoot 'start-gate.json'
    $finalSummaryPath = Join-Path $EvidenceRoot 'final-summary.json'
    $runDirectory = Join-Path $EvidenceRoot 'run'

    Write-TargetedJson -Path (Join-Path $EvidenceRoot 'invocation.json') -Object ([ordered]@{
        run_id = $RunId
        mode = 'TargetedZip'
        role = 'supervisor'
        script_path = $PSCommandPath
        script_sha256 = (Get-TargetedFileSha256 -Path $PSCommandPath)
        parameters = [ordered]@{
            candidate_zip = $CandidateZip
            expected_zip_sha256 = ([string]$ExpectedZipSha256).Trim()
            expected_zip_size_bytes = [long]$ExpectedZipSizeBytes
            outer_deadline_seconds = [int]$TargetedOuterDeadlineSeconds
            worker_deadline_seconds = [int]$TargetedWorkerDeadlineSeconds
            evidence_root = $EvidenceRoot
        }
        supervisor_pid = $supPid
        supervisor_creation_time = $supCreation
        started_at = $supStartedAt.ToString('o')
        absolute_deadline_at = $supAbsoluteDeadline.ToString('o')
    })

    try {
        New-LocalSafetyAttemptMarker -Path $markerPath -RunId $RunId -SupervisorPid $supPid `
            -SupervisorCreationTimeUtc $supCreation | Out-Null
    }
    catch {
        [Console]::Error.WriteLine(([string]$_.Exception.Message))
        exit 2
    }

    $supTimeoutDetected = $false
    $supFailureReason = $null
    $workerExitCode = $null
    $workerSummary = $null
    $workerStartCount = 0
    $startGateCreated = $false
    $context = $null
    $cleanupMeasure = $null
    $baselineConsoleIds = [int[]]@()
    $finalConsoleIds = [int[]]@()
    $newConsoleWindows = New-Object System.Collections.Generic.List[int]
    $visibleWindowsObservation = 'UNKNOWN'
    $windowProbeError = $null

    try {
        Assert-LocalSafetyEvidenceRootHasNoStaleFiles -EvidenceRoot $EvidenceRoot -RunDirectory $runDirectory -Phase SupervisorPreLaunch
        if (Test-Path -LiteralPath $runDirectory) { throw "unique run directory already exists: $runDirectory" }
        if (Test-Path -LiteralPath $startGatePath) { throw "start gate already exists: $startGatePath" }
        [IO.Directory]::CreateDirectory($runDirectory) | Out-Null

        $context = New-HarnessLifecycle -Name 'targeted-zip-supervisor' -RunRoot $runDirectory `
            -Scenario 'targeted-zip-verification' -OverallTimeoutSeconds $TargetedOuterDeadlineSeconds `
            -HeartbeatSeconds 10 -StartedAt $supStartedAt -AbsoluteDeadlineAt $supAbsoluteDeadline

        $baselineProbe = Invoke-TargetedWindowProbeHelper -Lifecycle $context `
            -OutputPath (Join-Path $runDirectory 'window-probe-baseline.json') -Stage 'window-probe-baseline'
        if ([string]$baselineProbe.status -ne 'ok') {
            $visibleWindowsObservation = 'UNKNOWN'
            $windowProbeError = [string]$baselineProbe.error
            $supFailureReason = "visible-window baseline probe UNKNOWN: $windowProbeError"
        }
        else {
            $baselineConsoleIds = [int[]]$baselineProbe.ids
            $visibleWindowsObservation = 'ok'
        }

        Assert-HarnessDeadline -Context $context -Stage 'start-worker'
        $workerStdoutLog = Join-Path $runDirectory 'worker-stdout.log'
        $workerStderrLog = Join-Path $runDirectory 'worker-stderr.log'
        $workerRun = Start-HarnessProcess -Context $context -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                '-Mode', 'TargetedZip', '-Supervised',
                '-RunId', $RunId,
                '-SupervisorPid', [string]$supPid,
                '-SupervisorCreationTimeUtc', $supCreation,
                '-AttemptMarkerPath', $markerPath,
                '-StartGatePath', $startGatePath,
                '-StartGateToken', $gateToken,
                '-EvidenceRoot', $EvidenceRoot,
                '-RunDirectory', $runDirectory,
                '-CandidateZip', $CandidateZip,
                '-ExpectedZipSha256', ([string]$ExpectedZipSha256).Trim(),
                '-ExpectedZipSizeBytes', [string]$ExpectedZipSizeBytes,
                '-TargetedWorkerDeadlineSeconds', [string]$TargetedWorkerDeadlineSeconds) `
            -Kind 'targeted-zip-worker' -Scenario 'targeted-zip-verification' `
            -WorkingDirectory $script:RepoRoot `
            -RedirectStandardOutput $workerStdoutLog -RedirectStandardError $workerStderrLog
        $workerStartCount = 1

        Update-LocalSafetyAttemptMarker -Path $markerPath -Status 'RUNNING' | Out-Null
        New-LocalSafetyStartGate -Path $startGatePath -RunId $RunId -Token $gateToken `
            -SupervisorPid $supPid -SupervisorCreationTimeUtc $supCreation | Out-Null
        $startGateCreated = $true

        while (-not $workerRun.Launcher.WaitForExit(200)) {
            if ([DateTimeOffset]::UtcNow -ge $supAbsoluteDeadline) {
                $supTimeoutDetected = $true
                break
            }
            Write-HarnessHeartbeat -Context $context -Stage 'supervisor-wait' -Detail ("worker_pid=" + $workerRun.Record.ProcessId)
        }
        if ($supTimeoutDetected) {
            $supFailureReason = "SUPERVISOR TIMEOUT: worker PID $($workerRun.Record.ProcessId) exceeded absolute_deadline_at $($supAbsoluteDeadline.ToString('o')); the owned worker tree is terminated via the kill-on-close Job Object"
        }
        else {
            $workerExitCode = Get-HarnessProcessExitCode -Record $workerRun.Record -Stage 'targeted-zip-worker'
            $drainMs = 10000
            try { $drainMs = Get-HarnessClippedTimeoutMilliseconds -Context $context -RequestedMilliseconds 10000 -Stage 'worker-drains' }
            catch { $drainMs = 10000 }
            if (-not $workerRun.Launcher.WaitDrains($drainMs)) {
                $supFailureReason = 'worker exited but stdout/stderr drains did not complete'
            }
            $workerSummaryPath = Join-Path $runDirectory 'worker-summary.json'
            if (Test-Path -LiteralPath $workerSummaryPath) {
                try { $workerSummary = Get-Content -LiteralPath $workerSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $workerSummary = $null }
            }
            if ($null -eq $workerSummary -and -not $supFailureReason) {
                $supFailureReason = "worker exited with code $workerExitCode but produced no parsable worker-summary.json"
            }
        }

        if ($null -ne $context -and $null -ne $context.Job) {
            $finalProbe = Invoke-TargetedWindowProbeHelper -Lifecycle $context `
                -OutputPath (Join-Path $runDirectory 'window-probe-final.json') -Stage 'window-probe-final'
            if ([string]$finalProbe.status -ne 'ok') {
                $visibleWindowsObservation = 'UNKNOWN'
                $windowProbeError = [string]$finalProbe.error
                if (-not $supFailureReason) { $supFailureReason = "visible-window final probe UNKNOWN: $windowProbeError" }
            }
            else {
                $finalConsoleIds = [int[]]$finalProbe.ids
                $baselineSet = New-Object 'System.Collections.Generic.HashSet[int]'
                foreach ($id in $baselineConsoleIds) { [void]$baselineSet.Add([int]$id) }
                foreach ($id in $finalConsoleIds) {
                    if (-not $baselineSet.Contains([int]$id)) { [void]$newConsoleWindows.Add([int]$id) }
                }
            }
        }
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -like '*SUPERVISOR TIMEOUT*' -or $message -like '*deadline exceeded*') { $supTimeoutDetected = $true }
        if (-not $supFailureReason) { $supFailureReason = "supervisor error: $message" }
    }
    finally {
        $cleanupFailure = $null
        if ($null -ne $context) {
            try { Close-HarnessLifecycle -Context $context -Reason $(if ($supTimeoutDetected) { 'supervisor-timeout' } else { 'worker-finished' }) }
            catch { $cleanupFailure = [string]$_.Exception.Message }
        }
        $cleanupMeasure = Measure-HarnessCleanup -Contexts @($context) -CleanupFailure $cleanupFailure
    }

    # ---------------------------------------------------------------------
    # Single terminal verdict path (the only writer of final-summary.json).
    # ---------------------------------------------------------------------
    $finishedAt = [DateTimeOffset]::UtcNow
    $actualDurationMs = [int][Math]::Round(($finishedAt - $supStartedAt).TotalMilliseconds)
    $deadlineVerdict = Get-LocalSafetyDeadlineVerdict -FinishedAt $finishedAt -AbsoluteDeadlineAt $supAbsoluteDeadline -BaseTimeoutDetected ([bool]$supTimeoutDetected)
    if ($deadlineVerdict.timeout_detected) {
        $supTimeoutDetected = $true
        $supFailureReason = "DEADLINE VERDICT TIMEOUT: finished_at $($finishedAt.ToString('o')) vs absolute_deadline_at $($supAbsoluteDeadline.ToString('o'))"
    }

    # Residual verification by exact PID + creation time of the processes the
    # worker recorded (HUD root and discovered Observer child).
    $residualOwnedPids = [int[]]@()
    $extractTempDir = $null
    $extractTempDirRemoved = $true
    $workerReportedPass = $false
    if ($null -ne $workerSummary) {
        $workerReportedPass = [bool]$workerSummary.pass
        $residual = New-Object System.Collections.Generic.List[int]
        foreach ($recordSpec in @(
            @{ pid = [int](Get-HarnessProperty $workerSummary.hud_smoke 'hud_pid'); ms = [int64](Get-HarnessProperty $workerSummary.hud_smoke 'hud_started_at_unix_ms') },
            @{ pid = [int](Get-HarnessProperty $workerSummary.observer_child 'pid'); ms = [int64](Get-HarnessProperty $workerSummary.observer_child 'started_at_unix_ms') })) {
            if ($recordSpec.pid -gt 0 -and $recordSpec.ms -gt 0) {
                # Fail closed: 'alive' OR 'unknown' both count as a residual
                # (uncertain observations are never allowed to read as clean).
                $state = Get-TargetedProcessLiveness -PidValue $recordSpec.pid -StartedAtUnixMs $recordSpec.ms
                if ($state -ne 'exited') { [void]$residual.Add($recordSpec.pid) }
            }
        }
        $residualOwnedPids = [int[]]$residual.ToArray()
        $extractTempDir = [string](Get-HarnessProperty (Get-HarnessProperty $workerSummary 'cleanup') 'temp_dir')
        if ($extractTempDir) { $extractTempDirRemoved = -not (Test-Path -LiteralPath $extractTempDir) }
        $workerCleanup = Get-HarnessProperty $workerSummary 'cleanup'
        if (-not (Get-HarnessProperty $workerCleanup 'cleanup_success')) {
            $supFailureReason = 'worker cleanup failed'
            $workerReportedPass = $false
        }
        if ([int](Get-HarnessProperty $workerCleanup 'owned_processes_remaining') -ne 0) {
            $supFailureReason = 'worker reported owned processes remaining'
            $workerReportedPass = $false
        }
        if (-not (Get-HarnessProperty $workerCleanup 'temp_dir_cleaned')) {
            $supFailureReason = 'worker temp directory cleanup failed'
            $workerReportedPass = $false
        }
    }

    $startGateConsumed = (Test-Path -LiteralPath (Get-LocalSafetyStartGateConsumedPath -StartGatePath $startGatePath))
    $noNewConsoleWindows = (($visibleWindowsObservation -eq 'ok') -and ($newConsoleWindows.Count -eq 0))
    $cleanupSuccess = [bool]$cleanupMeasure.cleanup_success
    $ownedRemainingTotal = [int]$cleanupMeasure.owned_processes_remaining + $residualOwnedPids.Count

    $targetedPass = (
        $workerReportedPass -and
        -not $supTimeoutDetected -and
        $deadlineVerdict.deadline_respected -and
        $cleanupSuccess -and
        $ownedRemainingTotal -eq 0 -and
        $noNewConsoleWindows -and
        -not $supFailureReason -and
        $workerStartCount -eq 1 -and
        $startGateConsumed
    )
    $finalStatus = if ($supTimeoutDetected) { 'TIMEOUT' } elseif ($targetedPass) { 'OFFLINE' } else { 'FAIL' }
    if (-not $targetedPass -and -not $supFailureReason) { $supFailureReason = 'targeted ZIP verification did not pass' }

    $summaryWritten = $false
    $summary = [pscustomobject][ordered]@{
        schema_version = 'targeted-zip-acceptance-summary/v1'
        generated_by = 'daily-use-local-package-acceptance.ps1 TargetedZip supervisor'
        run_id = $RunId
        test = 'Targeted candidate ZIP standalone verification (acceptance attempt 2)'
        supervisor_pid = $supPid
        supervisor_creation_time = $supCreation
        started_at = $supStartedAt.ToString('o')
        finished_at = $finishedAt.ToString('o')
        actual_duration_ms = $actualDurationMs
        absolute_deadline_at = $supAbsoluteDeadline.ToString('o')
        deadline_respected = [bool]$deadlineVerdict.deadline_respected
        attempt_count = 1
        worker_start_count = [int]$workerStartCount
        start_gate_consumed = [bool]$startGateConsumed
        start_gate_created = [bool]$startGateCreated
        automatic_retries = 0
        worker_script = $PSCommandPath
        worker_exit_code = $workerExitCode
        status = $finalStatus
        final_status = $finalStatus
        targeted_pass = [bool]$targetedPass
        timeout_detected = [bool]$supTimeoutDetected
        failure_reason = $supFailureReason
        outer_deadline_seconds = [int]$TargetedOuterDeadlineSeconds
        worker_deadline_seconds = [int]$TargetedWorkerDeadlineSeconds
        cleanup_success = $cleanupSuccess
        owned_processes_remaining = $ownedRemainingTotal
        supervisor_cleanup = $cleanupMeasure
        worker_reported_residual_pids_alive = @($residualOwnedPids)
        extract_temp_dir = $extractTempDir
        extract_temp_dir_removed = $extractTempDirRemoved
        visible_console_windows_observation = $visibleWindowsObservation
        new_visible_console_window_pids = [int[]]$newConsoleWindows.ToArray()
        window_probe_error = $windowProbeError
        network_access_permitted = $false
        network_requests_observed = $null
        model_calls = 0
        live_agent_calls = 0
        real_agent_configuration_touched = $false
        supervisor_process_hard_deadline = 'UNPROVEN'
        worker_summary = $workerSummary
        evidence_root = $EvidenceRoot
        run_directory = $runDirectory
    }
    try {
        $markerBefore = Read-LocalSafetyAttemptMarker -Path $markerPath
        $null = Update-LocalSafetyAttemptMarker -Path $markerPath -Status 'FINISHED'
        Write-LocalSafetyEvidenceJson -Path $finalSummaryPath -Object $summary
        $null = Update-LocalSafetyAttemptMarker -Path $markerPath -Status 'FINISHED' -FinalStatus $finalStatus
        $markerAfter = Read-LocalSafetyAttemptMarker -Path $markerPath
        $summaryRead = $null
        try { $summaryRead = Get-Content -LiteralPath $finalSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $summaryRead = $null }
        Assert-LocalSafetyMarkerSummaryAgreement -Summary $summaryRead -Marker $markerAfter
        $summaryWritten = $true
    }
    catch {
        [Console]::Error.WriteLine(("TERMINAL-STATE PROTOCOL FAILURE (INCOMPLETE): {0}" -f [string]$_.Exception.Message))
        try { $null = Update-LocalSafetyAttemptMarker -Path $markerPath -Status 'FINISHED' -FinalStatus 'INCOMPLETE' } catch { }
    }

    if (-not $summaryWritten) { exit 1 }
    if (-not $targetedPass) {
        [Console]::Error.WriteLine(("TARGETED ZIP VERIFICATION FAILED (final_status=$finalStatus): {0}" -f $supFailureReason))
        exit 1
    }
    Write-Output ("TARGETED ZIP VERIFICATION PASSED (final_status=OFFLINE): {0}" -f $RunId)
    exit 0
}

. (Join-Path $PSScriptRoot 'local-package-harness.ps1')

$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:FixedAllowedRoot = Get-LocalPackageFixedAllowedRoot -RepoRoot $script:RepoRoot
if (-not $PackageRoot) { $PackageRoot = Join-Path $script:FixedAllowedRoot 'agent-observer-hud-poc' }
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
$null = Assert-LocalPackageUnderFixedArtifactsRoot -PackageRoot $PackageRoot -RepoRoot $script:RepoRoot
if (-not $EvidenceRoot) {
    $EvidenceRoot = Join-Path $script:RepoRoot "docs\evidence\daily-use-local-package-v0.1-r2\runs\$RunId"
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
[IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null

# Path safety (rule 13): every disposable directory of this run must live in
# a canonical path inside the system TEMP root, never the TEMP root itself.
$script:TempAllowedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$disposableDir = Join-Path $script:TempAllowedRoot ("agent-observer-hud-poc-accept-" + $RunId)
$null = Assert-LocalPackageSafePath -Path $disposableDir -AllowedRoots @($script:TempAllowedRoot) -RepoRoot $script:RepoRoot
$missingDir = Join-Path $script:TempAllowedRoot ("agent-observer-hud-poc-missing-" + $RunId)
$null = Assert-LocalPackageSafePath -Path $missingDir -AllowedRoots @($script:TempAllowedRoot) -RepoRoot $script:RepoRoot

$script:Harness = $null
$script:Failures = [Collections.Generic.List[string]]::new()
$script:Steps = [Collections.Generic.List[object]]::new()
$script:VisibilityObservations = [Collections.Generic.List[object]]::new()
$script:BaselineVisibleIds = $null
$script:ObservedVisibleIds = [Collections.Generic.HashSet[int]]::new()
$script:VisibilityProbeFailure = $null
$script:OwnedObservations = [Collections.Generic.List[object]]::new()
$script:TrackedProcesses = @{}
$script:HudWindowPids = [Collections.Generic.HashSet[int]]::new()
$script:ConsoleHostNames = @('conhost.exe', 'OpenConsole.exe', 'WindowsTerminal.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe')
$script:TempDirs = [Collections.Generic.List[string]]::new()
$script:CleanupMeasure = $null
$script:TempDirsCleaned = $true
$script:ExecutedCommands = [Collections.Generic.List[object]]::new()
$utf8 = [Text.UTF8Encoding]::new($false)

if (-not ('AgentObserverDailyUse.WindowProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AgentObserverDailyUse
{
    public static class WindowProbe
    {
        private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);

        public const uint WM_CLOSE = 0x0010;

        public static int[] VisibleWindowProcessIds()
        {
            var ids = new HashSet<int>();
            var succeeded = EnumWindows((window, parameter) =>
            {
                if (IsWindowVisible(window))
                {
                    uint processId;
                    GetWindowThreadProcessId(window, out processId);
                    if (processId != 0)
                        ids.Add((int)processId);
                }
                return true;
            }, IntPtr.Zero);
            if (!succeeded)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed");
            var result = new int[ids.Count];
            ids.CopyTo(result);
            return result;
        }

        public static int CloseVisibleWindowsOfProcess(int processId)
        {
            var closed = 0;
            var succeeded = EnumWindows((window, parameter) =>
            {
                if (IsWindowVisible(window))
                {
                    uint owner;
                    GetWindowThreadProcessId(window, out owner);
                    if (owner == (uint)processId && PostMessage(window, WM_CLOSE, IntPtr.Zero, IntPtr.Zero))
                        closed++;
                }
                return true;
            }, IntPtr.Zero);
            if (!succeeded)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed");
            return closed;
        }
    }
}
'@
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Content = '')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Get-ProcessRows {
    return @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, CreationDate, Name, CommandLine)
}

function Convert-RowToObservation {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)]$VisibleIds,
        [switch]$ReadMainWindowHandle
    )
    $processId = [int]$Row.ProcessId
    $creation = ([DateTime]$Row.CreationDate).ToUniversalTime()
    $handle = 0L
    if ($ReadMainWindowHandle -and $processId -gt 0) {
        try {
            $candidate = [Diagnostics.Process]::GetProcessById($processId)
            try { $candidate.Refresh(); $handle = $candidate.MainWindowHandle.ToInt64() }
            finally { $candidate.Dispose() }
        } catch { $handle = -1L }
    }
    [pscustomobject]@{
        run_id = $RunId
        pid = $processId
        parent_pid = [int]$Row.ParentProcessId
        creation_time = $creation.ToString('o')
        name = [string]$Row.Name
        command_line = [string]$Row.CommandLine
        role = $Role
        main_window_handle = $handle
        visible_window_observed = (@($VisibleIds) -contains $processId)
    }
}

function Get-VisibleWindowSnapshot {
    param([Parameter(Mandatory)][string]$Stage)
    try {
        $ids = @([AgentObserverDailyUse.WindowProbe]::VisibleWindowProcessIds() | Sort-Object -Unique)
        foreach ($processId in $ids) { [void]$script:ObservedVisibleIds.Add([int]$processId) }
        $newIds = if ($null -eq $script:BaselineVisibleIds) { $null } else { @($ids | Where-Object { $script:BaselineVisibleIds -notcontains [int]$_ }) }
        [void]$script:VisibilityObservations.Add([pscustomobject]@{
            run_id = $RunId
            observed_at = [DateTimeOffset]::UtcNow.ToString('o')
            stage = $Stage
            visible_window_process_ids = $ids
            new_visible_window_process_ids = $newIds
        })
        return ,$ids
    }
    catch {
        $script:VisibilityProbeFailure = ("{0}: {1}" -f $Stage, $_.Exception.Message)
        return $null
    }
}

function Get-OwnedProcessTree {
    param(
        [Parameter(Mandatory)][int[]]$RootPids,
        [Parameter(Mandatory)][string]$Stage,
        [switch]$ReadMainWindowHandle
    )
    $visibleIds = @(Get-VisibleWindowSnapshot -Stage $Stage)
    if ($null -eq $visibleIds) { $visibleIds = @() }
    $rows = Get-ProcessRows
    $wanted = [Collections.Generic.HashSet[int]]::new()
    foreach ($rootPid in $RootPids) { [void]$wanted.Add($rootPid) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($row in $rows) {
            $procId = [int]$row.ProcessId
            $parent = [int]$row.ParentProcessId
            if ($wanted.Contains($parent) -and -not $wanted.Contains($procId)) {
                [void]$wanted.Add($procId)
                $changed = $true
            }
        }
    }

    $observations = @()
    foreach ($row in $rows) {
        $procId = [int]$row.ProcessId
        if (-not $wanted.Contains($procId)) { continue }
        $role = if ($RootPids -contains $procId) { 'owned-root' } else { 'owned-descendant' }
        $observation = Convert-RowToObservation -Row $row -Role $role -VisibleIds $visibleIds -ReadMainWindowHandle:($ReadMainWindowHandle -and $RootPids -contains $procId)
        $observations += $observation
        # Never overwrite an existing tracked entry: launch-time entries are
        # captured from Process.StartTime, while this CIM-derived value rounds
        # differently (sub-millisecond), which would break exact PID + creation
        # time comparisons.
        if (-not $script:TrackedProcesses.ContainsKey([string]$procId)) {
            $script:TrackedProcesses[[string]$procId] = $observation.creation_time
        }
        [void]$script:OwnedObservations.Add($observation)
    }
    return ,$observations
}

function Stop-TrackedProcesses {
    # Last-resort sweep for processes this run tracked (HUD roots and their
    # Observer children). Every kill is guarded by PID + creation time; only
    # processes this run recorded are ever stopped. Never Kill($true); the
    # kill-on-close Job Object handles the full tree at harness cleanup.
    param([string]$Reason = 'cleanup')
    $remaining = @()
    foreach ($pidText in @($script:TrackedProcesses.Keys)) {
        $pidValue = [int]$pidText
        $expectedCreation = [string]$script:TrackedProcesses[$pidText]
        $candidate = $null
        try { $candidate = [Diagnostics.Process]::GetProcessById($pidValue) } catch { continue }
        try {
            $candidate.Refresh()
            $actualCreation = ([DateTimeOffset][datetime]$candidate.StartTime.ToUniversalTime()).ToString('o')
            $expectedDt = [DateTimeOffset]::Parse($expectedCreation)
            $actualDt = [DateTimeOffset]::Parse($actualCreation)
            if ([Math]::Abs(($actualDt - $expectedDt).TotalSeconds) -lt 2.0) {
                try { Stop-Process -Id $pidValue -Force -ErrorAction Stop } catch { }
            }
        }
        finally { $candidate.Dispose() }
    }
    Start-Sleep -Milliseconds 500
    foreach ($pidText in @($script:TrackedProcesses.Keys)) {
        $pidValue = [int]$pidText
        try { [void][Diagnostics.Process]::GetProcessById($pidValue); $remaining += $pidValue } catch { }
    }
    return $remaining
}

function Remove-TempDirectoryWithRetry {
    # Retry here only absorbs the OS asynchronous-delete quirk (an index still
    # mapped for a few hundred ms after the child died); it never retries a
    # lock or access-denied: that case rethrows immediately as a cleanup
    # failure (the run then FAILs). The whole operation is bounded.
    param([Parameter(Mandatory)][string]$Path)
    $canonical = Assert-LocalPackageSafePath -Path $Path -AllowedRoots @($script:TempAllowedRoot) -RepoRoot $script:RepoRoot
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        if (-not (Test-Path -LiteralPath $canonical)) { return $true }
        try {
            Remove-Item -LiteralPath $canonical -Recurse -Force -ErrorAction Stop
            return $true
        } catch [System.UnauthorizedAccessException] {
            $script:CleanupAccessDenied = $true
            return $false
        } catch [System.IO.IOException] {
            if ($script:CleanupAccessDenied) { return $false }
            Start-Sleep -Milliseconds 400
        }
    }
    return (-not (Test-Path -LiteralPath $canonical))
}

function Add-StepResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Pass,
        [long]$DurationMs = 0,
        [AllowNull()]$Detail = $null
    )
    [void]$script:Steps.Add([pscustomobject][ordered]@{
        name = $Name
        pass = $Pass
        duration_ms = $DurationMs
        detail = $Detail
    })
    if (-not $Pass) { [void]$script:Failures.Add($Name) }
}

function Invoke-AcceptanceStep {
    # Bounded external command step via the shared production helper. A step
    # timeout or non-zero exit records a FAIL step and returns $null; an
    # overall deadline violation stays fatal.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    Assert-HarnessDeadline -Context $script:Harness -Stage $Name
    [void]$script:ExecutedCommands.Add([pscustomobject][ordered]@{
        tool = $FilePath
        arguments = @($Arguments)
        timeout_seconds = $TimeoutSeconds
    })
    $stepStarted = [DateTimeOffset]::UtcNow
    try {
        $result = Invoke-LocalHarnessCommand -Context $script:Harness -Name $Name -FilePath $FilePath `
            -Arguments $Arguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds `
            -Scenario 'daily-use-acceptance' -HideConsoleWindow
        $pass = ($result.exit_code -eq 0)
        Add-StepResult -Name $Name -Pass $pass -DurationMs $result.duration_ms -Detail "exit_code=$($result.exit_code) timeout_detected=$($result.timeout_detected)"
        return $result.exit_code
    }
    catch {
        $message = $_.Exception.Message
        if ($message -like '*deadline exceeded*') { throw }
        Add-StepResult -Name $Name -Pass $false -DurationMs ([int]([DateTimeOffset]::UtcNow - $stepStarted).TotalMilliseconds) -Detail "timeout: $message"
        return $null
    }
}

function Start-AcceptanceHud {
    # GUI HUD launch: direct exe start (no launcher, no shell wrapper),
    # registered as an owned process in the kill-on-close Job Object.
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string[]]$Arguments = @()
    )
    $run = Start-LocalHarnessProcess -Context $script:Harness -FilePath $FilePath -ArgumentList $Arguments `
        -Kind $Kind -WorkingDirectory $WorkingDirectory -Scenario 'daily-use-acceptance' -ShowWindow
    [void]$script:ExecutedCommands.Add([pscustomobject][ordered]@{
        tool = $FilePath
        arguments = @($Arguments)
        kind = $Kind
    })
    $run.Record.Process.Refresh()
    $script:TrackedProcesses[[string]$run.Record.ProcessId] = $run.Record.Process.StartTime.ToUniversalTime().ToString('o')
    return $run
}

function Get-ObserverChildren {
    # Returns the Observer child rows for a HUD PID. The result MUST be
    # enumerated (return $children, NOT ,$children): a comma-wrapped return
    # makes every caller's @(...) a nested array whose Count is always 1,
    # which hides the 0-observer case and turns the 2-observer case into
    # dead code.
    param([Parameter(Mandatory)][int]$HudPid)
    $rows = Get-ProcessRows
    $children = @()
    foreach ($row in $rows) {
        if ([int]$row.ParentProcessId -eq $HudPid -and [string]$row.Name -ieq 'agent-observer-poc.exe') {
            $children += $row
        }
    }
    return $children
}

function Test-ProcessAlive {
    # PID + creation time liveness. ToleranceSeconds > 0 allows comparing
    # creation times captured from different sources (Win32_Process
    # CreationDate vs Process.StartTime), which can differ by sub-millisecond
    # rounding; exact string comparison stays the default.
    param(
        [Parameter(Mandatory)][int]$PidValue,
        [Parameter(Mandatory)][string]$CreationTime,
        [double]$ToleranceSeconds = 0
    )
    try {
        $candidate = [Diagnostics.Process]::GetProcessById($PidValue)
        try {
            $candidate.Refresh()
            $actual = $candidate.StartTime.ToUniversalTime().ToString('o')
            if ($ToleranceSeconds -le 0) {
                return ($actual -eq $CreationTime)
            }
            $actualDt = [DateTimeOffset]::Parse($actual)
            $expectedDt = [DateTimeOffset]::Parse($CreationTime)
            return ([Math]::Abs(($actualDt - $expectedDt).TotalSeconds) -le $ToleranceSeconds)
        }
        finally { $candidate.Dispose() }
    }
    catch { return $false }
}

function Invoke-AcceptanceCleanup {
    # Full cleanup: dispose the Job Object (terminates the entire owned tree),
    # verify every recorded PID + creation time is gone, sweep tracked
    # processes, remove disposable directories. Failures are recorded and must
    # force a FAIL result.
    $script:TempDirsCleaned = $true
    foreach ($tempDir in $script:TempDirs) {
        if (-not (Remove-TempDirectoryWithRetry -Path $tempDir)) { $script:TempDirsCleaned = $false }
    }
    if ($null -eq $script:Harness) { return }
    $script:CleanupMeasure = Close-LocalHarnessRun -Context $script:Harness -Reason 'acceptance-end'
    $trackedRemaining = @(Stop-TrackedProcesses -Reason 'final')
    if ($trackedRemaining.Count -gt 0) {
        $note = "tracked processes remaining: $($trackedRemaining -join ',')"
        $script:CleanupMeasure = [pscustomobject]@{
            cleanup_success = $false
            owned_processes_remaining = ($script:CleanupMeasure.owned_processes_remaining + $trackedRemaining.Count)
            cleanup_failure = if ($script:CleanupMeasure.cleanup_failure) { "$($script:CleanupMeasure.cleanup_failure); $note" } else { $note }
        }
    }
}

try {
    # ------------------------------------------------------------------
    # 0. Preflight: disposable copy outside the repository + manifest integrity
    # ------------------------------------------------------------------
    $script:Harness = New-HarnessLifecycle -Name 'daily-use-local-package-acceptance' `
        -RunRoot $EvidenceRoot -Scenario 'daily-use-acceptance' `
        -OverallTimeoutSeconds $OverallDeadlineSeconds -HeartbeatSeconds 30

    $manifestPath = Join-Path $PackageRoot 'package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "package manifest not found: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifestFileCount = @($manifest.files).Count
    $script:TempDirs.Add($disposableDir)
    if (Test-Path -LiteralPath $disposableDir) { Remove-Item -LiteralPath $disposableDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $disposableDir | Out-Null
    $integrityFailures = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($manifest.files)) {
        $source = Join-Path $PackageRoot ([string]$entry.path)
        if (-not (Test-Path -LiteralPath $source)) { [void]$integrityFailures.Add("missing $($entry.path)"); continue }
        Copy-Item -LiteralPath $source -Destination (Join-Path $disposableDir ([string]$entry.path)) -Force
        $actual = (Get-FileHash -LiteralPath (Join-Path $disposableDir ([string]$entry.path)) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne [string]$entry.sha256) { [void]$integrityFailures.Add("hash mismatch $($entry.path)") }
    }
    Add-StepResult -Name ('manifest integrity (disposable copy, {0} files)' -f $manifestFileCount) `
        -Pass ($integrityFailures.Count -eq 0) -Detail (@($integrityFailures) -join '; ')
    $wrappedManifest = [ordered]@{
        run_id = $RunId
        package_manifest = $manifest
    }
    Write-Utf8File -Path (Join-Path $EvidenceRoot 'package-manifest.json') -Content ($wrappedManifest | ConvertTo-Json -Depth 10)

    $repoOutside = -not ($disposableDir.StartsWith($script:RepoRoot, [StringComparison]::OrdinalIgnoreCase))
    Add-StepResult -Name 'disposable package directory is outside the repository' -Pass $repoOutside -Detail $disposableDir

    $hudExe = Join-Path $disposableDir 'AgentObserver.Hud.exe'

    # ------------------------------------------------------------------
    # 1. Static test steps (real offline commands, bounded owned processes)
    # ------------------------------------------------------------------
    $cargoFmtArgs = Get-LocalHarnessCargoFmtArguments
    [void](Invoke-AcceptanceStep -Name ('cargo ' + ($cargoFmtArgs -join ' ')) -FilePath 'cargo' `
        -Arguments $cargoFmtArgs -WorkingDirectory $script:RepoRoot -TimeoutSeconds 60)

    # The 4 runner::pi_prompt_tests spawn real child processes with internal
    # settle timeouts; under the default full parallelism on a loaded machine
    # they can exceed those timeouts. Limited parallelism runs the identical
    # 197-test suite deterministically.
    $cargoTestArgs = Get-LocalHarnessCargoTestArguments
    [void](Invoke-AcceptanceStep -Name ('cargo ' + ($cargoTestArgs -join ' ')) -FilePath 'cargo' `
        -Arguments $cargoTestArgs -WorkingDirectory $script:RepoRoot -TimeoutSeconds 150)

    $dotnetBuildArgs = Get-LocalHarnessDotnetBuildArguments -ProjectPath (Join-Path $script:RepoRoot 'hud\AgentObserver.Hud\AgentObserver.Hud.csproj')
    [void](Invoke-AcceptanceStep -Name ('dotnet ' + ($dotnetBuildArgs -join ' ')) -FilePath 'dotnet' `
        -Arguments $dotnetBuildArgs -WorkingDirectory $script:RepoRoot -TimeoutSeconds 90)

    # HUD self-tests run from the repository publish directory so the replay
    # fixture under hud\fixtures is discoverable; the exe must be byte-identical
    # to the packaged one or the step fails.
    $repoPublishHud = Join-Path $script:RepoRoot 'hud\AgentObserver.Hud\bin\Release\netcoreapp3.0\publish\AgentObserver.Hud.exe'
    $packageHudExe = Join-Path $disposableDir 'AgentObserver.Hud.exe'
    $selfTestExe = $repoPublishHud
    $selfTestLocation = 'repository publish directory'
    if (-not (Test-Path -LiteralPath $repoPublishHud)) {
        $selfTestExe = $packageHudExe
        $selfTestLocation = 'package directory (fixture fallback)'
    }
    else {
        $repoHash = (Get-FileHash -LiteralPath $repoPublishHud -Algorithm SHA256).Hash.ToLowerInvariant()
        $packageHash = (Get-FileHash -LiteralPath $packageHudExe -Algorithm SHA256).Hash.ToLowerInvariant()
        Add-StepResult -Name 'self-test exe matches packaged exe (SHA256)' -Pass ($repoHash -eq $packageHash) -Detail "repo=$repoHash package=$packageHash"
    }
    [void](Invoke-AcceptanceStep -Name ("HUD self-tests (from {0})" -f $selfTestLocation) -FilePath $selfTestExe `
        -Arguments @('--self-test') -WorkingDirectory (Split-Path -Parent $selfTestExe) -TimeoutSeconds 45)

    # ------------------------------------------------------------------
    # 2. Baseline visible windows
    # ------------------------------------------------------------------
    Assert-HarnessDeadline -Context $script:Harness -Stage 'baseline'
    $baselineIds = Get-VisibleWindowSnapshot -Stage 'baseline'
    if ($null -eq $baselineIds) { throw "visibility probe failed at baseline: $script:VisibilityProbeFailure" }
    $script:BaselineVisibleIds = @($baselineIds)
    Write-Utf8File -Path (Join-Path $EvidenceRoot 'visible-window-baseline.json') -Content (
        [pscustomobject]@{
            run_id = $RunId
            captured_at = [DateTimeOffset]::UtcNow.ToString('o')
            probe_reliable = $true
            visible_window_process_ids = @($script:BaselineVisibleIds)
        } | ConvertTo-Json -Depth 4)

    # ------------------------------------------------------------------
    # 3. Main launch: double-click equivalent, no arguments, outside repo
    # ------------------------------------------------------------------
    Assert-HarnessDeadline -Context $script:Harness -Stage 'main-launch'
    $mainRun = Start-AcceptanceHud -Kind 'hud-main' -FilePath $hudExe -WorkingDirectory $disposableDir
    $mainPid = $mainRun.Record.ProcessId

    $hudWindowShown = Wait-LocalHarnessConditionResult -Context $script:Harness -Stage 'main-launch-window' -TimeoutSeconds 20 -Condition {
        $ids = [AgentObserverDailyUse.WindowProbe]::VisibleWindowProcessIds()
        ($ids -contains $mainPid)
    }
    if ($hudWindowShown) { [void]$script:HudWindowPids.Add($mainPid) }
    Add-StepResult -Name 'direct exe launch shows HUD window (no launcher)' -Pass $hudWindowShown -Detail "hud_pid=$mainPid"

    # Observe for 6 seconds: window + process tree sampling.
    # Audit semantics follow the accepted visibility-audit method: a failure is
    # any owned-tree process showing a visible window (the HUD window itself is
    # expected) or any newly visible console host. Unrelated new windows are
    # recorded as unattributed diagnostics only.
    $observerChildCount = 0
    $observerMainWindowHandle = -1L
    $visibleOwnedUnexpected = 0
    $newVisibleConsoleHosts = 0
    $unattributedNewVisible = [Collections.Generic.HashSet[int]]::new()
    $observationDeadline = [DateTimeOffset]::UtcNow.AddSeconds(6)
    while ([DateTimeOffset]::UtcNow -lt $observationDeadline) {
        Assert-HarnessDeadline -Context $script:Harness -Stage 'main-observation'
        $tree = Get-OwnedProcessTree -RootPids @($mainPid) -Stage 'main-observation' -ReadMainWindowHandle
        $observerRows = @($tree | Where-Object { $_.name -ieq 'agent-observer-poc.exe' })
        $observerChildCount = $observerRows.Count
        if ($observerChildCount -gt 0) {
            $observerPid = [int]$observerRows[0].pid
            try {
                $observerProcess = [Diagnostics.Process]::GetProcessById($observerPid)
                try { $observerProcess.Refresh(); $observerMainWindowHandle = $observerProcess.MainWindowHandle.ToInt64() }
                finally { $observerProcess.Dispose() }
            } catch { $observerMainWindowHandle = -1L }
        }
        foreach ($process in $tree) {
            if ($process.visible_window_observed -and [int]$process.pid -ne $mainPid) { $visibleOwnedUnexpected++ }
        }
        $visibleIds = @([AgentObserverDailyUse.WindowProbe]::VisibleWindowProcessIds())
        $ownedPids = @($tree | ForEach-Object { [int]$_.pid })
        $rowsByName = @{}
        foreach ($row in (Get-ProcessRows)) { $rowsByName[[string][int]$row.ProcessId] = [string]$row.Name }
        foreach ($visibleId in $visibleIds) {
            if ($script:BaselineVisibleIds -notcontains [int]$visibleId -and $visibleId -ne $mainPid) {
                $processName = [string]$rowsByName[[string]$visibleId]
                if ($script:ConsoleHostNames -contains $processName.ToLowerInvariant()) { $newVisibleConsoleHosts++ }
                if ($ownedPids -notcontains [int]$visibleId) { [void]$unattributedNewVisible.Add([int]$visibleId) }
            }
        }
        Wait-HarnessSleep -Context $script:Harness -Stage 'main-observation' -Milliseconds 1000
    }

    Add-StepResult -Name 'exactly one Observer child process' -Pass ($observerChildCount -eq 1) -Detail "observer_children=$observerChildCount"
    Add-StepResult -Name 'Observer child MainWindowHandle = 0' -Pass ($observerMainWindowHandle -eq 0) -Detail "main_window_handle=$observerMainWindowHandle"
    Add-StepResult -Name 'no visible PowerShell/cmd/conhost/Windows Terminal owned' -Pass ($visibleOwnedUnexpected -eq 0 -and $newVisibleConsoleHosts -eq 0) -Detail "visible_owned_unexpected=$visibleOwnedUnexpected new_visible_console_hosts=$newVisibleConsoleHosts unattributed_new_visible=$($unattributedNewVisible.Count)"

    # ------------------------------------------------------------------
    # 4. Single instance: second double-click exits quietly within 5s
    # ------------------------------------------------------------------
    Assert-HarnessDeadline -Context $script:Harness -Stage 'single-instance'
    $secondStarted = [DateTimeOffset]::UtcNow
    $secondRun = Start-AcceptanceHud -Kind 'hud-second-instance' -FilePath $hudExe -WorkingDirectory $disposableDir
    $secondPid = $secondRun.Record.ProcessId
    $secondCreation = [string]$script:TrackedProcesses[[string]$secondPid]

    $secondExitedQuietly = $false
    $secondExitCode = $null
    try {
        $secondExitCode = Wait-HarnessProcess -Context $script:Harness -Record $secondRun.Record `
            -Stage 'second-instance-exit' -TimeoutSeconds 5
        $secondExitedQuietly = $true
    } catch {
        $message = $_.Exception.Message
        if ($message -like '*deadline exceeded*') { throw }
        # Wait-HarnessProcess already terminated the second instance record.
        $secondExitedQuietly = $false
    }
    $secondExitSeconds = if ($secondExitedQuietly) { [Math]::Round(([DateTimeOffset]::UtcNow - $secondStarted).TotalSeconds, 2) } else { $null }

    $firstStillAlive = Test-ProcessAlive -PidValue $mainPid -CreationTime ([string]$script:TrackedProcesses[[string]$mainPid])
    $treeAfterSecond = Get-OwnedProcessTree -RootPids @($mainPid) -Stage 'single-instance-after'
    $observerChildrenAfterSecond = @($treeAfterSecond | Where-Object { $_.name -ieq 'agent-observer-poc.exe' }).Count
    $secondWindowIds = @([AgentObserverDailyUse.WindowProbe]::VisibleWindowProcessIds())
    $rowsBySecondName = @{}
    foreach ($row in (Get-ProcessRows)) { $rowsBySecondName[[string][int]$row.ProcessId] = [string]$row.Name }
    $secondNewVisible = @($secondWindowIds | Where-Object { $script:BaselineVisibleIds -notcontains [int]$_ -and $_ -ne $mainPid })
    $secondNewConsoleHosts = @($secondNewVisible | Where-Object {
        $script:ConsoleHostNames -contains ([string]$rowsBySecondName[[string][int]$_]).ToLowerInvariant()
    })

    $singleInstancePass = ($secondExitedQuietly -and $secondExitCode -eq 0 -and $firstStillAlive -and $observerChildrenAfterSecond -eq 1 -and $secondNewConsoleHosts.Count -eq 0)
    Add-StepResult -Name 'second launch exits quietly within 5s (exit 0)' -Pass ($secondExitedQuietly -and $secondExitCode -eq 0) -Detail "exit_code=$secondExitCode seconds=$secondExitSeconds"
    Add-StepResult -Name 'second launch leaves first HUD alive' -Pass $firstStillAlive -Detail "first_hud_alive=$firstStillAlive"
    Add-StepResult -Name 'second launch starts no second Observer' -Pass ($observerChildrenAfterSecond -eq 1) -Detail "observer_children=$observerChildrenAfterSecond"
    Add-StepResult -Name 'second launch shows no error dialog or terminal' -Pass ($secondNewConsoleHosts.Count -eq 0) -Detail "new_console_hosts=$($secondNewConsoleHosts.Count) new_visible_beyond_hud=$($secondNewVisible.Count)"

    Write-Utf8File -Path (Join-Path $EvidenceRoot 'single-instance-summary.json') -Content (
        [pscustomobject]@{
            run_id = $RunId
            first_hud_pid = $mainPid
            first_hud_creation_time = [string]$script:TrackedProcesses[[string]$mainPid]
            second_launch_pid = $secondPid
            second_launch_creation_time = $secondCreation
            second_exited = [bool]$secondExitedQuietly
            second_exit_code = $secondExitCode
            second_exit_seconds = $secondExitSeconds
            second_exit_within_5s = [bool]$secondExitedQuietly
            first_hud_alive_after_second = $firstStillAlive
            observer_children_after_second = $observerChildrenAfterSecond
            second_new_visible_window_process_ids = @($secondNewVisible)
            pass = $singleInstancePass
        } | ConvertTo-Json -Depth 4)

    # ------------------------------------------------------------------
    # 5. Graceful close: owned Observer exits with the HUD
    # ------------------------------------------------------------------
    Assert-HarnessDeadline -Context $script:Harness -Stage 'close'
    $closedWindowCount = [AgentObserverDailyUse.WindowProbe]::CloseVisibleWindowsOfProcess($mainPid)
    $mainExited = Wait-LocalHarnessConditionResult -Context $script:Harness -Stage 'close-wait-hud' -TimeoutSeconds 15 -Condition {
        -not (Test-ProcessAlive -PidValue $mainPid -CreationTime ([string]$script:TrackedProcesses[[string]$mainPid]))
    }
    if (-not $mainExited) {
        # Last resort: stop the recorded record only (PID + creation time
        # guarded, through the harness record). The Observer child is covered
        # by the kill-on-close Job Object at final cleanup.
        Stop-HarnessProcessRecord -Record $mainRun.Record -Reason 'hud-refused-graceful-close' | Out-Null
    }
    Add-StepResult -Name 'graceful close exits the HUD' -Pass $mainExited -Detail "wm_close_posted=$closedWindowCount"

    $observerExited = Wait-LocalHarnessConditionResult -Context $script:Harness -Stage 'close-wait-observer' -TimeoutSeconds 10 -Condition {
        (@(Get-ObserverChildren -HudPid $mainPid).Count -eq 0) -and -not (Test-ProcessAlive -PidValue $mainPid -CreationTime ([string]$script:TrackedProcesses[[string]$mainPid]))
    }
    $childrenAfterClose = @(Get-ObserverChildren -HudPid $mainPid).Count
    Add-StepResult -Name 'owned Observer exits after HUD close' -Pass ($observerExited -and $childrenAfterClose -eq 0) -Detail "observer_children_after_close=$childrenAfterClose"

    # ------------------------------------------------------------------
    # 6. Screenshot run: QA flags prove live updates from the packaged exe
    # ------------------------------------------------------------------
    Assert-HarnessDeadline -Context $script:Harness -Stage 'screenshot-run'
    $screenshotPath = Join-Path $EvidenceRoot 'hud-screenshot.png'
    $screenshotLog = Join-Path $EvidenceRoot 'hud-diagnostic.log'
    if (Test-Path -LiteralPath $screenshotPath) { Remove-Item -LiteralPath $screenshotPath -Force }
    if (Test-Path -LiteralPath $screenshotLog) { Remove-Item -LiteralPath $screenshotLog -Force }
    $shotRun = Start-AcceptanceHud -Kind 'hud-screenshot' -FilePath $hudExe -WorkingDirectory $disposableDir `
        -Arguments @('--screenshot-file', $screenshotPath, '--diagnostic-log', $screenshotLog, '--close-after-ms', '9000')
    $shotPid = $shotRun.Record.ProcessId

    # Poll during screenshot HUD lifetime for the spawned Observer child
    $shotObserverFound = $false
    $shotObsDetails = @()
    $pollWaitStart = [DateTimeOffset]::UtcNow
    $obsPidToTrack = $null
    while (([DateTimeOffset]::UtcNow - $pollWaitStart).TotalSeconds -lt 8 -and -not $shotRun.Record.Process.HasExited) {
        $children = @(Get-ObserverChildren -HudPid $shotPid)
        if ($children.Count -eq 1) {
            $obs = $children[0]
            $obsPid = [int]$obs.ProcessId
            $obsPidToTrack = $obsPid
            $obsCtime = [System.Xml.XmlConvert]::ToString([datetime]$obs.CreationDate.ToUniversalTime(), [System.Xml.XmlDateTimeSerializationMode]::Utc)
            $script:TrackedProcesses[[string]$obsPid] = $obsCtime
            $obsParentPid = [int]$obs.ParentProcessId
            $obsHandle = 0
            try {
                $pObj = [Diagnostics.Process]::GetProcessById($obsPid)
                $obsHandle = $pObj.MainWindowHandle.ToInt64()
                $pObj.Dispose()
            } catch { }

            $shotObsDetails = @([pscustomobject][ordered]@{
                process_id = $obsPid
                creation_time = $obsCtime
                parent_process_id = $obsParentPid
                main_window_handle = $obsHandle
            })
            $shotObserverFound = $true
            break
        }
        elseif ($children.Count -gt 1) {
            # multiple observers detected!
            $shotObsDetails = @($children | ForEach-Object {
                $cHandle = 0
                try {
                    $cObj = [Diagnostics.Process]::GetProcessById([int]$_.ProcessId)
                    $cHandle = $cObj.MainWindowHandle.ToInt64()
                    $cObj.Dispose()
                } catch { }
                [pscustomobject][ordered]@{
                    process_id = [int]$_.ProcessId
                    creation_time = [System.Xml.XmlConvert]::ToString([datetime]$_.CreationDate.ToUniversalTime(), [System.Xml.XmlDateTimeSerializationMode]::Utc)
                    parent_process_id = [int]$_.ParentProcessId
                    main_window_handle = $cHandle
                }
            })
            break
        }
        Wait-HarnessSleep -Context $script:Harness -Stage 'screenshot-observer-poll' -Milliseconds 200
    }

    # Production predicate from the shared helper (also exercised by
    # tools/test-screenshot-observer-regression.ps1): exactly one Observer,
    # parent == screenshot HUD PID, MainWindowHandle == 0.
    $shotObserverCountDuringRun = @($shotObsDetails).Count
    $shotObserverPass = Test-ScreenshotObserverBinding -ObserverDetails @($shotObsDetails) -HudPid $shotPid

    Add-StepResult -Name 'screenshot run Observer spawned while HUD alive' -Pass $shotObserverPass -Detail (
        "observer_count=$shotObserverCountDuringRun detail=$(ConvertTo-Json -Compress @($shotObsDetails))"
    )

    $remSec = [Math]::Max(1, [int][Math]::Floor((Get-HarnessRemainingSeconds -Context $script:Harness)))
    $shotWaitSec = [Math]::Min(30, $remSec)
    $shotExitedCleanly = $false
    $shotExitCode = $null
    try {
        $shotExitCode = Wait-HarnessProcess -Context $script:Harness -Record $shotRun.Record `
            -Stage 'screenshot-run-exit' -TimeoutSeconds $shotWaitSec
        $shotExitedCleanly = $true
    } catch {
        $message = $_.Exception.Message
        if ($message -like '*deadline exceeded*') { throw }
        # Wait-HarnessProcess already terminated the screenshot HUD record.
        $shotExitedCleanly = $false
    }
    Add-StepResult -Name 'screenshot run exits on its own' -Pass ($shotExitedCleanly -and $shotExitCode -eq 0) -Detail "exit_code=$shotExitCode timeout_detected=$(-not $shotExitedCleanly)"

    # Assert Observer count is strictly 0 after screenshot HUD exits
    $obsAfterAlive = Wait-LocalHarnessConditionResult -Context $script:Harness -Stage 'screenshot-observer-after-exit' -TimeoutSeconds 5 -Condition {
        if ($obsPidToTrack) {
            -not (Test-ProcessAlive -PidValue $obsPidToTrack -CreationTime ([string]$shotObsDetails[0].creation_time) -ToleranceSeconds 2.0)
        } else {
            ((Get-ObserverChildren -HudPid $shotPid).Count -eq 0)
        }
    }
    $shotObserverChildrenAfterExit = if ($obsAfterAlive) { 0 } else { 1 }
    if ($shotObserverChildrenAfterExit -eq 0 -and $obsPidToTrack) {
        [void]$script:TrackedProcesses.Remove([string]$obsPidToTrack)
    }
    Add-StepResult -Name 'screenshot run Observer exits after HUD exit' -Pass ($shotObserverChildrenAfterExit -eq 0) -Detail "observer_children_after_exit=$shotObserverChildrenAfterExit"

    $screenshotExists = (Test-Path -LiteralPath $screenshotPath)
    Add-StepResult -Name 'package HUD screenshot captured' -Pass $screenshotExists -Detail $screenshotPath
    Add-StepResult -Name 'screenshot run Observer exactly one while running and zero after exit' -Pass ($shotObserverPass -and $shotObserverChildrenAfterExit -eq 0) -Detail "observer_count_during_run=$shotObserverCountDuringRun observer_count_after_exit=$shotObserverChildrenAfterExit"


    $liveScanEvidence = ''
    if (Test-Path -LiteralPath $screenshotLog) {
        $logLines = @(Get-Content -LiteralPath $screenshotLog)
        $scanLines = @($logLines | Where-Object { $_ -match 'observer scan sessions=' -or $_ -match 'observer stdout line bytes=' })
        $renderLines = @($logLines | Where-Object { $_ -match 'scan rendered rows=' })
        $liveScanEvidence = "scan_lines=$($scanLines.Count) render_commits=$($renderLines.Count)"
        Add-StepResult -Name 'HUD receives live scan updates' -Pass ($scanLines.Count -gt 0) -Detail $liveScanEvidence
    }
    else {
        Add-StepResult -Name 'HUD receives live scan updates' -Pass $false -Detail 'diagnostic log missing'
    }

    # ------------------------------------------------------------------
    # 7. Missing observer package: HUD stays alive on unavailable state
    # ------------------------------------------------------------------
    Assert-HarnessDeadline -Context $script:Harness -Stage 'missing-observer'
    $script:TempDirs.Add($missingDir)
    if (Test-Path -LiteralPath $missingDir) { Remove-Item -LiteralPath $missingDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $missingDir | Out-Null
    foreach ($name in @('AgentObserver.Hud.exe', 'AgentObserver.Hud.dll', 'AgentObserver.Hud.deps.json', 'AgentObserver.Hud.runtimeconfig.json')) {
        Copy-Item -LiteralPath (Join-Path $disposableDir $name) -Destination (Join-Path $missingDir $name) -Force
    }
    $missingHudExe = Join-Path $missingDir 'AgentObserver.Hud.exe'
    $missingShot = Join-Path $EvidenceRoot 'missing-observer-hud.png'
    $missingLog = Join-Path $EvidenceRoot 'missing-observer-diagnostic.log'
    $missingRun = Start-AcceptanceHud -Kind 'hud-missing-observer' -FilePath $missingHudExe -WorkingDirectory $missingDir `
        -Arguments @('--screenshot-file', $missingShot, '--diagnostic-log', $missingLog, '--close-after-ms', '9000')
    $missingPid = $missingRun.Record.ProcessId
    $remMissingSec = [Math]::Max(1, [int][Math]::Floor((Get-HarnessRemainingSeconds -Context $script:Harness)))
    $missingWaitSec = [Math]::Min(30, $remMissingSec)
    $missingExited = $false
    $missingExitCode = $null
    try {
        $missingExitCode = Wait-HarnessProcess -Context $script:Harness -Record $missingRun.Record `
            -Stage 'missing-observer-exit' -TimeoutSeconds $missingWaitSec
        $missingExited = $true
    } catch {
        $message = $_.Exception.Message
        if ($message -like '*deadline exceeded*') { throw }
        $missingExited = $false
    }
    $missingTree = Get-OwnedProcessTree -RootPids @($missingPid) -Stage 'missing-observer'
    $missingObserverChildren = @($missingTree | Where-Object { $_.name -ieq 'agent-observer-poc.exe' }).Count

    $missingUnavailableEvidence = ''
    if (Test-Path -LiteralPath $missingLog) {
        $missingLines = @(Get-Content -LiteralPath $missingLog)
        $unavailableLines = @($missingLines | Where-Object { $_ -match 'observer unavailable' })
        $missingUnavailableEvidence = "unavailable_status_lines=$($unavailableLines.Count)"
    }

    $missingPass = ($missingExited -and $missingExitCode -eq 0 -and $missingObserverChildren -eq 0 -and (Test-Path -LiteralPath $missingShot) -and $missingUnavailableEvidence -match 'unavailable_status_lines=([1-9])')
    Add-StepResult -Name 'missing observer: HUD exits cleanly, no crash' -Pass ($missingExited -and $missingExitCode -eq 0) -Detail "exit_code=$missingExitCode"
    Add-StepResult -Name 'missing observer: no Observer child spawned' -Pass ($missingObserverChildren -eq 0) -Detail "observer_children=$missingObserverChildren"
    Add-StepResult -Name 'missing observer: Observer unavailable state shown' -Pass ($missingUnavailableEvidence -match 'unavailable_status_lines=([1-9])') -Detail "$missingUnavailableEvidence; screenshot=$(Test-Path -LiteralPath $missingShot)"

    Write-Utf8File -Path (Join-Path $EvidenceRoot 'missing-observer-summary.json') -Content (
        [pscustomobject]@{
            run_id = $RunId
            hud_pid = $missingPid
            package_directory = $missingDir
            observer_exe_present = $false
            hud_exited = [bool]$missingExited
            hud_exit_code = $missingExitCode
            observer_children = $missingObserverChildren
            observer_unavailable_evidence = $missingUnavailableEvidence
            screenshot_captured = (Test-Path -LiteralPath $missingShot)
            pass = $missingPass
        } | ConvertTo-Json -Depth 4)

    # ------------------------------------------------------------------
    # 8. Final residual check
    # ------------------------------------------------------------------
    Assert-HarnessDeadline -Context $script:Harness -Stage 'residual'
    Wait-HarnessSleep -Context $script:Harness -Stage 'residual' -Seconds 3
    $residualVisibleIds = Get-VisibleWindowSnapshot -Stage 'residual'
    $residualOwned = @()
    foreach ($pidText in @($script:TrackedProcesses.Keys)) {
        if (Test-ProcessAlive -PidValue ([int]$pidText) -CreationTime ([string]$script:TrackedProcesses[$pidText]) -ToleranceSeconds 2.0) {
            $residualOwned += [int]$pidText
        }
    }
    $residualNewVisible = @($residualVisibleIds | Where-Object { $script:BaselineVisibleIds -notcontains [int]$_ })
    $rowsByResidualName = @{}
    foreach ($row in (Get-ProcessRows)) { $rowsByResidualName[[string][int]$row.ProcessId] = [string]$row.Name }
    $residualNewConsoleHosts = @($residualNewVisible | Where-Object {
        $script:ConsoleHostNames -contains ([string]$rowsByResidualName[[string][int]$_]).ToLowerInvariant()
    })
    $residualPass = ($residualOwned.Count -eq 0 -and $residualNewConsoleHosts.Count -eq 0)

    Write-Utf8File -Path (Join-Path $EvidenceRoot 'final-residual-check.json') -Content (
        [pscustomobject]@{
            run_id = $RunId
            checked_at = [DateTimeOffset]::UtcNow.ToString('o')
            tracked_processes_remaining = @($residualOwned)
            new_visible_window_process_ids_vs_baseline = @($residualNewVisible)
            new_visible_console_host_process_ids = @($residualNewConsoleHosts)
            pass = $residualPass
        } | ConvertTo-Json -Depth 4)
    Add-StepResult -Name 'no residual owned processes after close' -Pass ($residualOwned.Count -eq 0) -Detail "remaining=$($residualOwned.Count)"
    Add-StepResult -Name 'no new visible console hosts after close' -Pass ($residualNewConsoleHosts.Count -eq 0) -Detail "new_console_hosts=$($residualNewConsoleHosts.Count) unattributed_new_visible=$($residualNewVisible.Count)"
}
catch {
    # ------------------------------------------------------------------
    # Failure path: full cleanup FIRST (measured), then evidence, then FAIL.
    # ------------------------------------------------------------------
    Invoke-AcceptanceCleanup
    $classification = Resolve-HarnessFailureClassification -Message ([string]$_.Exception.Message)
    $status = if ($classification.timed_out) { 'FAIL' } else { 'BLOCKED' }
    $deadlineExceeded = ($null -ne $script:Harness -and [DateTimeOffset]::UtcNow -ge $script:Harness.Deadline)
    $cleanupSuccess = ($null -ne $script:CleanupMeasure -and $script:CleanupMeasure.cleanup_success -and $script:TempDirsCleaned)
    $cleanupOwnedRemaining = if ($null -ne $script:CleanupMeasure) { [int]$script:CleanupMeasure.owned_processes_remaining } else { -1 }
    if (-not $cleanupSuccess) { $status = 'FAIL' }
    Write-Utf8File -Path (Join-Path $EvidenceRoot 'acceptance-summary.json') -Content (
        [pscustomobject][ordered]@{
            run_id = $RunId
            test = 'Daily-use Local Package v0.1 Repair 2'
            status = $status
            pass = $false
            error = $_.Exception.Message
            error_position = $_.InvocationInfo.PositionMessage
            error_script_stack = $_.ScriptStackTrace
            started_at = $startedAt.ToString('o')
            finished_at = [DateTimeOffset]::UtcNow.ToString('o')
            timeout_detected = ($classification.timed_out -or $deadlineExceeded)
            cleanup_success = $cleanupSuccess
            owned_processes_remaining = $cleanupOwnedRemaining
            cleanup_failure = if ($null -ne $script:CleanupMeasure) { $script:CleanupMeasure.cleanup_failure } else { $null }
            temp_dirs_cleaned = $script:TempDirsCleaned
            steps = @($script:Steps)
        } | ConvertTo-Json -Depth 5)
    Write-Utf8File -Path (Join-Path $EvidenceRoot 'visible-window-observations.jsonl') -Content (
        ($script:VisibilityObservations | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }) -join [Environment]::NewLine)
    Write-Utf8File -Path (Join-Path $EvidenceRoot 'process-tree.json') -Content (
        [pscustomobject]@{ run_id = $RunId; processes = @($script:OwnedObservations) } | ConvertTo-Json -Depth 5)
    exit 2
}

# Final cleanup attempt (normally nothing left to stop) BEFORE the summary is
# written, so the summary records the measured cleanup result.
Invoke-AcceptanceCleanup

# ------------------------------------------------------------------
# Evidence output
# ------------------------------------------------------------------
Write-Utf8File -Path (Join-Path $EvidenceRoot 'visible-window-observations.jsonl') -Content (
    ($script:VisibilityObservations | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }) -join [Environment]::NewLine)

$uniqueOwned = [ordered]@{}
foreach ($observation in $script:OwnedObservations) {
    $uniqueOwned[([string]$observation.pid) + '|' + ([string]$observation.creation_time)] = $observation
}
Write-Utf8File -Path (Join-Path $EvidenceRoot 'process-tree.json') -Content (
    [pscustomobject]@{ run_id = $RunId; processes = @($uniqueOwned.Values) } | ConvertTo-Json -Depth 5)

$visibilityProbeReliable = ($null -eq $script:VisibilityProbeFailure)
$cleanupSuccessFinal = ($null -ne $script:CleanupMeasure -and $script:CleanupMeasure.cleanup_success -and $script:TempDirsCleaned)
$finalStatus = if ($script:Failures.Count -eq 0 -and $visibilityProbeReliable -and $cleanupSuccessFinal) { 'PASS' } else { 'FAIL' }
if (-not $cleanupSuccessFinal) { [void]$script:Failures.Add('final cleanup') }

Write-Utf8File -Path (Join-Path $EvidenceRoot 'acceptance-summary.json') -Content (
    [pscustomobject][ordered]@{
        run_id = $RunId
        test = 'Daily-use Local Package v0.1 Repair 2'
        status = $finalStatus
        pass = ($finalStatus -eq 'PASS')
        evidence_run_id_verified = $false
        evidence_run_id_failures = @()
        package_root = $PackageRoot
        package_entry_point = 'AgentObserver.Hud.exe'
        package_manifest_file_count = $manifestFileCount
        deployment = 'framework-dependent'
        target_framework = 'netcoreapp3.0'
        required_runtime = 'Microsoft.WindowsDesktop.App 3.0 (or later 3.x) runtime'
        started_at = $startedAt.ToString('o')
        finished_at = [DateTimeOffset]::UtcNow.ToString('o')
        duration_ms = [int]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        overall_deadline_seconds = $OverallDeadlineSeconds
        timeout_detected = ([DateTimeOffset]::UtcNow -ge $script:Harness.Deadline)
        cleanup_success = $cleanupSuccessFinal
        owned_processes_remaining = if ($null -ne $script:CleanupMeasure) { [int]$script:CleanupMeasure.owned_processes_remaining } else { -1 }
        cleanup_failure = if ($null -ne $script:CleanupMeasure) { $script:CleanupMeasure.cleanup_failure } else { $null }
        temp_dirs_cleaned = $script:TempDirsCleaned
        visibility_probe_reliable = $visibilityProbeReliable
        visibility_probe_failure = $script:VisibilityProbeFailure
        baseline_visible_window_process_ids = @($script:BaselineVisibleIds)
        observed_visible_window_process_ids = @($script:ObservedVisibleIds)
        hud_window_process_ids = @($script:HudWindowPids)
        failures = @($script:Failures)
        steps = @($script:Steps)
        executed_commands = @($script:ExecutedCommands)
        # Offline facts actually enforced by the command lines above. There is
        # no network monitoring in this run, so network_requests_observed stays
        # null instead of asserting an unobserved zero.
        network_access_permitted = $false
        cargo_offline_enforced = $true
        dotnet_restore_disabled = $true
        network_requests_observed = $null
        model_calls = 0
        real_user_configuration_touched = $false
        bridge_installation_attempted = $false
    } | ConvertTo-Json -Depth 5)

# Verify evidence run_id consistency across all generated evidence files
$verifyResult = & (Join-Path $PSScriptRoot 'verify-evidence-run-id.ps1') -RunDir $EvidenceRoot -ExpectedRunId $RunId | ConvertFrom-Json
$summaryJsonPath = Join-Path $EvidenceRoot 'acceptance-summary.json'
$summaryObj = Get-Content -LiteralPath $summaryJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$summaryObj.evidence_run_id_verified = [bool]$verifyResult.pass
$summaryObj.evidence_run_id_failures = @($verifyResult.failures)
if (-not $verifyResult.pass) {
    $finalStatus = 'FAIL'
    $summaryObj.status = 'FAIL'
    $summaryObj.pass = $false
    $summaryObj.failures = @($summaryObj.failures) + @($verifyResult.failures)
}
Write-Utf8File -Path $summaryJsonPath -Content ($summaryObj | ConvertTo-Json -Depth 5)

# Write latest-run.json atomically (pointing at this run only)
$evidenceParent = Split-Path -Parent $EvidenceRoot
$evidenceBase = Split-Path -Parent $evidenceParent
$latestRunPath = Join-Path $evidenceBase 'latest-run.json'
$latestTmpPath = Join-Path $evidenceBase ("latest-run-{0}.json.tmp" -f ([Guid]::NewGuid().ToString('N')))
$latestRunContent = [pscustomobject][ordered]@{
    run_id = $RunId
    relative_run_path = ("runs/{0}" -f $RunId)
    status = $finalStatus
    started_at = $startedAt.ToString('o')
    finished_at = [DateTimeOffset]::UtcNow.ToString('o')
    duration_ms = [int]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
    timeout_detected = ($summaryObj.timeout_detected)
    cleanup_success = ($summaryObj.cleanup_success)
    owned_processes_remaining = [int]$summaryObj.owned_processes_remaining
    evidence_run_id_verified = ($summaryObj.evidence_run_id_verified)
} | ConvertTo-Json -Depth 5
Write-Utf8File -Path $latestTmpPath -Content $latestRunContent
Move-Item -LiteralPath $latestTmpPath -Destination $latestRunPath -Force

if ($finalStatus -ne 'PASS') { exit 1 }
exit 0
