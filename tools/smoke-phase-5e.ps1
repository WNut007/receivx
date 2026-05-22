# Phase 5e — scripted end-to-end happy path
#
# Drives the §3.5 / §7.x stack from procurement (create locked pull + linked PO)
# through receiving (preview + receive + cancel) to admin (close PO + 409 on edit).
# Each step asserts the contract the UI relies on; this doubles as a permanent
# regression for the locked-pull mode B path.
#
# Steps (mirror the spec 1:1):
#   1. POST /api/pulls           — create PL-SMOKE-5E-#### with LockPoByPull=true
#   2. POST /api/pos             — create PO-SMOKE-5E-#### linked to that pull
#      + POST /api/pos/{id}/lines — add PCBA-AX450-R2 line (OrderedQty=500)
#   3. GET /api/pos?warehouseId  — verify PO surfaces with PullId set
#   4. SQL INSERT                — add PullItem + PullItemWindow (no API for this)
#   5. GET /api/pulls/by-number  — PullDetail.lockPoByPull = true
#      GET /api/receipts/preview — scope='pull-locked', allocations[0].poNumber matches
#      POST /api/receipts        — 200, allocations[0].qty = 200
#   6. POST /api/receipts/{id}/cancel — 200, NewReceivedQty=0, PoLineRestored set
#   7. GET /api/transactions     — both receive + reversal rows with PO context
#   8. PUT /api/pulls/{id} flipping lockPoByPull → 409 (§7.15)
#   9. POST /api/pos/{id}/close  — 204
#  10. PUT /api/pos/{id} on closed PO → 409 "Cannot edit a closed PO"
#
# Pre/post SQL cleanup (PL-SMOKE-5E-* and PO-SMOKE-5E-*) so verify-phase-3.5
# stays green between runs.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

