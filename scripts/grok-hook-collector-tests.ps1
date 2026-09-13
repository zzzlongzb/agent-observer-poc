# Offline regression tests for integrations/grok-observer-hook.ps1.
#
# Feeds crafted hook envelopes to the collector through a redirected stdin and
# asserts the metadata it persists. No model, network, or user directory is
# touched: the collector writes under AGENT_OBSERVER_GROK_HOOK_ROOT, which is
# redirected to a scratch directory under $env:TEMP.
#
# The core invariant under test: only a genuinely empty backgroundTasks array
# and a genuinely empty sessionCrons array may be persisted as []. A missing,
# null, string, or malformed object payload must stay null so the Observer can
# tell "no background work" apart from "background-work evidence missing" and
# therefore never produce a false green.
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$collector = Join-Path $repoRoot 'integrations\grok-observer-hook.ps1'
$scratch = Join-Path $env:TEMP ("agent-observer-grok-collector-tests-" + [Guid]::NewGuid().ToString('N'))
$previousRoot = $env:AGENT_OBSERVER_GROK_HOOK_ROOT
$failures = @()

function Invoke-Collector {
    param([Parameter(Mandatory)][string]$Payload)

    $reader = [System.IO.StringReader]::new($Payload)
    [Console]::SetIn($reader)
    & $collector | Out-Null
}

function Get-CollectedRecord {
    param([Parameter(Mandatory)][string]$SessionId)

    $path = Join-Path (Join-Path $scratch $SessionId) '*'
    $file = Get-ChildItem -Path $path -Filter '*.json' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $file) { return $null }
    return Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
}

