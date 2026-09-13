[CmdletBinding()]
param(
    [string]$EvidenceRoot = '',
    [ValidateRange(1, 300)][int]$OverallDeadlineSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$startedAt = [DateTimeOffset]::UtcNow
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $repoRoot 'docs\evidence\windows-background-process-hardening-v1.1-r1' }
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
$runId = $startedAt.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N')
$runDirectory = Join-Path (Join-Path $EvidenceRoot 'runs') $runId
[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$launchContextPath = Join-Path $runDirectory 'coordinator-launch-context.json'
$stdoutPath = Join-Path $runDirectory 'child.stdout.log'
$stderrPath = Join-Path $runDirectory 'child.stderr.log'

function Write-AtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $tempPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($tempPath, ($Value | ConvertTo-Json -Depth 12), $utf8)
    if (Test-Path -LiteralPath $Path) {
        $backupPath = $tempPath + '.bak'
        [IO.File]::Replace($tempPath, $Path, $backupPath)
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
    } else {
        [IO.File]::Move($tempPath, $Path)
    }
}

if (-not ('AgentObserverHardening.LaunchWindowProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace AgentObserverHardening {
    public static class LaunchWindowProbe {
        private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        public static int[] VisibleWindowProcessIds() {
            var ids = new HashSet<int>();
            var succeeded = EnumWindows((window, parameter) => {
                if (IsWindowVisible(window)) { uint processId; GetWindowThreadProcessId(window, out processId); if (processId != 0) ids.Add((int)processId); }
                return true;
            }, IntPtr.Zero);
            if (!succeeded) throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed");
            var result = new int[ids.Count]; ids.CopyTo(result); return result;
        }
    }
}
'@
}

$processRows = @()
$processInventoryFailure = $null
try { $processRows = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { $processInventoryFailure = $_.Exception.Message }
$running = @($processRows | Where-Object {
    [int]$_.ProcessId -ne $PID -and [string]$_.CommandLine -match '(?i)-File\s+[^\r\n]*(windows-background-process-hardening-(?:coordinator|supervisor)|pi-no-session-suppression-e2e)\.ps1'
})
if ($running.Count -gt 0) {
    $finishedAt = [DateTimeOffset]::UtcNow
    $blocked = [ordered]@{ run_id = $runId; test = 'Windows Background Process Hardening v1.1 Repair 1'; status = 'BLOCKED'; pass = $false; started_at = $startedAt.ToString('o'); finished_at = $finishedAt.ToString('o'); failures = @('a hardening coordinator, supervisor, or Pi E2E instance is already running'); existing_processes = @($running | ForEach-Object { [pscustomobject]@{ run_id = $runId; pid = [int]$_.ProcessId; parent_pid = [int]$_.ParentProcessId; creation_time = ([DateTime]$_.CreationDate).ToUniversalTime().ToString('o'); name = [string]$_.Name } }) }
    Write-AtomicJson (Join-Path $runDirectory 'acceptance-summary.json') $blocked
    Write-AtomicJson (Join-Path $EvidenceRoot 'latest-run.json') ([ordered]@{ run_id = $runId; relative_run_path = "runs/$runId"; status = 'BLOCKED'; started_at = $startedAt.ToString('o'); finished_at = $finishedAt.ToString('o') })
    $blocked | ConvertTo-Json -Depth 8
    exit 1
}

$baselineFailure = $null
$baselineIds = $null
try { $baselineIds = @([AgentObserverHardening.LaunchWindowProbe]::VisibleWindowProcessIds() | Sort-Object -Unique) } catch { $baselineFailure = $_.Exception.Message }
$selfProcess = [Diagnostics.Process]::GetProcessById($PID)
try {
    $selfProcess.Refresh()
    $coordinatorCreation = $selfProcess.StartTime.ToUniversalTime()
    $coordinatorHandle = $selfProcess.MainWindowHandle.ToInt64()
} finally { $selfProcess.Dispose() }

$rowByPid = @{}
foreach ($row in $processRows) { $rowByPid[[string]$row.ProcessId] = $row }
$selfRow = $rowByPid[[string]$PID]
$coordinatorParentPid = if ($null -ne $selfRow) { [int]$selfRow.ParentProcessId } else { $null }
$parentDiagnostics = [Collections.Generic.List[object]]::new()
$associatedConsoleHosts = [Collections.Generic.List[object]]::new()
$associatedWindowsTerminal = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[int]]::new()
$parentPid = if ($null -ne $coordinatorParentPid) { [int]$coordinatorParentPid } else { 0 }
while ($parentPid -gt 0 -and $seen.Add($parentPid)) {
    $parentRow = $rowByPid[[string]$parentPid]
    if ($null -eq $parentRow) {
        [void]$parentDiagnostics.Add([pscustomobject]@{ run_id = $runId; pid = $parentPid; status = 'TERMINATED_BEFORE_SAMPLE'; reliability = 'DIAGNOSTIC_ONLY'; creation_time = $null; parent_pid = $null; name = $null })
        break
    }
    $diagnostic = [pscustomobject]@{ run_id = $runId; pid = $parentPid; status = 'RECORDED_AT_LAUNCH'; reliability = 'DIAGNOSTIC_ONLY'; creation_time = ([DateTime]$parentRow.CreationDate).ToUniversalTime().ToString('o'); parent_pid = [int]$parentRow.ParentProcessId; name = [string]$parentRow.Name }
    [void]$parentDiagnostics.Add($diagnostic)
    if (@('conhost.exe', 'OpenConsole.exe', 'WindowsTerminal.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe') -contains $diagnostic.name) { [void]$associatedConsoleHosts.Add($diagnostic) }
    if ($diagnostic.name -ieq 'WindowsTerminal.exe') { [void]$associatedWindowsTerminal.Add($diagnostic) }
    $parentPid = [int]$parentRow.ParentProcessId
}

