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
# 3. /Reports — server-rendered partial. With pageSize=1 we force totalPages > 1.
# ----------------------------------------------------------------------------
Step "/Reports: partial renders pagination-nav when totalPages > 1"
$reports = Invoke-WebRequest -Uri "$base/Reports?pageSize=1" -WebSession $sv -UseBasicParsing
if ($reports.Content -notmatch '/css/components/pagination\.css') { Fail "/Reports missing pagination.css link" }
if ($reports.Content -notmatch 'class="pagination"') { Fail "/Reports partial not rendered (expected when total > 1 with pageSize=1)" }
if ($reports.Content -notmatch 'class="pagination-info"') { Fail "/Reports pagination-info missing" }
if ($reports.Content -notmatch 'class="pagination-nav"')  { Fail "/Reports pagination-nav missing" }
if ($reports.Content -notmatch 'href="\?[^"]*page=2[^"]*"') { Fail "/Reports nav links don't carry ?page=N" }
if ($reports.Content -notmatch 'aria-current="page"') { Fail "/Reports active page link missing aria-current" }
OK "/Reports partial renders pagination-nav with page=N hrefs + aria-current"

# ----------------------------------------------------------------------------
# 4. /Reports — partial omitted when totalPages <= 1 (small dataset)
# ----------------------------------------------------------------------------
Step "/Reports: partial omitted when totalPages <= 1"
$reports2 = Invoke-WebRequest -Uri "$base/Reports?pageSize=500" -WebSession $sv -UseBasicParsing
if ($reports2.Content -match 'class="pagination"') {
    Fail "Reports rendered .pagination wrapper for tiny dataset (pageSize=500, total < 500)"
}
OK "/Reports pagination omitted when one page covers everything"

# ----------------------------------------------------------------------------
# 5. /Reports — ?page=2&pageSize=1 returns a different row than page=1
# ----------------------------------------------------------------------------
Step "/Reports: ?page=N drives different slices server-side"
$p1 = Invoke-WebRequest -Uri "$base/Reports?pageSize=1&page=1" -WebSession $sv -UseBasicParsing
$p2 = Invoke-WebRequest -Uri "$base/Reports?pageSize=1&page=2" -WebSession $sv -UseBasicParsing
$id1 = ([regex]::Match($p1.Content, 'data-pull-id="([0-9a-f-]+)"')).Groups[1].Value
$id2 = ([regex]::Match($p2.Content, 'data-pull-id="([0-9a-f-]+)"')).Groups[1].Value
if (-not $id1) { Fail "page=1 returned no row id" }
if (-not $id2) { Fail "page=2 returned no row id (Reports may have only 1 eligible pull)" }
if ($id1 -eq $id2) { Fail "page=1 + page=2 returned same row id — OFFSET not applied" }
OK "page=1 row $($id1.Substring(0,8)) vs page=2 row $($id2.Substring(0,8)) (distinct)"

# ----------------------------------------------------------------------------
# 6. /Reports — base query preserved across page links
# ----------------------------------------------------------------------------
Step "/Reports: pagination links preserve other query params"
$preserved = Invoke-WebRequest -Uri "$base/Reports?dateRange=all&pageSize=1&page=1" -WebSession $sv -UseBasicParsing
if ($preserved.Content -notmatch 'href="\?[^"]*dateRange=all[^"]*page=2"') {
    if ($preserved.Content -notmatch 'href="\?[^"]*page=2[^"]*dateRange=all') {
        Fail "Reports nav link dropped dateRange=all when navigating to page 2"
    }
}
OK "Reports nav links preserve dateRange=all across page navigation"

Write-Host ""
Write-Host "ALL PASS — Phase 8.3 pagination wired across Reports / Pos / Transactions." -ForegroundColor Green
exit 0
