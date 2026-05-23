# Smoke test: §3.5 / §7.2a lock-aware Receive
#   (1) PL-2847 lock=0 receive 100 PCBA → 200, single alloc PO-2401-018, audit Scope: warehouse-wide FIFO
#   (2) PL-2900 lock=1 receive 50 PCBA → 200, single alloc PO-2405-001, audit Scope: pull-locked
#   (3) PL-2900 lock=1 receive 600 (cap 500) → 409 Insufficient
#   (4) PL-2901 lock=1 (no PO) → 409 "No PO linked"
#   (5) qty=0 → 400 ValidationException (now consistent with Preview)
#   (6) PL-2840 closed → 409
#   (7) FIFO split: PL-2847 receive (first-line-remaining + 1) → multi-allocation spanning 2 POs
#   (8) Cancel restores qty to the SAME PO line the original consumed (no FIFO reverse-walk)
#
# Assumes ReceivingOps.Web on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$session = $null

$WH_01 = '22222222-2222-2222-2222-000000000001'

$PI_2847_PCBA   = '44444444-4444-4444-2847-000000000001'  # PL-2847 lock=0
$PI_2900_PCBA   = '44444444-4444-4444-2900-000000000001'  # PL-2900 lock=1, linked to PO-2405-001
$PI_2901_PCBA   = '44444444-4444-4444-2901-000000000001'  # PL-2901 lock=1, NO linked PO
$PI_2840_CLOSED = '44444444-4444-4444-2840-000000000001'  # PL-2840 closed

$receiptsCreated = @()

function Step($name) { Write-Host "`n--- $name ---" -ForegroundColor Cyan }
function OK($msg)    { Write-Host "PASS: $msg" -ForegroundColor Green }
function Fail($msg)  { Write-Host "FAIL: $msg" -ForegroundColor Red; CleanupReceipts; exit 1 }

