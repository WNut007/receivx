/* ============================================================================
   ReceivingOps — 012_backfill_receipts.sql  (Phase 2 of v2 migration)
   ----------------------------------------------------------------------------
   Backfill PurchaseOrderId / PurchaseOrderLineId on every existing Receipts
   row WITHOUT touching QtyReceived or any other column. Receipts table stays
   append-only (no DELETE except smoke residue, no UPDATE except the two new
   PO columns).

   Order of operations (one transaction):

     2.0  Cleanup smoke residue (receipts against ItemCode='SUMMARY').
          The original seed (006) never created SUMMARY receipts — they are
          smoke-test leftovers. Removing them keeps the backfill targets to
          the 18 planned PL-2847 rows.

     2.0a Feasibility check (fail fast, before walking):
          - gross qty per (warehouse, itemCode) ≤ total open PO capacity
          - max single positive qty ≤ largest open PO line capacity
          If either fails → RAISERROR + rollback. No partial state.

     2.1  Cursor walk every positive receipt in (ReceivedAt, Id) order.
          Assign each to the oldest open PO line for its (warehouse, itemCode)
          where remaining qty ≥ this receipt's qty. NO SPLITTING during
          backfill — each historical receipt becomes exactly one (PO, line).

     2.2  Attach reversals to their original's (PO, line). One UPDATE … FROM.

     2.3  Apply reversal qty to PO line cache (subtract).

     2.4  Verify invariants:
            a) zero receipts with NULL PO columns
            b) every PurchaseOrderLines.ReceivedQty in [0, OrderedQty]
            c) cache == SUM(Receipts.QtyReceived) per PO line

   Behavior note (v2 §4.5a): after this backfill, every historical receipt
   sits on the *oldest* open PO line for its item. Multi-PO FIFO splitting
   only becomes visible on receives placed AFTER the v2 cutover. That is
   natural — not a bug — because no historical receipt exceeded a single
   line's capacity in this seed.

   Re-running this script after a successful first run is a no-op:
     2.0  finds no SUMMARY receipts
     2.0a passes trivially
     2.1  walks 0 receipts (filtered to PurchaseOrderId IS NULL)
     2.2  updates 0 reversals
     2.3  updates 0 lines (no new reversals)
     2.4  passes
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

BEGIN TRANSACTION;
SET XACT_ABORT ON;

DECLARE @msg NVARCHAR(400);

----------------------------------------------------------------------------
-- 2.0  Cleanup smoke residue
----------------------------------------------------------------------------
DECLARE @smokeCount INT;
SELECT @smokeCount = COUNT(*)
FROM   dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
WHERE  pi.ItemCode = 'SUMMARY';

PRINT CONCAT('2.0  Smoke residue (ItemCode=''SUMMARY''): ', @smokeCount, ' receipt row(s) to delete');

IF @smokeCount > 0
BEGIN
    DELETE r
    FROM   dbo.Receipts r
    INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
    WHERE  pi.ItemCode = 'SUMMARY';
END

----------------------------------------------------------------------------
-- 2.0a Feasibility check — abort BEFORE the walk if any item lacks capacity
----------------------------------------------------------------------------
PRINT '2.0a Feasibility check';

;WITH gross AS (
    SELECT  p.WarehouseId, pi.ItemCode,
            SUM(r.QtyReceived) AS GrossQty,
            MAX(r.QtyReceived) AS MaxSingle
    FROM    dbo.Receipts r
    INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
    INNER JOIN dbo.Pulls      p ON p.Id  = pi.PullId
    WHERE   r.QtyReceived > 0
      AND   r.PurchaseOrderId IS NULL
    GROUP BY p.WarehouseId, pi.ItemCode
),
avail AS (
    SELECT  po.WarehouseId, pol.ItemCode,
            SUM(pol.OrderedQty - pol.ReceivedQty) AS TotalAvail,
            MAX(pol.OrderedQty - pol.ReceivedQty) AS MaxLineAvail
    FROM    dbo.PurchaseOrderLines pol
    INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
    WHERE   po.Status = 'open'
      AND   pol.OrderedQty > pol.ReceivedQty
    GROUP BY po.WarehouseId, pol.ItemCode
),
defect AS (
    SELECT  g.WarehouseId, g.ItemCode, g.GrossQty, g.MaxSingle,
            ISNULL(a.TotalAvail, 0)   AS TotalAvail,
            ISNULL(a.MaxLineAvail, 0) AS MaxLineAvail
    FROM    gross g
    LEFT JOIN avail a ON a.WarehouseId = g.WarehouseId AND a.ItemCode = g.ItemCode
)
SELECT @msg = STRING_AGG(
    CONVERT(NVARCHAR(MAX),
            CONCAT('warehouse ', WarehouseId,
                   ' item ', ItemCode,
                   ' gross=', GrossQty, ' max-single=', MaxSingle,
                   ' avail=', TotalAvail, ' largest-line=', MaxLineAvail)),
    ' | ')
FROM   defect
WHERE  TotalAvail   < GrossQty
   OR  MaxLineAvail < MaxSingle;

IF @msg IS NOT NULL
BEGIN
    SET @msg = LEFT(N'Feasibility check FAILED: ' + @msg, 400);
    ROLLBACK;
    THROW 50001, @msg, 1;
END

PRINT '2.0a  OK — every (warehouse, itemCode) has enough capacity and a line that fits the largest single receipt';

----------------------------------------------------------------------------
-- 2.1  Cursor walk: assign each positive receipt to oldest open PO line
--       with sufficient remaining capacity. No splitting.
----------------------------------------------------------------------------
PRINT '2.1  Walking positive receipts in chronological order';

DECLARE @ReceiptId UNIQUEIDENTIFIER, @ItemCode VARCHAR(64),
        @WarehouseId UNIQUEIDENTIFIER, @Qty INT,
        @PoLineId UNIQUEIDENTIFIER, @PoId UNIQUEIDENTIFIER,
        @WalkedCount INT = 0;

DECLARE walk CURSOR LOCAL FAST_FORWARD FOR
    SELECT  r.Id, pi.ItemCode, p.WarehouseId, r.QtyReceived
    FROM    dbo.Receipts r
    INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
    INNER JOIN dbo.Pulls      p ON p.Id  = pi.PullId
    WHERE   r.QtyReceived > 0
      AND   r.PurchaseOrderId IS NULL
    ORDER BY r.ReceivedAt, r.Id;

OPEN walk;
FETCH NEXT FROM walk INTO @ReceiptId, @ItemCode, @WarehouseId, @Qty;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @PoLineId = NULL; SET @PoId = NULL;

    SELECT TOP 1
           @PoLineId = pol.Id,
           @PoId     = pol.PurchaseOrderId
    FROM   dbo.PurchaseOrderLines pol
    INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
    WHERE  po.WarehouseId = @WarehouseId
      AND  po.Status      = 'open'
      AND  pol.ItemCode   = @ItemCode
      AND  (pol.OrderedQty - pol.ReceivedQty) >= @Qty
    ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;

    IF @PoLineId IS NULL
    BEGIN
        SET @msg = CONCAT(N'Walk failed at receipt ', CONVERT(NVARCHAR(40), @ReceiptId),
                          N' (', @ItemCode, N', qty=', @Qty,
                          N', warehouse=', CONVERT(NVARCHAR(40), @WarehouseId),
                          N'). No open PO line with remaining >= qty. Feasibility check should have caught this — this is a bug.');
        CLOSE walk; DEALLOCATE walk;
        ROLLBACK;
        THROW 50002, @msg, 1;
    END

    UPDATE dbo.Receipts
       SET PurchaseOrderId     = @PoId,
           PurchaseOrderLineId = @PoLineId
     WHERE Id = @ReceiptId;

    UPDATE dbo.PurchaseOrderLines
       SET ReceivedQty = ReceivedQty + @Qty
     WHERE Id = @PoLineId;

    SET @WalkedCount += 1;
    FETCH NEXT FROM walk INTO @ReceiptId, @ItemCode, @WarehouseId, @Qty;
END
CLOSE walk; DEALLOCATE walk;

PRINT CONCAT('2.1  Walked + assigned ', @WalkedCount, ' positive receipt(s)');

----------------------------------------------------------------------------
-- 2.2  Attach reversals to their original's PO line
----------------------------------------------------------------------------
DECLARE @reversalAttached INT;

UPDATE rev
   SET PurchaseOrderId     = orig.PurchaseOrderId,
       PurchaseOrderLineId = orig.PurchaseOrderLineId
FROM   dbo.Receipts rev
INNER JOIN dbo.Receipts orig ON orig.Id = rev.ReversesReceiptId
WHERE  rev.PurchaseOrderId IS NULL
  AND  rev.ReversesReceiptId IS NOT NULL;

SET @reversalAttached = @@ROWCOUNT;
PRINT CONCAT('2.2  Attached ', @reversalAttached, ' reversal(s) to their original''s PO line');

----------------------------------------------------------------------------
-- 2.3  Reconcile PO line cache from truth (idempotent).
-- This recomputes ReceivedQty = SUM(Receipts.QtyReceived) per line, including
-- both positives and reversals. Doing it as "set from truth" rather than
-- "+= reversal sum" means re-running this script doesn't double-subtract.
-- Skips PO-2312-091 L1 (pre-seeded historical closed; has no Receipts but
-- ReceivedQty=1000 by design).
----------------------------------------------------------------------------
;WITH truth AS (
    SELECT  PurchaseOrderLineId,
            SUM(QtyReceived) AS Net
    FROM    dbo.Receipts
    WHERE   PurchaseOrderLineId IS NOT NULL
    GROUP BY PurchaseOrderLineId
)
UPDATE pol
   SET ReceivedQty = ISNULL(t.Net, 0)
FROM   dbo.PurchaseOrderLines pol
LEFT JOIN truth t ON t.PurchaseOrderLineId = pol.Id
WHERE  pol.Id <> '77777777-7777-7777-7777-010100000001'   -- historical closed PO-2312-091 L1
  AND  pol.ReceivedQty <> ISNULL(t.Net, 0);

DECLARE @cacheUpdated INT = @@ROWCOUNT;
PRINT CONCAT('2.3  Reconciled ', @cacheUpdated, ' PO line cache(s) to match Receipts truth');

----------------------------------------------------------------------------
-- 2.4  Verify invariants
----------------------------------------------------------------------------
DECLARE @orphan INT, @outOfRange INT, @mismatch INT;

-- (a) no orphan receipts
SELECT @orphan = COUNT(*) FROM dbo.Receipts WHERE PurchaseOrderId IS NULL OR PurchaseOrderLineId IS NULL;
IF @orphan > 0
BEGIN
    SET @msg = CONCAT(N'Invariant (a) FAILED: ', @orphan, N' receipt row(s) still have NULL PO columns.');
    ROLLBACK; THROW 50003, @msg, 1;
END

-- (b) cache in [0, OrderedQty]
SELECT @outOfRange = COUNT(*)
FROM   dbo.PurchaseOrderLines
WHERE  ReceivedQty < 0 OR ReceivedQty > OrderedQty;
IF @outOfRange > 0
BEGIN
    SET @msg = CONCAT(N'Invariant (b) FAILED: ', @outOfRange, N' PO line(s) have ReceivedQty outside [0, OrderedQty].');
    ROLLBACK; THROW 50004, @msg, 1;
END

-- (c) cache == SUM(QtyReceived) per line
;WITH actual AS (
    SELECT PurchaseOrderLineId, SUM(QtyReceived) AS Net
    FROM   dbo.Receipts
    WHERE  PurchaseOrderLineId IS NOT NULL
    GROUP BY PurchaseOrderLineId
)
SELECT @mismatch = COUNT(*)
FROM   dbo.PurchaseOrderLines pol
LEFT JOIN actual a ON a.PurchaseOrderLineId = pol.Id
WHERE  pol.ReceivedQty <> ISNULL(a.Net, 0)
   AND pol.Id <> '77777777-7777-7777-7777-010100000001';   -- PO-2312-091 L1 is pre-seeded as 1000/1000 (historical closed; never touched by Receipts)

IF @mismatch > 0
BEGIN
    SET @msg = CONCAT(N'Invariant (c) FAILED: ', @mismatch, N' PO line(s) have ReceivedQty != SUM(Receipts.QtyReceived).');
    ROLLBACK; THROW 50005, @msg, 1;
END

PRINT '2.4  Invariants OK — backfill complete, ready for Phase 1b';
COMMIT;
PRINT '012_backfill_receipts.sql complete.';
GO
