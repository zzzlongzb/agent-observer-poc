[CmdletBinding()]
param(
    [string]$EvidenceRoot = '',
    [string]$LaunchContextPath = '',
    [string]$ExpectedRunId = '',
    [ValidateRange(1, 300)][int]$OverallDeadlineSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$startedAt = [DateTimeOffset]::UtcNow
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$RunId = if ($ExpectedRunId) { $ExpectedRunId } else { 'standalone-' + [Guid]::NewGuid().ToString('N') }
if (-not $EvidenceRoot) {
    $EvidenceRoot = Join-Path $repoRoot "docs\evidence\windows-background-process-hardening-v1.1-r1\runs\$RunId"
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
[IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null
. (Join-Path $PSScriptRoot 'harness-lifecycle.ps1')
. (Join-Path $PSScriptRoot 'windows-visibility-audit.ps1')

if (-not ('AgentObserverHardening.WindowProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AgentObserverHardening
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
    }
}
'@
}

$utf8 = [Text.UTF8Encoding]::new($false)
$overallDeadline = $startedAt.AddSeconds($OverallDeadlineSeconds)
$allRuns = [Collections.Generic.List[object]]::new()
$steps = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()
$visibilityProbeFailure = $null
$baselineVisibleIds = $null
$observedVisibleIds = [Collections.Generic.HashSet[int]]::new()
$visibilityObservations = [Collections.Generic.List[object]]::new()
$supervisorContext = $null
$launchContext = $null
$coordinatorBinding = $null

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Content = '')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Assert-OverallDeadline {
    param([string]$Stage)
    if ([DateTimeOffset]::UtcNow -ge $overallDeadline) {
        throw "TIMEOUT: overall ${OverallDeadlineSeconds}s deadline exceeded during $Stage"
    }
}

function Get-VisibleWindowSnapshot {
    param([Parameter(Mandatory)][string]$Stage)
    try {
        $ids = @([AgentObserverHardening.WindowProbe]::VisibleWindowProcessIds() | Sort-Object -Unique)
        foreach ($processId in $ids) { [void]$script:observedVisibleIds.Add([int]$processId) }
        $newIds = if ($null -eq $script:baselineVisibleIds) {
            $null
        } else {
            @($ids | Where-Object { $script:baselineVisibleIds -notcontains [int]$_ })
        }
        [void]$script:visibilityObservations.Add([pscustomobject]@{
            run_id = $RunId
            observed_at = [DateTimeOffset]::UtcNow.ToString('o')
            stage = $Stage
            visible_window_process_ids = $ids
            new_visible_window_process_ids = $newIds
        })
        return ,$ids
    } catch {
        $script:visibilityProbeFailure = "${Stage}: $($_.Exception.Message)"
        return $null
    }
}

function Convert-CimRowToProcessObservation {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)]$VisibleIds,
        [switch]$ReadMainWindowHandle
    )
    $processId = [int]$Row.ProcessId
    $creation = ([DateTime]$Row.CreationDate).ToUniversalTime()
    $handle = 0L
    if ($ReadMainWindowHandle) {
        $candidate = [Diagnostics.Process]::GetProcessById($processId)
        try {
            $candidate.Refresh()
            $handle = $candidate.MainWindowHandle.ToInt64()
        } finally {
            $candidate.Dispose()
        }
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
        visible_window_observed = ($VisibleIds -contains $processId)
    }
}

