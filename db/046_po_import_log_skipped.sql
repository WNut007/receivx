/* ============================================================================
   ReceivingOps — 046_po_import_log_skipped.sql  (PO import: skip duplicates)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Two nullable columns on dbo.PoImportLog:
     PosSkipped       INT NULL
     SkippedPoNumbers NVARCHAR(MAX) NULL   -- JSON array of PoNumber strings

   Stage 2 (PoImportJob) previously wrapped every PO in the file in ONE
   transaction and rolled the whole thing back if any PoNumber already
   existed in dbo.PurchaseOrders — one duplicate row meant zero imports.
   The new behavior imports the new POs and skips only the duplicates, so
   the log row needs to report the difference between "how many landed"
   (PosInserted, existing) and "how many were already here" (PosSkipped).

   Duplicate grain is the PoNumber GROUP, not the SKU line — a skipped
   PoNumber means the existing PO was left completely untouched. There is
   no upsert-into-existing-PO path, so SkippedPoNumbers is a complete
   description of what the run declined to do.

   Why JSON instead of a child table (same reasoning as db/034):
     - The list is read together with the parent row 100% of the time;
       nothing queries skipped PoNumbers independently.
     - Bounded by the file's distinct PoNumber count; the operator's
       status panel renders the list verbatim.

   NULL semantics: rows written before this migration keep NULL, which
   reads as "ran before skip-tracking existed" — deliberately distinct
   from 0 ("this run skipped nothing"). Do NOT backfill to 0; that would
   assert something about historical runs that we cannot know.

   State machine UNCHANGED — a run with skips is still 'succeeded'. The
   counts express the difference; no new status value.

   Idempotent — per-column COL_LENGTH guard. Safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.PoImportLog', 'PosSkipped') IS NULL
BEGIN
    PRINT 'Adding PoImportLog.PosSkipped (INT NULL)...';
    ALTER TABLE dbo.PoImportLog ADD PosSkipped INT NULL;
END
ELSE
BEGIN
    PRINT 'PoImportLog.PosSkipped already exists — no change.';
END
GO

IF COL_LENGTH('dbo.PoImportLog', 'SkippedPoNumbers') IS NULL
BEGIN
    PRINT 'Adding PoImportLog.SkippedPoNumbers (NVARCHAR(MAX) NULL)...';
    ALTER TABLE dbo.PoImportLog ADD SkippedPoNumbers NVARCHAR(MAX) NULL;
END
ELSE
BEGIN
    PRINT 'PoImportLog.SkippedPoNumbers already exists — no change.';
END
GO

PRINT '046_po_import_log_skipped.sql complete (PO import: skip duplicates).';
GO
