/* ============================================================================
   ReceivingOps — 024_pull_items_extended_fields.sql  (Phase 9.1 — PullItem ERP)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. 7 nullable NVARCHAR(50) columns on dbo.PullItems —
   destinations for ERP-sourced PullItem metadata used by the production team
   when receiving against this pull.

   Unlike Phase 9's PurchaseOrderLines fields (db/021) which are display-only
   and ERP-write-through, these PullItem fields ARE editable in-app: the
   operator (admin or supervisor) can fill them in when the ERP push hasn't
   reached us yet. The upcoming Phase 10 ERP integration will populate them
   automatically on push.

   Fields:
     ProductFamily      — product family / category code
     FromSubInventory   — source sub-inventory the parts move out of
     ToSubInventory     — destination sub-inventory after the receive
     SpecialControl     — flag for hazmat / restricted / customer-controlled
     TrailId            — internal trail / movement identifier
     Location           — physical staging/storage location for this pull item
     Phase              — production phase / build stage tag

   No indexes. Search/filter on these is not in scope; no query patterns to
   inform index design. Add later when usage warrants (matches the policy
   we used for db/021).

   Idempotent — re-run safe via per-column COL_LENGTH guard.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.PullItems', 'ProductFamily') IS NULL
BEGIN
    PRINT 'Adding PullItems.ProductFamily...';
    ALTER TABLE dbo.PullItems ADD ProductFamily NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PullItems', 'FromSubInventory') IS NULL
BEGIN
    PRINT 'Adding PullItems.FromSubInventory...';
    ALTER TABLE dbo.PullItems ADD FromSubInventory NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PullItems', 'ToSubInventory') IS NULL
BEGIN
    PRINT 'Adding PullItems.ToSubInventory...';
    ALTER TABLE dbo.PullItems ADD ToSubInventory NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PullItems', 'SpecialControl') IS NULL
BEGIN
    PRINT 'Adding PullItems.SpecialControl...';
    ALTER TABLE dbo.PullItems ADD SpecialControl NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PullItems', 'TrailId') IS NULL
BEGIN
    PRINT 'Adding PullItems.TrailId...';
    ALTER TABLE dbo.PullItems ADD TrailId NVARCHAR(50) NULL;
END
GO

IF COL_LENGTH('dbo.PullItems', 'Location') IS NULL
BEGIN
    PRINT 'Adding PullItems.Location...';
    ALTER TABLE dbo.PullItems ADD Location NVARCHAR(50) NULL;
END
GO

-- "Phase" is not strictly a SQL reserved word but is heavily used as a keyword
-- in CDC / dynamic-PIVOT contexts; bracket-escaping in DDL is the safer
-- convention and stays consistent across migrations.
IF COL_LENGTH('dbo.PullItems', 'Phase') IS NULL
BEGIN
    PRINT 'Adding PullItems.[Phase]...';
    ALTER TABLE dbo.PullItems ADD [Phase] NVARCHAR(50) NULL;
END
GO

PRINT '024_pull_items_extended_fields.sql complete (Phase 9.1 — 7 ERP-sourced PullItem fields).';
GO
