# Smoke test: §3.5 / §7.3 lock-aware Cancel invariants
#   Cancel is structurally lock-agnostic. This smoke locks down the contract:
#
#   (1) Cancel on locked-pull receipt restores qty to the SAME PO line
#       it originally consumed (no FIFO reverse-walk).
#   (2) When that line's PO was auto-closed (full cap on a single-line PO),
#       Cancel reopens it: Status='open', ClosedAt=NULL.
#   (3) After reopen, the locked pull can receive again from its dedicated PO
#       — the lock-aware FIFO sees the now-open line.
#
# Assumes ReceivingOps.Web on http://localhost:5213.
# Assumes PL-2900 hour 12 net=0 and PO-2405-001 fully open (500 remaining) — true
# right after smoke-phase-4b cleanup. The smoke also resets if state drifts.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$session = $null

$WH_01 = '22222222-2222-2222-2222-000000000001'

$PI_2900_PCBA = '44444444-4444-4444-2900-000000000001'  # PL-2900 lock=1
$PO_2405_001  = '66666666-6666-6666-6666-000000000012'  # dedicated to PL-2900
$POLINE_2405  = '77777777-7777-7777-7777-120100000001'  # PO-2405-001 line 1

function Step($name) { Write-Host "`n--- $name ---" -ForegroundColor Cyan }
function OK($msg)    { Write-Host "PASS: $msg" -ForegroundColor Green }
function Fail($msg)  { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }

function Q($sql) {
    (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
}

# ---------- Login ----------
Step "Login (sadmin / WH-01)"
$loginBody = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
$r = Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable session
if ($r.StatusCode -ne 200) { Fail "Login expected 200, got $($r.StatusCode)" }
OK "Login ok"

# ---------- Pre-condition: PO-2405-001 fully open (500 remaining) ----------
Step "Pre: PO-2405-001 line 1 is 500/500 remaining (open)"
$line = Q @"
SELECT CONVERT(varchar, OrderedQty - ReceivedQty) + '|' + CONVERT(varchar, OrderedQty) + '|' +
       (SELECT Status FROM dbo.PurchaseOrders WHERE Id = pol.PurchaseOrderId)
FROM   dbo.PurchaseOrderLines pol
WHERE  Id = '$POLINE_2405';
"@
$parts = $line.Split('|')
$remaining = [int]$parts[0]; $ordered = [int]$parts[1]; $status = $parts[2]
Write-Host "  remaining=$remaining ordered=$ordered status=$status"
if ($status -ne 'open' -or $remaining -ne 500) {
    Fail "Pre-condition failed: PO-2405-001 must be open with 500 remaining (got status=$status, remaining=$remaining). Re-run smoke-phase-4b cleanup or reset via SQL."
}
OK "Pre-condition met"

# ============================================================================
# (1) Receive 500 (full cap) → PO-2405-001 auto-closes
# ============================================================================
Step "(1) PL-2900 lock=1 receive 500 PCBA hour 12 → consumes full dedicated cap"
$body = @{ pullItemId=$PI_2900_PCBA; hourOfDay=12; qty=500; qcStatus='pending'; note='4c-full-cap' } | ConvertTo-Json
$rr = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if ($rr.totalQty -ne 500) { Fail "Expected totalQty=500, got $($rr.totalQty)" }
if ($rr.allocations.Count -ne 1) { Fail "Expected 1 allocation, got $($rr.allocations.Count)" }
if ($rr.allocations[0].poNumber -ne 'PO-2405-001') { Fail "Expected PO-2405-001, got $($rr.allocations[0].poNumber)" }
$rcptId = $rr.allocations[0].receiptId
OK "receipt=$rcptId, alloc 500@PO-2405-001"

# ============================================================================
# (2) Verify PO-2405-001 is now auto-closed
# ============================================================================
Step "(2) PO-2405-001 auto-closed after full-cap receive"
$poStatus = Q "SELECT Status FROM dbo.PurchaseOrders WHERE Id='$PO_2405_001';"
$poClosed = Q "SELECT CASE WHEN ClosedAt IS NULL THEN 'NULL' ELSE 'SET' END FROM dbo.PurchaseOrders WHERE Id='$PO_2405_001';"
if ($poStatus -ne 'closed') { Fail "Expected PO-2405-001 status=closed, got '$poStatus'" }
if ($poClosed -ne 'SET')    { Fail "Expected ClosedAt SET, got '$poClosed'" }
OK "PO-2405-001 status=closed, ClosedAt=SET"

# Bonus: another receive should now fail — since the PO is closed, the lock-aware
# query filters it out (po.Status='open') and there is nothing left to allocate.
#
# This step used to assert a bare 409 with no tick. It cannot any more: the 500-receive
# filled the window, so a further 1 pc is an OVER-RECEIPT, and rev 11 (§2f) refuses that
# at 400 OVER_RECEIPT_NOT_ACCEPTED before the PO walk is ever reached. The old assertion
# was testing the over-receipt gate while believing it tested PO exhaustion.
#
# Both halves are asserted now, in order, because the ORDER is the point: the window gate
# fires first, and only past it does PO exhaustion surface as the 409 this step is
# actually about.
Step "(2b) Bonus: receive 1 more on PL-2900, no tick → 400 at the window gate (not the PO gate)"
$body = @{ pullItemId=$PI_2900_PCBA; hourOfDay=12; qty=1 } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 400, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 400) { Fail "Expected 400 OVER_RECEIPT_NOT_ACCEPTED, got $code" }
    $pd = $null; try { $pd = $_.ErrorDetails.Message | ConvertFrom-Json } catch { }
    if ($pd.code -ne 'OVER_RECEIPT_NOT_ACCEPTED') { Fail "Expected OVER_RECEIPT_NOT_ACCEPTED. Got: $($_.ErrorDetails.Message)" }
    OK "400 OVER_RECEIPT_NOT_ACCEPTED — the window gate refuses before any PO is consulted"
}

