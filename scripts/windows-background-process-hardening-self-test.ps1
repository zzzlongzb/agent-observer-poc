[CmdletBinding()]
param(
    [string]$EvidenceDirectory = '',
    [string]$RunId = '',
    [ValidateRange(1, 30)][int]$DeadlineSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$startedAt = [DateTimeOffset]::UtcNow
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $RunId) { $RunId = 'standalone-' + [Guid]::NewGuid().ToString('N') }
if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $repoRoot "docs\evidence\windows-background-process-hardening-v1.1-r1\runs\$RunId"
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
[IO.Directory]::CreateDirectory($EvidenceDirectory) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$failures = [Collections.Generic.List[string]]::new()
$visibilityResults = [Collections.Generic.List[object]]::new()
$bindingResults = [Collections.Generic.List[object]]::new()

. (Join-Path $repoRoot 'tools\windows-visibility-audit.ps1')

function Write-SelfTestJson {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value)
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory $Name), ($Value | ConvertTo-Json -Depth 12), $utf8)
}

function New-FixtureProcess {
    param([int]$Id, [string]$Name, [bool]$Visible, [string]$Role = 'descendant', [string]$CreationTime = '2026-09-03T00:00:00.0000000Z')
    [pscustomobject]@{ pid = $Id; name = $Name; creation_time = $CreationTime; visible_window_observed = $Visible; role = $Role }
}

function Add-VisibilityFixture {
    param(
        [string]$Name, [bool]$ProbeReliable, [AllowNull()]$Baseline, [AllowNull()]$Observed,
        [AllowNull()]$Owned, [AllowNull()]$Associated, [int]$SupervisorPid,
        [string]$ExpectedStatus, [bool]$ExpectedPass,
        [AllowNull()][Nullable[int]]$ExpectedVisibleOwned,
        [AllowNull()][Nullable[int]]$ExpectedUnattributed = $null,
        [AllowNull()][Nullable[int]]$ExpectedWindowsTerminal = $null
    )
    $audit = Get-VisibilityAuditResult -ProbeReliable $ProbeReliable `
        -BaselineVisibleProcessIds $Baseline -ObservedVisibleProcessIds $Observed `
        -OwnedProcesses $Owned -AssociatedProcesses $Associated -SupervisorPid $SupervisorPid
    $fixtureFailures = [Collections.Generic.List[string]]::new()
    if ($audit.status -ne $ExpectedStatus) { [void]$fixtureFailures.Add("status=$($audit.status), want $ExpectedStatus") }
    if ($audit.pass -ne $ExpectedPass) { [void]$fixtureFailures.Add("pass=$($audit.pass), want $ExpectedPass") }
    if ($null -ne $ExpectedVisibleOwned -and $audit.visible_owned_windows -ne [int]$ExpectedVisibleOwned) { [void]$fixtureFailures.Add("visible_owned_windows=$($audit.visible_owned_windows), want $ExpectedVisibleOwned") }
    if ($null -ne $ExpectedUnattributed -and $audit.unattributed_new_visible_windows -ne [int]$ExpectedUnattributed) { [void]$fixtureFailures.Add("unattributed_new_visible_windows=$($audit.unattributed_new_visible_windows), want $ExpectedUnattributed") }
    if ($null -ne $ExpectedWindowsTerminal -and $audit.windows_terminal_owned_visible -ne [int]$ExpectedWindowsTerminal) { [void]$fixtureFailures.Add("windows_terminal_owned_visible=$($audit.windows_terminal_owned_visible), want $ExpectedWindowsTerminal") }
    $fixturePass = $fixtureFailures.Count -eq 0
    if (-not $fixturePass) { [void]$failures.Add("visibility fixture '$Name' failed: $($fixtureFailures -join '; ')") }
    [void]$visibilityResults.Add([pscustomobject]@{ run_id = $RunId; name = $Name; pass = $fixturePass; failures = @($fixtureFailures); audit = $audit })
}

