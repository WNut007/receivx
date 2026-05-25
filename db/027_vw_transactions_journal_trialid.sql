/* ============================================================================
   ReceivingOps — 027_vw_transactions_journal_trialid.sql  (v2.3.2)
   ----------------------------------------------------------------------------
   Re-alter dbo.vw_TransactionsJournal so its SELECT list references the
   renamed pi.TrialId column (db/026). Otherwise identical to db/025 — only
   the TrailId/TrialId token differs. Same alias scheme retained:
     • pi.TrialId surfaces as TrialId on the view (matches DTO + JSON key)
     • pi.Location  -> PullLocation (collision-safe with future PO Location)
     • pi.[Phase]   -> PullPhase    (avoids the PHASE keyword on readers)

   Idempotent — CREATE OR ALTER VIEW.
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

PRINT '027_vw_transactions_journal_trialid.sql complete.';
GO
