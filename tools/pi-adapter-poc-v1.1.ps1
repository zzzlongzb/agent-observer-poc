[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('normal', 'kill', 'restart-missed', 'parallel')][string]$Scenario,
    [Parameter(Mandatory)][int]$ModelCallBudget,
    [string]$Root = '',
    [string]$Binary = '',
    [string]$Provider = 'xai',
    [string]$Model = 'xai/grok-4.3',
    [string]$Thinking = 'off',
    [int]$StaleAfterSecs = 32,
    [switch]$Supervised,
    [string]$StartGate = '',
    [int]$TimeoutSeconds = 0,
    [string]$ProgressFile = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'harness-lifecycle.ps1')

# Pi Adapter Scenario Harness v1.2.
# Enforces strict single-scenario live execution.
# Direct invocation is intentionally disabled. The supervisor assigns this
# worker to a kill-on-close Windows Job Object before opening StartGate.
if (-not $Supervised -or -not $StartGate) {
    throw 'Direct live-harness invocation is disabled. Use pi-adapter-harness-supervisor.ps1.'
}

$scenarioCfg = Get-HarnessScenarioConfig -Scenario $Scenario
if ($ModelCallBudget -ne $scenarioCfg.ModelCallBudget) {
    throw "Model call budget mismatch for scenario '$Scenario'. Expected $($scenarioCfg.ModelCallBudget), but received $ModelCallBudget."
}

if ($TimeoutSeconds -le 0) {
    $TimeoutSeconds = $scenarioCfg.DefaultTimeoutSeconds
}

