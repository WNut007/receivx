# Smoke: Phase 8.3 — pagination wired into Reports, Pos, Transactions.
#
# Checks (per page):
#   - The shared pagination JS + CSS are loaded by the page
#   - The page-specific pagination container DOM exists
#   - For Reports (server-rendered): when total > pageSize the partial
#     emits .pagination-nav with Prev/Next + numeric buttons; ?page=N
#     URL drives a different slice
#
# JS-rendered pages (Pos + Transactions): the pagination DOM is created
# at runtime by mountPagination(), so the static HTML only carries the
# container + the <script src> for pagination.js. The control's render
# is exercised by the Phase 8.2 component smoke (Node module tests).

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
# 1. /Pos — JS-mounted control. Static HTML carries container + script ref.
# ----------------------------------------------------------------------------
Step "/Pos: container + pagination.js loaded"
$pos = Invoke-WebRequest -Uri "$base/Pos" -WebSession $sv -UseBasicParsing
if ($pos.Content -notmatch 'id="pos-pagination"')         { Fail "/Pos missing pagination container" }
if ($pos.Content -notmatch '/js/components/pagination\.js') { Fail "/Pos missing pagination.js script tag" }
if ($pos.Content -notmatch '/css/components/pagination\.css') { Fail "/Pos missing pagination.css link" }
OK "/Pos chrome wired (container + JS + CSS)"

# ----------------------------------------------------------------------------
# 2. /Transactions — same shape as Pos
# ----------------------------------------------------------------------------
Step "/Transactions: container + pagination.js loaded"
$tx = Invoke-WebRequest -Uri "$base/Transactions" -WebSession $sv -UseBasicParsing
if ($tx.Content -notmatch 'id="tx-pagination"')             { Fail "/Transactions missing pagination container" }
if ($tx.Content -notmatch '/js/components/pagination\.js')  { Fail "/Transactions missing pagination.js script tag" }
if ($tx.Content -notmatch '/css/components/pagination\.css'){ Fail "/Transactions missing pagination.css link" }
OK "/Transactions chrome wired (container + JS + CSS)"

# ----------------------------------------------------------------------------
# 3. /Reports - JS-mounted pagination, same as /Pos and /Transactions above.
#    Until the filter bar moved into SQL this page server-rendered the
#    _Pagination partial, whose <a href="?page=N"> links carried the page number
#    but no filter state - so a page link navigated back to unfiltered rows.
#    The list is now fed by GET /api/reports/closed-pulls and paged by
#    mountPagination(), so the assertions match /Pos and /Transactions.
# ----------------------------------------------------------------------------
Step "/Reports: container + pagination.js loaded"
$reports = Invoke-WebRequest -Uri "$base/Reports" -WebSession $sv -UseBasicParsing
if ($reports.Content -notmatch 'id="reports-pagination"')         { Fail "/Reports missing pagination container" }
if ($reports.Content -notmatch '/js/components/pagination\.js')   { Fail "/Reports missing pagination.js script tag" }
if ($reports.Content -notmatch '/css/components/pagination\.css') { Fail "/Reports missing pagination.css link" }
# The server-rendered pager is gone along with the rows it paged.
if ($reports.Content -match 'class="pagination-btn"') { Fail "/Reports still server-renders the pager" }
if ($reports.Content -match 'href="\?[^"]*page=\d')  { Fail "/Reports still emits ?page=N links" }
OK "/Reports mounts pagination client-side; no server-rendered pager remains"

# ----------------------------------------------------------------------------
# 4. /Reports - ?page=N drives distinct slices, and carries the filter with it.
#    This is what sections 4-6 used to prove about the partial: that paging
#    slices server-side, and that a page link does not drop the active filter.
# ----------------------------------------------------------------------------
Step "/Reports: ?page=N drives different slices and preserves the filter"
$cp1 = Invoke-RestMethod -Uri "$base/api/reports/closed-pulls?pageSize=1&page=1" -WebSession $sv
$cp2 = Invoke-RestMethod -Uri "$base/api/reports/closed-pulls?pageSize=1&page=2" -WebSession $sv
if ($cp1.items.Count -lt 1) { Fail "closed-pulls page=1 returned no row" }
if ($cp1.totalPages -lt 2) {
    Write-Host "  (only 1 eligible closed pull - skip distinct-slice check)" -ForegroundColor DarkGray
} else {
    if ($cp2.items.Count -lt 1) { Fail "closed-pulls page=2 returned no row but totalPages=$($cp1.totalPages)" }
    if ($cp1.items[0].id -eq $cp2.items[0].id) { Fail "page=1 and page=2 returned the same row - OFFSET not applied" }
    OK "page=1 row $($cp1.items[0].id.Substring(0,8)) vs page=2 row $($cp2.items[0].id.Substring(0,8)) (distinct)"
}

# A filter travels alongside page: the total must stay the FILTERED total on
# page 2, not silently revert to the unfiltered count the way the old
# server-rendered pager's href did.
$target = $cp1.items[0].pullNumber
$enc = [uri]::EscapeDataString($target)
$f1 = Invoke-RestMethod -Uri "$base/api/reports/closed-pulls?pullNumber=$enc&pageSize=1&page=1" -WebSession $sv
$f2 = Invoke-RestMethod -Uri "$base/api/reports/closed-pulls?pullNumber=$enc&pageSize=1&page=2" -WebSession $sv
if ($f1.total -ge $cp1.total) { Fail "filtered total ($($f1.total)) did not narrow the unfiltered total ($($cp1.total))" }
if ($f2.total -ne $f1.total)  { Fail "total changed from $($f1.total) to $($f2.total) between pages - filter dropped on page 2" }
OK "filter preserved across pages: total stays $($f1.total) on page 1 and page 2"

Write-Host ""
Write-Host "ALL PASS — Phase 8.3 pagination wired across Reports / Pos / Transactions." -ForegroundColor Green
exit 0
