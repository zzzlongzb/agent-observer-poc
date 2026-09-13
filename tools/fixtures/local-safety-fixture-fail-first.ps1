# Synthetic offline safety fixture: fixture A fails intentionally. The
# fixture worker runs its own sequential break-on-first-failure loop, so
# fixture B (which would write a canary file) must NEVER run.
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
$canaryPath = Join-Path $EvidenceRoot 'canary.txt'

function Invoke-FixtureA {
    throw 'fixture-a intentional failure'
}

function Invoke-FixtureB {
    [IO.File]::WriteAllText($canaryPath, 'fixture-b ran', $utf8)
    return $true
}

$executed = New-Object System.Collections.Generic.List[object]
$anyFailed = $false
foreach ($fixture in @(@{ name = 'fixture-a'; script = ${function:Invoke-FixtureA} }, @{ name = 'fixture-b'; script = ${function:Invoke-FixtureB} })) {
    if ($anyFailed) { break }
    $pass = $false
    $detail = ''
    try {
        $pass = [bool](& $fixture.script)
    } catch {
        $detail = [string]$_.Exception.Message
    }
    if (-not $pass) { $anyFailed = $true }
    [void]$executed.Add([pscustomobject][ordered]@{
        fixture = $fixture.name
        deadline_seconds = 2
        pass = [bool]$pass
        duration_ms = 0
        timeout_detected = $false
        detail = $detail
    })
}

$summary = [pscustomobject][ordered]@{
    status = 'FAIL'
    acceptance_pass = $false
    offline_selftest_passed = $false
    stopped_at_fixture = 'fixture-a'
    automatic_retries = 0
    fixtures = [object[]]$executed.ToArray()
    cleanup_success = $true
    owned_processes_remaining = 0
    canary_path = $canaryPath
    start_gate_consumed = $true
}
[System.IO.File]::WriteAllText((Join-Path $preflight.run_directory 'worker-summary.json'), ($summary | ConvertTo-Json -Depth 6), $utf8)
exit 1