$gateDeadline = (Get-Date).AddSeconds(15)
while (-not (Test-Path -LiteralPath $StartGate)) {
    if ((Get-Date) -ge $gateDeadline) {
        throw 'The harness supervisor did not open StartGate within 15 seconds.'
    }
    Start-Sleep -Milliseconds 100
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:ModelCallsStarted = 0
$script:ModelCallBudget = $ModelCallBudget
$script:AutomaticRetries = 0
$script:Harness = $null
$scenarioStartedAt = [DateTimeOffset]::UtcNow

Write-Host "worker stage=started scenario=$Scenario model_call_budget=$ModelCallBudget retries=0 timeout=${TimeoutSeconds}s"

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Publish-WorkerProgress {
    param([Parameter(Mandatory)][string]$Stage)
    if (-not $script:ProgressPath) { return }
    Write-HarnessProgress -Path $script:ProgressPath -Scenario $Scenario -Stage $Stage `
        -ModelCallBudget $script:ModelCallBudget -ModelCallsStarted $script:ModelCallsStarted
    if ($script:Harness) {
        $script:Harness.ModelCallsStarted = $script:ModelCallsStarted
        $script:Harness.ProgressStage = $Stage
    }
}

function Assert-NoProviderFailure {
    param(
        [string]$EvidenceDir = '',
        [string]$RecordPath = '',
        [string]$StderrPath = ''
    )
    $protocolLines = @()
    if ($EvidenceDir -and (Test-Path -LiteralPath $EvidenceDir)) {
        foreach ($file in Get-ChildItem -LiteralPath $EvidenceDir -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
            $protocolLines += Get-Content -LiteralPath $file.FullName
        }
    }
    $rows = @()
    if ($RecordPath) { $rows = @(Get-WatchRows -RecordPath $RecordPath) }
    $stderr = ''
    if ($StderrPath -and (Test-Path -LiteralPath $StderrPath)) {
        $stderr = Get-Content -LiteralPath $StderrPath -Raw
    }
    $reason = Get-HarnessProviderFailureReason -ProtocolLines $protocolLines -WatchRows $rows -StderrText $stderr
    if ($reason) { throw $reason }
}

function Wait-ForFile {
    param([Parameter(Mandatory)][string]$Path, [int]$TimeoutSeconds = 30)
    Wait-HarnessCondition -Context $script:Harness -Stage "file:$Path" -TimeoutSeconds $TimeoutSeconds `
        -Condition { Test-Path -LiteralPath $Path } -Detail $Path | Out-Null
}

function Wait-ForBindingActive {
    param(
        [Parameter(Mandatory)][string]$EvidenceDir,
        [int]$TimeoutSeconds = 0,
        [string]$RecordPath = '',
        [string]$StderrPath = ''
    )
    Wait-HarnessCondition -Context $script:Harness -Stage 'binding-active' -TimeoutSeconds $TimeoutSeconds -Detail $EvidenceDir `
        -FailFast {
            Assert-NoProviderFailure -EvidenceDir $EvidenceDir -RecordPath $RecordPath -StderrPath $StderrPath
            $null
        } -Condition {
            $file = Get-ChildItem -Path $EvidenceDir -Filter '*.binding-active.json' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($file) { Read-JsonFile $file.FullName } else { $false }
        }
}

function Wait-ForBindingActiveCount {
    param(
        [Parameter(Mandatory)][string]$EvidenceDir,
        [Parameter(Mandatory)][int]$Count,
        [int]$TimeoutSeconds = 0,
        [string]$RecordPath = '',
        [string]$StderrPath = ''
    )
    Wait-HarnessCondition -Context $script:Harness -Stage "binding-active-count-$Count" -TimeoutSeconds $TimeoutSeconds `
        -Detail $EvidenceDir -FailFast {
            Assert-NoProviderFailure -EvidenceDir $EvidenceDir -RecordPath $RecordPath -StderrPath $StderrPath
            $null
        } -Condition {
            $files = @(Get-ChildItem -Path $EvidenceDir -Filter '*.binding-active.json' -ErrorAction SilentlyContinue)
            if ($files.Count -ge $Count) { $files } else { $false }
        }
}

function Get-WatchRows {
    param([Parameter(Mandatory)][string]$RecordPath)
    if (-not (Test-Path -LiteralPath $RecordPath)) { return ,@() }
    $rows = @()
    foreach ($line in Get-Content -LiteralPath $RecordPath) {
        if ($line -notmatch '^\{') { continue }
        $row = $null
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if ($row.record_type -eq 'snapshot' -and $row.agent_family -eq 'Pi') {
            $rows += [pscustomobject]@{
                recorded_at_unix_ms = [int64]$row.recorded_at_unix_ms
                native_session_id = $row.native_session_id
                attention_state = $row.attention_state
                evidence_freshness = $row.evidence_freshness
                host_liveness = $row.host_liveness
                session_liveness = $row.session_liveness
                runtime_binding_id = $row.runtime_binding_id
                process_id = $row.process_id
            }
        }
    }
    ,$rows
}

function Wait-WatchPredicate {
    param(
        [Parameter(Mandatory)][string]$RecordPath,
        [Parameter(Mandatory)][scriptblock]$Predicate,
        [int]$TimeoutSeconds = 0,
        [string]$Label = 'state',
        [string]$EvidenceDir = '',
        [string]$StderrPath = '',
        [switch]$SkipProviderFailFast
    )
    $script:LastWatchRow = $null
    $waitParams = @{
        Context = $script:Harness
        Stage = "watch:$Label"
        TimeoutSeconds = $TimeoutSeconds
        Detail = $Label
        Condition = {
            $rows = Get-WatchRows -RecordPath $RecordPath
            if ($rows.Count -gt 0) {
                $script:LastWatchRow = $rows[$rows.Count - 1]
                if (& $Predicate $script:LastWatchRow) { return $script:LastWatchRow }
            }
            $false
        }
    }
    if (-not $SkipProviderFailFast) {
        $waitParams.FailFast = {
            Assert-NoProviderFailure -EvidenceDir $EvidenceDir -RecordPath $RecordPath -StderrPath $StderrPath
            $null
        }
    }
    Wait-HarnessCondition @waitParams
}

function Start-Watch {
    param(
        [Parameter(Mandatory)][string]$BindingsRoot,
        [Parameter(Mandatory)][string]$RecordPath,
        [int]$StaleAfter = 300
    )
    $arguments = @(
        'watch', '--json', '--all', '--interval-secs', '1',
        '--stale-after-secs', $StaleAfter.ToString(),
        '--runtime-binding-root', $BindingsRoot,
        '--record-file', $RecordPath
    ) -join ' '
    $owned = Start-HarnessProcess -Context $script:Harness -FilePath $Binary -ArgumentList $arguments `
        -Kind 'observer-watch' -Scenario $Scenario -BindingRoot $BindingsRoot `
        -RedirectStandardOutput "$RecordPath.scan" -RedirectStandardError "$RecordPath.scan.err"
    Wait-ForFile -Path $RecordPath -TimeoutSeconds 15
    $owned
}

function Invoke-ObserveScan {
    param(
        [Parameter(Mandatory)][string]$BindingsRoot,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][int]$StaleAfter
    )
    $errPath = "$OutputPath.stderr"
    $arguments = @(
        'observe', '--json', '--all',
        '--stale-after-secs', $StaleAfter.ToString(),
        '--runtime-binding-root', "`"$BindingsRoot`""
    ) -join ' '
    $owned = Start-HarnessProcess -Context $script:Harness -FilePath $Binary -ArgumentList $arguments `
        -Kind 'observe-scan' -Scenario $Scenario -BindingRoot $BindingsRoot `
        -RedirectStandardOutput $OutputPath -RedirectStandardError $errPath
    $exit = Wait-HarnessProcess -Context $script:Harness -Record $owned.Record -Stage 'observe-scan'
    if ($exit -ne 0) {
        $stderr = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw } else { '' }
        throw "observe scan failed with exit code $exit. $stderr"
    }
    Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function New-CaseDir {
    param([Parameter(Mandatory)][string]$CaseName)
    $dir = Join-Path $script:RunIdDir $CaseName
    foreach ($sub in @('ws', 'sessions', 'bindings')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null
    }
    [pscustomobject]@{
        dir = $dir
        ws = Join-Path $dir 'ws'
        sessions = Join-Path $dir 'sessions'
        bindings = Join-Path $dir 'bindings'
        evidence = Join-Path $dir 'bindings\pi-rpc'
    }
}

function Invoke-RunPi {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$SessionDir,
        [Parameter(Mandatory)][string]$BindingsRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$Background,
        [string]$StdErrLog = '',
        [string]$StdOutLog = ''
    )
    if ($script:ModelCallsStarted -ge $script:ModelCallBudget) {
        throw "Model call budget exceeded ($script:ModelCallsStarted >= $script:ModelCallBudget). Launch aborted."
    }
    $script:ModelCallsStarted++
    Publish-WorkerProgress -Stage "model-call-$($script:ModelCallsStarted)"

    $arguments = @(
        'run', 'pi',
        '--cwd', "`"$Workspace`"",
        '--runtime-binding-root', "`"$BindingsRoot`"",
        '--pi-session-dir', "`"$SessionDir`"",
        '--provider', $Provider,
        '--model', $Model,
        '--thinking', $Thinking,
        '--name', "`"$Name`"",
        '--', "`"$Prompt`""
    ) -join ' '
    if (-not $StdErrLog) {
        $StdErrLog = Join-Path $script:RunIdDir "runpi-$($script:ModelCallsStarted).stderr.log"
    }
    if (-not $StdOutLog) {
        $StdOutLog = Join-Path $script:RunIdDir "runpi-$($script:ModelCallsStarted).stdout.log"
    }
    $owned = Start-HarnessProcess -Context $script:Harness -FilePath $Binary -ArgumentList $arguments `
        -Kind 'pi-runner' -Scenario $Scenario -BindingRoot $BindingsRoot `
        -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog
    if ($Background) {
        return $owned
    }
    $evidenceDir = Join-Path $BindingsRoot 'pi-rpc'
    $exit = Wait-HarnessProcess -Context $script:Harness -Record $owned.Record `
        -Stage "run-pi-$($script:ModelCallsStarted)" -FailFast {
            Assert-NoProviderFailure -EvidenceDir $evidenceDir -StderrPath $StdErrLog
            $null
        }
    $output = if (Test-Path -LiteralPath $StdOutLog) { Get-Content -LiteralPath $StdOutLog -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $StdErrLog) { Get-Content -LiteralPath $StdErrLog -Raw } else { '' }
    return [pscustomobject]@{
        output = $output
        stderr = $stderr
        exit_code = $exit
        Process = $owned.Process
        Record = $owned.Record
    }
}

if (-not $Root) {
    $Root = Join-Path $env:TEMP 'agent-observer-pi-adapter-worker'
}
if (-not $Binary) {
    $Binary = Join-Path $PSScriptRoot '..\target\debug\agent-observer-poc.exe'
}
if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) {
    throw "Observer binary does not exist: $Binary. Run cargo build first."
}
$resolvedBinary = (Resolve-Path -LiteralPath $Binary).Path
$Binary = $resolvedBinary

$runId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$script:RunRoot = Join-Path $Root 'automated'
New-Item -ItemType Directory -Force -Path $script:RunRoot | Out-Null
$script:RunIdDir = Join-Path $script:RunRoot $runId
New-Item -ItemType Directory -Force -Path $script:RunIdDir | Out-Null
$script:ProgressPath = if ($ProgressFile) { $ProgressFile } else { Join-Path $Root 'harness-progress.json' }

$script:Harness = New-HarnessLifecycle -Name "Pi Adapter $Scenario worker" -RunRoot $script:RunIdDir `
    -Scenario $Scenario -OverallTimeoutSeconds $TimeoutSeconds -HeartbeatSeconds 10 `
    -ProgressFile $script:ProgressPath
$scenarioStartedAt = $script:Harness.StartedAt
Publish-WorkerProgress -Stage 'started'

# Isolate legacy observer source roots.
$script:LegacyIsolation = Join-Path $script:RunIdDir 'legacy-isolation'
foreach ($sub in @('codex', 'claude', 'claude-hooks', 'claude-sessions')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:LegacyIsolation $sub) | Out-Null
}
$env:AGENT_OBSERVER_CODEX_ROOT = Join-Path $script:LegacyIsolation 'codex'
$env:AGENT_OBSERVER_CLAUDE_ROOT = Join-Path $script:LegacyIsolation 'claude'
$env:AGENT_OBSERVER_CLAUDE_HOOK_ROOT = Join-Path $script:LegacyIsolation 'claude-hooks'
$env:AGENT_OBSERVER_CLAUDE_SESSION_ROOT = Join-Path $script:LegacyIsolation 'claude-sessions'

function Get-TraceMs {
    param([string]$Text, [string]$Label)
    if ($Text -match ("pi rpc: " + [regex]::Escape($Label) + " at (\d+)")) {
        return [int64]$Matches[1]
    }
    return $null
}

# ---------------------------------------------------------------- Scenario Functions

function Invoke-ScenarioNormal {
    Write-Host 'worker stage=normal model_call=1/1'
    Publish-WorkerProgress -Stage 'normal'
    $normalCase = New-CaseDir 'normal'
    $normalRecord = Join-Path $normalCase.dir 'watch.jsonl'
    $normalStderr = Join-Path $normalCase.dir 'run.stderr.log'
    $normalWatch = Start-Watch -BindingsRoot $normalCase.bindings -RecordPath $normalRecord -StaleAfter 300
    try {
        $normal = Invoke-RunPi -Workspace $normalCase.ws -SessionDir $normalCase.sessions -BindingsRoot $normalCase.bindings `
            -Name 'Pi正常完成验证_日本語' -Prompt 'Reply with exactly PI_RPC_ADAPTER_OK. Then briefly explain in two sentences what a Console Observer does for coding agents. Do not use tools.' `
            -StdErrLog $normalStderr
        $normalExit = $normal.exit_code
        $normalStderrText = if (Test-Path -LiteralPath $normalStderr) { Get-Content -LiteralPath $normalStderr -Raw } else { '' }

        Assert-NoProviderFailure -EvidenceDir $normalCase.evidence -RecordPath $normalRecord -StderrPath $normalStderr

        $normalActiveFile = Get-ChildItem -Path $normalCase.evidence -Filter '*.binding-active.json' -ErrorAction SilentlyContinue | Select-Object -First 1
        $normalActiveJson = if ($normalActiveFile) { Read-JsonFile $normalActiveFile.FullName } else { $null }

        $normalProtocolFile = Get-ChildItem -Path $normalCase.evidence -Filter '*.jsonl' -ErrorAction SilentlyContinue | Select-Object -First 1
        $normalProtocol = if ($normalProtocolFile) { Get-Content -LiteralPath $normalProtocolFile.FullName -Raw } else { '' }

        $normalSnapshot = Wait-WatchPredicate -RecordPath $normalRecord -Label 'normal RESULT_READY DETACHED' `
            -EvidenceDir $normalCase.evidence -StderrPath $normalStderr -Predicate {
            param($row) $row.attention_state -eq 'RESULT_READY' -and $row.session_liveness -eq 'DETACHED'
        }
        $normalRows = Get-WatchRows -RecordPath $normalRecord
        $normalHadWorking = @($normalRows | Where-Object { $_.attention_state -eq 'WORKING' -and $_.session_liveness -eq 'LIVE_ACTIVE' }).Count -gt 0
        $normalAnyLost = @($normalRows | Where-Object { $_.session_liveness -eq 'LOST' }).Count -gt 0
        $normalFalseGreen = @($normalRows | Where-Object {
            $_.attention_state -eq 'RESULT_READY' -and $_.session_liveness -eq 'LIVE_ACTIVE'
        }).Count -gt 0
        $normalSawAgentEnd = $normalProtocol -match '"type":\s*"agent_end"'
        $normalSawAgentSettled = $normalProtocol -match '"type":\s*"agent_settled"'
        $normalExitRecordOk = ($normalProtocol -match '"type":\s*"observer_process_exit"') -and ($normalProtocol -match '"mode":"normal"')

        $settledMs = Get-TraceMs $normalStderrText 'settled'
        $stdinClosedMs = Get-TraceMs $normalStderrText 'stdin closed'
        $childExitedMs = Get-TraceMs $normalStderrText 'child exited'
        $exitRecordMs = Get-TraceMs $normalStderrText 'normal-exit record written'
        $normalOrderOk = ($null -ne $settledMs) -and ($null -ne $stdinClosedMs) -and
            ($null -ne $childExitedMs) -and ($null -ne $exitRecordMs) -and
            ($settledMs -le $stdinClosedMs) -and ($stdinClosedMs -le $childExitedMs) -and
            ($childExitedMs -le $exitRecordMs)

        $normalEvidenceOrderOk = $false
        $settledEvidenceMs = $null; $exitEvidenceMs = $null
        $normalLines = @()
        if ($normalProtocolFile) { $normalLines = @(Get-Content -LiteralPath $normalProtocolFile.FullName) }
        $lastEvidenceLine = ''
        foreach ($l in $normalLines) {
            if ($l -notmatch '^\{') { continue }
            try { $rec = $l | ConvertFrom-Json } catch { continue }
            $lastEvidenceLine = $l
            if ($rec.type -eq 'agent_settled') { $settledEvidenceMs = [int64]$rec.observed_at_unix_ms }
            if ($rec.type -eq 'observer_process_exit') { $exitEvidenceMs = [int64]$rec.observed_at_unix_ms }
        }
        if ($settledEvidenceMs -and $exitEvidenceMs) {
            $normalEvidenceOrderOk = ($settledEvidenceMs -le $exitEvidenceMs) -and
                ($lastEvidenceLine -match '"observer_process_exit"') -and
                ($lastEvidenceLine -match '"mode":"normal"')
        }

        $checkShortTask = ($normalExit -eq 0 -and $normalActiveJson -and $normalActiveJson.native_session_id -and
            $normalActiveJson.process_id -and $normalSnapshot.attention_state -eq 'RESULT_READY' -and
            $normalSnapshot.session_liveness -eq 'DETACHED' -and $normalHadWorking -and -not $normalAnyLost -and
            -not $normalFalseGreen -and $normalSawAgentEnd -and $normalSawAgentSettled -and $normalExitRecordOk)
        $checkExitOrder = ($normalOrderOk -and $normalEvidenceOrderOk)

        $passed = $checkShortTask -and $checkExitOrder
        return [pscustomobject]@{
            passed = $passed
            checks = [ordered]@{
                normal_short_task = $checkShortTask
                normal_exit_evidence_order = $checkExitOrder
            }
        }
    } finally {
        if ($normalWatch) {
            Stop-HarnessProcessRecord -Record $normalWatch.Record -Reason 'normal-watch-stop' | Out-Null
        }
    }
}

