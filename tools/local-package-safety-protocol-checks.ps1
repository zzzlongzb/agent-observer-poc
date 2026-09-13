# Pure in-process protocol checks for Daily-use Local Package v0.1 R3 Safety
# Repair 2. Everything runs inside THIS PowerShell process: AST parsing,
# pure-function assertions and TEMP-file fixture cases only. No worker, no
# fixture child, no cargo, no dotnet, no node, no observer is started, and no
# network or model call is made.
#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local-package-harness.ps1')

$protocolChecks = New-Object System.Collections.Generic.List[object]
$protocolFailures = New-Object System.Collections.Generic.List[string]

function Add-ProtocolCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Pass,
        [string]$Detail = ''
    )
    [void]$script:protocolChecks.Add([pscustomobject][ordered]@{
        check = $Name
        pass = [bool]$Pass
        detail = $Detail
    })
    if (-not $Pass) {
        [void]$script:protocolFailures.Add(("$Name : $Detail"))
    }
}

function Test-ProtocolThrows {
    param([Parameter(Mandatory)][scriptblock]$Body)
    try {
        & $Body | Out-Null
        return $false
    } catch {
        return $true
    }
}

# ---------------------------------------------------------------------------
# 0. AST parse of every modified script (current-process Parser::ParseFile).
# ---------------------------------------------------------------------------
$scriptFiles = @(
    'tools/harness-lifecycle.ps1',
    'tools/local-package-harness.ps1',
    'tools/run-local-package-regressions.ps1',
    'tools/local-package-safety-worker.ps1',
    'tools/local-package-safety-static-check.ps1',
    'tools/local-package-safety-protocol-checks.ps1',
    'tools/fixtures/local-safety-fixture-canary.ps1',
    'tools/fixtures/local-safety-fixture-fail-first.ps1',
    'tools/fixtures/local-safety-fixture-infinite-loop.ps1',
    'tools/fixtures/local-safety-fixture-silent-hang.ps1'
)
$parseErrorTotal = 0
foreach ($rel in $scriptFiles) {
    $path = Join-Path $repoRoot $rel
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $parseErrorTotal += $errors.Count
        foreach ($err in $errors) {
            [void]$script:protocolFailures.Add(("ast-parse {0} : {1}" -f $rel, $err.Message))
        }
    }
}
Add-ProtocolCheck -Name 'ast-parse-all-modified-scripts' -Pass ($parseErrorTotal -eq 0) -Detail ("parse_errors=$parseErrorTotal")

# ---------------------------------------------------------------------------
# 1. Log-ownership protocol: SupervisorPreLaunch vs WorkerPostLaunch (pure).
# ---------------------------------------------------------------------------
$supervisorNames = Get-LocalSafetyStaleFileNames -Phase SupervisorPreLaunch
$workerNames = Get-LocalSafetyStaleFileNames -Phase WorkerPostLaunch
$expectedAll = @('worker-stdout.log', 'worker-stderr.log', 'worker-summary.json', 'fixture-stream-stdout.log', 'fixture-stream-stderr.log', 'final-summary.json')
$expectedWorker = @('worker-summary.json', 'fixture-stream-stdout.log', 'fixture-stream-stderr.log', 'final-summary.json')
$transportNames = @('worker-stdout.log', 'worker-stderr.log')

$supervisorOk = ($supervisorNames.Count -eq 6)
foreach ($name in $expectedAll) { if ($supervisorNames -notcontains $name) { $supervisorOk = $false } }
Add-ProtocolCheck -Name 'phase-pure-supervisorprelaunch-forbids-all-six' -Pass $supervisorOk `
    -Detail ("names={0}" -f ($supervisorNames -join ','))

$workerOk = ($workerNames.Count -eq 4)
foreach ($name in $expectedWorker) { if ($workerNames -notcontains $name) { $workerOk = $false } }
foreach ($name in $transportNames) { if ($workerNames -contains $name) { $workerOk = $false } }
Add-ProtocolCheck -Name 'phase-pure-workerpostlaunch-allows-only-transport-logs' -Pass $workerOk `
    -Detail ("names={0}" -f ($workerNames -join ','))