$baselineCapturedAt = [DateTimeOffset]::UtcNow
$launchContext = [ordered]@{
    observer_schema = 'windows-background-process-hardening-v1.1-r1'
    run_id = $runId
    repository_root = $repoRoot
    coordinator_pid = $PID
    coordinator_creation_time = $coordinatorCreation.ToString('o')
    coordinator_creation_time_unix_ms = ([DateTimeOffset]$coordinatorCreation).ToUnixTimeMilliseconds()
    coordinator_parent_pid = $coordinatorParentPid
    coordinator_main_window_handle = $coordinatorHandle
    coordinator_visible_window_observed = if ($null -eq $baselineIds) { $null } else { $baselineIds -contains $PID }
    baseline_captured_at = $baselineCapturedAt.ToString('o')
    baseline_visible_window_process_ids = $baselineIds
    baseline_probe_reliable = [string]::IsNullOrEmpty($baselineFailure)
    visibility_probe_failure = $baselineFailure
    associated_console_hosts = @($associatedConsoleHosts)
    associated_windows_terminal_processes = @($associatedWindowsTerminal)
    parent_chain_diagnostics = @($parentDiagnostics)
    process_inventory_failure = $processInventoryFailure
    created_at = [DateTimeOffset]::UtcNow.ToString('o')
}
Write-AtomicJson $launchContextPath $launchContext

$shell = if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe')) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $shell
$psi.WorkingDirectory = $repoRoot
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
if (-not ($psi.PSObject.Properties.Name -contains 'ArgumentList')) { throw 'This coordinator requires ProcessStartInfo.ArgumentList support' }
foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'windows-background-process-hardening-supervisor.ps1'), '-EvidenceRoot', $runDirectory, '-LaunchContextPath', $launchContextPath, '-ExpectedRunId', $runId, '-OverallDeadlineSeconds', [string]$OverallDeadlineSeconds)) { [void]$psi.ArgumentList.Add([string]$argument) }

$process = [Diagnostics.Process]::new()
$process.StartInfo = $psi
if (-not $process.Start()) { throw 'hardening supervisor failed to start' }
$supervisorCreation = $process.StartTime.ToUniversalTime()
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$completed = $process.WaitForExit(($OverallDeadlineSeconds + 5) * 1000)
if (-not $completed) {
    try {
        $candidate = [Diagnostics.Process]::GetProcessById($process.Id)
        try { if ($candidate.StartTime.ToUniversalTime() -eq $supervisorCreation) { $candidate.Kill($true); [void]$candidate.WaitForExit(5000) } } finally { $candidate.Dispose() }
    } catch [ArgumentException] { }
}
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
[IO.File]::WriteAllText($stdoutPath, $stdout, $utf8)
[IO.File]::WriteAllText($stderrPath, $stderr, $utf8)
$exitCode = if ($completed) { $process.ExitCode } else { 1 }
$process.Dispose()

$finishedAt = [DateTimeOffset]::UtcNow
$status = 'BLOCKED'
$acceptancePath = Join-Path $runDirectory 'acceptance-summary.json'
if (Test-Path -LiteralPath $acceptancePath) {
    try { $status = [string]((Get-Content -LiteralPath $acceptancePath -Raw | ConvertFrom-Json).status) } catch { $status = 'BLOCKED' }
}
Write-AtomicJson (Join-Path $EvidenceRoot 'latest-run.json') ([ordered]@{ run_id = $runId; relative_run_path = "runs/$runId"; status = $status; started_at = $startedAt.ToString('o'); finished_at = $finishedAt.ToString('o') })
Write-Output $stdout
if ($stderr) { [Console]::Error.Write($stderr) }
if (-not $completed) { [Console]::Error.WriteLine('hardening supervisor exceeded the coordinator deadline') }
exit $exitCode
