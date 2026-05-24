/* ============================================================================
   ReceivingOps — 023_export_jobs_log_downloaded_at.sql
   ----------------------------------------------------------------------------
   Phase 8.4 ext — 2-tab My Exports (Pending / Downloaded).

   ADDITIVE, NON-BREAKING. Adds dbo.ExportJobsLog.DownloadedAt nullable
   column. The /Exports page splits the existing single list into two
   tabs:

     Pending     — anything the operator still needs to act on:
                   queued | running | failed | (succeeded AND
                   DownloadedAt IS NULL AND file still on disk)
     Downloaded  — succeeded AND DownloadedAt IS NOT NULL
                   (archive of jobs the user has explicitly grabbed)

   DownloadedAt is stamped server-side when the user clicks the
   Download button on the My Exports page (POST mark-downloaded).
   Intent-based: we record the click, not the byte transfer — far
   simpler and good enough for "did the operator see / grab this."

   Backfill: NONE. Pre-existing succeeded rows stay as Pending until
   the operator clicks Download (or they expire off disk). Rationale:
   we can't retroactively know which historic exports were grabbed
   from the email link vs ignored; leaving them in Pending lets the
   operator triage explicitly. The badge (db/022 ReadAt) handles the
   "don't flood operators day-1" concern in a different way already.

   Filtered index: IX_ExportJobsLog_UserPending narrows to
   (RequesterUserId) for succeeded-not-yet-downloaded rows — the
   dominant hot path (Pending tab query + tab-count badge). Filtered
   indexes are tiny because the predicate excludes the bulk of historic
   rows once they're downloaded.

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.ExportJobsLog', 'DownloadedAt') IS NULL
BEGIN
    PRINT 'Adding dbo.ExportJobsLog.DownloadedAt (DATETIME2 NULL)...';
    ALTER TABLE dbo.ExportJobsLog
        ADD DownloadedAt DATETIME2(0) NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_ExportJobsLog_UserPending'
      AND object_id = OBJECT_ID('dbo.ExportJobsLog')
)
BEGIN
    PRINT 'Creating IX_ExportJobsLog_UserPending (filtered: succeeded + not downloaded)...';
    CREATE NONCLUSTERED INDEX IX_ExportJobsLog_UserPending
        ON dbo.ExportJobsLog (RequesterUserId, EnqueuedAt DESC)
        INCLUDE (Status, JobType, FileName, RowsExported, DownloadedAt)
        WHERE Status = 'succeeded' AND DownloadedAt IS NULL;
END
GO

PRINT '023_export_jobs_log_downloaded_at.sql complete (Phase 8.4 ext — 2-tab).';
GO