$diffOk = $true
foreach ($name in $supervisorNames) { if ($workerNames -notcontains $name -and $transportNames -notcontains $name) { $diffOk = $false } }
foreach ($name in $transportNames) { if ($supervisorNames -notcontains $name) { $diffOk = $false } }
Add-ProtocolCheck -Name 'phase-pure-difference-is-exactly-the-two-transport-logs' -Pass $diffOk `
    -Detail ("supervisor_only={0} worker={1}" -f (($supervisorNames | Where-Object { $workerNames -notcontains $_ }) -join ','), ($workerNames -join ','))

# ---------------------------------------------------------------------------
# 1b. Behavioral stale-file checks in a disposable TEMP root (files only).
# ---------------------------------------------------------------------------
$tempBase = Join-Path ([IO.Path]::GetTempPath()) ('r3r2-protocol-checks-' + [Guid]::NewGuid().ToString('n'))
try {
    [IO.Directory]::CreateDirectory($tempBase) | Out-Null
    $tempAllowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())

    # Case A: empty evidence root -> both phases must allow.
    $caseRoot = Join-Path $tempBase 'case-empty'
    $caseRun = Join-Path $caseRoot 'run'
    [IO.Directory]::CreateDirectory($caseRun) | Out-Null
    $a1 = -not (Test-ProtocolThrows -Body { Assert-LocalSafetyEvidenceRootHasNoStaleFiles -EvidenceRoot $caseRoot -RunDirectory $caseRun -Phase SupervisorPreLaunch })
    $a2 = -not (Test-ProtocolThrows -Body { Assert-LocalSafetyEvidenceRootHasNoStaleFiles -EvidenceRoot $caseRoot -RunDirectory $caseRun -Phase WorkerPostLaunch })
    Add-ProtocolCheck -Name 'phase-behavior-empty-root-allows-both-phases' -Pass ($a1 -and $a2) -Detail ("supervisor_ok=$a1 worker_ok=$a2")

    # Case B: only the two transport logs exist (created by the current
    # supervisor launch flow) -> WorkerPostLaunch must allow, SupervisorPreLaunch must refuse.
    $caseRoot = Join-Path $tempBase 'case-transport'
    $caseRun = Join-Path $caseRoot 'run'
    [IO.Directory]::CreateDirectory($caseRun) | Out-Null
    [IO.File]::WriteAllText((Join-Path $caseRun 'worker-stdout.log'), 'x')
    [IO.File]::WriteAllText((Join-Path $caseRun 'worker-stderr.log'), 'x')
    $b1 = Test-ProtocolThrows -Body { Assert-LocalSafetyEvidenceRootHasNoStaleFiles -EvidenceRoot $caseRoot -RunDirectory $caseRun -Phase SupervisorPreLaunch }
    $b2 = -not (Test-ProtocolThrows -Body { Assert-LocalSafetyEvidenceRootHasNoStaleFiles -EvidenceRoot $caseRoot -RunDirectory $caseRun -Phase WorkerPostLaunch })
    Add-ProtocolCheck -Name 'phase-behavior-transport-logs-supervisor-refuses-worker-allows' -Pass ($b1 -and $b2) -Detail ("supervisor_refuses=$b1 worker_allows=$b2")

    # Case C: each remaining official output must still be refused by
    # WorkerPostLaunch (worker must not mistake them for its own transport logs).
    $caseCIterable = @('worker-summary.json', 'fixture-stream-stdout.log', 'fixture-stream-stderr.log', 'final-summary.json')
    $caseCDetail = New-Object System.Collections.Generic.List[string]
    $caseCAll = $true
    foreach ($staleName in $caseCIterable) {
        $caseRoot = Join-Path $tempBase ('case-' + $staleName)
        $caseRun = Join-Path $caseRoot 'run'
        [IO.Directory]::CreateDirectory($caseRun) | Out-Null
        [IO.File]::WriteAllText((Join-Path $caseRun $staleName), 'x')
        $refused = Test-ProtocolThrows -Body { Assert-LocalSafetyEvidenceRootHasNoStaleFiles -EvidenceRoot $caseRoot -RunDirectory $caseRun -Phase WorkerPostLaunch }
        if (-not $refused) { $caseCAll = $false }
        [void]$caseCDetail.Add(("{0}={1}" -f $staleName, $refused))
    }
    Add-ProtocolCheck -Name 'phase-behavior-workerpostlaunch-still-refuses-official-outputs' -Pass $caseCAll `
        -Detail ($caseCDetail -join ',')
}
finally {
    try { $null = Remove-LocalPackageDirectorySafely -Path $tempBase -AllowedRoots @($tempAllowed) -RepoRoot $repoRoot } catch { }
}