function Invoke-ScenarioKill {
    Write-Host 'worker stage=exact-kill model_call=1/1'
    Publish-WorkerProgress -Stage 'kill'
    $killCase = New-CaseDir 'kill'
    $killRecord = Join-Path $killCase.dir 'watch.jsonl'
    $killWatch = Start-Watch -BindingsRoot $killCase.bindings -RecordPath $killRecord -StaleAfter $StaleAfterSecs
    $killStderr = Join-Path $killCase.dir 'run.stderr.log'
    try {
        $killRun = Invoke-RunPi -Workspace $killCase.ws -SessionDir $killCase.sessions -BindingsRoot $killCase.bindings `
            -Name 'Pi精确强杀验证_日本語' -Prompt 'Reply with PI_RPC_KILL_TEST. Then write a 200-word technical explanation of exact runtime binding between a Console Observer and an Observer-owned Pi RPC child over JSONL stdio, covering native session id, PID, Windows creation time and the one-outstanding-prompt rule. Do not use tools.' -Background `
            -StdErrLog $killStderr

        $killActive = Wait-ForBindingActive -EvidenceDir $killCase.evidence -RecordPath $killRecord -StderrPath $killStderr
        $killPid = [int]$killActive.process_id
        $killCtimeMs = [int64]$killActive.process_started_at_unix_ms
        $killNativeId = [string]$killActive.native_session_id
        $killProc = Get-Process -Id $killPid -ErrorAction SilentlyContinue
        $killCtimeMatched = ($null -ne $killProc) -and
            ([int64]([DateTimeOffset]$killProc.StartTime).ToUnixTimeMilliseconds() -eq $killCtimeMs)
        if (-not $killCtimeMatched) { throw "Kill case: PID $killPid creation time did not match" }

        $killAliveRow = Wait-WatchPredicate -RecordPath $killRecord -Label 'watch witnessed alive WORKING' `
            -EvidenceDir $killCase.evidence -StderrPath $killStderr -Predicate {
            param($row) $row.attention_state -eq 'WORKING' -and $row.host_liveness -eq 'ALIVE' -and $row.session_liveness -eq 'LIVE_ACTIVE'
        }
        Assert-NoProviderFailure -EvidenceDir $killCase.evidence -RecordPath $killRecord -StderrPath $killStderr
        Stop-Process -Id $killPid -Force

        $killFreshLost = Wait-WatchPredicate -RecordPath $killRecord -Label 'kill FRESH DEAD LOST' `
            -EvidenceDir $killCase.evidence -StderrPath $killStderr -SkipProviderFailFast -Predicate {
            param($row) $row.attention_state -eq 'WORKING' -and $row.evidence_freshness -eq 'FRESH' -and
                $row.host_liveness -eq 'DEAD' -and $row.session_liveness -eq 'LOST'
        }
        $killAgingLost = Wait-WatchPredicate -RecordPath $killRecord -Label 'kill AGING DEAD LOST' `
            -EvidenceDir $killCase.evidence -StderrPath $killStderr -SkipProviderFailFast -Predicate {
            param($row) $row.attention_state -eq 'WORKING' -and $row.evidence_freshness -eq 'AGING' -and
                $row.host_liveness -eq 'DEAD' -and $row.session_liveness -eq 'LOST'
        }
        $killStaleLost = Wait-WatchPredicate -RecordPath $killRecord -Label 'kill STALE DEAD LOST' `
            -EvidenceDir $killCase.evidence -StderrPath $killStderr -SkipProviderFailFast -Predicate {
            param($row) $row.attention_state -eq 'WORKING' -and $row.evidence_freshness -eq 'STALE' -and
                $row.host_liveness -eq 'DEAD' -and $row.session_liveness -eq 'LOST'
        }
        Wait-HarnessProcess -Context $script:Harness -Record $killRun.Record -Stage 'exact-kill-runner-exit' | Out-Null
        $killRows = Get-WatchRows -RecordPath $killRecord
        $killAliveRow = @($killRows | Where-Object {
            $_.attention_state -eq 'WORKING' -and $_.host_liveness -eq 'ALIVE' -and $_.session_liveness -eq 'LIVE_ACTIVE'
        }) | Select-Object -First 1
        $killNeverGreen = @($killRows | Where-Object { $_.attention_state -eq 'RESULT_READY' }).Count -eq 0
        $killLaunchRecord = Get-ChildItem -Path $killCase.bindings -Filter 'pi-binding-*.json' | Select-Object -First 1
        $killLaunchJson = Read-JsonFile $killLaunchRecord.FullName
        $killPersistedAbnormalExit = $null -ne $killLaunchJson.abnormal_exit_observed_at_unix_ms
        $killStderrText = if (Test-Path -LiteralPath $killStderr) { Get-Content -LiteralPath $killStderr -Raw } else { '' }
        $killCleanupConfirmedLost = $killStderrText -match 'cleanup recorded_lost=(True|true)'

        $checkExactKill = ($killCtimeMatched -and $killNativeId -and
            $null -ne $killAliveRow -and $killAliveRow.attention_state -eq 'WORKING' -and
            $killFreshLost.attention_state -eq 'WORKING' -and $killFreshLost.host_liveness -eq 'DEAD' -and
            $killFreshLost.session_liveness -eq 'LOST' -and $killAgingLost.evidence_freshness -eq 'AGING' -and
            $killStaleLost.evidence_freshness -eq 'STALE' -and $killNeverGreen -and $killPersistedAbnormalExit -and
            $killCleanupConfirmedLost)

        $scanFile = Join-Path $killCase.dir 'restart-scan.json'
        $restartPersistedObserve = Invoke-ObserveScan -BindingsRoot $killCase.bindings -OutputPath $scanFile `
            -StaleAfter $StaleAfterSecs
        $restartPersistedPis = @($restartPersistedObserve.sessions | Where-Object { $_.agent_family -eq 'Pi' })
        $restartPersistedPi = $null
        if ($restartPersistedPis.Count -eq 1) { $restartPersistedPi = $restartPersistedPis[0] }
        $checkRestartPersisted = ($null -ne $restartPersistedPi -and
            $restartPersistedPi.host_liveness -eq 'DEAD' -and $restartPersistedPi.session_liveness -eq 'LOST' -and
            $restartPersistedPi.attention_state -eq 'WORKING' -and $restartPersistedPi.attention_state -ne 'RESULT_READY')

        $passed = $checkExactKill -and $checkRestartPersisted
        return [pscustomobject]@{
            passed = $passed
            checks = [ordered]@{
                exact_kill_fresh_aging_stale = $checkExactKill
                restart_persisted_lost = $checkRestartPersisted
            }
        }
    } finally {
        if ($killWatch) {
            Stop-HarnessProcessRecord -Record $killWatch.Record -Reason 'kill-watch-stop' | Out-Null
        }
    }
}

function Invoke-ScenarioRestartMissed {
    Write-Host 'worker stage=restart-missed model_call=1/1'
    Publish-WorkerProgress -Stage 'restart-missed'
    $missCase = New-CaseDir 'restart-missed'
    $missStderr = Join-Path $missCase.dir 'run.stderr.log'
    $missRun = Invoke-RunPi -Workspace $missCase.ws -SessionDir $missCase.sessions -BindingsRoot $missCase.bindings `
        -Name 'Pi重启错过退出验证_日本語' -Prompt 'Reply with exactly PI_RPC_MISS_TEST. Do not use tools.' -Background `
        -StdErrLog $missStderr
    $missActive = Wait-ForBindingActive -EvidenceDir $missCase.evidence -StderrPath $missStderr
    $missPid = [int]$missActive.process_id
    $missCtimeMs = [int64]$missActive.process_started_at_unix_ms
    $missProc = Get-Process -Id $missPid -ErrorAction SilentlyContinue
    $missCtimeMatched = ($null -ne $missProc) -and
        ([int64]([DateTimeOffset]$missProc.StartTime).ToUnixTimeMilliseconds() -eq $missCtimeMs)
    if (-not $missCtimeMatched) { throw 'Missed-exit case: child PID/ctime did not match before observer kill' }

    Assert-NoProviderFailure -EvidenceDir $missCase.evidence -StderrPath $missStderr
    Stop-HarnessProcessRecord -Record $missRun.Record -Reason 'intentional-observer-kill' | Out-Null
    Wait-HarnessSleep -Context $script:Harness -Stage 'restart-missed-gap' -Seconds 6
    $missChildStillAlive = $false
    $missProcAfter = Get-Process -Id $missPid -ErrorAction SilentlyContinue
    if ($missProcAfter) {
        $stillSame = ([int64]([DateTimeOffset]$missProcAfter.StartTime).ToUnixTimeMilliseconds() -eq $missCtimeMs)
        if ($stillSame) {
            $missChildStillAlive = $true
            Stop-Process -Id $missPid -Force -ErrorAction SilentlyContinue
        }
        Wait-HarnessSleep -Context $script:Harness -Stage 'restart-missed-child-stop' -Seconds 1
    }
    $missLaunchRecord = Get-ChildItem -Path $missCase.bindings -Filter 'pi-binding-*.json' | Select-Object -First 1
    $missLaunchJson = Read-JsonFile $missLaunchRecord.FullName
    $missHasAbnormalEvidence = $null -ne $missLaunchJson.abnormal_exit_observed_at_unix_ms

    $scanFile2 = Join-Path $missCase.dir 'restart-scan.json'
    $restartMissedObserve = Invoke-ObserveScan -BindingsRoot $missCase.bindings -OutputPath $scanFile2 `
        -StaleAfter $StaleAfterSecs
    $missPis = @($restartMissedObserve.sessions | Where-Object { $_.agent_family -eq 'Pi' })
    $missPi = $null
    if ($missPis.Count -eq 1) { $missPi = $missPis[0] }
    $checkRestartMissed = ($null -ne $missPi -and
        $missPi.host_liveness -eq 'UNKNOWN' -and $missPi.session_liveness -eq 'UNKNOWN' -and
        $missPi.attention_state -eq 'WORKING' -and -not $missHasAbnormalEvidence -and
        $missPi.session_liveness -ne 'LOST')

    $passed = $checkRestartMissed
    return [pscustomobject]@{
        passed = $passed
        checks = [ordered]@{
            restart_missed_exit_unknown = $checkRestartMissed
        }
    }
}

function Invoke-ScenarioParallel {
    Write-Host 'worker stage=parallel model_calls=1-2/2'
    Publish-WorkerProgress -Stage 'parallel'
    $parallelDir = Join-Path $script:RunIdDir 'parallel'
    foreach ($sub in @('ws', 'bindings', 'bindings\pi-rpc', 'sessions-a', 'sessions-b')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $parallelDir $sub) | Out-Null
    }
    $parallelWs = Join-Path $parallelDir 'ws'
    $parallelBindings = Join-Path $parallelDir 'bindings'
    $parallelEvidence = Join-Path $parallelBindings 'pi-rpc'
    $stderrA = Join-Path $parallelDir 'runner-a.stderr.log'
    $stderrB = Join-Path $parallelDir 'runner-b.stderr.log'

    $runnerA = Invoke-RunPi -Workspace $parallelWs -SessionDir (Join-Path $parallelDir 'sessions-a') `
        -BindingsRoot $parallelBindings -Name 'Pi并行会话A_日本語' -Background `
        -Prompt 'Reply with exactly PI_RPC_PARALLEL_A. Then write a 100-word explanation of why two agent sessions in the same working directory must stay independent. Do not use tools.' `
        -StdErrLog $stderrA
    Wait-ForBindingActive -EvidenceDir $parallelEvidence -StderrPath $stderrA | Out-Null
    Assert-NoProviderFailure -EvidenceDir $parallelEvidence -StderrPath $stderrA

    $runnerB = Invoke-RunPi -Workspace $parallelWs -SessionDir (Join-Path $parallelDir 'sessions-b') `
        -BindingsRoot $parallelBindings -Name 'Pi并行会话B_日本語' -Background `
        -Prompt 'Reply with exactly PI_RPC_PARALLEL_B. Then write a 100-word explanation of why runtime binding identity must use PID and creation time. Do not use tools.' `
        -StdErrLog $stderrB
    $parallelActiveFiles = Wait-ForBindingActiveCount -EvidenceDir $parallelEvidence -Count 2
    Assert-NoProviderFailure -EvidenceDir $parallelEvidence -StderrPath $stderrA
    Assert-NoProviderFailure -EvidenceDir $parallelEvidence -StderrPath $stderrB

    $parallelOverlap = $true
    $parallelBindingsSeen = @()
    foreach ($f in $parallelActiveFiles) {
        $json = Read-JsonFile $f.FullName
        $parallelBindingsSeen += $json
        $p = Get-Process -Id ([int]$json.process_id) -ErrorAction SilentlyContinue
        $ctimeMatched = ($null -ne $p) -and
            ([int64]([DateTimeOffset]$p.StartTime).ToUnixTimeMilliseconds() -eq
                [int64]$json.process_started_at_unix_ms)
        if (-not $ctimeMatched) { $parallelOverlap = $false }
    }
    # Both parallel waits carry the same combined FailFast callback. A provider failure
    # on either runner (shared evidence dir, runner A stderr or runner B stderr) aborts the
    # whole parallel scenario: Invoke-HarnessFailFast stops the entire owned process tree
    # of this scenario (both runners) before the error propagates, so the other runner is
    # never awaited to completion, no PASS can be produced, and no extra model call starts.
    $parallelProviderFailFast = {
        Assert-NoProviderFailure -EvidenceDir $parallelEvidence -StderrPath $stderrA
        Assert-NoProviderFailure -EvidenceDir $parallelEvidence -StderrPath $stderrB
        $null
    }
    Wait-HarnessProcess -Context $script:Harness -Record $runnerA.Record -Stage 'parallel-runner-a' `
        -FailFast $parallelProviderFailFast | Out-Null
    Assert-NoProviderFailure -EvidenceDir $parallelEvidence -StderrPath $stderrA
    Wait-HarnessProcess -Context $script:Harness -Record $runnerB.Record -Stage 'parallel-runner-b' `
        -FailFast $parallelProviderFailFast | Out-Null
    Assert-NoProviderFailure -EvidenceDir $parallelEvidence -StderrPath $stderrB
    $parallelExitA = Get-HarnessProcessExitCode -Record $runnerA.Record -Stage 'parallel-runner-a'
    $parallelExitB = Get-HarnessProcessExitCode -Record $runnerB.Record -Stage 'parallel-runner-b'

    $parallelRows = @()
    foreach ($activeJson in $parallelBindingsSeen) {
        $bindingId = [string]$activeJson.runtime_binding_id
        $evidencePath = Join-Path $parallelEvidence "$bindingId.jsonl"
        $launchPath = Join-Path $parallelBindings "$bindingId.json"
        $sessionFile = $null
        $sessionName = $null
        $nativeId = $null
        foreach ($l in @(Get-Content -LiteralPath $evidencePath)) {
            if ($l -notmatch '^\{') { continue }
            try { $rec = $l | ConvertFrom-Json } catch { continue }
            if ($rec.type -eq 'response' -and $rec.command -eq 'get_state' -and $rec.success) {
                $nativeId = [string]$rec.data.sessionId
                $sessionFile = [string]$rec.data.sessionFile
                $sessionName = [string]$rec.data.sessionName
            }
        }
        $parallelRows += [pscustomobject]@{
            binding_id = $bindingId
            native_session_id = $nativeId
            session_file = $sessionFile
            session_name = $sessionName
            process_id = [int]$activeJson.process_id
            process_started_at_unix_ms = [int64]$activeJson.process_started_at_unix_ms
            session_dir_matches = (Test-Path -LiteralPath $launchPath)
        }
    }

    $scanFile3 = Join-Path $parallelDir 'scan.json'
    $parallelObserve = Invoke-ObserveScan -BindingsRoot $parallelBindings -OutputPath $scanFile3 `
        -StaleAfter $StaleAfterSecs
    $parallelPis = @($parallelObserve.sessions | Where-Object { $_.agent_family -eq 'Pi' })
    $distinctIds = ($parallelRows[0].native_session_id -ne $parallelRows[1].native_session_id)
    $distinctFiles = ($parallelRows[0].session_file -ne $parallelRows[1].session_file)
    $distinctPids = ($parallelRows[0].process_id -ne $parallelRows[1].process_id)
    $distinctBindings = ($parallelRows[0].binding_id -ne $parallelRows[1].binding_id)
    $distinctCtimes = ($parallelRows[0].process_started_at_unix_ms -ne $parallelRows[1].process_started_at_unix_ms)
    $parallelNames = @($parallelRows | ForEach-Object { $_.session_name })
    $unicodeNames = ($parallelNames.Count -eq 2) -and
        ($parallelNames -ccontains 'Pi并行会话A_日本語') -and
        ($parallelNames -ccontains 'Pi并行会话B_日本語')
    $observerTwoSessions = $parallelPis.Count -eq 2
    $observerNamesOk = $false
    $observerBindingSplit = $false
    $observerPidsSplit = $false
    $observerCtimeSplit = $false
    $obsHaveSameCwd = $false
    $observerAllSettledDetached = $false
    if ($observerTwoSessions) {
        $observerNames = @($parallelPis | ForEach-Object { $_.session_display_name })
        $observerNamesOk = ($observerNames -contains 'Pi并行会话A_日本語') -and
            ($observerNames -contains 'Pi并行会话B_日本語')
        $observerBindingSplit = @($parallelPis | ForEach-Object { $_.runtime_binding_id } | Sort-Object -Unique).Count -eq 2
        $observerPidsSplit = @($parallelPis | ForEach-Object { $_.process_id } | Sort-Object -Unique).Count -eq 2
        $observerCtimeSplit = @($parallelPis | ForEach-Object { $_.process_started_at_unix_ms } | Sort-Object -Unique).Count -eq 2
        $obsHaveSameCwd = @($parallelPis | ForEach-Object { $_.cwd } | Sort-Object -Unique).Count -eq 1
        $observerAllSettledDetached = @($parallelPis | Where-Object {
            $_.attention_state -eq 'RESULT_READY' -and $_.session_liveness -eq 'DETACHED' -and $_.host_liveness -eq 'DEAD'
        }).Count -eq 2
    }
    $productionEvidenceCount = (@(Get-ChildItem -Path $parallelEvidence -Filter '*.jsonl').Count -eq 2) -and
        (@(Get-ChildItem -Path $parallelEvidence -Filter '*.binding-active.json').Count -eq 2) -and
        (@(Get-ChildItem -Path $parallelBindings -Filter 'pi-binding-*.json').Count -eq 2)

    $checkParallel = ($parallelOverlap -and $parallelExitA -eq 0 -and $parallelExitB -eq 0 -and
        $distinctIds -and $distinctFiles -and $distinctPids -and $distinctBindings -and $distinctCtimes -and
        $observerTwoSessions -and $observerNamesOk -and $observerBindingSplit -and $observerPidsSplit -and
        $observerCtimeSplit -and $obsHaveSameCwd -and $observerAllSettledDetached -and $productionEvidenceCount)
    $checkUnicode = ($unicodeNames -and $observerNamesOk)

    $passed = $checkParallel -and $checkUnicode
    return [pscustomobject]@{
        passed = $passed
        checks = [ordered]@{
            same_cwd_production_parallel = $checkParallel
            unicode_names_preserved = $checkUnicode
        }
    }
}

# ---------------------------------------------------------------- Execution
$status = 'PASS'
$acceptancePass = $false
$failureReason = $null
$timedOut = $false

try {
    $result = switch ($Scenario) {
        'normal' { Invoke-ScenarioNormal }
        'kill' { Invoke-ScenarioKill }
        'restart-missed' { Invoke-ScenarioRestartMissed }
        'parallel' { Invoke-ScenarioParallel }
    }
    $acceptancePass = [bool]$result.passed
    if (-not $acceptancePass) {
        $status = 'FAIL'
        $failureReason = "One or more scenario checks failed: $((@($result.checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })) -join ', ')"
    }
} catch {
    $msg = $_.Exception.Message
    $failureReason = $msg
    # Shared classification: only an explicit BLOCKED_BY_PROVIDER message is BLOCKED.
    # A generic harness exception (EVIDENCE_READ_FAILED, ACCESS_DENIED, ...) stays FAIL.
    $classification = Resolve-HarnessFailureClassification -Message $msg
    if ($classification.blocked) {
        $blocked = New-HarnessBlockedResult -Reason $msg
        $status = $blocked.status
        $acceptancePass = $false
        $timedOut = $false
        $failureReason = $blocked.failure_reason
    } elseif ($classification.timed_out) {
        $status = 'FAIL'
        $timedOut = $true
        $acceptancePass = $false
    } else {
        $status = 'FAIL'
        $acceptancePass = $false
    }
} finally {
    if ($script:Harness) {
        Close-HarnessLifecycle -Context $script:Harness -Reason "worker-finally status=$status"
    }
}

$elapsedSeconds = [math]::Round(([DateTimeOffset]::UtcNow - $scenarioStartedAt).TotalSeconds, 3)
$ownedRemaining = 0
$cleanupSuccess = $true
if ($script:Harness) {
    $ownedRemaining = Get-HarnessOwnedAliveCount -Context $script:Harness
    $cleanupSuccess = ($ownedRemaining -eq 0)
    try { Assert-NoHarnessProcesses -Context $script:Harness } catch {
        $cleanupSuccess = $false
        if (-not $failureReason) { $failureReason = $_.Exception.Message }
        if ($status -eq 'PASS') { $status = 'FAIL'; $acceptancePass = $false }
    }
}

$summary = New-HarnessScenarioSummary -Scenario $Scenario -Status $status -AcceptancePass:$acceptancePass `
    -TimedOut:$timedOut -ModelCallBudget $ModelCallBudget -ModelCallsStarted $script:ModelCallsStarted `
    -FailureReason $failureReason -CleanupSuccess:$cleanupSuccess -OwnedProcessesRemaining $ownedRemaining `
    -RunRoot $script:RunIdDir -ElapsedSeconds $elapsedSeconds
Publish-WorkerProgress -Stage "summary:$status"

$summaryJsonPath = Join-Path $script:RunIdDir 'scenario-summary.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryJsonPath -Encoding utf8
$summary | ConvertTo-Json -Depth 6

if ($status -eq 'BLOCKED') {
    exit (Get-HarnessBlockedExitCode)
}
if ($status -ne 'PASS') {
    exit 1
}
