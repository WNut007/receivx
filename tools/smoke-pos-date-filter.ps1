# Smoke test: /Pos page OrderDate range filter (Phase 7.4+).
#
# Checks the chrome + the server-side filter:
#   1. /Pos renders the Date Range dropdown with all 7 options, default = last_2_days
#   2. /Pos renders the custom-range row (hidden by default)
#   3. GET /api/pos?orderDateFrom=&orderDateTo= narrows results
#   4. Combined filter (warehouse + orderDateFrom/to) intersects correctly
#   5. Empty range (future dates) returns []

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

$loginBody = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable sv | Out-Null

# ----------------------------------------------------------------------------
# 1. Chrome — dropdown options, default, custom-range row markup
# ----------------------------------------------------------------------------
Step "GET /Pos → Date Range dropdown + custom-range row"
$page = Invoke-WebRequest -Uri "$base/Pos" -Method GET -WebSession $sv -UseBasicParsing
if ($page.StatusCode -ne 200) { Fail "GET /Pos returned $($page.StatusCode)" }
$opts = [regex]::Match($page.Content, '(?s)<select[^>]+id="f-date"[^>]*>(.*?)</select>').Groups[1].Value
if (-not $opts) { Fail "f-date dropdown not found in /Pos HTML" }
foreach ($v in 'all','today','last_2_days','yesterday','this_week','last_week','custom') {
    if ($opts -notmatch ('value="' + $v + '"')) { Fail "f-date missing option value=`"$v`"" }
}
if ($opts -notmatch 'last_2_days[^>]*selected') { Fail "f-date default should be last_2_days" }
if ($page.Content -notmatch 'id="custom-date-row"') { Fail "/Pos missing custom-date-row markup" }
if ($page.Content -notmatch 'id="date-apply"')      { Fail "/Pos missing date-apply button" }
if ($page.Content -notmatch 'id="date-clear"')      { Fail "/Pos missing date-clear button" }
OK "Chrome has 7 options (default=last_2_days) + custom-range row + Apply/Clear"

# ----------------------------------------------------------------------------
# 2. Server filter — orderDateFrom/orderDateTo narrows results
# Phase 8.1: /api/pos returns PaginatedResponse so `.total` is the
# server-filtered count (pageSize=500 keeps `.items` full for the
# range-spotcheck below).
# ----------------------------------------------------------------------------
Step "GET /api/pos with orderDateFrom/orderDateTo narrows the list"
$today     = (Get-Date -Format 'yyyy-MM-dd')
$yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
$weekAgo   = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd')

$noFilter = Invoke-RestMethod -Uri "$base/api/pos?pageSize=500" -WebSession $sv
$last2    = Invoke-RestMethod -Uri "$base/api/pos?orderDateFrom=$yesterday&orderDateTo=$today&pageSize=500" -WebSession $sv
$week     = Invoke-RestMethod -Uri "$base/api/pos?orderDateFrom=$weekAgo&orderDateTo=$today&pageSize=500" -WebSession $sv

if ($noFilter.total -lt 1) { Fail "Expected baseline /api/pos to return at least 1 row, got 0" }
if ($last2.total -gt $week.total) { Fail "last 2 days ($($last2.total)) > last 7 days ($($week.total)) — bad filter" }
if ($week.total -gt $noFilter.total) { Fail "last 7 days ($($week.total)) > no filter ($($noFilter.total)) — bad filter" }
# Every row returned must respect the range — sample check
$outOfRange = @($last2.items | Where-Object { $_.orderDate -lt $yesterday -or $_.orderDate -gt "$today`T23:59:59" }).Count
if ($outOfRange -gt 0) { Fail "$outOfRange rows in last_2_days fell outside [$yesterday, $today]" }
OK "Date filter narrows: no-filter=$($noFilter.total) | last 7d=$($week.total) | last 2d=$($last2.total)"

# ----------------------------------------------------------------------------
# 3. Combined filter — warehouse + date range intersects
# ----------------------------------------------------------------------------
Step "Combined warehouse + date filter intersects correctly"
$whOnly      = Invoke-RestMethod -Uri "$base/api/pos?warehouseId=$WH_01&pageSize=500" -WebSession $sv
$whAndLast2  = Invoke-RestMethod -Uri "$base/api/pos?warehouseId=$WH_01&orderDateFrom=$yesterday&orderDateTo=$today&pageSize=500" -WebSession $sv
if ($whAndLast2.total -gt $whOnly.total) { Fail "warehouse+date ($($whAndLast2.total)) > warehouse-only ($($whOnly.total))" }
$wrongWh = @($whAndLast2.items | Where-Object { $_.warehouseId -ne $WH_01 }).Count
if ($wrongWh -gt 0) { Fail "$wrongWh rows had wrong warehouseId" }
OK "warehouse + date: $($whAndLast2.total) rows (subset of $($whOnly.total) warehouse-only)"

# ----------------------------------------------------------------------------
# 4. Empty range — future dates return total=0
# ----------------------------------------------------------------------------
Step "Future date range returns total=0"
$future = (Get-Date).AddDays(10).ToString('yyyy-MM-dd')
$farFut = (Get-Date).AddDays(20).ToString('yyyy-MM-dd')
$empty = Invoke-RestMethod -Uri "$base/api/pos?orderDateFrom=$future&orderDateTo=$farFut" -WebSession $sv
if ($empty.total -ne 0) { Fail "Future range should return total=0, got $($empty.total)" }
OK "Future range correctly returns empty (total=0)"

Write-Host ""
Write-Host "ALL PASS — /Pos OrderDate filter (chrome + API + combined + empty)." -ForegroundColor Green
exit 0
