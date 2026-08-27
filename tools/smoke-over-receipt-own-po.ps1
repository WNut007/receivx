# Smoke test: an over-receipt stays on the pull's OWN PO line
#
# Brief: brief-over-receipt-own-po.md (§6 test cases). Requires db/051.
#
# Renamed from smoke-po-overflow-variance.ps1. That file asserted the feature this
# one reverses, so the cases it carried are inverted here rather than deleted, with
# the old assertion quoted above each so the change is visible and deliberate.
#
# THE DEFECT THIS PINS
# --------------------
# Receiving 501 against a line ordered at 500 records 501 on THAT line. It does not
# consume any other purchase order.
#
# The predecessor read the requirement as "the goods must be recordable somewhere",
# and since other open PO lines for the same vendor had capacity, widened allocation
# to spill into them. Production pull 0000028773: one SKU, one window, 501 against
# 500. The walk put 500 on the pull's own PO and sent the remaining 1 to
# TH5805-P233094 — a PO belonging to pull 0000015008. Two Receipts rows against two
# different purchase orders for what the operator experienced as a single receive,
# and a Delivery Note that printed as two pages with different ASN, invoice and PO
# on each. One receive, one PO line.
#
# db/051 is what makes that storable: CK_POL_Caps loses its OrderedQty ceiling and
# keeps its floor, so ReceivedQty becomes the figure actually received.
#
# THE SEED, AND WHY IT IS HERE
# ----------------------------
# The dev database carries pull 0000026590 but NOT the anchor PO that production has
# (PoNumber = PullExternalRef = '0000026590', 400 pcs). Without it the receive fails
# earlier and differently — "No PO linked to this pull" — which is a different 409
# and would silently make this smoke assert the wrong thing.
#
# CASES
#   1.  §6.1   401 ticked → ONE receipt row, 401 on the pull's own line, the line
#              stored at ReceivedQty 401 / OrderedQty 400. INVERTED (was: two rows,
#              400 on the pull's PO + 1 spilled onto another).
#   2.  §6.2   Same request unticked → 400 OVER_RECEIPT_NOT_ACCEPTED, zero rows.
#              Unchanged.
#   3.         Pull PO alone covers the qty → ONE row, plain 'pull-locked' label,
#              no over-receipt clause. The figure is read off the plan, not the tick.
#   4.  §6.3   A same-vendor, older, ample-capacity PO belonging to ANOTHER pull is
#              untouched, and so is every other line in the warehouse. This is the
#              direct inversion and the case that proves the reversal.
#   5.         Audit names the over-received line and the overage. INVERTED (was:
#              carries the 'variance overflow' scope label + names two POs).
#   6.  §6.6   Cancelling the over-received slice returns the line to 0 — never left
#              above OrderedQty — and clears IsClosed though it carries no
#              VarianceQty. RE-SEEDED onto the pull's own two lines.
#   6b.        The same for the slice that DOES carry VarianceQty.
#   6c.        The half-reversed state 6b leaves behind, field by field.
#   7.         Normal in-range receive, unticked → narrow path unchanged.
#   8-13.      The step-8c VarianceQty recompute. Unchanged by this brief.
#   14. §6.7   db/051 itself: a line accepts ReceivedQty > OrderedQty; a negative is
#              still rejected.
#   15. §6.8   vw_PurchaseOrderAvailability excludes an over-received line.
#   16. §6.9   Auto-close fires for a PO whose only line is over-received.
#   17. §4.3   The storer rule. An over-receipt is refused when the item's storer has
#              no PO line of its own (fallback), and refused with a DIFFERENT message
#              when the item has no storer at all. Allocation WITHIN capacity is
#              unaffected in both cases.
#
# Brief §6.4 (multi-line 1,200 across two 500 lines) is covered by case 10's existing
# three-slice fixture; §6.5 (short close) by cases 12 and 13. §6.10 (the DN renders
# one page) is a report-level check and lives in smoke-do-report.
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'

$WH_BPI    = 'bb414f53-11d6-4db8-8909-7e251b0823bf'
$PULL_NO   = '0000026590'
$ITEM      = '2063-810743-0E4'
$HOUR      = 20
$VENDOR    = 'COI-HSABP1'
$SEED_PO   = '0000026590'          # anchor PO: PoNumber == PullExternalRef == PullNumber
$OTHER_PO  = 'PO-SOV-OTHERVENDOR'  # case 4 — different vendor, must never be drawn on
$SQL       = @{ S = 'LAPTOP-CSB3KO3E'; d = 'ReceivingOps' }

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }

# -b is load-bearing: without it sqlcmd exits 0 even when a statement fails, so
# $LASTEXITCODE proves nothing and a broken cleanup passes silently. That is not
# hypothetical — it hid an FK violation in Cleanup below, which left receipts and
# a spent anchor PO in place and made case 3 allocate an overflow it should never
# have needed. A teardown that cannot fail loudly will eventually corrupt a case
# that looks unrelated.
#
# Via a temp file rather than -Q: sqlcmd re-tokenizes -Q and treats a bare "/"
# inside it as a switch prefix, aborting before any SQL runs.
function Sql($q) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sov-{0}.sql" -f [guid]::NewGuid())
    try {
        Set-Content -Path $tmp -Value $q -Encoding UTF8
        $out = sqlcmd -S $SQL.S -E -C -d $SQL.d -I -b -h -1 -W -i $tmp 2>&1
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed: $($out | Out-String)" }
        return $out
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}
function SqlScalar($q) { (Sql $q | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -First 1).Trim() }

# ---------------------------------------------------------------------------
# Cleanup / seed
#
# Cleanup deletes only what this smoke wrote, then RECOMPUTES the caches from
# Receipts truth rather than decrementing them. The overflow slice lands on a
# REAL PO line that this smoke did not create and must not corrupt; set-from-truth
# is the same pattern db/038 used for exactly this reason. Decrementing would
# drift the moment a case fails midway and leaves a partial receive behind.
# ---------------------------------------------------------------------------
function Cleanup {
    $q = @"
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @pullItem UNIQUEIDENTIFIER = (
    SELECT pi.Id FROM dbo.PullItems pi
    INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
    WHERE p.PullNumber = '$PULL_NO' AND pi.ItemCode = '$ITEM');

-- Remember which PO lines this smoke touched BEFORE deleting the receipts.
DECLARE @touched TABLE (LineId UNIQUEIDENTIFIER PRIMARY KEY);
INSERT INTO @touched (LineId)
SELECT DISTINCT PurchaseOrderLineId FROM dbo.Receipts
WHERE PullItemId = @pullItem AND PurchaseOrderLineId IS NOT NULL;

-- The self-reference runs BOTH ways:
--   original.ReversedById      -> reversal.Id   (FK_Receipts_Reversed)
--   reversal.ReversesReceiptId -> original.Id   (FK_Receipts_Reverses)
-- so children-first is not enough — the back-link has to be cleared before the
-- reversal can go, and the reversal before its original. ReversedById is nullable
-- and carries no CHECK, unlike ReversesReceiptId (§7.10).
UPDATE dbo.Receipts SET ReversedById = NULL WHERE PullItemId = @pullItem;
DELETE FROM dbo.Receipts WHERE PullItemId = @pullItem AND ReversesReceiptId IS NOT NULL;
DELETE FROM dbo.Receipts WHERE PullItemId = @pullItem;

-- Set-from-truth on every line this smoke consumed, including the real ones.
UPDATE pol SET ReceivedQty = ISNULL(t.Qty, 0)
FROM dbo.PurchaseOrderLines pol
INNER JOIN @touched tt ON tt.LineId = pol.Id
OUTER APPLY (SELECT SUM(r.QtyReceived) AS Qty FROM dbo.Receipts r
             WHERE r.PurchaseOrderLineId = pol.Id) t;

-- Reopen any PO this smoke auto-closed by filling it.
UPDATE po SET Status = 'open', ClosedAt = NULL
FROM dbo.PurchaseOrders po
WHERE po.Status = 'closed'
  AND EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol
              INNER JOIN @touched tt ON tt.LineId = pol.Id
              WHERE pol.PurchaseOrderId = po.Id AND pol.OrderedQty > pol.ReceivedQty);

-- Restore the window to its pre-smoke state.
UPDATE dbo.PullItemWindows
   SET ReceivedQty = 0, IsClosed = 0, ClosedAt = NULL, ClosedBy = NULL, ClosedReason = NULL
 WHERE PullItemId = @pullItem AND HourOfDay = $HOUR;

