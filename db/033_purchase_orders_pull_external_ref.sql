/* ============================================================================
   ReceivingOps — 033_purchase_orders_pull_external_ref.sql  (Phase 12 follow-up)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Adds dbo.PurchaseOrders.PullExternalRef +
   IX_PO_PullExternalRef filtered index.

   v3.2 shipped PO import (Phase 12) with PullId=NULL on every imported
   PO because the v3.2 spec's "PullId = PRS_ID denormalized" idea
   conflicted with the real Guid FK_PO_Pull constraint. PullExternalRef
   is a parallel NVARCHAR(50) column that captures the external pull
   reference (the workbook's PRS_ID) without touching the FK.

   Receive flow extension (§7.15 lock-by-pull) and UI rendering land in
   separate commits; this migration is the storage substrate.

   Filtered index mirrors IX_PO_Pull's shape (filtered WHERE NOT NULL +
   leads with WarehouseId so the FIFO walk's WHERE WarehouseId clause
   composes cleanly). Index size stays proportional to imported POs
   only — cross-pool POs pay nothing.

   Idempotent — COL_LENGTH + sys.indexes guards. Safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.PurchaseOrders', 'PullExternalRef') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrders.PullExternalRef (NVARCHAR(50) NULL)...';
    ALTER TABLE dbo.PurchaseOrders ADD PullExternalRef NVARCHAR(50) NULL;
END
ELSE
BEGIN
    PRINT 'PurchaseOrders.PullExternalRef already exists — no change.';
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM   sys.indexes
    WHERE  name = N'IX_PO_PullExternalRef'
      AND  object_id = OBJECT_ID(N'dbo.PurchaseOrders')
)
BEGIN
    PRINT 'Creating filtered index IX_PO_PullExternalRef (WarehouseId, PullExternalRef)...';
    CREATE INDEX IX_PO_PullExternalRef
        ON dbo.PurchaseOrders (WarehouseId, PullExternalRef)
        WHERE PullExternalRef IS NOT NULL;
END
ELSE
BEGIN
    PRINT 'IX_PO_PullExternalRef already exists — no change.';
END
GO

PRINT '033_purchase_orders_pull_external_ref.sql complete (Phase 12 follow-up).';
GO