function Add-BindingFixture {
    param(
        [string]$Name, [AllowNull()]$Context, [AllowNull()][Nullable[int]]$ParentPid,
        [AllowNull()]$CoordinatorProcess, [bool]$ExpectedVerified,
        [AllowNull()]$RecordedAncestors = @(), [AllowNull()]$CurrentAncestors = @(),
        [AllowNull()][string]$ExpectedDiagnosticStatus = $null,
        [bool]$SupervisorRootAvailable = $true
    )
    $binding = Test-CoordinatorLaunchBinding -LaunchContext $Context -ExpectedRunId $RunId `
        -ExpectedRepositoryRoot $repoRoot -SupervisorParentPid $ParentPid `
        -CoordinatorProcess $CoordinatorProcess -SupervisorRootAvailable $SupervisorRootAvailable
    $diagnostics = @(Get-LaunchAncestorDiagnostics -RecordedAncestors $RecordedAncestors -CurrentProcesses $CurrentAncestors)
    $fixtureFailures = [Collections.Generic.List[string]]::new()
    if ($binding.supervisor_parent_binding_verified -ne $ExpectedVerified) { [void]$fixtureFailures.Add("verified=$($binding.supervisor_parent_binding_verified), want $ExpectedVerified") }
    if ($ExpectedDiagnosticStatus -and ($diagnostics.Count -ne 1 -or $diagnostics[0].status -ne $ExpectedDiagnosticStatus)) { [void]$fixtureFailures.Add("diagnostic status mismatch; want $ExpectedDiagnosticStatus") }
    $fixturePass = $fixtureFailures.Count -eq 0
    if (-not $fixturePass) { [void]$failures.Add("binding fixture '$Name' failed: $($fixtureFailures -join '; ')") }
    [void]$bindingResults.Add([pscustomobject]@{ run_id = $RunId; name = $Name; pass = $fixturePass; binding = $binding; parent_chain_diagnostics = $diagnostics; failures = @($fixtureFailures) })
}

$hashSetResults = [Collections.Generic.List[object]]::new()
foreach ($case in @(
    [pscustomobject]@{ name = 'null'; input = $null; count = 0 },
    [pscustomobject]@{ name = 'empty-array'; input = @(); count = 0 },
    [pscustomobject]@{ name = 'single'; input = @(1); count = 1 },
    [pscustomobject]@{ name = 'duplicates'; input = @(1, 1, 2); count = 2 }
)) {
    $set = ConvertTo-VisibilityIdSet $case.input
    $actualType = if ($null -eq $set) { $null } else { $set.GetType().FullName }
    $casePass = $null -ne $set -and $set -is [Collections.Generic.HashSet[int]] -and $set.Count -eq $case.count
    [void]$hashSetResults.Add([pscustomobject]@{ run_id = $RunId; name = $case.name; pass = $casePass; actual_type = $actualType; count = if ($null -eq $set) { $null } else { $set.Count } })
}
$emptySet = ConvertTo-VisibilityIdSet @()
$exceptSet = [Collections.Generic.HashSet[int]]::new()
[void]$exceptSet.Add(1)
[void]$exceptSet.Add(2)
$exceptFailure = $null
try { $exceptSet.ExceptWith($emptySet) } catch { $exceptFailure = $_.Exception.Message }
$exceptPass = $null -eq $exceptFailure -and $exceptSet.Count -eq 2 -and $exceptSet.Contains(1) -and $exceptSet.Contains(2)
[void]$hashSetResults.Add([pscustomobject]@{ run_id = $RunId; name = 'ExceptWith-empty'; pass = $exceptPass; failure = $exceptFailure })
$hashSetPass = @($hashSetResults | Where-Object { -not $_.pass }).Count -eq 0
if (-not $hashSetPass) { [void]$failures.Add('HashSet empty-input regression failed') }

