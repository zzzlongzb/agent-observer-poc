# Synthetic offline safety fixture: writes a canary file and succeeds. Used
# only by the duplicate-attempt refusal fixture: if the runner starts this
# worker even once, the canary proves the one-shot marker was bypassed.
# Direct execution is refused; the start gate must be consumed first.
#Requires -Version 5.1
[CmdletBinding()]
param(
    # No prompt-triggering required bindings: a missing supervision parameter must fail
    # loudly and non-interactively, never trigger an interactive prompt.
    [switch]$Supervised,
    [string]$RunId = '',
    [int]$SupervisorPid = 0,
    [string]$SupervisorCreationTimeUtc = '',
    [string]$AttemptMarkerPath = '',
    [string]$StartGatePath = '',
    [string]$StartGateToken = '',
    [string]$EvidenceRoot = '',
    [int]$OverallDeadlineSeconds = 90,
    [string]$RunDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# FIRST check of the script body: non-interactive refusal of direct execution.
# This runs before the harness library is loaded and before TEMP, logs,
# evidence files or any child process can be created.
if (-not $Supervised) {
    [Console]::Error.WriteLine('REFUSING TO START: fixture worker must be launched by the supervisor with -Supervised; direct execution is forbidden')
    exit 1
}

# Explicit per-parameter supervision checks (each missing item is reported by
# name; still no side effects on this refusal path).
$missingSupervisionParams = New-Object System.Collections.Generic.List[string]
if ([string]::IsNullOrWhiteSpace($RunId)) { [void]$missingSupervisionParams.Add('-RunId') }
if ($SupervisorPid -le 0) { [void]$missingSupervisionParams.Add('-SupervisorPid') }
if ([string]::IsNullOrWhiteSpace($SupervisorCreationTimeUtc)) { [void]$missingSupervisionParams.Add('-SupervisorCreationTimeUtc') }
if ([string]::IsNullOrWhiteSpace($AttemptMarkerPath)) { [void]$missingSupervisionParams.Add('-AttemptMarkerPath') }
if ([string]::IsNullOrWhiteSpace($StartGatePath)) { [void]$missingSupervisionParams.Add('-StartGatePath') }
if ([string]::IsNullOrWhiteSpace($StartGateToken)) { [void]$missingSupervisionParams.Add('-StartGateToken') }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { [void]$missingSupervisionParams.Add('-EvidenceRoot') }
if ($missingSupervisionParams.Count -gt 0) {
    [Console]::Error.WriteLine(("REFUSING TO START: missing required supervision parameter(s): {0}" -f ($missingSupervisionParams -join ', ')))
    exit 1
}
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($OverallDeadlineSeconds)
. (Join-Path $PSScriptRoot '..\local-package-harness.ps1')
$preflight = Invoke-LocalSafetyWorkerPreflight -BoundParameters $PSBoundParameters `
    -Supervised:([bool]$Supervised) -RunId $RunId -SupervisorPid $SupervisorPid `
    -SupervisorCreationTimeUtc $SupervisorCreationTimeUtc `
    -AttemptMarkerPath $AttemptMarkerPath -StartGatePath $StartGatePath `
    -StartGateToken $StartGateToken -EvidenceRoot $EvidenceRoot `
    -Deadline $deadline -RunDirectory $RunDirectory
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $EvidenceRoot 'canary.txt'), 'canary-written', $utf8)
$summary = [pscustomobject][ordered]@{
    status = 'OFFLINE'
    acceptance_pass = $false
    offline_selftest_passed = $true
    automatic_retries = 0
    fixtures = @()
    cleanup_success = $true
    owned_processes_remaining = 0
    start_gate_consumed = $true
}
[System.IO.File]::WriteAllText((Join-Path $preflight.run_directory 'worker-summary.json'), ($summary | ConvertTo-Json -Depth 6), $utf8)
exit 0
