/* ============================================================================
   ReceivingOps — 036_vendor_to_po_lines.sql  (Phase 14 — vendor schema move)
   ----------------------------------------------------------------------------
   Moves VendorCode + VendorName from dbo.PurchaseOrders (header) to
   dbo.PurchaseOrderLines (line). Phase 14 locked decision Q2: mixed
   vendor per PO is a real production case — the v3.2 import job's
   "take firstRow.VendorCode and stamp the whole PO" was silently
   discarding lines 2..N's vendor.

   Order of operations matters:
     1a. Re-CREATE OR ALTER vw_TransactionsJournal to source vendor from
         pol.* instead of po.*. The existing view (db/027) selects
         po.VendorCode / po.VendorName; if we DROP those columns first
         the view falls into a deferred-compile failure that surfaces
         as runtime breakage on every Transactions/Reports query.
         Re-altering first keeps the view valid across the transition.
     1b. Re-CREATE OR ALTER vw_PurchaseOrderAvailability — same
         reasoning. db/015 originally bound vendor from po.*; the
         view feeds PurchaseOrderRepository.GetAvailabilityAsync
         which is the §3.5 lock-aware FIFO scan that ReceiptService
         walks on every receive. DROP first would break receives the
         moment any operator picks up an item.
     2. ADD VendorCode (VARCHAR(64) NULL) + VendorName (NVARCHAR(160) NULL)
        on dbo.PurchaseOrderLines. Sizing matches the columns being
        dropped from PurchaseOrders so DTOs + Dapper stay byte-for-byte
        compatible.
     3. CREATE filtered index IX_POL_Vendor on POL.VendorCode WHERE NOT NULL.
        Phase 14 DO grouping reads vendor from POL for every closed
        pull's report (DeliveryOrderService groups by FromSubInventory ×
        ToLocation × VendorCode). The filter keeps the index narrow —
        legacy/manual POs without vendor data pay nothing.
     4. DROP VendorCode + VendorName from dbo.PurchaseOrders. Safe to
        DROP because (a) db/035 wiped the tables, (b) view re-alters
        in steps 1a + 1b stopped referencing these columns, and
        (c) no other index or FK binds to either column (verified:
        IX_PO_FIFO leads with WarehouseId + Status + OrderDate;
        IX_PO_PullExternalRef leads with WarehouseId + PullExternalRef;
        no other index references vendor on the PO header).

   Re-runnability: every step is guarded (CREATE OR ALTER on the view,
   COL_LENGTH guards on column add/drop, sys.indexes guard on the new
   index). A second run prints "no change" lines and exits cleanly.

   This migration assumes db/035 has run (no PO/POL rows exist). It will
   still apply on a non-empty table — but post-condition is that any
   pre-existing po.VendorCode/Name values are LOST without backfill to
   POL. db/035 is the contract that makes that loss intentional.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- 1a. Re-alter vw_TransactionsJournal to source vendor from POL.
--     Diff vs db/027: po.VendorCode → pol.VendorCode, po.VendorName → pol.VendorName.
--     Everything else identical.
------------------------------------------------------------------------------
PRINT 'Re-altering vw_TransactionsJournal (vendor from POL)...';
GO

CREATE OR ALTER VIEW dbo.vw_TransactionsJournal AS
SELECT  r.Id,
        r.PullItemId,
        pi.PullId,
        p.PullNumber,
        p.WarehouseId,
        w.Code           AS WarehouseCode,
        w.Name           AS WarehouseName,
        pi.ItemCode,
        pi.Description   AS ItemDescription,
        -- PO context (§4.8 v2). Phase 14: vendor now lives on POL.
        r.PurchaseOrderId,
        po.PoNumber,
        pol.VendorCode,
        pol.VendorName,
        r.PurchaseOrderLineId,
        pol.LineNumber   AS PoLineNumber,
        r.HourOfDay,
        r.QtyReceived,
        r.LotBatch,
        r.PalletId,
        r.BinLocation,
        r.QcStatus,
        r.Note,
        r.ReceivedBy,
        u.Name           AS ReceivedByName,
        r.ReceivedAt,
        r.ReversesReceiptId,
        r.ReversedById,
        r.CancelReason,
        CASE
            WHEN r.QtyReceived < 0          THEN 'reversal'
            WHEN r.ReversedById IS NOT NULL THEN 'voided'
            ELSE 'receive'
        END AS Kind,
        -- Phase 9.1 — ERP-sourced PullItem fields (db/024 + db/026 rename).
        pi.ProductFamily,
        pi.FromSubInventory,
        pi.ToSubInventory,
        pi.SpecialControl,
        pi.TrialId,
        pi.Location      AS PullLocation,
        pi.[Phase]       AS PullPhase
FROM    dbo.Receipts r
INNER JOIN dbo.PullItems pi          ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p               ON p.Id  = pi.PullId
INNER JOIN dbo.Warehouses w          ON w.Id  = p.WarehouseId
INNER JOIN dbo.Users u               ON u.Id  = r.ReceivedBy
INNER JOIN dbo.PurchaseOrders po     ON po.Id = r.PurchaseOrderId
INNER JOIN dbo.PurchaseOrderLines pol ON pol.Id = r.PurchaseOrderLineId;
GO

------------------------------------------------------------------------------
-- 1b. Re-alter vw_PurchaseOrderAvailability to source vendor from POL.
--     Diff vs db/015: po.VendorCode/Name → pol.VendorCode/Name.
--     Used by §3.5 lock-aware FIFO availability scan in
--     PurchaseOrderRepository.GetAvailabilityAsync; ReceiptService walks
--     this view on every receive call, so any column-drop on the PO
--     header before this re-alter would break receives immediately.
------------------------------------------------------------------------------
PRINT 'Re-altering vw_PurchaseOrderAvailability (vendor from POL)...';
GO

CREATE OR ALTER VIEW dbo.vw_PurchaseOrderAvailability AS
SELECT  pol.Id            AS PurchaseOrderLineId,
        pol.PurchaseOrderId,
        po.PoNumber,
        po.WarehouseId,
        po.PullId,                                  -- §3.5 — lock-aware FIFO filter key
        pol.VendorCode,
        pol.VendorName,
        po.OrderDate,
        po.Status         AS PoStatus,
        pol.LineNumber,
        pol.ItemCode,
        pol.OrderedQty,
        pol.ReceivedQty,
        (pol.OrderedQty - pol.ReceivedQty) AS RemainingQty
FROM    dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE   po.Status = 'open'
  AND   pol.OrderedQty > pol.ReceivedQty;
GO

------------------------------------------------------------------------------
-- 2. ADD vendor to PurchaseOrderLines. Sizing matches the columns being
--    dropped from PurchaseOrders (db/001 + db/010): VARCHAR(64) + NVARCHAR(160).
------------------------------------------------------------------------------
IF COL_LENGTH('dbo.PurchaseOrderLines', 'VendorCode') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.VendorCode (VARCHAR(64) NULL)...';
    ALTER TABLE dbo.PurchaseOrderLines ADD VendorCode VARCHAR(64) NULL;
END
ELSE
BEGIN
    PRINT 'PurchaseOrderLines.VendorCode already exists — no change.';
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'VendorName') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.VendorName (NVARCHAR(160) NULL)...';
    ALTER TABLE dbo.PurchaseOrderLines ADD VendorName NVARCHAR(160) NULL;
END
ELSE
BEGIN
    PRINT 'PurchaseOrderLines.VendorName already exists — no change.';
END
GO

------------------------------------------------------------------------------
-- 3. Filtered index on POL.VendorCode. Phase 14 DO grouping reads vendor
--    per line; legacy/manual POs without vendor pay no index cost.
------------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1
    FROM   sys.indexes
    WHERE  name = N'IX_POL_Vendor'
      AND  object_id = OBJECT_ID(N'dbo.PurchaseOrderLines')
)
BEGIN
    PRINT 'Creating filtered index IX_POL_Vendor (VendorCode) WHERE NOT NULL...';
    CREATE INDEX IX_POL_Vendor
        ON dbo.PurchaseOrderLines (VendorCode)
        WHERE VendorCode IS NOT NULL;
END
ELSE
BEGIN
    PRINT 'IX_POL_Vendor already exists — no change.';
END
GO

------------------------------------------------------------------------------
-- 4. DROP vendor from PurchaseOrders. Safe because (a) db/035 wiped rows,
--    (b) view re-alters in steps 1a + 1b stopped referencing these columns,
--    and (c) no other index or FK binds to vendor on the PO header.
------------------------------------------------------------------------------
IF COL_LENGTH('dbo.PurchaseOrders', 'VendorName') IS NOT NULL
BEGIN
    PRINT 'Dropping PurchaseOrders.VendorName...';
    ALTER TABLE dbo.PurchaseOrders DROP COLUMN VendorName;
END
ELSE
BEGIN
    PRINT 'PurchaseOrders.VendorName already absent — no change.';
END
GO

IF COL_LENGTH('dbo.PurchaseOrders', 'VendorCode') IS NOT NULL
BEGIN
    PRINT 'Dropping PurchaseOrders.VendorCode...';
    ALTER TABLE dbo.PurchaseOrders DROP COLUMN VendorCode;
END
ELSE
BEGIN
    PRINT 'PurchaseOrders.VendorCode already absent — no change.';
END
GO

PRINT '036_vendor_to_po_lines.sql complete. Vendor now lives at the line level.';
GO
