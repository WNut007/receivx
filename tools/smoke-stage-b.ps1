# Stage B smoke: confirms the receiving page can fully drive itself from APIs.
# Covers the endpoints the receiving.js client touches:
#   GET  /api/pulls/by-number/{pullNumber}      (startup fetch)
#   GET  /api/receipts/pull/{pullId}             (drawer load)
#   POST /api/receipts                           (confirm receipt)
#   POST /api/receipts/{id}/cancel               (reverse-entry)
# And the warehouse-scoping rule on by-number for non-admins.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH01 = '22222222-2222-2222-2222-000000000001'
$WH02 = '22222222-2222-2222-2222-000000000002'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# ---------------------------------------------------------------------------
Step "Login as sadmin / WH-01"
$sess = Login 'sadmin' 'admin' $WH01
OK "Logged in"

# ---------------------------------------------------------------------------
Step "GET /api/pulls/by-number/PL-2844 (open pull in WH-01)"
$pull = Invoke-RestMethod -Uri "$base/api/pulls/by-number/PL-2844" -WebSession $sess
if (-not $pull.id) { Fail "No pull id returned" }
if ($pull.pullNumber -ne 'PL-2844') { Fail "Expected PL-2844, got $($pull.pullNumber)" }
if (-not $pull.items -or $pull.items.Count -eq 0) { Fail "Pull has no items" }
$firstItem = $pull.items[0]
$firstWindow = $firstItem.windows | Where-Object { $_.expectedQty -gt $_.receivedQty } | Select-Object -First 1
if (-not $firstWindow) { Fail "No window with remaining qty on first item" }
OK "Pull resolved by number — $($pull.items.Count) item(s), warehouse $($pull.warehouseCode), status $($pull.status)"

# ---------------------------------------------------------------------------
Step "GET /api/pulls/by-number/PL-DOES-NOT-EXIST → 404"
try {
    Invoke-WebRequest -Uri "$base/api/pulls/by-number/PL-DOES-NOT-EXIST" -WebSession $sess -ErrorAction Stop | Out-Null
    Fail "Expected 404"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) { Fail "Expected 404, got $($_.Exception.Response.StatusCode.value__)" }
    OK "404 on unknown pull number"
}

# ---------------------------------------------------------------------------
Step "POST /api/receipts using pullItemId from by-number lookup"
$body = @{
    pullItemId  = $firstItem.id
    hourOfDay   = $firstWindow.hourOfDay
    qty         = 50
    qcStatus    = 'pending'
    note        = 'stage-b smoke'
} | ConvertTo-Json
$resp = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $sess
if ($resp.newReceivedQty -ne ($firstWindow.receivedQty + 50)) {
    Fail "newReceivedQty=$($resp.newReceivedQty), expected $($firstWindow.receivedQty + 50)"
}
$receiptId = $resp.allocations[0].receiptId   # v2: receive returns allocations[]; single-line in this smoke
OK "Receipt $receiptId, newReceivedQty=$($resp.newReceivedQty)"

# ---------------------------------------------------------------------------
Step "GET /api/receipts/pull/{guid} returns the new receipt with the right shape"
$journal = Invoke-RestMethod -Uri "$base/api/receipts/pull/$($pull.id)" -WebSession $sess
$row = $journal | Where-Object { $_.id -eq $receiptId } | Select-Object -First 1
if (-not $row) { Fail "Receipt $receiptId not found in journal" }
foreach ($prop in @('id','pullId','pullNumber','warehouseCode','itemCode','itemDescription','hourOfDay','qtyReceived','receivedByName','receivedAt','kind')) {
    if (-not ($row.PSObject.Properties.Name -contains $prop)) { Fail "Journal row missing property '$prop'" }
}
if ($row.kind -ne 'receive') { Fail "Expected kind=receive, got $($row.kind)" }
OK "Journal row contains all expected camelCase fields, kind=$($row.kind)"

# ---------------------------------------------------------------------------
Step "POST /api/receipts/{id}/cancel — reversal"
$body = @{ reason = 'miscount'; note = 'stage-b smoke rollback' } | ConvertTo-Json
$cancel = Invoke-RestMethod -Uri "$base/api/receipts/$receiptId/cancel" -Method POST -Body $body -ContentType 'application/json' -WebSession $sess
if ($cancel.newReceivedQty -ne $firstWindow.receivedQty) {
    Fail "After cancel: newReceivedQty=$($cancel.newReceivedQty), expected $($firstWindow.receivedQty)"
}
OK "Reversal $($cancel.reversalReceiptId), newReceivedQty=$($cancel.newReceivedQty)"

# ---------------------------------------------------------------------------
Step "Journal now contains both rows (original voided + reversal)"
$journal2 = Invoke-RestMethod -Uri "$base/api/receipts/pull/$($pull.id)" -WebSession $sess
$orig = $journal2 | Where-Object { $_.id -eq $receiptId } | Select-Object -First 1
$rev  = $journal2 | Where-Object { $_.id -eq $cancel.reversalReceiptId } | Select-Object -First 1
if (-not $orig) { Fail "Original missing from journal" }
if (-not $rev)  { Fail "Reversal missing from journal" }
if ($orig.kind -ne 'voided')   { Fail "Original kind=$($orig.kind), expected voided" }
if ($rev.kind  -ne 'reversal') { Fail "Reversal kind=$($rev.kind), expected reversal" }
if ($rev.qtyReceived -ge 0)    { Fail "Reversal qty should be negative, got $($rev.qtyReceived)" }
if ($rev.reversesReceiptId -ne $receiptId) { Fail "Reversal doesn't link back to original" }
OK "Linkage: original→voided, reversal→reversal, reverses=$($rev.reversesReceiptId)"

# ---------------------------------------------------------------------------
Step "Warehouse scoping: log in as swattana into WH-02, then by-number on WH-01's PL-2848 → 403"
$sess2 = Login 'swattana' 'demo1234' $WH02
try {
    Invoke-WebRequest -Uri "$base/api/pulls/by-number/PL-2848" -WebSession $sess2 -ErrorAction Stop | Out-Null
    Fail "Expected 403 (PL-2848 is WH-01, session is WH-02)"
} catch {
    $sc = $_.Exception.Response.StatusCode.value__
    if ($sc -ne 403) { Fail "Expected 403, got $sc" }
    OK "by-number enforces warehouse scoping for non-admins"
}

Write-Host "`nStage B API smoke passed." -ForegroundColor Green
