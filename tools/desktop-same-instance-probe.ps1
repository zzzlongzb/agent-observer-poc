# Read-only Desktop same-instance enumerator.
# Does not connect to pipes/TCP, does not print command lines, does not read
# ~/.claude/sessions/*.key, does not start app-server, does not send prompts.
# Usage: powershell -NoProfile -File tools/desktop-same-instance-probe.ps1

$ErrorActionPreference = 'Stop'

function Get-Tree([int[]]$rootPids, $all) {
    $seed = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($r in $rootPids) { [void]$seed.Add($r) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($p in $all) {
            $id = [int]$p.ProcessId
            $pp = [int]$p.ParentProcessId
            if ($seed.Contains($pp) -and -not $seed.Contains($id)) {
                [void]$seed.Add($id)
                $changed = $true
            }
        }
    }
    return $seed
}

$all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate)
$codexRoots = @($all | Where-Object {
        $_.ExecutablePath -match '(?i)WindowsApps\\OpenAI\.Codex_.*\\app\\ChatGPT\.exe$'
    })
$claudeRoots = @($all | Where-Object {
        $_.ExecutablePath -match '(?i)WindowsApps\\Claude_.*\\app\\Claude\.exe$'
    })

$codexIds = Get-Tree @($codexRoots | ForEach-Object { [int]$_.ProcessId }) $all
$claudeIds = Get-Tree @($claudeRoots | ForEach-Object { [int]$_.ProcessId }) $all

function Show-Proc($p) {
    $ctime = if ($p.CreationDate) { ([DateTimeOffset]$p.CreationDate).UtcDateTime.ToString('o') } else { $null }
    [pscustomobject]@{
        process_id = [int]$p.ProcessId
        parent_process_id = [int]$p.ParentProcessId
        name = $p.Name
        executable = $p.ExecutablePath
        creation_time_utc = $ctime
    }
}

Write-Output '=== Codex Desktop tree ==='
$all | Where-Object { $codexIds.Contains([int]$_.ProcessId) } | ForEach-Object { Show-Proc $_ | ConvertTo-Json -Compress }

Write-Output '=== Claude Desktop tree ==='
$all | Where-Object { $claudeIds.Contains([int]$_.ProcessId) } | ForEach-Object { Show-Proc $_ | ConvertTo-Json -Compress }

Write-Output '=== Claude PID session registry (no .key files) ==='
$sessRoot = Join-Path $env:USERPROFILE '.claude\sessions'
foreach ($p in ($all | Where-Object { $claudeIds.Contains([int]$_.ProcessId) })) {
    $jsonPath = Join-Path $sessRoot ("{0}.json" -f $p.ProcessId)
    if (-not (Test-Path -LiteralPath $jsonPath)) { continue }
    $s = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    [pscustomobject]@{
        pid = $s.pid
        sessionId = $s.sessionId
        cwd = $s.cwd
        entrypoint = $s.entrypoint
        kind = $s.kind
        version = $s.version
        pidDomain = $s.pidDomain
        messagingSocketPath = $s.messagingSocketPath
        procStart = $s.procStart
        live_executable = $p.ExecutablePath
    } | ConvertTo-Json -Compress
}

Write-Output '=== Named pipes (name match only; ownership not proven here) ==='
$keys = @('codex-ipc','codex-browser-use','codex-computer-use','cc-msg','cowork-vm-service')
Get-ChildItem '\\.\pipe\' -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($k in $keys) {
        if ($_.Name -like "*$k*") { $_.Name; break }
    }
}
