/* ============================================================================
   ReceivingOps — 022_export_jobs_log_read_at.sql  (Phase 8.5+ — nav badge)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Adds dbo.ExportJobsLog.ReadAt nullable column,
   used by the nav-bar badge counter that surfaces unread completed
   exports.

   Backfill: every existing Status='succeeded' row is marked read
   (ReadAt = COALESCE(CompletedAt, now)). Without this, every operator
   would log in to a flood of "you have N unread exports" pointing at
   files they may have already grabbed via the email link. The badge
   is meant to flag NEW completions post-deploy.

   Status value is 'succeeded' (Phase 8.4 naming), NOT 'completed'.

   Note: db/021 was reserved by the handoff for Phase 9 (PurchaseOrderLines
   ERP fields). This migration takes db/022 to stay out of its way.

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.ExportJobsLog', 'ReadAt') IS NULL
BEGIN
    PRINT 'Adding dbo.ExportJobsLog.ReadAt (DATETIME2 NULL)...';
    ALTER TABLE dbo.ExportJobsLog
        ADD ReadAt DATETIME2(0) NULL;
END
GO

-- Backfill historical succeeded rows so the badge doesn't show a giant
-- number for every operator the first time they log in after this deploy.
-- Re-runnable: the WHERE ReadAt IS NULL guard means this only touches rows
-- that weren't marked on a prior run.
UPDATE dbo.ExportJobsLog
SET    ReadAt = COALESCE(CompletedAt, SYSUTCDATETIME())
WHERE  Status = 'succeeded' AND ReadAt IS NULL;
GO

PRINT '022_export_jobs_log_read_at.sql complete (Phase 8.5+ badge).';
GO