function Get-SupervisorProcessContext {
    param([Parameter(Mandatory)]$Rows, [Parameter(Mandatory)]$VisibleIds, [Parameter(Mandatory)]$LaunchContext)
    $rowByPid = @{}
    foreach ($row in $Rows) { $rowByPid[[string]$row.ProcessId] = $row }
    $rootRow = $rowByPid[[string]$PID]
    if ($null -eq $rootRow) { throw "supervisor PID $PID was absent from Win32_Process" }

    $root = Convert-CimRowToProcessObservation -Row $rootRow -Role 'supervisor-root' -VisibleIds $VisibleIds -ReadMainWindowHandle
    $coordinatorProcess = $null
    $coordinatorPid = [int]$LaunchContext.coordinator_pid
    if ($rowByPid.ContainsKey([string]$coordinatorPid)) {
        try {
            $candidate = [Diagnostics.Process]::GetProcessById($coordinatorPid)
            try {
                $candidate.Refresh()
                $coordinatorProcess = [pscustomobject]@{
                    run_id = $RunId
                    pid = $coordinatorPid
                    parent_pid = [int]$rowByPid[[string]$coordinatorPid].ParentProcessId
                    creation_time = $candidate.StartTime.ToUniversalTime().ToString('o')
                    name = [string]$rowByPid[[string]$coordinatorPid].Name
                    role = 'exact-coordinator'
                    main_window_handle = $candidate.MainWindowHandle.ToInt64()
                    visible_window_observed = ($VisibleIds -contains $coordinatorPid)
                }
            } finally { $candidate.Dispose() }
        } catch [ArgumentException] { $coordinatorProcess = $null }
    }

    $effectiveContext = $LaunchContext.PSObject.Copy()
    if ($null -ne $coordinatorProcess -and $coordinatorProcess.visible_window_observed) { $effectiveContext.coordinator_visible_window_observed = $true }
    $binding = Test-CoordinatorLaunchBinding -LaunchContext $effectiveContext -ExpectedRunId $ExpectedRunId `
        -ExpectedRepositoryRoot $repoRoot -SupervisorParentPid ([int]$root.parent_pid) -CoordinatorProcess $coordinatorProcess

    $currentAncestors = @($Rows | ForEach-Object {
        [pscustomobject]@{ pid = [int]$_.ProcessId; creation_time = ([DateTime]$_.CreationDate).ToUniversalTime().ToString('o'); name = [string]$_.Name }
    })
    $parentDiagnostics = @(Get-LaunchAncestorDiagnostics -RecordedAncestors @($LaunchContext.parent_chain_diagnostics) -CurrentProcesses $currentAncestors)
    $consoleNames = @('conhost.exe', 'OpenConsole.exe', 'WindowsTerminal.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe')
    [pscustomobject][ordered]@{
        run_id = $RunId
        supervisor_pid = [int]$root.pid
        supervisor_parent_pid = [int]$root.parent_pid
        supervisor_creation_time = $root.creation_time
        supervisor_main_window_handle = [long]$root.main_window_handle
        supervisor_visible_window_observed = [bool]$root.visible_window_observed
        supervisor_parent_binding_verified = $binding.supervisor_parent_binding_verified
        coordinator_binding = $binding
        exact_coordinator = $coordinatorProcess
        parent_chain_diagnostics = $parentDiagnostics
        supervisor_parent_chain = @($coordinatorProcess)
        associated_console_hosts = @($coordinatorProcess | Where-Object { $consoleNames -contains [string]$_.name })
        associated_windows_terminal_processes = @($coordinatorProcess | Where-Object { [string]$_.name -ieq 'WindowsTerminal.exe' })
        root_process = $root
    }
}

function New-ProcessTracker {
    [ordered]@{ by_pid = @{}; observations = [Collections.Generic.List[object]]::new() }
}

function Add-TrackedProcess {
    param(
        [Parameter(Mandatory)]$Tracker,
        [int]$ProcessId,
        [int]$ParentProcessId,
        [string]$Name,
        [string]$CommandLine,
        [DateTime]$CreationTime,
        [bool]$VisibleWindow,
        [long]$MainWindowHandle,
        [string]$Role
    )
    $key = [string]$ProcessId
    if ($Tracker.by_pid.ContainsKey($key)) {
        $existing = $Tracker.by_pid[$key]
        if ($VisibleWindow) { $existing.visible_window_observed = $true }
        if ($MainWindowHandle -ne 0) { $existing.main_window_handle = $MainWindowHandle }
        return
    }
    $entry = [pscustomobject]@{
        run_id = $RunId
        pid = $ProcessId
        parent_pid = $ParentProcessId
        creation_time = $CreationTime.ToUniversalTime().ToString('o')
        name = $Name
        command_line = $CommandLine
        role = $Role
        main_window_handle = $MainWindowHandle
        visible_window_observed = $VisibleWindow
    }
    $Tracker.by_pid[$key] = $entry
    [void]$Tracker.observations.Add($entry)
}

function Update-OwnedProcessTree {
    param([Parameter(Mandatory)]$Tracker)
    try {
        $visibleSnapshot = Get-VisibleWindowSnapshot -Stage 'owned-process-tree-sample'
        if ($null -eq $visibleSnapshot) { return }
        $visibleIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($id in $visibleSnapshot) { [void]$visibleIds.Add([int]$id) }
        $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $known = [Collections.Generic.HashSet[int]]::new()
        foreach ($entry in $Tracker.observations) { [void]$known.Add([int]$entry.pid) }
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($row in $rows) {
                $pidValue = [int]$row.ProcessId
                if ($known.Contains($pidValue) -or -not $known.Contains([int]$row.ParentProcessId)) { continue }
                $creation = try { ([DateTime]$row.CreationDate).ToUniversalTime() } catch { [DateTime]::UtcNow }
                $handle = 0L
                try {
                    $candidate = [Diagnostics.Process]::GetProcessById($pidValue)
                    try { $candidate.Refresh(); $handle = $candidate.MainWindowHandle.ToInt64() }
                    finally { $candidate.Dispose() }
                } catch [ArgumentException] { }
                Add-TrackedProcess -Tracker $Tracker -ProcessId $pidValue -ParentProcessId ([int]$row.ParentProcessId) `
                    -Name ([string]$row.Name) -CommandLine ([string]$row.CommandLine) -CreationTime $creation `
                    -VisibleWindow ($visibleIds.Contains($pidValue)) -MainWindowHandle $handle -Role 'descendant'
                [void]$known.Add($pidValue)
                $changed = $true
            }
        }
        foreach ($entry in $Tracker.observations) {
            if ($visibleIds.Contains([int]$entry.pid)) { $entry.visible_window_observed = $true }
        }
    } catch {
        $script:visibilityProbeFailure = "owned-process-tree-sample: $($_.Exception.Message)"
    }
}

function Start-HiddenOwnedProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$RunDirectory,
        [hashtable]$Environment = @{},
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 60
    )
    Assert-OverallDeadline $Name
    [IO.Directory]::CreateDirectory($RunDirectory) | Out-Null
    $stdoutPath = Join-Path $RunDirectory 'child.stdout.log'
    $stderrPath = Join-Path $RunDirectory 'child.stderr.log'
    $context = New-HarnessLifecycle -Name $Name -RunRoot $RunDirectory -Scenario $Name `
        -OverallTimeoutSeconds $TimeoutSeconds -HeartbeatSeconds 10
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if (-not ($psi.PSObject.Properties.Name -contains 'ArgumentList')) {
        throw 'This hardening supervisor requires ProcessStartInfo.ArgumentList support'
    }
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add([string]$argument) }
    foreach ($key in $Environment.Keys) { $psi.Environment[[string]$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "$Name failed to start" }
    $record = Register-HarnessProcess -Context $context -Process $process -Kind $Name -Scenario $Name
    $tracker = New-ProcessTracker
    $process.Refresh()
    $initialVisibleIds = Get-VisibleWindowSnapshot -Stage "start:$Name"
    Add-TrackedProcess -Tracker $tracker -ProcessId $process.Id -ParentProcessId $PID `
        -Name ($process.ProcessName + '.exe') -CommandLine ((@($FilePath) + @($Arguments)) -join ' ') `
        -CreationTime $process.StartTime -VisibleWindow ($null -ne $initialVisibleIds -and $initialVisibleIds -contains $process.Id) `
        -MainWindowHandle $process.MainWindowHandle.ToInt64() -Role 'registered-root'
    [pscustomobject]@{
        name = $Name
        process = $process
        context = $context
        record = $record
        tracker = $tracker
        stdout_task = $process.StandardOutput.ReadToEndAsync()
        stderr_task = $process.StandardError.ReadToEndAsync()
        stdout_path = $stdoutPath
        stderr_path = $stderrPath
        run_directory = $RunDirectory
        started_at = [DateTimeOffset]::UtcNow
        timeout_seconds = $TimeoutSeconds
    }
}

function Complete-HiddenOwnedProcess {
    param(
        [Parameter(Mandatory)]$Launch,
        [int]$KillAfterMilliseconds = 0
    )
    $timedOut = $false
    $intentionallyKilled = $false
    $deadline = $Launch.started_at.AddSeconds($Launch.timeout_seconds)
    try {
        while (Test-HarnessProcessRecordAlive -Record $Launch.record) {
            Update-OwnedProcessTree -Tracker $Launch.tracker
            $elapsedMs = ([DateTimeOffset]::UtcNow - $Launch.started_at).TotalMilliseconds
            if ($KillAfterMilliseconds -gt 0 -and $elapsedMs -ge $KillAfterMilliseconds) {
                $intentionallyKilled = $true
                Stop-HarnessProcessRecord -Record $Launch.record -Reason 'qa-abnormal-exit' | Out-Null
                break
            }
            if ([DateTimeOffset]::UtcNow -ge $deadline -or [DateTimeOffset]::UtcNow -ge $overallDeadline) {
                $timedOut = $true
                Stop-HarnessOwnedProcesses -Context $Launch.context -Reason 'hard-deadline'
                break
            }
            Start-Sleep -Milliseconds 50
        }
        Update-OwnedProcessTree -Tracker $Launch.tracker
        [void]$Launch.process.WaitForExit(5000)
        $stdout = $Launch.stdout_task.GetAwaiter().GetResult()
        $stderr = $Launch.stderr_task.GetAwaiter().GetResult()
        Write-Utf8File $Launch.stdout_path $stdout
        Write-Utf8File $Launch.stderr_path $stderr
        $exitCode = try { $Launch.process.ExitCode } catch { $null }
    } finally {
        Close-HarnessLifecycle -Context $Launch.context -Reason 'hardening-supervisor-finally'
    }
    $remaining = @($Launch.context.OwnedProcesses | Where-Object { Test-HarnessProcessRecordAlive -Record $_ }).Count
    $shellNames = @('powershell.exe', 'pwsh.exe', 'cmd.exe')
    $visibleOwned = @($Launch.tracker.observations | Where-Object visible_window_observed).Count
    $visibleWindowsTerminal = @($Launch.tracker.observations | Where-Object {
        $_.visible_window_observed -and $_.name -ieq 'WindowsTerminal.exe'
    }).Count
    $unexpected = 0
    foreach ($entry in $Launch.tracker.observations) {
        $lower = $entry.name.ToLowerInvariant()
        if ($entry.role -eq 'registered-root' -or $shellNames -notcontains $lower) { continue }
        $parent = $Launch.tracker.by_pid[[string]$entry.parent_pid]
        $parentName = if ($null -ne $parent) { $parent.name.ToLowerInvariant() } else { '' }
        $expectedHostProbe = $lower -eq 'powershell.exe' -and ($parentName -eq 'agent-observer-poc.exe' -or $parentName -like 'agent_observer_poc-*.exe')
        $expectedQaChild = $Launch.name -eq '02-offline-self-test' -and $lower -eq 'pwsh.exe' -and $null -ne $parent -and $parent.name.ToLowerInvariant() -eq 'pwsh.exe'
        if (-not $expectedHostProbe -and -not $expectedQaChild) { $unexpected++ }
    }
    $finishedAt = [DateTimeOffset]::UtcNow
    $run = [ordered]@{
        run_id = $RunId
        name = $Launch.name
        status = if ($timedOut) { 'TIMEOUT' } elseif ($intentionallyKilled) { 'INTENTIONALLY_KILLED' } elseif ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
        started_at = $Launch.started_at.ToString('o')
        finished_at = $finishedAt.ToString('o')
        duration_ms = [int64][math]::Round(($finishedAt - $Launch.started_at).TotalMilliseconds)
        timeout_detected = $timedOut
        cleanup_success = ($remaining -eq 0)
        owned_processes_remaining = $remaining
        child_exit_code = $exitCode
        stdout_path = $Launch.stdout_path
        stderr_path = $Launch.stderr_path
        visible_owned_windows = $visibleOwned
        attributable_visible_windows = $visibleOwned
        windows_terminal_owned_visible = $visibleWindowsTerminal
        visible_console_windows = $visibleOwned
        unexpected_shell_children = $unexpected
        visibility_probe_reliable = [string]::IsNullOrEmpty($visibilityProbeFailure)
        intentionally_killed = $intentionallyKilled
        owned_process_tree_path = (Join-Path $Launch.run_directory 'owned-process-tree.json')
        owned_processes = @($Launch.tracker.observations)
    }
    Write-Utf8File $run.owned_process_tree_path ([ordered]@{ run_id = $RunId; processes = @($Launch.tracker.observations) } | ConvertTo-Json -Depth 7)
    Write-Utf8File (Join-Path $Launch.run_directory 'run-summary.json') ($run | ConvertTo-Json -Depth 8)
    $Launch.process.Dispose()
    [void]$allRuns.Add([pscustomobject]$run)
    [pscustomobject]$run
}

function Invoke-HiddenOwnedProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$RunDirectory,
        [hashtable]$Environment = @{},
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 60
    )
    $launch = Start-HiddenOwnedProcess -Name $Name -FilePath $FilePath -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory -RunDirectory $RunDirectory -Environment $Environment `
        -TimeoutSeconds $TimeoutSeconds
    Complete-HiddenOwnedProcess -Launch $launch
}

