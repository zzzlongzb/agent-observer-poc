# Regression test for atomic package promotion (Daily-use Local Package v0.1
# Repair 2; contract hardening from Candidate Package Build v1 Repair 1).
#
# This test calls the REAL production promotion helper
# (Invoke-LocalPackageAtomicPromotion in tools/local-package-harness.ps1) —
# the exact code tools/build-local-hud-package.ps1 executes — using its
# explicit test-only failure injection points. It does NOT re-implement any
# promotion logic.
#
# Promotion result contract (Repair 1): every call must emit EXACTLY ONE
# result object (@(...).Count -eq 1, no success-stream pollution) carrying
# ALL required properties (promoted, status, error, warning, backup_path,
# backup_retained, package_restored, package_integrity_verified). The wrapper
# Invoke-RegressionPromotion enforces both for every call below.
#
# Catch safety regression (Repair 1): a polluted array result, an object
# missing backup_retained and $null must never make the build's top-level
# catch diagnostic throw a second exception, and the original failure reason
# must never be lost.
#
# Verified scenarios (all inside ONE disposable TEMP directory):
#   1. early build failure        (BeforePromotion)      : old package hash unchanged
#   2. staging sanity failure     (BeforePromotion)      : old package hash unchanged
#   3. failure after backup move  (AfterBackupMove)      : old package restored byte-identical
#   4. simulated restore failure  (BeforeBackupRestore)  : backup still exists, never deleted
#   5. backup cleanup failure     (BackupCleanupFailure) : promoted package kept, backup kept,
#                                                        PASS-with-warning only when integrity proven
#   6. successful promote         (no injection)         : new package in place, backup removed
#
# This script starts NO child processes. It only runs in Windows PowerShell
# 5.1; on any other major version it reports PS51_UNVERIFIED and stops.
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Windows PowerShell 5.1 identity check (self-verifying) ----------------
$psVersionText = [string]$PSVersionTable.PSVersion
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Output "PS51_UNVERIFIED: expected Windows PowerShell 5.1, got $psVersionText"
    exit 4
}

. (Join-Path $PSScriptRoot 'local-package-harness.ps1')

$tempDir = $null
$script:PromotionCallCount = 0

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "Atomic promotion regression FAILED: $Message" }
}

function Invoke-RegressionPromotion {
    # Single choke point enforcing the Repair 1 promotion result contract for
    # EVERY regression call: capture the full output array, assert Count -eq 1
    # (no success-stream pollution from the helper), then assert the single
    # object carries all required properties before returning it.
    param(
        [Parameter(Mandatory)][string]$StagingPath,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$AllowedRoot,
        [string]$InjectFailure = 'None',
        [scriptblock]$VerifyPackage = $null,
        [Parameter(Mandatory)][string]$Case
    )
    $script:PromotionCallCount++
    $arguments = @{
        StagingPath = $StagingPath
        PackageRoot = $PackageRoot
        BackupRoot = $BackupRoot
        AllowedRoot = $AllowedRoot
        InjectFailure = $InjectFailure
    }
    if ($null -ne $VerifyPackage) { $arguments['VerifyPackage'] = $VerifyPackage }
    $output = @(Invoke-LocalPackageAtomicPromotion @arguments)
    Assert-True ($output.Count -eq 1) ("{0}: promotion must return EXACTLY one result object, got {1} (success-stream pollution)" -f $Case, $output.Count)
    $result = $output[0]
    Assert-True (Test-LocalPackagePromotionResultContract -Value $result) ("{0}: promotion result is missing one or more required properties" -f $Case)
    return $result
}

