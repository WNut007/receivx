# Smoke: Phase 8.1 pagination foundation.
#   1. Migration 019 indexes exist
#   2. /api/pos returns PaginatedResponse<PoListRow>; pages return distinct slices
#   3. /Reports server-renders PaginatedResponse; ?page=N drives the slice
#   4. /Transactions data-limit-notice DOM present (hidden by default)

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# 1. Indexes
Step "Migration 019 — IX_Pulls_ClosedAt + IX_PO_OrderDate exist"
# sqlcmd returns array (one line per row). Join before regex so -match
# returns the expected boolean instead of filter-out semantics.
$idx = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.indexes WHERE name IN ('IX_Pulls_ClosedAt','IX_PO_OrderDate') ORDER BY name;") -join ' '
if ($idx -notmatch 'IX_PO_OrderDate')    { Fail "IX_PO_OrderDate missing (got: $idx)" }
if ($idx -notmatch 'IX_Pulls_ClosedAt')  { Fail "IX_Pulls_ClosedAt missing (got: $idx)" }
OK "Both pagination indexes present"

$loginBody = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable sv | Out-Null

# 2. /api/pos paginated
Step "GET /api/pos returns PaginatedResponse shape"
$p1 = Invoke-RestMethod -Uri "$base/api/pos?page=1&pageSize=10" -WebSession $sv
foreach ($prop in 'items','page','pageSize','total','totalPages') {
    if ($null -eq $p1.$prop) { Fail "PaginatedResponse missing $prop" }
}
if ($p1.page -ne 1)        { Fail "page should echo 1, got $($p1.page)" }
if ($p1.pageSize -ne 10)   { Fail "pageSize should echo 10, got $($p1.pageSize)" }
if ($p1.items.Count -gt 10) { Fail "page 1 returned $($p1.items.Count) items, > 10" }
if ($p1.total -lt $p1.items.Count) { Fail "total ($($p1.total)) < items.Count ($($p1.items.Count))" }
OK "page 1 shape valid: items=$($p1.items.Count) of total=$($p1.total) (totalPages=$($p1.totalPages))"

Step "GET /api/pos page 2 returns distinct rows from page 1"
if ($p1.totalPages -lt 2) {
    Write-Host "  (only 1 page in dataset — skip distinct-slice check)" -ForegroundColor DarkGray
} else {
    $p2 = Invoke-RestMethod -Uri "$base/api/pos?page=2&pageSize=10" -WebSession $sv
    if ($p2.items.Count -eq 0)  { Fail "page 2 empty but totalPages=$($p1.totalPages)" }
    if ($p1.items[0].id -eq $p2.items[0].id) { Fail "page 1 + page 2 returned same first row — OFFSET broken" }
    OK "page 2 distinct: first row id $($p2.items[0].id.Substring(0,8))"
}

Step "GET /api/pos defaults: page=1, pageSize=50"
$def = Invoke-RestMethod -Uri "$base/api/pos" -WebSession $sv
if ($def.page -ne 1)      { Fail "default page should be 1, got $($def.page)" }
if ($def.pageSize -ne 50) { Fail "default pageSize should be 50, got $($def.pageSize)" }
OK "defaults applied: page=$($def.page), pageSize=$($def.pageSize)"

# 3. /Reports closed-pull list, paginated through the JSON endpoint.
#    This used to assert a server-rendered page of rows. The list moved to
#    GET /api/reports/closed-pulls when the filter bar moved into SQL, so the
#    paging claim is asserted where paging now happens; the filters themselves
#    are covered by smoke-closed-pulls-server-filters.ps1.
Step "GET /api/reports/closed-pulls returns a page slice; /Reports renders the shell"
$cp = Invoke-RestMethod -Uri "$base/api/reports/closed-pulls?page=1&pageSize=3" -WebSession $sv
foreach ($prop in 'items','page','pageSize','total','totalPages') {
    if ($null -eq $cp.$prop) { Fail "closed-pulls response missing $prop" }
}
if ($cp.page -ne 1)         { Fail "closed-pulls page should echo 1, got $($cp.page)" }
if ($cp.pageSize -ne 3)     { Fail "closed-pulls pageSize should echo 3, got $($cp.pageSize)" }
if ($cp.items.Count -gt 3)  { Fail "closed-pulls pageSize=3 returned $($cp.items.Count) rows" }
if ($cp.total -lt $cp.items.Count) { Fail "closed-pulls total ($($cp.total)) < items ($($cp.items.Count))" }
$r1 = Invoke-WebRequest -Uri "$base/Reports" -WebSession $sv -UseBasicParsing
if ($r1.StatusCode -ne 200) { Fail "GET /Reports returned $($r1.StatusCode)" }
if ($r1.Content -notmatch 'id="result-count"')       { Fail "Reports missing the result-count surface" }
if ($r1.Content -notmatch 'id="reports-pagination"') { Fail "Reports missing the pagination container" }
OK "closed-pulls slice: $($cp.items.Count) of total=$($cp.total); /Reports renders the shell"

# 4. /Transactions data-limit-notice DOM
Step "GET /Transactions includes data-limit-notice DOM"
$tx = Invoke-WebRequest -Uri "$base/Transactions" -WebSession $sv -UseBasicParsing
foreach ($needle in 'id="data-limit-notice"', 'id="dln-shown"', 'id="dln-total"', 'id="dln-export"') {
    if ($tx.Content -notmatch [regex]::Escape($needle)) { Fail "Transactions page missing $needle" }
}
# hidden attribute should be on the wrapper at load time (JS toggles when total > page)
if ($tx.Content -notmatch 'data-limit-notice[^>]*hidden') { Fail "data-limit-notice should start hidden" }
OK "data-limit-notice DOM present + initially hidden"

Write-Host ""
Write-Host "ALL PASS — Phase 8.1 pagination foundation." -ForegroundColor Green
exit 0