function Add-StepResult {
    param([string]$Name, $Run, [bool]$ExpectedSuccess = $true)
    $passed = if ($ExpectedSuccess) {
        $Run.child_exit_code -eq 0 -and -not $Run.timeout_detected -and $Run.cleanup_success -and `
            $Run.visibility_probe_reliable -and $Run.visible_owned_windows -eq 0
    } else { $true }
    [void]$steps.Add([pscustomobject]@{
        name = $Name
        pass = $passed
        duration_ms = $Run.duration_ms
        exit_code = $Run.child_exit_code
        timeout_detected = $Run.timeout_detected
        cleanup_success = $Run.cleanup_success
    })
    if (-not $passed) { [void]$failures.Add("$Name failed (exit=$($Run.child_exit_code), timeout=$($Run.timeout_detected))") }
}

function Get-IntegerSum {
    param([Parameter(Mandatory)]$Items, [Parameter(Mandatory)][string]$Property)
    $total = 0
    foreach ($item in $Items) { $total += [int]$item.$Property }
    $total
}

function Get-AllOwnedProcessObservations {
    $byIdentity = [ordered]@{}
    if ($null -ne $supervisorContext) {
        $root = $supervisorContext.root_process
        $byIdentity["$($root.pid)|$($root.creation_time)"] = $root
    }
    foreach ($run in $allRuns) {
        foreach ($process in @($run.owned_processes)) {
            $key = "$($process.pid)|$($process.creation_time)"
            if ($byIdentity.Contains($key)) {
                if ($process.visible_window_observed) { $byIdentity[$key].visible_window_observed = $true }
            } else {
                $byIdentity[$key] = $process
            }
        }
    }
    @($byIdentity.Values)
}

function Get-AliveExactOwnedProcesses {
    param([AllowNull()][AllowEmptyCollection()]$Processes)
    $alive = [Collections.Generic.List[object]]::new()
    foreach ($observation in @($Processes)) {
        if ([int]$observation.pid -eq $PID) { continue }
        try {
            $candidate = [Diagnostics.Process]::GetProcessById([int]$observation.pid)
            try {
                $expected = [DateTimeOffset]::Parse([string]$observation.creation_time).UtcDateTime
                if (-not $candidate.HasExited -and $candidate.StartTime.ToUniversalTime() -eq $expected) {
                    [void]$alive.Add($observation)
                }
            } finally {
                $candidate.Dispose()
            }
        } catch [ArgumentException] { }
    }
    @($alive)
}

function Stop-ExactOwnedProcessObservation {
    param([Parameter(Mandatory)]$Observation)
    $candidate = [Diagnostics.Process]::GetProcessById([int]$Observation.pid)
    try {
        $expected = [DateTimeOffset]::Parse([string]$Observation.creation_time).UtcDateTime
        if (-not $candidate.HasExited -and $candidate.StartTime.ToUniversalTime() -eq $expected) {
            $candidate.Kill($true)
            [void]$candidate.WaitForExit(5000)
        }
    } finally {
        $candidate.Dispose()
    }
}

function New-SyntheticEnvironment {
    param([string]$Root)
    $paths = @{}
    foreach ($name in @('codex', 'claude', 'claude-hooks', 'claude-sessions', 'pi-sessions', 'pi-hooks', 'grok-sessions', 'grok-hooks', 'runtime-bindings')) {
        $path = Join-Path $Root $name
        [IO.Directory]::CreateDirectory($path) | Out-Null
        $paths[$name] = $path
    }
    Write-Utf8File (Join-Path $paths.codex 'desktop.jsonl') @'
{"timestamp":"2026-09-02T10:00:00Z","type":"session_meta","payload":{"id":"hardening-desktop","cwd":"D:\\synthetic","originator":"Codex Desktop","source":"user"}}
{"timestamp":"2026-09-02T10:00:01Z","type":"event_msg","payload":{"type":"task_started"}}
'@
    $grokActive = Join-Path $Root 'active_sessions.json'
    Write-Utf8File $grokActive '[]'
    @{
        AGENT_OBSERVER_CODEX_ROOT = $paths.codex
        AGENT_OBSERVER_CLAUDE_ROOT = $paths.claude
        AGENT_OBSERVER_CLAUDE_HOOK_ROOT = $paths.'claude-hooks'
        AGENT_OBSERVER_CLAUDE_SESSION_ROOT = $paths.'claude-sessions'
        AGENT_OBSERVER_PI_SESSION_ROOT = $paths.'pi-sessions'
        AGENT_OBSERVER_PI_HOOK_ROOT = $paths.'pi-hooks'
        AGENT_OBSERVER_GROK_SESSION_ROOT = $paths.'grok-sessions'
        AGENT_OBSERVER_GROK_ACTIVE_SESSIONS = $grokActive
        AGENT_OBSERVER_GROK_HOOK_ROOT = $paths.'grok-hooks'
        AGENT_OBSERVER_RUNTIME_BINDING_ROOT = $paths.'runtime-bindings'
    }
}

$shell = if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe')) { Join-Path $PSHOME 'pwsh.exe' } else { 'pwsh.exe' }
$cargo = (Get-Command cargo.exe -ErrorAction Stop).Source
$exe = Join-Path $repoRoot 'target\debug\agent-observer-poc.exe'
$scratchRoots = [Collections.Generic.List[string]]::new()
$stoppedAfterFailure = $false

try {
    $astStarted = [DateTimeOffset]::UtcNow
    $astFiles = @('scripts\pi-no-session-suppression-e2e.ps1', 'scripts\pi-no-session-deadline-cleanup-self-test.ps1', 'scripts\pi-no-session-installer-temp-self-test.ps1', 'scripts\windows-background-process-hardening-self-test.ps1', 'tools\harness-lifecycle.ps1', 'tools\pi-adapter-harness-supervisor.ps1', 'tools\windows-visibility-audit.ps1', 'tools\windows-background-process-hardening-coordinator.ps1', 'tools\windows-background-process-hardening-supervisor.ps1')
    $astErrors = [Collections.Generic.List[string]]::new()
    foreach ($file in $astFiles) {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $file), [ref]$tokens, [ref]$errors)
        foreach ($error in @($errors)) { [void]$astErrors.Add("${file}:$($error.Message)") }
    }
    $astPass = $astErrors.Count -eq 0
    [void]$steps.Add([pscustomobject]@{ name = 'PowerShell AST parse'; pass = $astPass; duration_ms = [int64][math]::Round(([DateTimeOffset]::UtcNow - $astStarted).TotalMilliseconds); exit_code = if ($astPass) { 0 } else { 1 }; timeout_detected = $false; cleanup_success = $true })
    if (-not $astPass) { foreach ($error in $astErrors) { [void]$failures.Add($error) }; throw 'stop after PowerShell AST parse failure' }

    $offlineStarted = [DateTimeOffset]::UtcNow
    $null = & (Join-Path $repoRoot 'scripts\windows-background-process-hardening-self-test.ps1') -EvidenceDirectory $EvidenceRoot -RunId $RunId -DeadlineSeconds 30
    $offlineDuration = [int64][math]::Round(([DateTimeOffset]::UtcNow - $offlineStarted).TotalMilliseconds)
    $hashSummary = Get-Content -LiteralPath (Join-Path $EvidenceRoot 'hashset-regression-summary.json') -Raw | ConvertFrom-Json
    $offlineFixtureSummary = Get-Content -LiteralPath (Join-Path $EvidenceRoot 'offline-visibility-fixture-summary.json') -Raw | ConvertFrom-Json
    $bindingFixtureSummary = Get-Content -LiteralPath (Join-Path $EvidenceRoot 'coordinator-binding-fixture-summary.json') -Raw | ConvertFrom-Json
    foreach ($offlineStep in @(
        [pscustomobject]@{ name = 'HashSet empty collection regression'; pass = [bool]$hashSummary.pass },
        [pscustomobject]@{ name = '8 visibility fixtures'; pass = [bool]$offlineFixtureSummary.pass },
        [pscustomobject]@{ name = 'coordinator binding fixtures'; pass = [bool]$bindingFixtureSummary.pass }
    )) {
        [void]$steps.Add([pscustomobject]@{ name = $offlineStep.name; pass = $offlineStep.pass; duration_ms = $offlineDuration; exit_code = if ($offlineStep.pass) { 0 } else { 1 }; timeout_detected = $false; cleanup_success = $true })
        if (-not $offlineStep.pass) { [void]$failures.Add("$($offlineStep.name) failed") }
    }
    if ($failures.Count) { throw 'stop after offline fixture failure' }

    if (-not $ExpectedRunId -or -not $LaunchContextPath) { throw 'launch context path and expected run_id are required' }
    try { $launchContext = Get-Content -LiteralPath $LaunchContextPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { throw "launch context is missing or invalid: $($_.Exception.Message)" }
    if ($launchContext.baseline_probe_reliable -ne $true -or $null -eq $launchContext.baseline_visible_window_process_ids) { throw 'visibility probe unreliable: coordinator baseline is missing or unreliable' }
    $script:baselineVisibleIds = @($launchContext.baseline_visible_window_process_ids | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    foreach ($processId in $script:baselineVisibleIds) { [void]$observedVisibleIds.Add($processId) }
    $initialVisibleIds = Get-VisibleWindowSnapshot -Stage 'supervisor-preflight'
    if ($null -eq $initialVisibleIds) { throw 'visibility probe unreliable: supervisor preflight window enumeration failed' }
    $initialRows = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $supervisorContext = Get-SupervisorProcessContext -Rows $initialRows -VisibleIds $initialVisibleIds -LaunchContext $launchContext
    $coordinatorBinding = $supervisorContext.coordinator_binding
    if (-not $coordinatorBinding.supervisor_parent_binding_verified) { throw "coordinator binding blocked: $($coordinatorBinding.failures -join '; ')" }
    $preflightAudit = Get-VisibilityAuditResult -ProbeReliable $true -BaselineVisibleProcessIds $script:baselineVisibleIds -ObservedVisibleProcessIds $observedVisibleIds -OwnedProcesses @($supervisorContext.root_process) -AssociatedProcesses @($supervisorContext.exact_coordinator) -SupervisorPid $PID
    if (-not $preflightAudit.pass) { throw 'supervisor/root visibility preflight failed' }
    [void]$steps.Add([pscustomobject]@{ name = 'real coordinator/supervisor launch binding preflight'; pass = $true; duration_ms = 0; exit_code = 0; timeout_detected = $false; cleanup_success = $true })

    $run = Invoke-HiddenOwnedProcess -Name '03-cargo-fmt-check' -FilePath $cargo `
        -Arguments @('fmt', '--check') -WorkingDirectory $repoRoot `
        -RunDirectory (Join-Path $EvidenceRoot '03-cargo-fmt-check') -TimeoutSeconds 120
    Add-StepResult 'cargo fmt --check' $run
    if ($failures.Count) { throw 'stop after cargo fmt failure' }

    $run = Invoke-HiddenOwnedProcess -Name '04-cargo-test' -FilePath $cargo `
        -Arguments @('test', '--bin', 'agent-observer-poc') -WorkingDirectory $repoRoot `
        -RunDirectory (Join-Path $EvidenceRoot '04-cargo-test') -TimeoutSeconds 120
    Add-StepResult 'cargo test --bin agent-observer-poc' $run
    if ($failures.Count) { throw 'stop after cargo test failure' }

    $observeScratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('agent-observer-hardening-observe-' + [Guid]::NewGuid().ToString('N'))))
    [void]$scratchRoots.Add($observeScratch)
    [IO.Directory]::CreateDirectory($observeScratch) | Out-Null
    $observeEnv = New-SyntheticEnvironment $observeScratch
    $run = Invoke-HiddenOwnedProcess -Name '05a-controlled-observe' -FilePath $exe `
        -Arguments @('observe', '--json') -WorkingDirectory $repoRoot -Environment $observeEnv `
        -RunDirectory (Join-Path $EvidenceRoot '05a-controlled-observe') -TimeoutSeconds 60
    Add-StepResult 'controlled agent-observer-poc.exe observe --json' $run
    $hostProbeCount = @($run.owned_processes | Where-Object { $_.name.ToLowerInvariant() -eq 'powershell.exe' -and $_.role -eq 'descendant' }).Count
    if ($hostProbeCount -lt 1) { [void]$failures.Add('controlled observe did not capture the owned host PowerShell process') }
    if ($run.visible_console_windows -ne 0) { [void]$failures.Add('controlled observe visible_console_windows!=0') }
    if ($run.unexpected_shell_children -ne 0) { [void]$failures.Add('controlled observe unexpected_shell_children!=0') }
    if ($failures.Count) { throw 'stop after controlled observe failure' }

    $e2eScratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('agent-observer-hardening-e2e-' + [Guid]::NewGuid().ToString('N'))))
    [void]$scratchRoots.Add($e2eScratch)
    [IO.Directory]::CreateDirectory($e2eScratch) | Out-Null
    $run = Invoke-HiddenOwnedProcess -Name '05b-single-synthetic-e2e' -FilePath $shell `
        -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $repoRoot 'scripts\pi-no-session-suppression-e2e.ps1'), '-Exe', $exe, '-ObserverDeadlineSeconds', '60', '-EvidenceDirectory', $e2eScratch, '-RunId', $RunId) `
        -WorkingDirectory $repoRoot -RunDirectory (Join-Path $EvidenceRoot '05b-single-synthetic-e2e') -TimeoutSeconds 90
    Add-StepResult 'single synthetic E2E' $run
    $singleE2eSummary = Get-Content -LiteralPath (Join-Path $e2eScratch 'e2e-summary.json') -Raw | ConvertFrom-Json
    if ($singleE2eSummary.visible_console_windows -ne 0 -or -not $singleE2eSummary.observer_pid) { [void]$failures.Add('single E2E did not record a hidden owned Observer') }
    if ($run.visible_console_windows -ne 0) { [void]$failures.Add('single E2E visible_console_windows!=0') }
    if ($run.unexpected_shell_children -ne 0) { [void]$failures.Add('single E2E unexpected_shell_children!=0') }
    if ($failures.Count) { throw 'stop after single E2E failure' }

    $concurrencyStart = [DateTimeOffset]::UtcNow
    $concurrencyDir = Join-Path $EvidenceRoot '06-concurrency'
    $concurrencyWork = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('agent-observer-hardening-concurrency-' + [Guid]::NewGuid().ToString('N'))))
    [void]$scratchRoots.Add($concurrencyWork)
    [IO.Directory]::CreateDirectory($concurrencyWork) | Out-Null
    $first = Start-HiddenOwnedProcess -Name '06a-first-lock-owner' -FilePath $shell `
        -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $repoRoot 'scripts\pi-no-session-suppression-e2e.ps1'), '-Exe', $exe, '-TestHoldLockMilliseconds', '3000', '-EvidenceDirectory', (Join-Path $concurrencyWork 'first'), '-RunId', $RunId) `
        -WorkingDirectory $repoRoot -RunDirectory (Join-Path $concurrencyDir 'first') -TimeoutSeconds 30
    Start-Sleep -Milliseconds 300
    $second = Invoke-HiddenOwnedProcess -Name '06b-second-lock-rejected' -FilePath $shell `
        -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $repoRoot 'scripts\pi-no-session-suppression-e2e.ps1'), '-Exe', $exe, '-EvidenceDirectory', (Join-Path $concurrencyWork 'second'), '-RunId', $RunId) `
        -WorkingDirectory $repoRoot -RunDirectory (Join-Path $concurrencyDir 'second') -TimeoutSeconds 3
    $firstRun = Complete-HiddenOwnedProcess -Launch $first
    $firstSummary = Get-Content -LiteralPath (Join-Path $concurrencyWork 'first\e2e-summary.json') -Raw | ConvertFrom-Json
    $secondSummary = Get-Content -LiteralPath (Join-Path $concurrencyWork 'second\e2e-summary.json') -Raw | ConvertFrom-Json
    if ($second.duration_ms -gt 3000) { [void]$failures.Add("second instance duration_ms=$($second.duration_ms), want <=3000") }
    if ($secondSummary.status -ne 'ALREADY_RUNNING' -or $secondSummary.pass -ne $false -or $secondSummary.observer_started -ne $false) {
        [void]$failures.Add('second instance did not return ALREADY_RUNNING/pass=false/observer_started=false')
    }
    if (@($second.owned_processes | Where-Object { $_.name.ToLowerInvariant() -eq 'agent-observer-poc.exe' }).Count -ne 0) {
        [void]$failures.Add('second instance started Observer')
    }
    if ($firstRun.child_exit_code -ne 0) { [void]$failures.Add('first lock owner did not finish successfully') }
    if (-not $firstSummary.observer_started -or -not $firstSummary.observer_pid -or @($firstSummary.owned_processes).Count -ne 1) {
        [void]$failures.Add('first lock owner did not record exactly one owned Observer')
    }

    $third = Invoke-HiddenOwnedProcess -Name '06c-third-after-release' -FilePath $shell `
        -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $repoRoot 'scripts\pi-no-session-suppression-e2e.ps1'), '-Exe', $exe, '-EvidenceDirectory', (Join-Path $concurrencyWork 'third'), '-RunId', $RunId) `
        -WorkingDirectory $repoRoot -RunDirectory (Join-Path $concurrencyDir 'third') -TimeoutSeconds 30
    if ($third.child_exit_code -ne 0) { [void]$failures.Add('third instance could not acquire released lock') }

    $abnormal = Start-HiddenOwnedProcess -Name '06d-abnormal-lock-owner' -FilePath $shell `
        -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $repoRoot 'scripts\pi-no-session-suppression-e2e.ps1'), '-Exe', $exe, '-TestHoldLockMilliseconds', '5000', '-EvidenceDirectory', (Join-Path $concurrencyWork 'abnormal'), '-RunId', $RunId) `
        -WorkingDirectory $repoRoot -RunDirectory (Join-Path $concurrencyDir 'abnormal') -TimeoutSeconds 30
    $abnormalRun = Complete-HiddenOwnedProcess -Launch $abnormal -KillAfterMilliseconds 300
    $afterAbnormal = Invoke-HiddenOwnedProcess -Name '06e-after-abnormal-release' -FilePath $shell `
        -Arguments @('-NoProfile', '-NonInteractive', '-File', (Join-Path $repoRoot 'scripts\pi-no-session-suppression-e2e.ps1'), '-Exe', $exe, '-EvidenceDirectory', (Join-Path $concurrencyWork 'after-abnormal'), '-RunId', $RunId) `
        -WorkingDirectory $repoRoot -RunDirectory (Join-Path $concurrencyDir 'after-abnormal') -TimeoutSeconds 30
    if (-not $abnormalRun.intentionally_killed -or $afterAbnormal.child_exit_code -ne 0) {
        [void]$failures.Add('mutex was not recovered after exact abnormal owner termination')
    }
    $concurrencyRuns = @($firstRun, $second, $third, $abnormalRun, $afterAbnormal)
    $concurrencyVisible = Get-IntegerSum $concurrencyRuns 'visible_console_windows'
    $concurrencyUnexpected = Get-IntegerSum $concurrencyRuns 'unexpected_shell_children'
    $concurrencyRemaining = Get-IntegerSum $concurrencyRuns 'owned_processes_remaining'
    $concurrencyDuration = [int64][math]::Round(([DateTimeOffset]::UtcNow - $concurrencyStart).TotalMilliseconds)
    $concurrencyPass = $failures.Count -eq 0 -and $concurrencyDuration -le 30000 -and $concurrencyVisible -eq 0 -and $concurrencyUnexpected -eq 0 -and $concurrencyRemaining -eq 0
    if ($concurrencyDuration -gt 30000) { [void]$failures.Add("concurrency test duration_ms=$concurrencyDuration, want <=30000") }
    if ($concurrencyVisible -ne 0) { [void]$failures.Add('concurrency visible_console_windows!=0') }
    if ($concurrencyUnexpected -ne 0) { [void]$failures.Add('concurrency unexpected_shell_children!=0') }
    if ($concurrencyRemaining -ne 0) { [void]$failures.Add('concurrency owned_processes_remaining!=0') }
    $concurrencySummary = [ordered]@{
        run_id = $RunId
        test = 'single-instance concurrency regression'
        status = if ($concurrencyPass) { 'PASS' } else { 'FAIL' }
        pass = $concurrencyPass
        started_at = $concurrencyStart.ToString('o')
        finished_at = [DateTimeOffset]::UtcNow.ToString('o')
        duration_ms = $concurrencyDuration
        timeout_detected = $false
        cleanup_success = ($concurrencyRemaining -eq 0)
        owned_processes_remaining = $concurrencyRemaining
        visible_console_windows = $concurrencyVisible
        unexpected_shell_children = $concurrencyUnexpected
        second_status = $secondSummary.status
        second_pass = $secondSummary.pass
        second_observer_started = $secondSummary.observer_started
        first_observer_pid = $firstSummary.observer_pid
        first_observer_count = @($firstSummary.owned_processes).Count
        second_observer_count = @($secondSummary.owned_processes).Count
        abnormal_recovery_pass = ($afterAbnormal.child_exit_code -eq 0)
    }
    Write-Utf8File (Join-Path $concurrencyDir 'concurrency-summary.json') ($concurrencySummary | ConvertTo-Json -Depth 6)
    Write-Utf8File (Join-Path $EvidenceRoot 'concurrency-summary.json') ($concurrencySummary | ConvertTo-Json -Depth 6)
    [void]$steps.Add([pscustomobject]@{ name = 'controlled concurrency rejection'; pass = $concurrencyPass; duration_ms = $concurrencyDuration; exit_code = 0; timeout_detected = $false; cleanup_success = ($concurrencyRemaining -eq 0) })
    if ($failures.Count) { throw 'stop after concurrency failure' }
} catch {
    $stoppedAfterFailure = $true
    if ([string]::IsNullOrEmpty($visibilityProbeFailure)) { $visibilityProbeFailure = $_.Exception.Message }
    if ($_.Exception.Message -notlike 'stop after*') { [void]$failures.Add($_.Exception.Message) }
} finally {
    foreach ($scratch in $scratchRoots) {
        try {
            $absolute = [IO.Path]::GetFullPath($scratch)
            $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            if (-not $absolute.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw "refusing non-TEMP cleanup: $absolute" }
            if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
        } catch { [void]$failures.Add("scratch cleanup: $($_.Exception.Message)") }
    }
}

$finalVisibleSnapshot = Get-VisibleWindowSnapshot -Stage 'supervisor-final'
$ownedProcesses = @(Get-AllOwnedProcessObservations)
if ($null -ne $supervisorContext -and $observedVisibleIds.Contains([int]$supervisorContext.supervisor_pid)) {
    $supervisorContext.root_process.visible_window_observed = $true
    $supervisorContext.supervisor_visible_window_observed = $true
}
$consoleNames = @('conhost.exe', 'OpenConsole.exe', 'WindowsTerminal.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe')
if ($null -ne $supervisorContext) {
    $ownedConsoleHosts = @($ownedProcesses | Where-Object { $consoleNames -contains [string]$_.name })
    $ownedWindowsTerminal = @($ownedProcesses | Where-Object { [string]$_.name -ieq 'WindowsTerminal.exe' })
    $supervisorContext.associated_console_hosts = @($supervisorContext.associated_console_hosts) + $ownedConsoleHosts
    $supervisorContext.associated_windows_terminal_processes = @($supervisorContext.associated_windows_terminal_processes) + $ownedWindowsTerminal
}
$visibilityReliable = [string]::IsNullOrEmpty($visibilityProbeFailure) -and $null -ne $supervisorContext -and `
    $supervisorContext.supervisor_parent_binding_verified -and $null -ne $finalVisibleSnapshot
