# Offline executable E2E for Pi No-Session Invocation Suppression v1.1.
# Uses synthetic TEMP-only data; no real model, network, Pi, or user session.
param(
    [string]$Exe = '',
    [int]$ObserverDeadlineSeconds = 60,
    [ValidateRange(0, 5000)][int]$TestHoldLockMilliseconds = 0,
    [string]$EvidenceDirectory = '',
    [string]$RunId = ''
)

$ErrorActionPreference = 'Stop'
$startedAt = [DateTimeOffset]::UtcNow
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (-not $Exe) { $Exe = Join-Path $repoRoot 'target\debug\agent-observer-poc.exe' }
$Exe = [IO.Path]::GetFullPath($Exe)

$guid = [Guid]::NewGuid().ToString('N')
$scratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("agent-observer-pi-no-session-e2e-$guid")))
if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $repoRoot "docs\evidence\windows-background-process-hardening-v1\direct-e2e-$guid"
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
$ownedProcesses = [Collections.Generic.List[object]]::new()
$proc = $null
$stdoutFile = $null
$stderrFile = $null
$singleInstanceMutex = $null
$lockAcquired = $false
$previous = @{}
$envVars = @{}
$result = [ordered]@{
    run_id = if ($RunId) { $RunId } else { $null }
    test = 'Pi No-Session Invocation Suppression v1.1 E2E'
    status = 'FAIL'
    pass = $false
    qa_only_lock_hold_milliseconds = $TestHoldLockMilliseconds
    observer_started = $false
    observer_pid = $null
    observer_parent_pid = $PID
    observer_creation_time = $null
    observer_main_window_handle = $null
    visible_console_windows = -1
    unexpected_shell_children = 0
    owned_processes = @()
    started_at = $startedAt.ToString('o')
    finished_at = $null
    duration_ms = $null
    timeout_detected = $false
    timed_out = $false
    cleanup_success = $false
    cleanup_complete = $false
    scratch_remaining = $true
    owned_processes_remaining = -1
    observer_deadline_seconds = $ObserverDeadlineSeconds
    session_count = $null
    suppressed_count = $null
    working_count = $null
    result_ready_count = $null
    lost_count = $null
    sessions = @()
    failures = @()
}

$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Content = '')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}
function Stop-ExactProcessTree {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    $killWithTree = $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
    if ($null -ne $killWithTree) {
        $Process.Kill($true)
    } else {
        # Windows PowerShell 5.1 has no Kill(bool); the observer is launched
        # directly and has no child process contract, so this remains exact PID.
        $Process.Kill()
    }
    [void]$Process.WaitForExit(5000)
}
function Get-ExactOwnedProcessCount {
    $remaining = 0
    foreach ($owned in $ownedProcesses) {
        try {
            $p = [Diagnostics.Process]::GetProcessById($owned.pid)
            if (-not $p.HasExited -and $p.StartTime.ToUniversalTime() -eq $owned.started_at) { $remaining++ }
            $p.Dispose()
        } catch [ArgumentException] { }
    }
    return $remaining
}
function Expect-Present {
    param([string]$Id, [array]$Ids)
    if ($Ids -notcontains $Id) { $result.failures += "missing $Id" }
}
function Expect-Absent {
    param([string]$Id, [array]$Ids)
    if ($Ids -contains $Id) { $result.failures += "unexpected $Id" }
}