# name -> @{ payload = <envelope json>; background = 'empty'|'null'|'one'|'two'; crons = 'empty'|'null'|'one' }
$cases = [ordered]@{
    # 1. [] stays []
    empty_arrays_are_empty           = @{ payload = '{"hookEventName":"stop","sessionId":"t-empty","promptId":"p1","reason":"end_turn","backgroundTasks":[],"sessionCrons":[]}'; background = 'empty'; crons = 'empty' }
    # 2. [null] becomes null
    single_null_task_is_null         = @{ payload = '{"hookEventName":"stop","sessionId":"t-null-task","promptId":"p1","reason":"end_turn","backgroundTasks":[null],"sessionCrons":[]}'; background = 'null'; crons = 'empty' }
    # 3. [null, null] becomes null
    double_null_tasks_is_null        = @{ payload = '{"hookEventName":"stop","sessionId":"t-double-null-tasks","promptId":"p1","reason":"end_turn","backgroundTasks":[null,null],"sessionCrons":[]}'; background = 'null'; crons = 'empty' }
    # 4. [{}] becomes null
    empty_object_task_is_null        = @{ payload = '{"hookEventName":"stop","sessionId":"t-empty-obj-task","promptId":"p1","reason":"end_turn","backgroundTasks":[{}],"sessionCrons":[]}'; background = 'null'; crons = 'empty' }
    # 5. [{"unexpected":true}] becomes null
    unexpected_task_is_null          = @{ payload = '{"hookEventName":"stop","sessionId":"t-unexp-task","promptId":"p1","reason":"end_turn","backgroundTasks":[{"unexpected":true}],"sessionCrons":[]}'; background = 'null'; crons = 'empty' }
    # 6. string, object, missing, null all stay null
    null_arrays_stay_null            = @{ payload = '{"hookEventName":"stop","sessionId":"t-null","promptId":"p1","reason":"end_turn","backgroundTasks":null,"sessionCrons":null}'; background = 'null'; crons = 'null' }
    missing_arrays_stay_null         = @{ payload = '{"hookEventName":"stop","sessionId":"t-missing","promptId":"p1","reason":"end_turn"}'; background = 'null'; crons = 'null' }
    object_payload_stays_null        = @{ payload = '{"hookEventName":"stop","sessionId":"t-object","promptId":"p1","reason":"end_turn","backgroundTasks":{"unexpected":true},"sessionCrons":[]}'; background = 'null'; crons = 'empty' }
    string_payload_stays_null        = @{ payload = '{"hookEventName":"stop","sessionId":"t-string","promptId":"p1","reason":"end_turn","backgroundTasks":"running","sessionCrons":[]}'; background = 'null'; crons = 'empty' }
    bare_object_stays_null           = @{ payload = '{"hookEventName":"stop","sessionId":"t-bare","promptId":"p1","reason":"end_turn","backgroundTasks":{"id":"t1","type":"shell","status":"running"},"sessionCrons":[]}'; background = 'null'; crons = 'empty' }
    # 7. single valid background task stays non-empty array
    one_task_is_an_array             = @{ payload = '{"hookEventName":"stop","sessionId":"t-one","promptId":"p1","reason":"end_turn","backgroundTasks":[{"id":"t1","type":"shell","status":"running"}],"sessionCrons":[]}'; background = 'one'; crons = 'empty' }
    # 8. multiple valid background tasks stay non-empty array
    two_tasks_are_an_array           = @{ payload = '{"hookEventName":"stop","sessionId":"t-two","promptId":"p1","reason":"end_turn","backgroundTasks":[{"id":"t1","type":"shell","status":"running"},{"id":"t2","type":"shell","status":"done"}],"sessionCrons":[]}'; background = 'two'; crons = 'empty' }
    # 9. single valid cron stays non-empty array
    one_cron_is_an_array             = @{ payload = '{"hookEventName":"stop","sessionId":"t-one-cron","promptId":"p1","reason":"end_turn","backgroundTasks":[],"sessionCrons":[{"id":"c1","schedule":"* * * * *","recurring":true}]}'; background = 'empty'; crons = 'one' }
    # 10. malformed non-empty cron array becomes null
    null_cron_is_null                = @{ payload = '{"hookEventName":"stop","sessionId":"t-null-cron","promptId":"p1","reason":"end_turn","backgroundTasks":[],"sessionCrons":[null]}'; background = 'empty'; crons = 'null' }
    empty_obj_cron_is_null           = @{ payload = '{"hookEventName":"stop","sessionId":"t-empty-obj-cron","promptId":"p1","reason":"end_turn","backgroundTasks":[],"sessionCrons":[{}]}'; background = 'empty'; crons = 'null' }
    # 11. mixed valid/invalid keeps valid items and stays non-empty array
    mixed_tasks_keep_valid           = @{ payload = '{"hookEventName":"stop","sessionId":"t-mixed-tasks","promptId":"p1","reason":"end_turn","backgroundTasks":[null,{},{"id":"t1","type":"shell","status":"running"}],"sessionCrons":[]}'; background = 'one'; crons = 'empty' }
    # 15. subagent events are dropped
    subagent_events_are_dropped      = @{ payload = '{"hookEventName":"stop","sessionId":"t-subagent","promptId":"p1","reason":"end_turn","subagentType":"explore","backgroundTasks":[],"sessionCrons":[]}'; background = 'dropped'; crons = 'dropped' }
}

