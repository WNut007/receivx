/* ============================================================================
   ReceivingOps — 015_schema_po_pull_link.sql  (Phase 3.5 of v2 migration)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Configurable PO-pull lock.

     1. ALTER PurchaseOrders ADD PullId UNIQUEIDENTIFIER NULL
        + FK_PO_Pull         → dbo.Pulls(Id)
        + IX_PO_Pull         filtered index WHERE PullId IS NOT NULL
     2. ALTER Pulls ADD LockPoByPull BIT NOT NULL DEFAULT 0
        (Default 0 = backward-compat warehouse-wide FIFO. Lock is immutable
         after pull creation — enforced at the application layer in 4e.)
     3. CREATE OR ALTER vw_PurchaseOrderAvailability — project PullId so the
        FIFO query layer can filter `WHERE po.PullId = @PullId` when the
        pull is in strict mode.

   Semantics (recap, enforced in application code in Phase 4):
     - LockPoByPull = 0: FIFO scope = warehouse-wide (existing behavior).
     - LockPoByPull = 1: FIFO scope = WHERE po.PullId = this pull's Id.
       If no PO is linked, receive 409s with "No PO linked to this pull".
     - PullId on PO is set at create-time only — PUT changes refuse 409.
     - LockPoByPull on Pulls is set at create-time only — PUT changes refuse 409.

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- 1. PurchaseOrders.PullId  (nullable — optional metadata)
------------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE Name = N'PullId'
      AND Object_ID = OBJECT_ID(N'dbo.PurchaseOrders')
)
BEGIN
    PRINT 'Adding PurchaseOrders.PullId (nullable)...';
    ALTER TABLE dbo.PurchaseOrders ADD PullId UNIQUEIDENTIFIER NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = N'FK_PO_Pull'
      AND parent_object_id = OBJECT_ID(N'dbo.PurchaseOrders')
)
BEGIN
    PRINT 'Adding FK_PO_Pull...';
    ALTER TABLE dbo.PurchaseOrders
      ADD CONSTRAINT FK_PO_Pull
      FOREIGN KEY (PullId) REFERENCES dbo.Pulls(Id);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_PO_Pull'
      AND object_id = OBJECT_ID(N'dbo.PurchaseOrders')
)
BEGIN
    PRINT 'Creating filtered index IX_PO_Pull...';
    CREATE INDEX IX_PO_Pull ON dbo.PurchaseOrders(PullId)
        WHERE PullId IS NOT NULL;
END
GO

------------------------------------------------------------------------------
-- 2. Pulls.LockPoByPull  (NOT NULL, default 0 — applied to existing rows)
------------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE Name = N'LockPoByPull'
      AND Object_ID = OBJECT_ID(N'dbo.Pulls')
)
BEGIN
    PRINT 'Adding Pulls.LockPoByPull (NOT NULL DEFAULT 0)...';
    ALTER TABLE dbo.Pulls
      ADD LockPoByPull BIT NOT NULL
      CONSTRAINT DF_Pulls_LockPoByPull DEFAULT 0;
END
GO

------------------------------------------------------------------------------
-- 3. vw_PurchaseOrderAvailability — project PullId for lock-aware FIFO
------------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_PurchaseOrderAvailability AS
SELECT  pol.Id            AS PurchaseOrderLineId,
        pol.PurchaseOrderId,
        po.PoNumber,
        po.WarehouseId,
        po.PullId,                                  -- §3.5 — lock-aware FIFO filter key
        po.VendorCode,
        po.VendorName,
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

PRINT '015_schema_po_pull_link.sql complete (Phase 3.5).';
GO
