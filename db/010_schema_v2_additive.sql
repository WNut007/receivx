/* ============================================================================
   ReceivingOps — 010_schema_v2_additive.sql  (Phase 1a of v2 migration)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Safe to re-run.
     1. CREATE PurchaseOrders + PurchaseOrderLines (§4.5a)
     2. ALTER Receipts ADD PurchaseOrderId, PurchaseOrderLineId (nullable —
        will become NOT NULL + FK after Phase 2 backfill)
     3. DROP CK_PIW_Caps — per §7.1, the PO is the hard cap; per-hour overage
        is allowed (§4.6 v2)
     4. CREATE OR ALTER VIEW vw_PurchaseOrderAvailability — FIFO read path
        (§4.8 v2)

   vw_TransactionsJournal is intentionally NOT modified here — it would break
   on existing receipts (NULL PO columns) and breaking changes belong in 1b.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- §4.5a PurchaseOrders
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.PurchaseOrders', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.PurchaseOrders...';
    CREATE TABLE dbo.PurchaseOrders (
        Id             UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
        PoNumber       VARCHAR(32)      NOT NULL UNIQUE,
        WarehouseId    UNIQUEIDENTIFIER NOT NULL,
        VendorCode     VARCHAR(64)      NULL,
        VendorName     NVARCHAR(160)    NULL,
        OrderDate      DATE             NOT NULL,                    -- FIFO key
        ExpectedDate   DATE             NULL,
        Status         VARCHAR(16)      NOT NULL DEFAULT 'open'
                        CONSTRAINT CK_PO_Status
                        CHECK (Status IN ('open','closed','canceled')),
        Notes          NVARCHAR(500)    NULL,
        CreatedBy      UNIQUEIDENTIFIER NULL,
        CreatedAt      DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
        ClosedAt       DATETIME2(0)     NULL,                        -- set when fully received
        CONSTRAINT FK_PO_Warehouse FOREIGN KEY (WarehouseId) REFERENCES dbo.Warehouses(Id),
        CONSTRAINT FK_PO_CreatedBy FOREIGN KEY (CreatedBy)   REFERENCES dbo.Users(Id)
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_PO_FIFO'
      AND object_id = OBJECT_ID(N'dbo.PurchaseOrders')
)
BEGIN
    PRINT 'Creating index IX_PO_FIFO...';
    CREATE INDEX IX_PO_FIFO ON dbo.PurchaseOrders(WarehouseId, Status, OrderDate);
END
GO

------------------------------------------------------------------------------
-- §4.5a PurchaseOrderLines
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.PurchaseOrderLines', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.PurchaseOrderLines...';
    CREATE TABLE dbo.PurchaseOrderLines (
        Id              UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
        PurchaseOrderId UNIQUEIDENTIFIER NOT NULL,
        LineNumber      INT              NOT NULL,
        ItemCode        VARCHAR(64)      NOT NULL,
        Description     NVARCHAR(255)    NOT NULL,
        OrderedQty      INT              NOT NULL
                         CONSTRAINT CK_POL_Ordered CHECK (OrderedQty > 0),
        ReceivedQty     INT              NOT NULL DEFAULT 0,         -- denormalized cache; truth = SUM(Receipts.QtyReceived) WHERE PurchaseOrderLineId = this
        CONSTRAINT FK_POL_PurchaseOrder FOREIGN KEY (PurchaseOrderId) REFERENCES dbo.PurchaseOrders(Id) ON DELETE CASCADE,
        CONSTRAINT UQ_POL_LineNumber UNIQUE (PurchaseOrderId, LineNumber),
        CONSTRAINT CK_POL_Caps      CHECK (ReceivedQty <= OrderedQty AND ReceivedQty >= 0)
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_POL_FIFO'
      AND object_id = OBJECT_ID(N'dbo.PurchaseOrderLines')
)
BEGIN
    PRINT 'Creating index IX_POL_FIFO...';
    CREATE INDEX IX_POL_FIFO ON dbo.PurchaseOrderLines(ItemCode, PurchaseOrderId)
        INCLUDE (OrderedQty, ReceivedQty);
END
GO

------------------------------------------------------------------------------
-- §4.7 Receipts — additive nullable PO columns
-- Will be tightened to NOT NULL + FK + CK_Receipts_ReversalIntegrity in 1b
-- after Phase 2 backfills every row.
------------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE Name = N'PurchaseOrderId'
      AND Object_ID = OBJECT_ID(N'dbo.Receipts')
)
BEGIN
    PRINT 'Adding Receipts.PurchaseOrderId (nullable — Phase 1a)...';
    ALTER TABLE dbo.Receipts ADD PurchaseOrderId UNIQUEIDENTIFIER NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE Name = N'PurchaseOrderLineId'
      AND Object_ID = OBJECT_ID(N'dbo.Receipts')
)
BEGIN
    PRINT 'Adding Receipts.PurchaseOrderLineId (nullable — Phase 1a)...';
    ALTER TABLE dbo.Receipts ADD PurchaseOrderLineId UNIQUEIDENTIFIER NULL;
END
GO

------------------------------------------------------------------------------
-- §4.6 v2 — drop CK_PIW_Caps so per-hour overage is allowed.
-- (The PO line CK_POL_Caps becomes the new hard limit; PullItemWindows.ReceivedQty
--  remains as a denormalized cache that may exceed ExpectedQty.)
------------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = N'CK_PIW_Caps'
      AND parent_object_id = OBJECT_ID(N'dbo.PullItemWindows')
)
BEGIN
    PRINT 'Dropping CK_PIW_Caps from PullItemWindows (per §7.1 v2)...';
    ALTER TABLE dbo.PullItemWindows DROP CONSTRAINT CK_PIW_Caps;
END
GO

------------------------------------------------------------------------------
-- §4.8 v2 — vw_PurchaseOrderAvailability (FIFO read path for the allocator)
------------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_PurchaseOrderAvailability AS
SELECT  pol.Id            AS PurchaseOrderLineId,
        pol.PurchaseOrderId,
        po.PoNumber,
        po.WarehouseId,
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

PRINT '010_schema_v2_additive.sql complete (Phase 1a).';
GO