# With the tick, the window gate passes and the receive reaches the PO walk — which is
# what this step has always been about. It also pins the variance-overflow fallback
# (brief-po-overflow-on-variance §4.1): overflow anchors its vendor on a pull-linked OPEN
# PO line, and PO-2405-001 is closed, so there is no anchor. The correct answer is to
# refuse, NOT to widen to every open PO in WH-01. If that fallback ever regresses, this
# step turns green in the wrong way — hence the row/PO checks below, which prove the
# refusal was total.
Step "(2b') Same receive WITH the tick → 409 No PO linked; overflow must not widen without an anchor"
$before = Q "SELECT COUNT(*) FROM dbo.Receipts WHERE PullItemId='$PI_2900_PCBA';"
$body = @{ pullItemId=$PI_2900_PCBA; hourOfDay=12; qty=1; varianceAccepted=$true
           note='4c: drained PO, tick accepted' } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 409, got success — the tick must not conjure PO capacity that does not exist"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code : $($_.ErrorDetails.Message)" }
    if ($_.ErrorDetails.Message -notmatch 'No PO linked') { Fail "Expected 'No PO linked'. Got: $($_.ErrorDetails.Message)" }
    OK "409 No PO linked — no pull-linked open line to anchor a vendor, so no widening"
}
$after = Q "SELECT COUNT(*) FROM dbo.Receipts WHERE PullItemId='$PI_2900_PCBA';"
if ($after -ne $before) { Fail "the refused receive wrote rows: $before -> $after" }
# The whole point of the anchor fallback: some OTHER open PO in WH-01 carrying this item
# must not have been drawn on.
$strayPo = Q @"
SELECT ISNULL(SUM(r.QtyReceived),0) FROM dbo.Receipts r
INNER JOIN dbo.PurchaseOrders po ON po.Id = r.PurchaseOrderId
WHERE r.PullItemId='$PI_2900_PCBA' AND po.Id <> '$PO_2405_001';
"@
if ($strayPo -ne '0') { Fail "receipts landed on a PO other than PO-2405-001 ($strayPo pcs) — overflow widened without an anchor" }
OK "no rows written, no other PO touched"