UPDATE dbo.Pulls SET Status = 'pending', FirstReceiptAt = NULL
 WHERE PullNumber = '$PULL_NO' AND Status IN ('in_progress','fully_received');

-- Drop the seeded POs (lines cascade via FK ON DELETE CASCADE where present;
-- delete explicitly so this works either way).
DELETE FROM dbo.PurchaseOrderLines WHERE PurchaseOrderId IN
    (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber IN ('$SEED_PO','$OTHER_PO'));
DELETE FROM dbo.PurchaseOrders WHERE PoNumber IN ('$SEED_PO','$OTHER_PO');
"@
    Sql $q | Out-Null
}

# Seeds the anchor PO with N lines of $perLine each, all pull-linked. Case 11 needs a
# multi-row allocation that involves NO variance, and on a lock-by-pull pull the only
# way to split without the tick is across two lines of the pull's own PO — overflow is
# gated on variance by design (§4.1), so a second PO would not be reachable unticked.
function SeedAnchorPoLines($lineCount, $perLine) {
    $values = (1..$lineCount | ForEach-Object {
        "(@po, $_, '$ITEM', 'SOV anchor line $_', $perLine, 0, '$VENDOR', 'Western Digital')"
    }) -join ",`n"
    $q = @"
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DECLARE @po UNIQUEIDENTIFIER = NEWID();
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, Status, PullExternalRef, CreatedBy)
VALUES (@po, '$SEED_PO', '$WH_BPI', CAST(DATEADD(day,-30,SYSUTCDATETIME()) AS DATE), 'open', '$PULL_NO',
        '11111111-1111-1111-1111-000000000001');
INSERT INTO dbo.PurchaseOrderLines
    (PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName)
VALUES
$values;
"@
    Sql $q | Out-Null
}

# Seeds the anchor PO. $ordered lets case 3 give the pull's own PO enough headroom
# to cover the whole receive, which is what proves the label is decided from the
# plan rather than from the tick.
function SeedAnchorPo($ordered) {
    $q = @"
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DECLARE @po UNIQUEIDENTIFIER = NEWID();
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, Status, PullExternalRef, CreatedBy)
VALUES (@po, '$SEED_PO', '$WH_BPI', CAST(DATEADD(day,-30,SYSUTCDATETIME()) AS DATE), 'open', '$PULL_NO',
        '11111111-1111-1111-1111-000000000001');
INSERT INTO dbo.PurchaseOrderLines
    (PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName)
VALUES (@po, 1, '$ITEM', 'SOV anchor line', $ordered, 0, '$VENDOR', 'Western Digital');
"@
    Sql $q | Out-Null
}

# Case 4 — the PO an over-receipt would spill onto if anything still widened. SAME
# vendor, same item, ample stock, dated OLDER than everything else so a naive FIFO walk
# reaches it first, and belonging to no pull — exactly the shape of TH5805-P233094, the
# line production's 401st unit actually landed on.
#
# The predecessor of this fixture used a DIFFERENT vendor, which tested a weaker claim:
# overflow was allowed to cross POs and only barred from crossing vendors, so a
# wrong-vendor line proved nothing about the same-vendor spill that was the defect.
function SeedSameVendorOtherPullPo {
    $q = @"
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DECLARE @po UNIQUEIDENTIFIER = NEWID();
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, Status, CreatedBy)
VALUES (@po, '$OTHER_PO', '$WH_BPI', '2020-01-01', 'open', '11111111-1111-1111-1111-000000000001');
INSERT INTO dbo.PurchaseOrderLines
    (PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName)
VALUES (@po, 1, '$ITEM', 'SOV other-pull same-vendor line', 999999, 0, '$VENDOR', 'Western Digital');
"@
    Sql $q | Out-Null
}

function PullItemId {
    SqlScalar @"
SET NOCOUNT ON;
SELECT pi.Id FROM dbo.PullItems pi
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL_NO' AND pi.ItemCode = '$ITEM';
"@
}

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body `
        -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

function Receive($session, $pullItemId, $qty, $variance, $note) {
    $body = @{
        pullItemId = $pullItemId; hourOfDay = $HOUR; qty = $qty
        varianceAccepted = $variance; note = $note
        # db/049 — a variance needs a reason code. COUNT_MISMATCH is valid in both
        # directions and needs no note, so it keeps these cases testing allocation and
        # the VarianceQty recompute rather than the reason rules, which have their own
        # suite in smoke-variance-reason.ps1.
        varianceReasonCode = $(if ($variance) { 'COUNT_MISMATCH' } else { $null })
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body `
        -ContentType 'application/json' -WebSession $session
}

function ReceiveExpectFail($session, $pullItemId, $qty, $variance, $note, $expectedStatus) {
    try {
        Receive $session $pullItemId $qty $variance $note | Out-Null
        return $null
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        $status = [int]$resp.StatusCode
        $title = $null; $code = $null
        if ($_.ErrorDetails.Message) {
            try { $pd = $_.ErrorDetails.Message | ConvertFrom-Json; $title = $pd.title; $code = $pd.code }
            catch { $title = $_.ErrorDetails.Message }
        }
        return [pscustomobject]@{ Status=$status; Title=$title; Code=$code
                                  Wrong=($status -ne $expectedStatus) }
    }
}

# ===========================================================================
Cleanup
$sv = Login 'sadmin' 'admin' $WH_BPI
$pi = PullItemId
if (-not $pi) { Write-Host "FAIL: pull $PULL_NO / item $ITEM not present in this database." -ForegroundColor Red; exit 1 }
Write-Host "PullItemId = $pi" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
Step '1. Repro — 401 against a 400 pull-linked PO, variance ticked'
SeedAnchorPo 400

# PRECONDITION — the pull-linked set must be EXACTLY the seeded anchor.
#
# This guard exists because its absence already produced a false pass once. If any
# other PO in the database links to this pull (via PullId or a matching
# PullExternalRef) and carries this item, the pre-change code could already spill
# onto it, and case 1 would pass without the widening doing any work at all —
# testing nothing while looking green. Production has exactly one linked line;
# assert the fixture matches that before drawing any conclusion from it.
$linked = Sql @"
SET NOCOUNT ON;
DECLARE @pull UNIQUEIDENTIFIER = (SELECT Id FROM dbo.Pulls WHERE PullNumber='$PULL_NO');
SELECT CAST(COUNT(*) AS VARCHAR)+'|'+CAST(ISNULL(SUM(pol.OrderedQty-pol.ReceivedQty),0) AS VARCHAR)
FROM   dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE  po.WarehouseId = (SELECT WarehouseId FROM dbo.Pulls WHERE Id=@pull)
  AND  po.Status = 'open' AND pol.ItemCode = '$ITEM'
  AND  pol.OrderedQty > pol.ReceivedQty
  AND  (po.PullId = @pull OR po.PullExternalRef = '$PULL_NO');
"@
$lp = ($linked | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
if ($lp[0] -ne '1' -or $lp[1] -ne '400') {
    Fail ("precondition: expected exactly 1 pull-linked line with 400 remaining, got " +
          "$($lp[0]) line(s) / $($lp[1]) pcs. Another PO links to this pull — the overflow " +
          "would not be doing the work and this case would pass vacuously.")
}
OK 'precondition: exactly one pull-linked line, 400 remaining (matches production)'

$res = Receive $sv $pi 401 $true 'Vendor over-delivered by 1; accepted at gate.'
if ($res.totalQty -ne 401) { Fail "expected totalQty 401, got $($res.totalQty)" }

# INVERTED. This case previously asserted the opposite:
#
#     if ($res.allocations.Count -ne 2) { Fail "expected 2 allocation slices, ..." }
#     if ($slice1.qty -ne 400) { ... }   # the pull's own PO, filled to OrderedQty
#     if ($slice2.qty -ne 1)   { ... }   # the spill, on SOMEONE ELSE'S purchase order
#     if ($slice2.isPullLinked -ne $false) { ... }
#     if ($slice2.poNumber -eq $SEED_PO)   { ... }
#
# That is the defect, written down as a requirement. Production pull 0000028773 sent
# its 1 spare unit to TH5805-P233094 — a PO belonging to pull 0000015008 — and the
# Delivery Note printed as two pages with different ASN, invoice and PO on each. One
# receive, one PO line: the 401st unit stays on the line ordered at 400 and pushes
# its ReceivedQty to 401, which db/051 now permits.
if ($res.allocations.Count -ne 1) {
    $where = ($res.allocations | ForEach-Object { "$($_.qty)@$($_.poNumber)" }) -join ' + '
    Fail "expected ONE allocation slice, got $($res.allocations.Count): $where"
}

$slice1 = $res.allocations[0]
if ($slice1.qty -ne 401) { Fail "the single slice should carry all 401, got $($slice1.qty)" }
if ($slice1.poNumber -ne $SEED_PO) { Fail "the slice must be the pull's own PO $SEED_PO, got $($slice1.poNumber)" }
if ($slice1.overReceivedQty -ne 1) { Fail "expected overReceivedQty 1, got $($slice1.overReceivedQty)" }
OK "401 recorded as a single 401@$($slice1.poNumber) slice, 1 pc beyond OrderedQty"

# The stored figure is the point of db/051: ReceivedQty is what was received, and it
# is allowed to exceed OrderedQty rather than being spread until it fits.
$polState = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR)+'|'+CAST(pol.OrderedQty AS VARCHAR)
FROM   dbo.PurchaseOrderLines pol
WHERE  pol.Id = '$($slice1.purchaseOrderLineId)';
"@
if ($polState.Trim() -ne '401|400') { Fail "PO line should read ReceivedQty|OrderedQty = 401|400, got $polState" }
OK 'the pull-linked PO line stores ReceivedQty 401 against OrderedQty 400'

