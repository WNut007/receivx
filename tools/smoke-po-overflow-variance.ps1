# Smoke test: PO allocation overflow past the pull-linked PO when variance is accepted
#
# Brief: brief-po-overflow-on-variance.md (§7 test cases).
#
# THE CASE THIS REPRODUCES
# ------------------------
# Pull 0000026590, WH-BPI, item 2063-810743-0E4, hour 20. The window expects 400;
# the vendor delivered 401. The operator ticks accept-variance. Before this change
# the receive was refused by PO-line capacity (BUILD_PROMPT §7.1 Cap 2) with
# "Insufficient PO capacity. Need 401, have 400 pcs." — the pull's own PO had
# exactly 400 and FIFO was scoped to it, so nothing could be recorded.
#
# The over-delivered unit DOES have purchase-order cover: 22 other open PO lines
# for the same vendor (COI-HSABP1), same item, same warehouse. It just sat on a
# different line. This is a matching problem, not an unpurchased-goods problem,
# so the fix widens allocation rather than relaxing any cap. Every received unit
# still lands on a real PO line; CK_POL_Caps is untouched.
#
# THE SEED, AND WHY IT IS HERE
# ----------------------------
# The dev database carries pull 0000026590 and the 22-line overflow pool, but NOT
# the anchor PO that production has (PoNumber = PullExternalRef = '0000026590',
# one line, 400 pcs). Without it the receive fails earlier and differently —
# "No PO linked to this pull" — which is a different 409 and would silently make
# this smoke assert the wrong thing. The seed below creates that anchor PO so the
# production failure is reproducible locally, per the brief's §7 instruction to
# reproduce before changing anything.
#
# CASES
#   1.  Repro/§7.1  401 ticked → 200, TWO receipt rows (400 on the pull's PO line,
#                   1 on the FIFO-next line for the same vendor), window 401,
#                   IsClosed=1, VarianceAccepted=1, VarianceQty=1
#   2.  §7.2        Same request unticked → 400 OVER_RECEIPT_NOT_ACCEPTED, zero rows
#   3.  §7.3        Pull PO alone covers the qty → ONE row, audit scope 'pull-locked'
#                   (NOT the overflow label — overflow is decided from the plan, not
#                   from the request flag)
#   4.  §7.5        Overflow never crosses vendors — a fat open PO under a different
#                   VendorCode is not drawn on, and the receive fails instead
#   5.  §7.14       Audit row carries the overflow label + names every PO consumed
#   6.  NEW         VarianceAccepted / IsClosed across a multi-row allocation:
#                   cancelling the SECOND slice (the one whose VarianceQty is NULL)
#                   must still clear IsClosed. See the note at case 6.
#   6b. NEW         The same for the FIRST slice — the VarianceQty carrier.
#   6c. NEW         The half-reversed state 6b leaves behind, field by field:
#                   window cache reconciles with live receipt rows, reversal shape,
#                   PO line restored + auto-closed PO reopened, forward path intact.
#   7.  §7.10       Normal in-range receive, box unticked → single pull-linked slice,
#                   scope label unchanged. Regression guard on the narrow path.
#
# Cases 4, 6, 8, 9, 11, 13 of the brief are NOT covered here — see the trailer.
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

# Case 4 — a different vendor with ample stock, dated OLDER than everything else so
# a naive FIFO walk would reach it first. If overflow ever crossed vendors, this is
# the line it would grab.
function SeedOtherVendorPo {
    $q = @"
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DECLARE @po UNIQUEIDENTIFIER = NEWID();
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, Status, CreatedBy)
VALUES (@po, '$OTHER_PO', '$WH_BPI', '2020-01-01', 'open', '11111111-1111-1111-1111-000000000001');
INSERT INTO dbo.PurchaseOrderLines
    (PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName)
VALUES (@po, 1, '$ITEM', 'SOV wrong-vendor line', 999999, 0, 'COI-NOTTHISVENDOR', 'Not This Vendor');
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
if ($res.allocations.Count -ne 2) { Fail "expected 2 allocation slices, got $($res.allocations.Count)" }

$slice1 = $res.allocations[0]; $slice2 = $res.allocations[1]
if ($slice1.qty -ne 400) { Fail "slice 1 should take 400 from the pull's PO, got $($slice1.qty)" }
if ($slice1.poNumber -ne $SEED_PO) { Fail "slice 1 should be the pull-linked PO $SEED_PO, got $($slice1.poNumber)" }
if ($slice1.isPullLinked -ne $true) { Fail "slice 1 should be flagged isPullLinked" }
if ($slice2.qty -ne 1) { Fail "slice 2 should take 1, got $($slice2.qty)" }
if ($slice2.isPullLinked -ne $false) { Fail "slice 2 should be flagged as NOT pull-linked (overflow)" }
if ($slice2.poNumber -eq $SEED_PO) { Fail "slice 2 must come from a different PO" }
OK "401 allocated 400@$($slice1.poNumber) + 1@$($slice2.poNumber), overflow slice flagged"

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
if ($parts[2] -ne '2')   { Fail "expected VarianceAccepted=1 on BOTH rows, got $($parts[2])" }
if ($parts[3] -ne '1')   { Fail "expected SUM(VarianceQty)=1 (stamped once), got $($parts[3])" }
OK "window 401 / IsClosed=1 / VarianceAccepted on both rows / VarianceQty summed once"