# ============================================================================
# (3) Cancel restores to SAME PO line (no FIFO reverse-walk)
# ============================================================================
Step "(3) Cancel receipt → restores 500 to PO-2405-001 (same line, no walk)"
$body = @{ reason='miscount'; note='4c cancel restores+reopens' } | ConvertTo-Json
$cr = Invoke-RestMethod -Uri "$base/api/receipts/$rcptId/cancel" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if (-not $cr.poLineRestored) { Fail "Cancel response missing poLineRestored" }
if ($cr.poLineRestored.poNumber -ne 'PO-2405-001')  { Fail "Expected restore on PO-2405-001, got $($cr.poLineRestored.poNumber)" }
if ($cr.poLineRestored.purchaseOrderLineId -ne $POLINE_2405) { Fail "Restored line GUID mismatch — expected $POLINE_2405, got $($cr.poLineRestored.purchaseOrderLineId)" }
if ($cr.poLineRestored.newRemainingQty -ne 500) { Fail "Expected newRemainingQty=500, got $($cr.poLineRestored.newRemainingQty)" }
OK "restored 500 to same line $($cr.poLineRestored.purchaseOrderLineId), newRemainingQty=500"

# ============================================================================
# (4) PO auto-reopens (Status='open', ClosedAt=NULL)
# ============================================================================
Step "(4) PO-2405-001 auto-reopened after cancel"
$poStatus = Q "SELECT Status FROM dbo.PurchaseOrders WHERE Id='$PO_2405_001';"
$poClosed = Q "SELECT CASE WHEN ClosedAt IS NULL THEN 'NULL' ELSE 'SET' END FROM dbo.PurchaseOrders WHERE Id='$PO_2405_001';"
if ($poStatus -ne 'open') { Fail "Expected PO-2405-001 status=open after reopen, got '$poStatus'" }
if ($poClosed -ne 'NULL') { Fail "Expected ClosedAt=NULL after reopen, got '$poClosed'" }
OK "PO-2405-001 status=open, ClosedAt=NULL (auto-reopen worked)"

# ============================================================================
# (5) Lock-aware FIFO sees the reopened line — receive again on PL-2900 works
# ============================================================================
Step "(5) PL-2900 receive 100 again after reopen → succeeds via lock-aware FIFO"
$body = @{ pullItemId=$PI_2900_PCBA; hourOfDay=12; qty=100; qcStatus='pending'; note='4c-roundtrip' } | ConvertTo-Json
$rr = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if ($rr.totalQty -ne 100) { Fail "Expected totalQty=100, got $($rr.totalQty)" }
if ($rr.allocations[0].poNumber -ne 'PO-2405-001') { Fail "Expected PO-2405-001 (reopened), got $($rr.allocations[0].poNumber)" }
$cleanupId = $rr.allocations[0].receiptId
OK "round-trip ok — receipt=$cleanupId, 100@PO-2405-001"

# ---------- Cleanup ----------
Step "Cleanup"
$body = @{ reason='other'; note='4c cleanup' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/receipts/$cleanupId/cancel" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
$net = Q "SELECT ISNULL(SUM(NetReceived),0) FROM dbo.vw_PullItemReceived WHERE PullItemId='$PI_2900_PCBA' AND HourOfDay=12;"
if ($net -ne '0') { Fail "PL-2900 hour 12 net != 0 after cleanup, got '$net'" }
$remaining = Q "SELECT OrderedQty - ReceivedQty FROM dbo.PurchaseOrderLines WHERE Id='$POLINE_2405';"
if ($remaining -ne '500') { Fail "PO-2405-001 line remaining != 500 after cleanup, got '$remaining'" }
OK "Cleanup converges (net=0, PO line=500/500)"

Write-Host "`nPhase 4c smoke passed (Cancel is lock-agnostic; auto-reopen works on locked POs)." -ForegroundColor Green
