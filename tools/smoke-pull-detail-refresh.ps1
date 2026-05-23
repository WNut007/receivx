# Smoke test: GET /api/pulls/{id} returns fresh totals after item + window
# mutations — the contract the new dashboard.js refreshPullDetailDrawer()
# relies on. Server-side test: if these totals ever go stale at the API
# level, the dashboard drawer will also go stale even with the JS refresh
# call. This pins the contract.
#
# 4 cases:
#   1. POST /items adds a window → GET /api/pulls/{id} reflects bumped
#      expected + items + windows totals.
#   2. POST /items adds a SECOND item → totals accumulate.
#   3. POST /windows on item 1 → expected + windows count climb again.
#   4. DELETE item 1 → expected + items + windows shrink back.
#
# Assumes ReceivingOps.Web running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

function SqlCleanup {
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-DRP-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}
SqlCleanup

# Login
$body = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null

# Fresh smoke pull (loose mode so we don't drag in PO-availability concerns).
$pullNum = "PL-DRP-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$pullBody = @{
    pullNumber = $pullNum; warehouseId = $WH_01
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null
    lockPoByPull = $false; lockHourCap = $false
} | ConvertTo-Json
$pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv
$pullId = $pull.id

function GetDetail { Invoke-RestMethod -Uri "$base/api/pulls/$pullId" -Method GET -WebSession $sv }

# Baseline — fresh pull, no items
Step "Baseline GET /api/pulls/{id} on empty pull"
$d0 = GetDetail
if ($d0.itemCount     -ne 0) { Fail "Baseline itemCount=$($d0.itemCount), expected 0" }
if ($d0.totalExpected -ne 0) { Fail "Baseline totalExpected=$($d0.totalExpected), expected 0" }
if ($d0.windowsTotal  -ne 0) { Fail "Baseline windowsTotal=$($d0.windowsTotal), expected 0" }
OK "Baseline empty"

# Case 1: Add first item with 2 windows totaling 500 expected
Step "Add item A with 2 windows (200 + 300) → totals reflect new state"
$itemA = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
    itemCode = 'DRP-A'; description = 'refresh smoke item A'
    windows = @(@{ hourOfDay = 9; expectedQty = 200 }, @{ hourOfDay = 10; expectedQty = 300 })
} | ConvertTo-Json -Depth 5)
$d1 = GetDetail
if ($d1.itemCount     -ne 1)   { Fail "After add A: itemCount=$($d1.itemCount), expected 1" }
if ($d1.totalExpected -ne 500) { Fail "After add A: totalExpected=$($d1.totalExpected), expected 500" }
if ($d1.windowsTotal  -ne 2)   { Fail "After add A: windowsTotal=$($d1.windowsTotal), expected 2" }
OK "Detail reflects item A (1 item / 500 expected / 2 windows)"

# Case 2: Add second item — totals accumulate
Step "Add item B with 1 window (100) → totals accumulate"
$itemB = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
    itemCode = 'DRP-B'; description = 'refresh smoke item B'
    windows = @(@{ hourOfDay = 14; expectedQty = 100 })
} | ConvertTo-Json -Depth 5)
$d2 = GetDetail
if ($d2.itemCount     -ne 2)   { Fail "After add B: itemCount=$($d2.itemCount), expected 2" }
if ($d2.totalExpected -ne 600) { Fail "After add B: totalExpected=$($d2.totalExpected), expected 600" }
if ($d2.windowsTotal  -ne 3)   { Fail "After add B: windowsTotal=$($d2.windowsTotal), expected 3" }
OK "Detail reflects 2 items / 600 expected / 3 windows"

# Case 3: Add a window to item A → expected + windows climb
Step "POST /windows hour 11 / qty 150 on item A → totals climb"
Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$($itemA.id)/windows" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
    hourOfDay = 11; expectedQty = 150
} | ConvertTo-Json) | Out-Null
$d3 = GetDetail
if ($d3.itemCount     -ne 2)   { Fail "After add window: itemCount=$($d3.itemCount), expected 2" }
if ($d3.totalExpected -ne 750) { Fail "After add window: totalExpected=$($d3.totalExpected), expected 750" }
if ($d3.windowsTotal  -ne 4)   { Fail "After add window: windowsTotal=$($d3.windowsTotal), expected 4" }
OK "Detail reflects new window (750 expected / 4 windows)"

# Case 4: Delete item A entirely → expected + items + windows shrink back
Step "DELETE item A → totals shrink to item B only"
$delResp = Invoke-WebRequest -Uri "$base/api/pulls/$pullId/items/$($itemA.id)" -Method DELETE -WebSession $sv -UseBasicParsing
if ($delResp.StatusCode -ne 204) { Fail "DELETE returned $($delResp.StatusCode), expected 204" }
$d4 = GetDetail
if ($d4.itemCount     -ne 1)   { Fail "After delete A: itemCount=$($d4.itemCount), expected 1" }
if ($d4.totalExpected -ne 100) { Fail "After delete A: totalExpected=$($d4.totalExpected), expected 100 (item B's window only)" }
if ($d4.windowsTotal  -ne 1)   { Fail "After delete A: windowsTotal=$($d4.windowsTotal), expected 1" }
OK "Detail reflects delete (1 item / 100 expected / 1 window)"

SqlCleanup
Write-Host ""
Write-Host "ALL PASS — GET /api/pulls/{id} returns fresh totals after each mutation." -ForegroundColor Green
exit 0
