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
#   8-13. NEW       The step-8c VarianceQty recompute. See the block above case 8 for
#                   the invariant; 8 clears to NULL at exactly zero, 9 and 12 and 13
#                   restate a negative, 10 restates a positive, 11 proves 8c is inert
#                   where no variance was ever accepted.
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
# Step 8c moved the figure onto the surviving ticked row rather than letting it die with
# the slice that happened to carry it: 1 received of 400 expected is -399. This assertion
# read '0' before 8c existed, which was the orphaned state the recompute now prevents.
if ($lv[1] -ne '-399')  { Fail "SUM(VarianceQty) over live rows should be -399 (live 1 - expected 400), got $($lv[1])" }
# The surviving overflow row KEEPS VarianceAccepted=1. That flag is provenance of the
# confirm that wrote the row, not a claim about the window's current state, and §8b
# depends on every slice carrying it: were it cleared here, a later cancel of this row
# would no longer reopen the window. It is also what makes the row eligible to carry the
# recomputed figure above.
if ($lv[2] -ne '1')     { Fail "the surviving overflow row should still carry VarianceAccepted=1, got $($lv[2]) row(s)" }
OK "window reconciles with live receipts (1 = 1); figure restated to -399 on the surviving ticked row"

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
Step '8. 401 ticked -> cancel the OVERFLOW slice only -> variance figure clears'
Cleanup; SeedAnchorPo 400
$r8 = Receive $sv $pi 401 $true 'Vendor over-delivered by 1; accepted at gate.'
$s8over = $r8.allocations | Where-Object { $_.isPullLinked -eq $false }
if (-not $s8over) { Fail "expected an overflow slice in the 401 allocation" }
$pre8 = AssertInvariant $pi '8 (before cancel)'
if ($pre8.Delta -ne 1) { Fail "precondition: window should be over by 1, got $($pre8.Delta)" }

CancelSlice $sv $s8over.receiptId 'smoke: reverse overflow slice'
$a8 = AssertInvariant $pi '8'
if ($a8.Win.Received -ne 400 -or $a8.Win.Expected -ne 400) { Fail "window should be 400/400, got $($a8.Win.Received)/$($a8.Win.Expected)" }
if ($a8.Win.IsClosed) { Fail "IsClosed should have cleared, got 1" }
if ($a8.Live.VarSum -ne 'NULL') { Fail "SUM(VarianceQty) should be NULL at exactly 400/400, got $($a8.Live.VarSum)" }
OK "window 400/400, IsClosed=0, SUM(VarianceQty)=NULL — the +1 did not survive the slice that carried it"
ReportPullStatus $pi '8'

# ---------------------------------------------------------------------------
Step '9. 401 ticked -> cancel the PULL-LINKED slice only -> figure restated to -399 on an OPEN window'
Cleanup; SeedAnchorPo 400
$r9 = Receive $sv $pi 401 $true 'Vendor over-delivered by 1; accepted at gate.'
$s9linked = $r9.allocations | Where-Object { $_.isPullLinked -eq $true }
CancelSlice $sv $s9linked.receiptId 'smoke: reverse pull-linked slice'

$a9 = AssertInvariant $pi '9'
if ($a9.Live.Qty -ne 1)   { Fail "live SUM(qty) should be 1, got $($a9.Live.Qty)" }
if ($a9.Win.IsClosed)     { Fail "IsClosed should have cleared, got 1" }
# Signed rule: the surviving row carried the operator's tick, so it carries the window's
# current difference — 1 - 400 = -399. The figure tracks the quantities, not whether the
# window happens to be closed right now; IsClosed is asserted separately, just above.
if ($a9.Live.VarSum -ne '-399') { Fail "surviving ticked row should carry -399, got $($a9.Live.VarSum)" }
if ($a9.Live.VarRows -ne 1)     { Fail "expected exactly 1 row carrying the figure, got $($a9.Live.VarRows)" }
OK "live 1 pc of 400, IsClosed=0, VarianceQty restated to -399 on the surviving ticked row"

# ---------------------------------------------------------------------------
Step '10. 1,200 ticked across three slices -> cancel the MIDDLE slice -> invariant holds'
Cleanup; SeedAnchorPo 400
$r10 = Receive $sv $pi 1200 $true 'Three-way spill; over by 800.'
if ($r10.allocations.Count -ne 3) { Fail "expected 3 slices for 1,200 (400 anchor + 2 pool lines), got $($r10.allocations.Count)" }
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
