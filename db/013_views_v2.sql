/* ============================================================================
   ReceivingOps — 013_views_v2.sql  (Phase 3 of v2 migration)
   ----------------------------------------------------------------------------
   CREATE OR ALTER vw_TransactionsJournal so it carries PO context on every
   row. INNER JOIN PurchaseOrders + PurchaseOrderLines is safe now that Phase
   1b enforces non-null FK on Receipts.

   No new columns are introduced beyond what §4.8 v2 specifies. Existing
   readers ignore unknown SELECT columns; consumers that want the new
   columns (PoNumber, VendorCode, VendorName, PurchaseOrderId,
   PurchaseOrderLineId, PoLineNumber) opt in by mapping them on the DTO.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
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
        -- PO context (§4.8 v2)
        r.PurchaseOrderId,
        po.PoNumber,
        po.VendorCode,
        po.VendorName,
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
        END AS Kind
FROM    dbo.Receipts r
INNER JOIN dbo.PullItems pi          ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p               ON p.Id  = pi.PullId
INNER JOIN dbo.Warehouses w          ON w.Id  = p.WarehouseId
INNER JOIN dbo.Users u               ON u.Id  = r.ReceivedBy
INNER JOIN dbo.PurchaseOrders po     ON po.Id = r.PurchaseOrderId
INNER JOIN dbo.PurchaseOrderLines pol ON pol.Id = r.PurchaseOrderLineId;
GO

PRINT '013_views_v2.sql complete — vw_TransactionsJournal now carries PO context.';
GO