# Cleanup must drop in FK order: Receipts → PullItemWindows → PullItems → Pulls,
# then PurchaseOrderLines → PurchaseOrders. Filtered IX_PO_Pull mandates
# SET QUOTED_IDENTIFIER ON for DML on Pulls (memory note from Phase 4d).
function SqlCleanup {
    $sql = @'
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
DELETE r FROM dbo.Receipts r
  INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
 WHERE p.PullNumber LIKE 'PL-SMOKE-5E-%';
DELETE piw FROM dbo.PullItemWindows piw
  INNER JOIN dbo.PullItems pi ON pi.Id = piw.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
 WHERE p.PullNumber LIKE 'PL-SMOKE-5E-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
 WHERE p.PullNumber LIKE 'PL-SMOKE-5E-%';
DELETE pol FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
 WHERE po.PoNumber LIKE 'PO-SMOKE-5E-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-SMOKE-5E-%';
DELETE FROM dbo.Pulls         WHERE PullNumber LIKE 'PL-SMOKE-5E-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}
function Q($sql) {
    return (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
}

# Pre-test cleanup
SqlCleanup

# ----------------------------------------------------------------------------
# Login as admin — full surface
# ----------------------------------------------------------------------------
Step "Login (sadmin / WH-01)"
$loginBody = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable sv | Out-Null
OK "Login ok"

# Unique numbers per run
$tick = [DateTime]::UtcNow.Ticks % 1000000
$pullNumber = "PL-SMOKE-5E-$tick"
$poNumber   = "PO-SMOKE-5E-$tick"

# ============================================================================
# STEP 1 — Create locked pull
# ============================================================================
Step "Step 1: POST /api/pulls — create $pullNumber with lockPoByPull=true"
$pullBody = @{
    pullNumber   = $pullNumber
    warehouseId  = $WH_01
    pullDate     = (Get-Date).ToString('yyyy-MM-dd')
    notes        = 'Phase 5e end-to-end'
    lockPoByPull = $true
} | ConvertTo-Json
$pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv
if ($pull.lockPoByPull -ne $true) { Fail "Expected lockPoByPull=true, got $($pull.lockPoByPull)" }
$pullId = $pull.id
OK "Pull $pullNumber created (Id $($pullId.ToString().Substring(0,8))), locked"

# ============================================================================
# STEP 2 — Create linked PO + add line
# ============================================================================
Step "Step 2a: POST /api/pos — create $poNumber linked to $pullNumber"
$poBody = @{
    poNumber    = $poNumber
    warehouseId = $WH_01
    vendorCode  = 'VND-E2E'
    vendorName  = 'E2E Vendor'
    orderDate   = (Get-Date).ToString('yyyy-MM-dd')
    notes       = 'Phase 5e linked PO'
    pullId      = $pullId
    lines       = @()
} | ConvertTo-Json
$po = Invoke-RestMethod -Uri "$base/api/pos" -Method POST -Body $poBody -ContentType 'application/json' -WebSession $sv
if ($po.pullId -ne $pullId) { Fail "Expected pullId=$pullId, got $($po.pullId)" }
$poId = $po.id
OK "PO $poNumber created (Id $($poId.ToString().Substring(0,8))), pullId set"

Step "Step 2b: POST /api/pos/{id}/lines — add PCBA-AX450-R2 line (OrderedQty=500)"
$lineBody = @{ lineNumber = 1; itemCode = 'PCBA-AX450-R2'; description = 'PCBA AX450 Rev 2'; orderedQty = 500 } | ConvertTo-Json
$line = Invoke-RestMethod -Uri "$base/api/pos/$poId/lines" -Method POST -Body $lineBody -ContentType 'application/json' -WebSession $sv
if (-not $line.id) { Fail "AddLine returned no id" }
OK "Line added (Id $($line.id.ToString().Substring(0,8)))"

# ============================================================================
# STEP 3 — Filtered list returns the linked PO
# ============================================================================
Step "Step 3: GET /api/pos?warehouseId — list contains $poNumber with pullId=$pullId"
$listed = Invoke-RestMethod -Uri "$base/api/pos?warehouseId=$WH_01" -WebSession $sv
$match = $listed | Where-Object { $_.poNumber -eq $poNumber } | Select-Object -First 1
if (-not $match)                  { Fail "$poNumber missing from list" }
if ($match.pullId -ne $pullId)    { Fail "List row pullId=$($match.pullId), expected $pullId" }
if ($match.pullNumber -ne $pullNumber) { Fail "List row pullNumber=$($match.pullNumber), expected $pullNumber" }
OK "List row: pull=$($match.pullNumber), lines=$($match.lineCount), ordered=$($match.totalOrdered)"

# ============================================================================
# STEP 4 — Insert PullItem + PullItemWindow via SQL (no API for this in v2)
# ============================================================================
Step "Step 4: SQL INSERT — add PullItem (PCBA-AX450-R2) + PullItemWindow (hour 14 / 500 pcs)"
$pullItemId = [Guid]::NewGuid().ToString()
$insertSql = @"
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;
INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Status, SortOrder)
VALUES ('$pullItemId', '$pullId', 'PCBA-AX450-R2', 'PCBA AX450 Rev 2', 'VND-E2E', 'E2E Vendor', 'normal', 1);
INSERT INTO dbo.PullItemWindows (PullItemId, HourOfDay, ExpectedQty)
VALUES ('$pullItemId', 14, 500);
"@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $insertSql 2>&1 | Out-Null
$piExists = Q "SELECT COUNT(*) FROM dbo.PullItems WHERE Id = '$pullItemId';"
if ($piExists -ne '1') { Fail "PullItem insert didn't take" }
OK "PullItem $($pullItemId.Substring(0,8)) + hour-14 window inserted"

# ============================================================================
# STEP 5 — Pull detail, preview, receive
# ============================================================================
Step "Step 5a: GET /api/pulls/by-number/$pullNumber — PullDetail.lockPoByPull=true"
$detail = Invoke-RestMethod -Uri "$base/api/pulls/by-number/$pullNumber" -WebSession $sv
if ($detail.lockPoByPull -ne $true) { Fail "Expected detail.lockPoByPull=true, got $($detail.lockPoByPull)" }
OK "PullDetail surfaces lockPoByPull=true"

Step "Step 5b: GET /api/receipts/preview — scope='pull-locked' + allocations[0].poNumber=$poNumber"
$preview = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$pullItemId&qty=200" -WebSession $sv
if ($preview.scope -ne 'pull-locked') { Fail "Expected scope='pull-locked', got '$($preview.scope)'" }
if ($preview.allocations.Count -ne 1) { Fail "Expected 1 allocation, got $($preview.allocations.Count)" }
if ($preview.allocations[0].poNumber -ne $poNumber) {
    Fail "Expected allocation poNumber=$poNumber, got $($preview.allocations[0].poNumber)"
}
if ($preview.allocations[0].qty -ne 200) { Fail "Expected qty=200, got $($preview.allocations[0].qty)" }
OK "Preview: scope=pull-locked, 200@$($preview.allocations[0].poNumber)·L$($preview.allocations[0].poLineNumber)"

Step "Step 5c: POST /api/receipts — receive 200 pcs"
$rcvBody = @{ pullItemId = $pullItemId; hourOfDay = 14; qty = 200; note = 'Phase 5e e2e receive' } | ConvertTo-Json
$rcv = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $rcvBody -ContentType 'application/json' -WebSession $sv
if ($rcv.totalQty -ne 200)           { Fail "Expected totalQty=200, got $($rcv.totalQty)" }
if ($rcv.newReceivedQty -ne 200)     { Fail "Expected newReceivedQty=200, got $($rcv.newReceivedQty)" }
if ($rcv.allocations.Count -ne 1)    { Fail "Expected 1 allocation, got $($rcv.allocations.Count)" }
$receiptId = $rcv.allocations[0].receiptId
OK "Received 200 pcs against $($rcv.allocations[0].poNumber)·L$($rcv.allocations[0].poLineNumber), receiptId=$($receiptId.Substring(0,8))"

# ============================================================================
# STEP 6 — Cancel restores qty to the SAME PO line (§7.3)
# ============================================================================
Step "Step 6: POST /api/receipts/$($receiptId.Substring(0,8))/cancel"
$cancelBody = @{ reason = 'miscount'; note = 'Phase 5e e2e cancel' } | ConvertTo-Json
$cancel = Invoke-RestMethod -Uri "$base/api/receipts/$receiptId/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $sv
if ($cancel.newReceivedQty -ne 0) { Fail "Expected post-cancel newReceivedQty=0, got $($cancel.newReceivedQty)" }
if (-not $cancel.poLineRestored)  { Fail "Expected poLineRestored populated" }
if ($cancel.poLineRestored.poNumber -ne $poNumber) {
    Fail "Cancel restored to wrong PO: expected $poNumber, got $($cancel.poLineRestored.poNumber)"
}
OK "Cancel restored to $($cancel.poLineRestored.poNumber)·L$($cancel.poLineRestored.lineNumber), remaining=$($cancel.poLineRestored.newRemainingQty)"

# ============================================================================
# STEP 7 — Transactions journal carries BOTH rows with PO context
# ============================================================================
Step "Step 7: GET /api/transactions?pullNumber=$pullNumber — receive + reversal rows"
$page = Invoke-RestMethod -Uri "$base/api/transactions?pullNumber=$pullNumber&take=50" -WebSession $sv
if (-not $page.rows -or $page.rows.Count -lt 2) { Fail "Expected ≥2 rows (receive + reversal), got $($page.rows.Count)" }
# After cancel the original positive row has ReversedById set (kind='voided') —
# qty stays positive, the reversal carries the negative qty.
$pos = @($page.rows | Where-Object { $_.qtyReceived -gt 0 })   # original receipt (now voided)
$neg = @($page.rows | Where-Object { $_.qtyReceived -lt 0 })   # the reversal
if ($pos.Count -lt 1) { Fail "No positive (receive) row in journal" }
if ($neg.Count -lt 1) { Fail "No reversal row in journal" }
if ($pos[0].poNumber -ne $poNumber) { Fail "Positive row PO mismatch" }
if ($neg[0].poNumber -ne $poNumber) { Fail "Reversal row PO mismatch (cancel must keep original PO — §7.3)" }
# §4.8 — every row must carry PO context (mandatory post-Phase-1b)
$missingPo = @($page.rows | Where-Object { -not $_.poNumber }).Count
if ($missingPo -gt 0) { Fail "$missingPo journal rows missing poNumber" }
OK "Journal: positive (kind=$($pos[0].kind)) + reversal both anchored to $poNumber·L$($pos[0].poLineNumber)"

# ============================================================================
# STEP 8 — PUT pull with lockPoByPull flipped → 409
# ============================================================================
Step "Step 8: PUT /api/pulls/$($pullId.Substring(0,8)) flipping lockPoByPull → 409"
$putPullBad = @{
    pullDate     = $detail.pullDate
    eta          = $null
    notes        = 'attempt to unlock'
    lockPoByPull = $false   # was true at create
} | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/pulls/$pullId" -Method PUT -Body $putPullBad -ContentType 'application/json' -WebSession $sv | Out-Null
    Fail "Expected 409 on lockPoByPull flip, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    OK "409 — LockPoByPull immutable"
}

