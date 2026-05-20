# Smoke: /api/transactions multi-token search + filters + paging + scoping.
# Seeds a known set of receipts on PL-2848 (WH-01) at the top, then queries.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH01 = '22222222-2222-2222-2222-000000000001'
$WH02 = '22222222-2222-2222-2222-000000000002'
$PullId_2848 = '33333333-3333-3333-3333-000000002848'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Login($u, $p, $wh) {
    $b = @{ username=$u; password=$p; warehouseId=$wh; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $b -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# ---- 0. Reset PL-2848 receipts so the test is deterministic ----
Step "Reset PL-2848 receipts"
$resetSql = @"
SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId WHERE pi.PullId = '$PullId_2848';
UPDATE dbo.PullItemWindows SET ReceivedQty = 0 WHERE PullItemId IN (SELECT Id FROM dbo.PullItems WHERE PullId = '$PullId_2848');
UPDATE dbo.Pulls SET Status='in_progress', ClosedAt=NULL, ClosedBy=NULL, SignatureSvg=NULL, ReopenedAt=NULL, ReopenedBy=NULL, ReopenReason=NULL, FirstReceiptAt=NULL, LastActivityAt=NULL WHERE Id='$PullId_2848';
"@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -Q $resetSql | Out-Null
OK "PL-2848 reset"

# ---- 1. Login sadmin / WH-01 (admin → no warehouse scoping) ----
$sess = Login 'sadmin' 'admin' $WH01
OK "Logged in sadmin"

# Find an item with remaining qty in PL-2848 via /api/pulls/by-number
$pull = Invoke-RestMethod -Uri "$base/api/pulls/by-number/PL-2848" -WebSession $sess
$item = $pull.items | Where-Object { $_.status -ne 'canceled' -and ($_.windows | Where-Object { $_.expectedQty -gt 0 }) } | Select-Object -First 1
$win  = $item.windows | Where-Object { $_.expectedQty -gt $_.receivedQty } | Select-Object -First 1
if (-not $win) { Fail "PL-2848 has no remaining window" }
OK "Target: item $($item.itemCode), hour $($win.hourOfDay), remaining $($win.expectedQty - $win.receivedQty)"

# ---- 2. Seed two receipts on PL-2848 (one normal, one to cancel) ----
Step "Seed 2 receipts (one will be cancelled)"
$r1 = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body (@{ pullItemId=$item.id; hourOfDay=$win.hourOfDay; qty=10; note='smoke-tx-keep' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess
$r2 = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body (@{ pullItemId=$item.id; hourOfDay=$win.hourOfDay; qty=20; note='smoke-tx-cancel' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess
# Cancel r2 to produce a voided + reversal pair
$null = Invoke-RestMethod -Uri "$base/api/receipts/$($r2.receiptId)/cancel" -Method POST -Body (@{ reason='miscount'; note='smoke-tx-reversal' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess
OK "Receipts $($r1.receiptId), $($r2.receiptId) [voided], + 1 reversal"

# ---- 3. Basic query — pullNumber filter ----
Step "GET /api/transactions?pullNumber=PL-2848"
$q = Invoke-RestMethod -Uri "$base/api/transactions?pullNumber=PL-2848" -WebSession $sess
if ($q.rows.Count -lt 3) { Fail "Expected ≥ 3 rows for PL-2848, got $($q.rows.Count)" }
if ($q.total -lt 3) { Fail "Total < 3, got $($q.total)" }
OK "Got $($q.rows.Count) rows / total $($q.total)"

# ---- 4. Multi-token AND match (q='PL-2848 smoke-tx-keep') ----
Step "Multi-token search: q='PL-2848 smoke-tx-keep' → exactly 1 row"
$q2 = Invoke-RestMethod -Uri "$base/api/transactions?q=PL-2848+smoke-tx-keep" -WebSession $sess
if ($q2.rows.Count -ne 1) { Fail "Expected 1, got $($q2.rows.Count)" }
if ($q2.rows[0].id -ne $r1.receiptId) { Fail "Wrong row id" }
OK "AND match returns exactly the 'keep' row"

# ---- 5. Multi-token with a token that excludes everything ----
Step "q='PL-2848 smoke-tx-keep smoke-tx-cancel' → 0 rows (no row has both keep AND cancel notes)"
$q3 = Invoke-RestMethod -Uri "$base/api/transactions?q=PL-2848+smoke-tx-keep+smoke-tx-cancel" -WebSession $sess
if ($q3.rows.Count -ne 0) { Fail "Expected 0, got $($q3.rows.Count)" }
OK "Empty result on impossible AND combination"

# ---- 6. kind=reversal returns only the negative-qty row ----
Step "kind=reversal → reversal row only"
$q4 = Invoke-RestMethod -Uri "$base/api/transactions?pullNumber=PL-2848&kind=reversal" -WebSession $sess
if ($q4.rows.Count -ne 1) { Fail "Expected exactly 1 reversal row, got $($q4.rows.Count)" }
if ($q4.rows[0].qtyReceived -ge 0) { Fail "Reversal row qty should be negative" }
if ($q4.rows[0].kind -ne 'reversal') { Fail "Expected kind=reversal" }
OK "kind=reversal isolates the negative-qty entry"

# ---- 7. kind=voided ----
Step "kind=voided → the original row of the cancelled pair"
$q5 = Invoke-RestMethod -Uri "$base/api/transactions?pullNumber=PL-2848&kind=voided" -WebSession $sess
$voided = $q5.rows | Where-Object { $_.id -eq $r2.receiptId }
if (-not $voided) { Fail "Voided row $($r2.receiptId) not returned" }
if ($voided.kind -ne 'voided') { Fail "kind != voided" }
OK "kind=voided returns the original (positive-qty) row"

# ---- 8. hour filter ----
Step "hour=$($win.hourOfDay) → all 3 rows for PL-2848 (they share that hour)"
$q6 = Invoke-RestMethod -Uri "$base/api/transactions?pullNumber=PL-2848&hour=$($win.hourOfDay)" -WebSession $sess
if ($q6.rows.Count -lt 3) { Fail "Expected ≥ 3, got $($q6.rows.Count)" }
OK "hour filter narrows to the chosen window"

# ---- 9. Paging — take=1, skip=0 then skip=1 ----
Step "Paging: take=1 returns 1 row; skip=1 returns a different row id"
$page1 = Invoke-RestMethod -Uri "$base/api/transactions?pullNumber=PL-2848&take=1&skip=0" -WebSession $sess
$page2 = Invoke-RestMethod -Uri "$base/api/transactions?pullNumber=PL-2848&take=1&skip=1" -WebSession $sess
if ($page1.rows.Count -ne 1) { Fail "page1 count" }
if ($page2.rows.Count -ne 1) { Fail "page2 count" }
if ($page1.rows[0].id -eq $page2.rows[0].id) { Fail "Same row returned for skip=0 and skip=1" }
if ($page1.total -lt 3) { Fail "page total should reflect full match, not page size" }
OK "Paging is order-stable and total reflects full match set"

# ---- 10. itemCode filter ----
Step "itemCode=$($item.itemCode) → only rows for that SKU"
$q7 = Invoke-RestMethod -Uri "$base/api/transactions?itemCode=$($item.itemCode)&pullNumber=PL-2848" -WebSession $sess
foreach ($row in $q7.rows) {
    if ($row.itemCode -ne $item.itemCode) { Fail "Got mixed item codes" }
}
OK "itemCode narrows to that SKU"

# ---- 11. warehouseCode (admin can pass it) ----
Step "warehouseCode=WH-01 returns only WH-01 rows"
$q8 = Invoke-RestMethod -Uri "$base/api/transactions?warehouseCode=WH-01&pullNumber=PL-2848" -WebSession $sess
foreach ($row in $q8.rows) {
    if ($row.warehouseCode -ne 'WH-01') { Fail "Got non-WH-01 row" }
}
OK "warehouseCode filter applied"

# ---- 12. Warehouse scoping — non-admin's query is forced to their session warehouse ----
Step "swattana / WH-02: query with warehouseCode=WH-01 ignored, results stay scoped"
$sess2 = Login 'swattana' 'demo1234' $WH02
$q9 = Invoke-RestMethod -Uri "$base/api/transactions?warehouseCode=WH-01&pullNumber=PL-2848" -WebSession $sess2
foreach ($row in $q9.rows) {
    if ($row.warehouseCode -ne 'WH-02') { Fail "Non-admin saw a WH-01 row" }
}
OK ("Non-admin scoped to WH-02 regardless of warehouseCode hint (got {0} rows)" -f $q9.rows.Count)

# ---- 13. Cancel via /api/receipts/{id}/cancel — same endpoint as receiving drawer ----
Step "POST /api/receipts/{id}/cancel from transactions context"
$cancelResp = Invoke-RestMethod -Uri "$base/api/receipts/$($r1.receiptId)/cancel" -Method POST -Body (@{ reason='other'; note='from-tx-smoke' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess
if (-not $cancelResp.reversalReceiptId) { Fail "No reversalReceiptId returned" }
OK "Cancel endpoint shared with receiving works from transactions"

Write-Host "`nTransactions API smoke passed." -ForegroundColor Green
