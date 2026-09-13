# Pure-offline regression: build/promotion success + cleanup failure MUST
# produce final status=FAIL and a non-zero process exit code.
#
# This exercises the single terminal verdict helper
# (Get-LocalBuildFinalVerdict in tools/local-package-harness.ps1) that
# tools/build-local-hud-package.ps1 uses as the ONLY source of its exit code:
#
#     success = build_steps_succeeded
#             AND promotion_succeeded
#             AND cleanup_succeeded
#             AND owned_processes_remaining == 0
#
# Case matrix (all offline, no cargo, no dotnet, no network, no processes):
#   1. build+promotion OK, cleanup FAILED          -> exit code non-zero
#   2. everything OK, owned processes remaining=2  -> exit code non-zero
#   3. everything OK                               -> exit code 0
#   4. promotion failed, cleanup OK                -> exit code non-zero
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'local-package-harness.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "cleanup-exit regression FAILED: $Message" }
}

$case1 = Get-LocalBuildFinalVerdict -BuildStepsSucceeded $true -PromotionSucceeded $true -CleanupSucceeded $false -OwnedProcessesRemaining 0
Assert-True ((-not $case1.success) -and ($case1.exit_code -ne 0) -and ($case1.failures -contains 'cleanup failed')) `
    'build+promotion success with cleanup failure must be FAIL with a non-zero exit code'

$case2 = Get-LocalBuildFinalVerdict -BuildStepsSucceeded $true -PromotionSucceeded $true -CleanupSucceeded $true -OwnedProcessesRemaining 2
Assert-True ((-not $case2.success) -and ($case2.exit_code -ne 0)) `
    'residual owned processes must be FAIL with a non-zero exit code'

$case3 = Get-LocalBuildFinalVerdict -BuildStepsSucceeded $true -PromotionSucceeded $true -CleanupSucceeded $true -OwnedProcessesRemaining 0
Assert-True ($case3.success -and ($case3.exit_code -eq 0)) `
    'a fully successful build must be the only exit-code-0 case'

$case4 = Get-LocalBuildFinalVerdict -BuildStepsSucceeded $true -PromotionSucceeded $false -CleanupSucceeded $true -OwnedProcessesRemaining 0
Assert-True ((-not $case4.success) -and ($case4.exit_code -ne 0) -and ($case4.failures -contains 'promotion failed')) `
    'promotion failure must be FAIL with a non-zero exit code'

# The historical bug: cleanup failed -> exitCode=1, then buildSucceeded
# overrode it to 0. The single verdict makes that override impossible; the
# process exit code below is the verdict's exit code and nothing else.
$verdict = Get-LocalBuildFinalVerdict -BuildStepsSucceeded $true -PromotionSucceeded $true -CleanupSucceeded $false -OwnedProcessesRemaining 0
[pscustomobject][ordered]@{
    regression = 'build-cleanup-exit'
    status = if ($verdict.success) { 'PASS' } else { 'FAIL' }
    cases = @($case1, $case2, $case3, $case4)
} | ConvertTo-Json -Depth 5 | Write-Output
exit $verdict.exit_code