function New-TestStaging {
    param([Parameter(Mandatory)][string]$Root)
    $staging = Join-Path $Root ('.staging-' + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    [IO.File]::WriteAllText((Join-Path $staging 'new.txt'), 'new package content', [Text.Encoding]::UTF8)
    return $staging
}

function New-TestPackageTree {
    # Creates a fake "existing package" (with a sentinel file whose hash must
    # survive failures) plus a fresh staging tree.
    param([Parameter(Mandatory)][string]$Root)
    $pkgDir = Join-Path $Root 'target-package'
    New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
    $sentinel = Join-Path $pkgDir 'sentinel.txt'
    $content = "original-pre-existing-package-sentinel-content-" + [Guid]::NewGuid().ToString()
    [IO.File]::WriteAllText($sentinel, $content, [Text.Encoding]::UTF8)

    $staging = New-TestStaging -Root $Root

    [pscustomobject]@{
        PackageRoot = $pkgDir
        Sentinel = $sentinel
        SentinelHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
        Staging = $staging
    }
}

function Invoke-CatchSafetySimulation {
    # Mirrors the top-level catch block of tools/build-local-hud-package.ps1
    # (Repair 1). The diagnostic path must never throw a second exception and
    # must never lose the original failure reason. $InjectedDiagnosticFailure
    # simulates the diagnostic itself crashing, to prove the failure text is
    # APPENDED, never overwrites the original reason.
    param(
        [AllowNull()]$PseudoPromotionResult,
        [string]$InjectedDiagnosticFailure = ''
    )
    $failureReason = $null
    $failureClassification = 'NONE'
    $originalFailureMessage = 'ORIGINAL-FAILURE-' + [Guid]::NewGuid().ToString('n').Substring(0, 8)
    # --- build catch mirror ---
    $originalFailureMessage = [string]$originalFailureMessage
    if (-not $failureReason) { $failureReason = $originalFailureMessage }
    if ($failureClassification -eq 'NONE') { $failureClassification = 'FAIL' }
    try {
        if ($InjectedDiagnosticFailure) { throw $InjectedDiagnosticFailure }
        $promotionDiagnostic = Get-LocalPackagePromotionDiagnostic -PromotionResult $PseudoPromotionResult
        if ($null -ne $promotionDiagnostic) { Write-Warning $promotionDiagnostic }
    } catch {
        $failureReason = "$originalFailureMessage; promotion diagnostic failed: $($_.Exception.Message)"
    }
    # --- end mirror ---
    return [pscustomobject]@{
        OriginalFailure = $originalFailureMessage
        FailureReason = $failureReason
        Classification = $failureClassification
    }
}

Write-Output "POWERSHELL_VERSION=$psVersionText"

try {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("atomic-test-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    # --- Case 1: early build failure (before anything moves) ------------------
    $tree = New-TestPackageTree -Root $tempDir
    $backup = Join-Path $tempDir ('.backup-' + [Guid]::NewGuid().ToString('n'))
    $result = Invoke-RegressionPromotion -AllowedRoot $tempDir -StagingPath $tree.Staging -PackageRoot $tree.PackageRoot -BackupRoot $backup -InjectFailure 'BeforePromotion' -Case 'case 1'
    Assert-True ($result.status -eq 'FAIL') "case 1: expected FAIL, got $($result.status)"
    Assert-True (-not $result.promoted) "case 1: promoted must be false"
    Assert-True (Test-Path -LiteralPath $tree.Sentinel) 'case 1: sentinel missing after early build failure'
    Assert-True ((Get-FileHash -LiteralPath $tree.Sentinel -Algorithm SHA256).Hash -eq $tree.SentinelHash) 'case 1: old package hash changed'
    Assert-True (Test-Path -LiteralPath $tree.Staging) 'case 1: staging must still exist (nothing moved)'

    # --- Case 2: staging sanity failure (same pre-move gate) ------------------
    $result = Invoke-RegressionPromotion -AllowedRoot $tempDir -StagingPath $tree.Staging -PackageRoot $tree.PackageRoot -BackupRoot $backup -InjectFailure 'BeforePromotion' -Case 'case 2'
    Assert-True ($result.status -eq 'FAIL') "case 2: expected FAIL, got $($result.status)"
    Assert-True (Test-Path -LiteralPath $tree.Sentinel) 'case 2: sentinel missing after staging sanity failure'
    Assert-True ((Get-FileHash -LiteralPath $tree.Sentinel -Algorithm SHA256).Hash -eq $tree.SentinelHash) 'case 2: old package hash changed'
    Remove-Item -LiteralPath $tree.Staging -Recurse -Force

    # --- Case 3: failure right after the backup move --------------------------
    $tree.Staging = New-TestStaging -Root $tempDir
    $result = Invoke-RegressionPromotion -AllowedRoot $tempDir -StagingPath $tree.Staging -PackageRoot $tree.PackageRoot -BackupRoot $backup -InjectFailure 'AfterBackupMove' -Case 'case 3'
    Assert-True ($result.status -eq 'FAIL') "case 3: expected FAIL, got $($result.status)"
    Assert-True $result.package_restored 'case 3: original package must be restored'
    Assert-True (Test-Path -LiteralPath $tree.Sentinel) 'case 3: sentinel missing after during-promote failure'
    Assert-True ((Get-FileHash -LiteralPath $tree.Sentinel -Algorithm SHA256).Hash -eq $tree.SentinelHash) 'case 3: restored package hash differs from original'
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'case 3: backup must be gone after successful restore'
    Assert-True (Test-Path -LiteralPath $tree.Staging) 'case 3: staging must still exist (promote failed)'

    # --- Case 4: simulated restore failure (backup must survive) --------------
    $result = Invoke-RegressionPromotion -AllowedRoot $tempDir -StagingPath $tree.Staging -PackageRoot $tree.PackageRoot -BackupRoot $backup -InjectFailure 'BeforeBackupRestore' -Case 'case 4'
    Assert-True ($result.status -eq 'FAIL') "case 4: expected FAIL, got $($result.status)"
    Assert-True (-not $result.package_restored) 'case 4: restore must have failed'
    Assert-True $result.backup_retained 'case 4: backup_retained must be true'
    Assert-True ($null -ne $result.backup_path) 'case 4: backup absolute path must be recorded'
    Assert-True (Test-Path -LiteralPath $result.backup_path) 'case 4: backup directory must still exist'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $result.backup_path 'sentinel.txt') -Algorithm SHA256).Hash -eq $tree.SentinelHash) 'case 4: backup content must be byte-identical to the old package'
    Assert-True (-not (Test-Path -LiteralPath $tree.PackageRoot)) 'case 4: package root must be absent (not restored)'
    # Recovery path: manually restore from the retained backup, then continue.
    Move-Item -LiteralPath $result.backup_path -Destination $tree.PackageRoot
    Assert-True ((Get-FileHash -LiteralPath $tree.Sentinel -Algorithm SHA256).Hash -eq $tree.SentinelHash) 'case 4: manual recovery produced different content'

    # --- Case 5: backup cleanup failure after successful promote --------------
    $tree.Staging = New-TestStaging -Root $tempDir
    $script:verifyCalled = $false
    $result = Invoke-RegressionPromotion -AllowedRoot $tempDir -StagingPath $tree.Staging -PackageRoot $tree.PackageRoot -BackupRoot $backup `
        -InjectFailure 'BackupCleanupFailure' -VerifyPackage { $script:verifyCalled = $true; Test-Path -LiteralPath (Join-Path $tree.PackageRoot 'new.txt') } -Case 'case 5'
    Assert-True ($result.status -eq 'PASS') "case 5: expected PASS-with-warning, got $($result.status) ($($result.error))"
    Assert-True $result.promoted 'case 5: package must be promoted'
    Assert-True ([bool]$result.warning) 'case 5: warning must be recorded'
    Assert-True $script:verifyCalled 'case 5: package integrity verifier must have been called'
    Assert-True $result.backup_retained 'case 5: backup must be retained'
    Assert-True (Test-Path -LiteralPath $result.backup_path) 'case 5: backup directory must still exist'
    Assert-True (Test-Path -LiteralPath (Join-Path $tree.PackageRoot 'new.txt')) 'case 5: promoted package must be the new one'
    Assert-True (-not (Test-Path -LiteralPath $tree.Sentinel)) 'case 5: old sentinel must NOT be in the promoted package'
    # Without an integrity verifier the same failure must be FAIL, backup kept.
    $tree2 = New-TestPackageTree -Root $tempDir
    $backup2 = Join-Path $tempDir ('.backup-' + [Guid]::NewGuid().ToString('n'))
    $result = Invoke-RegressionPromotion -AllowedRoot $tempDir -StagingPath $tree2.Staging -PackageRoot $tree2.PackageRoot -BackupRoot $backup2 -InjectFailure 'BackupCleanupFailure' -Case 'case 5b'
    Assert-True ($result.status -eq 'FAIL') "case 5b: expected FAIL when integrity cannot be proven, got $($result.status)"
    Assert-True $result.backup_retained 'case 5b: backup must be retained'
    Assert-True (Test-Path -LiteralPath $tree2.PackageRoot) 'case 5b: promoted package must NOT be deleted'

    # --- Case 6: successful promote -------------------------------------------
    $tree3 = New-TestPackageTree -Root $tempDir
    $backup3 = Join-Path $tempDir ('.backup-' + [Guid]::NewGuid().ToString('n'))
    $result = Invoke-RegressionPromotion -AllowedRoot $tempDir -StagingPath $tree3.Staging -PackageRoot $tree3.PackageRoot -BackupRoot $backup3 -Case 'case 6'
    Assert-True ($result.status -eq 'PASS') "case 6: expected PASS, got $($result.status) ($($result.error))"
    Assert-True $result.promoted 'case 6: promoted must be true'
    Assert-True (Test-Path -LiteralPath (Join-Path $tree3.PackageRoot 'new.txt')) 'case 6: new package content must be in place'
    Assert-True (-not (Test-Path -LiteralPath $backup3)) 'case 6: backup must have been cleaned up'
    Assert-True (-not (Test-Path -LiteralPath $tree3.Staging)) 'case 6: staging must have been moved away'

    # --- Case 7: catch safety (Repair 1) --------------------------------------
    # A polluted (array-form) pseudo promotion result, an object missing
    # backup_retained, and $null must all fail the contract check...
    $validResultObject = [pscustomobject][ordered]@{
        promoted = $true; status = 'PASS'; error = $null; warning = $null
        backup_path = $null; backup_retained = $false
        package_restored = $false; package_integrity_verified = $false
    }
    $arrayPseudoResult = @($validResultObject, 'success-stream pollution from a helper')
    $missingBackupRetained = [pscustomobject][ordered]@{ promoted = $true; status = 'PASS' }
    Assert-True ($arrayPseudoResult.Count -eq 2) 'case 7: array pseudo result must have two elements'
    Assert-True (-not (Test-LocalPackagePromotionResultContract -Value $arrayPseudoResult)) 'case 7: array-form pseudo result must fail the contract check'
    Assert-True (-not (Test-LocalPackagePromotionResultContract -Value $missingBackupRetained)) 'case 7: object missing backup_retained must fail the contract check'
    Assert-True (-not (Test-LocalPackagePromotionResultContract -Value $null)) 'case 7: null must fail the contract check'
    Assert-True (Test-LocalPackagePromotionResultContract -Value $validResultObject) 'case 7: complete result object must pass the contract check'
    # ...the diagnostic helper must never throw for them, and the build catch
    # mirror must never lose the original failure reason.
    $pseudoCases = New-Object System.Collections.Generic.List[object]
    [void]$pseudoCases.Add($arrayPseudoResult)
    [void]$pseudoCases.Add($missingBackupRetained)
    [void]$pseudoCases.Add($null)
    for ($index = 0; $index -lt $pseudoCases.Count; $index++) {
        $pseudo = $pseudoCases[$index]
        $diagnostic = $null
        $diagnosticThrew = $false
        try { $diagnostic = Get-LocalPackagePromotionDiagnostic -PromotionResult $pseudo } catch { $diagnosticThrew = $true }
        Assert-True (-not $diagnosticThrew) "case 7: diagnostic helper must not throw (input $index)"
        Assert-True ($null -eq $diagnostic) "case 7: diagnostic must return null for contract-violating input $index"
        $sim = Invoke-CatchSafetySimulation -PseudoPromotionResult $pseudo
        Assert-True ($sim.FailureReason.StartsWith($sim.OriginalFailure)) "case 7: original failure reason must not be lost (input $index)"
        Assert-True ($sim.Classification -eq 'FAIL') "case 7: failure classification must be saved (input $index)"
    }
    # A diagnostic-internal crash appends; it never overwrites the original.
    $sim = Invoke-CatchSafetySimulation -PseudoPromotionResult $null -InjectedDiagnosticFailure 'simulated diagnostic crash'
    Assert-True ($sim.FailureReason.StartsWith($sim.OriginalFailure)) 'case 7: diagnostic failure must append, not overwrite, the original failure reason'
    Assert-True ($sim.FailureReason -like '*simulated diagnostic crash*') 'case 7: diagnostic failure text must be appended'
    # A contract-valid result with a retained backup still yields the warning.
    $retainedResult = [pscustomobject][ordered]@{
        promoted = $true; status = 'PASS'; error = $null; warning = $null
        backup_path = 'C:\somewhere\backup'; backup_retained = $true
        package_restored = $false; package_integrity_verified = $true
    }
    $diagnostic = Get-LocalPackagePromotionDiagnostic -PromotionResult $retainedResult
    Assert-True ($null -ne $diagnostic -and $diagnostic -like '*BACKUP RETAINED*') 'case 7: valid retained-backup result must yield the backup warning'

    Assert-True ($script:PromotionCallCount -ge 7) "case 7: expected at least 7 contract-checked promotion calls, saw $($script:PromotionCallCount)"

    Write-Host 'Atomic package promotion regression PASS: production helper verified with all failure injections, single-object result contract and catch safety'
    exit 0
}
finally {
    # Rule 13: prove the canonical fixture root is strictly inside the TEMP
    # root before the recursive delete; refuse anything else. Cleanup failure
    # is a hard FAIL (the throw propagates).
    if ($null -ne $tempDir) {
        $tempRootCanonical = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $check = Test-LocalPackageSafePath -Path $tempDir -AllowedRoots @($tempRootCanonical)
        if (-not $check.safe) {
            throw "Atomic promotion regression cleanup REFUSED (unsafe TEMP path): $($check.reason)"
        }
        if (Test-Path -LiteralPath $check.canonical_path) {
            Remove-Item -LiteralPath $check.canonical_path -Recurse -Force -ErrorAction Stop
        }
    }
}
