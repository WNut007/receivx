/* ============================================================================
   ReceivingOps — 011_schema_v2_strict.sql  (Phase 1b of v2 migration)
   ----------------------------------------------------------------------------
   STRICT, breaking-if-data-isn't-clean. Run AFTER 012 backfill.

     1. Pre-flight: refuse to run if any data would violate the new constraints.
     2. ALTER Receipts.PurchaseOrderId      NOT NULL
        ALTER Receipts.PurchaseOrderLineId  NOT NULL
     3. ADD FK_Receipts_PO       → dbo.PurchaseOrders(Id)
        ADD FK_Receipts_POLine   → dbo.PurchaseOrderLines(Id)
     4. ADD CK_Receipts_ReversalIntegrity:
          (ReversesReceiptId IS NULL     AND QtyReceived > 0)
          OR (ReversesReceiptId IS NOT NULL AND QtyReceived < 0)
        — encodes §7.10 reverse-entry semantics in DDL.
     5. CREATE INDEX IX_Receipts_POLine — read path for PO detail page.

   Idempotent. Re-running after a successful Phase 1b finds every object
   already in place and prints nothing.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

----------------------------------------------------------------------------
-- 1. Pre-flight — refuse to proceed unless data is consistent with the
--    constraints we are about to apply.
----------------------------------------------------------------------------
DECLARE @nullPo INT, @nullPoLine INT, @ckViolators INT, @danglingPo INT, @danglingPoLine INT;
DECLARE @msg NVARCHAR(400);

SELECT @nullPo     = COUNT(*) FROM dbo.Receipts WHERE PurchaseOrderId     IS NULL;
SELECT @nullPoLine = COUNT(*) FROM dbo.Receipts WHERE PurchaseOrderLineId IS NULL;

SELECT @ckViolators = COUNT(*) FROM dbo.Receipts
WHERE  NOT (
    (ReversesReceiptId IS NULL     AND QtyReceived > 0) OR
    (ReversesReceiptId IS NOT NULL AND QtyReceived < 0)
);

SELECT @danglingPo = COUNT(*) FROM dbo.Receipts r
WHERE  r.PurchaseOrderId IS NOT NULL
  AND  NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders po WHERE po.Id = r.PurchaseOrderId);

SELECT @danglingPoLine = COUNT(*) FROM dbo.Receipts r
WHERE  r.PurchaseOrderLineId IS NOT NULL
  AND  NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol WHERE pol.Id = r.PurchaseOrderLineId);

IF @nullPo > 0 OR @nullPoLine > 0 OR @ckViolators > 0 OR @danglingPo > 0 OR @danglingPoLine > 0
BEGIN
    SET @msg = CONCAT(
        N'Phase 1b pre-flight FAILED. ',
        N'NULL PurchaseOrderId=', @nullPo,
        N', NULL PurchaseOrderLineId=', @nullPoLine,
        N', CK violators=', @ckViolators,
        N', dangling PO=', @danglingPo,
        N', dangling POLine=', @danglingPoLine,
        N'. Run Phase 2 (012_backfill_receipts.sql) first.');
    THROW 50010, @msg, 1;
END
PRINT 'Pre-flight OK';

----------------------------------------------------------------------------
-- 2. NOT NULL on the PO binding columns
----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE Name = N'PurchaseOrderId'
      AND Object_ID = OBJECT_ID(N'dbo.Receipts')
      AND is_nullable = 1
)
BEGIN
    PRINT 'Tightening Receipts.PurchaseOrderId to NOT NULL...';
    ALTER TABLE dbo.Receipts ALTER COLUMN PurchaseOrderId UNIQUEIDENTIFIER NOT NULL;
END
GO

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE Name = N'PurchaseOrderLineId'
      AND Object_ID = OBJECT_ID(N'dbo.Receipts')
      AND is_nullable = 1
)
BEGIN
    PRINT 'Tightening Receipts.PurchaseOrderLineId to NOT NULL...';
    ALTER TABLE dbo.Receipts ALTER COLUMN PurchaseOrderLineId UNIQUEIDENTIFIER NOT NULL;
END
GO

----------------------------------------------------------------------------
-- 3. Foreign keys
----------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = N'FK_Receipts_PO'
      AND parent_object_id = OBJECT_ID(N'dbo.Receipts')
)
BEGIN
    PRINT 'Adding FK_Receipts_PO...';
    ALTER TABLE dbo.Receipts
      ADD CONSTRAINT FK_Receipts_PO
      FOREIGN KEY (PurchaseOrderId) REFERENCES dbo.PurchaseOrders(Id);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = N'FK_Receipts_POLine'
      AND parent_object_id = OBJECT_ID(N'dbo.Receipts')
)
BEGIN
    PRINT 'Adding FK_Receipts_POLine...';
    ALTER TABLE dbo.Receipts
      ADD CONSTRAINT FK_Receipts_POLine
      FOREIGN KEY (PurchaseOrderLineId) REFERENCES dbo.PurchaseOrderLines(Id);
END
GO

----------------------------------------------------------------------------
-- 4. CK_Receipts_ReversalIntegrity — encode §7.10 reverse-entry rule in DDL
----------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = N'CK_Receipts_ReversalIntegrity'
      AND parent_object_id = OBJECT_ID(N'dbo.Receipts')
)
BEGIN
    PRINT 'Adding CK_Receipts_ReversalIntegrity...';
    ALTER TABLE dbo.Receipts
      ADD CONSTRAINT CK_Receipts_ReversalIntegrity CHECK (
          (ReversesReceiptId IS NULL     AND QtyReceived > 0) OR
          (ReversesReceiptId IS NOT NULL AND QtyReceived < 0)
      );
END
GO

----------------------------------------------------------------------------
-- 5. IX_Receipts_POLine — covers "list receipts for a PO line" query
----------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_Receipts_POLine'
      AND object_id = OBJECT_ID(N'dbo.Receipts')
)
BEGIN
    PRINT 'Creating index IX_Receipts_POLine...';
    CREATE INDEX IX_Receipts_POLine ON dbo.Receipts(PurchaseOrderLineId);
END
GO

PRINT '011_schema_v2_strict.sql complete (Phase 1b).';
GO