function Q($sql) {
    (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
}

function LatestReceiveAudit() {
    Q @"
SELECT TOP 1 Message
FROM   dbo.AuditLog
WHERE  ActionType = 'receive'
ORDER BY Id DESC;
"@
}

function CleanupReceipts {
    foreach ($rid in $receiptsCreated) {
        try {
            $body = @{ reason='other'; note='phase-4b smoke cleanup' } | ConvertTo-Json
            Invoke-RestMethod -Uri "$base/api/receipts/$rid/cancel" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
        } catch { }   # ignore failures during teardown
    }
    RestoreHourCap
}

# v2.1 Hour Cap context: this smoke was written under §7.1 v2 where per-hour
# ExpectedQty was a planning hint and over-receive was allowed. Hour Cap Phase 6.1
# defaulted every existing pull to LockHourCap=1 (strict), which blocks
# scenarios (1) + (7) here (receive past the hour's ExpectedQty). We flip
# the test pulls to loose at setup and restore to strict at teardown so the
# §3.5 lock-aware Receive scenarios this smoke owns stay backward-compatible
# without rewriting the test data.
$HCFlipPulls = "'PL-2847','PL-2900','PL-2901','PL-2840'"

function FlipHourCapLoose {
    $sql = "SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON; UPDATE dbo.Pulls SET LockHourCap = 0 WHERE PullNumber IN ($HCFlipPulls);"
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}

function RestoreHourCap {
    $sql = "SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON; UPDATE dbo.Pulls SET LockHourCap = 1 WHERE PullNumber IN ($HCFlipPulls);"
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}

FlipHourCapLoose

# ---------- Login ----------
Step "Login (sadmin / WH-01)"
$loginBody = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
$r = Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable session
if ($r.StatusCode -ne 200) { Fail "Login expected 200, got $($r.StatusCode)" }
OK "Login ok"

# ============================================================================
# (1) PL-2847 lock=0 receive 100 PCBA hour 7 → single alloc + warehouse-wide audit
# ============================================================================
Step "(1) PL-2847 lock=0 receive 100 PCBA hour 7"
$body = @{ pullItemId=$PI_2847_PCBA; hourOfDay=7; qty=100; qcStatus='pending'; note='4b-1' } | ConvertTo-Json
$rr = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if ($rr.totalQty -ne 100) { Fail "Expected totalQty=100, got $($rr.totalQty)" }
if ($rr.allocations.Count -ne 1) { Fail "Expected 1 allocation, got $($rr.allocations.Count)" }
if ($rr.allocations[0].poNumber -ne 'PO-2401-018') { Fail "Expected PO-2401-018, got $($rr.allocations[0].poNumber)" }
$receiptsCreated += $rr.allocations[0].receiptId

$audit = LatestReceiveAudit
if ($audit -notmatch 'Scope: warehouse-wide FIFO') { Fail "Audit missing 'Scope: warehouse-wide FIFO'. Got: $audit" }
if ($audit -notmatch '100@PO-2401-018')            { Fail "Audit missing '100@PO-2401-018'. Got: $audit" }
OK "single alloc PO-2401-018, audit Scope=warehouse-wide FIFO"

# ============================================================================
# (2) PL-2900 lock=1 receive 50 PCBA hour 12 → single alloc PO-2405-001 + pull-locked audit
# ============================================================================
Step "(2) PL-2900 lock=1 receive 50 PCBA hour 12"
$body = @{ pullItemId=$PI_2900_PCBA; hourOfDay=12; qty=50; qcStatus='pending'; note='4b-2' } | ConvertTo-Json
$rr = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if ($rr.totalQty -ne 50) { Fail "Expected totalQty=50, got $($rr.totalQty)" }
if ($rr.allocations.Count -ne 1) { Fail "Expected 1 allocation, got $($rr.allocations.Count)" }
if ($rr.allocations[0].poNumber -ne 'PO-2405-001') { Fail "Expected PO-2405-001, got $($rr.allocations[0].poNumber)" }
$receiptsCreated += $rr.allocations[0].receiptId
$rcpt2900 = $rr.allocations[0].receiptId
$poLine2900 = $rr.allocations[0].purchaseOrderLineId

$audit = LatestReceiveAudit
if ($audit -notmatch 'Scope: pull-locked')   { Fail "Audit missing 'Scope: pull-locked'. Got: $audit" }
if ($audit -notmatch '50@PO-2405-001')       { Fail "Audit missing '50@PO-2405-001'. Got: $audit" }
OK "single alloc PO-2405-001 line=$poLine2900, audit Scope=pull-locked"

# ============================================================================
# (3) PL-2900 lock=1 receive 600 (cap 500-50=450 now) → 409 Insufficient
# ============================================================================
Step "(3) PL-2900 lock=1 receive 600 → 409 Insufficient"
$body = @{ pullItemId=$PI_2900_PCBA; hourOfDay=12; qty=600; qcStatus='pending' } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'Insufficient PO capacity') { Fail "Title missing 'Insufficient PO capacity'. Got: $msg" }
    if ($msg -notmatch 'Need 600')                 { Fail "Title missing 'Need 600'. Got: $msg" }
    OK "409 Insufficient PO capacity (Need 600, have 450)"
}

# ============================================================================
# (4) PL-2901 lock=1 no PO → 409 "No PO linked"
# ============================================================================
Step "(4) PL-2901 lock=1 (no PO) receive 25 → 409 No PO linked"
$body = @{ pullItemId=$PI_2901_PCBA; hourOfDay=12; qty=25; qcStatus='pending' } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'No PO linked') { Fail "Title missing 'No PO linked'. Got: $msg" }
    OK "409 'No PO linked to this pull'"
}

# ============================================================================
# (5) qty=0 → 400 ValidationException (now consistent with Preview)
# ============================================================================
Step "(5) qty=0 receive → 400 ValidationException"
$body = @{ pullItemId=$PI_2847_PCBA; hourOfDay=7; qty=0 } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 400, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 400) { Fail "Expected 400, got $code" }
    OK "400 on qty=0 (was 409 pre-4b)"
}

# ============================================================================
# (6) PL-2840 closed → 409
# ============================================================================
Step "(6) PL-2840 closed pull → 409"
$body = @{ pullItemId=$PI_2840_CLOSED; hourOfDay=12; qty=1 } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'closed') { Fail "Title missing 'closed'. Got: $msg" }
    OK "409 'Pull is closed and cannot accept receipts'"
}

