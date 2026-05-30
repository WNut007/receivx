/* ============================================================================
   ReceivingOps — 038_phase_14_receipt_backfill.sql  (v3.4.1 — seed gap closure)
   ----------------------------------------------------------------------------
   Restore the historical PL-2847 Receipts that db/006 §5 used to seed but
   can no longer create against the v2 strict schema.

   Why this exists:
     db/006 §5 inserts ~19 receipts without PurchaseOrderLineId. That worked
     under v1 (column was nullable). db/011 (Phase 1b) tightened
     Receipts.PurchaseOrderLineId to NOT NULL, and db/012 supplied the
     missing column via a chronological FIFO walk. After db/035 (Phase 14
     destructive wipe) the historical receipts are gone and db/006's
     INSERTs would fail against the strict column. This migration is the
     Phase-14-era equivalent of db/006 §5 + db/012: resolve PoLineId
     up-front via the same FIFO logic db/012 used, then INSERT.

   Data shape (identical to db/006 §5):
     17 positive receipts + 2 reversal pairs (r1005↔r1007 QC-fail,
     r2002↔r2003 miscount + r2004 correction = 19 rows total). Every
     receipt sits on PL-2847's PullItems (4444-4444-4444-2847-...) and
     lands on PO-2401-018 (the oldest open WH-01 PO carrying each item).

   Per-item PoLine resolution (deterministic FIFO ORDER BY db/007 dates):
     PCBA-AX450-R2 → PO-2401-018 L1 (capacity 5500; receipts net 2100)
     PCBA-AX451-R2 → PO-2401-018 L2 (capacity 2000; receipts net 1300)
     CAP-470UF-25V → PO-2401-018 L3 (capacity 7000; receipts net 3500)
     RES-10K-1%    → PO-2401-018 L4 (capacity 20000; receipts net 8200)
     CONN-USB-C-16 → PO-2401-018 L5 (capacity 500; receipts net 200)
     LCD-3.5-IPS   → PO-2401-018 L6 (capacity 100; receipts net 50)
     SHIELD-RF-A1  → PO-2401-018 L7 (capacity 500; receipts net 300)

   Idempotent via NOT EXISTS on the receipt GUIDs (55555-5555-5555-5555-...).
   The PoL.ReceivedQty + PIW.ReceivedQty cache recalcs at the end are
   set-from-truth, so a re-run produces no drift.

   Prerequisites: db/006 (pulls + items + windows) + db/007 (POs + lines)
   already applied. The script aborts cleanly if any PoLineId resolution
   returns NULL (missing seed PO).
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE [ReceivingOps];
GO

BEGIN TRANSACTION;

------------------------------------------------------------------------------
-- 1. Users + warehouse + PullItem GUIDs (must match db/006).
------------------------------------------------------------------------------
DECLARE @uSwattana   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000002';
DECLARE @uPsomchai   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000003';
DECLARE @uNpatcharin UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000004';
DECLARE @wBkk        UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000001';

DECLARE @i2847_1 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000001'; -- PCBA-AX450-R2
DECLARE @i2847_2 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000002'; -- PCBA-AX451-R2
DECLARE @i2847_3 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000003'; -- CAP-470UF-25V
DECLARE @i2847_4 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000004'; -- RES-10K-1%
DECLARE @i2847_6 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000006'; -- CONN-USB-C-16
DECLARE @i2847_7 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000007'; -- LCD-3.5-IPS
DECLARE @i2847_8 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000008'; -- SHIELD-RF-A1

------------------------------------------------------------------------------
-- 2. Resolve per-item PoLineId via FIFO. Same ORDER BY as db/012's walk:
--    (po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC). Every item
--    in PL-2847 has at least one matching line on a WH-01 open PO.
------------------------------------------------------------------------------
DECLARE @poPCBA_AX450   UNIQUEIDENTIFIER, @polPCBA_AX450   UNIQUEIDENTIFIER;
DECLARE @poPCBA_AX451   UNIQUEIDENTIFIER, @polPCBA_AX451   UNIQUEIDENTIFIER;
DECLARE @poCAP_470UF    UNIQUEIDENTIFIER, @polCAP_470UF    UNIQUEIDENTIFIER;
DECLARE @poRES_10K      UNIQUEIDENTIFIER, @polRES_10K      UNIQUEIDENTIFIER;
DECLARE @poCONN_USB_C   UNIQUEIDENTIFIER, @polCONN_USB_C   UNIQUEIDENTIFIER;
DECLARE @poLCD_35       UNIQUEIDENTIFIER, @polLCD_35       UNIQUEIDENTIFIER;
DECLARE @poSHIELD_RF    UNIQUEIDENTIFIER, @polSHIELD_RF    UNIQUEIDENTIFIER;

SELECT TOP 1 @poPCBA_AX450 = pol.PurchaseOrderId, @polPCBA_AX450 = pol.Id
FROM dbo.PurchaseOrderLines pol JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE pol.ItemCode = 'PCBA-AX450-R2' AND po.WarehouseId = @wBkk AND po.Status = 'open'
ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;

SELECT TOP 1 @poPCBA_AX451 = pol.PurchaseOrderId, @polPCBA_AX451 = pol.Id
FROM dbo.PurchaseOrderLines pol JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE pol.ItemCode = 'PCBA-AX451-R2' AND po.WarehouseId = @wBkk AND po.Status = 'open'
ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;

SELECT TOP 1 @poCAP_470UF = pol.PurchaseOrderId, @polCAP_470UF = pol.Id
FROM dbo.PurchaseOrderLines pol JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE pol.ItemCode = 'CAP-470UF-25V' AND po.WarehouseId = @wBkk AND po.Status = 'open'
ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;

SELECT TOP 1 @poRES_10K = pol.PurchaseOrderId, @polRES_10K = pol.Id
FROM dbo.PurchaseOrderLines pol JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE pol.ItemCode = 'RES-10K-1%' AND po.WarehouseId = @wBkk AND po.Status = 'open'
ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;

SELECT TOP 1 @poCONN_USB_C = pol.PurchaseOrderId, @polCONN_USB_C = pol.Id
FROM dbo.PurchaseOrderLines pol JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE pol.ItemCode = 'CONN-USB-C-16' AND po.WarehouseId = @wBkk AND po.Status = 'open'
ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;

SELECT TOP 1 @poLCD_35 = pol.PurchaseOrderId, @polLCD_35 = pol.Id
FROM dbo.PurchaseOrderLines pol JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE pol.ItemCode = 'LCD-3.5-IPS' AND po.WarehouseId = @wBkk AND po.Status = 'open'
ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;

SELECT TOP 1 @poSHIELD_RF = pol.PurchaseOrderId, @polSHIELD_RF = pol.Id
FROM dbo.PurchaseOrderLines pol JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE pol.ItemCode = 'SHIELD-RF-A1' AND po.WarehouseId = @wBkk AND po.Status = 'open'
ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;

------------------------------------------------------------------------------
-- 3. Abort cleanly if any resolution failed (missing seed).
------------------------------------------------------------------------------
IF @polPCBA_AX450 IS NULL OR @polPCBA_AX451 IS NULL OR @polCAP_470UF IS NULL
   OR @polRES_10K IS NULL OR @polCONN_USB_C IS NULL OR @polLCD_35 IS NULL
   OR @polSHIELD_RF IS NULL
BEGIN
    ROLLBACK;
    RAISERROR('db/038 abort: at least one PL-2847 item has no matching open WH-01 PO line. Did db/007 run?', 16, 1);
    RETURN;
END

------------------------------------------------------------------------------
-- 4. Receipts — same shape + qtys + GUIDs as db/006 §5, now with the
--    resolved PurchaseOrderId + PurchaseOrderLineId so the v2 strict
--    NOT NULL is satisfied at insert time.
------------------------------------------------------------------------------
DECLARE @r1001 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001001';
DECLARE @r1002 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001002';
DECLARE @r1003 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001003';
DECLARE @r1004 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001004';
DECLARE @r1005 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001005';
DECLARE @r1006 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001006';
DECLARE @r1007 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001007';
DECLARE @r1008 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001008';
DECLARE @r1009 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001009';
DECLARE @r1010 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001010';
DECLARE @r1011 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001011';
DECLARE @r1012 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001012';
DECLARE @r1013 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001013';
DECLARE @r1014 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001014';
DECLARE @r1015 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001015';
DECLARE @r2002 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000002002';
DECLARE @r2003 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000002003';
DECLARE @r2004 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000002004';

-- PCBA-AX450-R2 (Swattana) — 4 receipts, net 2100
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1001)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1001, @i2847_1, @poPCBA_AX450, @polPCBA_AX450, 7,  300,  'LOT-2401-018', 'PLT-00470', 'A-12-01', 'passed', @uSwattana, '2026-03-18T00:24:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1002)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1002, @i2847_1, @poPCBA_AX450, @polPCBA_AX450, 8,  300,  'LOT-2401-018', 'PLT-00471', 'A-12-01', 'passed', @uSwattana, '2026-03-18T01:24:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1003)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1003, @i2847_1, @poPCBA_AX450, @polPCBA_AX450, 12, 1000, 'LOT-2401-018', 'PLT-00472', 'A-12-02', 'passed', @uSwattana, '2026-03-18T05:30:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1004)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1004, @i2847_1, @poPCBA_AX450, @polPCBA_AX450, 14, 500,  'LOT-2401-019', 'PLT-00475', 'A-12-02', 'passed', @uSwattana, '2026-03-18T07:18:00');

-- PCBA-AX451-R2 — 2 receipts, net 1300
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1008)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1008, @i2847_2, @poPCBA_AX451, @polPCBA_AX451, 7,  300,  'LOT-2401-020', 'PLT-00476', 'A-13-01', 'passed', @uSwattana, '2026-03-18T00:35:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1009)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1009, @i2847_2, @poPCBA_AX451, @polPCBA_AX451, 12, 1000, 'LOT-2401-020', 'PLT-00477', 'A-13-01', 'passed', @uSwattana, '2026-03-18T05:40:00');

-- CAP-470UF-25V (Psomchai) — 2 receipts, net 3500
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1010)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1010, @i2847_3, @poCAP_470UF, @polCAP_470UF, 7,  1500, 'LOT-2403-044', 'PLT-00478', 'B-05-03', 'passed', @uPsomchai, '2026-03-18T00:45:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1011)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1011, @i2847_3, @poCAP_470UF, @polCAP_470UF, 11, 2000, 'LOT-2403-044', 'PLT-00479', 'B-05-03', 'passed', @uPsomchai, '2026-03-18T04:50:00');

-- RES-10K-1% — 7 receipts incl. 2 reversal pairs, net 8200
-- r1005 (positive 5000, QC-fail target)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1005)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, Note, ReceivedBy, ReceivedAt)
    VALUES (@r1005, @i2847_4, @poRES_10K, @polRES_10K, 7,  5000, 'LOT-2403-051', 'PLT-00480', 'C-02-01', 'rejected', N'Failed visual QC — surface defects', @uNpatcharin, '2026-03-18T00:55:00');

-- r1006 (positive 3000, legitimate)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1006)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1006, @i2847_4, @poRES_10K, @polRES_10K, 9,  3000, 'LOT-2403-052', 'PLT-00481', 'C-02-01', 'passed', @uNpatcharin, '2026-03-18T02:40:00');

-- r1007 (reversal of r1005, -5000) + bind ReversedById on the original
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1007)
BEGIN
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus,
                              Note, ReceivedBy, ReceivedAt, ReversesReceiptId, CancelReason)
    VALUES (@r1007, @i2847_4, @poRES_10K, @polRES_10K, 7, -5000, 'LOT-2403-051', 'PLT-00480', 'C-02-01', 'rejected',
            N'Reversed — entire lot failed final QC', @uNpatcharin, '2026-03-18T03:10:00', @r1005, 'qc-fail');
    UPDATE dbo.Receipts SET ReversedById = @r1007 WHERE Id = @r1005;
END;

-- r1013 (positive 5000)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1013)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1013, @i2847_4, @poRES_10K, @polRES_10K, 13, 5000, 'LOT-2403-053', 'PLT-00482', 'C-02-02', 'passed', @uNpatcharin, '2026-03-18T06:15:00');

-- r2002 (positive 2000, miscount target)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r2002)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r2002, @i2847_4, @poRES_10K, @polRES_10K, 11, 2000, 'LOT-2403-052', 'PLT-00483', 'C-02-02', 'passed', @uPsomchai, '2026-03-18T04:30:00');

-- r2003 (reversal of r2002, -2000) + bind ReversedById
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r2003)
BEGIN
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus,
                              Note, ReceivedBy, ReceivedAt, ReversesReceiptId, CancelReason)
    VALUES (@r2003, @i2847_4, @poRES_10K, @polRES_10K, 11, -2000, 'LOT-2403-052', 'PLT-00483', 'C-02-02', 'passed',
            N'Miscount — actual qty was 200 not 2000', @uPsomchai, '2026-03-18T04:45:00', @r2002, 'miscount');
    UPDATE dbo.Receipts SET ReversedById = @r2003 WHERE Id = @r2002;
END;

-- r2004 (correction 200)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r2004)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, Note, ReceivedBy, ReceivedAt)
    VALUES (@r2004, @i2847_4, @poRES_10K, @polRES_10K, 11, 200, 'LOT-2403-052', 'PLT-00483', 'C-02-02', 'passed', N'Corrected count after miscount', @uPsomchai, '2026-03-18T04:50:00');

-- CONN-USB-C-16 — 1 receipt, net 200
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1012)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1012, @i2847_6, @poCONN_USB_C, @polCONN_USB_C, 7, 200, 'LOT-2402-101', 'PLT-00484', 'D-08-01', 'passed', @uSwattana, '2026-03-18T01:00:00');

-- LCD-3.5-IPS — 1 receipt, net 50
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1014)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1014, @i2847_7, @poLCD_35, @polLCD_35, 7, 50, 'LOT-2404-001', 'PLT-00485', 'E-04-01', 'passed', @uSwattana, '2026-03-18T01:15:00');

-- SHIELD-RF-A1 — 1 receipt, net 300
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1015)
    INSERT INTO dbo.Receipts (Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1015, @i2847_8, @poSHIELD_RF, @polSHIELD_RF, 7, 300, 'LOT-2401-090', 'PLT-00486', 'F-03-01', 'passed', @uSwattana, '2026-03-18T01:30:00');

------------------------------------------------------------------------------
-- 5. Recalc PoL.ReceivedQty from receipts (set-from-truth = idempotent).
--    Same pattern as db/012 §2.3; skip the pre-seeded historical closed
--    line PO-2312-091 L1 (1000/1000 with no Receipts by design).
------------------------------------------------------------------------------
;WITH truth AS (
    SELECT PurchaseOrderLineId, SUM(QtyReceived) AS Net
    FROM   dbo.Receipts
    WHERE  PurchaseOrderLineId IS NOT NULL
    GROUP BY PurchaseOrderLineId
)
UPDATE pol
   SET ReceivedQty = ISNULL(t.Net, 0)
FROM   dbo.PurchaseOrderLines pol
LEFT JOIN truth t ON t.PurchaseOrderLineId = pol.Id
WHERE  pol.Id <> '77777777-7777-7777-7777-010100000001'   -- PO-2312-091 L1 (historical closed, no Receipts)
  AND  pol.ReceivedQty <> ISNULL(t.Net, 0);

PRINT CONCAT('PoL.ReceivedQty reconciled: ', @@ROWCOUNT, ' line(s) updated');

------------------------------------------------------------------------------
-- 6. Recalc PIW.ReceivedQty from receipts via vw_PullItemReceived (which is
--    the authoritative SUM grouped by (PullItemId, HourOfDay)). Mirrors
--    db/006 §6 — the cache must agree with the view at rest.
------------------------------------------------------------------------------
UPDATE w
SET    ReceivedQty = ISNULL(v.NetReceived, 0)
FROM   dbo.PullItemWindows w
LEFT JOIN dbo.vw_PullItemReceived v
       ON v.PullItemId = w.PullItemId AND v.HourOfDay = w.HourOfDay;

PRINT CONCAT('PIW.ReceivedQty reconciled: ', @@ROWCOUNT, ' window row(s) updated');

------------------------------------------------------------------------------
-- 7. Verify the same invariants db/012 §2.4 enforces.
------------------------------------------------------------------------------
DECLARE @orphan INT, @outOfRange INT, @mismatch INT;

SELECT @orphan = COUNT(*) FROM dbo.Receipts WHERE PurchaseOrderId IS NULL OR PurchaseOrderLineId IS NULL;
IF @orphan > 0
BEGIN
    ROLLBACK;
    RAISERROR('db/038 invariant (a) FAILED: %d receipt(s) have NULL PO columns.', 16, 1, @orphan);
    RETURN;
END

SELECT @outOfRange = COUNT(*)
FROM   dbo.PurchaseOrderLines
WHERE  ReceivedQty < 0 OR ReceivedQty > OrderedQty;
IF @outOfRange > 0
BEGIN
    ROLLBACK;
    RAISERROR('db/038 invariant (b) FAILED: %d PO line(s) have ReceivedQty outside [0, OrderedQty].', 16, 1, @outOfRange);
    RETURN;
END

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
   AND pol.Id <> '77777777-7777-7777-7777-010100000001';
IF @mismatch > 0
BEGIN
    ROLLBACK;
    RAISERROR('db/038 invariant (c) FAILED: %d PO line(s) have ReceivedQty != SUM(Receipts.QtyReceived).', 16, 1, @mismatch);
    RETURN;
END

PRINT 'Invariants OK — receipt backfill complete.';
COMMIT;
GO

PRINT '038_phase_14_receipt_backfill.sql complete — 19 receipts restored on PL-2847.';
GO