try {
    $env:AGENT_OBSERVER_GROK_HOOK_ROOT = $scratch
    foreach ($name in $cases.Keys) {
        $case = $cases[$name]
        Invoke-Collector -Payload $case.payload
        $record = Get-CollectedRecord -SessionId ($case.payload | ConvertFrom-Json).sessionId

        if ($case.background -eq 'dropped') {
            if ($record) { $failures += ($name + ': subagent event should not be recorded') }
            continue
        }
        if (-not $record) { $failures += ($name + ': no record was written'); continue }

        $background = $record.background_tasks
        $crons = $record.session_crons
        $actualBackground = if ($null -eq $background) { 'null' }
            elseif ($background -is [array] -and $background.Count -eq 0) { 'empty' }
            elseif ($background -is [array] -and $background.Count -eq 1) { 'one' }
            elseif ($background -is [array] -and $background.Count -eq 2) { 'two' }
            else { 'other' }
        $actualCrons = if ($null -eq $crons) { 'null' }
            elseif ($crons -is [array] -and $crons.Count -eq 0) { 'empty' }
            elseif ($crons -is [array] -and $crons.Count -eq 1) { 'one' }
            else { 'other' }

        if ($actualBackground -ne $case.background) {
            $failures += ($name + ": background_tasks expected '$($case.background)', got '$actualBackground'")
        }
        if ($actualCrons -ne $case.crons) {
            $failures += ($name + ": session_crons expected '$($case.crons)', got '$actualCrons'")
        }

        # Privacy guard: the persisted record must stay metadata-only and error-free.
        $json = $record | ConvertTo-Json -Compress -Depth 8
        foreach ($secret in @('secret prompt body', 'secret assistant reply', 'secret error text')) {
            if ($json -like "*$secret*") { $failures += ($name + ": record leaked '$secret'") }
        }
        if ($record.PSObject.Properties.Name -contains 'error') {
            $failures += ($name + ": record must not contain 'error' property")
        }
    }

    # 12 & 13. Payload with sensitive error string or error object must not persist error text or object
    Invoke-Collector -Payload '{"hookEventName":"stop_failure","sessionId":"t-error-str","promptId":"p2","reason":"error","error":"secret error text with internal stack /srv/app/auth.js:42"}'
    $errStrRecord = Get-CollectedRecord -SessionId 't-error-str'
    if (-not $errStrRecord) {
        $failures += 'error_str: no record was written'
    } else {
        $errStrJson = $errStrRecord | ConvertTo-Json -Compress -Depth 8
        if ($errStrJson -like '*secret error text*') { $failures += 'error_str: record leaked error string' }
        if ($errStrRecord.PSObject.Properties.Name -contains 'error') { $failures += 'error_str: record contains error property' }
    }

    Invoke-Collector -Payload '{"hookEventName":"stop_failure","sessionId":"t-error-obj","promptId":"p3","reason":"error","error":{"message":"secret error obj message","code":500,"details":"sensitive db info"}}'
    $errObjRecord = Get-CollectedRecord -SessionId 't-error-obj'
    if (-not $errObjRecord) {
        $failures += 'error_obj: no record was written'
    } else {
        $errObjJson = $errObjRecord | ConvertTo-Json -Compress -Depth 8
        if ($errObjJson -like '*secret error obj message*') { $failures += 'error_obj: record leaked error object message' }
        if ($errObjJson -like '*sensitive db info*') { $failures += 'error_obj: record leaked error object details' }
        if ($errObjRecord.PSObject.Properties.Name -contains 'error') { $failures += 'error_obj: record contains error property' }
    }

    # 14. A payload that carries prompt/assistant/tool body content must never persist it.
    Invoke-Collector -Payload '{"hookEventName":"user_prompt_submit","sessionId":"t-privacy","promptId":"p9","prompt":"secret prompt body","messages":[{"role":"assistant","content":"secret assistant reply"}],"toolCall":{"arguments":"secret tool args"}}'
    $privacy = Get-CollectedRecord -SessionId 't-privacy'
    if (-not $privacy) {
        $failures += 'privacy: no record was written'
    } else {
        $privacyJson = $privacy | ConvertTo-Json -Compress -Depth 8
        foreach ($secret in @('secret prompt body', 'secret assistant reply', 'secret tool args')) {
            if ($privacyJson -like "*$secret*") { $failures += "privacy: record leaked '$secret'" }
        }
    }
} finally {
    if ($previousRoot) { $env:AGENT_OBSERVER_GROK_HOOK_ROOT = $previousRoot }
    else { Remove-Item Env:\AGENT_OBSERVER_GROK_HOOK_ROOT -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force -LiteralPath $scratch -ErrorAction SilentlyContinue
}

$total = ($cases.Keys | Measure-Object).Count + 3
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { "FAIL $_" }
    throw "grok collector tests: $($failures.Count) of $total checks failed"
}

"grok collector tests: $total/$total passed"