Add-VisibilityFixture -Name 'owned WindowsTerminal visible fails' -ProbeReliable $true -Baseline @() -Observed @(200) -Owned @((New-FixtureProcess 200 'WindowsTerminal.exe' $true)) -Associated @() -SupervisorPid 100 -ExpectedStatus 'FAIL' -ExpectedPass $false -ExpectedVisibleOwned 1 -ExpectedWindowsTerminal 1
Add-VisibilityFixture -Name 'owned unknown visible fails' -ProbeReliable $true -Baseline @() -Observed @(201) -Owned @((New-FixtureProcess 201 'unknown-helper.exe' $true)) -Associated @() -SupervisorPid 100 -ExpectedStatus 'FAIL' -ExpectedPass $false -ExpectedVisibleOwned 1
Add-VisibilityFixture -Name 'visible supervisor root fails' -ProbeReliable $true -Baseline @() -Observed @(100) -Owned @((New-FixtureProcess 100 'pwsh.exe' $true 'supervisor-root')) -Associated @() -SupervisorPid 100 -ExpectedStatus 'FAIL' -ExpectedPass $false -ExpectedVisibleOwned 1
Add-VisibilityFixture -Name 'hidden owned conhost allowed' -ProbeReliable $true -Baseline @() -Observed @() -Owned @((New-FixtureProcess 202 'conhost.exe' $false)) -Associated @() -SupervisorPid 100 -ExpectedStatus 'PASS' -ExpectedPass $true -ExpectedVisibleOwned 0
Add-VisibilityFixture -Name 'owned PowerShell with no visible window allowed' -ProbeReliable $true -Baseline @() -Observed @() -Owned @((New-FixtureProcess 203 'powershell.exe' $false)) -Associated @() -SupervisorPid 100 -ExpectedStatus 'PASS' -ExpectedPass $true -ExpectedVisibleOwned 0
Add-VisibilityFixture -Name 'unrelated pre-existing WindowsTerminal ignored' -ProbeReliable $true -Baseline @(204) -Observed @(204) -Owned @() -Associated @() -SupervisorPid 100 -ExpectedStatus 'PASS' -ExpectedPass $true -ExpectedVisibleOwned 0 -ExpectedUnattributed 0 -ExpectedWindowsTerminal 0
Add-VisibilityFixture -Name 'new unattributed visible window is diagnostic only' -ProbeReliable $true -Baseline @() -Observed @(205) -Owned @() -Associated @() -SupervisorPid 100 -ExpectedStatus 'PASS' -ExpectedPass $true -ExpectedVisibleOwned 0 -ExpectedUnattributed 1
Add-VisibilityFixture -Name 'visibility probe exception blocks acceptance' -ProbeReliable $false -Baseline $null -Observed $null -Owned @() -Associated @() -SupervisorPid 100 -ExpectedStatus 'BLOCKED' -ExpectedPass $false -ExpectedVisibleOwned $null

$creation = '2026-09-03T00:00:00.0000000Z'
$baseContext = [pscustomobject]@{ run_id = $RunId; repository_root = $repoRoot; coordinator_pid = 2000; coordinator_creation_time = $creation; baseline_probe_reliable = $true; coordinator_visible_window_observed = $false }
$validCoordinator = New-FixtureProcess 2000 'pwsh.exe' $false 'coordinator' $creation
Add-BindingFixture -Name 'valid coordinator identity' -Context $baseContext -ParentPid 2000 -CoordinatorProcess $validCoordinator -ExpectedVerified $true
Add-BindingFixture -Name 'coordinator PID mismatch blocks' -Context $baseContext -ParentPid 2001 -CoordinatorProcess $validCoordinator -ExpectedVerified $false
Add-BindingFixture -Name 'coordinator creation-time mismatch blocks' -Context $baseContext -ParentPid 2000 -CoordinatorProcess (New-FixtureProcess 2000 'pwsh.exe' $false 'coordinator' '2026-09-03T00:00:01.0000000Z') -ExpectedVerified $false
Add-BindingFixture -Name 'immediate coordinator missing blocks' -Context $baseContext -ParentPid 2000 -CoordinatorProcess $null -ExpectedVerified $false
$ancestor = New-FixtureProcess 3000 'runner.exe' $false 'ancestor' $creation
Add-BindingFixture -Name 'grandparent missing is diagnostic only' -Context $baseContext -ParentPid 2000 -CoordinatorProcess $validCoordinator -ExpectedVerified $true -RecordedAncestors @($ancestor) -CurrentAncestors @() -ExpectedDiagnosticStatus 'TERMINATED_BEFORE_SAMPLE'
Add-BindingFixture -Name 'grandparent PID reuse is diagnostic only' -Context $baseContext -ParentPid 2000 -CoordinatorProcess $validCoordinator -ExpectedVerified $true -RecordedAncestors @($ancestor) -CurrentAncestors @((New-FixtureProcess 3000 'other.exe' $false 'ancestor' '2026-09-03T00:00:02.0000000Z')) -ExpectedDiagnosticStatus 'PID_REUSED_OR_IDENTITY_MISMATCH'
$visibleContext = $baseContext.PSObject.Copy(); $visibleContext.coordinator_visible_window_observed = $true
Add-BindingFixture -Name 'visible coordinator blocks' -Context $visibleContext -ParentPid 2000 -CoordinatorProcess $validCoordinator -ExpectedVerified $false
Add-BindingFixture -Name 'supervisor immediate parent exact match verifies' -Context $baseContext -ParentPid 2000 -CoordinatorProcess $validCoordinator -ExpectedVerified $true

