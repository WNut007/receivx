/* ============================================================================
   ReceivingOps — 025_vw_transactions_journal_pull_item_erp.sql  (Phase 9.1)
   ----------------------------------------------------------------------------
   Extend dbo.vw_TransactionsJournal with the 7 ERP-sourced PullItem fields
   from db/024. The view already INNER JOINs PullItems (aliased `pi`) so the
   only change here is adding columns to the SELECT list.

   Naming notes:
     • pi.Location is aliased `PullLocation` to avoid future ambiguity if/when
       Phase 10 surfaces PurchaseOrderLines.Location (db/021) into the same
       view — single-name "Location" would collide.
     • pi.[Phase] is aliased `PullPhase` so consumers (DTOs / Excel headers)
       don't have to bracket-escape PHASE on the readers' side either.
     • Other 5 columns pass through with their column name.

   Backwards compat:
     • Additive — all 7 columns are appended at the end of the SELECT list.
     • Existing consumers (drawer / receiving / transactions page) ignore
       columns they don't map, so this is safe.
     • ReceiptJournalRow DTO + JournalSelect string in ReceiptRepository
       gain matching properties / column names so Dapper materializes them.

   Idempotent — CREATE OR ALTER VIEW (re-run safe).
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
        -- Phase 9.1 — ERP-sourced PullItem fields (db/024).
        pi.ProductFamily,
        pi.FromSubInventory,
        pi.ToSubInventory,
        pi.SpecialControl,
        pi.TrailId,
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

PRINT '025_vw_transactions_journal_pull_item_erp.sql complete — 7 ERP fields added.';
GO
