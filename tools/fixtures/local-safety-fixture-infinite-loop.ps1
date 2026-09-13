# Synthetic offline safety fixture: a worker whose main loop never terminates
# AFTER consuming the supervisor start gate. Direct execution is refused.
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
$null = Invoke-LocalSafetyWorkerPreflight -BoundParameters $PSBoundParameters `
    -Supervised:([bool]$Supervised) -RunId $RunId -SupervisorPid $SupervisorPid `
    -SupervisorCreationTimeUtc $SupervisorCreationTimeUtc `
    -AttemptMarkerPath $AttemptMarkerPath -StartGatePath $StartGatePath `
    -StartGateToken $StartGateToken -EvidenceRoot $EvidenceRoot `
    -Deadline $deadline -RunDirectory $RunDirectory
for (;;) { }
