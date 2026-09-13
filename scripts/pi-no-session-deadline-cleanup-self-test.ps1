# Offline self-test for exact-child deadline and TEMP cleanup.
param([int]$TimeoutMilliseconds = 1000)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('agent-observer-deadline-selftest-' + [Guid]::NewGuid().ToString('N'))))
$child = $null
$result = [ordered]@{
    test = 'deadline-cleanup-self-test'
    timeout_detected = $false
    exact_child_terminated = $false
    scratch_remaining = $true
    owned_processes_remaining = -1
    pass = $false
    failures = @()
}
function Stop-ExactChild {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    $killWithTree = $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
    if ($null -ne $killWithTree) { $Process.Kill($true) } else { $Process.Kill() }
    [void]$Process.WaitForExit(5000)
}
try {
    if ($TimeoutMilliseconds -lt 500 -or $TimeoutMilliseconds -gt 3000) { throw 'timeout must be 500..3000 ms' }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'owned.txt'), 'synthetic')
    $shell = if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')) {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    } else { 'pwsh' }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $shell
    $psi.Arguments = '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 10"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $psi
    if (-not $child.Start()) { throw 'failed to start self-test child' }
    $childPid = $child.Id
    if ($child.WaitForExit($TimeoutMilliseconds)) { throw 'child exited before deadline; timeout was not exercised' }
    $result.timeout_detected = $true
    Stop-ExactChild $child
    $result.exact_child_terminated = $child.HasExited
    if (-not $result.exact_child_terminated) { throw "exact child PID $childPid did not exit" }
} catch { $result.failures += $_.Exception.Message } finally {
    $childExited = $true
    if ($null -ne $child) {
        try { if (-not $child.HasExited) { Stop-ExactChild $child }; $childExited = $child.HasExited } catch { $childExited = $false; $result.failures += "child cleanup: $($_.Exception.Message)" }
        try { $child.Dispose() } catch { }
    }
    try { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } } catch { $result.failures += "scratch cleanup: $($_.Exception.Message)" }
    $result.scratch_remaining = Test-Path -LiteralPath $root
    $result.owned_processes_remaining = if ($childExited) { 0 } else { 1 }
    if ($result.scratch_remaining) { $result.failures += 'scratch_remaining=true' }
    if ($result.owned_processes_remaining -ne 0) { $result.failures += 'owned_processes_remaining!=0' }
    $result.pass = ($result.failures.Count -eq 0 -and $result.timeout_detected -and $result.exact_child_terminated -and -not $result.scratch_remaining -and $result.owned_processes_remaining -eq 0)
}
Write-Output ($result | ConvertTo-Json -Depth 5)
if (-not $result.pass) { exit 1 }
