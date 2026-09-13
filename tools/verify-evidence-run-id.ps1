<#
.SYNOPSIS
    Standalone verifier for docs/evidence/daily-use-local-package-v0.1-r1/ run artifacts.
    Recursively inspects every *.json and *.jsonl in a run directory and asserts that
    every JSON root and every non-empty JSONL line contains the exact expected run_id.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDir,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedRunId
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RunDir)) {
    throw "Run directory not found: $RunDir"
}

$checkedFiles = 0
$checkedRecords = 0
$failures = @()

$jsonFiles = Get-ChildItem -LiteralPath $RunDir -Recurse -File -Filter *.json
foreach ($f in $jsonFiles) {
    $checkedFiles++
    $rel = $f.FullName.Substring($RunDir.Length).TrimStart('\', '/')
    try {
        $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $failures += ("{0}: empty JSON file" -f $rel)
            continue
        }
        $parsed = $raw | ConvertFrom-Json
        $checkedRecords++
        $props = $parsed | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
        if ($props -notcontains 'run_id') {
            $failures += ("{0}: missing top-level run_id" -f $rel)
        }
        elseif ([string]$parsed.run_id -ne $ExpectedRunId) {
            $failures += ("{0}: run_id mismatch (got '{1}', expected '{2}')" -f $rel, [string]$parsed.run_id, $ExpectedRunId)
        }
    }
    catch {
        $failures += ("{0}: failed to parse JSON ({1})" -f $rel, $_.Exception.Message)
    }
}

$jsonlFiles = Get-ChildItem -LiteralPath $RunDir -Recurse -File -Filter *.jsonl
foreach ($f in $jsonlFiles) {
    $checkedFiles++
    $rel = $f.FullName.Substring($RunDir.Length).TrimStart('\', '/')
    $lineNum = 0
    $lines = Get-Content -LiteralPath $f.FullName -Encoding UTF8
    foreach ($line in $lines) {
        $lineNum++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $checkedRecords++
        try {
            $parsed = $line | ConvertFrom-Json
            $props = $parsed | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
            if ($props -notcontains 'run_id') {
                $failures += ("{0}:{1}: missing top-level run_id" -f $rel, $lineNum)
            }
            elseif ([string]$parsed.run_id -ne $ExpectedRunId) {
                $failures += ("{0}:{1}: run_id mismatch (got '{2}', expected '{3}')" -f $rel, $lineNum, [string]$parsed.run_id, $ExpectedRunId)
            }
        }
        catch {
            $failures += ("{0}:{1}: failed to parse JSONL ({2})" -f $rel, $lineNum, $_.Exception.Message)
        }
    }
}

$result = [pscustomobject][ordered]@{
    run_id = $ExpectedRunId
    run_dir = (Resolve-Path $RunDir).Path
    checked_files = $checkedFiles
    checked_records = $checkedRecords
    pass = ($failures.Count -eq 0)
    failures = $failures
}

$result | ConvertTo-Json -Depth 5 | Write-Output

if ($failures.Count -gt 0) {
    exit 1
}
exit 0