# ---------------------------------------------------------------------------
# 2. Deadline verdict: finished_at past the absolute deadline can never succeed.
# ---------------------------------------------------------------------------
$dlBase = [DateTimeOffset]::Parse('2026-09-01T00:00:00Z')
$dlDeadline = $dlBase.AddSeconds(110)

$v1 = Get-LocalSafetyDeadlineVerdict -FinishedAt $dlDeadline.AddMilliseconds(-500) -AbsoluteDeadlineAt $dlDeadline -BaseTimeoutDetected $false
Add-ProtocolCheck -Name 'deadline-verdict-in-time-success-allowed' -Pass ($v1.success_allowed -and (-not $v1.timeout_detected) -and $v1.final_status -eq 'OK' -and $v1.deadline_respected) -Detail 'finished 500ms before deadline'

$v2 = Get-LocalSafetyDeadlineVerdict -FinishedAt $dlDeadline -AbsoluteDeadlineAt $dlDeadline -BaseTimeoutDetected $false
Add-ProtocolCheck -Name 'deadline-verdict-boundary-inclusive-success' -Pass ($v2.success_allowed -and (-not $v2.timeout_detected) -and $v2.deadline_respected) -Detail 'finished exactly at deadline (<= is success)'

$v3 = Get-LocalSafetyDeadlineVerdict -FinishedAt $dlDeadline.AddMilliseconds(1) -AbsoluteDeadlineAt $dlDeadline -BaseTimeoutDetected $false
Add-ProtocolCheck -Name 'deadline-verdict-overrun-forces-timeout' -Pass ((-not $v3.success_allowed) -and $v3.timeout_detected -and $v3.final_status -eq 'TIMEOUT' -and (-not $v3.deadline_respected)) -Detail 'finished 1ms past deadline with no other timeout observed'

$v4 = Get-LocalSafetyDeadlineVerdict -FinishedAt $dlDeadline.AddSeconds(-30) -AbsoluteDeadlineAt $dlDeadline -BaseTimeoutDetected $true
Add-ProtocolCheck -Name 'deadline-verdict-base-timeout-forces-timeout' -Pass ((-not $v4.success_allowed) -and $v4.timeout_detected -and $v4.final_status -eq 'TIMEOUT') -Detail 'timeout already detected before deadline'

# ---------------------------------------------------------------------------
# 3. Marker/summary terminal agreement: inconsistency can never succeed.
# ---------------------------------------------------------------------------
$mkSummary = {
    param([string]$RunId = 'run-agree', [string]$FinalStatus = 'OFFLINE', [int]$DurationMs = 5000, [string]$FinishedAt = '2026-09-01T00:00:05.0000000+00:00')
    [pscustomobject][ordered]@{
        schema_version = 'local-package-safety-summary/v2'
        generated_by = 'run-local-package-regressions.ps1'
        run_id = $RunId
        supervisor_pid = 4242
        supervisor_creation_time = '2026-09-01T00:00:00.0000000+00:00'
        started_at = '2026-09-01T00:00:00.0000000+00:00'
        finished_at = $FinishedAt
        actual_duration_ms = $DurationMs
        absolute_deadline_at = '2026-09-01T00:01:50.0000000+00:00'
        attempt_count = 1
        worker_start_count = 1
        start_gate_consumed = $true
        automatic_retries = 0
        final_status = $FinalStatus
        timeout_detected = $false
    }
}
$mkMarker = {
    param([string]$RunId = 'run-agree', [string]$Status = 'FINISHED', $FinalStatus = 'OFFLINE', [string]$FinishedAt = '2026-09-01T00:00:05.1000000+00:00')
    [pscustomobject][ordered]@{
        run_id = $RunId
        attempt_number = 1
        created_at = '2026-09-01T00:00:00.0000000+00:00'
        supervisor_pid = 4242
        supervisor_creation_time = '2026-09-01T00:00:00.0000000+00:00'
        status = $Status
        finished_at = $FinishedAt
        final_status = $FinalStatus
    }
}

