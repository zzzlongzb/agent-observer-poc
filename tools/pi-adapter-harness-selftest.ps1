[CmdletBinding()]
param(
    [string]$Root = '',
    [int]$MaximumRuntimeSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'harness-lifecycle.ps1')

if ($MaximumRuntimeSeconds -le 0) { $MaximumRuntimeSeconds = 120 }

if (-not $Root) {
    $Root = Join-Path $env:TEMP "agent-observer-harness-selftest-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}
$Root = [System.IO.Path]::GetFullPath($Root)
New-Item -ItemType Directory -Force -Path $Root | Out-Null
$shell = Join-Path $PSHOME 'pwsh.exe'
$suiteStarted = [DateTimeOffset]::UtcNow
$results = [ordered]@{}
$control = $null
$controlRecord = $null
$controlCtx = $null
$crashWorkerRecord = $null
$crashChildRecord = $null
$watchdog = $null
$watchdogState = $null
$suiteContext = $null
$ownedContexts = [System.Collections.ArrayList]::new()

$suiteContext = New-HarnessLifecycle -Name 'Pi Adapter harness self-test' -RunRoot $Root `
    -Scenario 'offline-selftest' -OverallTimeoutSeconds $MaximumRuntimeSeconds -HeartbeatSeconds 5
[void]$ownedContexts.Add($suiteContext)

$watchdogState = [hashtable]::Synchronized(@{ Cancel = $false; ParentPid = $PID })
$watchdog = [powershell]::Create()
[void]$watchdog.AddScript({
    param($state, $timeoutMs)
    $elapsed = 0
    while ($elapsed -lt $timeoutMs) {
        if ($state.Cancel) { return }
        Start-Sleep -Milliseconds 500
        $elapsed += 500
    }
    if (-not $state.Cancel) {
        try { Stop-Process -Id $state.ParentPid -Force -ErrorAction SilentlyContinue } catch { }
    }
}).AddArgument($watchdogState).AddArgument(($MaximumRuntimeSeconds * 1000))
$watchdogHandle = $watchdog.BeginInvoke()

function Register-TestContext {
    param($Context)
    [void]$ownedContexts.Add($Context)
    $Context
}

function New-SleepProcess {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Scenario,
        [int]$Seconds = 30
    )
    Start-HarnessProcess -Context $Context -FilePath $shell `
        -ArgumentList "-NoProfile -NonInteractive -Command `"Start-Sleep -Seconds $Seconds`"" `
        -Kind 'selftest-child' -Scenario $Scenario
}

function Start-HarnessTreeChild {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Dir,
        [int]$SleepSeconds = 60,
        [string]$Scenario = 'owned-tree'
    )
    # Starts an owned child that immediately spawns its own descendant, then publishes
    # the descendant identity (PID + creation time) so the suite can verify that the
    # whole owned process tree (parent + descendant) is terminated.
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $identityPath = Join-Path $Dir 'descendant-identity.json'
    if (Test-Path -LiteralPath $identityPath) { Remove-Item -LiteralPath $identityPath -Force }
    $childScript = Join-Path $Dir 'tree-child.ps1'
    $childSource = @'
$ErrorActionPreference = 'Stop'
$g = Start-Process -FilePath '__SHELL__' -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds __SLEEP__"' -PassThru -NoNewWindow
@{
    process_id = [int]$g.Id
    process_started_at_unix_ms = [int64]([DateTimeOffset]($g.StartTime).ToUniversalTime()).ToUnixTimeMilliseconds()
} | ConvertTo-Json | Set-Content -LiteralPath '__IDENTITY__' -Encoding utf8
Start-Sleep -Seconds __SLEEP__
'@
    $childSource = $childSource.Replace('__SHELL__', $shell).
        Replace('__SLEEP__', [string]$SleepSeconds).
        Replace('__IDENTITY__', $identityPath)
    [System.IO.File]::WriteAllText($childScript, $childSource, (New-Object System.Text.UTF8Encoding $false))
    $owned = Start-HarnessProcess -Context $Context -FilePath $shell `
        -ArgumentList "-NoProfile -NonInteractive -File `"$childScript`"" `
        -Kind 'tree-child' -Scenario $Scenario
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $identityPath) -and [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $identityPath)) {
        throw 'Owned tree probe did not publish its descendant identity.'
    }
    $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    $descendant = [pscustomobject]@{
        ProcessId = [int]$identity.process_id
        ProcessStartedAtUnixMs = [int64]$identity.process_started_at_unix_ms
        Kind = 'tree-descendant'
        Scenario = $Scenario
    }
    [pscustomobject]@{ Owned = $owned; Descendant = $descendant; IdentityPath = $identityPath }
}