try {
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "Observer executable not found: $Exe" }
    if ($ObserverDeadlineSeconds -lt 1 -or $ObserverDeadlineSeconds -gt 60) { throw 'Observer deadline must be 1..60 seconds' }

    $lockIdentity = ($repoRoot.TrimEnd('\').ToUpperInvariant() + '|' + [IO.Path]::GetFileName($PSCommandPath).ToUpperInvariant())
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $lockHash = -join ($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($lockIdentity)) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha256.Dispose()
    }
    $singleInstanceMutex = [Threading.Mutex]::new($false, "Local\AgentObserverPiNoSessionE2E-$lockHash")
    try {
        $lockAcquired = $singleInstanceMutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $lockAcquired = $true
    }
    if (-not $lockAcquired) {
        $result.status = 'ALREADY_RUNNING'
        $result.failures += 'ALREADY_RUNNING: another instance owns the repository/script mutex'
        throw [InvalidOperationException]::new('ALREADY_RUNNING')
    }
    if ($TestHoldLockMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $TestHoldLockMilliseconds
    }

    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $piSessions = Join-Path $scratch 'pi-sessions'
    $piHooks = Join-Path $scratch 'pi-hooks'
    $emptyDirs = @('codex','claude','claude-hooks','claude-sessions','grok-sessions','grok-hooks','runtime-bindings','empty')
    foreach ($dir in @($piSessions, $piHooks) + ($emptyDirs | ForEach-Object { Join-Path $scratch $_ })) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $grokActive = Join-Path $scratch 'active_sessions.json'
    Write-Utf8File $grokActive '[]'

    # A: explicit no-session helper, hook only: suppressed.
    Write-Utf8File (Join-Path $piHooks 'pi-ns-drop.jsonl') @'
{"observer_schema":1,"source":"pi-extension","event":"agent_start","session_id":"pi-ns-drop","mode":"print","no_session":true,"observed_at_unix_ms":1788300000000}
'@
    # B: ordinary RPC with explicit false, Chinese title: visible/WORKING.
    Write-Utf8File (Join-Path $piHooks 'pi-ordinary-rpc.jsonl') @'
{"observer_schema":1,"source":"pi-extension","event":"agent_start","session_id":"pi-ordinary-rpc","cwd":"D:\\work\\ordinary","mode":"rpc","session_name":"\u666e\u901a\u4e2d\u6587\u4f1a\u8bdd","no_session":false,"observed_at_unix_ms":1788300000000}
'@
    # C: legacy print hook with the marker absent: visible/WORKING.
    Write-Utf8File (Join-Path $piHooks 'pi-legacy-print.jsonl') @'
{"observer_schema":1,"source":"pi-extension","event":"agent_start","session_id":"pi-legacy-print","cwd":"D:\\legacy","mode":"print","observed_at_unix_ms":1788300000000}
'@
    # D: false -> true is mixed and must be conservatively kept.
    Write-Utf8File (Join-Path $piHooks 'pi-mixed-false-true.jsonl') @'
{"observer_schema":1,"source":"pi-extension","event":"agent_start","session_id":"pi-mixed-false-true","cwd":"D:\\mixed-false-true","no_session":false,"observed_at_unix_ms":1788300000000}
{"observer_schema":1,"source":"pi-extension","event":"agent_start","session_id":"pi-mixed-false-true","cwd":"D:\\mixed-false-true","no_session":true,"observed_at_unix_ms":1788300000001}
'@
    # E: true -> false is mixed and must also be kept.
    Write-Utf8File (Join-Path $piHooks 'pi-mixed-true-false.jsonl') @'
{"observer_schema":1,"source":"pi-extension","event":"agent_start","session_id":"pi-mixed-true-false","cwd":"D:\\mixed-true-false","no_session":true,"observed_at_unix_ms":1788300000000}
{"observer_schema":1,"source":"pi-extension","event":"agent_start","session_id":"pi-mixed-true-false","cwd":"D:\\mixed-true-false","no_session":false,"observed_at_unix_ms":1788300000001}
'@
    # F: hook true is suppressed, but same native ID has a valid journal.
    Write-Utf8File (Join-Path $piHooks 'pi-shared-hook.jsonl') @'
{"observer_schema":1,"source":"pi-extension","event":"agent_start","session_id":"pi-shared","cwd":"D:\\hook-cwd","no_session":true,"observed_at_unix_ms":1788300000000}
'@
    $sharedCwd = 'D:\' + (-join @([char]0x4E2D,[char]0x6587,[char]0x5DE5,[char]0x4F5C,[char]0x533A))
    $sharedTitle = -join @([char]0x5171,[char]0x4EAB,[char]0x4E2D,[char]0x6587,[char]0x6807,[char]0x9898)
    Write-Utf8File (Join-Path $piSessions 'pi-shared.jsonl') ((
        '{"type":"session","version":3,"id":"pi-shared","timestamp":"2026-09-02T10:00:00Z","cwd":"' + $sharedCwd.Replace('\','\\') + '"}' + "`n" +
        '{"type":"message","id":"m","parentId":null,"timestamp":"2026-09-02T10:00:01Z","message":{"role":"user","content":"redacted","timestamp":1788300001000}}' + "`n" +
        '{"type":"session_info","id":"n","timestamp":"2026-09-02T10:00:02Z","name":"' + $sharedTitle + '"}' + "`n"
    ))

    $outputPath = Join-Path $scratch 'observer-output.json'
    $stderrPath = Join-Path $scratch 'observer-stderr.txt'
    $envVars = @{
        AGENT_OBSERVER_CODEX_ROOT = Join-Path $scratch 'codex'
        AGENT_OBSERVER_CLAUDE_ROOT = Join-Path $scratch 'claude'
        AGENT_OBSERVER_CLAUDE_HOOK_ROOT = Join-Path $scratch 'claude-hooks'
        AGENT_OBSERVER_CLAUDE_SESSION_ROOT = Join-Path $scratch 'claude-sessions'
        AGENT_OBSERVER_PI_SESSION_ROOT = $piSessions
        AGENT_OBSERVER_PI_HOOK_ROOT = $piHooks
        AGENT_OBSERVER_GROK_SESSION_ROOT = Join-Path $scratch 'grok-sessions'
        AGENT_OBSERVER_GROK_ACTIVE_SESSIONS = $grokActive
        AGENT_OBSERVER_GROK_HOOK_ROOT = Join-Path $scratch 'grok-hooks'
        AGENT_OBSERVER_RUNTIME_BINDING_ROOT = Join-Path $scratch 'runtime-bindings'
    }
    foreach ($name in $envVars.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $envVars[$name], 'Process')
    }

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    if ($psi.PSObject.Properties.Name -contains 'ArgumentList') {
        [void]$psi.ArgumentList.Add('observe')
        [void]$psi.ArgumentList.Add('--json')
    } else {
        # Windows PowerShell 5.1 fallback; both arguments are fixed literals.
        $psi.Arguments = 'observe --json'
    }
    $psi.WorkingDirectory = $repoRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $proc = [Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw 'failed to start exact Observer process' }
    $proc.Refresh()
    $observerStartedAt = $proc.StartTime.ToUniversalTime()
    $observerWindowHandle = $proc.MainWindowHandle.ToInt64()
    $result.observer_started = $true
    $result.observer_pid = $proc.Id
    $result.observer_creation_time = $observerStartedAt.ToString('o')
    $result.observer_main_window_handle = $observerWindowHandle
    $result.visible_console_windows = if ($observerWindowHandle -eq 0) { 0 } else { 1 }
    $result.owned_processes = @([ordered]@{
        pid = $proc.Id
        parent_pid = $PID
        creation_time = $observerStartedAt.ToString('o')
        name = 'agent-observer-poc.exe'
        command_line = "$Exe observe --json"
        main_window_handle = $observerWindowHandle
        visible_window_observed = ($observerWindowHandle -ne 0)
    })
    [void]$ownedProcesses.Add([pscustomobject]@{
        pid = $proc.Id
        started_at = $observerStartedAt
    })
    # Begin draining both redirected pipes before waiting. Waiting first can
    # deadlock when the JSON scan exceeds the OS pipe buffer.
    $stdoutFile = [IO.File]::Open($outputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $stderrFile = [IO.File]::Open($stderrPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $stdoutTask = $proc.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
    $stderrTask = $proc.StandardError.BaseStream.CopyToAsync($stderrFile)
    $deadlineMs = $ObserverDeadlineSeconds * 1000
    if (-not $proc.WaitForExit($deadlineMs)) {
        $result.timeout_detected = $true
        $result.timed_out = $true
        Stop-ExactProcessTree $proc
        throw "Observer exceeded internal deadline of $ObserverDeadlineSeconds seconds"
    }
    [void]$stdoutTask.GetAwaiter().GetResult()
    [void]$stderrTask.GetAwaiter().GetResult()
    $stdoutFile.Dispose()
    $stderrFile.Dispose()
    $stdout = [IO.File]::ReadAllText($outputPath, $utf8)
    $stderr = [IO.File]::ReadAllText($stderrPath, $utf8)
    $result.exit_code = $proc.ExitCode
    if ($proc.ExitCode -ne 0) { throw "Observer exit $($proc.ExitCode): $stderr" }

    $scan = ConvertFrom-Json -InputObject $stdout
    $sessions = @($scan.sessions)
    $ids = @($sessions | ForEach-Object { $_.native_session_id })
    $result.session_count = [int]$scan.session_count
    $expectedVisibleIds = @('pi-ordinary-rpc','pi-legacy-print','pi-mixed-false-true','pi-mixed-true-false','pi-shared')
    $expectedSuppressedIds = @('pi-ns-drop')
    $result.suppressed_count = @($expectedSuppressedIds | Where-Object { $ids -notcontains $_ }).Count
    $result.working_count = @($sessions | Where-Object attention_state -eq 'WORKING').Count
    $result.result_ready_count = @($sessions | Where-Object attention_state -eq 'RESULT_READY').Count
    $result.lost_count = @($sessions | Where-Object session_liveness -eq 'LOST').Count
    $result.sessions = @($sessions | ForEach-Object {
        [ordered]@{
            native_session_id = $_.native_session_id
            cwd = $_.cwd
            session_display_name = $_.session_display_name
            attention_state = $_.attention_state
            evidence_freshness = $_.evidence_freshness
            session_liveness = $_.session_liveness
            host_liveness = $_.host_liveness
            source = $_.source
        }
    })

    Expect-Absent 'pi-ns-drop' $ids
    foreach ($id in $expectedVisibleIds) { Expect-Present $id $ids }
    if ($result.suppressed_count -ne $expectedSuppressedIds.Count) { $result.failures += "suppressed_count=$($result.suppressed_count), want $($expectedSuppressedIds.Count)" }
    if ($result.session_count -ne 5) { $result.failures += "session_count=$($result.session_count), want 5" }
    if ($result.working_count -lt 4) { $result.failures += "working_count=$($result.working_count), want >=4" }
    if ($result.result_ready_count -ne 0) { $result.failures += "result_ready_count=$($result.result_ready_count), want 0" }
    if ($result.lost_count -ne 0) { $result.failures += "lost_count=$($result.lost_count), want 0" }
    if (@($ids | Group-Object | Where-Object Count -gt 1).Count -ne 0) { $result.failures += 'duplicate native IDs' }
    foreach ($id in @('pi-ordinary-rpc','pi-legacy-print','pi-mixed-false-true','pi-mixed-true-false')) {
        $row = $sessions | Where-Object native_session_id -eq $id | Select-Object -First 1
        if ($row.attention_state -ne 'WORKING') { $result.failures += "$id not WORKING" }
    }
    $ordinary = $sessions | Where-Object native_session_id -eq 'pi-ordinary-rpc' | Select-Object -First 1
    $ordinaryTitle = -join @([char]0x666E,[char]0x901A,[char]0x4E2D,[char]0x6587,[char]0x4F1A,[char]0x8BDD)
    if ($ordinary.session_display_name -ne $ordinaryTitle) { $result.failures += 'ordinary Chinese title mismatch' }
    if ($ordinary.session_liveness -eq 'LOST') { $result.failures += 'ordinary session is LOST' }
    $shared = $sessions | Where-Object native_session_id -eq 'pi-shared' | Select-Object -First 1
    if ($shared.source -ne 'pi-journal (passive)') { $result.failures += 'shared source was not pi-journal (passive)' }
    $sharedTitle = -join @([char]0x5171,[char]0x4EAB,[char]0x4E2D,[char]0x6587,[char]0x6807,[char]0x9898)
    $sharedCwd = 'D:\' + (-join @([char]0x4E2D,[char]0x6587,[char]0x5DE5,[char]0x4F5C,[char]0x533A))
    if ($shared.session_display_name -ne $sharedTitle) { $result.failures += 'shared Chinese title mismatch' }
    if ($shared.cwd -ne $sharedCwd) { $result.failures += 'shared cwd mismatch' }
    if ($shared.session_liveness -eq 'LOST') { $result.failures += 'shared session is LOST' }

    $result.pass = ($result.failures.Count -eq 0)
    if ($result.pass) { $result.status = 'PASS' }
} catch {
    if ($result.status -ne 'ALREADY_RUNNING') { $result.failures += $_.Exception.Message }
} finally {
    if ($null -ne $stdoutFile) { try { $stdoutFile.Dispose() } catch { } }
    if ($null -ne $stderrFile) { try { $stderrFile.Dispose() } catch { } }
    if ($null -ne $proc) {
        try {
            if (-not $proc.HasExited) { Stop-ExactProcessTree $proc }
        } catch { $result.failures += "cleanup process: $($_.Exception.Message)" }
    }
    foreach ($name in $envVars.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
    $result.owned_processes_remaining = Get-ExactOwnedProcessCount
    $result.owned_processes_remaining = [int]$result.owned_processes_remaining
    # Evidence must be copied before deleting the unique scratch directory.
    $evidence = $EvidenceDirectory
    [IO.Directory]::CreateDirectory((Join-Path $evidence 'fixtures\pi-hooks')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $evidence 'fixtures\pi-sessions')) | Out-Null
    if (Test-Path -LiteralPath (Join-Path $scratch 'observer-output.json')) { Copy-Item (Join-Path $scratch 'observer-output.json') (Join-Path $evidence 'observer-output.json') -Force }
    if (Test-Path -LiteralPath (Join-Path $scratch 'observer-stderr.txt')) { Copy-Item (Join-Path $scratch 'observer-stderr.txt') (Join-Path $evidence 'observer-stderr.txt') -Force }
    if (Test-Path -LiteralPath (Join-Path $scratch 'pi-hooks')) { Copy-Item (Join-Path $scratch 'pi-hooks\*') (Join-Path $evidence 'fixtures\pi-hooks') -Force }
    if (Test-Path -LiteralPath (Join-Path $scratch 'pi-sessions')) { Copy-Item (Join-Path $scratch 'pi-sessions\*') (Join-Path $evidence 'fixtures\pi-sessions') -Force }

    $scratchAbsolute = [IO.Path]::GetFullPath($scratch)
    $tempAbsolute = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $scratchUnderTemp = $scratchAbsolute.StartsWith($tempAbsolute.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    if (-not $scratchUnderTemp) { $result.failures += 'scratch was not under TEMP' }
    try {
        if (Test-Path -LiteralPath $scratchAbsolute) { Remove-Item -LiteralPath $scratchAbsolute -Recurse -Force }
    } catch { $result.failures += "scratch cleanup: $($_.Exception.Message)" }
    $result.scratch_remaining = Test-Path -LiteralPath $scratchAbsolute
    if ($result.scratch_remaining) { $result.failures += 'scratch_remaining=true' }
    if ($result.owned_processes_remaining -ne 0) { $result.failures += 'owned_processes_remaining!=0' }
    $result.cleanup_complete = (-not $result.scratch_remaining -and $result.owned_processes_remaining -eq 0)
    $result.cleanup_success = $result.cleanup_complete
    if ($result.visible_console_windows -lt 0) { $result.visible_console_windows = 0 }
    if ($result.visible_console_windows -ne 0) { $result.failures += 'visible_console_windows!=0' }
    $result.pass = ($result.failures.Count -eq 0 -and $result.cleanup_complete -and -not $result.timeout_detected)
    if ($result.pass) { $result.status = 'PASS' }
    elseif ($result.status -ne 'ALREADY_RUNNING') { $result.status = 'FAIL' }
    if ($lockAcquired -and $null -ne $singleInstanceMutex) {
        try { $singleInstanceMutex.ReleaseMutex() } catch { $result.failures += "mutex release: $($_.Exception.Message)"; $result.pass = $false; $result.status = 'FAIL' }
    }
    if ($null -ne $singleInstanceMutex) { $singleInstanceMutex.Dispose() }
    $finishedAt = [DateTimeOffset]::UtcNow
    $result.finished_at = $finishedAt.ToString('o')
    $result.duration_ms = [int64][math]::Round(($finishedAt - $startedAt).TotalMilliseconds)
    Write-Utf8File (Join-Path $evidence 'e2e-summary.json') ($result | ConvertTo-Json -Depth 8)
}

Write-Output ($result | ConvertTo-Json -Depth 8)
if (-not $result.pass) { exit 1 }