$agreeOk = (& {
    $reason = Test-LocalSafetyMarkerSummaryAgreement -Summary (& $mkSummary) -Marker (& $mkMarker)
    return ($null -eq $reason)
})
Add-ProtocolCheck -Name 'marker-summary-agreement-consistent-case-passes' -Pass $agreeOk -Detail 'consistent marker+summary returns null reason'

$mismatchCases = @(
    @{ label = 'run-id-mismatch'; summary = (& $mkSummary -RunId 'run-a'); marker = (& $mkMarker -RunId 'run-b') },
    @{ label = 'marker-status-running'; summary = (& $mkSummary); marker = (& $mkMarker -Status 'RUNNING') },
    @{ label = 'final-status-mismatch'; summary = (& $mkSummary -FinalStatus 'OFFLINE'); marker = (& $mkMarker -FinalStatus 'FAIL') },
    @{ label = 'marker-final-status-empty'; summary = (& $mkSummary); marker = (& $mkMarker -FinalStatus $null) },
    @{ label = 'duration-mismatch'; summary = (& $mkSummary -DurationMs 9999); marker = (& $mkMarker) },
    @{ label = 'marker-null'; summary = (& $mkSummary); marker = $null },
    @{ label = 'summary-null'; summary = $null; marker = (& $mkMarker) }
)
$mismatchAll = $true
$mismatchDetail = New-Object System.Collections.Generic.List[string]
foreach ($case in $mismatchCases) {
    $reason = $null
    $directThrew = $false
    try {
        $reason = Test-LocalSafetyMarkerSummaryAgreement -Summary $case.summary -Marker $case.marker
    } catch {
        # Null summary is rejected at binding time; that is also a refusal.
        $directThrew = $true
        $reason = ('rejected: ' + $_.Exception.Message)
    }
    if (-not $reason) { $mismatchAll = $false }
    $assertThrew = Test-ProtocolThrows -Body { Assert-LocalSafetyMarkerSummaryAgreement -Summary $case.summary -Marker $case.marker }
    if (-not $assertThrew) { $mismatchAll = $false }
    [void]$mismatchDetail.Add(("{0}=reason:{1},assert_threw:{2}" -f $case.label, [bool]$reason, $assertThrew))
}
Add-ProtocolCheck -Name 'marker-summary-mismatch-can-never-succeed' -Pass $mismatchAll -Detail ($mismatchDetail -join ',')

$consistencyOk = $true
$goodReason = Test-LocalSafetyFinalSummaryConsistency -Summary (& $mkSummary) -Marker (& $mkMarker)
if ($null -ne $goodReason) { $consistencyOk = $false }
$badSummary = (& $mkSummary)
$badSummary.PSObject.Properties.Remove('worker_start_count')
if ($null -eq (Test-LocalSafetyFinalSummaryConsistency -Summary $badSummary)) { $consistencyOk = $false }
if ($null -eq (Test-LocalSafetyFinalSummaryConsistency -Summary (& $mkSummary -DurationMs 1234))) { $consistencyOk = $false }
if ($null -eq (Test-LocalSafetyFinalSummaryConsistency -Summary (& $mkSummary) -Marker (& $mkMarker -RunId 'other-run'))) { $consistencyOk = $false }
Add-ProtocolCheck -Name 'final-summary-consistency-rejects-invalid-summaries' -Pass $consistencyOk -Detail 'good passes; missing field / wrong duration / marker run_id mismatch all rejected'

