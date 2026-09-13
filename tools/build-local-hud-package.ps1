# Windows x64 Alpha candidate builder (same entry point for local and CI).
#
# Builds a BRAND-NEW candidate package into
#   artifacts\candidates\<RunId>\agent-observer-hud-poc
# and NEVER touches the current stable daily-use package at
#   artifacts\agent-observer-hud-poc (refused explicitly).
#
# Evidence goes to a brand-new artifacts/release-integration/<RunId> root with a one-shot
# attempt.json marker (FileMode.CreateNew, no Force/Retry/Reset/Overwrite
# bypass) created BEFORE any child process starts, and a single terminal path
# that writes build-summary.json (FileMode.CreateNew).
#
# This stage proves build/test completion only. It never starts the HUD main window and
# never claims daily-use acceptance: status=OFFLINE, build_pass=true,
# acceptance_pass=false.
#
# Reused unchanged from the R3 Safety Repair 2 harness (local-package-harness.ps1
# + harness-lifecycle.ps1):
#   - the sole safe launcher (CREATE_SUSPENDED -> AssignProcessToJobObject ->
#     record PID + creation time -> ResumeThread), all windows hidden;
#   - the kill-on-close Job Object lifecycle and exact residual verification;
#   - concurrent bounded stdout/stderr drains (2 MiB whole-file cap, draining
#     continues past the cap);
#   - canonical path validation (rule 13) and the atomic staging promotion;
#   - the single terminal build verdict (build AND promotion AND cleanup AND
#     owned_processes_remaining == 0).