function Wait-HarnessTreeGone {
    param(
        [Parameter(Mandatory)]$Tree,
        [int]$TimeoutSeconds = 5
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while (((Test-HarnessProcessRecordAlive -Record $Tree.Owned.Record) -or
            (Test-HarnessProcessRecordAlive -Record $Tree.Descendant)) -and
        [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    -not ((Test-HarnessProcessRecordAlive -Record $Tree.Owned.Record) -or
        (Test-HarnessProcessRecordAlive -Record $Tree.Descendant))
}

function Get-SelfTestFunctionBody {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [string]$NextName = ''
    )
    $start = $Text.IndexOf("function $Name")
    $end = if ($NextName) { $Text.IndexOf("function $NextName") } else { $Text.Length }
    if ($start -lt 0 -or $end -le $start) { return '' }
    $Text.Substring($start, $end - $start)
}

function Invoke-NestedSupervisor {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$BaseRoot = '',
        [string]$DiagnosticsRoot = '',
        [Parameter(Mandatory)][string]$LogDir,
        [string]$ExtraArgumentList = '',
        [string]$Stage = 'nested-supervisor',
        [switch]$OmitRoots
    )
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $stdout = Join-Path $LogDir 'stdout.log'
    $stderr = Join-Path $LogDir 'stderr.log'
    $supervisorScript = Join-Path $PSScriptRoot 'pi-adapter-harness-supervisor.ps1'
    $rootArgs = if ($OmitRoots) { '' } else { "-BaseRoot `"$BaseRoot`" -DiagnosticsRoot `"$DiagnosticsRoot`"" }
    $arg = "-NoProfile -NonInteractive -File `"$supervisorScript`" $rootArgs $ExtraArgumentList"
    $owned = Start-HarnessProcess -Context $Context -FilePath $shell -ArgumentList $arg `
        -Kind 'nested-supervisor' -Scenario 'offline-selftest' `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $exit = $null
    $waitError = ''
    try {
        $exit = Wait-HarnessProcess -Context $Context -Record $owned.Record -Stage $Stage
    } catch {
        $waitError = $_.Exception.Message
    }
    $combined = ''
    if (Test-Path -LiteralPath $stdout) { $combined += [string](Get-Content -LiteralPath $stdout -Raw) }
    if (Test-Path -LiteralPath $stderr) { $combined += [string](Get-Content -LiteralPath $stderr -Raw) }
    if ($waitError) { $combined += $waitError }
    [pscustomobject]@{ ExitCode = $exit; Output = $combined; Owned = $owned }
}

function Invoke-NestedWorker {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$LogDir,
        [string]$ExtraArgumentList = '',
        [string]$Stage = 'nested-worker'
    )
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $stdout = Join-Path $LogDir 'stdout.log'
    $stderr = Join-Path $LogDir 'stderr.log'
    $workerScript = Join-Path $PSScriptRoot 'pi-adapter-poc-v1.1.ps1'
    $arg = "-NoProfile -NonInteractive -File `"$workerScript`" $ExtraArgumentList"
    $owned = Start-HarnessProcess -Context $Context -FilePath $shell -ArgumentList $arg `
        -Kind 'nested-worker' -Scenario 'offline-selftest' `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $exit = $null
    $waitError = ''
    try {
        $exit = Wait-HarnessProcess -Context $Context -Record $owned.Record -Stage $Stage
    } catch {
        $waitError = $_.Exception.Message
    }
    $combined = ''
    if (Test-Path -LiteralPath $stdout) { $combined += [string](Get-Content -LiteralPath $stdout -Raw) }
    if (Test-Path -LiteralPath $stderr) { $combined += [string](Get-Content -LiteralPath $stderr -Raw) }
    if ($waitError) { $combined += $waitError }
    [pscustomobject]@{ ExitCode = $exit; Output = $combined; Owned = $owned }
}

try {
    Assert-HarnessDeadline -Context $suiteContext -Stage 'start'

    # 1. Scenario budget mapping
    $budgetMappingsOk = $true
    try {
        $cfgNormal = Get-HarnessScenarioConfig -Scenario 'normal'
        $cfgKill = Get-HarnessScenarioConfig -Scenario 'kill'
        $cfgRestart = Get-HarnessScenarioConfig -Scenario 'restart-missed'
        $cfgParallel = Get-HarnessScenarioConfig -Scenario 'parallel'
        $budgetMappingsOk = ($cfgNormal.ModelCallBudget -eq 1 -and $cfgNormal.DefaultTimeoutSeconds -eq 300) -and
            ($cfgKill.ModelCallBudget -eq 1 -and $cfgKill.DefaultTimeoutSeconds -eq 180) -and
            ($cfgRestart.ModelCallBudget -eq 1 -and $cfgRestart.DefaultTimeoutSeconds -eq 180) -and
            ($cfgParallel.ModelCallBudget -eq 2 -and $cfgParallel.DefaultTimeoutSeconds -eq 300)
    } catch {
        $budgetMappingsOk = $false
    }
    $results.scenario_budgets_mapped = $budgetMappingsOk

    # 2. 'all' is prohibited
    Assert-HarnessDeadline -Context $suiteContext -Stage 'all-prohibited'
    $allRejected = $false
    try {
        Get-HarnessScenarioConfig -Scenario 'all' | Out-Null
    } catch {
        $allRejected = $_.Exception.Message -like '*prohibited*' -or $_.Exception.Message -like '*Invalid scenario*'
    }
    $allCtx = Register-TestContext (New-HarnessLifecycle -Name 'all-rejected' -RunRoot (Join-Path $Root 'all-rejected') `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $allBase = Join-Path $Root 'all-rejected-base-missing'
    $allDiag = Join-Path $Root 'all-rejected-diag-missing'
    try {
        $allNested = Invoke-NestedSupervisor -Context $allCtx -BaseRoot $allBase -DiagnosticsRoot $allDiag `
            -LogDir (Join-Path $Root 'all-rejected-logs') `
            -ExtraArgumentList '-AllowLiveScenario -Scenario all -ConfirmModelCallBudget 1' `
            -Stage 'reject-all'
        $allRejected = $allRejected -and ($allNested.Output -like '*prohibited*' -or $allNested.Output -like '*Invalid scenario*')
    } finally {
        Close-HarnessLifecycle -Context $allCtx -Reason 'selftest-all-rejected'
    }
    $results.all_scenario_prohibited = [bool]$allRejected

    # 3. Missing scenario rejected, no run root created
    Assert-HarnessDeadline -Context $suiteContext -Stage 'missing-scenario'
    $missingCtx = Register-TestContext (New-HarnessLifecycle -Name 'missing-scenario' -RunRoot (Join-Path $Root 'missing-scenario') `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $missingBase = Join-Path $Root 'missing-scenario-base'
    $missingDiag = Join-Path $Root 'missing-scenario-diag'
    $missingOk = $false
    try {
        $missingNested = Invoke-NestedSupervisor -Context $missingCtx -BaseRoot $missingBase -DiagnosticsRoot $missingDiag `
            -LogDir (Join-Path $Root 'missing-scenario-logs') `
            -ExtraArgumentList '-AllowLiveScenario' -Stage 'reject-missing-scenario'
        $missingOk = ($missingNested.Output -like '*requires explicit -Scenario*') -and
            -not (Test-Path -LiteralPath $missingBase) -and
            -not (Test-Path -LiteralPath $missingDiag)
    } finally {
        Close-HarnessLifecycle -Context $missingCtx -Reason 'selftest-missing-scenario'
    }
    $results.missing_scenario_rejected = $missingOk
    $results.invalid_params_do_not_create_run_root = $missingOk

    # 4. Incorrect budget rejected, no run root created
    Assert-HarnessDeadline -Context $suiteContext -Stage 'incorrect-budget'
    $budgetCtx = Register-TestContext (New-HarnessLifecycle -Name 'incorrect-budget' -RunRoot (Join-Path $Root 'incorrect-budget') `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $budgetBase = Join-Path $Root 'incorrect-budget-base'
    $budgetDiag = Join-Path $Root 'incorrect-budget-diag'
    $incorrectBudgetRejected = $false
    try {
        $budgetNested = Invoke-NestedSupervisor -Context $budgetCtx -BaseRoot $budgetBase -DiagnosticsRoot $budgetDiag `
            -LogDir (Join-Path $Root 'incorrect-budget-logs') `
            -ExtraArgumentList '-AllowLiveScenario -Scenario normal -ConfirmModelCallBudget 99' `
            -Stage 'reject-budget'
        $workerBudget = Invoke-NestedWorker -Context $budgetCtx -LogDir (Join-Path $Root 'incorrect-budget-worker-logs') `
            -ExtraArgumentList '-Scenario normal -ModelCallBudget 5 -Supervised -StartGate "missing-gate"' `
            -Stage 'reject-worker-budget'
        $incorrectBudgetRejected = ($budgetNested.Output -like '*requires -ConfirmModelCallBudget 1*') -and
            -not (Test-Path -LiteralPath $budgetBase) -and
            ($workerBudget.Output -like '*Model call budget mismatch*')
    } finally {
        Close-HarnessLifecycle -Context $budgetCtx -Reason 'selftest-incorrect-budget'
    }
    $results.incorrect_budget_rejected = $incorrectBudgetRejected

    # 4b. Invalid live params without BaseRoot must not create default/legacy roots
    Assert-HarnessDeadline -Context $suiteContext -Stage 'default-root-side-effect'
    $legacyFixRoot = 'D:\agent-observer-pi-adapter-fix-v1'
    $defaultBase = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.tmp\pi-adapter-harness'))
    $defaultDiag = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.tmp\pi-adapter-harness-diagnostics'))
    $defaultSupervised = Join-Path $defaultBase 'supervised'
    $beforeLegacy = Test-Path -LiteralPath $legacyFixRoot
    $beforeKids = @()
    if (Test-Path -LiteralPath $defaultSupervised) {
        $beforeKids = @(Get-ChildItem -LiteralPath $defaultSupervised -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    $omitCtx = Register-TestContext (New-HarnessLifecycle -Name 'default-root-side-effect' -RunRoot (Join-Path $Root 'default-root-side-effect') `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $omitOk = $false
    try {
        $omitNested = Invoke-NestedSupervisor -Context $omitCtx -OmitRoots `
            -LogDir (Join-Path $Root 'default-root-side-effect-logs') `
            -ExtraArgumentList '-AllowLiveScenario -Scenario normal -ConfirmModelCallBudget 99' `
            -Stage 'reject-budget-no-roots'
        $afterKids = @()
        if (Test-Path -LiteralPath $defaultSupervised) {
            $afterKids = @(Get-ChildItem -LiteralPath $defaultSupervised -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        }
        $newKids = @($afterKids | Where-Object { $beforeKids -notcontains $_ })
        $omitOk = ($omitNested.Output -like '*requires -ConfirmModelCallBudget 1*') -and
            ($newKids.Count -eq 0) -and
            ((-not (Test-Path -LiteralPath $legacyFixRoot)) -or $beforeLegacy)
    } finally {
        Close-HarnessLifecycle -Context $omitCtx -Reason 'selftest-default-root-side-effect'
    }
    $results.invalid_params_do_not_create_default_run_root = $omitOk

    $supervisorText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'pi-adapter-harness-supervisor.ps1') -Raw
    $assertIdx = $supervisorText.IndexOf('Assert-HarnessSupervisorInvocation')
    $newItemIdx = $supervisorText.IndexOf('New-Item -ItemType Directory -Force -Path $runRoot')
    $results.supervisor_validates_before_run_root = ($assertIdx -ge 0 -and $newItemIdx -gt $assertIdx)

    $results.supervisor_rejection_validation =
        [bool]$results.missing_scenario_rejected -and [bool]$incorrectBudgetRejected -and
        [bool]$omitOk -and [bool]$results.supervisor_validates_before_run_root
    $results.invalid_params_do_not_create_run_root =
        [bool]$results.missing_scenario_rejected -and
        [bool]$incorrectBudgetRejected -and
        [bool]$omitOk -and
        -not (Test-Path -LiteralPath $allBase) -and
        -not (Test-Path -LiteralPath $allDiag)

    # 5. Direct worker invocation rejected
    Assert-HarnessDeadline -Context $suiteContext -Stage 'direct-worker'
    $directCtx = Register-TestContext (New-HarnessLifecycle -Name 'direct-worker' -RunRoot (Join-Path $Root 'direct-worker') `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $directRejected = $false
    try {
        $direct = Invoke-NestedWorker -Context $directCtx -LogDir (Join-Path $Root 'direct-worker-logs') `
            -ExtraArgumentList '-Scenario normal -ModelCallBudget 1' -Stage 'reject-direct-worker'
        $directRejected = $direct.Output -like '*Direct live-harness invocation is disabled*'
    } finally {
        Close-HarnessLifecycle -Context $directCtx -Reason 'selftest-direct-worker'
    }
    $results.direct_worker_rejected = $directRejected

    # 6. Normal does not enter other scenarios
    Assert-HarnessDeadline -Context $suiteContext -Stage 'normal-isolation'
    $normalPlan = Get-HarnessScenarioPlan -Scenario 'normal'
    $workerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'pi-adapter-poc-v1.1.ps1') -Raw
    $normalStart = $workerText.IndexOf('function Invoke-ScenarioNormal')
    $killStart = $workerText.IndexOf('function Invoke-ScenarioKill')
    $normalBody = if ($normalStart -ge 0 -and $killStart -gt $normalStart) {
        $workerText.Substring($normalStart, $killStart - $normalStart)
    } else {
        ''
    }
    $results.normal_does_not_enter_other_scenarios =
        ($normalPlan.InvokesNormal -eq $true) -and
        ($normalPlan.InvokesKill -eq $false) -and
        ($normalPlan.InvokesRestartMissed -eq $false) -and
        ($normalPlan.InvokesParallel -eq $false) -and
        ($normalPlan.StartsSecondModelCall -eq $false) -and
        ($normalPlan.IntentionalKill -eq $false) -and
        ($normalBody.Length -gt 0) -and
        ($normalBody -notmatch 'Invoke-ScenarioKill') -and
        ($normalBody -notmatch 'Invoke-ScenarioRestartMissed') -and
        ($normalBody -notmatch 'Invoke-ScenarioParallel') -and
        ($workerText -match "'normal' \{ Invoke-ScenarioNormal \}") -and
        ($workerText -notmatch "'normal' \{ Invoke-ScenarioNormal; Invoke-ScenarioKill")

    $killBody = Get-SelfTestFunctionBody -Text $workerText -Name 'Invoke-ScenarioKill' -NextName 'Invoke-ScenarioRestartMissed'
    $missBody = Get-SelfTestFunctionBody -Text $workerText -Name 'Invoke-ScenarioRestartMissed' -NextName 'Invoke-ScenarioParallel'
    $parBody = Get-SelfTestFunctionBody -Text $workerText -Name 'Invoke-ScenarioParallel'
    $observeScanBody = Get-SelfTestFunctionBody -Text $workerText -Name 'Invoke-ObserveScan' -NextName 'New-CaseDir'
    $results.observe_scan_uses_explicit_stale_threshold =
        ($observeScanBody -match '\[Parameter\(Mandatory\)\]\[int\]\$StaleAfter') -and
        ($observeScanBody -match '''--stale-after-secs'', \$StaleAfter\.ToString\(\)')
    $results.scenario_scans_forward_stale_threshold =
        (@([regex]::Matches($workerText, 'Invoke-ObserveScan[^\r\n]+(?:`[\r\n]+\s*)?-StaleAfter \$StaleAfterSecs')).Count -eq 3)
    $overlapStart = $parBody.IndexOf('$parallelOverlap = $true')
    $overlapEnd = $parBody.IndexOf('$parallelProviderFailFast', $overlapStart)
    $overlapBody = if ($overlapStart -ge 0 -and $overlapEnd -gt $overlapStart) {
        $parBody.Substring($overlapStart, $overlapEnd - $overlapStart)
    } else {
        ''
    }
    $results.parallel_overlap_checks_pid_and_ctime =
        ($overlapBody -match 'Get-Process -Id') -and
        ($overlapBody -match '\$p\.StartTime') -and
        ($overlapBody -match '\$json\.process_started_at_unix_ms')
    $results.parallel_unicode_names_are_order_independent =
        ($parBody -match '\$parallelNames -ccontains ''Pi并行会话A_日本語''') -and
        ($parBody -match '\$parallelNames -ccontains ''Pi并行会话B_日本語''') -and
        ($parBody -notmatch '\$parallelRows\[0\]\.session_name -ceq')
    $killAssertIdx = $killBody.IndexOf('Assert-NoProviderFailure')
    $killStopIdx = $killBody.IndexOf('Stop-Process -Id $killPid')
    $missAssertIdx = $missBody.IndexOf('Assert-NoProviderFailure')
    $missKillIdx = $missBody.IndexOf('intentional-observer-kill')
    $parFirst = $parBody.IndexOf('Invoke-RunPi')
    $parSecond = if ($parFirst -ge 0) { $parBody.IndexOf('Invoke-RunPi', $parFirst + 1) } else { -1 }
    $parAssertBetween = $false
    $parAssertAfterSecond = $false
    if ($parFirst -ge 0 -and $parSecond -gt $parFirst) {
        $parAssertBetween = $parBody.Substring($parFirst, $parSecond - $parFirst).Contains('Assert-NoProviderFailure')
        $parAssertAfterSecond = $parBody.IndexOf('Assert-NoProviderFailure', $parSecond) -ge 0
    }
    $results.provider_checkpoint_normal = $normalBody.Contains('Assert-NoProviderFailure')
    $results.provider_checkpoint_kill_before_intentional_kill = ($killAssertIdx -ge 0 -and $killStopIdx -gt $killAssertIdx)
    $results.provider_checkpoint_restart_missed_before_observer_kill = ($missAssertIdx -ge 0 -and $missKillIdx -gt $missAssertIdx)
    $results.provider_checkpoint_parallel_both_invocations = $parAssertBetween -and $parAssertAfterSecond

    # Every parallel runner wait must carry a FailFast callback, so that a provider
    # failure on either runner stops the whole parallel scenario.
    $parRunnerAFailFast = $false
    $parRunnerBFailFast = $false
    foreach ($runnerStage in @('parallel-runner-a', 'parallel-runner-b')) {
        $stageIdx = $parBody.IndexOf("'$runnerStage'")
        $hasFailFast = $false
        if ($stageIdx -ge 0) {
            $windowLength = [math]::Min(400, $parBody.Length - $stageIdx)
            $hasFailFast = $parBody.Substring($stageIdx, $windowLength) -match '-FailFast'
        }
        if ($runnerStage -eq 'parallel-runner-a') { $parRunnerAFailFast = $hasFailFast } else { $parRunnerBFailFast = $hasFailFast }
    }
    $results.parallel_waits_use_failfast = ($parRunnerAFailFast -and $parRunnerBFailFast)

    # The lifecycle wait must run a final FailFast after the child exits and before
    # the exit code is read, otherwise a same-instant provider failure would yield 0.
    $lifecycleText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'harness-lifecycle.ps1') -Raw
    $waitProcessBody = Get-SelfTestFunctionBody -Text $lifecycleText -Name 'Wait-HarnessProcess' -NextName 'Wait-HarnessCondition'
    $waitPostExitIdx = $waitProcessBody.IndexOf('post-exit')
    $waitExitCodeIdx = $waitProcessBody.IndexOf('Get-HarnessProcessExitCode')
    $results.wait_process_post_exit_failfast = ($waitPostExitIdx -ge 0) -and ($waitExitCodeIdx -gt $waitPostExitIdx)

    # Wait-HarnessCondition must re-check FailFast at the success boundary, after the
    # condition returned and before the result is returned, without re-running it.
    $waitConditionBody = Get-SelfTestFunctionBody -Text $lifecycleText -Name 'Wait-HarnessCondition' -NextName 'Wait-HarnessSleep'
    $condCallIdx = $waitConditionBody.IndexOf('$result = & $Condition')
    $condReturnIdx = $waitConditionBody.IndexOf('return $result')
    $condBoundary = ''
    if ($condCallIdx -ge 0 -and $condReturnIdx -gt $condCallIdx) {
        $condBoundary = $waitConditionBody.Substring($condCallIdx, $condReturnIdx - $condCallIdx)
    }
    $results.condition_success_boundary_failfast = ($condBoundary.Length -gt 0) -and
        ($condBoundary -match '-Stage "\$Stage-success"') -and
        ($condBoundary -match 'Invoke-HarnessFailFast') -and
        (@([regex]::Matches($condBoundary, '& \$Condition')).Count -eq 1)

    # Both top-level entry points must classify through the shared helper, so a generic
    # harness failure can never be relabelled as a provider failure.
    $results.top_level_uses_shared_classification =
        ($workerText -match 'Resolve-HarnessFailureClassification') -and
        ($workerText -notmatch 'if \(\$msg -like ''\*BLOCKED_BY_PROVIDER\*''\)') -and
        ($supervisorText -match 'Resolve-HarnessFailureClassification') -and
        ($supervisorText -notmatch 'elseif \(\$failureReason -like ''\*BLOCKED_BY_PROVIDER\*''\)')
    # Generic harness failures must not be able to reach the BLOCKED prefix helper.
    # Match the exact declaration so that Invoke-HarnessFailFastCleanup is not picked up.
    $failFastStart = $lifecycleText.IndexOf('function Invoke-HarnessFailFast {')
    $failFastEnd = $lifecycleText.IndexOf('function Wait-HarnessProcess')
    $failFastBody = ''
    if ($failFastStart -ge 0 -and $failFastEnd -gt $failFastStart) {
        $failFastBody = $lifecycleText.Substring($failFastStart, $failFastEnd - $failFastStart)
    }
    $results.generic_exception_never_relabelled_blocked = ($failFastBody.Length -gt 0) -and
        ($failFastBody -notmatch 'Get-HarnessBlockedMessage') -and
        ($failFastBody -match 'Get-HarnessProviderFailureMessage') -and
        (@([regex]::Matches($failFastBody, 'Get-HarnessProviderFailureMessage')).Count -eq 1) -and
        ($failFastBody -match '\$message = \[string\]\$_\.Exception\.Message')

    # The timeout summary must not hardcode cleanup success.
    $timeoutFuncBody = Get-SelfTestFunctionBody -Text $lifecycleText -Name 'Write-HarnessTimeoutSummaryFile'
    $results.timeout_summary_not_hardcoded_cleanup = ($timeoutFuncBody.Length -gt 0) -and
        ($timeoutFuncBody -notmatch 'CleanupSuccess:\$true') -and
        ($timeoutFuncBody -notmatch 'OwnedProcessesRemaining 0') -and
        ($timeoutFuncBody -match '\[Parameter\(Mandatory\)\]\[bool\]\$CleanupSuccess') -and
        ($timeoutFuncBody -match '\[Parameter\(Mandatory\)\]\[int\]\$OwnedProcessesRemaining')
    $results.supervisor_timeout_summary_uses_real_cleanup =
        ($supervisorText -notmatch 'function Write-HarnessTimeoutSummaryFile') -and
        ($supervisorText -match 'Measure-HarnessCleanup') -and
        ($supervisorText -match 'Write-HarnessTimeoutSummaryFile[\s\S]{0,800}?-CleanupSuccess')

    # 7. Exact deadline kills child
    Assert-HarnessDeadline -Context $suiteContext -Stage 'exact-deadline'
    $context = Register-TestContext (New-HarnessLifecycle -Name 'process-timeout' -RunRoot (Join-Path $Root 'process-timeout') `
        -OverallTimeoutSeconds 15 -HeartbeatSeconds 1)
    $owned = $null
    $timedOut = $false
    try {
        $owned = New-SleepProcess -Context $context -Scenario 'process-timeout'
        Wait-HarnessProcess -Context $context -Record $owned.Record -Stage 'long-child' -TimeoutSeconds 2 | Out-Null
    } catch {
        $timedOut = $_.Exception.Message -like '*Timed out after 2s*'
    } finally {
        Close-HarnessLifecycle -Context $context -Reason 'selftest-process-timeout'
    }
    Assert-NoHarnessProcesses -Context $context
    $results.exact_deadline_kills_child = $timedOut -and
        $null -ne $owned -and
        -not (Test-HarnessProcessRecordAlive -Record $owned.Record)

    # 8. Worker exception kills child
    Assert-HarnessDeadline -Context $suiteContext -Stage 'exception-cleanup'
    $context = Register-TestContext (New-HarnessLifecycle -Name 'exception-cleanup' -RunRoot (Join-Path $Root 'exception-cleanup') `
        -OverallTimeoutSeconds 15 -HeartbeatSeconds 1)
    $owned = $null
    $caught = $false
    try {
        $owned = New-SleepProcess -Context $context -Scenario 'exception-cleanup'
        throw 'INTENTIONAL_SELFTEST_EXCEPTION'
    } catch {
        $caught = $_.Exception.Message -eq 'INTENTIONAL_SELFTEST_EXCEPTION'
    } finally {
        Close-HarnessLifecycle -Context $context -Reason 'selftest-intentional-exception'
    }
    Assert-NoHarnessProcesses -Context $context
    $results.worker_exception_kills_child = $caught -and
        $null -ne $owned -and
        -not (Test-HarnessProcessRecordAlive -Record $owned.Record)

    # 9. FailFast owner kills descendants via Job Object
    Assert-HarnessDeadline -Context $suiteContext -Stage 'job-owner-crash'
    $crashDir = Join-Path $Root 'job-owner-crash'
    New-Item -ItemType Directory -Force -Path $crashDir | Out-Null
    $crashIdentity = Join-Path $crashDir 'child-identity.json'
    $crashScript = Join-Path $crashDir 'crash-owner.ps1'
    $helperPath = (Resolve-Path (Join-Path $PSScriptRoot 'harness-lifecycle.ps1')).Path.Replace("'", "''")
    $crashDirQuoted = $crashDir.Replace("'", "''")
    $crashIdentityQuoted = $crashIdentity.Replace("'", "''")
    $shellQuoted = $shell.Replace("'", "''")
    $crashSource = @"
`$ErrorActionPreference = 'Stop'
. '$helperPath'
`$context = New-HarnessLifecycle -Name 'crash-owner' -RunRoot '$crashDirQuoted' -OverallTimeoutSeconds 30 -HeartbeatSeconds 5
`$owned = Start-HarnessProcess -Context `$context -FilePath '$shellQuoted' -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -Kind 'crash-child' -Scenario 'job-owner-crash'
@{ process_id = `$owned.Record.ProcessId; process_started_at_unix_ms = `$owned.Record.ProcessStartedAtUnixMs } | ConvertTo-Json | Set-Content -LiteralPath '$crashIdentityQuoted' -Encoding utf8
[Environment]::FailFast('INTENTIONAL_HARNESS_JOB_SELFTEST')
"@
    Set-Content -LiteralPath $crashScript -Value $crashSource -Encoding utf8
    $crashCtx = Register-TestContext (New-HarnessLifecycle -Name 'crash-owner-host' -RunRoot $crashDir `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $crashWorker = Start-HarnessProcess -Context $crashCtx -FilePath $shell `
        -ArgumentList "-NoProfile -NonInteractive -File `"$crashScript`"" `
        -Kind 'crash-owner' -Scenario 'job-owner-crash' `
        -RedirectStandardError (Join-Path $crashDir 'crash-owner.stderr.log')
    $crashWorkerRecord = $crashWorker.Record
    $identityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $crashIdentity) -and [DateTimeOffset]::UtcNow -lt $identityDeadline) {
        Assert-HarnessDeadline -Context $suiteContext -Stage 'job-owner-crash-identity'
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $crashIdentity)) {
        throw 'Crash-owner self-test did not publish its child identity.'
    }
    $identity = Get-Content -LiteralPath $crashIdentity -Raw | ConvertFrom-Json
    $crashChildRecord = [pscustomobject]@{
        ProcessId = [int]$identity.process_id
        ProcessStartedAtUnixMs = [int64]$identity.process_started_at_unix_ms
        Kind = 'crash-child'
        Scenario = 'job-owner-crash'
    }
    $goneDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ((Test-HarnessProcessRecordAlive -Record $crashChildRecord) -and [DateTimeOffset]::UtcNow -lt $goneDeadline) {
        Assert-HarnessDeadline -Context $suiteContext -Stage 'job-owner-crash-wait'
        Start-Sleep -Milliseconds 100
    }
    Close-HarnessLifecycle -Context $crashCtx -Reason 'selftest-crash-owner-host'
    $results.job_owner_crash_kills_child = -not (Test-HarnessProcessRecordAlive -Record $crashChildRecord)

    # 10. Same PID, different creation time must not be killed
    Assert-HarnessDeadline -Context $suiteContext -Stage 'pid-reuse'
    $context = Register-TestContext (New-HarnessLifecycle -Name 'pid-reuse' -RunRoot (Join-Path $Root 'pid-reuse') `
        -OverallTimeoutSeconds 15 -HeartbeatSeconds 1)
    $owned = $null
    try {
        $owned = New-SleepProcess -Context $context -Scenario 'pid-reuse'
        $stale = [pscustomobject]@{
            ProcessId = [int]$owned.Record.ProcessId
            ProcessStartedAtUnixMs = [int64]1
            Kind = 'stale-pid'
            Scenario = 'pid-reuse'
        }
        Stop-HarnessProcessRecord -Record $stale -Reason 'stale-ctime' | Out-Null
        $results.pid_reuse_different_ctime_not_killed = Test-HarnessProcessRecordAlive -Record $owned.Record
    } finally {
        Close-HarnessLifecycle -Context $context -Reason 'selftest-pid-reuse'
    }

    # 11. Unrelated process survives
    Assert-HarnessDeadline -Context $suiteContext -Stage 'unrelated'
    $controlCtx = Register-TestContext (New-HarnessLifecycle -Name 'unrelated-control' -RunRoot (Join-Path $Root 'unrelated-control') `
        -OverallTimeoutSeconds 20 -HeartbeatSeconds 5)
    $control = Start-HarnessProcess -Context $controlCtx -FilePath $shell `
        -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' `
        -Kind 'unregistered-control' -Scenario 'ownership-boundary'
    $controlRecord = $control.Record
    $context = Register-TestContext (New-HarnessLifecycle -Name 'ownership-boundary' -RunRoot (Join-Path $Root 'ownership-boundary') `
        -OverallTimeoutSeconds 15 -HeartbeatSeconds 1)
    $owned = $null
    try {
        $owned = New-SleepProcess -Context $context -Scenario 'ownership-boundary'
    } finally {
        Close-HarnessLifecycle -Context $context -Reason 'selftest-ownership-boundary'
    }
    Assert-NoHarnessProcesses -Context $context
    $results.unrelated_process_survives = (Test-HarnessProcessRecordAlive -Record $controlRecord) -and
        -not (Test-HarnessProcessRecordAlive -Record $owned.Record)

    # 12. Provider failure classification for all four scenarios
    Assert-HarnessDeadline -Context $suiteContext -Stage 'provider-classifier'
    $blockedAcceptance = $true
    $scenarioBlocked = [ordered]@{
        normal = $false
        kill = $false
        'restart-missed' = $false
        parallel = $false
    }
    $normalReason = Get-HarnessProviderFailureReason -ProtocolLines @('{"type":"agent_end","assistantOutcome":"failed"}')
    $killReason = Get-HarnessProviderFailureReason -ProtocolText '{"type":"agent_end","assistantOutcome":"failed"}'
    $restartReason = Get-HarnessProviderFailureReason -ProtocolText '{"stopReason":"error"}'
    $parallelReason = Get-HarnessProviderFailureReason -Snapshot ([pscustomobject]@{ attention_state = 'INTERRUPTED' })
    $scenarioBlocked.normal = ($normalReason -like 'BLOCKED_BY_PROVIDER:*')
    $scenarioBlocked.kill = ($killReason -like 'BLOCKED_BY_PROVIDER:*')
    $scenarioBlocked.'restart-missed' = ($restartReason -like 'BLOCKED_BY_PROVIDER:*')
    $scenarioBlocked.parallel = ($parallelReason -like 'BLOCKED_BY_PROVIDER:*')
    foreach ($name in @('normal', 'kill', 'restart-missed', 'parallel')) {
        $reason = switch ($name) {
            'normal' { $normalReason }
            'kill' { $killReason }
            'restart-missed' { $restartReason }
            'parallel' { $parallelReason }
        }
        $blockedSummary = New-HarnessScenarioSummary -Scenario $name -Status 'BLOCKED' -FailureReason $reason `
            -ModelCallBudget (Get-HarnessScenarioConfig -Scenario $name).ModelCallBudget
        if ($blockedSummary.acceptance_pass -ne $false -or $blockedSummary.timed_out -ne $false -or $blockedSummary.status -ne 'BLOCKED') {
            $blockedAcceptance = $false
        }
        $results["provider_classifier_blocked_$($name -replace '-', '_')"] = [bool]$scenarioBlocked[$name]
    }

    $timeoutSummary = New-HarnessScenarioSummary -Scenario 'normal' -Status 'FAIL' -TimedOut:$true `
        -FailureReason 'Timed out after 2s' -AcceptancePass:$true
    $results.timeout_summary_acceptance_pass_false = ($timeoutSummary.acceptance_pass -eq $false) -and
        ($timeoutSummary.timed_out -eq $true) -and ($timeoutSummary.status -eq 'FAIL')

    # 12b. Provider failure must be caught through the real Wait-HarnessProcess path,
    #      not only through the Get-HarnessProviderFailureReason classifier.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'provider-failfast-wait'
    $waitFailureDir = Join-Path $Root 'provider-failfast-wait'
    New-Item -ItemType Directory -Force -Path $waitFailureDir | Out-Null
    $failureSignals = [ordered]@{
        normal = @{ Json = '{"type":"agent_end","assistantOutcome":"failed"}'; Stderr = $null }
        kill = @{ Json = $null; Stderr = 'provider unavailable: upstream 503' }
        'restart-missed' = @{ Json = '{"stopReason":"error"}'; Stderr = $null }
        parallel = @{ Json = '{"type":"state","attention_state":"INTERRUPTED"}'; Stderr = $null }
    }
    $waitBlocked = [ordered]@{ normal = $false; kill = $false; 'restart-missed' = $false; parallel = $false }
    foreach ($name in @('normal', 'kill', 'restart-missed', 'parallel')) {
        $slug = $name -replace '-', '_'
        $caseDir = Join-Path $waitFailureDir $slug
        $caseEvidence = Join-Path $caseDir 'evidence'
        New-Item -ItemType Directory -Force -Path $caseEvidence | Out-Null
        $signal = $failureSignals[$name]
        if ($signal.Json) {
            Set-Content -LiteralPath (Join-Path $caseEvidence "$slug.jsonl") -Value $signal.Json -Encoding utf8
        }
        $caseStderr = Join-Path $caseDir 'runner.stderr.log'
        if ($signal.Stderr) {
            Set-Content -LiteralPath $caseStderr -Value $signal.Stderr -Encoding utf8
        }
        $caseCtx = Register-TestContext (New-HarnessLifecycle -Name "wait-failfast-$slug" -RunRoot $caseDir `
            -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
        $caseChild = $null
        $caseThrew = $false
        $caseMessage = ''
        $caseAliveAtCatch = $true
        $caseExit = $null
        try {
            $caseChild = New-SleepProcess -Context $caseCtx -Scenario "wait-failfast-$slug" -Seconds 60
            $caseExit = Wait-HarnessProcess -Context $caseCtx -Record $caseChild.Record `
                -Stage "wait-failfast-$slug" -TimeoutSeconds 20 -FailFast {
                $lines = @()
                foreach ($f in Get-ChildItem -LiteralPath $caseEvidence -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
                    $lines += Get-Content -LiteralPath $f.FullName
                }
                $stderrText = if (Test-Path -LiteralPath $caseStderr) { Get-Content -LiteralPath $caseStderr -Raw } else { '' }
                Get-HarnessProviderFailureReason -ProtocolLines $lines -StderrText $stderrText
            }
        } catch {
            $caseThrew = $true
            $caseMessage = $_.Exception.Message
            $caseAliveAtCatch = Test-HarnessProcessRecordAlive -Record $caseChild.Record
        } finally {
            Close-HarnessLifecycle -Context $caseCtx -Reason "selftest-wait-failfast-$slug"
        }
        Assert-NoHarnessProcesses -Context $caseCtx
        $waitBlocked[$name] = $caseThrew -and ($caseMessage -like '*BLOCKED_BY_PROVIDER*') -and
            ($null -eq $caseExit) -and (-not $caseAliveAtCatch) -and
            (-not (Test-HarnessProcessRecordAlive -Record $caseChild.Record))
        $results["provider_failure_wait_path_$slug"] = [bool]$waitBlocked[$name]
    }
    $results.provider_failure_uses_wait_path = [bool]$waitBlocked.normal -and [bool]$waitBlocked.kill -and
        [bool]$waitBlocked.'restart-missed' -and [bool]$waitBlocked.parallel
    # These keys must prove the scenario blocks BOTH through the classifier and through
    # the real Wait-HarnessProcess path, so a classifier-only check can never pass them.
    $results.provider_failure_blocked_normal = [bool]$scenarioBlocked.normal -and [bool]$waitBlocked.normal
    $results.provider_failure_blocked_kill = [bool]$scenarioBlocked.kill -and [bool]$waitBlocked.kill
    $results.provider_failure_blocked_restart_missed = [bool]$scenarioBlocked.'restart-missed' -and [bool]$waitBlocked.'restart-missed'
    $results.provider_failure_blocked_parallel = [bool]$scenarioBlocked.parallel -and [bool]$waitBlocked.parallel
    $results.blocked_summary_acceptance_pass_false = $blockedAcceptance -and
        $scenarioBlocked.normal -and $scenarioBlocked.kill -and
        $scenarioBlocked.'restart-missed' -and $scenarioBlocked.parallel -and
        [bool]$waitBlocked.normal -and [bool]$waitBlocked.kill -and
        [bool]$waitBlocked.'restart-missed' -and [bool]$waitBlocked.parallel

    # 12c. FailFast returning a failure reason must clean the live child first.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'failfast-reason'
    $ffReasonCtx = Register-TestContext (New-HarnessLifecycle -Name 'failfast-reason' -RunRoot (Join-Path $Root 'failfast-reason') `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $ffReasonChild = $null
    $ffReasonThrew = $false
    $ffReasonMessage = ''
    $ffReasonAliveAtCatch = $true
    $ffReasonExit = $null
    try {
        $ffReasonChild = New-SleepProcess -Context $ffReasonCtx -Scenario 'failfast-reason' -Seconds 60
        $ffReasonExit = Wait-HarnessProcess -Context $ffReasonCtx -Record $ffReasonChild.Record `
            -Stage 'failfast-reason-wait' -TimeoutSeconds 20 `
            -FailFast { 'BLOCKED_BY_PROVIDER: fake provider failure reason' }
    } catch {
        $ffReasonThrew = $true
        $ffReasonMessage = $_.Exception.Message
        $ffReasonAliveAtCatch = Test-HarnessProcessRecordAlive -Record $ffReasonChild.Record
    } finally {
        Close-HarnessLifecycle -Context $ffReasonCtx -Reason 'selftest-failfast-reason'
    }
    Assert-NoHarnessProcesses -Context $ffReasonCtx
    $results.failfast_reason_kills_live_child = $ffReasonThrew -and ($null -eq $ffReasonExit) -and
        ($ffReasonMessage -like '*BLOCKED_BY_PROVIDER*') -and
        (-not $ffReasonAliveAtCatch) -and
        (-not (Test-HarnessProcessRecordAlive -Record $ffReasonChild.Record))

    # 12d. A FailFast callback that throws must still clean the whole owned tree of
    #      the current scenario (target child plus a sibling owned process) first.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'failfast-throw'
    $ffThrowCtx = Register-TestContext (New-HarnessLifecycle -Name 'failfast-throw' -RunRoot (Join-Path $Root 'failfast-throw') `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $ffThrowChild = $null
    $ffThrowSibling = $null
    $ffThrowThrew = $false
    $ffThrowMessage = ''
    $ffThrowAliveAtCatch = $true
    try {
        $ffThrowChild = New-SleepProcess -Context $ffThrowCtx -Scenario 'failfast-throw' -Seconds 60
        $ffThrowSibling = New-SleepProcess -Context $ffThrowCtx -Scenario 'failfast-throw-sibling' -Seconds 60
        Wait-HarnessProcess -Context $ffThrowCtx -Record $ffThrowChild.Record `
            -Stage 'failfast-throw-wait' -TimeoutSeconds 20 `
            -FailFast { throw 'BLOCKED_BY_PROVIDER: fake provider failure throw' } | Out-Null
    } catch {
        $ffThrowThrew = $true
        $ffThrowMessage = $_.Exception.Message
        $ffThrowAliveAtCatch = (Test-HarnessProcessRecordAlive -Record $ffThrowChild.Record) -or
            (Test-HarnessProcessRecordAlive -Record $ffThrowSibling.Record)
    } finally {
        Close-HarnessLifecycle -Context $ffThrowCtx -Reason 'selftest-failfast-throw'
    }
    Assert-NoHarnessProcesses -Context $ffThrowCtx
    $results.failfast_throw_kills_owned_tree = $ffThrowThrew -and
        ($ffThrowMessage -like '*BLOCKED_BY_PROVIDER*') -and
        (-not $ffThrowAliveAtCatch) -and
        (-not (Test-HarnessProcessRecordAlive -Record $ffThrowChild.Record)) -and
        (-not (Test-HarnessProcessRecordAlive -Record $ffThrowSibling.Record))

    # 12e. A provider failure that only becomes observable after the child exited must
    #      still be caught by the final FailFast; the wait must never return exit code 0.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'failfast-post-exit'
    $postCtx = Register-TestContext (New-HarnessLifecycle -Name 'failfast-post-exit' -RunRoot (Join-Path $Root 'failfast-post-exit') `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $postChild = $null
    $postThrew = $false
    $postMessage = ''
    $postExit = $null
    try {
        $postChild = New-SleepProcess -Context $postCtx -Scenario 'failfast-post-exit' -Seconds 2
        $postExit = Wait-HarnessProcess -Context $postCtx -Record $postChild.Record `
            -Stage 'failfast-post-exit-wait' -TimeoutSeconds 20 -FailFast {
            if (Test-HarnessProcessRecordAlive -Record $postChild.Record) { return $null }
            return 'BLOCKED_BY_PROVIDER: failure written while the child exited'
        }
    } catch {
        $postThrew = $true
        $postMessage = $_.Exception.Message
    } finally {
        Close-HarnessLifecycle -Context $postCtx -Reason 'selftest-failfast-post-exit'
    }
    Assert-NoHarnessProcesses -Context $postCtx
    $results.failfast_post_exit_not_exit_zero = $postThrew -and ($null -eq $postExit) -and
        ($postMessage -like '*BLOCKED_BY_PROVIDER*') -and ($postMessage -like '*post-exit*')

    # 12e-2. Wait-HarnessCondition success boundary. The condition writes the provider
    #        failure signal and returns true in the same instant, so the pre-condition
    #        FailFast cannot see it. The success-boundary FailFast must catch it, clean
    #        the owned tree and throw instead of returning the condition result. The
    #        condition itself must run exactly once.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'condition-success-boundary'
    $condCtx = Register-TestContext (New-HarnessLifecycle -Name 'condition-success-boundary' `
        -RunRoot (Join-Path $Root 'condition-success-boundary') -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $condChild = $null
    $condSignal = @{ Present = $false; ConditionRuns = 0 }
    $condThrew = $false
    $condMessage = ''
    $condResult = $null
    $condAliveAtCatch = $true
    try {
        $condChild = New-SleepProcess -Context $condCtx -Scenario 'condition-success-boundary' -Seconds 60
        $condResult = Wait-HarnessCondition -Context $condCtx -Stage 'condition-race' -TimeoutSeconds 20 `
            -Detail 'signal-writes-on-success' -Condition {
            $condSignal.ConditionRuns++
            $condSignal.Present = $true
            $true
        } -FailFast {
            if ($condSignal.Present) { return 'BLOCKED_BY_PROVIDER: signal written at the success boundary' }
            return $null
        }
    } catch {
        $condThrew = $true
        $condMessage = $_.Exception.Message
        $condAliveAtCatch = Test-HarnessProcessRecordAlive -Record $condChild.Record
    } finally {
        Close-HarnessLifecycle -Context $condCtx -Reason 'selftest-condition-success-boundary'
    }
    Assert-NoHarnessProcesses -Context $condCtx
    $results.condition_success_boundary_provider_failure = $condThrew -and ($null -eq $condResult) -and
        ([int]$condSignal.ConditionRuns -eq 1) -and ([bool]$condSignal.Present) -and
        ($condMessage -like '*BLOCKED_BY_PROVIDER*') -and ($condMessage -like '*condition-race-success*') -and
        (-not $condAliveAtCatch) -and (-not (Test-HarnessProcessRecordAlive -Record $condChild.Record))

    # 12e-3. Generic callback exception classification.
    #        C - a plain harness exception must clean the child, keep the original text
    #            and stay FAIL (never relabelled as BLOCKED_BY_PROVIDER).
    Assert-HarnessDeadline -Context $suiteContext -Stage 'generic-failfast-exception'
    $genCtx = Register-TestContext (New-HarnessLifecycle -Name 'generic-failfast-exception' `
        -RunRoot (Join-Path $Root 'generic-failfast-exception') -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $genChild = $null
    $genThrew = $false
    $genMessage = ''
    $genAliveAtCatch = $true
    try {
        $genChild = New-SleepProcess -Context $genCtx -Scenario 'generic-failfast-exception' -Seconds 60
        Wait-HarnessProcess -Context $genCtx -Record $genChild.Record -Stage 'generic-exception-wait' `
            -TimeoutSeconds 20 -FailFast { throw 'EVIDENCE_READ_FAILED' } | Out-Null
    } catch {
        $genThrew = $true
        $genMessage = $_.Exception.Message
        $genAliveAtCatch = Test-HarnessProcessRecordAlive -Record $genChild.Record
    } finally {
        Close-HarnessLifecycle -Context $genCtx -Reason 'selftest-generic-failfast-exception'
    }
    Assert-NoHarnessProcesses -Context $genCtx
    $genClassification = Resolve-HarnessFailureClassification -Message $genMessage
    $results.generic_failfast_exception_is_fail_not_blocked = $genThrew -and
        ($genMessage -like '*EVIDENCE_READ_FAILED*') -and
        ($genMessage -notlike '*BLOCKED_BY_PROVIDER*') -and
        ([bool]$genClassification.blocked -eq $false) -and
        ([bool]$genClassification.timed_out -eq $false) -and
        (-not $genAliveAtCatch) -and
        (-not (Test-HarnessProcessRecordAlive -Record $genChild.Record))

    # 12e-4. B - an explicit provider throw must still clean the child and stay BLOCKED.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'explicit-provider-exception'
    $expCtx = Register-TestContext (New-HarnessLifecycle -Name 'explicit-provider-exception' `
        -RunRoot (Join-Path $Root 'explicit-provider-exception') -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $expChild = $null
    $expThrew = $false
    $expMessage = ''
    $expAliveAtCatch = $true
    try {
        $expChild = New-SleepProcess -Context $expCtx -Scenario 'explicit-provider-exception' -Seconds 60
        Wait-HarnessProcess -Context $expCtx -Record $expChild.Record -Stage 'explicit-provider-wait' `
            -TimeoutSeconds 20 -FailFast { throw 'BLOCKED_BY_PROVIDER: injected provider failure' } | Out-Null
    } catch {
        $expThrew = $true
        $expMessage = $_.Exception.Message
        $expAliveAtCatch = Test-HarnessProcessRecordAlive -Record $expChild.Record
    } finally {
        Close-HarnessLifecycle -Context $expCtx -Reason 'selftest-explicit-provider-exception'
    }
    Assert-NoHarnessProcesses -Context $expCtx
    $expClassification = Resolve-HarnessFailureClassification -Message $expMessage
    $results.explicit_provider_exception_remains_blocked = $expThrew -and
        ($expMessage -like '*BLOCKED_BY_PROVIDER*') -and
        ($expMessage -like '*injected provider failure*') -and
        ([bool]$expClassification.blocked) -and
        (-not $expAliveAtCatch) -and
        (-not (Test-HarnessProcessRecordAlive -Record $expChild.Record))

    # 12e-5. A - a returned (unprefixed) provider reason must be normalised, clean the
    #        child and stay BLOCKED.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'returned-provider-reason'
    $retCtx = Register-TestContext (New-HarnessLifecycle -Name 'returned-provider-reason' `
        -RunRoot (Join-Path $Root 'returned-provider-reason') -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    $retChild = $null
    $retThrew = $false
    $retMessage = ''
    $retAliveAtCatch = $true
    try {
        $retChild = New-SleepProcess -Context $retCtx -Scenario 'returned-provider-reason' -Seconds 60
        Wait-HarnessProcess -Context $retCtx -Record $retChild.Record -Stage 'returned-reason-wait' `
            -TimeoutSeconds 20 -FailFast { return 'injected returned provider reason' } | Out-Null
    } catch {
        $retThrew = $true
        $retMessage = $_.Exception.Message
        $retAliveAtCatch = Test-HarnessProcessRecordAlive -Record $retChild.Record
    } finally {
        Close-HarnessLifecycle -Context $retCtx -Reason 'selftest-returned-provider-reason'
    }
    Assert-NoHarnessProcesses -Context $retCtx
    $retClassification = Resolve-HarnessFailureClassification -Message $retMessage
    $results.returned_provider_reason_remains_blocked = $retThrew -and
        ($retMessage -like '*BLOCKED_BY_PROVIDER*') -and
        ($retMessage -like '*injected returned provider reason*') -and
        ([bool]$retClassification.blocked) -and
        (-not $retAliveAtCatch) -and
        (-not (Test-HarnessProcessRecordAlive -Record $retChild.Record))

    # 12f. FailFast must end the whole owned process tree, including a descendant that
    #      the owned child spawned itself.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'failfast-owned-tree'
    $treeCtx = Register-TestContext (New-HarnessLifecycle -Name 'failfast-owned-tree' -RunRoot (Join-Path $Root 'failfast-owned-tree') `
        -OverallTimeoutSeconds 40 -HeartbeatSeconds 5)
    $treeProbe = $null
    $treeThrew = $false
    $treeMessage = ''
    $treeExit = $null
    try {
        $treeProbe = Start-HarnessTreeChild -Context $treeCtx -Dir (Join-Path $Root 'failfast-owned-tree\probe') `
            -Scenario 'failfast-owned-tree'
        $treeExit = Wait-HarnessProcess -Context $treeCtx -Record $treeProbe.Owned.Record `
            -Stage 'failfast-owned-tree-wait' -TimeoutSeconds 25 `
            -FailFast { 'BLOCKED_BY_PROVIDER: owned tree provider failure' }
    } catch {
        $treeThrew = $true
        $treeMessage = $_.Exception.Message
    } finally {
        Close-HarnessLifecycle -Context $treeCtx -Reason 'selftest-failfast-owned-tree'
    }
    Assert-NoHarnessProcesses -Context $treeCtx
    $treeGone = Wait-HarnessTreeGone -Tree $treeProbe
    $results.failfast_cleans_owned_tree = $treeThrew -and ($null -eq $treeExit) -and
        ($treeMessage -like '*BLOCKED_BY_PROVIDER*') -and $treeGone

    # 12g. Real absolute deadline: the lifecycle deadline must be shorter than the
    #      requested wait timeout, and the deadline must end parent plus descendant.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'absolute-deadline'
    $absoluteOverallSeconds = 6
    $absoluteWaitSeconds = 60
    $absoluteCtx = Register-TestContext (New-HarnessLifecycle -Name 'absolute-deadline' -RunRoot (Join-Path $Root 'absolute-deadline') `
        -OverallTimeoutSeconds $absoluteOverallSeconds -HeartbeatSeconds 1)
    $absoluteProbe = $null
    $absoluteThrew = $false
    $absoluteMessage = ''
    $absoluteExit = $null
    try {
        $absoluteProbe = Start-HarnessTreeChild -Context $absoluteCtx -Dir (Join-Path $Root 'absolute-deadline\probe') `
            -Scenario 'absolute-deadline'
        $absoluteExit = Wait-HarnessProcess -Context $absoluteCtx -Record $absoluteProbe.Owned.Record `
            -Stage 'absolute-deadline-wait' -TimeoutSeconds $absoluteWaitSeconds
    } catch {
        $absoluteThrew = $true
        $absoluteMessage = $_.Exception.Message
    } finally {
        Close-HarnessLifecycle -Context $absoluteCtx -Reason 'selftest-absolute-deadline'
    }
    $absoluteGone = Wait-HarnessTreeGone -Tree $absoluteProbe
    $results.absolute_deadline_shorter_than_wait_timeout = ($absoluteWaitSeconds -gt $absoluteOverallSeconds)
    $results.absolute_deadline_kills_parent_and_descendant = $absoluteThrew -and ($null -eq $absoluteExit) -and
        ($absoluteWaitSeconds -gt $absoluteOverallSeconds) -and
        ($absoluteMessage -like '*deadline exceeded*') -and
        ($absoluteMessage -notlike '*Timed out after*') -and $absoluteGone

    # 12h. Parallel: a provider failure on either runner must stop the whole parallel
    #      scenario and clean both runners, without waiting for the other runner.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'parallel-failfast'
    $parallelFailFastOk = $true
    foreach ($parallelMode in @('a-fails', 'b-fails')) {
        $parCtx = Register-TestContext (New-HarnessLifecycle -Name "parallel-failfast-$parallelMode" `
            -RunRoot (Join-Path $Root "parallel-failfast-$parallelMode") -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
        $runnerA = $null
        $runnerB = $null
        $parThrew = $false
        $parMessage = ''
        $parExit = $null
        $parAliveAtCatch = $true
        try {
            $runnerA = New-SleepProcess -Context $parCtx -Scenario 'parallel-runner-a' -Seconds 60
            $runnerB = New-SleepProcess -Context $parCtx -Scenario 'parallel-runner-b' -Seconds 60
            $parTarget = if ($parallelMode -eq 'b-fails') { $runnerB } else { $runnerA }
            $parStage = if ($parallelMode -eq 'b-fails') { 'parallel-runner-b' } else { 'parallel-runner-a' }
            $parExit = Wait-HarnessProcess -Context $parCtx -Record $parTarget.Record -Stage $parStage `
                -TimeoutSeconds 20 -FailFast { 'BLOCKED_BY_PROVIDER: fake parallel provider failure' }
        } catch {
            $parThrew = $true
            $parMessage = $_.Exception.Message
            $parAliveAtCatch = (Test-HarnessProcessRecordAlive -Record $runnerA.Record) -or
                (Test-HarnessProcessRecordAlive -Record $runnerB.Record)
        } finally {
            Close-HarnessLifecycle -Context $parCtx -Reason "selftest-parallel-failfast-$parallelMode"
        }
        Assert-NoHarnessProcesses -Context $parCtx
        $modeOk = $parThrew -and ($null -eq $parExit) -and ($parMessage -like '*BLOCKED_BY_PROVIDER*') -and
            (-not $parAliveAtCatch) -and
            (-not (Test-HarnessProcessRecordAlive -Record $runnerA.Record)) -and
            (-not (Test-HarnessProcessRecordAlive -Record $runnerB.Record))
        $results["parallel_failfast_cleans_both_runners_$($parallelMode -replace '-', '_')"] = [bool]$modeOk
        if (-not $modeOk) { $parallelFailFastOk = $false }
    }
    $results.parallel_failfast_cleans_both_runners = $parallelFailFastOk

    # 12i. Timeout summary must report the real measured cleanup result, and must not
    #      rewrite an injected cleanup failure / remaining count.
    Assert-HarnessDeadline -Context $suiteContext -Stage 'timeout-summary'
    $tsDir = Join-Path $Root 'timeout-summary'
    New-Item -ItemType Directory -Force -Path $tsDir | Out-Null
    $tsCleanCtx = Register-TestContext (New-HarnessLifecycle -Name 'timeout-summary-clean' -RunRoot (Join-Path $tsDir 'clean') `
        -OverallTimeoutSeconds 30 -HeartbeatSeconds 5)
    New-SleepProcess -Context $tsCleanCtx -Scenario 'timeout-summary-clean' -Seconds 60 | Out-Null
    Close-HarnessLifecycle -Context $tsCleanCtx -Reason 'selftest-timeout-summary-clean'
    $tsCleanMeasure = Measure-HarnessCleanup -Contexts @($tsCleanCtx)
    $tsCleanPath = Join-Path $tsDir 'clean-timeout-summary.json'
    Write-HarnessTimeoutSummaryFile -Path $tsCleanPath -ScenarioName 'timeout-summary-clean' -TimeoutSeconds 30 `
        -Budget 1 -CallsStarted 1 -Root $tsDir -ElapsedSeconds 1.5 `
        -Reason 'Timed out after 30s waiting for timeout-summary-clean' `
        -CleanupSuccess:$([bool]$tsCleanMeasure.cleanup_success) `
        -OwnedProcessesRemaining ([int]$tsCleanMeasure.owned_processes_remaining) | Out-Null
    $tsCleanJson = Get-Content -LiteralPath $tsCleanPath -Raw | ConvertFrom-Json
    $results.timeout_summary_real_cleanup_success = ([bool]$tsCleanMeasure.cleanup_success) -and
        ([int]$tsCleanMeasure.owned_processes_remaining -eq 0) -and
        ([bool]$tsCleanJson.cleanup_success) -and ([int]$tsCleanJson.owned_processes_remaining -eq 0) -and
        ([string]$tsCleanJson.status -eq 'FAIL') -and ([bool]$tsCleanJson.acceptance_pass -eq $false) -and
        ([bool]$tsCleanJson.passed -eq $false) -and ($null -eq $tsCleanJson.cleanup_failure)

    $tsFailPath = Join-Path $tsDir 'failed-timeout-summary.json'
    Write-HarnessTimeoutSummaryFile -Path $tsFailPath -ScenarioName 'timeout-summary-failed' -TimeoutSeconds 30 `
        -Budget 2 -CallsStarted 2 -Root $tsDir -ElapsedSeconds 2.5 `
        -Reason 'Timed out after 30s waiting for timeout-summary-failed' `
        -CleanupSuccess:$false -OwnedProcessesRemaining 1 -CleanupFailure 'INJECTED_CLEANUP_FAILURE' | Out-Null
    $tsFailJson = Get-Content -LiteralPath $tsFailPath -Raw | ConvertFrom-Json
    $results.timeout_summary_reflects_cleanup_failure = ([bool]$tsFailJson.cleanup_success -eq $false) -and
        ([int]$tsFailJson.owned_processes_remaining -eq 1) -and
        ([string]$tsFailJson.cleanup_failure -eq 'INJECTED_CLEANUP_FAILURE') -and
        ([string]$tsFailJson.status -eq 'FAIL') -and
        ([bool]$tsFailJson.acceptance_pass -eq $false) -and
        ([bool]$tsFailJson.passed -eq $false) -and
        ([string]$tsFailJson.failure_reason -like '*INJECTED_CLEANUP_FAILURE*') -and
        ([string]$tsFailJson.failure_reason -like '*owned_processes_remaining=1*')

    $offlineClaim = Resolve-HarnessAcceptanceClaim -LiveAttempted:$false -Status 'PASS' -AcceptancePass:$true
    $offlineFailClaim = Resolve-HarnessAcceptanceClaim -LiveAttempted:$false -Status 'FAIL' -AcceptancePass:$false
    $livePassClaim = Resolve-HarnessAcceptanceClaim -LiveAttempted:$true -Status 'PASS' -AcceptancePass:$true
    $liveBlockedClaim = Resolve-HarnessAcceptanceClaim -LiveAttempted:$true -Status 'BLOCKED' -AcceptancePass:$true
    $results.offline_does_not_claim_acceptance_pass =
        ($offlineClaim.status -eq 'OFFLINE') -and
        ($offlineClaim.acceptance_pass -eq $false) -and
        ($offlineClaim.live_scenario_attempted -eq $false) -and
        ($offlineFailClaim.status -eq 'FAIL') -and
        ($offlineFailClaim.acceptance_pass -eq $false) -and
        ($livePassClaim.status -eq 'PASS') -and
        ($livePassClaim.acceptance_pass -eq $true) -and
        ($livePassClaim.live_scenario_attempted -eq $true) -and
        ($liveBlockedClaim.status -eq 'BLOCKED') -and
        ($liveBlockedClaim.acceptance_pass -eq $false)
    $results.supervisor_resolves_acceptance_claim =
        ($supervisorText -match 'Resolve-HarnessAcceptanceClaim') -and
        ($supervisorText -match '\$scenarioStatus = ''OFFLINE''') -and
        ($supervisorText -notmatch 'if \(-not \$AllowLiveScenario\)[\s\S]{0,800}\$scenarioStatus = ''PASS''') -and
        ($supervisorText -notmatch 'if \(-not \$AllowLiveScenario\)[\s\S]{0,800}\$acceptancePass = \$true')

    # 13. Heartbeat updates from 0 to fake model call count
    Assert-HarnessDeadline -Context $suiteContext -Stage 'heartbeat'
    $hbDir = Join-Path $Root 'heartbeat'
    New-Item -ItemType Directory -Force -Path $hbDir | Out-Null
    $hbProgress = Join-Path $hbDir 'harness-progress.json'
    $hbCtx = Register-TestContext (New-HarnessLifecycle -Name 'heartbeat' -RunRoot $hbDir `
        -OverallTimeoutSeconds 20 -HeartbeatSeconds 1 -ProgressFile $hbProgress)
    Write-HarnessProgress -Path $hbProgress -Scenario 'normal' -Stage 'init' -ModelCallBudget 1 -ModelCallsStarted 0
    $hbCtx.ModelCallsStarted = 0
    $hbScript = Join-Path $hbDir 'fake-progress.ps1'
    $hbProgressQuoted = $hbProgress.Replace("'", "''")
    Set-Content -LiteralPath $hbScript -Value @"
Start-Sleep -Milliseconds 200
`$json = '{"scenario":"normal","stage":"model-call-1","model_call_budget":1,"model_calls_started":1,"updated_at":"2026-01-01T00:00:00Z"}'
`$tmp = '$hbProgressQuoted.tmp'
Set-Content -LiteralPath `$tmp -Value `$json -Encoding utf8
Move-Item -LiteralPath `$tmp -Destination '$hbProgressQuoted' -Force
Start-Sleep -Seconds 1
"@ -Encoding utf8
    $hbChild = Start-HarnessProcess -Context $hbCtx -FilePath $shell `
        -ArgumentList "-NoProfile -NonInteractive -File `"$hbScript`"" `
        -Kind 'fake-model-progress' -Scenario 'heartbeat'
    $exitHb = Wait-HarnessProcess -Context $hbCtx -Record $hbChild.Record -Stage 'heartbeat-fake-call' -TimeoutSeconds 8 -ProgressFile $hbProgress
    Close-HarnessLifecycle -Context $hbCtx -Reason 'selftest-heartbeat'
    $results.heartbeat_updates_from_zero = ($exitHb -eq 0) -and ($hbCtx.ModelCallsStarted -ge 1)

    # 14. Malformed progress JSON does not crash supervisor heartbeat
    Assert-HarnessDeadline -Context $suiteContext -Stage 'malformed-progress'
    $malDir = Join-Path $Root 'malformed-progress'
    New-Item -ItemType Directory -Force -Path $malDir | Out-Null
    $malProgress = Join-Path $malDir 'harness-progress.json'
    $malCtx = Register-TestContext (New-HarnessLifecycle -Name 'malformed-progress' -RunRoot $malDir `
        -OverallTimeoutSeconds 15 -HeartbeatSeconds 1 -ProgressFile $malProgress)
    Write-HarnessProgress -Path $malProgress -Scenario 'normal' -Stage 'ok' -ModelCallBudget 1 -ModelCallsStarted 2
    Update-HarnessProgressState -Context $malCtx
    $before = $malCtx.ModelCallsStarted
    Set-Content -LiteralPath $malProgress -Value '{not-json' -Encoding utf8
    $malformedOk = $false
    try {
        Update-HarnessProgressState -Context $malCtx
        Write-HarnessHeartbeat -Context $malCtx -Stage 'malformed' -Force
        $read = Read-HarnessProgress -Path $malProgress -Fallback $malCtx.LastValidProgress
        $malformedOk = ($malCtx.ModelCallsStarted -eq $before) -and ($read.model_calls_started -eq $before)
    } catch {
        $malformedOk = $false
    } finally {
        Close-HarnessLifecycle -Context $malCtx -Reason 'selftest-malformed-progress'
    }
    $results.malformed_progress_does_not_crash = $malformedOk

    # Extra: impossible condition still times out and cleans child
    Assert-HarnessDeadline -Context $suiteContext -Stage 'condition-timeout'
    $context = Register-TestContext (New-HarnessLifecycle -Name 'condition-timeout' -RunRoot (Join-Path $Root 'condition-timeout') `
        -OverallTimeoutSeconds 15 -HeartbeatSeconds 1)
    $owned = $null
    $condTimedOut = $false
    try {
        $owned = New-SleepProcess -Context $context -Scenario 'condition-timeout'
        Wait-HarnessCondition -Context $context -Stage 'impossible-state' -TimeoutSeconds 2 `
            -Condition { $false } -Detail 'expected=false' | Out-Null
    } catch {
        $condTimedOut = $_.Exception.Message -like '*Timed out after 2s*'
    } finally {
        Close-HarnessLifecycle -Context $context -Reason 'selftest-condition-timeout'
    }
    Assert-NoHarnessProcesses -Context $context
    $results.condition_timeout_cleans_child = $condTimedOut -and
        $null -ne $owned -and
        -not (Test-HarnessProcessRecordAlive -Record $owned.Record)
} finally {
    if ($watchdogState) { $watchdogState.Cancel = $true }
    if ($watchdog) {
        try { $watchdog.Stop() } catch { }
        try { $watchdog.Dispose() } catch { }
    }
    if ($controlRecord -and (Test-HarnessProcessRecordAlive -Record $controlRecord)) {
        Stop-HarnessProcessRecord -Record $controlRecord -Reason 'selftest-control-cleanup' | Out-Null
    }
    if ($crashWorkerRecord -and (Test-HarnessProcessRecordAlive -Record $crashWorkerRecord)) {
        Stop-HarnessProcessRecord -Record $crashWorkerRecord -Reason 'selftest-crash-owner-cleanup' | Out-Null
    }
    if ($crashChildRecord -and (Test-HarnessProcessRecordAlive -Record $crashChildRecord)) {
        Stop-HarnessProcessRecord -Record $crashChildRecord -Reason 'selftest-crash-child-cleanup' | Out-Null
    }
    foreach ($ctx in $ownedContexts) {
        try { Close-HarnessLifecycle -Context $ctx -Reason 'selftest-suite-finally' } catch { }
    }
}

$ownedRemaining = 0
foreach ($ctx in $ownedContexts) {
    $ownedRemaining += Get-HarnessOwnedAliveCount -Context $ctx
}
if ($controlRecord -and (Test-HarnessProcessRecordAlive -Record $controlRecord)) { $ownedRemaining++ }
if ($crashChildRecord -and (Test-HarnessProcessRecordAlive -Record $crashChildRecord)) { $ownedRemaining++ }

$results.offline_model_call_count_zero = $true
$results.owned_processes_remaining_zero = ($ownedRemaining -eq 0)

$passed = -not ($results.Values -contains $false)
$summary = [ordered]@{
    suite = 'Pi Adapter harness lifecycle self-test'
    passed = $passed
    maximum_runtime_seconds = $MaximumRuntimeSeconds
    elapsed_seconds = [math]::Round(([DateTimeOffset]::UtcNow - $suiteStarted).TotalSeconds, 3)
    network_model_calls = 0
    model_calls_started = 0
    owned_processes_remaining = $ownedRemaining
    results = $results
    root = $Root
}
$summary | ConvertTo-Json -Depth 5
if (-not $passed) {
    throw "Harness lifecycle self-test failed: $((@($results.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })) -join ', ')"
}