# ============================================================================
# STEP 9 — Close PO manually with reason
# ============================================================================
Step "Step 9: POST /api/pos/$($poId.Substring(0,8))/close — reason 'Phase 5e cleanup'"
$closeBody = @{ reason = 'Phase 5e cleanup' } | ConvertTo-Json
$closeResp = Invoke-WebRequest -Uri "$base/api/pos/$poId/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $sv
if ($closeResp.StatusCode -ne 204) { Fail "Expected 204, got $($closeResp.StatusCode)" }
$closed = Invoke-RestMethod -Uri "$base/api/pos/$poId" -WebSession $sv
if ($closed.status -ne 'closed') { Fail "Expected status='closed', got '$($closed.status)'" }
OK "PO closed (status=closed, closedAt=$($closed.closedAt))"

# ============================================================================
# STEP 10 — PUT on closed PO → 409 (defense-in-depth from commit 03597c8)
# ============================================================================
Step "Step 10: PUT /api/pos/{id} on closed PO → 409 'Cannot edit a closed PO'"
$putPoBad = @{
    vendorCode   = 'whatever'
    vendorName   = 'attempted change'
    orderDate    = $closed.orderDate
    expectedDate = $null
    notes        = $null
    pullId       = $closed.pullId
} | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/pos/$poId" -Method PUT -Body $putPoBad -ContentType 'application/json' -WebSession $sv | Out-Null
    Fail "Expected 409 on closed-PO PUT, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $bodyText = $_.ErrorDetails.Message
    if ($bodyText -notmatch 'Cannot edit a closed PO') { Fail "Expected 'Cannot edit a closed PO' title, got: $bodyText" }
    OK "409 — Cannot edit a closed PO"
}

# ============================================================================
# Cleanup
# ============================================================================
Step "Cleanup smoke artifacts (Receipts → PullItemWindows → PullItems → Pulls + PO lines + PO)"
SqlCleanup
$remaining = Q "SELECT (SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE 'PL-SMOKE-5E-%') + (SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-SMOKE-5E-%');"
if ($remaining -ne '0') { Fail "Cleanup incomplete: $remaining artifact(s) remain" }
OK "Smoke artifacts cleared"

Write-Host "`nPhase 5e end-to-end PASSED." -ForegroundColor Green
exit 0