# ---------------------------------------------------------------------------
# 4. Direct-run parameters: no Mandatory prompt, -Supervised checked first.
# ---------------------------------------------------------------------------
$entryScripts = @(
    @{ rel = 'tools/local-package-safety-worker.ps1'; first = 'worker' },
    @{ rel = 'tools/fixtures/local-safety-fixture-canary.ps1'; first = 'fixture' },
    @{ rel = 'tools/fixtures/local-safety-fixture-fail-first.ps1'; first = 'fixture' },
    @{ rel = 'tools/fixtures/local-safety-fixture-infinite-loop.ps1'; first = 'fixture' },
    @{ rel = 'tools/fixtures/local-safety-fixture-silent-hang.ps1'; first = 'fixture' }
)
$paramDetail = New-Object System.Collections.Generic.List[string]
$paramAllOk = $true
foreach ($entry in $entryScripts) {
    $path = Join-Path $repoRoot $entry.rel
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $entryOk = $true
    if ($errors -and $errors.Count -gt 0) { $entryOk = $false }
    $paramBlock = $ast.ParamBlock
    if ($null -eq $paramBlock) { $entryOk = $false }
    else {
        $paramText = [string]$paramBlock.Extent.Text
        if ($paramText -match 'Mandatory') { $entryOk = $false }
    }
    # The first IfStatement of the body must be the -Supervised refusal.
    $firstIf = $ast.Find({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] }, $true)
    if ($null -eq $firstIf) { $entryOk = $false }
    else {
        # IfStatementAst keeps conditions in .Clauses; the whole extent of the
        # first if must be the -Supervised refusal check.
        $ifText = [string]$firstIf.Extent.Text
        if ($ifText -notmatch 'Supervised') { $entryOk = $false }
    }
    if (-not $entryOk) { $paramAllOk = $false }
    [void]$paramDetail.Add(("{0}={1}" -f (Split-Path -Leaf $entry.rel), $entryOk))
}
Add-ProtocolCheck -Name 'direct-run-no-mandatory-supervised-checked-first' -Pass $paramAllOk -Detail ($paramDetail -join ',')

