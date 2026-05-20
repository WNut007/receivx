# Smoke test: §7.2 Receive + §7.3 Cancel + §7.12 closed-pull rejection.
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$session = $null

$WH_01 = '22222222-2222-2222-2222-000000000001'
$PullItemOpen = '44444444-4444-4444-2844-000000000001'  # PL-2844 in_progress, hour 12, expected 3200
$PullItemClosed = '44444444-4444-4444-2840-000000000001'  # PL-2840 closed, hour 12, expected 11000

function Step($name) { Write-Host "`n--- $name ---" -ForegroundColor Cyan }
function OK($msg) { Write-Host "PASS: $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }

# ---------- 1. Login ----------
Step "Login (sadmin / WH-01)"
$loginBody = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$resp = Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable session
if ($resp.StatusCode -ne 200) { Fail "Login expected 200, got $($resp.StatusCode)" }
OK "Login ok"

# ---------- 2. Happy receive ----------
Step "Receive 100 pcs (PL-2844, hour 12)"
$body = @{ pullItemId = $PullItemOpen; hourOfDay = 12; qty = 100; qcStatus = 'pending'; note = 'smoke-test-1' } | ConvertTo-Json
$resp = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if ($resp.newReceivedQty -ne 100) { Fail "Expected newReceivedQty=100, got $($resp.newReceivedQty)" }
$firstReceiptId = $resp.receiptId
OK "Receipt $firstReceiptId, newReceivedQty=$($resp.newReceivedQty)"

# ---------- 3. Receive cap violation ----------
Step "Receive 9999999 (should 409 cap-at-expected)"
$body = @{ pullItemId = $PullItemOpen; hourOfDay = 12; qty = 9999999 } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) {
        Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)"
    }
    OK "409 Conflict on cap-violation"
}

# ---------- 4. Receive zero qty ----------
Step "Receive 0 (should 409 - non-positive)"
$body = @{ pullItemId = $PullItemOpen; hourOfDay = 12; qty = 0 } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    OK "409 on Qty=0"
}

# ---------- 5. Receive against closed pull ----------
Step "Receive against PL-2840 (closed) (should 409)"
$body = @{ pullItemId = $PullItemClosed; hourOfDay = 12; qty = 1 } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 409 closed pull, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    OK "409 on closed-pull receive"
}

# ---------- 6. Cancel the receipt ----------
Step "Cancel receipt $firstReceiptId"
$body = @{ reason = 'miscount'; note = 'rolling back smoke test' } | ConvertTo-Json
$resp = Invoke-RestMethod -Uri "$base/api/receipts/$firstReceiptId/cancel" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
if ($resp.newReceivedQty -ne 0) { Fail "Expected newReceivedQty=0 after cancel, got $($resp.newReceivedQty)" }
OK "Reversal $($resp.reversalReceiptId), newReceivedQty=$($resp.newReceivedQty)"

# ---------- 7. Cancel again — should 409 (already voided) ----------
Step "Cancel same receipt again (should 409 already voided)"
try {
    Invoke-WebRequest -Uri "$base/api/receipts/$firstReceiptId/cancel" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 409 already voided, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    OK "409 on re-cancel"
}

# ---------- 8. Cancel with bad reason ----------
Step "Cancel a fresh receipt with bad reason (should 409)"
$body = @{ pullItemId = $PullItemOpen; hourOfDay = 12; qty = 50 } | ConvertTo-Json
$fresh = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
$body = @{ reason = 'pizza' } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/receipts/$($fresh.receiptId)/cancel" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
    Fail "Expected 409 invalid reason, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    OK "409 on invalid reason"
}
# clean up the fresh receipt
$body = @{ reason = 'other'; note = 'cleanup' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/receipts/$($fresh.receiptId)/cancel" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null

# ---------- 9. View truth check ----------
Step "Net received via vw_PullItemReceived = 0 (after both cancels)"
$net = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT ISNULL(SUM(NetReceived),0) FROM dbo.vw_PullItemReceived WHERE PullItemId='$PullItemOpen' AND HourOfDay=12;"
if ($net.Trim() -ne '0') { Fail "Expected net=0, got '$($net.Trim())'" }
OK "vw_PullItemReceived net = 0"

Write-Host "`nAll smoke tests passed." -ForegroundColor Green
