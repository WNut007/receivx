# Smoke: forward Pull status transition in_progress → fully_received.
#
# Locks in the state-machine invariant fixed by commit 4a91883: when a
# receive fills the last outstanding window of a Pull, ReceiveAsync MUST
# flip Pull.Status to 'fully_received' atomically and emit a matching
# 'pull-fully-received' audit row.
#
# Self-contained fixture: the smoke creates its own Pull + PullItem +
# PullItemWindow + PO + PoLine under a 'PFT-%' (Pull Forward Transition)
# prefix so cleanup is unambiguous and there is zero overlap with seed
# or other smokes. LockPoByPull = false so the FIFO walk is warehouse-
# wide and the PO row needs no Pull link.
#
# Assertions:
#   1. Pre-cleanup of any leftover PFT-% rows
#   2. Insert fixture (PO + line, Pull + item + window) — all sized at 5 pcs
#   3. Login as sadmin
#   4. Pull starts at 'pending' (verify pre-receive state)
#   5. POST /api/receipts (qty=5, hour=12) → response.fullyReceived = true
#   6. Pull.Status flipped to 'fully_received' in DB (the bug we are
#      guarding against would leave it at 'in_progress')
#   7. Pull.ClosedAt remains NULL (signature step is separate)
#   8. AuditLog row 'pull-fully-received' present for the Pull with prior-
#      status hint in the message
#   9. Post-cleanup leaves zero PFT-% residue

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Sql($q)  { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Fixture identifiers — 'PFT-' prefix so cleanup is collision-free.
$PullId      = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01'
$PullItemId  = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02'
$WindowId    = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa03'
$PoId        = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa04'
$PoLineId    = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa05'
$ItemCode    = 'PFT-TEST-001'
$PullNumber  = 'PFT-PL-001'
$PoNumber    = 'PFT-PO-001'

function Cleanup-Fixture {
    # FK order: Receipts → PullItemWindows → PullItems → Pulls
    #                    PurchaseOrderLines → PurchaseOrders → ...
    # Receipts reference both PullItemId AND PurchaseOrderLineId, so they
    # come first. AuditLog has no FK back to either, but we sweep its
    # PFT-% rows too so re-runs do not accumulate.
    Sql @"
SET NOCOUNT ON;
DELETE FROM dbo.Receipts WHERE PullItemId = '$PullItemId' OR PurchaseOrderLineId = '$PoLineId';
DELETE FROM dbo.PullItemWindows WHERE PullItemId = '$PullItemId';
DELETE FROM dbo.PullItems WHERE Id = '$PullItemId';
DELETE FROM dbo.Pulls WHERE Id = '$PullId';
DELETE FROM dbo.PurchaseOrderLines WHERE Id = '$PoLineId';
DELETE FROM dbo.PurchaseOrders WHERE Id = '$PoId';
DELETE FROM dbo.AuditLog
 WHERE (EntityType = 'Pull' AND EntityId = '$PullId')
    OR (EntityType = 'Receipt' AND EntityId LIKE 'pi=$PullItemId%');
"@ | Out-Null
}

# ----------------------------------------------------------------------------
# 1. Pre-cleanup
# ----------------------------------------------------------------------------
Step "Pre-cleanup PFT-% fixture rows"
Cleanup-Fixture
$resid = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Pulls WHERE Id='$PullId';") -join '' -replace '\s',''
if ($resid -ne '0') { Fail "Pre-cleanup left $resid Pulls row(s) behind" }
OK "Fixture slate clean"

# ----------------------------------------------------------------------------
# 2. Insert fixture
# ----------------------------------------------------------------------------
Step "Insert fixture: PO line + Pull + item + window (all sized 5)"
# sadmin = 11111111-1111-1111-1111-000000000001 (per seed)
# Phase 14 (db/036): vendor moved from PO header to POL.
Sql @"
SET NOCOUNT ON;
INSERT INTO dbo.PurchaseOrders
    (Id, PoNumber, WarehouseId, PullId,
     OrderDate, Status, CreatedBy, CreatedAt)
VALUES
    ('$PoId', '$PoNumber', '$WH_01', NULL,
     CAST(SYSUTCDATETIME() AS DATE), 'open',
     '11111111-1111-1111-1111-000000000001', SYSUTCDATETIME());

INSERT INTO dbo.PurchaseOrderLines
    (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName)
VALUES
    ('$PoLineId', '$PoId', 1, '$ItemCode', 'PFT smoke item', 5, 0, 'VEND-PFT', 'PFT Vendor');

INSERT INTO dbo.Pulls
    (Id, PullNumber, WarehouseId, PullDate, Status,
     CreatedBy, CreatedAt, LockPoByPull, LockHourCap)
VALUES
    ('$PullId', '$PullNumber', '$WH_01', CAST(SYSUTCDATETIME() AS DATE), 'pending',
     '11111111-1111-1111-1111-000000000001', SYSUTCDATETIME(), 0, 1);

INSERT INTO dbo.PullItems
    (Id, PullId, ItemCode, Description, Status, SortOrder)
VALUES
    ('$PullItemId', '$PullId', '$ItemCode', 'PFT smoke item', 'normal', 1);

INSERT INTO dbo.PullItemWindows
    (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
VALUES
    ('$WindowId', '$PullItemId', 12, 5, 0);
"@ | Out-Null
OK "Fixture inserted (PullNumber=$PullNumber, PoNumber=$PoNumber, qty=5)"

# ----------------------------------------------------------------------------
# 3. Login
# ----------------------------------------------------------------------------
Step "Login as sadmin / WH-01"
$sv = Login 'sadmin' 'admin' $WH_01
OK "Logged in"

# ----------------------------------------------------------------------------
# 4. Verify pre-receive Pull state
# ----------------------------------------------------------------------------
Step "Pre-receive: Pull at 'pending' with one outstanding window"
$pre = (Sql "SET NOCOUNT ON; SELECT Status FROM dbo.Pulls WHERE Id='$PullId';") -join '' -replace '\s',''
if ($pre -ne 'pending') { Fail "Pre-state status='$pre', expected 'pending'" }
OK "Pull starts at 'pending'"

# ----------------------------------------------------------------------------
# 5. Receive the full 5 pcs in one call
# ----------------------------------------------------------------------------
Step "POST /api/receipts qty=5 (fills the only window)"
$body = @{ pullItemId=$PullItemId; hourOfDay=12; qty=5; qcStatus='pending'; note='smoke-pft' } | ConvertTo-Json
$resp = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
if ($resp.totalQty -ne 5)         { Fail "Expected totalQty=5, got $($resp.totalQty)" }
if ($resp.newReceivedQty -ne 5)   { Fail "Expected newReceivedQty=5, got $($resp.newReceivedQty)" }
if (-not $resp.fullyReceived)     { Fail "Expected fullyReceived=true on the response DTO" }
OK "Receive response: totalQty=5, newReceivedQty=5, fullyReceived=true"

# ----------------------------------------------------------------------------
# 6. Pull.Status flipped to 'fully_received' in DB
# ----------------------------------------------------------------------------
Step "Pull.Status flipped to 'fully_received' (the load-bearing assertion)"
$post = (Sql "SET NOCOUNT ON; SELECT Status FROM dbo.Pulls WHERE Id='$PullId';") -join '' -replace '\s',''
if ($post -ne 'fully_received') {
    Cleanup-Fixture
    Fail "REGRESSION: Pull.Status='$post' after filling the last window; expected 'fully_received'. The forward transition in ReceiveAsync (commit 4a91883) has decayed."
}
OK "Pull.Status = 'fully_received' (forward transition fired correctly)"

# ----------------------------------------------------------------------------
# 7. ClosedAt remains NULL — signature is a separate step
# ----------------------------------------------------------------------------
Step "Pull.ClosedAt remains NULL (signature step is separate from status transition)"
$closedAt = (Sql "SET NOCOUNT ON; SELECT ISNULL(CAST(ClosedAt AS NVARCHAR(50)),'NULL') FROM dbo.Pulls WHERE Id='$PullId';") -join '' -replace '\s',''
if ($closedAt -ne 'NULL') {
    Cleanup-Fixture
    Fail "ClosedAt='$closedAt' on a fully_received pull; expected NULL (close = signature event, not auto-fired)"
}
OK "ClosedAt = NULL — close requires explicit signature"

# ----------------------------------------------------------------------------
# 8. AuditLog row 'pull-fully-received' exists
# ----------------------------------------------------------------------------
Step "AuditLog has 'pull-fully-received' row for the pull"
$audit = (Sql @"
SET NOCOUNT ON;
SELECT TOP 1 Message
FROM   dbo.AuditLog
WHERE  ActionType = 'pull-fully-received'
   AND EntityType = 'Pull'
   AND EntityId   = '$PullId'
ORDER BY OccurredAt DESC;
"@) -join '' -replace '^\s+|\s+$',''
if (-not $audit) {
    Cleanup-Fixture
    Fail "No 'pull-fully-received' audit row for Pull $PullId"
}
if ($audit -notmatch [regex]::Escape($PullNumber)) {
    Cleanup-Fixture
    Fail "Audit message missing PullNumber '$PullNumber': $audit"
}
if ($audit -notmatch 'from\s+pending|from\s+in_progress') {
    Cleanup-Fixture
    Fail "Audit message missing prior-status hint (expected 'from pending' or 'from in_progress'): $audit"
}
OK "Audit row present; message includes PullNumber + prior-status hint"

# ----------------------------------------------------------------------------
# 9. Cleanup
# ----------------------------------------------------------------------------
Step "Post-cleanup leaves no PFT-% residue"
Cleanup-Fixture
$resid = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Pulls WHERE Id='$PullId';") -join '' -replace '\s',''
if ($resid -ne '0') { Fail "Post-cleanup left $resid Pulls row(s) behind" }
OK "All PFT-% rows removed"

Write-Host ""
Write-Host "ALL PASS — Pull forward transition in_progress → fully_received verified end-to-end." -ForegroundColor Green
exit 0
