# Regression test: screenshot Observer binding predicate (Daily-use Local
# Package v0.1 Repair 2).
#
# Calls the REAL production predicate Test-ScreenshotObserverBinding from
# tools/local-package-harness.ps1 (the same function the acceptance supervisor
# uses for the live screenshot run). No assertion logic is re-implemented here.
#
# Cases:
#   count=0                          -> false
#   count=1, correct parent, handle=0 -> true
#   count=2                          -> false
#   count=1, wrong parent            -> false
#   count=1, nonzero handle          -> false
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'local-package-harness.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "Screenshot observer regression FAILED: $Message" }
}

$hudPid = 4242

# count = 0 -> false
$res = Test-ScreenshotObserverBinding -ObserverDetails @() -HudPid $hudPid
Assert-True (-not $res) 'count 0 unexpectedly PASSED'

# count = 1, parent correct, handle = 0 -> true
$good = [pscustomobject]@{
    process_id = 4243
    parent_process_id = $hudPid
    main_window_handle = [int64]0
}
$res = Test-ScreenshotObserverBinding -ObserverDetails @($good) -HudPid $hudPid
Assert-True $res 'count 1 with correct parent and handle 0 unexpectedly FAILED'

# count = 2 -> false (both individually valid)
$second = [pscustomobject]@{
    process_id = 4244
    parent_process_id = $hudPid
    main_window_handle = [int64]0
}
$res = Test-ScreenshotObserverBinding -ObserverDetails @($good, $second) -HudPid $hudPid
Assert-True (-not $res) 'count 2 unexpectedly PASSED'

# count = 1, wrong parent -> false
$wrongParent = [pscustomobject]@{
    process_id = 4243
    parent_process_id = 9999
    main_window_handle = [int64]0
}
$res = Test-ScreenshotObserverBinding -ObserverDetails @($wrongParent) -HudPid $hudPid
Assert-True (-not $res) 'wrong parent unexpectedly PASSED'

# count = 1, nonzero window handle (unexpected visible window) -> false
$badHandle = [pscustomobject]@{
    process_id = 4243
    parent_process_id = $hudPid
    main_window_handle = [int64]12345
}
$res = Test-ScreenshotObserverBinding -ObserverDetails @($badHandle) -HudPid $hudPid
Assert-True (-not $res) 'nonzero window handle unexpectedly PASSED'

# detail object missing the expected properties -> false (defensive)
$malformed = [pscustomobject]@{ process_id = 4243 }
$res = Test-ScreenshotObserverBinding -ObserverDetails @($malformed) -HudPid $hudPid
Assert-True (-not $res) 'malformed detail unexpectedly PASSED'

Write-Host 'Screenshot observer binding regression PASS: 0=false, 1(correct)=true, 2=false, wrong parent=false, nonzero handle=false'
exit 0
