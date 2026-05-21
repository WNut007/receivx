# Spot-verify (2): PO auto-close + auto-reopen via the view layer.
#
# Uses PL-2900 (lock=1) + dedicated PO-2405-001 (500 capacity, single line).
#   1. Initial state — Status=open, view exposes the line at 500 remaining.
#   2. Receive 500 (full cap)            → PO should auto-close, view should hide the line.
#   3. Verify state after drain.
#   4. Receive again → expect 409 (locked pull with no open POs).
#   5. Cancel the drain receipt          → PO should auto-reopen, view should expose the line again.
#   6. Verify state after cancel.
#   7. Receive 1 to confirm the reopen actually re-admits receives.
# (Plus final cleanup to leave state at SUM=0 on PL-2900.)

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH01 = '22222222-2222-2222-2222-000000000001'
$PI_2900_PCBA = '44444444-4444-4444-2900-000000000001'
$PO_2405 = '66666666-6666-6666-6666-000000000012'
$POLINE_2405 = '77777777-7777-7777-7777-120100000001'

function Login {
    $body = @{ username='sadmin'; password='admin'; warehouseId=$WH01; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

function DumpState($label) {
    Write-Host ""
    Write-Host ">>> $label" -ForegroundColor Cyan
    Write-Host "    PurchaseOrders row:"
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -W -Q @"
SET NOCOUNT ON;
SELECT  PoNumber, Status,
        CASE WHEN ClosedAt IS NULL THEN 'NULL' ELSE CONVERT(varchar, ClosedAt, 120) END AS ClosedAt,
        PullId
FROM    dbo.PurchaseOrders WHERE Id = '$PO_2405';
"@
    Write-Host "    PurchaseOrderLines row:"
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -W -Q @"
SET NOCOUNT ON;
SELECT  LineNumber, ItemCode, OrderedQty, ReceivedQty, (OrderedQty - ReceivedQty) AS Remaining
FROM    dbo.PurchaseOrderLines WHERE Id = '$POLINE_2405';
"@
    Write-Host "    vw_PurchaseOrderAvailability rows for PO-2405-001:"
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -W -Q @"
SET NOCOUNT ON;
SELECT  PoNumber, LineNumber, ItemCode, OrderedQty, ReceivedQty, RemainingQty, PoStatus, PullId
FROM    dbo.vw_PurchaseOrderAvailability
WHERE   PurchaseOrderId = '$PO_2405';
"@
}

$sv = Login

# ============================================================================
# STEP 1 — initial state
# ============================================================================
Write-Host "================================================================"
Write-Host "STEP 1 — initial state (expect: Status=open, view row present, remaining=500)"
Write-Host "================================================================"
DumpState 'Pre-drain'

# ============================================================================
# STEP 2 — receive 500 (drain the PO)
# ============================================================================
Write-Host ""
Write-Host "================================================================"
Write-Host "STEP 2 — receive 500 on PL-2900 hour 12 (consumes full cap)"
Write-Host "================================================================"
$rcvBody = @{ pullItemId=$PI_2900_PCBA; hourOfDay=12; qty=500; note='spot2-drain' } | ConvertTo-Json
$rcv = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $rcvBody -ContentType 'application/json' -WebSession $sv
$drainReceiptId = $rcv.allocations[0].receiptId
Write-Host "  Response: totalQty=$($rcv.totalQty), receiptId=$drainReceiptId, allocations[0].poNumber=$($rcv.allocations[0].poNumber)"

# ============================================================================
# STEP 3 — state after drain (expect: Status=closed, ClosedAt set, view row GONE)
# ============================================================================
Write-Host ""
Write-Host "================================================================"
Write-Host "STEP 3 — state after drain (expect: Status=closed, ClosedAt set, view row GONE)"
Write-Host "================================================================"
DumpState 'Post-drain'

# ============================================================================
# STEP 4 — receive again → 409
# ============================================================================
Write-Host ""
Write-Host "================================================================"
Write-Host "STEP 4 — receive 1 more → 409 (PO exhausted, lock=1 has no other PO)"
Write-Host "================================================================"
$retryBody = @{ pullItemId=$PI_2900_PCBA; hourOfDay=12; qty=1 } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $retryBody -ContentType 'application/json' -WebSession $sv | Out-Null
    Write-Host "  UNEXPECTED 200 — expected 409!" -ForegroundColor Red
    exit 1
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    $msg  = $_.ErrorDetails.Message
    Write-Host "  HTTP $code — ProblemDetails body:"
    Write-Host "  $msg"
}

# ============================================================================
# STEP 5 — cancel the drain receipt
# ============================================================================
Write-Host ""
Write-Host "================================================================"
Write-Host "STEP 5 — cancel the drain receipt (should auto-reopen PO)"
Write-Host "================================================================"
$cancelBody = @{ reason='other'; note='spot2-cancel' } | ConvertTo-Json
$cancel = Invoke-RestMethod -Uri "$base/api/receipts/$drainReceiptId/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $sv
Write-Host "  Response.poLineRestored:"
Write-Host "    poNumber=$($cancel.poLineRestored.poNumber)"
Write-Host "    purchaseOrderLineId=$($cancel.poLineRestored.purchaseOrderLineId)"
Write-Host "    newRemainingQty=$($cancel.poLineRestored.newRemainingQty)"
Write-Host "  reversalReceiptId=$($cancel.reversalReceiptId)"

# ============================================================================
# STEP 6 — state after cancel (expect: Status=open, ClosedAt=NULL, view row back)
# ============================================================================
Write-Host ""
Write-Host "================================================================"
Write-Host "STEP 6 — state after cancel (expect: Status=open, ClosedAt=NULL, view row back, remaining=500)"
Write-Host "================================================================"
DumpState 'Post-cancel'

# ============================================================================
# STEP 7 — receive 1 to confirm the reopen actually re-admits receives
# ============================================================================
Write-Host ""
Write-Host "================================================================"
Write-Host "STEP 7 — receive 1 again → expect 200 via PO-2405-001 (lock-aware FIFO)"
Write-Host "================================================================"
$confirmBody = @{ pullItemId=$PI_2900_PCBA; hourOfDay=12; qty=1; note='spot2-roundtrip' } | ConvertTo-Json
$confirm = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $confirmBody -ContentType 'application/json' -WebSession $sv
Write-Host "  HTTP 200 — totalQty=$($confirm.totalQty), receiptId=$($confirm.allocations[0].receiptId), poNumber=$($confirm.allocations[0].poNumber)"

# Final cleanup so PL-2900 net=0 + PO-2405-001 back to full
Invoke-RestMethod -Uri "$base/api/receipts/$($confirm.allocations[0].receiptId)/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $sv | Out-Null
Write-Host ""
Write-Host "Final cleanup done." -ForegroundColor DarkGray
