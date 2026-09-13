# Job-owned helper: enumerate visible console-host window PIDs.
# Bounded by its own wall-clock deadline (default 3s). Does not create a Job
# Object, does not start children, and does not write attempt markers.
# Output is a single JSON file at -OutputPath.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1, 3)][int]$DeadlineSeconds = 3
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$startedAt = [DateTimeOffset]::UtcNow
$deadline = $startedAt.AddSeconds($DeadlineSeconds)
$utf8 = New-Object System.Text.UTF8Encoding $false

function Write-HelperResult {
    param([Parameter(Mandatory)]$Object)
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    [System.IO.File]::WriteAllText($OutputPath, ($Object | ConvertTo-Json -Compress -Depth 4), $utf8)
}

if ([DateTimeOffset]::UtcNow -ge $deadline) {
    Write-HelperResult -Object ([ordered]@{ status = 'UNKNOWN'; ids = @(); error = 'helper deadline exceeded before probe' })
    exit 1
}

if (-not ('AgentObserverSafety.WindowProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AgentObserverSafety
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

$consoleHostNames = @('conhost.exe', 'OpenConsole.exe', 'WindowsTerminal.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe')
$ids = New-Object System.Collections.Generic.List[int]
try {
    if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'helper deadline exceeded' }
    $visible = [AgentObserverSafety.WindowProbe]::VisibleWindowProcessIds()
    $names = @{}
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'helper deadline exceeded' }
        if ($null -eq $process) { continue }
        $names[[int]$process.Id] = ([string]$process.ProcessName).ToLowerInvariant()
    }
    if ($null -ne $visible) {
        foreach ($id in $visible) {
            $intId = [int]$id
            $name = [string]$names[$intId]
            if ($consoleHostNames -contains $name) {
                [void]$ids.Add($intId)
            }
        }
    }
    Write-HelperResult -Object ([ordered]@{
        status = 'ok'
        ids = [int[]]$ids.ToArray()
        error = $null
        duration_ms = [int]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
    })
    exit 0
} catch {
    Write-HelperResult -Object ([ordered]@{
        status = 'UNKNOWN'
        ids = [int[]]@()
        error = [string]$_.Exception.Message
        duration_ms = [int]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
    })
    exit 1
}
