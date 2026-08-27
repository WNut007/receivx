# Smoke test: §3.5 lock-aware FIFO Preview
#   (a) PL-2847 lock=0 → FIFO across warehouse; PO-2401-018 wins
#   (b) PL-2900 lock=1 → pull-locked; only sees PO-2405-001
#   (c) PL-2900 lock=1 + qty > PO-2405-001 remaining → 409 Insufficient
#   (d) PL-2901 lock=1 + no PO linked → 409 "No PO linked"
#   (e) qty <= 0 → 400 (ValidationException)
#   (f) Closed pull (PL-2840) → 409 "Pull is closed"
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$session = $null

$WH_01 = '22222222-2222-2222-2222-000000000001'

# PullItem GUIDs for PCBA-AX450-R2 in each pull
$PI_2847_PCBA  = '44444444-4444-4444-2847-000000000001'  # PL-2847 lock=0
$PI_2900_PCBA  = '44444444-4444-4444-2900-000000000001'  # PL-2900 lock=1, linked to PO-2405-001
$PI_2901_PCBA  = '44444444-4444-4444-2901-000000000001'  # PL-2901 lock=1, NO PO linked
$PI_2840_CLOSED = '44444444-4444-4444-2840-000000000001' # PL-2840 closed (SUMMARY)

