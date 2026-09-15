# Smoke: /Reports Closed Pulls — every filter is applied SERVER-SIDE.
#
# The bug this guards against: the filter bar used to run in the browser over
# whichever ~50 rows the server had already rendered, while the pager counted
# the whole table. Searching a pull number that happened to sit on page 12
# therefore returned nothing (reported against pull 0000031539), and the header
# counter ("N pulls" = visible DOM rows) disagreed with the pager ("X closed
# pulls" = unfiltered COUNT) by construction.
#
# Cases:
#   1. Endpoint shape: { items, total, page, pageSize } + paging is real
#   2. THE REGRESSION — a pull on page > 1 is found from page 1 by search
#   3. total equals the filtered row count, and matches SQL COUNT over the
#      same predicate (proves page + count share one WHERE)
#   4. "All dates" sends NO date predicate; All >= Last 2 days
#   5. Pull number normalization: zero-padded / zero-stripped / prefix
#   6. LIKE metacharacters are literal, not wildcards
#   7. q matches PO number + item code via EXISTS — never multiplies rows
#   8. Signature filters partition the set (complete + awaiting == all)
#   9. Warehouse scope: a non-admin's crafted ?warehouseId= cannot widen it
#  10. The page ships no server-rendered list and no filter-blind pager
#  11. reports.js: debounce, AbortController, page-1 reset, selection rules
#
# Fixture namespace: pulls 'PL-CPF-%', POs 'PO-CPF-%'. Purged on entry, on
# exit, and on the failure path.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$SQLSRV = 'LAPTOP-CSB3KO3E'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

function SqlCleanup {
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-CPF-%';
-- FK_PullSig_Pull and FK_PO_Pull do NOT cascade from dbo.Pulls, and the
-- DELETE below is set-based: one signed pull strands the whole range.
-- See docs/defect-pull-signature-fk-blocks-smoke-cleanup.md
DELETE s FROM dbo.PullSignatures s
INNER JOIN dbo.Pulls p ON p.Id = s.PullId
WHERE p.PullNumber LIKE 'PL-CPF-%';
UPDATE po SET PullId = NULL FROM dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE p.PullNumber LIKE 'PL-CPF-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-CPF-%';
PRINT 'cleanup: pulls removed = ' + CONVERT(varchar, @@ROWCOUNT);
DELETE FROM dbo.PurchaseOrderLines
 WHERE PurchaseOrderId IN (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-CPF-%');
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-CPF-%';
'@
    # -b so sqlcmd exits non-zero on a SQL error, and the output is KEPT so a
    # refusal is printed rather than discarded. A cleanup that cannot report its
    # own failure is how 148 fixture pulls once accumulated unnoticed.
    $out = sqlcmd -S $SQLSRV -E -C -d ReceivingOps -I -h -1 -W -b -Q $sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "CLEANUP FAILED (exit $LASTEXITCODE): $out" -ForegroundColor Red
        exit 2
    }
    $out | Where-Object { $_ -match 'cleanup:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

function SqlScalar($query) {
    $v = sqlcmd -S $SQLSRV -E -C -d ReceivingOps -I -h -1 -W -b -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "sqlcmd failed: $v" }
    return ([string]($v -join '')).Trim()
}

function Login($u, $p, $w) {
    $body = @{ username = $u; password = $p; warehouseId = $w; remember = $false } | ConvertTo-Json
    $s = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable s | Out-Null
    return $s
}

function Q($session, $qs) {
    try { return Invoke-RestMethod -Uri "$base/api/reports/closed-pulls?$qs" -WebSession $session }
    catch { Fail "GET /api/reports/closed-pulls?$qs threw: $($_.Exception.Message)" }
}

SqlCleanup

# ---------------------------------------------------------------------------
# Setup — three qualifying closed pulls in one namespace. Created in order, so
# ClosedAt ascends and the list's ORDER BY ClosedAt DESC returns C, B, A.
# ---------------------------------------------------------------------------
Step "Setup: seed PO-CPF + three closed PL-CPF pulls"
$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$itemCode = "CPF-ITEM-$stamp"
$poNumber = "PO-CPF-$stamp"

$seedSql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DECLARE @poId UNIQUEIDENTIFIER = NEWID();
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, ExpectedDate, Status, Notes, CreatedAt)
VALUES (@poId, '__PONUM__', '__WH__', '2026-01-01', NULL, 'open',
        N'closed-pull filter smoke', SYSUTCDATETIME());
INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
VALUES (NEWID(), @poId, 1, '__ITEM__', N'filter smoke line', 9000, 0);
'@.Replace('__PONUM__', $poNumber).Replace('__ITEM__', $itemCode).Replace('__WH__', $WH_01)
$seedOut = sqlcmd -S $SQLSRV -E -C -d ReceivingOps -I -h -1 -W -b -Q $seedSql 2>&1
if ($LASTEXITCODE -ne 0) { Fail "PO seed failed: $seedOut" }

$sv = Login 'sadmin' 'admin' $WH_01

$pullNumbers = @()
foreach ($suffix in 'A', 'B', 'C') {
    $pn = "PL-CPF-$stamp-$suffix"
    $pullBody = @{
        pullNumber = $pn; warehouseId = $WH_01
        pullDate = (Get-Date -Format 'yyyy-MM-dd')
        eta = $null; notes = $null
        lockPoByPull = $false; lockHourCap = $false
        referenceNumber = $null
    } | ConvertTo-Json
    $pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv

    $itemBody = @{ itemCode = $itemCode; description = 'filter smoke'
                   windows = @(@{ hourOfDay = 10; expectedQty = 5 }) } | ConvertTo-Json -Depth 5
    $item = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -Body $itemBody -ContentType 'application/json' -WebSession $sv

    $recvBody = @{ pullItemId = $item.id; hourOfDay = 10; qty = 5
                   lotBatch = $null; palletId = $null; binLocation = $null
                   qcStatus = 'pending'; note = $null } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $recvBody -ContentType 'application/json' -WebSession $sv | Out-Null

    $closeBody = @{ signatureSvg = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $sv | Out-Null
    $pullNumbers += $pn
    Start-Sleep -Milliseconds 1100   # distinct ClosedAt so the ordering is deterministic
}
OK "seeded 3 closed pulls: $($pullNumbers -join ', ')"

# ---------------------------------------------------------------------------
# 1. Response shape + real paging
# ---------------------------------------------------------------------------
Step "1. Endpoint returns { items, total, page, pageSize } and pages for real"
$r = Q $sv 'page=1&pageSize=5'
foreach ($prop in 'items', 'total', 'page', 'pageSize') {
    if ($null -eq $r.$prop) { Fail "response missing '$prop'" }
}
if ($r.page -ne 1)      { Fail "page should echo 1, got $($r.page)" }
if ($r.pageSize -ne 5)  { Fail "pageSize should echo 5, got $($r.pageSize)" }
if ($r.items.Count -gt 5) { Fail "pageSize=5 returned $($r.items.Count) items" }
OK "shape valid: items=$($r.items.Count) total=$($r.total) page=$($r.page) pageSize=$($r.pageSize)"

# ---------------------------------------------------------------------------
# 2. THE REGRESSION. Within the fixture namespace, pageSize=1 puts pull 'A'
#    (the oldest close, hence last by ClosedAt DESC) on page 3. Asking for it
#    by number from page 1 must return it. The old client-side filter searched
#    only the rows already in the DOM, so this returned nothing.
# ---------------------------------------------------------------------------
Step "2. A pull on page > 1 is found from page 1 by search"
$ns = Q $sv "pullNumber=PL-CPF-$stamp&pageSize=1&page=1"
if ($ns.total -ne 3) { Fail "expected 3 fixture pulls, got total=$($ns.total)" }
$page3 = Q $sv "pullNumber=PL-CPF-$stamp&pageSize=1&page=3"
if ($page3.items.Count -ne 1) { Fail "page 3 of the fixture namespace is empty" }
$targetOnPage3 = $page3.items[0].pullNumber
if ($targetOnPage3 -eq $ns.items[0].pullNumber) {
    Fail "page 1 and page 3 returned the same pull ($targetOnPage3) — OFFSET is broken"
}
# The pull is demonstrably NOT on page 1 ...
$found = Q $sv "pullNumber=$targetOnPage3&page=1&pageSize=50"
if ($found.total -ne 1) { Fail "searching '$targetOnPage3' from page 1 gave total=$($found.total), expected 1" }
if ($found.items[0].pullNumber -ne $targetOnPage3) {
    Fail "searching '$targetOnPage3' returned '$($found.items[0].pullNumber)'"
}
OK "'$targetOnPage3' sits on page 3 unfiltered, and search returns it on page 1"

# ---------------------------------------------------------------------------
# 3. total == filtered row count, and matches SQL over the same predicate
# ---------------------------------------------------------------------------
Step "3. total equals the filtered row count and agrees with SQL"
$wide = Q $sv "pullNumber=PL-CPF-$stamp&pageSize=50"
if ($wide.total -ne $wide.items.Count) {
    Fail "one page covers the result but total=$($wide.total) != items=$($wide.items.Count)"
}
$sqlAll = [int](SqlScalar @"
SELECT COUNT(*) FROM dbo.Pulls p
WHERE p.Status='closed'
  AND EXISTS (SELECT 1 FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId
              WHERE pi.PullId=p.Id AND r.ReversedById IS NULL)
  AND (SELECT SUM(r.QtyReceived) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId
       WHERE pi.PullId=p.Id) > 0;
"@)
$apiAll = (Q $sv 'pageSize=1').total
if ($apiAll -ne $sqlAll) { Fail "unfiltered total: API=$apiAll but SQL=$sqlAll (page + count WHERE clauses disagree)" }
OK "filtered total==row count ($($wide.total)); unfiltered total==SQL COUNT ($apiAll)"

# ---------------------------------------------------------------------------
# 4. "All dates" emits no date predicate
# ---------------------------------------------------------------------------
Step "4. All dates >= Last 2 days, and All dates == the unpredicated count"
$from = [uri]::EscapeDataString((Get-Date).Date.AddDays(-1).ToUniversalTime().ToString('o'))
$to   = [uri]::EscapeDataString((Get-Date).Date.AddDays(1).ToUniversalTime().ToString('o'))
$last2 = (Q $sv "closedFrom=$from&closedTo=$to&pageSize=1").total
if ($apiAll -lt $last2) { Fail "All dates ($apiAll) < Last 2 days ($last2)" }
if ($apiAll -ne $sqlAll) { Fail "All dates total ($apiAll) != unpredicated SQL count ($sqlAll)" }
# The window must actually narrow something, or the assertion above is vacuous.
$narrow = (Q $sv "closedFrom=$([uri]::EscapeDataString((Get-Date).Date.AddYears(5).ToUniversalTime().ToString('o')))&pageSize=1").total
if ($narrow -ne 0) { Fail "a window starting 5 years out returned $narrow rows — date predicate not applied" }
OK "All dates=$apiAll >= Last 2 days=$last2; a future window correctly returns 0"

# ---------------------------------------------------------------------------
# 5. Pull-number normalization, against a real zero-padded ERP pull number
# ---------------------------------------------------------------------------
Step "5. Pull number matches zero-padded, zero-stripped, and by prefix"
$padded = SqlScalar @"
SELECT TOP 1 p.PullNumber FROM dbo.Pulls p
WHERE p.Status='closed' AND p.PullNumber NOT LIKE '%[^0-9]%' AND p.PullNumber LIKE '0%'
  AND EXISTS (SELECT 1 FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId
              WHERE pi.PullId=p.Id AND r.ReversedById IS NULL)
  AND (SELECT SUM(r.QtyReceived) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId
       WHERE pi.PullId=p.Id) > 0
ORDER BY p.PullNumber DESC;
"@
if ([string]::IsNullOrWhiteSpace($padded)) {
    Write-Host "  (no zero-padded numeric closed pull in this DB — skipping normalization case)" -ForegroundColor DarkGray
} else {
    $stripped = $padded.TrimStart('0')
    $exact = Q $sv "pullNumber=$padded&pageSize=5"
    if ($exact.total -lt 1) { Fail "exact '$padded' found nothing" }
    $zero  = Q $sv "pullNumber=$stripped&pageSize=5"
    if ($zero.total -lt 1) { Fail "zero-stripped '$stripped' found nothing — this is the 0000031539 case" }
    if (($zero.items | Where-Object { $_.pullNumber -eq $padded }).Count -ne 1) {
        Fail "zero-stripped '$stripped' did not return '$padded'"
    }
    $pre = Q $sv "pullNumber=$($stripped.Substring(0, [Math]::Max(1, $stripped.Length - 1)))&pageSize=50"
    if (($pre.items | Where-Object { $_.pullNumber -eq $padded }).Count -ne 1) {
        Fail "prefix search did not return '$padded'"
    }
    OK "'$padded' found by exact, by zero-stripped '$stripped', and by prefix"
}

# ---------------------------------------------------------------------------
# 6. LIKE metacharacters must be literal
# ---------------------------------------------------------------------------
Step "6. LIKE metacharacters are escaped, not treated as wildcards"
foreach ($meta in '%', '_', '[') {
    $m = Q $sv "pullNumber=$([uri]::EscapeDataString($meta))&pageSize=1"
    if ($m.total -ne 0) { Fail "pullNumber='$meta' matched $($m.total) rows — LIKE metacharacter not escaped" }
    $m2 = Q $sv "q=$([uri]::EscapeDataString($meta))&pageSize=1"
    if ($m2.total -ne 0) { Fail "q='$meta' matched $($m2.total) rows — LIKE metacharacter not escaped" }
}
OK "'%', '_' and '[' match literally in both pullNumber and q"

# ---------------------------------------------------------------------------
# 7. q searches PO number + item code via EXISTS, without multiplying rows
# ---------------------------------------------------------------------------
Step "7. q matches item code + PO number and never duplicates a pull row"
$byItem = Q $sv "q=$itemCode&pageSize=50"
if ($byItem.total -ne 3) { Fail "q by item code '$itemCode' gave total=$($byItem.total), expected the 3 fixture pulls" }
$byPo = Q $sv "q=$poNumber&pageSize=50"
if ($byPo.total -ne 3) { Fail "q by PO number '$poNumber' gave total=$($byPo.total), expected 3" }
$distinct = ($byItem.items | ForEach-Object { $_.pullNumber } | Select-Object -Unique).Count
if ($distinct -ne $byItem.items.Count) {
    Fail "q returned duplicate pull rows ($($byItem.items.Count) rows, $distinct distinct) — EXISTS replaced by a JOIN?"
}
if ((Q $sv 'q=ZZZ-NO-SUCH-THING&pageSize=1').total -ne 0) { Fail "q with no match returned rows" }
OK "q finds all 3 by item code and by PO number, one row each"

# ---------------------------------------------------------------------------
# 8. Signature filters partition the set
# ---------------------------------------------------------------------------
Step "8. sign=complete and sign=awaiting partition sign=all"
$sAll      = (Q $sv 'sign=all&pageSize=1').total
$sComplete = (Q $sv 'sign=complete&pageSize=1').total
$sAwaiting = (Q $sv 'sign=awaiting&pageSize=1').total
if ($sAll -ne $apiAll) { Fail "sign=all ($sAll) should equal the unfiltered total ($apiAll)" }
if (($sComplete + $sAwaiting) -ne $sAll) {
    Fail "complete ($sComplete) + awaiting ($sAwaiting) != all ($sAll)"
}
OK "complete=$sComplete + awaiting=$sAwaiting == all=$sAll"

# ---------------------------------------------------------------------------
# 9. Warehouse scope cannot be widened by the query string
# ---------------------------------------------------------------------------
Step "9. A non-admin's crafted ?warehouseId= does not widen their scope"
$otherWh = SqlScalar @"
SELECT TOP 1 CONVERT(varchar(36), p.WarehouseId) FROM dbo.Pulls p
WHERE p.Status='closed' AND p.WarehouseId <> '$WH_01'
  AND EXISTS (SELECT 1 FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId
              WHERE pi.PullId=p.Id AND r.ReversedById IS NULL)
  AND (SELECT SUM(r.QtyReceived) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId
       WHERE pi.PullId=p.Id) > 0;
"@
$sup = Login 'psomchai' 'demo1234' $WH_01
$supBase = (Q $sup 'pageSize=1').total
if ([string]::IsNullOrWhiteSpace($otherWh)) {
    Write-Host "  (no qualifying closed pull outside WH-01 — scope-widening case limited)" -ForegroundColor DarkGray
} else {
    $adminOther = (Q $sv "warehouseId=$otherWh&pageSize=1").total
    if ($adminOther -lt 1) { Fail "admin should see pulls in warehouse $otherWh" }
    $supOther = (Q $sup "warehouseId=$otherWh&pageSize=1").total
    if ($supOther -ne $supBase) {
        Fail "supervisor's total changed from $supBase to $supOther when passing ?warehouseId=$otherWh — scope widened"
    }
    OK "admin sees $adminOther in that warehouse; supervisor still sees only their own $supBase"
}
# The supervisor must still see the fixture pulls that ARE in their warehouse.
$supFixture = (Q $sup "pullNumber=PL-CPF-$stamp&pageSize=50").total
if ($supFixture -ne 3) { Fail "supervisor at WH-01 should see the 3 WH-01 fixture pulls, saw $supFixture" }
OK "supervisor sees their own warehouse's 3 fixture pulls"

# ---------------------------------------------------------------------------
# 10. The page itself ships no server-rendered list and no filter-blind pager
# ---------------------------------------------------------------------------
Step "10. /Reports renders the shell only — no SSR rows, no ?page= pager"
$page = Invoke-WebRequest -Uri "$base/Reports" -WebSession $sv -UseBasicParsing
if ($page.StatusCode -ne 200) { Fail "GET /Reports returned $($page.StatusCode)" }
if ($page.Content -notmatch 'id="pull-rows"')          { Fail "/Reports missing the #pull-rows container" }
if ($page.Content -notmatch 'id="reports-pagination"') { Fail "/Reports missing the #reports-pagination container" }
if ($page.Content -notmatch '/js/components/pagination\.js') { Fail "/Reports does not load pagination.js" }
# A server-rendered row would mean two markup paths for one list.
if ($page.Content -match 'class="pull-row"')      { Fail "/Reports still server-renders list rows" }
# The old partial emitted <a href="?page=N"> links that carried no filter state.
if ($page.Content -match 'class="pagination-btn"') { Fail "/Reports still server-renders the filter-blind pager" }
if ($page.Content -match 'href="\?[^"]*page=\d')   { Fail "/Reports still emits ?page=N navigation links" }
OK "shell-only render: JS containers present, no SSR rows, no ?page= links"

# ---------------------------------------------------------------------------
# 11. reports.js behaviour that has no HTTP surface.
#     Scoped to the specific function bodies, not the whole file — a match
#     anywhere in a 900-line file is not evidence about a particular rule.
# ---------------------------------------------------------------------------
Step "11. reports.js: server fetch, debounce, abort, page-1 reset, selection"
$jsPath = Join-Path $repoRoot 'src/ReceivingOps.Web/wwwroot/js/reports.js'
if (-not (Test-Path $jsPath)) { Fail "reports.js not found at $jsPath" }
$js = Get-Content $jsPath -Raw

if ($js -notmatch "/api/reports/closed-pulls") { Fail "reports.js never calls /api/reports/closed-pulls" }
if ($js -notmatch 'new AbortController\(\)')   { Fail "reports.js has no AbortController — stale responses can overwrite newer ones" }
if ($js -notmatch 'DEBOUNCE_MS\s*=\s*300')     { Fail "reports.js debounce is not 300ms" }

# The client-side row filter must be gone: it is what hid rows the server had
# already sent, and what made the header counter count visible rows.
if ($js -match 'row\.style\.display')          { Fail "reports.js still hides rows client-side (row.style.display)" }
if ($js -match 'function applyFilters')        { Fail "reports.js still defines the client-side applyFilters()" }

# Filter change => page 1 + selection cleared. Assert against the function body.
$onFilter = [regex]::Match($js, '(?s)function onFilterChanged\(\) \{.*?\n    \}')
if (-not $onFilter.Success) { Fail "could not extract onFilterChanged() from reports.js" }
if ($onFilter.Value -notmatch 'currentPage\s*=\s*1') { Fail "onFilterChanged does not reset to page 1" }
if ($onFilter.Value -notmatch 'selected\.clear\(\)') { Fail "onFilterChanged does not clear the selection" }

# Page change must NOT clear the selection (it persists across pages).
$onPage = [regex]::Match($js, 'onChange:\s*\(newPage\)\s*=>\s*\{[^}]*\}')
if (-not $onPage.Success) { Fail "could not extract the pagination onChange handler" }
if ($onPage.Value -match 'selected\.clear\(\)') { Fail "paging clears the selection — it must persist across pages" }

# "N selected" must be surfaced, including the off-page count.
$syncBar = [regex]::Match($js, '(?s)function syncBatchBar\(\) \{.*?\n    \}')
if (-not $syncBar.Success) { Fail "could not extract syncBatchBar() from reports.js" }
if ($syncBar.Value -notmatch 'selected') { Fail "syncBatchBar does not read the selection count" }
if ($syncBar.Value -notmatch 'offPageSelectedCount\(\)') { Fail "syncBatchBar does not surface the off-page selected count" }

# The counter must read the server total, not a count of visible rows.
$renderCount = [regex]::Match($js, '(?s)function renderCount\(total\) \{.*?\n    \}')
if (-not $renderCount.Success) { Fail "could not extract renderCount() from reports.js" }
if ($renderCount.Value -notmatch 'total') { Fail "renderCount does not use the server total" }

# The sign request carries pull ids only.
if ($js -notmatch 'pullIds:\s*ids') { Fail "sign-batch no longer posts pull ids" }
OK "fetch + 300ms debounce + AbortController; no client-side filtering; page-1 reset + selection rules hold"

# ---------------------------------------------------------------------------
Step "Cleanup"
SqlCleanup
$left = [int](SqlScalar "SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE 'PL-CPF-%';")
if ($left -ne 0) { Write-Host "FAIL: $left fixture pulls stranded" -ForegroundColor Red; exit 1 }
OK "fixture namespace is empty"

Write-Host "`nALL PASS — Closed Pulls filters are server-side." -ForegroundColor Green
