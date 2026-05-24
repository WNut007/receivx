/* ============================================================================
   ReceivingOps — 019_pagination_indexes.sql  (Phase 8.1 — pagination foundation)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Two non-clustered indexes to support paginated
   list endpoints at production scale (5K+ receipts/day, 1.8M+/year).

     1. IX_Pulls_ClosedAt    — Reports DO list:
                                WHERE Status = 'closed' ORDER BY ClosedAt DESC
        Filtered index restricted to closed pulls (≈30% of the table at
        steady state); INCLUDE the columns the list page reads so the index
        can satisfy the query without bookmark lookups.

     2. IX_PO_OrderDate      — Pos "all status + date range" path:
                                WHERE OrderDate BETWEEN x AND y
        Existing IX_PO_FIFO (WarehouseId, Status, OrderDate) only kicks in
        when Status is filtered. When the operator picks "All status" +
        a date range the optimizer scans without it. This index covers
        the status-agnostic path.

   Phase 8.0 spec also called for IX_Receipts_WhWhen (WarehouseId,
   ReceivedAt DESC) but dbo.Receipts has no WarehouseId column — the
   value lives on dbo.Pulls and is reached via the
   Receipts → PullItems → Pulls join chain. Adding it as a denormalized
   column requires a schema change + backfill (out of scope for an
   index-only migration); the existing IX_Receipts_When + the FK indexes
   along the join chain handle the WH-filtered sort well enough at the
   current order of magnitude. Re-evaluate after the 100K-row load test
   in Phase 8.5; if the optimizer still picks a bad plan, the denormalized
   column gets its own migration then.

   ONLINE = ON dropped: this codebase targets SQL Server Standard in prod;
   the indexes are small so a brief lock during build is acceptable.

   Note: CLAUDE.md mentioned db/019 was reserved for Pulls.CloseNote (the
   v2.x backlog deferral). That migration is re-slotted to db/020 if it
   ever lands — db/019 takes pagination per the Phase 8 plan.

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

-- ---------- 1. IX_Pulls_ClosedAt (filtered, INCLUDE) ----------
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Pulls_ClosedAt'
      AND object_id = OBJECT_ID('dbo.Pulls')
)
BEGIN
    PRINT 'Creating IX_Pulls_ClosedAt (filtered: Status = ''closed'')...';
    CREATE NONCLUSTERED INDEX IX_Pulls_ClosedAt
        ON dbo.Pulls (ClosedAt DESC)
        INCLUDE (Status, WarehouseId, PullDate, PullNumber)
        WHERE Status = 'closed'
        WITH (FILLFACTOR = 90);
END
GO

-- ---------- 2. IX_PO_OrderDate (status-agnostic) ----------
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_PO_OrderDate'
      AND object_id = OBJECT_ID('dbo.PurchaseOrders')
)
BEGIN
    PRINT 'Creating IX_PO_OrderDate (OrderDate DESC, WarehouseId)...';
    CREATE NONCLUSTERED INDEX IX_PO_OrderDate
        ON dbo.PurchaseOrders (OrderDate DESC, WarehouseId)
        INCLUDE (Status)
        WITH (FILLFACTOR = 90);
END
GO

PRINT '019_pagination_indexes.sql complete (Phase 8.1).';
GO
