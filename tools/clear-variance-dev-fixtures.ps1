# Clears the dev fixtures created while building db/047, and RESTORES the
# purchase-order capacity their receipts consumed.
#
# WHY THE RESTORE STEP EXISTS
# ---------------------------
# PurchaseOrderLines.ReceivedQty is a denormalised cache the receive path
# increments. Deleting a receipt row does NOT decrement it, so a naive
# "DELETE FROM Receipts / DELETE FROM Pulls" cleanup leaks capacity: the PO
# lines stay marked as consumed forever and the shared SUMMARY pool shrinks a
# little on every run until smokes start failing for reasons unrelated to the
# code under test. That is the drain documented in db/047_STATUS.md.
#
# This script therefore computes, per PO line, exactly how much the fixture
# receipts consumed, deletes them, and decrements the cache by that amount —
# then asserts the cache equals SUM(surviving receipts) for every line it
# touched, which is the same invariant db/012 and db/038 enforce.
#
# DEV ONLY. Refuses to run against anything but a local server.
#
#   pwsh -File tools\clear-variance-dev-fixtures.ps1
#   pwsh -File tools\clear-variance-dev-fixtures.ps1 -WhatIf    # report only

[CmdletBinding()]
param(
    [string] $Server   = 'LAPTOP-CSB3KO3E',
    [string] $Database = 'ReceivingOps',
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
if ($Server -notmatch '^(LAPTOP-|localhost|\.|\(local\))') {
    throw "Refusing to delete fixture data on '$Server'. This script is dev-only."
}

# Every namespace this change created. The smoke suites clean up after
# themselves on a clean run, but an aborted run leaves its pulls behind, so
# their prefixes are swept here too.
$pullLike = @('PL-VAR-%','PL-UIDEMO-%','PL-CLAMPFIX-%','PL-S8-%','PL-VQ-%','PL-PCA-%','PL-ROP-%','PL-SHC-%')
$poLike   = @('PO-VAR-%','PO-UIDEMO-%','PO-S8-%','PO-VQ-%','PO-PCA-%','PO-ROP-%')

$pullPred = ($pullLike | ForEach-Object { "p.PullNumber LIKE '$_'" }) -join ' OR '
$poPred   = ($poLike   | ForEach-Object { "po.PoNumber LIKE '$_'" })   -join ' OR '

function Sql($q) { sqlcmd -S $Server -E -C -d $Database -I -h -1 -W -b -Q "SET NOCOUNT ON; $q" 2>&1 }

$capacitySql = @"
SELECT ISNULL(SUM(pol.OrderedQty - pol.ReceivedQty),0)
FROM dbo.PurchaseOrderLines pol
JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.WarehouseId='22222222-2222-2222-2222-000000000001'
  AND pol.ItemCode='SUMMARY' AND po.Status='open';
"@

$before = [int](Sql $capacitySql).Trim()
Write-Host "SUMMARY open capacity in WH-01 BEFORE : $before"

$counts = (Sql @"
SELECT CONCAT(
  (SELECT COUNT(*) FROM dbo.Pulls p WHERE $pullPred), '|',
  (SELECT COUNT(*) FROM dbo.Receipts r
     JOIN dbo.PullItems pi ON pi.Id=r.PullItemId
     JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE $pullPred), '|',
  (SELECT ISNULL(SUM(r.QtyReceived),0) FROM dbo.Receipts r
     JOIN dbo.PullItems pi ON pi.Id=r.PullItemId
     JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE $pullPred), '|',
  (SELECT COUNT(*) FROM dbo.PurchaseOrders po WHERE $poPred));
"@).Trim() -split '\|'
Write-Host "Fixtures found: $($counts[0]) pulls, $($counts[1]) receipts totalling $($counts[2]) pcs, $($counts[3]) POs"

if ($WhatIf) { Write-Host "-WhatIf: nothing deleted." -ForegroundColor Yellow; exit 0 }

$cleanup = @"
SET XACT_ABORT ON;
BEGIN TRAN;

-- 1. Capture what the fixture receipts consumed, per surviving PO line, BEFORE
--    deleting them. Reversal rows carry negative qty and net out naturally.
SELECT r.PurchaseOrderLineId AS LineId, SUM(r.QtyReceived) AS Consumed
INTO   #Restore
FROM   dbo.Receipts r
JOIN   dbo.PullItems pi ON pi.Id = r.PullItemId
JOIN   dbo.Pulls p ON p.Id = pi.PullId
WHERE  $pullPred
GROUP BY r.PurchaseOrderLineId;

-- 2. Delete the fixture receipts, then the pulls (items + windows cascade).
DELETE r FROM dbo.Receipts r
JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE $pullPred;

-- 2b. Dependents that do NOT cascade with Pulls and will otherwise block the
--     delete. PullSignatures (FK_PullSig_Pull) exists for any fixture pull that
--     was closed — §8.16 closes and signs one. PurchaseOrders.PullId
--     (FK_PO_Pull) is nulled rather than deleted so a non-fixture PO that
--     happened to be linked survives; PO.PullId is immutable through the API,
--     but this is dev teardown, not the application path.
DELETE ps FROM dbo.PullSignatures ps
JOIN dbo.Pulls p ON p.Id = ps.PullId
WHERE $pullPred;

UPDATE po SET po.PullId = NULL
FROM dbo.PurchaseOrders po
JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE $pullPred;

DELETE p FROM dbo.Pulls p WHERE $pullPred;

-- 3. Give the capacity back. Only lines that still exist — a line belonging to
--    a fixture PO is about to be deleted outright and needs no restoration.
UPDATE pol
   SET pol.ReceivedQty = pol.ReceivedQty - x.Consumed
FROM dbo.PurchaseOrderLines pol
JOIN #Restore x ON x.LineId = pol.Id;

-- 4. Drop the fixture POs themselves.
DELETE pol FROM dbo.PurchaseOrderLines pol
JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE $poPred;
DELETE po FROM dbo.PurchaseOrders po WHERE $poPred;

-- 5. A PO that auto-closed when it filled up has headroom again now.
UPDATE po SET Status = 'open', ClosedAt = NULL
FROM dbo.PurchaseOrders po
WHERE po.Status = 'closed'
  AND EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol
              WHERE pol.PurchaseOrderId = po.Id AND pol.OrderedQty > pol.ReceivedQty)
  AND EXISTS (SELECT 1 FROM #Restore x
              JOIN dbo.PurchaseOrderLines pol2 ON pol2.Id = x.LineId
              WHERE pol2.PurchaseOrderId = po.Id);

-- 6. Reconcile the fixture CAPACITY lines to the ledger.
--
--    Restoring only what this run's receipts consumed is not enough. Earlier
--    smoke runs deleted their receipts without decrementing this cache, so the
--    fixture lines already overstate consumption — that is the drain, and it is
--    why the pool shrinks a little every time the suite runs. Because these are
--    fixture-capacity lines (PO-SEED-SUMMARY-*), set-from-truth is safe and is
--    the same technique db/038 used: the cache is reproducible from
--    SUM(Receipts.QtyReceived) by definition.
--
--    Scoped deliberately to the seeded fixture POs. Real POs are left alone —
--    their drift, if any, is a separate question and not this script's to touch.
SELECT pol.Id AS LineId,
       pol.ReceivedQty AS CacheBefore,
       ISNULL((SELECT SUM(r2.QtyReceived) FROM dbo.Receipts r2
               WHERE r2.PurchaseOrderLineId = pol.Id), 0) AS LedgerQty
INTO   #Reconcile
FROM   dbo.PurchaseOrderLines pol
JOIN   dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE  po.PoNumber LIKE 'PO-SEED-SUMMARY-%';

DECLARE @reclaimed int = (SELECT ISNULL(SUM(CacheBefore - LedgerQty),0) FROM #Reconcile);

UPDATE pol SET pol.ReceivedQty = x.LedgerQty
FROM   dbo.PurchaseOrderLines pol
JOIN   #Reconcile x ON x.LineId = pol.Id
WHERE  pol.ReceivedQty <> x.LedgerQty;

-- A reconciled PO may have been auto-closed while its cache said 'full'.
UPDATE po SET Status = 'open', ClosedAt = NULL
FROM dbo.PurchaseOrders po
WHERE po.Status = 'closed'
  AND EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol
              JOIN #Reconcile x ON x.LineId = pol.Id
              WHERE pol.PurchaseOrderId = po.Id AND pol.OrderedQty > pol.ReceivedQty);

PRINT CONCAT('Reclaimed from pre-existing cache drift on fixture capacity lines: ', @reclaimed, ' pcs.');

-- 7. Invariants, same shape db/012 §2.4 and db/038 assert.
DECLARE @neg int = (SELECT COUNT(*) FROM dbo.PurchaseOrderLines WHERE ReceivedQty < 0);
IF @neg > 0 THROW 51000, 'Cleanup FAILED: a PurchaseOrderLines.ReceivedQty went negative.', 1;

DECLARE @drift int = (
    SELECT COUNT(*) FROM dbo.PurchaseOrderLines pol
    JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
    WHERE po.PoNumber LIKE 'PO-SEED-SUMMARY-%'
      AND pol.ReceivedQty <> ISNULL((SELECT SUM(r2.QtyReceived) FROM dbo.Receipts r2
                                     WHERE r2.PurchaseOrderLineId = pol.Id), 0));
IF @drift > 0 THROW 51000, 'Cleanup FAILED: a fixture capacity line still disagrees with the ledger.', 1;

DROP TABLE #Restore;
DROP TABLE #Reconcile;
COMMIT;
PRINT 'Fixture cleanup committed; capacity restored and invariants hold.';
"@

Sql $cleanup
if ($LASTEXITCODE -ne 0) { throw "Cleanup failed (sqlcmd exit $LASTEXITCODE)." }

$after = [int](Sql $capacitySql).Trim()
Write-Host "SUMMARY open capacity in WH-01 AFTER  : $after"
Write-Host "Capacity returned to the pool         : $($after - $before)" -ForegroundColor Green

$left = (Sql "SELECT CONCAT((SELECT COUNT(*) FROM dbo.Pulls p WHERE $pullPred),'|',(SELECT COUNT(*) FROM dbo.PurchaseOrders po WHERE $poPred));").Trim() -split '\|'
Write-Host "Residual fixtures: $($left[0]) pulls, $($left[1]) POs"
if ($left[0] -ne '0' -or $left[1] -ne '0') { throw "Fixtures remain after cleanup." }
exit 0