$row = Sql @"
SET NOCOUNT ON;
SELECT CAST(piw.ReceivedQty AS VARCHAR)+'|'+CAST(piw.IsClosed AS VARCHAR)+'|'
     + CAST((SELECT COUNT(*) FROM dbo.Receipts r WHERE r.PullItemId='$pi' AND r.VarianceAccepted=1) AS VARCHAR)+'|'
     + CAST(ISNULL((SELECT SUM(r.VarianceQty) FROM dbo.Receipts r WHERE r.PullItemId='$pi'),-1) AS VARCHAR)
FROM dbo.PullItemWindows piw WHERE piw.PullItemId='$pi' AND piw.HourOfDay=$HOUR;
"@
$parts = ($row | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
if ($parts[0] -ne '401') { Fail "window ReceivedQty expected 401, got $($parts[0])" }
if ($parts[1] -ne '1')   { Fail "window IsClosed expected 1, got $($parts[1])" }
# INVERTED: was `-ne '2'` — "VarianceAccepted=1 on BOTH rows". There is one row now.
# The multi-row form of this invariant has not been dropped; it moved to case 6, which
# splits across the pull's own two lines to keep exercising it.
if ($parts[2] -ne '1')   { Fail "expected VarianceAccepted=1 on the single row, got $($parts[2])" }
if ($parts[3] -ne '1')   { Fail "expected SUM(VarianceQty)=1 (stamped once), got $($parts[3])" }
OK 'window 401 / IsClosed=1 / VarianceAccepted on the row / VarianceQty stamped once'

# ---------------------------------------------------------------------------
Step '5. Audit row names the over-received line and the overage'
$audit = SqlScalar @"
SET NOCOUNT ON;
SELECT TOP 1 Message FROM dbo.AuditLog
WHERE EntityId = 'pi=$pi' AND ActionType = 'receive'
ORDER BY OccurredAt DESC;
"@
# INVERTED. Previously:
#     if ($audit -notmatch 'pull-locked \+ variance overflow') { ... }
#     if ($audit -notmatch [regex]::Escape("400@$SEED_PO"))    { ... }
#     if ($audit -notmatch [regex]::Escape("1@$($slice2.poNumber)")) { ... }
#
# The third scope state is gone with the walk that produced it, so the label is
# plain 'pull-locked' and there is no second PO to name. What replaces it is §4.4:
# "401@PO" reads identically whether the line was ordered at 401 or at 400, so the
# one fact that makes this receive unusual has to be stated outright.
if ($audit -match 'variance overflow') { Fail "audit still carries the retired overflow label. Got: $audit" }
if ($audit -notmatch 'Scope: pull-locked\.') { Fail "audit should read 'Scope: pull-locked.'. Got: $audit" }
if ($audit -notmatch [regex]::Escape("401@$SEED_PO")) { Fail "audit missing the single slice. Got: $audit" }
if ($audit -notmatch 'Over-receipt: 1 pcs beyond OrderedQty 400') { Fail "audit missing the over-receipt clause. Got: $audit" }
OK "audit: $audit"

# ---------------------------------------------------------------------------
# Case 6 — the multi-row VarianceAccepted / IsClosed interaction.
#
# WHY THIS TEST EXISTS
# One confirm writes N rows. VarianceAccepted is written to EVERY row; VarianceQty
# to exactly ONE (the first slice) so SUM(VarianceQty) over the line stays right.
# Cancel clears IsClosed on `if (orig.VarianceAccepted)` — deliberately NOT on
# "does this row carry VarianceQty".
#
# If it had been keyed on VarianceQty instead, cancelling the SECOND slice would
# undo 1 pc of the closing quantity while leaving IsClosed = 1: the line would be
# permanently closed at a quantity that no longer matched its receipts, with no
# route back. That is the stranding this asserts cannot happen. Cancelling the
# non-first slice is the case that distinguishes the two implementations, which is
# why this test cancels slice 2 and not slice 1.
#
# RE-SEEDED for the reversal. This case used to inherit case 1's two slices, where the
# second was the spill onto another pull's PO. A receive no longer produces one, so the
# multi-slice allocation it needs now comes from the pull's OWN two lines — which is the
# only way to split on a lock-by-pull pull, and the shape case 11 already relied on. The
# invariant under test is unchanged and so are its stakes: 2 lines of 200, receive 401,
# giving slice 1 = 200 (carrying VarianceQty) and slice 2 = 201, over its line by 1.
Step '6. Cancel the SECOND slice (VarianceQty NULL) → IsClosed must still clear'
Cleanup; SeedAnchorPoLines 2 200
$res6 = Receive $sv $pi 401 $true 'Vendor over-delivered by 1; accepted at gate.'
if ($res6.allocations.Count -ne 2) { Fail "fixture: expected 2 slices across the pull's own lines, got $($res6.allocations.Count)" }
$slice2 = $res6.allocations[1]
if ($slice2.qty -ne 201)             { Fail "fixture: slice 2 should carry 201 (200 + the 1 over), got $($slice2.qty)" }
if ($slice2.overReceivedQty -ne 1)   { Fail "fixture: slice 2 should report overReceivedQty 1, got $($slice2.overReceivedQty)" }
if ($res6.allocations[0].overReceivedQty -ne 0) { Fail "fixture: slice 1 is within its line and must report overReceivedQty 0" }

$cancelBody = @{ reason = 'miscount'; note = 'smoke: reverse the over-received slice' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/receipts/$($slice2.receiptId)/cancel" -Method POST `
    -Body $cancelBody -ContentType 'application/json' -WebSession $sv | Out-Null

$after = Sql @"
SET NOCOUNT ON;
SELECT CAST(piw.IsClosed AS VARCHAR)+'|'+CAST(piw.ReceivedQty AS VARCHAR)+'|'
     + CAST(ISNULL((SELECT VarianceQty FROM dbo.Receipts WHERE Id='$($slice2.receiptId)'),-1) AS VARCHAR)
FROM dbo.PullItemWindows piw WHERE piw.PullItemId='$pi' AND piw.HourOfDay=$HOUR;
"@
$ap = ($after | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
if ($ap[2] -ne '-1') { Fail "precondition broken: slice 2 was expected to carry NULL VarianceQty, got $($ap[2])" }
if ($ap[0] -ne '0')  { Fail "IsClosed should have cleared when the non-first slice was reversed, got $($ap[0])" }
if ($ap[1] -ne '200'){ Fail "window should be back to 200 after reversing 201, got $($ap[1])" }
OK 'reversing the VarianceQty-NULL slice cleared IsClosed and left the window at 200'

# Brief §6 case 6 — cancelling an OVER-receipt must not leave the line above OrderedQty.
# The reversal goes back to the line the original consumed, and that line was the one
# pushed past its ordered quantity, so this is where a cancel that assumed the old cap
# would strand a line at 201/200 forever.
$restored = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR) FROM dbo.PurchaseOrderLines pol
WHERE pol.Id = '$($slice2.purchaseOrderLineId)';
"@
if ($restored -ne '0') { Fail "the over-received PO line should be restored to 0, got $restored" }
OK 'cancelling the over-receipt returned the line to 0 — not left above OrderedQty'

# ---------------------------------------------------------------------------
# 6b — the other end of the same invariant. Case 6 proved the slice WITHOUT
# VarianceQty still clears IsClosed; this proves the slice WITH it does too, so
# neither end is left resting on inference. Both must hold, because §8b keys on
# VarianceAccepted — which every slice carries — and not on which slice it was.
Step '6b. Cancel the FIRST slice (the one carrying VarianceQty) → IsClosed clears too'
Cleanup; SeedAnchorPoLines 2 200
$res6b = Receive $sv $pi 401 $true 'Vendor over-delivered by 1; accepted at gate.'
if ($res6b.allocations.Count -ne 2) { Fail "fixture: expected 2 slices, got $($res6b.allocations.Count)" }
$first = $res6b.allocations[0]
$firstVq = SqlScalar "SET NOCOUNT ON; SELECT CAST(ISNULL(VarianceQty,-1) AS VARCHAR) FROM dbo.Receipts WHERE Id='$($first.receiptId)';"
if ($firstVq -ne '1') { Fail "precondition: slice 1 should carry VarianceQty=1, got $firstVq" }

Invoke-RestMethod -Uri "$base/api/receipts/$($first.receiptId)/cancel" -Method POST `
    -Body (@{ reason='miscount'; note='smoke: reverse first slice' } | ConvertTo-Json) `
    -ContentType 'application/json' -WebSession $sv | Out-Null

$a6b = Sql @"
SET NOCOUNT ON;
SELECT CAST(IsClosed AS VARCHAR)+'|'+CAST(ReceivedQty AS VARCHAR)
FROM dbo.PullItemWindows WHERE PullItemId='$pi' AND HourOfDay=$HOUR;
"@
$p6b = ($a6b | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
if ($p6b[0] -ne '0')   { Fail "IsClosed should have cleared when the first slice was reversed, got $($p6b[0])" }
if ($p6b[1] -ne '201') { Fail "window should be 201 after reversing the 200 slice, got $($p6b[1])" }
OK 'reversing the VarianceQty-carrying slice cleared IsClosed and left the window at 201'

# ---------------------------------------------------------------------------
# 6c — the state 6b LEAVES BEHIND, asserted field by field rather than inferred
# from the fact that 6b did not throw.
#
# 6b cancels the 200-row and leaves the 201-pc over-received row live. That is a partial
# reversal of one confirm, and cancel is scoped to a receipt ROW, not to the confirm
# that wrote it (dbo.Receipts carries no confirm/batch key — see the trailer). So
# this half-state is reachable in production the moment an operator cancels one
# slice of a split allocation, and "IsClosed cleared" is not on its own enough to
# call it sound.
#
# The invariant that makes it sound is the reconciliation: the window cache must
# equal the sum of live receipt rows. Everything else here supports that — the PO
# line giving its quantity back, the auto-closed PO reopening, and the operator
# still having a forward path.
Step '6c. The half-reversed state reconciles and leaves a forward path'

$live = Sql @"
SET NOCOUNT ON;
SELECT CAST(ISNULL(SUM(r.QtyReceived),0) AS VARCHAR)+'|'
     + CAST(ISNULL(SUM(r.VarianceQty),0) AS VARCHAR)+'|'
     + CAST(SUM(CASE WHEN r.VarianceAccepted=1 THEN 1 ELSE 0 END) AS VARCHAR)+'|'
     + CAST(COUNT(*) AS VARCHAR)
FROM dbo.Receipts r
WHERE r.PullItemId='$pi' AND r.ReversedById IS NULL AND r.ReversesReceiptId IS NULL;
"@
$lv = ($live | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
# The window cache is denormalized from Receipts; a partial reversal is exactly where
# the two would drift apart if the decrement in step 8 were keyed on the wrong row.
if ($lv[0] -ne $p6b[1]) { Fail "window ReceivedQty ($($p6b[1])) does not reconcile with live receipts ($($lv[0]))" }
if ($lv[3] -ne '1')     { Fail "expected exactly 1 live receipt row after the partial cancel, got $($lv[3])" }
# Step 8c moved the figure onto the surviving ticked row rather than letting it die with
# the slice that happened to carry it: 201 received of 400 expected is -199. This assertion
# read '0' before 8c existed, which was the orphaned state the recompute now prevents.
if ($lv[1] -ne '-199')  { Fail "SUM(VarianceQty) over live rows should be -199 (live 201 - expected 400), got $($lv[1])" }
# The surviving over-received row KEEPS VarianceAccepted=1. That flag is provenance of the
# confirm that wrote the row, not a claim about the window's current state, and §8b
# depends on every slice carrying it: were it cleared here, a later cancel of this row
# would no longer reopen the window. It is also what makes the row eligible to carry the
# recomputed figure above.
if ($lv[2] -ne '1')     { Fail "the surviving over-received row should still carry VarianceAccepted=1, got $($lv[2]) row(s)" }
OK 'window reconciles with live receipts (201 = 201); figure restated to -199 on the surviving ticked row'

$rev = Sql @"
SET NOCOUNT ON;
SELECT CAST(rv.QtyReceived AS VARCHAR)+'|'+CAST(rv.VarianceAccepted AS VARCHAR)+'|'
     + CASE WHEN rv.PurchaseOrderLineId = orig.PurchaseOrderLineId THEN 'same' ELSE 'DIFFERENT' END
FROM dbo.Receipts rv
INNER JOIN dbo.Receipts orig ON orig.Id = rv.ReversesReceiptId
WHERE rv.ReversesReceiptId = '$($first.receiptId)';
"@
$rp = ($rev | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
if ($rp[0] -ne '-200') { Fail "reversal row should carry -200, got $($rp[0])" }
# §7.3 — the reversal goes back to the line the original consumed, never via FIFO.
if ($rp[2] -ne 'same') { Fail "reversal landed on a different PO line than the original" }
# The reversal is not itself a variance act; stamping it would double-count the flag.
if ($rp[1] -ne '0')    { Fail "reversal row should carry VarianceAccepted=0, got $($rp[1])" }
OK "reversal row: -200, VarianceAccepted=0, same PO line as the original"

# ORDER BY is load-bearing now that the anchor PO has two lines: without it the row
# this reads is whatever the plan happens to return first.
$po = Sql @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR)+'|'+po.Status
FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = '$SEED_PO' AND pol.LineNumber = 1;
"@
$pp = ($po | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
if ($pp[0] -ne '0')    { Fail "pull PO line 1 should be back to 0 received, got $($pp[0])" }
# Step 7 auto-reopen. Both lines were at-or-past their ordered quantity after the
# receive (200/200 and 201/200), so NOT EXISTS(OrderedQty > ReceivedQty) held and the PO
# auto-closed. Giving line 1's quantity back has to make it a FIFO candidate again or the
# next receive cannot reach it. Note line 2 stays at 201/200 and is correctly NOT a
# candidate — the walk filters OrderedQty > ReceivedQty, so an over-received line drops
# out of availability on its own (brief §5).
if ($pp[1] -ne 'open') { Fail "pull PO auto-closed on full receipt should have reopened on cancel, got '$($pp[1])'" }
OK 'pull PO line 1 restored to 0/200 and the auto-closed PO reopened'

# The forward path is the real test of "not stranded": with 201 of 400 received the
# window has 199 outstanding, and that remainder must allocate on the narrow path —
# line 1 has its 200 back, which covers it.
$pv = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$pi&qty=199&hour=$HOUR&varianceAccepted=false" -WebSession $sv
if ($pv.scope -ne 'pull-locked')            { Fail "forward preview should be plain pull-locked, got '$($pv.scope)'" }
if ($pv.allocations.Count -ne 1)            { Fail "forward preview should need 1 slice, got $($pv.allocations.Count)" }
if ($pv.allocations[0].qty -ne 199)         { Fail "forward preview should allocate 199, got $($pv.allocations[0].qty)" }
if ($pv.allocations[0].poNumber -ne $SEED_PO) { Fail "forward preview should sit on the pull's own PO, got $($pv.allocations[0].poNumber)" }
if ($pv.allocations[0].overReceivedQty -ne 0) { Fail "forward preview is within capacity and must report overReceivedQty 0" }
OK "forward path intact: 199 previews as one slice on $SEED_PO line 1, within capacity"

# ---------------------------------------------------------------------------
Step '2. Same over-receipt, box UNTICKED → 400, nothing recorded'
Cleanup; SeedAnchorPo 400
$fail = ReceiveExpectFail $sv $pi 401 $false $null 400
if (-not $fail -or $fail.Wrong) { Fail "expected 400, got $($fail.Status)" }
if ($fail.Code -ne 'OVER_RECEIPT_NOT_ACCEPTED') { Fail "expected OVER_RECEIPT_NOT_ACCEPTED, got $($fail.Code)" }
$n = SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Receipts WHERE PullItemId='$pi';"
if ($n -ne '0') { Fail "unticked over-receipt wrote $n rows; expected 0" }
OK "unticked over-receipt refused with OVER_RECEIPT_NOT_ACCEPTED, zero rows written"

# ---------------------------------------------------------------------------
Step '3. Pull PO alone covers the qty → ONE row, label stays pull-locked'
Cleanup; SeedAnchorPo 500
$res3 = Receive $sv $pi 401 $true 'Over by 1, but the pull PO has headroom.'
if ($res3.allocations.Count -ne 1) { Fail "expected 1 slice, got $($res3.allocations.Count)" }
if ($res3.allocations[0].poNumber -ne $SEED_PO) { Fail "the single slice should be the pull's own PO" }
# 401 into a 500 line is not an over-receipt at all, whatever the tick says. The figure
# is decided from the plan that was built, never from the request flag.
if ($res3.allocations[0].overReceivedQty -ne 0) { Fail "within-capacity receive must report overReceivedQty 0, got $($res3.allocations[0].overReceivedQty)" }
$audit3 = SqlScalar @"
SET NOCOUNT ON;
SELECT TOP 1 Message FROM dbo.AuditLog
WHERE EntityId = 'pi=$pi' AND ActionType = 'receive' ORDER BY OccurredAt DESC;
"@
if ($audit3 -match 'variance overflow') { Fail "no slice left the pull's PO — label must NOT say overflow. Got: $audit3" }
if ($audit3 -notmatch 'Scope: pull-locked') { Fail "expected 'Scope: pull-locked'. Got: $audit3" }
if ($audit3 -match 'Over-receipt:') { Fail "a within-capacity receive must not carry the over-receipt clause. Got: $audit3" }
OK 'headroom case stayed on one PO, plain pull-locked label, no over-receipt clause'

# ---------------------------------------------------------------------------
# INVERTED — and it is the case that proves the reversal (brief §6 case 3).
#
# This was 'Overflow never crosses vendors': it seeded a fat DIFFERENT-vendor PO and
# asserted the walk would not reach it, because overflow was allowed to cross POs but
# not vendors. The distinction no longer exists. An over-receipt does not reach ANY
# other purchase order — not another vendor's, and not another pull's under the SAME
# vendor, which is the one production actually hit (0000028773 spilled onto
# TH5805-P233094, same vendor, different pull).
#
# So the fixture is now the harder one: a same-vendor, same-item, OLDER PO with ample
# capacity, positioned so that any residual widening would reach it first.
Step '4. A same-vendor PO on another pull is untouched by an over-receipt'
Cleanup; SeedAnchorPo 400; SeedSameVendorOtherPullPo
$res4 = Receive $sv $pi 401 $true 'Vendor over-delivered by 1; accepted at gate.'
if ($res4.allocations.Count -ne 1) {
    $where = ($res4.allocations | ForEach-Object { "$($_.qty)@$($_.poNumber)" }) -join ' + '
    Fail "over-receipt spread across $($res4.allocations.Count) POs: $where — it must stay on the pull's own line"
}
if ($res4.allocations[0].poNumber -ne $SEED_PO) { Fail "the slice must be the pull's own PO, got $($res4.allocations[0].poNumber)" }

$otherTouched = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR) FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId WHERE po.PoNumber = '$OTHER_PO';
"@
if ($otherTouched -ne '0') { Fail "the other pull's PO line was consumed ($otherTouched) — the spill is back" }

# Nothing anywhere else in the warehouse moved either. The narrow check above would pass
# if the excess had landed on some third line; this one would not.
$strayLines = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR)
FROM   dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE  po.WarehouseId = '$WH_BPI' AND pol.ItemCode = '$ITEM'
  AND  pol.ReceivedQty > 0 AND po.PoNumber <> '$SEED_PO';
"@
if ($strayLines -ne '0') { Fail "$strayLines PO line(s) outside the pull's own PO carry receipts for this item" }
OK "401 stayed on $SEED_PO; the same-vendor PO on another pull and every other line untouched"

# ---------------------------------------------------------------------------
Step '7. Normal in-range receive, unticked → narrow path unchanged'
Cleanup; SeedAnchorPo 400
$res7 = Receive $sv $pi 250 $false 'Ordinary partial.'
if ($res7.allocations.Count -ne 1) { Fail "expected 1 slice, got $($res7.allocations.Count)" }
if ($res7.allocations[0].poNumber -ne $SEED_PO) { Fail "partial should sit on the pull's own PO" }
if ($res7.allocations[0].overReceivedQty -ne 0) { Fail "an in-range partial must report overReceivedQty 0" }
$audit7 = SqlScalar @"
SET NOCOUNT ON;
SELECT TOP 1 Message FROM dbo.AuditLog
WHERE EntityId = 'pi=$pi' AND ActionType = 'receive' ORDER BY OccurredAt DESC;
"@
if ($audit7 -match 'variance overflow') { Fail "in-range receive must not be labelled overflow. Got: $audit7" }
$closed7 = SqlScalar "SET NOCOUNT ON; SELECT CAST(IsClosed AS VARCHAR) FROM dbo.PullItemWindows WHERE PullItemId='$pi' AND HourOfDay=$HOUR;"
if ($closed7 -ne '0') { Fail "an unticked partial must leave the line open, got IsClosed=$closed7" }
OK "in-range partial: one pull-linked slice, plain label, line left open"

# ===========================================================================
# Cases 8-12 — the step-8c variance recompute.
#
# VarianceQty describes a decision about a WINDOW ("401 arrived against 400 outstanding")
# but is stored on one arbitrary slice. Cancel is row-scoped, so before step 8c existed,
# reversing any other slice left that number describing a receive that no longer happened.
# Cases 6/6b/6c above assert the IsClosed half of the reversal; these assert the quantity.
#
# THE INVARIANT, asserted directly in each case below. For a window carrying at least one
# live VarianceAccepted row:
#     SUM(VarianceQty) over live rows of (PullItemId, HourOfDay)
#         == SUM(QtyReceived) over those rows - window.ExpectedQty
#     SIGNED — negative when short, positive when over — and NULL only when that
#     difference is exactly zero.
# "Live" = not voided (ReversedById) and not itself a reversal (ReversesReceiptId).
#
# Where NO live row carries the tick the invariant does not apply and VarianceQty stays
# NULL everywhere: an ordinary partial is also live < expected, and stamping the figure on
# a plain row would make every partial read as an accepted variance. Case 11 is that guard.
# ===========================================================================

# live qty | live SUM(VarianceQty) as text ('NULL' when none) | rows carrying a non-NULL
# VarianceQty | live row count | live rows carrying VarianceAccepted. The non-NULL COUNT
# matters on its own: a SUM that happens to be right while two rows each carry half of it
# would satisfy the arithmetic and still be the bug this fixes.
function LiveStats($pi) {
    $r = Sql @"
SET NOCOUNT ON;
SELECT CAST(ISNULL(SUM(r.QtyReceived),0) AS VARCHAR)+'|'
     + ISNULL(CAST(SUM(r.VarianceQty) AS VARCHAR),'NULL')+'|'
     + CAST(COUNT(r.VarianceQty) AS VARCHAR)+'|'
     + CAST(COUNT(*) AS VARCHAR)+'|'
     + CAST(SUM(CASE WHEN r.VarianceAccepted=1 THEN 1 ELSE 0 END) AS VARCHAR)
FROM dbo.Receipts r
WHERE r.PullItemId='$pi' AND r.HourOfDay=$HOUR
  AND r.ReversedById IS NULL AND r.ReversesReceiptId IS NULL;
"@
    $p = ($r | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
    return [pscustomobject]@{ Qty=[int]$p[0]; VarSum=$p[1]; VarRows=[int]$p[2]; Rows=[int]$p[3]
                              TickedRows=[int]$p[4] }
}

function WinStats($pi) {
    $r = Sql @"
SET NOCOUNT ON;
SELECT CAST(ReceivedQty AS VARCHAR)+'|'+CAST(ExpectedQty AS VARCHAR)+'|'+CAST(IsClosed AS VARCHAR)
FROM dbo.PullItemWindows WHERE PullItemId='$pi' AND HourOfDay=$HOUR;
"@
    $p = ($r | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
    return [pscustomobject]@{ Received=[int]$p[0]; Expected=[int]$p[1]; IsClosed=($p[2] -eq '1') }
}

function CancelSlice($session, $receiptId, $note) {
    Invoke-RestMethod -Uri "$base/api/receipts/$receiptId/cancel" -Method POST `
        -Body (@{ reason='miscount'; note=$note } | ConvertTo-Json) `
        -ContentType 'application/json' -WebSession $session | Out-Null
}

# Asserts the invariant itself rather than a hardcoded number, so a case that changes its
# quantities cannot quietly stop testing anything.
function AssertInvariant($pi, $label) {
    $l = LiveStats $pi; $w = WinStats $pi
    $delta = $l.Qty - $w.Expected
    # Signed: the figure is carried whenever the difference is non-zero AND some live row
    # holds the tick to carry it on.
    $applies = ($l.TickedRows -gt 0 -and $delta -ne 0)
    $expectedSum = if ($applies) { "$delta" } else { 'NULL' }
    if ($l.VarSum -ne $expectedSum) {
        Fail "$label — invariant broken: live qty $($l.Qty) - expected $($w.Expected) = $delta with $($l.TickedRows) ticked row(s), so SUM(VarianceQty) should be $expectedSum, got $($l.VarSum)"
    }
    $wantRows = if ($applies) { 1 } else { 0 }
    if ($l.VarRows -ne $wantRows) {
        Fail "$label — expected exactly $wantRows live row(s) carrying VarianceQty, got $($l.VarRows)"
    }
    if ($l.Qty -ne $w.Received) {
        Fail "$label — window cache $($w.Received) does not reconcile with live receipts $($l.Qty)"
    }
    return [pscustomobject]@{ Live=$l; Win=$w; Delta=$delta }
}

# The pull-status demotion is a SEPARATE, logged defect (cancel's step 9 demotes on status
# alone instead of recomputing from outstanding windows, the way ReceiveAsync's step 7
# does). It is reported here rather than asserted green, so the smoke records the real
# behaviour without blessing it. When step 9 grows the recompute this prints PASS instead,
# and no assertion has to change.
function ReportPullStatus($pi, $label) {
    $s = SqlScalar "SET NOCOUNT ON; SELECT Status FROM dbo.Pulls WHERE PullNumber='$PULL_NO';"
    $outstanding = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PullItems pi
INNER JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
WHERE pi.PullId = (SELECT Id FROM dbo.Pulls WHERE PullNumber='$PULL_NO')
  AND pi.Status <> 'canceled' AND piw.IsClosed = 0 AND piw.ExpectedQty > piw.ReceivedQty;
"@
    if ($outstanding -eq '0' -and $s -ne 'fully_received') {
        Write-Host "KNOWN DEFECT ($label): 0 outstanding windows but pull status is '$s' — cancel step 9 demotes on status alone. Logged in db/047_STATUS.md, not fixed here." -ForegroundColor Yellow
    } else {
        OK "$label — pull status '$s' with $outstanding outstanding window(s)"
    }
}

# ---------------------------------------------------------------------------
# RE-SEEDED. This case used to receive 401 against a single 400 line and cancel the
# 1-pc overflow slice — the excess had its own row precisely because it lived on
# someone else's PO. It no longer does: the excess is merged into the last slice on
# the pull's own line, so "cancel the slice that is exactly the excess" has no
# referent. The invariant under test is untouched — SUM(VarianceQty) clears to NULL
# at exactly zero delta — so the fixture reaches zero a different way: three of the
# pull's own 200-lines, 600 received against 400 expected, cancel one 200 slice.
Step '8. 600 ticked across three own lines -> cancel one slice -> variance figure clears'
Cleanup; SeedAnchorPoLines 3 200
$r8 = Receive $sv $pi 600 $true 'Vendor over-delivered by 200; accepted at gate.'
if ($r8.allocations.Count -ne 3) { Fail "expected 3 slices across the 3-line anchor PO, got $($r8.allocations.Count)" }
$s8over = $r8.allocations[2]
$pre8 = AssertInvariant $pi '8 (before cancel)'
if ($pre8.Delta -ne 200) { Fail "precondition: window should be over by 200, got $($pre8.Delta)" }

CancelSlice $sv $s8over.receiptId 'smoke: reverse the last slice'
$a8 = AssertInvariant $pi '8'
if ($a8.Win.Received -ne 400 -or $a8.Win.Expected -ne 400) { Fail "window should be 400/400, got $($a8.Win.Received)/$($a8.Win.Expected)" }
if ($a8.Win.IsClosed) { Fail "IsClosed should have cleared, got 1" }
if ($a8.Live.VarSum -ne 'NULL') { Fail "SUM(VarianceQty) should be NULL at exactly 400/400, got $($a8.Live.VarSum)" }
OK 'window 400/400, IsClosed=0, SUM(VarianceQty)=NULL — the +200 did not survive the slice that carried it'
ReportPullStatus $pi '8'

# ---------------------------------------------------------------------------
# RE-SEEDED for the same reason as case 8: the slice this cancels used to be the
# pull-linked one, identified by the retired isPullLinked flag. Two own lines of 200
# with 401 received gives slices [200, 201]; cancelling the first leaves 201 live.
Step '9. 401 ticked -> cancel the FIRST slice -> figure restated to -199 on an OPEN window'
Cleanup; SeedAnchorPoLines 2 200
$r9 = Receive $sv $pi 401 $true 'Vendor over-delivered by 1; accepted at gate.'
if ($r9.allocations.Count -ne 2) { Fail "expected 2 slices, got $($r9.allocations.Count)" }
CancelSlice $sv $r9.allocations[0].receiptId 'smoke: reverse the first slice'

$a9 = AssertInvariant $pi '9'
if ($a9.Live.Qty -ne 201)  { Fail "live SUM(qty) should be 201, got $($a9.Live.Qty)" }
if ($a9.Win.IsClosed)      { Fail "IsClosed should have cleared, got 1" }
# Signed rule: the surviving row carried the operator's tick, so it carries the window's
# current difference — 201 - 400 = -199. The figure tracks the quantities, not whether the
# window happens to be closed right now; IsClosed is asserted separately, just above.
if ($a9.Live.VarSum -ne '-199') { Fail "surviving ticked row should carry -199, got $($a9.Live.VarSum)" }
if ($a9.Live.VarRows -ne 1)     { Fail "expected exactly 1 row carrying the figure, got $($a9.Live.VarRows)" }
OK 'live 201 pcs of 400, IsClosed=0, VarianceQty restated to -199 on the surviving ticked row'

# ---------------------------------------------------------------------------
# RE-SEEDED: the three slices used to be 400 on the anchor plus two pool lines. They
# are now three lines of the pull's OWN PO, which is the only way a receive splits
# three ways at all now. Quantities and every assertion below are unchanged.
Step '10. 1,200 ticked across three slices -> cancel the MIDDLE slice -> invariant holds'
Cleanup; SeedAnchorPoLines 3 400
$r10 = Receive $sv $pi 1200 $true 'Three-way split; over by 800.'
if ($r10.allocations.Count -ne 3) { Fail "expected 3 slices for 1,200 across three 400 lines, got $($r10.allocations.Count)" }
$pre10 = AssertInvariant $pi '10 (before cancel)'
if ($pre10.Delta -ne 800) { Fail "precondition: window should be over by 800, got $($pre10.Delta)" }

$mid = $r10.allocations[1]
CancelSlice $sv $mid.receiptId 'smoke: reverse the middle slice'

$a10 = AssertInvariant $pi '10'
# Still over after the cancel, so the figure is RESTATED rather than cleared — this is the
# branch that proves the recompute writes a new value, not merely nulls the old one.
if ($a10.Delta -le 0) { Fail "expected the window to still be over after cancelling one slice, got delta $($a10.Delta)" }
if ($a10.Live.VarSum -ne '400') { Fail "SUM(VarianceQty) should be restated to 400, got $($a10.Live.VarSum)" }
if ($a10.Live.Rows -ne 2)       { Fail "expected 2 live slices remaining, got $($a10.Live.Rows)" }
$carrierLive = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Receipts
WHERE PullItemId='$pi' AND HourOfDay=$HOUR AND VarianceQty IS NOT NULL
  AND ReversedById IS NULL AND ReversesReceiptId IS NULL AND Id <> '$($mid.receiptId)';
"@
if ($carrierLive -ne '1') { Fail "the restated figure should sit on a surviving row, got $carrierLive" }
OK "800 -> 400 restated onto one surviving slice; live 800 vs expected 400 reconciles"

# ---------------------------------------------------------------------------
Step '11. Non-variance multi-row receive -> cancel one slice -> VarianceQty stays NULL'
# Regression guard on the normal path: the recompute runs on EVERY cancel, so it has to be
# provably inert when no variance was ever accepted.
Cleanup; SeedAnchorPoLines 2 200
$r11 = Receive $sv $pi 400 $false 'Ordinary receive, split across two lines of the same PO.'
if ($r11.allocations.Count -ne 2) { Fail "expected 2 slices across the 2-line anchor PO, got $($r11.allocations.Count)" }
$pre11 = LiveStats $pi
if ($pre11.VarRows -ne 0 -or $pre11.VarSum -ne 'NULL') { Fail "no variance was accepted; VarianceQty should be NULL on both rows, got sum=$($pre11.VarSum) rows=$($pre11.VarRows)" }
$w11 = WinStats $pi
if ($w11.IsClosed) { Fail "an unticked receive must not close the window" }

CancelSlice $sv $r11.allocations[0].receiptId 'smoke: reverse one slice of a plain receive'
$a11 = AssertInvariant $pi '11'
if ($a11.Live.VarSum -ne 'NULL') { Fail "VarianceQty must stay NULL through a non-variance cancel, got $($a11.Live.VarSum)" }
if ($a11.Live.VarRows -ne 0)     { Fail "no row should have gained a VarianceQty, got $($a11.Live.VarRows)" }
if ($a11.Win.IsClosed)           { Fail "window must stay open, got IsClosed=1" }
if ($a11.Live.Qty -ne 200)       { Fail "live qty should be 200 after reversing one 200 slice, got $($a11.Live.Qty)" }
OK "plain multi-row receive: VarianceQty NULL before and after the cancel, window untouched by 8c"

# ---------------------------------------------------------------------------
Step '12. Cancelling a PLAIN sibling of a short close recomputes it too'
# The orphaning is not exclusive to overflow. A closed window whose plain partial is
# reversed keeps its close but loses the quantity that close was measured against, so 8c
# has to run even though the cancelled row carries no flag of its own.
#
# The window stays CLOSED here (the cancelled row carries no flag, so §8b does not fire),
# which makes this the case where a stale figure would be least visible: a closed line
# reading "-100 short" while actually 200 short of 400.
Cleanup; SeedAnchorPo 400
$plain = Receive $sv $pi 100 $false 'Plain partial.'
$short = Receive $sv $pi 200 $true  'That is all that is coming — closing short.'
if ($short.varianceQty -ne -100) { Fail "precondition: short close should record VarianceQty=-100, got $($short.varianceQty)" }
$w12pre = WinStats $pi
if (-not $w12pre.IsClosed) { Fail "precondition: the short close should have closed the window" }

CancelSlice $sv $plain.allocations[0].receiptId 'smoke: reverse the plain partial under a closed window'
$a12 = AssertInvariant $pi '12'
# The cancelled row carried no flag, so §8b does not fire and the close correctly stands.
if (-not $a12.Win.IsClosed) { Fail "cancelling a NON-variance row must not reopen the window, got IsClosed=0" }
if ($a12.Win.Received -ne 200) { Fail "window should be 200/400 after reversing the 100, got $($a12.Win.Received)" }
# Restated, not cleared: 200 - 400 = -200 replaces the stale -100.
if ($a12.Live.VarSum -ne '-200') { Fail "the stale -100 should have been restated to -200, got $($a12.Live.VarSum)" }
if ($a12.Live.VarRows -ne 1)     { Fail "expected exactly 1 row carrying the figure, got $($a12.Live.VarRows)" }
OK "closed window recomputed under a plain-sibling cancel: 200/400, still closed, -100 restated to -200"

# ---------------------------------------------------------------------------
Step '13. Accepted short close split across two slices -> cancel one of its OWN slices'
# The negative counterpart of case 10, and the multi-row counterpart of case 12: a short
# close that FIFO split across two PO lines, with one of those slices reversed. Proves the
# carrier is re-picked among the surviving ticked rows and the figure is restated with its
# sign intact, rather than being dropped because it is negative.
Cleanup; SeedAnchorPoLines 2 200
$r13 = Receive $sv $pi 300 $true 'Only 300 of 400 arrived — closing short.'
if ($r13.allocations.Count -ne 2) { Fail "expected the 300 to split across the 2-line anchor PO, got $($r13.allocations.Count)" }
if ($r13.varianceQty -ne -100)    { Fail "precondition: 300 against 400 outstanding is -100, got $($r13.varianceQty)" }
$pre13 = AssertInvariant $pi '13 (before cancel)'
if (-not $pre13.Win.IsClosed) { Fail "precondition: the short close should have closed the window" }

# Reverse the slice that does NOT carry the figure, so the restate has to move it.
$carrier13 = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(Id AS VARCHAR(36)) FROM dbo.Receipts
WHERE PullItemId='$pi' AND HourOfDay=$HOUR AND VarianceQty IS NOT NULL
  AND ReversedById IS NULL AND ReversesReceiptId IS NULL;
"@
$other13 = $r13.allocations | Where-Object { $_.receiptId -ne $carrier13 } | Select-Object -First 1
if (-not $other13) { Fail "could not identify the non-carrier slice (carrier=$carrier13)" }
CancelSlice $sv $other13.receiptId 'smoke: reverse the non-carrier slice of a short close'

$a13 = AssertInvariant $pi '13'
if ($a13.Delta -ge 0) { Fail "expected the window to still be short, got delta $($a13.Delta)" }
$want13 = "$($a13.Live.Qty - 400)"
if ($a13.Live.VarSum -ne $want13) { Fail "surviving ticked row should carry $want13 (live $($a13.Live.Qty) - 400), got $($a13.Live.VarSum)" }
if ($a13.Live.VarRows -ne 1)      { Fail "expected exactly 1 row carrying the figure, got $($a13.Live.VarRows)" }
OK "short close restated with its sign: live $($a13.Live.Qty) of 400 carries $want13 on exactly one surviving ticked row"

# ===========================================================================
# 14-16 — the schema half. These assert db/051 and the reads that depend on it,
# because "the receive succeeded" is not on its own proof that the constraint was
# relaxed rather than the quantity quietly clamped somewhere.
# ===========================================================================
Step '14. db/051 — the line accepts ReceivedQty > OrderedQty, and still rejects a negative'
$def = SqlScalar @"
SET NOCOUNT ON;
SELECT c.definition FROM sys.check_constraints c
WHERE c.parent_object_id = OBJECT_ID('dbo.PurchaseOrderLines') AND c.name = 'CK_POL_Caps';
"@
if (-not $def) { Fail 'CK_POL_Caps is missing entirely — db/051 has not been run' }
if ($def -match 'OrderedQty') { Fail "CK_POL_Caps still caps against OrderedQty — db/051 has not been run. Got: $def" }
if ($def -notmatch 'ReceivedQty') { Fail "CK_POL_Caps lost its ReceivedQty floor. Got: $def" }
OK "CK_POL_Caps = $($def.Trim()) — ceiling dropped, floor kept"

# Behavioural, not just structural: a definition check passes against a constraint that
# was left disabled or untrusted. Both writes are rolled back.
Cleanup; SeedAnchorPo 400
$probe = SqlScalar @"
SET NOCOUNT ON;
DECLARE @id UNIQUEIDENTIFIER = (SELECT TOP 1 pol.Id FROM dbo.PurchaseOrderLines pol
    INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId WHERE po.PoNumber='$SEED_PO');
DECLARE @over VARCHAR(10) = 'no', @neg VARCHAR(10) = 'accepted';
BEGIN TRY
    BEGIN TRAN; UPDATE dbo.PurchaseOrderLines SET ReceivedQty = 401 WHERE Id = @id; SET @over='yes'; ROLLBACK;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; END CATCH
BEGIN TRY
    BEGIN TRAN; UPDATE dbo.PurchaseOrderLines SET ReceivedQty = -1 WHERE Id = @id; ROLLBACK;
END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; SET @neg='rejected'; END CATCH
SELECT @over + '|' + @neg;
"@
$pb = $probe.Trim() -split '\|'
if ($pb[0] -ne 'yes')      { Fail 'the constraint still rejects ReceivedQty > OrderedQty' }
if ($pb[1] -ne 'rejected') { Fail 'the constraint accepts a NEGATIVE ReceivedQty — the floor was lost with the ceiling, and CancelAsync has nothing beneath it' }
OK '401 against a 400 line accepted; -1 still rejected'

# ---------------------------------------------------------------------------
Step '15. vw_PurchaseOrderAvailability excludes an over-received line'
Cleanup; SeedAnchorPo 400
Receive $sv $pi 401 $true 'Over by 1.' | Out-Null
$avail = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.vw_PurchaseOrderAvailability v
INNER JOIN dbo.PurchaseOrders po ON po.Id = v.PurchaseOrderId WHERE po.PoNumber = '$SEED_PO';
"@
if ($avail -ne '0') { Fail "an over-received line is still listed as available ($avail row(s)); RemainingQty would be negative" }
OK 'the over-received line drops out of availability on its own (OrderedQty > ReceivedQty is false)'

# ---------------------------------------------------------------------------
Step '16. Auto-close fires for a PO whose line is over-received'
# NOT EXISTS(OrderedQty > ReceivedQty) — 401 is not < 400, so the line does not hold
# the PO open. A cap-era reading that looked for equality would leave it open forever.
$status = SqlScalar "SET NOCOUNT ON; SELECT po.Status FROM dbo.PurchaseOrders po WHERE po.PoNumber = '$SEED_PO';"
if ($status.Trim() -ne 'closed') { Fail "PO with an over-received line should have auto-closed, got '$($status.Trim())'" }
OK 'the PO auto-closed with its line at 401/400'

# ===========================================================================
# 17 — §4.3, the storer rule. The overage is a claim that a SPECIFIC supplier
# over-delivered, so it may only land on a line belonging to the pull item's own
# storer. Allocation within capacity keeps its documented fallback onto the shared
# pool (docs/defect-storer-without-po-line.md, 629 live items on open pulls); what
# does not fall back is pushing a line past its OrderedQty.
# ===========================================================================
Step '17. Over-receipt is refused when the item has no line of its own storer'
Cleanup; SeedAnchorPo 400
# Retag the pull item to a storer that owns no line here, leaving the anchor PO's own
# vendor in place. The walk falls back to the shared pool and can still FILL the order —
# but the excess has no line of this storer's to land on.
$origVendor = SqlScalar "SET NOCOUNT ON; SELECT ISNULL(VendorCode,'<null>') FROM dbo.PullItems WHERE Id='$pi';"
Sql "SET NOCOUNT ON; UPDATE dbo.PullItems SET VendorCode = 'SOV-NOSUCHSTORER' WHERE Id = '$pi';" | Out-Null

$within = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$pi&qty=400&hour=$HOUR&varianceAccepted=false" -WebSession $sv
if ($within.allocations.Count -lt 1) { Fail 'the fallback must still allocate WITHIN capacity — those items have to stay receivable' }
OK 'within capacity: the storer fallback still allocates from the shared pool, unchanged'

$fail17 = ReceiveExpectFail $sv $pi 401 $true 'Over by 1 with no storer PO.' 409
if (-not $fail17 -or $fail17.Wrong) { Fail "expected 409, got $($fail17.Status) / $($fail17.Title)" }
if ($fail17.Code -ne 'OVER_RECEIPT_NO_STORER_PO') { Fail "expected OVER_RECEIPT_NO_STORER_PO, got '$($fail17.Code)'" }
if ($fail17.Title -notmatch 'SOV-NOSUCHSTORER') { Fail "the refusal must name the storer so procurement knows what to raise. Got: $($fail17.Title)" }
if ($fail17.Title -notmatch 'raise a purchase order') { Fail "the refusal must say what to do. Got: $($fail17.Title)" }
$wrote17 = SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Receipts WHERE PullItemId='$pi';"
if ($wrote17 -ne '0') { Fail "the refused over-receipt wrote $wrote17 row(s); expected 0" }
OK "refused with OVER_RECEIPT_NO_STORER_PO naming the storer; nothing written"

# ---------------------------------------------------------------------------
Step '17b. A NULL-storer item gets a DIFFERENT refusal'
# 2,943 items on open pulls carry no storer — historical rows merged before the ERP
# grained by (SKU, storer). There is no supplier to attribute an over-delivery to, so
# this refuses too, but must NOT send the operator to procurement: there is no storer
# to raise a PO against, and an instruction that cannot be acted on is worse than a
# plain refusal.
Sql "SET NOCOUNT ON; UPDATE dbo.PullItems SET VendorCode = NULL WHERE Id = '$pi';" | Out-Null
$fail17b = ReceiveExpectFail $sv $pi 401 $true 'Over by 1 with no storer at all.' 409
if (-not $fail17b -or $fail17b.Wrong) { Fail "expected 409, got $($fail17b.Status) / $($fail17b.Title)" }
if ($fail17b.Code -ne 'OVER_RECEIPT_NO_STORER') { Fail "expected OVER_RECEIPT_NO_STORER, got '$($fail17b.Code)'" }
if ($fail17b.Title -match 'raise a purchase order') { Fail "a NULL-storer item must NOT be sent to procurement — there is no storer to raise one against. Got: $($fail17b.Title)" }
if ($fail17b.Title -notmatch 'no storer recorded') { Fail "the refusal must say why it cannot be attributed. Got: $($fail17b.Title)" }
OK 'NULL-storer over-receipt refused with its own message, no procurement instruction'

# Restore the fixture's storer so a re-run starts from the same state.
if ($origVendor.Trim() -eq '<null>') {
    Sql "SET NOCOUNT ON; UPDATE dbo.PullItems SET VendorCode = NULL WHERE Id = '$pi';" | Out-Null
} else {
    Sql "SET NOCOUNT ON; UPDATE dbo.PullItems SET VendorCode = '$($origVendor.Trim())' WHERE Id = '$pi';" | Out-Null
}
OK "pull item storer restored to $($origVendor.Trim())"

# ---------------------------------------------------------------------------
Cleanup
Write-Host "`nALL CASES PASSED" -ForegroundColor Green

# ---------------------------------------------------------------------------
# NOT COVERED HERE (brief §7) — deliberately, so the gaps are visible:
#   §7.4  three-slice spill (1,200 against a 400 line). Case 1 proves the walk
#         spills and case 4 proves it stops; the 3-slice shape adds arithmetic,
#         not a new branch.
#   §7.6  cross-warehouse isolation. The warehouse predicate is untouched by this
#         change and sits outside the overflow branch entirely.
#   §7.8  "no PO linked + PullItems.VendorCode NULL". The PullItems fallback was
#         dropped from the design, so there is no widening path to test — the
#         anchor comes only from a pull-linked line, and with none the code takes
#         today's "No PO linked" branch unchanged.
#   §7.9  zero-qty short close with the PO exhausted. Covered by smoke-close-reopen.
#   §7.11 concurrency (two simultaneous over-receives). Needs a parallel harness;
#         the conditional close-update and HOLDLOCK are unchanged by this work.
#   §7.13 overflow slice fully consuming a PO and auto-closing it. The auto-close
#         step was not modified. (6c does assert the reopen half of it.)
#
# BRIEF §7.12 — CANCEL SCOPE. RESOLVED AS "NO CHANGE", RECORDED HERE.
# ------------------------------------------------------------------
# The brief expects cancelling a receive that produced N rows to reverse all N.
# It does not: POST /api/receipts/{id}/cancel is scoped to one receipt ROW, and
# dbo.Receipts carries no confirm/batch key that could group the N rows a single
# confirm wrote (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay,
# QtyReceived, ..., ReversesReceiptId, ReversedById — nothing else). Confirm-scoped
# cancel would need a new column or a ReceivedAt heuristic.
#
# This is pre-existing v2 §7.2a behaviour, not something overflow introduced — FIFO
# has been able to split one confirm across PO lines since v2. Overflow only makes
# it routine on the variance path. Cancel REMAINS row-scoped; no batch id was added.
#
# What that leaves is a reachable half-reversed state, so it is asserted rather than
# assumed: case 6 (cancel the non-carrier), 6b (cancel the carrier), and 6c (the
# resulting state reconciles and the operator still has a forward path). If cancel
# ever becomes confirm-scoped, 6c is the test that should fail first and loudest.
#
# WHAT CHANGED AFTER THAT REVIEW
# ------------------------------
# Row-scoped cancel was accepted; leaving VarianceQty behind was not. Cases 6/6b/6c
# only ever asserted the IsClosed half of a partial reversal, and 6c explicitly waved
# the surviving flag through as "provenance". That was right about VarianceAccepted
# and wrong about VarianceQty: the flag describes which confirm wrote a row, but the
# QUANTITY describes a window-level decision, so leaving the original figure on a
# surviving slice left the ledger asserting an over-delivery that had been reversed.
# ReceiptService step 8c now recomputes it from the surviving rows on every cancel.
# Cases 8-12 assert that invariant; 6c's SUM(VarianceQty)=0 assertion was the first
# hint of it and is now a special case of the general rule.
