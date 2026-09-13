# Regression test for tools/verify-evidence-run-id.ps1 (Daily-use Local
# Package v0.1 Repair 2).
#
# Verifies the real run_id verifier through its process exit code (not console
# text) for:
#   - valid JSON + JSONL                         -> verifier exit 0
#   - missing top-level run_id in JSON           -> verifier exit 1
#   - mismatched run_id in JSON                  -> verifier exit 1
#   - mismatched run_id in a JSONL line          -> verifier exit 1
#   - missing run_id in a JSONL line             -> verifier exit 1
#   - malformed JSON file                        -> verifier exit 1
#   - malformed JSONL line                       -> verifier exit 1
#
# Expected-negative cases assert that exit code 1 strictly means "fixture
# correctly rejected". The test itself explicitly exits 0 only after every
# positive and negative case passed.
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'local-package-harness.ps1')

$verifier = Join-Path $PSScriptRoot 'verify-evidence-run-id.ps1'
$testDir = Join-Path ([IO.Path]::GetTempPath()) ("runid-test-" + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $testDir | Out-Null

$context = New-HarnessLifecycle -Name 'runid-regression' -RunRoot $testDir `
    -Scenario 'regression' -OverallTimeoutSeconds 60 -HeartbeatSeconds 10

function Invoke-Verifier {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$ExpectedRunId)
    # Run the verifier as a separate HIDDEN, JOB-OWNED, bounded process (the
    # sole safe launcher) so its `exit` can never leak into this test's own
    # exit code; return its real process exit code.
    $owned = Start-LocalHarnessProcess -Context $context -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $verifier, `
            '-RunDir', $Dir, '-ExpectedRunId', $ExpectedRunId) `
        -Kind 'evidence-run-id-verifier' -WorkingDirectory $testDir -HideConsoleWindow
    return (Wait-HarnessProcess -Context $context -Record $owned.Record -Stage 'evidence-run-id-verifier' -TimeoutSeconds 30)
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "Evidence run_id regression FAILED: $Message" }
}

try {
    $expected = 'test-run-001'

    # --- fixture: valid files -------------------------------------------------
    [ordered]@{ run_id = $expected; ok = $true } | ConvertTo-Json | Out-File (Join-Path $testDir 'a.json') -Encoding utf8
    $line1 = ([ordered]@{ run_id = $expected; seq = 1 } | ConvertTo-Json -Compress)
    $line2 = ([ordered]@{ run_id = $expected; seq = 2 } | ConvertTo-Json -Compress)
    "$line1`r`n$line2" | Out-File (Join-Path $testDir 'b.jsonl') -Encoding utf8

    $code = Invoke-Verifier -Dir $testDir -ExpectedRunId $expected
    Assert-True ($code -eq 0) "valid fixtures must verify with exit 0, got $code"

    # --- negative case: missing run_id in JSON ---------------------------------
    [ordered]@{ wrong = $true } | ConvertTo-Json | Out-File (Join-Path $testDir 'bad.json') -Encoding utf8
    $code = Invoke-Verifier -Dir $testDir -ExpectedRunId $expected
    Assert-True ($code -eq 1) "missing run_id in JSON must be rejected with exit 1, got $code"
    Remove-Item -LiteralPath (Join-Path $testDir 'bad.json') -Force

    # --- negative case: mismatched run_id in JSON ------------------------------
    [ordered]@{ run_id = 'wrong-id' } | ConvertTo-Json | Out-File (Join-Path $testDir 'bad.json') -Encoding utf8
    $code = Invoke-Verifier -Dir $testDir -ExpectedRunId $expected
    Assert-True ($code -eq 1) "mismatched run_id in JSON must be rejected with exit 1, got $code"
    Remove-Item -LiteralPath (Join-Path $testDir 'bad.json') -Force

    # --- negative case: mismatched run_id in a JSONL line ----------------------
    $badLine = ([ordered]@{ run_id = 'wrong-id'; seq = 3 } | ConvertTo-Json -Compress)
    "$line1`r`n$badLine" | Out-File (Join-Path $testDir 'b.jsonl') -Encoding utf8
    $code = Invoke-Verifier -Dir $testDir -ExpectedRunId $expected
    Assert-True ($code -eq 1) "mismatched run_id in JSONL must be rejected with exit 1, got $code"

    # --- negative case: missing run_id in a JSONL line -------------------------
    $noIdLine = '{"seq": 4}'
    "$line1`r`n$noIdLine" | Out-File (Join-Path $testDir 'b.jsonl') -Encoding utf8
    $code = Invoke-Verifier -Dir $testDir -ExpectedRunId $expected
    Assert-True ($code -eq 1) "missing run_id in JSONL must be rejected with exit 1, got $code"

    # --- negative case: malformed JSON file -------------------------------------
    '{ not valid json !!' | Out-File (Join-Path $testDir 'malformed.json') -Encoding utf8
    $code = Invoke-Verifier -Dir $testDir -ExpectedRunId $expected
    Assert-True ($code -eq 1) "malformed JSON must be rejected with exit 1, got $code"
    Remove-Item -LiteralPath (Join-Path $testDir 'malformed.json') -Force

    # --- negative case: malformed JSONL line ------------------------------------
    "$line1`r`nthis is not json" | Out-File (Join-Path $testDir 'b.jsonl') -Encoding utf8
    $code = Invoke-Verifier -Dir $testDir -ExpectedRunId $expected
    Assert-True ($code -eq 1) "malformed JSONL line must be rejected with exit 1, got $code"

    # --- restore valid JSONL and re-verify clean --------------------------------
    "$line1`r`n$line2" | Out-File (Join-Path $testDir 'b.jsonl') -Encoding utf8
    $code = Invoke-Verifier -Dir $testDir -ExpectedRunId $expected
    Assert-True ($code -eq 0) "restored valid fixtures must verify with exit 0, got $code"

    Write-Host 'Evidence run_id regression PASS: valid=exit0; missing/mismatched/malformed (JSON and JSONL)=exit1'
    $cleanup = Close-LocalHarnessRun -Context $context -Reason 'regression-end'
    if (-not $cleanup.cleanup_success) {
        throw "Evidence run_id regression FAILED: cleanup failed: $($cleanup.cleanup_failure)"
    }
    exit 0
}
finally {
    if ($context -and -not $context.Closed) {
        $null = Close-LocalHarnessRun -Context $context -Reason 'regression-finally'
    }
    if (Test-Path -LiteralPath $testDir) { Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue }
}