# ---------------------------------------------------------------------------
Step '5. Audit row carries the overflow label and names every PO'
$audit = SqlScalar @"
SET NOCOUNT ON;
SELECT TOP 1 Message FROM dbo.AuditLog
WHERE EntityId = 'pi=$pi' AND ActionType = 'receive'
ORDER BY OccurredAt DESC;
"@
if ($audit -notmatch 'pull-locked \+ variance overflow') { Fail "audit missing overflow label. Got: $audit" }
if ($audit -notmatch [regex]::Escape("400@$SEED_PO")) { Fail "audit missing pull-linked slice. Got: $audit" }
if ($audit -notmatch [regex]::Escape("1@$($slice2.poNumber)")) { Fail "audit missing overflow slice. Got: $audit" }
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
Step '6. Cancel the SECOND slice (VarianceQty NULL) → IsClosed must still clear'
$cancelBody = @{ reason = 'miscount'; note = 'smoke: reverse overflow slice' } | ConvertTo-Json
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
if ($ap[1] -ne '400'){ Fail "window should be back to 400 after reversing 1, got $($ap[1])" }
OK "reversing the VarianceQty-NULL slice cleared IsClosed and left the window at 400"

# The overflow PO line must be whole again — the reversal goes back to ITS OWN line.
$restored = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR) FROM dbo.PurchaseOrderLines pol
WHERE pol.Id = '$($slice2.purchaseOrderLineId)';
"@
if ($restored -ne '0') { Fail "overflow PO line should be restored to 0, got $restored" }
OK "overflow slice reversed against its own PO line (ReceivedQty back to 0)"

# ---------------------------------------------------------------------------
# 6b — the other end of the same invariant. Case 6 proved the slice WITHOUT
# VarianceQty still clears IsClosed; this proves the slice WITH it does too, so
# neither end is left resting on inference. Both must hold, because §8b keys on
# VarianceAccepted — which every slice carries — and not on which slice it was.
Step '6b. Cancel the FIRST slice (the one carrying VarianceQty) → IsClosed clears too'
Cleanup; SeedAnchorPo 400
$res6b = Receive $sv $pi 401 $true 'Vendor over-delivered by 1; accepted at gate.'
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
if ($p6b[0] -ne '0') { Fail "IsClosed should have cleared when the first slice was reversed, got $($p6b[0])" }
if ($p6b[1] -ne '1') { Fail "window should be 1 after reversing the 400 slice, got $($p6b[1])" }
OK "reversing the VarianceQty-carrying slice cleared IsClosed and left the window at 1"

# ---------------------------------------------------------------------------
# 6c — the state 6b LEAVES BEHIND, asserted field by field rather than inferred
# from the fact that 6b did not throw.
#
# 6b cancels the 400-row and leaves the 1-pc overflow row live. That is a partial
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
if ($lv[1] -ne '0')     { Fail "SUM(VarianceQty) over live rows should be 0 — the variance carrier was reversed — got $($lv[1])" }
# The surviving overflow row KEEPS VarianceAccepted=1. That flag is provenance of the
# confirm that wrote the row, not a claim about the window's current state, and §8b
# depends on every slice carrying it: were it cleared here, a later cancel of this row
# would no longer reopen the window.
if ($lv[2] -ne '1')     { Fail "the surviving overflow row should still carry VarianceAccepted=1, got $($lv[2]) row(s)" }
OK "window reconciles with live receipts (1 = 1); variance carrier gone; surviving row keeps its flag"

$rev = Sql @"
SET NOCOUNT ON;
SELECT CAST(rv.QtyReceived AS VARCHAR)+'|'+CAST(rv.VarianceAccepted AS VARCHAR)+'|'
     + CASE WHEN rv.PurchaseOrderLineId = orig.PurchaseOrderLineId THEN 'same' ELSE 'DIFFERENT' END
