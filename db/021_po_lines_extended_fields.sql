/* ============================================================================
   ReceivingOps — 021_po_lines_extended_fields.sql  (Phase 9 — ERP prep)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. 20 nullable columns on dbo.PurchaseOrderLines —
   destinations for ERP-sourced metadata that Phase 10 will push in via
   POST /api/erp/pos. Phase 9 ships schema + display + export only; the
   ingestion endpoint is deferred.

   Field redistribution from the original 24-field design list:
     SKIPPED (duplicates of existing columns):
       OrderDate     — already on PurchaseOrders header
       CreatedAt     — auto-managed audit field, not ERP business data
       ReceivedDate  — Receipts.ReceivedAt covers this
     RENAMED:
       Round → OrderRound (SQL Server reserved word; quoting it forever
                           is worse than picking a non-reserved name)
     SIZE ADJUSTED:
       Note → NVARCHAR(500) (NVARCHAR(50) too short for free text;
                             matches PurchaseOrders.Notes width)

   No indexes. Index design deferred to Phase 10 when ERP integration
   reveals which fields are actually filtered/searched. Adding indexes
   speculatively before observing query patterns wastes write throughput
   on columns that may never be filtered.

   No write paths. The existing PoCreateRequest / PoUpdateRequest DTOs
   stay untouched — ERP is the source of truth for these fields and
   no in-app authoring UI exists for them. Receivx-managed fields
   (PullId, lock states, ReceivedQty) are preserved by the future ERP
   upsert; ERP fields are write-through from external system.

   Idempotent — safe to re-run (per-column COL_LENGTH guard).
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

-- Tracking IDs (12 fields)
IF COL_LENGTH('dbo.PurchaseOrderLines', 'InvoiceNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.InvoiceNo...';
    ALTER TABLE dbo.PurchaseOrderLines ADD InvoiceNo NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'KanbanNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.KanbanNo...';
    ALTER TABLE dbo.PurchaseOrderLines ADD KanbanNo NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'AsnNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.AsnNo...';
    ALTER TABLE dbo.PurchaseOrderLines ADD AsnNo NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'PCCNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.PCCNo...';
    ALTER TABLE dbo.PurchaseOrderLines ADD PCCNo NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'BatchNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.BatchNo...';
    ALTER TABLE dbo.PurchaseOrderLines ADD BatchNo NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'ManufacturingControlNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.ManufacturingControlNo...';
    ALTER TABLE dbo.PurchaseOrderLines ADD ManufacturingControlNo NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'ManufacturingReferenceNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.ManufacturingReferenceNo...';
    ALTER TABLE dbo.PurchaseOrderLines ADD ManufacturingReferenceNo NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'CustomerReferenceNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.CustomerReferenceNo...';
    ALTER TABLE dbo.PurchaseOrderLines ADD CustomerReferenceNo NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'ExportDeclarationNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.ExportDeclarationNo...';
    ALTER TABLE dbo.PurchaseOrderLines ADD ExportDeclarationNo NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'VendorItem') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.VendorItem...';
    ALTER TABLE dbo.PurchaseOrderLines ADD VendorItem NVARCHAR(50) NULL;
END
GO

-- Location (6 fields)
IF COL_LENGTH('dbo.PurchaseOrderLines', 'PalletId') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.PalletId...';
    ALTER TABLE dbo.PurchaseOrderLines ADD PalletId NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'VmiPalletId') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.VmiPalletId...';
    ALTER TABLE dbo.PurchaseOrderLines ADD VmiPalletId NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'Location') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.Location...';
    ALTER TABLE dbo.PurchaseOrderLines ADD Location NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'Building') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.Building...';
    ALTER TABLE dbo.PurchaseOrderLines ADD Building NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'SubInventory') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.SubInventory...';
    ALTER TABLE dbo.PurchaseOrderLines ADD SubInventory NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'ToLocation') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.ToLocation...';
    ALTER TABLE dbo.PurchaseOrderLines ADD ToLocation NVARCHAR(50) NULL;
END
GO

-- Operations (2 fields)
IF COL_LENGTH('dbo.PurchaseOrderLines', 'ProductionLine') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.ProductionLine...';
    ALTER TABLE dbo.PurchaseOrderLines ADD ProductionLine NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'OrderRound') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.OrderRound (was "Round" — SQL reserved)...';
    ALTER TABLE dbo.PurchaseOrderLines ADD OrderRound NVARCHAR(50) NULL;
END
GO

-- Dates (1 field) — DATE not DATETIME2; this is a planned delivery date,
-- not a precise timestamp. Storage and serialization both benefit.
IF COL_LENGTH('dbo.PurchaseOrderLines', 'DeliveryDate') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.DeliveryDate (DATE)...';
    ALTER TABLE dbo.PurchaseOrderLines ADD DeliveryDate DATE NULL;
END
GO

-- Note (1 field) — 500 chars for free text
IF COL_LENGTH('dbo.PurchaseOrderLines', 'Note') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.Note (NVARCHAR(500))...';
    ALTER TABLE dbo.PurchaseOrderLines ADD Note NVARCHAR(500) NULL;
END
GO

PRINT '021_po_lines_extended_fields.sql complete (Phase 9 — 20 ERP-sourced fields).';
PRINT 'No indexes added — deferred to Phase 10 when ERP query patterns are known.';
GO