$finishedAt = [DateTimeOffset]::UtcNow
$visibilityPass = @($visibilityResults | Where-Object { -not $_.pass }).Count -eq 0
$bindingPass = @($bindingResults | Where-Object { -not $_.pass }).Count -eq 0
$deadlinePass = ($finishedAt - $startedAt).TotalSeconds -le $DeadlineSeconds
if (-not $deadlinePass) { [void]$failures.Add("offline fixtures exceeded ${DeadlineSeconds}s") }
$hashSummary = [ordered]@{ run_id = $RunId; test = 'Visibility HashSet regressions'; status = if ($hashSetPass) { 'PASS' } else { 'FAIL' }; pass = $hashSetPass; case_count = $hashSetResults.Count; case_passed = @($hashSetResults | Where-Object pass).Count; cases = $hashSetResults }
$visibilitySummary = [ordered]@{ run_id = $RunId; test = 'Windows visibility offline fixtures'; status = if ($visibilityPass) { 'PASS' } else { 'FAIL' }; pass = $visibilityPass; fixture_count = $visibilityResults.Count; fixture_passed = @($visibilityResults | Where-Object pass).Count; fixtures = $visibilityResults }
$bindingSummary = [ordered]@{ run_id = $RunId; test = 'Coordinator binding offline fixtures'; status = if ($bindingPass) { 'PASS' } else { 'FAIL' }; pass = $bindingPass; fixture_count = $bindingResults.Count; fixture_passed = @($bindingResults | Where-Object pass).Count; fixtures = $bindingResults }
$resultPass = $hashSetPass -and $visibilityPass -and $bindingPass -and $deadlinePass
$result = [ordered]@{ run_id = $RunId; test = 'Windows background process hardening offline self-test'; status = if ($resultPass) { 'PASS' } else { 'FAIL' }; pass = $resultPass; started_at = $startedAt.ToString('o'); finished_at = $finishedAt.ToString('o'); duration_ms = [int64][math]::Round(($finishedAt - $startedAt).TotalMilliseconds); hashset_pass = $hashSetPass; fixture_count = $visibilityResults.Count; fixture_passed = @($visibilityResults | Where-Object pass).Count; binding_fixture_count = $bindingResults.Count; binding_fixture_passed = @($bindingResults | Where-Object pass).Count; failures = @($failures) }
Write-SelfTestJson 'hashset-regression-summary.json' $hashSummary
Write-SelfTestJson 'offline-visibility-fixture-summary.json' $visibilitySummary
Write-SelfTestJson 'coordinator-binding-fixture-summary.json' $bindingSummary
Write-SelfTestJson 'offline-self-test-summary.json' $result
$result | ConvertTo-Json -Depth 8
if (-not $result.pass) { throw 'offline hardening self-test failed' }