function Step($name) { Write-Host "`n--- $name ---" -ForegroundColor Cyan }
function OK($msg) { Write-Host "PASS: $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }

# ---------- Login ----------
Step "Login (sadmin / WH-01)"
$loginBody = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$resp = Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable session
if ($resp.StatusCode -ne 200) { Fail "Login expected 200, got $($resp.StatusCode)" }
OK "Login ok"

# ============================================================================
# (a) PL-2847 lock=0 → warehouse-wide FIFO
#     Expect first allocation from PO-2401-018 (oldest WH-01 PO with PCBA capacity)
# ============================================================================
Step "(a) PL-2847 lock=0 preview qty=500 PCBA → FIFO winner = PO-2401-018"
$p = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$PI_2847_PCBA&qty=500" -WebSession $session
if ($p.scope -ne 'warehouse-wide') { Fail "Expected scope='warehouse-wide', got '$($p.scope)'" }
if ($p.shortage -ne 0)              { Fail "Expected shortage=0, got $($p.shortage)" }
if (-not $p.allocations -or $p.allocations.Count -lt 1) { Fail "No allocations returned" }
if ($p.allocations[0].poNumber -ne 'PO-2401-018') {
    Fail "Expected FIFO winner PO-2401-018, got $($p.allocations[0].poNumber)"
}
if ($p.allocations[0].qty -ne 500) {
    Fail "Expected first allocation qty=500, got $($p.allocations[0].qty)"
}
OK "warehouse-wide scope, FIFO winner PO-2401-018 qty=500, totalAllocatable=$($p.totalAllocatable)"

# ============================================================================
# (b) PL-2900 lock=1 → pull-locked; only PO-2405-001
# ============================================================================
Step "(b) PL-2900 lock=1 preview qty=100 PCBA → pull-locked, only PO-2405-001"
$p = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$PI_2900_PCBA&qty=100" -WebSession $session
if ($p.scope -ne 'pull-locked') { Fail "Expected scope='pull-locked', got '$($p.scope)'" }
if ($p.shortage -ne 0)          { Fail "Expected shortage=0, got $($p.shortage)" }
if ($p.allocations.Count -ne 1) { Fail "Expected exactly 1 allocation, got $($p.allocations.Count)" }
if ($p.allocations[0].poNumber -ne 'PO-2405-001') {
    Fail "Expected only PO-2405-001, got $($p.allocations[0].poNumber)"
}
if ($p.allocations[0].qty -ne 100) {
    Fail "Expected allocation qty=100, got $($p.allocations[0].qty)"
}
if ($p.totalAllocatable -ne 500) {
    Fail "Expected totalAllocatable=500 (PO-2405-001 remaining), got $($p.totalAllocatable)"
}
OK "pull-locked scope, only PO-2405-001 visible, allocation=100, totalAllocatable=500"

# ============================================================================
# (c) PL-2900 lock=1 + qty > capacity → 409 "Insufficient PO capacity"
# ============================================================================
Step "(c) PL-2900 lock=1 preview qty=600 (> 500 cap on PO-2405-001) → 409"
try {
    Invoke-WebRequest -Uri "$base/api/receipts/preview?pullItemId=$PI_2900_PCBA&qty=600" -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $body = $_.ErrorDetails.Message
    if ($body -notmatch 'Insufficient PO capacity') { Fail "Expected title to mention 'Insufficient PO capacity'. Got: $body" }
    if ($body -notmatch 'Need 600') { Fail "Expected detail to include 'Need 600'. Got: $body" }
    if ($body -notmatch 'have 500') { Fail "Expected detail to include 'have 500'. Got: $body" }
    OK "409 Insufficient PO capacity, message includes 'Need 600' + 'have 500'"
}

# ============================================================================
# (d) PL-2901 lock=1 + no PO linked → 409 "No PO linked"
# ============================================================================
Step "(d) PL-2901 lock=1 (no PO linked) preview qty=50 → 409 No PO linked"
try {
    Invoke-WebRequest -Uri "$base/api/receipts/preview?pullItemId=$PI_2901_PCBA&qty=50" -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $body = $_.ErrorDetails.Message
    if ($body -notmatch 'No PO linked') { Fail "Expected title 'No PO linked'. Got: $body" }
    OK "409 'No PO linked to this pull'"
}

# ============================================================================
# (e) qty = 0 → 400, but no longer because zero is invalid
#
# db/047 §2d turned qty=0 into a legitimate operation: a short close, recording no
# Receipts row. So "Quantity must be positive" is gone — zero is refused only when
# the operator has NOT ticked accept-variance, and the message now names the remedy.
# The status is unchanged at 400; only the reason moved.
#
# Rewriting an assertion to match the code is normally a warning sign. It is right
# here because the behaviour change was deliberate, is documented in CLAUDE.md and
# in ReceiptService's §2d comment, and already shipped in the sibling smokes
# (smoke-variance-section8, smoke-receive step 3). The assertion went stale; the
# product did not regress. The ticked counterpart below is asserted too, so this
# step now covers the decision rather than just its refusal half.
# ============================================================================
Step "(e) qty=0 without the tick → 400 ZERO_QTY_WITHOUT_VARIANCE"
try {
    Invoke-WebRequest -Uri "$base/api/receipts/preview?pullItemId=$PI_2847_PCBA&qty=0" -WebSession $session | Out-Null
    Fail "Expected 400, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 400) { Fail "Expected 400, got $code" }
    $body = $_.ErrorDetails.Message
    $pd = $null; try { $pd = $body | ConvertFrom-Json } catch { }
    if ($pd.code -ne 'ZERO_QTY_WITHOUT_VARIANCE') { Fail "Expected code ZERO_QTY_WITHOUT_VARIANCE. Got: $body" }
    # The remedy has to be in the message or the operator has no way to discover it.
    if ($body -notmatch 'accept variance') { Fail "Expected the message to name the tick. Got: $body" }
    OK "400 ZERO_QTY_WITHOUT_VARIANCE, message names the tick"
}

Step "(e'') qty=0 WITH the tick → 200 close-only preview, no allocation"
# No hour parameter: PL-2847's PCBA is scheduled across several windows, and a
# variance close is a SKU-level act — see (e''') for the guard that enforces that.
$prev0 = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$PI_2847_PCBA&qty=0&varianceAccepted=true" -WebSession $session
# A short close consumes no PO capacity, so the plan must be empty rather than a
# zero-quantity slice — that is what makes §2d "records nothing" true on the wire.
if ($prev0.allocations.Count -ne 0) { Fail "close-only preview should allocate nothing, got $($prev0.allocations.Count) slice(s)" }
if ($prev0.shortage -ne 0)          { Fail "close-only preview should report no shortage, got $($prev0.shortage)" }
OK "200 with an empty allocation plan (scope=$($prev0.scope), allocatable=$($prev0.totalAllocatable))"

Step "(e''') qty=0 + tick + a single hour on a multi-window SKU → 400 MULTI_WINDOW_NOT_SUPPORTED"
try {
    Invoke-WebRequest -Uri "$base/api/receipts/preview?pullItemId=$PI_2847_PCBA&qty=0&hour=7&varianceAccepted=true" -WebSession $session | Out-Null
    Fail "Expected 400, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 400) { Fail "Expected 400, got $code" }
    $pd = $null; try { $pd = $_.ErrorDetails.Message | ConvertFrom-Json } catch { }
    if ($pd.code -ne 'MULTI_WINDOW_NOT_SUPPORTED') { Fail "Expected MULTI_WINDOW_NOT_SUPPORTED. Got: $($_.ErrorDetails.Message)" }
    OK "400 MULTI_WINDOW_NOT_SUPPORTED — closing one slot of a multi-window SKU is refused"
}

Step "(e') qty=-3 → 400 ValidationException"
try {
    Invoke-WebRequest -Uri "$base/api/receipts/preview?pullItemId=$PI_2847_PCBA&qty=-3" -WebSession $session | Out-Null
    Fail "Expected 400, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 400) { Fail "Expected 400, got $code" }
    OK "400 on negative qty"
}

# ============================================================================
# (f) Closed pull (PL-2840) → 409 "Pull is closed"
# ============================================================================
Step "(f) PL-2840 (closed) preview → 409 'Pull is closed'"
try {
    Invoke-WebRequest -Uri "$base/api/receipts/preview?pullItemId=$PI_2840_CLOSED&qty=1" -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $body = $_.ErrorDetails.Message
    if ($body -notmatch 'closed') { Fail "Expected title to mention 'closed'. Got: $body" }
    OK "409 'Pull is closed'"
}

# ============================================================================
# Bonus: ReceiveAsync untouched (4a stand-alone) — existing receive still works
# ============================================================================
Step "Sanity: ReceiveAsync untouched — happy receive still 200"
$body = @{ pullItemId = '44444444-4444-4444-2844-000000000001'; hourOfDay = 12; qty = 50; qcStatus = 'pending'; note = 'phase-4a-sanity' } | ConvertTo-Json
$rr = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if ($rr.totalQty -ne 50) { Fail "Expected receive totalQty=50, got $($rr.totalQty)" }
$cleanupId = $rr.allocations[0].receiptId
OK "Receive untouched (receiptId=$cleanupId)"

# Cleanup the sanity receipt so re-runs converge
$cancelBody = @{ reason = 'other'; note = 'phase-4a smoke cleanup' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/receipts/$cleanupId/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $session | Out-Null

Write-Host "`nPhase 4a smoke passed (all 9 scenarios)." -ForegroundColor Green