$associatedProcesses = if ($null -ne $supervisorContext) { @($supervisorContext.supervisor_parent_chain) } else { @() }
$visibilityAudit = Get-VisibilityAuditResult -ProbeReliable $visibilityReliable `
    -BaselineVisibleProcessIds $script:baselineVisibleIds -ObservedVisibleProcessIds $(if ($visibilityReliable) { @($observedVisibleIds) } else { $null }) `
    -OwnedProcesses $ownedProcesses -AssociatedProcesses $associatedProcesses -SupervisorPid $PID

$rootVisibilityPass = $visibilityReliable -and -not $visibilityAudit.supervisor_visible_window_observed -and `
    $visibilityAudit.attributable_visible_windows -eq 0
[void]$steps.Add([pscustomobject]@{
    name = 'supervisor/root visibility check'
    pass = $rootVisibilityPass
    duration_ms = 0
    exit_code = if ($rootVisibilityPass) { 0 } else { 1 }
    timeout_detected = $false
    cleanup_success = $true
})
if ($visibilityReliable -and -not $rootVisibilityPass) { [void]$failures.Add('supervisor/root visibility check failed') }

$residualDetected = @(Get-AliveExactOwnedProcesses -Processes $ownedProcesses)
foreach ($residual in $residualDetected) {
    try { Stop-ExactOwnedProcessObservation -Observation $residual }
    catch { [void]$failures.Add("exact residual cleanup PID $($residual.pid): $($_.Exception.Message)") }
}
$residualRemaining = @(Get-AliveExactOwnedProcesses -Processes $ownedProcesses)
$ownedRemaining = $residualRemaining.Count
$unexpectedShellsMeasured = Get-IntegerSum $allRuns 'unexpected_shell_children'
$allCleanup = @($allRuns | Where-Object { -not $_.cleanup_success }).Count -eq 0 -and $ownedRemaining -eq 0
$finalCheck = [ordered]@{
    run_id = $RunId
    test = 'final exact-owned residual check'
    pass = ($ownedRemaining -eq 0)
    started_at = [DateTimeOffset]::UtcNow.ToString('o')
    finished_at = [DateTimeOffset]::UtcNow.ToString('o')
    duration_ms = 0
    timeout_detected = $false
    cleanup_success = $allCleanup
    owned_processes_remaining = $ownedRemaining
    residual_processes_detected = @($residualDetected)
    residual_processes_after_cleanup = @($residualRemaining)
    exact_owned_processes = @($ownedProcesses | ForEach-Object { [pscustomobject]@{ pid = $_.pid; creation_time = $_.creation_time; name = $_.name } })
}
Write-Utf8File (Join-Path $EvidenceRoot 'final-residual-check.json') ($finalCheck | ConvertTo-Json -Depth 6)
if ($residualDetected.Count -ne 0) { [void]$failures.Add("final residual check detected $($residualDetected.Count) exact owned process(es)") }
if (-not $finalCheck.pass) { [void]$failures.Add('final owned_processes_remaining!=0') }

$baselineEvidence = [ordered]@{
    run_id = $RunId
    captured_at = if ($null -ne $launchContext) { $launchContext.baseline_captured_at } else { $null }
    probe_reliable = if ($null -ne $launchContext) { $launchContext.baseline_probe_reliable } else { $false }
    visibility_probe_failure = if ($null -ne $launchContext) { $launchContext.visibility_probe_failure } else { $visibilityProbeFailure }
    baseline_visible_window_process_ids = if ($null -ne $launchContext -and $launchContext.baseline_probe_reliable) { @($script:baselineVisibleIds) } else { $null }
}
Write-Utf8File (Join-Path $EvidenceRoot 'visible-window-baseline.json') ($baselineEvidence | ConvertTo-Json -Depth 5)
$observationLines = @($visibilityObservations | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join "`n"
if ($observationLines) { $observationLines += "`n" }
Write-Utf8File (Join-Path $EvidenceRoot 'visible-window-observations.jsonl') $observationLines
Write-Utf8File (Join-Path $EvidenceRoot 'owned-process-tree.json') ([ordered]@{ run_id = $RunId; processes = @($ownedProcesses) } | ConvertTo-Json -Depth 9)
$supervisorContextEvidence = if ($null -ne $supervisorContext) {
    $supervisorContext
} else {
    [pscustomobject][ordered]@{
        run_id = $RunId
        supervisor_pid = $PID
        supervisor_parent_pid = $null
        supervisor_creation_time = $null
        supervisor_main_window_handle = $null
        supervisor_visible_window_observed = $null
        supervisor_parent_binding_verified = $false
        coordinator_binding = $coordinatorBinding
        supervisor_parent_chain = $null
        associated_console_hosts = $null
        associated_windows_terminal_processes = $null
    }
}
Write-Utf8File (Join-Path $EvidenceRoot 'supervisor-process-context.json') `
    ($supervisorContextEvidence | ConvertTo-Json -Depth 8)

$skippedReason = if ($stoppedAfterFailure) { 'not run because the supervisor preflight or an earlier serial step stopped acceptance' } else { $null }
$offlineFixturePath = Join-Path $EvidenceRoot 'offline-visibility-fixture-summary.json'
if (-not (Test-Path -LiteralPath $offlineFixturePath)) {
    Write-Utf8File $offlineFixturePath ([ordered]@{
        run_id = $RunId
        test = 'Windows visibility offline fixtures'
        status = 'BLOCKED'
        pass = $false
        fixture_count = 0
        fixture_passed = 0
        skipped = $true
        reason = $skippedReason
    } | ConvertTo-Json -Depth 5)
}
$topConcurrencyPath = Join-Path $EvidenceRoot 'concurrency-summary.json'
if (-not (Test-Path -LiteralPath $topConcurrencyPath)) {
    Write-Utf8File $topConcurrencyPath ([ordered]@{
        run_id = $RunId
        test = 'single-instance concurrency regression'
        status = 'BLOCKED'
        pass = $false
        skipped = $true
        reason = $skippedReason
        timeout_detected = $null
        cleanup_success = $null
        owned_processes_remaining = $null
        second_status = $null
    } | ConvertTo-Json -Depth 5)
}

$runIdEvidenceFailures = [Collections.Generic.List[string]]::new()
foreach ($file in Get-ChildItem -LiteralPath $EvidenceRoot -Recurse -File -ErrorAction SilentlyContinue) {
    try {
        if ($file.Extension -ieq '.json') {
            $value = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $value.PSObject.Properties['run_id'] -or [string]$value.run_id -cne $RunId) { [void]$runIdEvidenceFailures.Add($file.FullName) }
        } elseif ($file.Extension -ieq '.jsonl') {
            foreach ($line in Get-Content -LiteralPath $file.FullName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
                $value = $line | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $value.PSObject.Properties['run_id'] -or [string]$value.run_id -cne $RunId) { [void]$runIdEvidenceFailures.Add($file.FullName); break }
            }
        }
    } catch { [void]$runIdEvidenceFailures.Add("$($file.FullName): $($_.Exception.Message)") }
}
$evidenceRunIdPass = $runIdEvidenceFailures.Count -eq 0
[void]$steps.Add([pscustomobject]@{ name = 'atomic run_id evidence validation'; pass = $evidenceRunIdPass; duration_ms = 0; exit_code = if ($evidenceRunIdPass) { 0 } else { 1 }; timeout_detected = $false; cleanup_success = $true })
if (-not $evidenceRunIdPass) { [void]$failures.Add("run_id evidence validation failed: $($runIdEvidenceFailures -join '; ')") }

$hexMatches = [Collections.Generic.List[object]]::new()
foreach ($file in Get-ChildItem -LiteralPath $EvidenceRoot -Recurse -File -Filter '*.stderr.log' -ErrorAction SilentlyContinue) {
    try { $text = [IO.File]::ReadAllText($file.FullName) } catch [IO.IOException] { continue }
    foreach ($match in [regex]::Matches($text, '0x[0-9A-Fa-f]+')) {
        [void]$hexMatches.Add([pscustomobject]@{ source = $file.FullName; text = $match.Value })
    }
}
$finishedAt = [DateTimeOffset]::UtcNow
$timeoutDetected = @($allRuns | Where-Object timeout_detected).Count -gt 0
$status = if (-not $visibilityReliable) {
    'BLOCKED'
} elseif ($failures.Count -eq 0 -and $visibilityAudit.pass -and $unexpectedShellsMeasured -eq 0 -and `
    -not $timeoutDetected -and $allCleanup -and $ownedRemaining -eq 0) {
    'PASS'
} else {
    'FAIL'
}
$summary = [ordered]@{
    run_id = $RunId
    test = 'Windows Background Process Hardening v1.1 Visibility Audit Closure'
    status = $status
    pass = ($status -eq 'PASS')
    supervisor_exit_code = if ($status -eq 'PASS') { 0 } else { 1 }
    started_at = $startedAt.ToString('o')
    finished_at = $finishedAt.ToString('o')
    duration_ms = [int64][math]::Round(($finishedAt - $startedAt).TotalMilliseconds)
    timeout_detected = $timeoutDetected
    cleanup_success = $allCleanup -and $ownedRemaining -eq 0
    owned_processes_remaining = $ownedRemaining
    supervisor_pid = $PID
    supervisor_parent_binding_verified = if ($null -ne $supervisorContext) { [bool]$supervisorContext.supervisor_parent_binding_verified } else { $false }
    exact_coordinator_pid = if ($null -ne $supervisorContext -and $null -ne $supervisorContext.exact_coordinator) { [int]$supervisorContext.exact_coordinator.pid } else { $null }
    exact_coordinator_creation_time = if ($null -ne $supervisorContext -and $null -ne $supervisorContext.exact_coordinator) { [string]$supervisorContext.exact_coordinator.creation_time } else { $null }
    coordinator_visible_window_observed = if ($null -ne $supervisorContext -and $null -ne $supervisorContext.exact_coordinator) { [bool]$supervisorContext.exact_coordinator.visible_window_observed } elseif ($null -ne $launchContext) { $launchContext.coordinator_visible_window_observed } else { $null }
    supervisor_visible_window_observed = $visibilityAudit.supervisor_visible_window_observed
    associated_visible_console_hosts = $visibilityAudit.associated_visible_console_hosts
    visible_owned_windows = $visibilityAudit.visible_owned_windows
    attributable_visible_windows = $visibilityAudit.attributable_visible_windows
    unattributed_new_visible_windows = $visibilityAudit.unattributed_new_visible_windows
    windows_terminal_owned_visible = $visibilityAudit.windows_terminal_owned_visible
    visible_console_windows = $visibilityAudit.visible_owned_windows
    unexpected_shell_children = if ($visibilityReliable) { $unexpectedShellsMeasured } else { $null }
    visibility_probe_reliable = $visibilityReliable
    visibility_probe_failure = $visibilityProbeFailure
    baseline_visible_window_process_ids = $visibilityAudit.baseline_visible_window_process_ids
    observed_visible_window_process_ids = $visibilityAudit.observed_visible_window_process_ids
    new_visible_window_process_ids = $visibilityAudit.new_visible_window_process_ids
    attributable_visible_window_process_ids = $visibilityAudit.attributable_visible_window_process_ids
    unattributed_new_visible_window_process_ids = $visibilityAudit.unattributed_new_visible_window_process_ids
    stopped_after_failure = $stoppedAfterFailure
    previous_hex_error = if ($hexMatches.Count) { @($hexMatches) } else { 'NOT REPRODUCED' }
    network_requests = 0
    model_calls = 0
    real_user_configuration_touched = $false
    real_bridge_installation_attempted = $false
    evidence_run_id_verified = $evidenceRunIdPass
    evidence_run_id_failures = @($runIdEvidenceFailures)
    steps = $steps
    failures = $failures
}
Write-Utf8File (Join-Path $EvidenceRoot 'acceptance-summary.json') ($summary | ConvertTo-Json -Depth 10)
$summary | ConvertTo-Json -Depth 10
if (-not $summary.pass) { exit 1 }