# ---------------------------------------------------------------------------
# 5. Static checker: read-only by default, explicit -OutputPath only.
# ---------------------------------------------------------------------------
$staticCheckPath = Join-Path $repoRoot 'tools/local-package-safety-static-check.ps1'
$tokens = $null
$errors = $null
$staticAst = [Management.Automation.Language.Parser]::ParseFile($staticCheckPath, [ref]$tokens, [ref]$errors)
$staticOk = $true
$staticNotes = New-Object System.Collections.Generic.List[string]
if ($errors -and $errors.Count -gt 0) { $staticOk = $false; [void]$staticNotes.Add('parse-errors') }
$staticParamBlock = $staticAst.ParamBlock
if ($null -eq $staticParamBlock) { $staticOk = $false; [void]$staticNotes.Add('no-param-block') }
else {
    $staticParamText = [string]$staticParamBlock.Extent.Text
    if ($staticParamText -match 'Mandatory') { $staticOk = $false; [void]$staticNotes.Add('mandatory-param-present') }
    if (-not ($staticParamText.Contains('$OutputPath') -and $staticParamText.Contains(" = ''"))) { $staticOk = $false; [void]$staticNotes.Add('outputpath-default-not-empty-string') }
}
# Every write-capable call site must sit inside an `if ($OutputPath)` guard.
$writeMemberNames = @('WriteAllText', 'WriteAllLines', 'AppendAllText', 'AppendText', 'CreateDirectory', 'Delete', 'Move', 'Replace', 'Open', 'OpenWrite', 'Create')
$writeCommandNames = @('Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Remove-Item', 'Move-Item', 'Copy-Item', 'Clear-Content', 'Export-Clixml', 'Export-Csv')
$writeNodes = New-Object System.Collections.Generic.List[object]
foreach ($node in $staticAst.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
    $memberName = $null
    try { $memberName = [string]$node.Member.Extent.Text } catch { $memberName = $null }
    if ($writeMemberNames -contains $memberName) { [void]$writeNodes.Add($node) }
}
foreach ($node in $staticAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    if ($writeCommandNames -contains $node.GetCommandName()) { [void]$writeNodes.Add($node) }
}
$unguardedWrites = New-Object System.Collections.Generic.List[string]
foreach ($node in $writeNodes) {
    $cursor = $node.Parent
    $guarded = $false
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.IfStatementAst]) {
            # IfStatementAst keeps conditions in .Clauses; a guard is an
            # enclosing if whose extent references $OutputPath.
            $ifText = [string]$cursor.Extent.Text
            if ($ifText -match 'OutputPath') { $guarded = $true; break }
        }
        $cursor = $cursor.Parent
    }
    if (-not $guarded) { [void]$unguardedWrites.Add(($node.Extent.Text -replace '\s+', ' ')) }
}
if ($unguardedWrites.Count -gt 0) {
    $staticOk = $false
    [void]$staticNotes.Add(("unguarded-writes={0}" -f ($unguardedWrites -join ' | ')))
}
if ($writeNodes.Count -eq 0) { $staticOk = $false; [void]$staticNotes.Add('no-write-sites-found-scan-broken') }
Add-ProtocolCheck -Name 'static-checker-default-is-read-only' -Pass $staticOk `
    -Detail ("write_sites={0}; {1}" -f $writeNodes.Count, ($(if ($staticNotes.Count -gt 0) { $staticNotes -join ';' } else { 'all writes guarded by if ($OutputPath)' })))

# ---------------------------------------------------------------------------
# 6. owned-processes.jsonl single-writer protocol (source-level invariants).
# ---------------------------------------------------------------------------
$workerSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'tools/local-package-safety-worker.ps1'))
$ownedOk = $true
$ownedNotes = New-Object System.Collections.Generic.List[string]
if ($workerSource -notmatch 'Initialize-LocalOwnedRecordsWriter') { $ownedOk = $false; [void]$ownedNotes.Add('no-single-writer-init') }
if ($workerSource -notmatch 'FileMode\]::CreateNew') { $ownedOk = $false; [void]$ownedNotes.Add('no-createnew-open') }
if ($workerSource -match 'FileMode\]::Append') { $ownedOk = $false; [void]$ownedNotes.Add('filemode-append-present') }
if ($workerSource -match 'AppendAllText') { $ownedOk = $false; [void]$ownedNotes.Add('appendalltext-present') }
if ($workerSource -match ('WriteAllLines\(\s*\$ownedRecordsPath|WriteAllText\(\s*\$ownedRecordsPath|Append' + 'AllText\(\s*\$ownedRecordsPath')) { $ownedOk = $false; [void]$ownedNotes.Add('owned-records-path-bulk-rewrite') }
if ($workerSource -notmatch 'OwnedRecordsSeen') { $ownedOk = $false; [void]$ownedNotes.Add('no-identity-hashset-dedupe') }
if ($workerSource -notmatch 'Flush\(\$true\)') { $ownedOk = $false; [void]$ownedNotes.Add('no-flush-to-disk') }
if ($workerSource -notmatch 'Close-LocalOwnedRecordsWriter') { $ownedOk = $false; [void]$ownedNotes.Add('no-finally-close') }
Add-ProtocolCheck -Name 'owned-process-evidence-single-writer-append-only' -Pass $ownedOk `
    -Detail ($(if ($ownedNotes.Count -gt 0) { $ownedNotes -join ';' } else { 'CreateNew once + per-record flush(true) + HashSet dedupe + finally close; no Append/WriteAllLines' }))

# ---------------------------------------------------------------------------
# Result (stdout only; this checker never writes files).
# ---------------------------------------------------------------------------
$allPassed = ($script:protocolFailures.Count -eq 0)
$result = [pscustomobject][ordered]@{
    protocol_check = 'daily-use-local-package-v0.1-r3-safety-r2'
    mode = 'pure in-process checks: AST parse + pure functions + TEMP-file cases; no child processes'
    passed = [bool]$allPassed
    check_count = [int]$script:protocolChecks.Count
    failure_count = [int]$script:protocolFailures.Count
    checks = [object[]]$script:protocolChecks.ToArray()
}
Write-Output ($result | ConvertTo-Json -Depth 6)
if (-not $allPassed) {
    Write-Output 'PROTOCOL CHECKS FAILED:'
    foreach ($failure in $script:protocolFailures.ToArray()) { Write-Output (" - $failure") }
    exit 1
}
Write-Output 'PROTOCOL CHECKS PASSED'
exit 0
