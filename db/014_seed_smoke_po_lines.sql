/* ============================================================================
   ReceivingOps — 014_seed_smoke_po_lines.sql  (Phase 4, smoke-infrastructure)
   ----------------------------------------------------------------------------
   Adds a single low-volume PO line for ItemCode='SUMMARY' on the newest PO of
   each active warehouse, so existing smoke suites (smoke-receive, stage-b,
   transactions, close-reopen) can keep targeting the SUMMARY-placeholder
   PullItems they were written against. Without this, /api/receipts on any
   SUMMARY pullItem 409s with "Insufficient PO capacity".

   Why this exists:
     - PullItems with ItemCode='SUMMARY' are a UI placeholder seeded on every
       pull except PL-2847 (see db/006). The mockup uses these rows to render
       a "Summary row — see dashboard for breakdown" pseudo-item.
     - Phase 2 deliberately purged SUMMARY *receipts* (smoke residue) and
       removed SUMMARY from the planned PO catalog (per user directive
       "PO catalog เหลือเฉพาะ planned items จริง"), leaving SUMMARY without
       any PO coverage.
     - Smoke tests still target SUMMARY items because no other PullItem rows
       exist on PL-2840/41/42/43/44/46/48/49/50/51. Rewriting all four smokes
       to use PL-2847's real items would force fragile assertion churn (the
       18 backfilled receipts there would contaminate count-based asserts).
     - The pragmatic fix: a small "smoke sandbox" PO line per warehouse,
       clearly labeled so future readers know its purpose.

   If the user later prefers to remove this concession and rewrite the smokes,
   delete this file and the lines (no receipts reference them yet — §7.13
   permits deletion).

   Idempotent — guarded INSERTs.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

-- WH-01 — append to PO-2403-044 (newest open WH-01 PO)
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-040100000003')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-040100000003', '66666666-6666-6666-6666-000000000004', 3,
            'SUMMARY', N'Smoke-test sandbox capacity (not a real stocking item)', 50000, 0);
END
GO

-- WH-02 — append to PO-2403-051 (newest open WH-02 PO)
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-070100000002')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-070100000002', '66666666-6666-6666-6666-000000000007', 2,
            'SUMMARY', N'Smoke-test sandbox capacity (not a real stocking item)', 50000, 0);
END
GO

-- WH-03 — append to PO-2403-061 (newest open WH-03 PO)
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-100100000002')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-100100000002', '66666666-6666-6666-6666-000000000010', 2,
            'SUMMARY', N'Smoke-test sandbox capacity (not a real stocking item)', 50000, 0);
END
GO

PRINT '014_seed_smoke_po_lines.sql complete — 3 SUMMARY sandbox lines (50k each) seeded.';
GO
