/* ============================================================================
   ReceivingOps — 039_warehouses_logo.sql  (per-warehouse logo)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Adds dbo.Warehouses.LogoDataUrl NVARCHAR(MAX) NULL.

   The DO report header (DeliveryOrderService + _DoPreview.cshtml) currently
   shows the global CompanyInfo logo only; per-warehouse branding lets each
   site stamp its own mark on the printed delivery order. Storage choice
   mirrors dbo.Pulls.SignatureSvg: full data URL
   ("data:image/png;base64,...") on the row, so the warehouse master is
   self-contained — no separate fetch endpoint, no file-vs-DB drift, and
   restore semantics align with the rest of the master data backup.

   No index — LogoDataUrl is read only when rendering a DO (one row per
   pull's WH), never filtered on, and the field would defeat row-store
   prefetch anyway because of its width. Same reasoning as
   Pulls.SignatureSvg (also un-indexed).

   Idempotent — COL_LENGTH guard. Safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.Warehouses', 'LogoDataUrl') IS NULL
BEGIN
    PRINT 'Adding Warehouses.LogoDataUrl (NVARCHAR(MAX) NULL)...';
    ALTER TABLE dbo.Warehouses ADD LogoDataUrl NVARCHAR(MAX) NULL;
END
ELSE
BEGIN
    PRINT 'Warehouses.LogoDataUrl already exists — no change.';
END
GO

PRINT '039_warehouses_logo.sql complete.';
GO