FROM dbo.Receipts rv
INNER JOIN dbo.Receipts orig ON orig.Id = rv.ReversesReceiptId
WHERE rv.ReversesReceiptId = '$($first.receiptId)';
"@
$rp = ($rev | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
if ($rp[0] -ne '-400') { Fail "reversal row should carry -400, got $($rp[0])" }
# §7.3 — the reversal goes back to the line the original consumed, never via FIFO.
if ($rp[2] -ne 'same') { Fail "reversal landed on a different PO line than the original" }
# The reversal is not itself a variance act; stamping it would double-count the flag.
if ($rp[1] -ne '0')    { Fail "reversal row should carry VarianceAccepted=0, got $($rp[1])" }
OK "reversal row: -400, VarianceAccepted=0, same PO line as the original"

$po = Sql @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR)+'|'+po.Status
FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = '$SEED_PO';
"@
$pp = ($po | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
if ($pp[0] -ne '0')    { Fail "pull PO line should be back to 0 received, got $($pp[0])" }
# Step 7 auto-reopen: the 400-receive filled and closed this PO; giving the quantity
# back has to make it a FIFO candidate again or the next receive cannot reach it.
if ($pp[1] -ne 'open') { Fail "pull PO auto-closed at 400/400 should have reopened on cancel, got '$($pp[1])'" }
OK "pull PO line restored to 0/400 and the auto-closed PO reopened"

# The forward path is the real test of "not stranded": with 1 of 400 received the
# window has 399 outstanding, and that remainder must allocate on the NARROW path —
# the pull's own PO has its capacity back, so no overflow should be needed or used.
$pv = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$pi&qty=399&hour=$HOUR&varianceAccepted=false" -WebSession $sv
if ($pv.scope -ne 'pull-locked')            { Fail "forward preview should be plain pull-locked, got '$($pv.scope)'" }
if ($pv.allocations.Count -ne 1)            { Fail "forward preview should need 1 slice, got $($pv.allocations.Count)" }
if ($pv.allocations[0].qty -ne 399)         { Fail "forward preview should allocate 399, got $($pv.allocations[0].qty)" }
if ($pv.allocations[0].poNumber -ne $SEED_PO) { Fail "forward preview should sit on the pull's own PO, got $($pv.allocations[0].poNumber)" }
if ($pv.allocations[0].isPullLinked -ne $true) { Fail "forward preview slice should be pull-linked" }
OK "forward path intact: 399 previews as one pull-linked slice on $SEED_PO, no overflow"

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
if ($res3.allocations[0].isPullLinked -ne $true) { Fail "the single slice should be pull-linked" }
$audit3 = SqlScalar @"
SET NOCOUNT ON;
SELECT TOP 1 Message FROM dbo.AuditLog
WHERE EntityId = 'pi=$pi' AND ActionType = 'receive' ORDER BY OccurredAt DESC;
"@
if ($audit3 -match 'variance overflow') { Fail "no slice left the pull's PO — label must NOT say overflow. Got: $audit3" }
if ($audit3 -notmatch 'Scope: pull-locked') { Fail "expected 'Scope: pull-locked'. Got: $audit3" }
OK "headroom case stayed on one PO and kept the plain pull-locked label"

# ---------------------------------------------------------------------------
Step '4. Overflow never crosses vendors'
Cleanup; SeedAnchorPo 400; SeedOtherVendorPo
# 999,999 pcs sit on an OLDER PO under a different vendor. If the vendor anchor
# were dropped, FIFO would reach it first and this receive would succeed.
$fail4 = ReceiveExpectFail $sv $pi 100000 $true 'Should not reach the other vendor.' 409
if (-not $fail4 -or $fail4.Wrong) { Fail "expected 409, got $($fail4.Status) / $($fail4.Title)" }
$otherTouched = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR) FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId WHERE po.PoNumber = '$OTHER_PO';
"@
if ($otherTouched -ne '0') { Fail "the other vendor's line was consumed ($otherTouched) — overflow crossed vendors" }
OK "other vendor's 999,999-pc line untouched; receive refused: $($fail4.Title)"

# ---------------------------------------------------------------------------
Step '7. Normal in-range receive, unticked → narrow path unchanged'
Cleanup; SeedAnchorPo 400
$res7 = Receive $sv $pi 250 $false 'Ordinary partial.'
if ($res7.allocations.Count -ne 1) { Fail "expected 1 slice, got $($res7.allocations.Count)" }
if ($res7.allocations[0].poNumber -ne $SEED_PO) { Fail "partial should sit on the pull's own PO" }
if ($res7.allocations[0].isPullLinked -ne $true) { Fail "partial slice should be pull-linked" }
$audit7 = SqlScalar @"
SET NOCOUNT ON;
SELECT TOP 1 Message FROM dbo.AuditLog
WHERE EntityId = 'pi=$pi' AND ActionType = 'receive' ORDER BY OccurredAt DESC;
"@
if ($audit7 -match 'variance overflow') { Fail "in-range receive must not be labelled overflow. Got: $audit7" }
$closed7 = SqlScalar "SET NOCOUNT ON; SELECT CAST(IsClosed AS VARCHAR) FROM dbo.PullItemWindows WHERE PullItemId='$pi' AND HourOfDay=$HOUR;"
if ($closed7 -ne '0') { Fail "an unticked partial must leave the line open, got IsClosed=$closed7" }
OK "in-range partial: one pull-linked slice, plain label, line left open"

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
# it routine on the variance path. Reviewed and accepted as-is (2026-08-07); the
# brief's §3.5 "stop and report" was discharged by reporting rather than by a fix.
#
# What that leaves is a reachable half-reversed state, so it is asserted rather than
# assumed: case 6 (cancel the non-carrier), 6b (cancel the carrier), and 6c (the
# resulting state reconciles and the operator still has a forward path). If cancel
# ever becomes confirm-scoped, 6c is the test that should fail first and loudest.