# ============================================================================
# (7) FIFO split — receive qty = (PO-2401-018 line 1 remaining) + 1 → 2 allocations
# ============================================================================
Step "(7) FIFO split: receive (first-line-remaining + 1) → multi-alloc"
$firstLineRemaining = [int](Q @"
SELECT TOP 1 (OrderedQty - ReceivedQty) AS Remaining
FROM   dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE  po.WarehouseId = '$WH_01'
  AND  po.Status = 'open'
  AND  pol.ItemCode = 'PCBA-AX450-R2'
ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;
"@)
Write-Host "  First-line remaining (FIFO): $firstLineRemaining pcs on PO-2401-018"
$splitQty = $firstLineRemaining + 1
$body = @{ pullItemId=$PI_2847_PCBA; hourOfDay=8; qty=$splitQty; qcStatus='pending'; note='4b-split' } | ConvertTo-Json
$rr = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if ($rr.totalQty -ne $splitQty) { Fail "Expected totalQty=$splitQty, got $($rr.totalQty)" }
if ($rr.allocations.Count -lt 2) { Fail "Expected >= 2 allocations (split), got $($rr.allocations.Count)" }
if ($rr.allocations[0].poNumber -ne 'PO-2401-018') { Fail "Expected slice 1 = PO-2401-018, got $($rr.allocations[0].poNumber)" }
if ($rr.allocations[0].qty -ne $firstLineRemaining) { Fail "Expected slice 1 qty=$firstLineRemaining, got $($rr.allocations[0].qty)" }
if ($rr.allocations[1].poNumber -ne 'PO-2401-019') { Fail "Expected slice 2 = PO-2401-019, got $($rr.allocations[1].poNumber)" }
if ($rr.allocations[1].qty -ne 1) { Fail "Expected slice 2 qty=1, got $($rr.allocations[1].qty)" }
foreach ($a in $rr.allocations) { $receiptsCreated += $a.receiptId }
OK "split: ${firstLineRemaining}@PO-2401-018 + 1@PO-2401-019"

# Verify the audit summary captures the split
$audit = LatestReceiveAudit
if ($audit -notmatch 'Scope: warehouse-wide FIFO') { Fail "Split audit Scope missing. Got: $audit" }
if ($audit -notmatch "$firstLineRemaining@PO-2401-018") { Fail "Split audit missing slice 1. Got: $audit" }
if ($audit -notmatch '1@PO-2401-019') { Fail "Split audit missing slice 2. Got: $audit" }
OK "audit summary captures both slices + scope"

# ============================================================================
# (8) Cancel restores qty to the SAME PO line (no FIFO reverse-walk)
#     Use the rcpt2900 from scenario (2): PO-2405-001 received 50.
#     After cancel, vw_PurchaseOrderAvailability remaining on that line returns to 500.
# ============================================================================
Step "(8) Cancel rcpt from PL-2900 restores PO-2405-001 line"
$body = @{ reason='miscount'; note='4b cancel test' } | ConvertTo-Json
$cr = Invoke-RestMethod -Uri "$base/api/receipts/$rcpt2900/cancel" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if (-not $cr.poLineRestored) { Fail "cancel response missing poLineRestored" }
if ($cr.poLineRestored.poNumber -ne 'PO-2405-001') { Fail "Expected restore on PO-2405-001, got $($cr.poLineRestored.poNumber)" }
if ($cr.poLineRestored.newRemainingQty -ne 500) { Fail "Expected newRemainingQty=500 (full), got $($cr.poLineRestored.newRemainingQty)" }
# remove the cancelled receipt from cleanup list (it's already cancelled)
$receiptsCreated = $receiptsCreated | Where-Object { $_ -ne $rcpt2900 }
OK "cancel restored 50 to PO-2405-001 (newRemainingQty=500)"

# ============================================================================
# Cleanup — cancel everything we created (idempotent re-run convergence)
# ============================================================================
Step "Cleanup created receipts"
$count = $receiptsCreated.Count
CleanupReceipts
OK "Cancelled $count outstanding receipt(s) from this run"

# ============================================================================
# Idempotency / regression check
# ============================================================================
Step "Net received on PL-2900 hour 12 = 0 (smoke neutral)"
$net = Q @"
SELECT ISNULL(SUM(NetReceived),0)
FROM   dbo.vw_PullItemReceived
WHERE  PullItemId = '$PI_2900_PCBA' AND HourOfDay = 12;
"@
if ($net -ne '0') { Fail "Expected net=0 on PL-2900 hour 12 after cleanup, got '$net'" }
OK "PL-2900 hour 12 net = 0"

# v2.1 Hour Cap teardown — restore seeded test pulls to strict so the next
# verify-hourcap-6.1 run stays green and other smokes don't get unexpected
# loose behavior.
RestoreHourCap

Write-Host "`nPhase 4b smoke passed (all 8 scenarios)." -ForegroundColor Green
