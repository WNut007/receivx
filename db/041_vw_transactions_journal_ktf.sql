------------------------------------------------------------------------------
-- 041_vw_transactions_journal_ktf.sql
--
-- KTF export support. Additive re-ALTER of vw_TransactionsJournal — adds two
-- columns the KTF form needs and that nothing else surfaced yet:
--
--   InvoiceNo         pol.InvoiceNo (db/021 Phase 9 extended field). The view
--                     already INNER JOINs PurchaseOrderLines; it just never
--                     selected this column. Feeds the KTF "INV." column.
--   WarehouseTimezone w.Timezone (db/001, IANA id, default 'Asia/Bangkok').
--                     Receipts.ReceivedAt is UTC; the KTF form is a printed
--                     Thai document whose Date/SHIFT/Time columns must read in
--                     warehouse-local time. Without this, a receive at 02:00
--                     ICT (= 19:00 UTC previous day) prints the wrong date.
--
-- Diff vs db/036 §2a: + pol.InvoiceNo, + w.Timezone AS WarehouseTimezone.
-- Everything else byte-identical. No column drops, no renames — existing
-- consumers (ReceiptRepository.JournalSelect, transactions export) are
-- unaffected because they SELECT an explicit column list.
--
-- Re-runnable: CREATE OR ALTER.
------------------------------------------------------------------------------

PRINT 'Re-altering vw_TransactionsJournal (KTF: + InvoiceNo, + WarehouseTimezone)...';
GO

CREATE OR ALTER VIEW dbo.vw_TransactionsJournal AS
SELECT  r.Id,
        r.PullItemId,
        pi.PullId,
        p.PullNumber,
        p.WarehouseId,
        w.Code           AS WarehouseCode,
        w.Name           AS WarehouseName,
        -- db/041 — warehouse-local rendering for the KTF form (ReceivedAt is UTC).
        w.Timezone       AS WarehouseTimezone,
        pi.ItemCode,
        pi.Description   AS ItemDescription,
        -- PO context (§4.8 v2). Phase 14: vendor now lives on POL.
        r.PurchaseOrderId,
        po.PoNumber,
        pol.VendorCode,
        pol.VendorName,
        -- db/041 — Phase 9 extended field (db/021), surfaced for the KTF "INV." column.
        pol.InvoiceNo,
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

PRINT 'db/041 complete.';
GO