#Requires -Version 5.1
[CmdletBinding()]
param(
    # One-shot run identity. Empty = generated (timestamp + guid) BEFORE the
    # attempt marker exists.
    [string]$RunId = '',
    # Brand-new evidence root. Default:
    # docs/evidence/daily-use-candidate-package-build-v1/
    [string]$EvidenceRoot = '',
    # Candidate package root. Default:
    # artifacts\candidates\<RunId>\agent-observer-hud-poc
    [string]$PackageRoot = '',
    [string]$DotnetExe = 'dotnet',
    [switch]$AllowDependencyDownloads,
    [switch]$Supervised,
    [string]$StartGatePath = '',
    [string]$StartGateToken = '',
    [int]$OwnerPid = 0,
    [string]$OwnerCreationTime = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
    # Fixed wall clock (AGENTS.md rule 18): started_at and absolute_deadline_at
# are fixed immediately after parameter parse and are NEVER recomputed. Every
# wait clips to the remaining time of THIS deadline only.
# ---------------------------------------------------------------------------
$script:StartedAt = [DateTimeOffset]::UtcNow
$script:OverallDeadlineSeconds = if ($Supervised) { 1080 } else { 1200 }
$script:AbsoluteDeadlineAt = $script:StartedAt.AddSeconds($script:OverallDeadlineSeconds)

# A PS7 caller can pass a module search path containing incompatible versions.
# Select this interpreter's own Utility module, not the inherited search winner.
if ($PSVersionTable.PSVersion.Major -eq 5) {
    Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -Force -ErrorAction Stop
}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

. (Join-Path $PSScriptRoot 'local-package-harness.ps1')
. (Join-Path $PSScriptRoot 'alpha-package-content.ps1')

$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactsRoot = Get-LocalPackageFixedAllowedRoot -RepoRoot $script:RepoRoot
$stablePackageRoot = [IO.Path]::GetFullPath((Join-Path $artifactsRoot 'agent-observer-hud-poc'))
$windowHelperScript = Join-Path $PSScriptRoot 'local-package-window-probe-helper.ps1'

# Step budget (seconds). Every wait is additionally clipped to the remaining
# overall deadline by the shared harness (Get-HarnessClippedTimeoutSeconds).
$script:RuntimeListTimeoutSeconds = 30
$script:CargoTimeoutSeconds = 300
$script:DotnetTimeoutSeconds = 480
$script:SelfTestTimeoutSeconds = 45
# stdout/stderr drain completion bound per command (clipped to remaining time).
$script:DrainWaitMilliseconds = 10000
# Absolute whole-file cap per official log file.
$script:MaxLogBytesCap = 2097152

function Test-PromotedPackageIntegrity {
    # Integrity proof for the promoted candidate package: manifest present,
    # every file present, every SHA256 matching.
    param([Parameter(Mandatory)][string]$Root)
    try {
        $manifestPath = Join-Path $Root 'package-manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { return $false }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        foreach ($entry in @($manifest.files)) {
            $file = Join-Path $Root ([string]$entry.path)
            if (-not (Test-Path -LiteralPath $file)) { return $false }
            $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne [string]$entry.sha256) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Get-LocalStablePackageSnapshot {
    # Pure in-process snapshot (name + size + SHA256 per file) of the stable
    # daily-use package, used to PROVE it was not modified by this run.
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -ErrorAction Stop | Sort-Object Name)) {
        [void]$entries.Add([pscustomobject][ordered]@{
            name = $file.Name
            size_bytes = [int64]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    return [pscustomobject][ordered]@{
        root = $Root
        file_count = [int]$entries.Count
        entries = [object[]]$entries.ToArray()
    }
}

function Test-LocalPackageSnapshotsEqual {
    param($Before, $After)
    if ($null -eq $Before -and $null -eq $After) { return $true }
    if ($null -eq $Before -or $null -eq $After) { return $false }
    $before = @($Before.entries)
    $after = @($After.entries)
    if ($before.Count -ne $after.Count) { return $false }
    for ($index = 0; $index -lt $before.Count; $index++) {
        if ([string]$before[$index].name -cne [string]$after[$index].name) { return $false }
        if ([int64]$before[$index].size_bytes -ne [int64]$after[$index].size_bytes) { return $false }
        if ([string]$before[$index].sha256 -cne [string]$after[$index].sha256) { return $false }
    }
    return $true
}

function Invoke-LocalBuildWindowProbe {
    # Reuses the shared Job-owned window probe helper (hidden, bounded 3s,
    # clipped to the remaining deadline). Never returns an exception.
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
            -Kind ("window-probe-" + $Stage) -Scenario 'candidate-package-build' `
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

function Get-LocalBuildFailureClassification {
    # Top-level failure classification for final_status:
    #   BLOCKED -> a precondition refused the run (message carries BLOCKED)
    #   TIMEOUT -> a step/overall wait timeout or deadline violation
    #   FAIL    -> anything else
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    if ($Message -like '*BLOCKED*') { return 'BLOCKED' }
    if ($Message -like '*Timed out*' -or $Message -like '*deadline exceeded*') { return 'TIMEOUT' }
    return 'FAIL'
}

# ---------------------------------------------------------------------------
# Pre-flight: pure checks only. No cargo / dotnet / HUD / Observer process is
# started here, and nothing is created yet. A refusal here exits BEFORE the
# one-shot attempt marker exists, so no build attempt has been consumed.
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = ("{0:yyyyMMddTHHmmssfffZ}-{1}" -f $script:StartedAt.UtcDateTime, ([Guid]::NewGuid().ToString('n')))
}
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = Join-Path $artifactsRoot ('release-integration/' + $RunId)
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = Join-Path (Join-Path (Join-Path $artifactsRoot 'candidates') $RunId) 'agent-observer-hud-poc'
}
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)

$runDirectory = Join-Path $EvidenceRoot $RunId
$markerPath = Join-Path $EvidenceRoot 'attempt.json'
$buildSummaryPath = Join-Path $EvidenceRoot 'build-summary.json'

# The same maintained entry point owns its worker. No separate supervisor copy.
if (-not $Supervised) {
    $null = Assert-LocalPackageUnderFixedArtifactsRoot -PackageRoot $EvidenceRoot -RepoRoot $script:RepoRoot
    if (Test-Path -LiteralPath $EvidenceRoot) { throw 'Evidence root must be new; no retry in place' }
    $null = [IO.Directory]::CreateDirectory($EvidenceRoot)
    $ownerTime = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
    $null = New-LocalSafetyAttemptMarker -Path $markerPath -RunId $RunId -SupervisorPid $PID -SupervisorCreationTimeUtc $ownerTime
    $outer = $null; $outerCleanup = $null; $workerResult = $null; $outerError = $null
    try {
        $outer = New-HarnessLifecycle -Name 'alpha-package-owner' -RunRoot (Join-Path $EvidenceRoot 'outer') `
            -Scenario 'offline-package' -OverallTimeoutSeconds 1200 -HeartbeatSeconds 15 `
            -StartedAt $script:StartedAt -AbsoluteDeadlineAt $script:AbsoluteDeadlineAt
        $token = [Guid]::NewGuid().ToString('n')
        $gate = Join-Path $EvidenceRoot 'start-gate.json'
        $argsForWorker = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
            '-Supervised', '-RunId', $RunId, '-EvidenceRoot', $EvidenceRoot, '-PackageRoot', $PackageRoot,
            '-DotnetExe', $DotnetExe, '-StartGatePath', $gate, '-StartGateToken', $token,
            '-OwnerPid', [string]$PID, '-OwnerCreationTime', $ownerTime)
        if ($AllowDependencyDownloads) { $argsForWorker += '-AllowDependencyDownloads' }
        $null = Update-LocalSafetyAttemptMarker -Path $markerPath -Status RUNNING
        $worker = Start-LocalHarnessProcess -Context $outer -FilePath 'powershell.exe' -ArgumentList $argsForWorker `
            -Kind 'alpha-package-worker' -WorkingDirectory $script:RepoRoot -HideConsoleWindow `
            -StdoutLogPath (Join-Path $EvidenceRoot 'worker-stdout.log') -StderrLogPath (Join-Path $EvidenceRoot 'worker-stderr.log')
        $null = New-LocalSafetyStartGate -Path $gate -RunId $RunId -Token $token -SupervisorPid $PID -SupervisorCreationTimeUtc $ownerTime
        $workerResult = Wait-HarnessProcess -Context $outer -Record $worker.Record -Stage 'package-worker' -TimeoutSeconds 1140
        if (-not $worker.Launcher.WaitDrains((Get-HarnessClippedTimeoutMilliseconds -Context $outer -RequestedMilliseconds 5000 -Stage 'worker-drains'))) {
            throw 'Worker drains incomplete'
        }
        if ($workerResult -ne 0) { throw "Package worker failed: $workerResult" }
    } catch { $outerError = $_.Exception.Message }
    finally { if ($null -ne $outer) { $outerCleanup = Close-LocalHarnessRun -Context $outer -Reason 'package-owner-finally' } }
    $result = $null
    if (Test-Path -LiteralPath $buildSummaryPath) { $result = Get-Content -LiteralPath $buildSummaryPath -Raw | ConvertFrom-Json }
    $finished = [DateTimeOffset]::UtcNow
    $okay = $null -eq $outerError -and $null -ne $outerCleanup -and $outerCleanup.cleanup_success -and `
        $outerCleanup.owned_processes_remaining -eq 0 -and $finished -lt $script:AbsoluteDeadlineAt -and `
        $null -ne $result -and $result.build_pass
    $status = if ($okay) { 'OFFLINE' } elseif ($null -eq $result) { 'INCOMPLETE' } else { 'FAIL' }
    $null = Update-LocalSafetyAttemptMarker -Path $markerPath -Status FINISHED -FinalStatus $status
    Write-LocalSafetyEvidenceJson -Path (Join-Path $EvidenceRoot 'final-summary.json') -Object ([ordered]@{
        run_id=$RunId; final_status=$status; build_pass=[bool]$okay; acceptance_pass=$false
        started_at=$script:StartedAt.ToString('o'); finished_at=$finished.ToString('o')
        actual_duration_ms=[long]($finished-$script:StartedAt).TotalMilliseconds
        worker_exit_code=$workerResult; error=$outerError; cleanup=$outerCleanup
        network_access_permitted=[bool]$AllowDependencyDownloads; model_calls_started=0
        supervisor_hard_cutoff='UNPROVEN'; package_root=$PackageRoot
    })
    Write-Output "STATUS=$status EVIDENCE=$EvidenceRoot"
    if (-not $okay) { exit 1 }
    exit 0
}

# A worker may only consume a gate issued by its exact, still-live owner.
if (-not $StartGatePath -or -not $StartGateToken -or $OwnerPid -le 0 -or -not $OwnerCreationTime) {
    throw 'Worker refuses direct execution without exact owner and one-shot gate'
}
$gateDeadline = $script:StartedAt.AddSeconds(10)
while (-not (Test-Path -LiteralPath $StartGatePath)) {
    if ([DateTimeOffset]::UtcNow -ge $gateDeadline) { throw 'Start gate timeout' }
    Start-Sleep -Milliseconds 25
}
$ownerMarker = Read-LocalSafetyAttemptMarker -Path $markerPath
if ($ownerMarker.run_id -cne $RunId -or $ownerMarker.status -ne 'RUNNING' -or
    $ownerMarker.supervisor_pid -ne $OwnerPid -or $ownerMarker.supervisor_creation_time -cne $OwnerCreationTime -or
    -not (Test-LocalExactProcessAlive -ProcessId $OwnerPid -CreationTimeUtc $OwnerCreationTime)) { throw 'Invalid owner marker' }
$null = Invoke-LocalSafetyStartGateConsume -StartGatePath $StartGatePath -ExpectedToken $StartGateToken `
    -ExpectedRunId $RunId -ExpectedSupervisorPid $OwnerPid -ExpectedSupervisorCreationTimeUtc $OwnerCreationTime

try {
    # Strictly inside the fixed artifacts root (never inferred from PackageRoot).
    $null = Assert-LocalPackageUnderFixedArtifactsRoot -PackageRoot $PackageRoot -RepoRoot $script:RepoRoot

    # This stage must never overwrite the current stable daily-use package.
    $stableFull = $stablePackageRoot.TrimEnd('\', '/') + '\'
    if ($PackageRoot -ieq $stablePackageRoot -or $PackageRoot.StartsWith($stableFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "BLOCKED: refusing to target the current stable daily-use package ($stablePackageRoot); this stage only builds a brand-new candidate under artifacts\candidates\<RunId>\"
    }

    # The candidate package root must not exist yet (brand-new package).
    if (Test-Path -LiteralPath $PackageRoot) {
        throw "BLOCKED: candidate PackageRoot already exists: $PackageRoot (a candidate build never overwrites an existing directory)"
    }

    # The evidence root must be fresh: no prior attempt marker, no prior
    # summary, no stale run directory. One attempt per evidence root.
    foreach ($stale in @($buildSummaryPath, $runDirectory)) {
        if (Test-Path -LiteralPath $stale) {
            throw "BLOCKED: stale evidence path already exists: $stale (one attempt per evidence root; there is no force/retry/overwrite override)"
        }
    }

    foreach ($tool in @('cargo', 'rustc', $DotnetExe)) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw ("BLOCKED: prerequisite '{0}' is not on PATH" -f $tool)
        }
    }

    $hudProject = Join-Path $script:RepoRoot 'hud\AgentObserver.Hud\AgentObserver.Hud.csproj'
    if (-not (Test-Path -LiteralPath $hudProject)) {
        throw "BLOCKED: HUD project not found: $hudProject"
    }
    if (-not (Test-Path -LiteralPath $windowHelperScript)) {
        throw "BLOCKED: window probe helper not found: $windowHelperScript"
    }
} catch {
    Write-Warning $_.Exception.Message
    Write-Output ('PREFLIGHT_REFUSED=1')
    exit 3
}

$stableBefore = Get-LocalStablePackageSnapshot -Root $stablePackageRoot

$supervisorPid = [int]$PID
$supervisorCreationTimeUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')

# ---------------------------------------------------------------------------
# ONE-SHOT GATE: attempt.json with FileMode.CreateNew. From this point on the
# single build attempt has started; there is no retry, no second directory.
# ---------------------------------------------------------------------------
[IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null
[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
# The outer owner already created the durable attempt marker before launch.

$attemptCount = 1
$buildStartCount = 0
$buildStepsSucceeded = $false
$promotionSucceeded = $false
$failureReason = $null
$failureClassification = 'NONE'
$cleanupMeasure = $null
$stagingCleanupSuccess = $false
$stagingCleanupError = $null
$context = $null
$stagingRoot = $null
$backupRoot = $null
$cargoTargetDir = $null
$publishDir = $null
$previousCargoTarget = $null
$savedEnvironment = @{}
$cargoMetadata = $null
$rustSysroot = $null
$rustPathPolicy = $null
$privatePathScan = $null
$manifestFiles = @()
$manifest = $null
$manifestVerified = $false
$promotionResult = $null
$steps = @()
$script:CargoExitCode = $null
$script:PublishExitCode = $null
$script:SelfTestExitCode = $null
$baselineConsoleIds = [int[]]@()
$baselineProbeOk = $false
$finalConsoleIds = [int[]]@()
$visibleWindowsObservation = 'UNKNOWN'
$visibleWindowsCreated = $false
$newConsoleWindows = New-Object System.Collections.Generic.List[int]
$windowProbeError = $null
$modelCallsStarted = 0

try {
    # One lifecycle for the whole build: the fixed worker deadline and the
    # kill-on-close Job Object owning every process this run starts.
    $context = New-HarnessLifecycle -Name 'daily-use-candidate-package-build' `
        -RunRoot $runDirectory -Scenario 'candidate-package-build' `
        -OverallTimeoutSeconds $script:OverallDeadlineSeconds -HeartbeatSeconds 30 `
        -StartedAt $script:StartedAt -AbsoluteDeadlineAt $script:AbsoluteDeadlineAt

    # Baseline visible-console-host probe (hidden, Job-owned, bounded).
    $baselineProbe = Invoke-LocalBuildWindowProbe -Lifecycle $context `
        -OutputPath (Join-Path $runDirectory 'window-probe-baseline.json') -Stage 'window-probe-baseline'
    if ([string]$baselineProbe.status -ne 'ok') {
        throw ("BLOCKED: baseline window probe failed: {0}" -f $baselineProbe.error)
    }
    $baselineProbeOk = $true
    $baselineConsoleIds = [int[]]$baselineProbe.ids

    # The single real build starts now (dotnet / cargo / HUD children follow).
    $buildStartCount = 1

    # Verify the explicit SDK; no installed legacy Desktop runtime is needed.
    $runtimeStep = Invoke-LocalHarnessCommand -Context $context `
        -Name 'dotnet --version' -FilePath $DotnetExe `
        -Arguments @('--version') `
        -WorkingDirectory $script:RepoRoot -TimeoutSeconds $script:RuntimeListTimeoutSeconds `
        -Scenario 'candidate-package-build' -CaptureOutput -HideConsoleWindow `
        -StdoutLogPath (Join-Path $runDirectory 'dotnet-list-runtimes-stdout.log') `
        -StderrLogPath (Join-Path $runDirectory 'dotnet-list-runtimes-stderr.log')
    $steps += $runtimeStep
    if ($runtimeStep.exit_code -ne 0 -or $runtimeStep.stdout_truncated -or ([string]$runtimeStep.stdout).Trim() -cne '10.0.401') {
        throw 'BLOCKED: package requires the explicitly selected .NET SDK 10.0.401'
    }

    # --- Unique, disposable build directories (never the shared target/) ---

    $randomSuffix = [Guid]::NewGuid().ToString('N')
    $stagingRoot = Join-Path $artifactsRoot (".staging-candidate-hud-{0}" -f $randomSuffix)
    $backupRoot = Join-Path $artifactsRoot (".backup-candidate-hud-{0}" -f $randomSuffix)
    # A unique one-shot CARGO_TARGET_DIR per build (rule 9): the shared
    # target\debug / target\release trees are never written to.
    $cargoTargetDir = Join-Path $stagingRoot '.cargo-target'
    $publishDir = Join-Path $stagingRoot '.dotnet-publish'
    foreach ($dir in @($stagingRoot, $backupRoot)) {
        if (Test-Path -LiteralPath $dir) {
            throw "unique build directory already exists: $dir"
        }
    }

    # Path safety (rule 13): prove staging / backup / package are canonical,
    # inside the artifacts root, pairwise distinct and non-containing BEFORE
    # anything is created, moved or deleted.
    $null = Assert-LocalPackageSafeOperationRoots -StagingPath $stagingRoot -PackageRoot $PackageRoot `
        -BackupRoot $backupRoot -AllowedRoots @($artifactsRoot) -RepoRoot $script:RepoRoot

    New-Item -ItemType Directory -Force -Path $cargoTargetDir | Out-Null
    New-Item -ItemType Directory -Force -Path $publishDir | Out-Null
    $contentTests = Test-AlphaPackageContent -FixtureRoot (Join-Path $stagingRoot '.content-tests')
    Write-LocalSafetyEvidenceJson -Path (Join-Path $runDirectory 'content-tests.json') -Object $contentTests
    $privacyTests = Test-AlphaRustPathPrivacy -FixtureRoot (Join-Path $stagingRoot '.privacy-tests')
    Write-LocalSafetyEvidenceJson -Path (Join-Path $runDirectory 'path-privacy-tests.json') -Object $privacyTests
    # Copy only source inputs; neither legacy obj files nor new intermediates
    # may enter default SDK compile globs or modify the working checkout.
    $hudSource = Split-Path -Parent $hudProject
    $isolatedHud = Join-Path $stagingRoot '.hud-source'
    $null = [IO.Directory]::CreateDirectory($isolatedHud)
    foreach ($file in Get-ChildItem -LiteralPath $hudSource -File | Where-Object { $_.Extension -in @('.cs','.csproj') }) {
        Copy-Item -LiteralPath $file.FullName -Destination $isolatedHud
    }
    $hudProject = Join-Path $isolatedHud 'AgentObserver.Hud.csproj'

    # Route cargo into the unique target directory via the child environment.
    $previousCargoTarget = $env:CARGO_TARGET_DIR
    $env:CARGO_TARGET_DIR = $cargoTargetDir
    foreach ($key in @('DOTNET_CLI_TELEMETRY_OPTOUT','DOTNET_SKIP_FIRST_TIME_EXPERIENCE','DOTNET_CLI_HOME','NUGET_PACKAGES','CARGO_ENCODED_RUSTFLAGS')) {
        $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    }
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:DOTNET_CLI_HOME = Join-Path $stagingRoot '.dotnet-home'
    $env:NUGET_PACKAGES = Join-Path $stagingRoot '.nuget-packages'
    $configPath = Join-Path $stagingRoot 'NuGet.Config'
    $sources = if ($AllowDependencyDownloads) { '<add key="nuget.org" value="https://api.nuget.org/v3/index.json" />' } else { '' }
    [IO.File]::WriteAllText($configPath, ('<configuration><packageSources><clear />' + $sources + '</packageSources></configuration>'))

    $rustVersion = Invoke-LocalHarnessCommand -Context $context -Name 'rustc-version' -FilePath 'rustc' -Arguments @('--version') `
        -WorkingDirectory $script:RepoRoot -TimeoutSeconds 15 -CaptureOutput -HideConsoleWindow
    if ($rustVersion.exit_code -ne 0 -or $rustVersion.stdout -notmatch '^rustc 1\.98\.0 ') { throw 'BLOCKED: Rust 1.98.0 is required' }
    $sysroot = Invoke-LocalHarnessCommand -Context $context -Name 'rustc-sysroot' -FilePath 'rustc' -Arguments @('--print','sysroot') `
        -WorkingDirectory $script:RepoRoot -TimeoutSeconds 15 -CaptureOutput -HideConsoleWindow
    if ($sysroot.exit_code -ne 0 -or $sysroot.stdout_truncated) { throw 'Cannot resolve Rust sysroot' }
    $rustSysroot = ([string]$sysroot.stdout).Trim()
    $metadataArgs = @('metadata','--locked','--format-version','1')
    if (-not $AllowDependencyDownloads) { $metadataArgs += '--offline' }
    $metadataStep = Invoke-LocalHarnessCommand -Context $context -Name 'cargo-metadata' -FilePath 'cargo' -Arguments $metadataArgs `
        -WorkingDirectory $script:RepoRoot -TimeoutSeconds 90 -CaptureOutput -HideConsoleWindow `
        -StdoutLogPath (Join-Path $runDirectory 'cargo-metadata.json') -StderrLogPath (Join-Path $runDirectory 'cargo-metadata-stderr.log')
    if ($metadataStep.exit_code -ne 0 -or $metadataStep.stdout_truncated) { throw 'Cargo metadata unavailable or truncated' }
    $cargoMetadata = $metadataStep.stdout | ConvertFrom-Json
    $rustPathPolicy = Get-AlphaRustPathPolicy -RepoRoot $script:RepoRoot -RustSysroot $rustSysroot `
        -CargoMetadata $cargoMetadata -UserProfile $env:USERPROFILE `
        -ExistingEncodedFlags $env:CARGO_ENCODED_RUSTFLAGS -ExistingRustFlags $env:RUSTFLAGS
    # This process-only setting reaches dependency crates as well as our binary.
    # It is restored in finally; no user's Cargo config or source is changed.
    $env:CARGO_ENCODED_RUSTFLAGS = $rustPathPolicy.encoded_flags

    # --- Build and deterministic tests; only approved dependency downloads ---

    $cargoBuildArgs = Get-LocalHarnessCargoBuildArguments
    if ($AllowDependencyDownloads) { $cargoBuildArgs = @($cargoBuildArgs | Where-Object { $_ -ne '--offline' }) }
    $steps += Invoke-LocalHarnessCommand -Context $context `
        -Name ('cargo ' + ($cargoBuildArgs -join ' ')) -FilePath 'cargo' -Arguments $cargoBuildArgs `
        -WorkingDirectory $script:RepoRoot -TimeoutSeconds $script:CargoTimeoutSeconds `
        -Scenario 'candidate-package-build' -HideConsoleWindow `
        -StdoutLogPath (Join-Path $runDirectory 'cargo-build-stdout.log') `
        -StderrLogPath (Join-Path $runDirectory 'cargo-build-stderr.log')
    $script:CargoExitCode = [int]$steps[-1].exit_code
    if ($steps[-1].exit_code -ne 0) { throw ("cargo build exited with code {0}" -f $steps[-1].exit_code) }

    $testArgs = @('test','--locked','--all-targets','--offline')
    $testStep = Invoke-LocalHarnessCommand -Context $context -Name 'cargo-test' -FilePath 'cargo' -Arguments $testArgs `
        -WorkingDirectory $script:RepoRoot -TimeoutSeconds 180 -HideConsoleWindow `
        -StdoutLogPath (Join-Path $runDirectory 'cargo-test-stdout.log') -StderrLogPath (Join-Path $runDirectory 'cargo-test-stderr.log')
    $steps += $testStep
    if ($testStep.exit_code -ne 0) { throw 'Rust tests failed' }
    $dotnetPublishArgs = Get-AlphaPublishArguments -Project $hudProject -Output $publishDir `
        -Intermediate (Join-Path $stagingRoot '.dotnet-obj') -Config $configPath
    $steps += Invoke-LocalHarnessCommand -Context $context `
        -Name 'dotnet publish (self-contained win-x64)' -FilePath $DotnetExe -Arguments $dotnetPublishArgs `
        -WorkingDirectory $script:RepoRoot -TimeoutSeconds $script:DotnetTimeoutSeconds `
        -Scenario 'candidate-package-build' -HideConsoleWindow `
        -StdoutLogPath (Join-Path $runDirectory 'dotnet-publish-stdout.log') `
        -StderrLogPath (Join-Path $runDirectory 'dotnet-publish-stderr.log')
    $script:PublishExitCode = [int]$steps[-1].exit_code
    if ($steps[-1].exit_code -ne 0) { throw ("dotnet publish exited with code {0}" -f $steps[-1].exit_code) }

    $observerExe = Join-Path $cargoTargetDir 'release\agent-observer-poc.exe'
    if (-not (Test-Path -LiteralPath $publishDir)) { throw "publish output not found: $publishDir" }
    if (-not (Test-Path -LiteralPath $observerExe)) { throw "observer release binary not found in the unique cargo target dir: $observerExe" }

    $buildStepsSucceeded = $true

    # --- Stage package files -------------------------------------------------

    $stagingPackageDir = Join-Path $stagingRoot 'package'
    New-Item -ItemType Directory -Force -Path $stagingPackageDir | Out-Null
    Add-AlphaPackageContent -RepoRoot $script:RepoRoot -PublishRoot $publishDir -PackageRoot $stagingPackageDir `
        -ObserverExe $observerExe -CargoMetadata $cargoMetadata -RustSysroot $rustSysroot -NugetPackages $env:NUGET_PACKAGES

    # --- Manifest --------------------------------------------------------------

    $manifestFiles = @(Get-AlphaPackageManifestFiles -Root $stagingPackageDir)

    $manifest = [pscustomobject][ordered]@{
        package_name = 'agent-observer-hud-poc'
        package_kind = 'candidate'
        run_id = $RunId
        created_at = (Get-Date).ToUniversalTime().ToString('O')
        entry_point = 'AgentObserver.Hud.exe'
        observer_entry = 'agent-observer-poc.exe'
        deployment = 'self-contained-multi-file'
        target_framework = 'net10.0-windows'
        required_runtime = 'bundled .NET 10.0.12 win-x64'
        self_contained = $true
        build = [pscustomobject][ordered]@{
            cargo_profile = 'release'
            cargo_target_dir = 'unique-per-build (.staging-*/.cargo-target)'
            dotnet_configuration = 'Release'
            dotnet_publish_output = 'unique-per-build (.staging-*/.dotnet-publish)'
            dependency_downloads_permitted = [bool]$AllowDependencyDownloads
            rust_version = '1.98.0'
            dotnet_sdk = '10.0.401'
            runtime_version = '10.0.12'
        }
        files = $manifestFiles
        build_steps = @($steps | ForEach-Object { [pscustomobject][ordered]@{
            name = $_.name; exit_code = $_.exit_code; duration_ms = $_.duration_ms; timeout_detected = $_.timeout_detected
        } })
    }

    $manifestJson = $manifest | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $stagingPackageDir 'package-manifest.json'), $manifestJson)
    $scanSeconds = Get-HarnessClippedTimeoutSeconds -Context $context -RequestedSeconds 60 -Stage 'package-private-path-scan'
    $privatePathScan = Measure-AlphaPrivateBuildPaths -Root $stagingPackageDir -Prefixes $rustPathPolicy.private_prefixes `
        -Deadline ([DateTimeOffset]::UtcNow.AddSeconds($scanSeconds))
    Write-LocalSafetyEvidenceJson -Path (Join-Path $runDirectory 'package-private-path-scan.json') -Object $privatePathScan
    if (-not $privatePathScan.passed) { throw 'Private build paths remain in package; refusing promotion and ZIP creation' }

    # --- Manifest integrity self-check (staging) --------------------------------

    $parsed = $manifestJson | ConvertFrom-Json
    foreach ($entry in $parsed.files) {
        $staged = Join-Path $stagingPackageDir $entry.path
        if (-not (Test-Path -LiteralPath $staged)) { throw ("manifest self-check failed: missing {0}" -f $entry.path) }
        $actual = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne [string]$entry.sha256) { throw ("manifest self-check failed: hash mismatch for {0}" -f $entry.path) }
    }

    # --- Packaged HUD self-test in the staging directory ------------------------
    # Bounded owned process, hidden window, concurrent bounded drains.
    $stagedHudExe = Join-Path $stagingPackageDir 'AgentObserver.Hud.exe'
    $selfTestStarted = [DateTimeOffset]::UtcNow
    $sanityRun = Start-LocalHarnessProcess -Context $context -FilePath $stagedHudExe `
        -ArgumentList @('--self-test') -Kind 'staging-hud-self-test' -WorkingDirectory $stagingPackageDir `
        -Scenario 'candidate-package-build' -HideConsoleWindow `
        -StdoutLogPath (Join-Path $runDirectory 'hud-selftest-stdout.log') `
        -StderrLogPath (Join-Path $runDirectory 'hud-selftest-stderr.log')
    $script:SelfTestExitCode = [int](Wait-HarnessProcess -Context $context -Record $sanityRun.Record `
        -Stage 'staging-hud-self-test' -TimeoutSeconds $script:SelfTestTimeoutSeconds)
    $drainMs = Get-HarnessClippedTimeoutMilliseconds -Context $context -RequestedMilliseconds $script:DrainWaitMilliseconds -Stage 'staging-hud-self-test-drains'
    if (-not $sanityRun.Launcher.WaitDrains($drainMs)) {
        throw "staging HUD self-test: stdout/stderr drains did not complete within ${drainMs}ms"
    }
    $steps += [pscustomobject][ordered]@{
        name = 'AgentObserver.Hud.exe --self-test (staging)'
        exit_code = [int]$script:SelfTestExitCode
        duration_ms = [int]([DateTimeOffset]::UtcNow - $selfTestStarted).TotalMilliseconds
        timeout_detected = $false
    }
    if ($script:SelfTestExitCode -ne 0) {
        throw ("staging HUD self-test exited with code {0}" -f $script:SelfTestExitCode)
    }

    # --- Atomic promote staging to the unique candidate package root ------------
    # The parent directory (artifacts\candidates\<RunId>) is created here; the
    # candidate package root itself still does not exist (promoted by rename).
    [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath((Split-Path -Parent $PackageRoot))) | Out-Null
    # Promotion result contract (Repair 1): capture the FULL output first;
    # the helper must emit EXACTLY ONE result object. Any extra success-stream
    # output (helper pollution) is a contract violation that fails the build
    # immediately. The caller NEVER masks pollution by taking the last array
    # element, and NEVER dereferences .status / .backup_retained / .backup_path
    # / .warning before the single object passed the property contract check.
    $promotionOutput = @(Invoke-LocalPackageAtomicPromotion -StagingPath $stagingPackageDir `
        -PackageRoot $PackageRoot -BackupRoot $backupRoot `
        -AllowedRoot $artifactsRoot -RepoRoot $script:RepoRoot `
        -VerifyPackage { Test-PromotedPackageIntegrity -Root $PackageRoot })
    if ($promotionOutput.Count -ne 1) {
        throw ("atomic promotion contract violation: expected exactly 1 promotion result object, got {0} (success-stream pollution)" -f $promotionOutput.Count)
    }
    if (-not (Test-LocalPackagePromotionResultContract -Value $promotionOutput[0])) {
        throw 'atomic promotion contract violation: promotion result object is missing one or more required properties (promoted, status, error, warning, backup_path, backup_retained, package_restored, package_integrity_verified)'
    }
    $promotionResult = $promotionOutput[0]

    if ($promotionResult.status -eq 'FAIL') {
        $message = "atomic promotion FAILED: $($promotionResult.error)"
        if ($promotionResult.backup_retained) {
            $message += " ; BACKUP RETAINED (never deleted automatically): $($promotionResult.backup_path)"
        }
        throw $message
    }
    if ($promotionResult.warning) {
        Write-Warning $promotionResult.warning
    }
    $promotionSucceeded = $true

    # --- Post-promotion manifest verification on the candidate root -------------
    $manifestVerified = Test-PromotedPackageIntegrity -Root $PackageRoot
    if (-not $manifestVerified) {
        throw "candidate package manifest verification failed (missing file or SHA-256 mismatch) at $PackageRoot"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path (Split-Path -Parent $PackageRoot) 'agent-observer-poc-v0.1.0-alpha.1-win-x64.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($PackageRoot, $zipPath)
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $PackageRoot) 'SHA256SUMS'), ($zipHash + '  ' + [IO.Path]::GetFileName($zipPath) + "`n"))
}
catch {
    # Repair 1: the catch block itself must NEVER throw a second exception.
    # 1. Save the original failure FIRST; every later step may only append.
    $originalFailureMessage = [string]$_.Exception.Message
    if (-not $failureReason) { $failureReason = $originalFailureMessage }
    if ($failureClassification -eq 'NONE') {
        $failureClassification = Get-LocalBuildFailureClassification -Message $originalFailureMessage
    }
    # 2. Promotion diagnostic in an isolated nested try/catch. Only the
    #    contract-checked helper reads backup_retained / backup_path; its own
    #    failure can only APPEND to the original failure reason, never
    #    overwrite it. Control flow always continues to finally cleanup and
    #    the single terminal path below.
    try {
        $promotionDiagnostic = Get-LocalPackagePromotionDiagnostic -PromotionResult $promotionResult
        if ($null -ne $promotionDiagnostic) { Write-Warning $promotionDiagnostic }
    } catch {
        $failureReason = "$originalFailureMessage; promotion diagnostic failed: $($_.Exception.Message)"
    }
}
finally {
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process') }
    # 1. Restore the caller's CARGO_TARGET_DIR.
    if ($null -ne $previousCargoTarget) {
        $env:CARGO_TARGET_DIR = $previousCargoTarget
    } elseif ($null -ne $cargoTargetDir) {
        Remove-Item Env:\CARGO_TARGET_DIR -ErrorAction SilentlyContinue
    }

    # 2. Final visible-console-host probe while the Job is still open, so the
    #    probe child itself is Job-owned. Failure => UNKNOWN => not provable.
    if ($null -ne $context -and $null -ne $context.Job) {
        $finalProbe = Invoke-LocalBuildWindowProbe -Lifecycle $context `
            -OutputPath (Join-Path $runDirectory 'window-probe-final.json') -Stage 'window-probe-final'
        if ([string]$finalProbe.status -ne 'ok') {
            $visibleWindowsObservation = 'UNKNOWN'
            $visibleWindowsCreated = $true
            $windowProbeError = [string]$finalProbe.error
            if (-not $failureReason) { $failureReason = "visible-window final probe UNKNOWN: $windowProbeError" }
            if ($failureClassification -eq 'NONE') { $failureClassification = 'FAIL' }
        } elseif ($baselineProbeOk) {
            $finalConsoleIds = [int[]]$finalProbe.ids
            $baselineSet = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($id in $baselineConsoleIds) { [void]$baselineSet.Add([int]$id) }
            foreach ($id in $finalConsoleIds) {
                $intId = [int]$id
                if (-not $baselineSet.Contains($intId)) { [void]$newConsoleWindows.Add($intId) }
            }
            $visibleWindowsCreated = ($newConsoleWindows.Count -gt 0)
            $visibleWindowsObservation = 'ok'
            if ($visibleWindowsCreated -and -not $failureReason) {
                $failureReason = ("new visible console host windows created: {0}" -f (($newConsoleWindows.ToArray()) -join ','))
            }
            if ($visibleWindowsCreated -and $failureClassification -eq 'NONE') { $failureClassification = 'FAIL' }
        } else {
            $visibleWindowsObservation = 'UNKNOWN'
            $visibleWindowsCreated = $true
            if (-not $windowProbeError) { $windowProbeError = 'baseline probe unavailable; visible-window creation not provable' }
        }
    }

    # 3. Process cleanup: dispose the kill-on-close Job Object, then verify
    #    every recorded PID + creation time is gone. Any cleanup failure or
    #    residual owned process forces a FAIL below.
    if ($null -ne $context) {
        $cleanupMeasure = Close-LocalHarnessRun -Context $context -Reason 'build-finished'
        if (-not $cleanupMeasure.cleanup_success) {
            if (-not $failureReason) {
                $failureReason = ("build cleanup FAILED: {0} (owned processes remaining: {1})" -f $cleanupMeasure.cleanup_failure, $cleanupMeasure.owned_processes_remaining)
            }
            if ($failureClassification -eq 'NONE') { $failureClassification = 'FAIL' }
        }
    }

    # 4. Staging cleanup: prove the canonical path is inside the artifacts
    #    root before the recursive delete. The backup is NEVER deleted here.
    if ($null -ne $stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
        try {
            $null = Remove-LocalPackageDirectorySafely -Path $stagingRoot -AllowedRoots @($artifactsRoot) -RepoRoot $script:RepoRoot
            $stagingCleanupSuccess = $true
        } catch {
            $stagingCleanupError = [string]$_.Exception.Message
            if (-not $failureReason) { $failureReason = "staging cleanup failed: $stagingCleanupError" }
            if ($failureClassification -eq 'NONE') { $failureClassification = 'FAIL' }
        }
    } elseif ($null -ne $stagingRoot) {
        $stagingCleanupSuccess = $true
    }
}

# ---------------------------------------------------------------------------
# SINGLE TERMINAL PATH (rule 17): marker FINISHED + build-summary.json
# (FileMode.CreateNew) + marker/summary agreement + exit code. If this process
# dies before this point, the marker and logs remain and the run is INCOMPLETE.
# ---------------------------------------------------------------------------

$finishedAt = [DateTimeOffset]::UtcNow
$actualDurationMs = [int][math]::Round(($finishedAt - $script:StartedAt).TotalMilliseconds)
$deadlineVerdict = Get-LocalSafetyDeadlineVerdict -FinishedAt $finishedAt `
    -AbsoluteDeadlineAt $script:AbsoluteDeadlineAt `
    -BaseTimeoutDetected ($failureClassification -eq 'TIMEOUT')

# Cleanup / process measurements (a missing measurement can never pass).
$cleanupSucceeded = ($null -ne $cleanupMeasure -and [bool]$cleanupMeasure.cleanup_success)
$ownedRemaining = if ($null -ne $cleanupMeasure) { [int]$cleanupMeasure.owned_processes_remaining } else { -1 }

# Stable package integrity: prove nothing changed.
$stableAfter = Get-LocalStablePackageSnapshot -Root $stablePackageRoot
$stableUnchanged = Test-LocalPackageSnapshotsEqual -Before $stableBefore -After $stableAfter

# Candidate root location re-check.
$candidatePathCheck = Test-LocalPackageSafePath -Path $PackageRoot -AllowedRoots @($artifactsRoot) -RepoRoot $script:RepoRoot

# Log inventory (every official log must be within the 2 MiB whole-file cap).
$logEntries = New-Object System.Collections.Generic.List[object]
$logsWithinCap = $true
if (Test-Path -LiteralPath $runDirectory) {
    foreach ($logFile in @(Get-ChildItem -LiteralPath $runDirectory -File -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        [void]$logEntries.Add([pscustomobject][ordered]@{
            name = $logFile.Name
            size_bytes = [int64]$logFile.Length
        })
        if ([int64]$logFile.Length -gt $script:MaxLogBytesCap) { $logsWithinCap = $false }
    }
}

# Final status from the failure classification and the deadline verdict.
$finalStatus = 'FAIL'
if ($deadlineVerdict.timeout_detected) {
    $finalStatus = 'TIMEOUT'
} elseif ($failureClassification -eq 'BLOCKED') {
    $finalStatus = 'BLOCKED'
} elseif ($failureClassification -eq 'TIMEOUT') {
    $finalStatus = 'TIMEOUT'
}

# Pass conditions (frozen for this stage). A missing measurement is never a pass.
$conditions = [ordered]@{
    attempt_count_is_one = ($attemptCount -eq 1)
    build_start_count_is_one = ($buildStartCount -eq 1)
    automatic_retries_zero = $true
    deadline_respected = [bool]$deadlineVerdict.deadline_respected
    cargo_build_exit_zero = ($script:CargoExitCode -eq 0)
    dotnet_publish_exit_zero = ($script:PublishExitCode -eq 0)
    hud_selftest_exit_zero = ($script:SelfTestExitCode -eq 0)
    manifest_files_present_and_sha256_matching = [bool]$manifestVerified
    private_build_path_scan_passed = ($null -ne $privatePathScan -and $privatePathScan.passed)
    candidate_package_root_inside_artifacts = [bool]$candidatePathCheck.safe
    stable_package_unchanged = [bool]$stableUnchanged
    cleanup_success = $cleanupSucceeded
    owned_processes_remaining_zero = ($ownedRemaining -eq 0)
    visible_console_windows_created_false = (($visibleWindowsObservation -eq 'ok') -and (-not $visibleWindowsCreated))
    all_logs_within_cap = [bool]$logsWithinCap
    no_model_calls = ($modelCallsStarted -eq 0)
}
$conditionFailures = New-Object System.Collections.Generic.List[string]
foreach ($key in @($conditions.Keys)) {
    if (-not [bool]$conditions[$key]) { [void]$conditionFailures.Add([string]$key) }
}
if ($null -eq $failureReason -and -not $deadlineVerdict.timeout_detected -and $conditionFailures.Count -eq 0) {
    $finalStatus = 'OFFLINE'
}
if ($conditionFailures.Count -gt 0 -and $finalStatus -eq 'OFFLINE') {
    $finalStatus = 'FAIL'
}

$buildPass = ($finalStatus -eq 'OFFLINE')

# The owner finalizes the attempt after checking its worker and own cleanup.
$markerUpdateError = $null

# build-summary.json (FileMode.CreateNew, single terminal path only).
$summaryProbe = [pscustomobject][ordered]@{
    run_id = $RunId
    final_status = $finalStatus
    started_at = $script:StartedAt.ToString('o')
    finished_at = $finishedAt.ToString('o')
    actual_duration_ms = $actualDurationMs
}
$markerForCheck = $null
try { $markerForCheck = Read-LocalSafetyAttemptMarker -Path $markerPath } catch { }
$markerSummaryReason = 'marker missing or unreadable'
if ($null -ne $markerForCheck -and $markerForCheck.status -eq 'RUNNING') { $markerSummaryReason = $null }
if ($null -ne $markerUpdateError) {
    $markerSummaryReason = "marker update failed: $markerUpdateError"
    $buildPass = $false
    if ($finalStatus -eq 'OFFLINE') { $finalStatus = 'FAIL' }
}

$exitCode = switch ($finalStatus) {
    'OFFLINE' { 0 }
    'BLOCKED' { Get-HarnessBlockedExitCode }
    'TIMEOUT' { 124 }
    default { 1 }
}

$summary = [ordered]@{
    schema_version = 1
    generated_by = 'build-local-hud-package.ps1'
    phase = 'windows-alpha-package'
    run_id = $RunId
    supervisor_pid = $supervisorPid
    supervisor_creation_time = $supervisorCreationTimeUtc
    started_at = $script:StartedAt.ToString('o')
    finished_at = $finishedAt.ToString('o')
    actual_duration_ms = $actualDurationMs
    absolute_deadline_at = $script:AbsoluteDeadlineAt.ToString('o')
    overall_deadline_seconds = $script:OverallDeadlineSeconds
    external_executor_hard_cutoff_seconds = 1200
    attempt_count = $attemptCount
    build_start_count = $buildStartCount
    automatic_retries = 0
    status = $finalStatus
    final_status = $finalStatus
    build_pass = [bool]$buildPass
    acceptance_pass = $false
    acceptance_note = 'This stage proves BUILD PASS only. No HUD main-window start, no Session acceptance, no daily-use acceptance was performed.'
    failure_reason = $failureReason
    deadline_respected = [bool]$deadlineVerdict.deadline_respected
    timeout_detected = [bool]$deadlineVerdict.timeout_detected
    pass_conditions = $conditions
    failed_conditions = [string[]]$conditionFailures.ToArray()
    build_steps = @($steps | ForEach-Object { [pscustomobject][ordered]@{
        name = $_.name
        exit_code = $_.exit_code
        duration_ms = $_.duration_ms
        timeout_detected = $_.timeout_detected
    } })
    cargo_exit_code = $script:CargoExitCode
    dotnet_publish_exit_code = $script:PublishExitCode
    hud_selftest_exit_code = $script:SelfTestExitCode
    private_build_path_scan = $privatePathScan
    evidence_root = $EvidenceRoot
    run_directory = $runDirectory
    package = [ordered]@{
        candidate_package_root = $PackageRoot
        stable_package_root = $stablePackageRoot
        candidate_inside_fixed_artifacts_root = [bool]$candidatePathCheck.safe
        promotion_status = if (Test-LocalPackagePromotionResultContract -Value $promotionResult) { [string]$promotionResult.status } else { 'NOT_REACHED' }
        manifest_verified_all_files_sha256 = [bool]$manifestVerified
        manifest_files = @($manifestFiles)
        stable_package_unchanged = [bool]$stableUnchanged
        stable_package_file_count = if ($null -ne $stableAfter) { [int]$stableAfter.file_count } else { 0 }
    }
    cleanup = [ordered]@{
        process_cleanup_success = $cleanupSucceeded
        owned_processes_remaining = $ownedRemaining
        cleanup_failure = if ($null -ne $cleanupMeasure) { $cleanupMeasure.cleanup_failure } else { 'cleanup never measured' }
        staging_cleanup_success = [bool]$stagingCleanupSuccess
        staging_cleanup_error = $stagingCleanupError
    }
    visible_windows = [ordered]@{
        observation = $visibleWindowsObservation
        visible_console_windows_created = [bool]$visibleWindowsCreated
        new_visible_console_window_pids = [int[]]$newConsoleWindows.ToArray()
        baseline_console_host_pids = [int[]]$baselineConsoleIds
        final_console_host_pids = [int[]]$finalConsoleIds
        probe_error = $windowProbeError
    }
    logs = [ordered]@{
        max_log_bytes_cap = $script:MaxLogBytesCap
        all_logs_within_cap = [bool]$logsWithinCap
        files = [object[]]$logEntries.ToArray()
    }
    model_calls_started = $modelCallsStarted
    network_access_permitted = [bool]$AllowDependencyDownloads
    network_requests_observed = $null
    network_attestation = 'No network monitor attached. Optional dependency downloads only (NuGet and Cargo registry); no model/provider tooling started. OFFLINE describes deterministic tests, not a claim of zero dependency network traffic.'
    unproven_properties = @(
        'PowerShell outer-owner process-level hard cutoff is UNPROVEN (rule 18). The owner bounds its Job-owned worker; CI also has a platform job timeout.'
    )
}

$summaryWriteError = $null
try {
    Write-LocalSafetyEvidenceJson -Path $buildSummaryPath -Object $summary
} catch {
    $summaryWriteError = [string]$_.Exception.Message
}

if ($null -ne $summaryWriteError) {
    Write-Warning ("build-summary.json could not be written: {0} (marker and logs remain; run is INCOMPLETE)" -f $summaryWriteError)
    $exitCode = 1
}
if ($null -ne $markerSummaryReason) {
    Write-Warning ("marker/summary consistency could not be proven: {0}" -f $markerSummaryReason)
}

Write-Output ('RUN_ID=' + $RunId)
Write-Output ('STATUS=' + $finalStatus)
Write-Output ('BUILD_PASS=' + ([bool]$buildPass))
Write-Output ('ACCEPTANCE_PASS=false')
Write-Output ('PACKAGE=' + $PackageRoot)
if ($buildPass) {
    Write-Output ('MANIFEST_FILES=' + $manifestFiles.Count)
    Write-Output ('FILES=' + ($manifestFiles.Count + 1))
    $manifest | ConvertTo-Json -Depth 5 | Write-Output
}
exit $exitCode
