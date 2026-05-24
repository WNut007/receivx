/* ============================================================================
   ReceivingOps — 020_export_jobs_log.sql  (Phase 8.5 — My Exports page)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Creates dbo.ExportJobsLog — the operator-visible
   trail for every Hangfire export job enqueued via ExportService.

   Why a separate table when Hangfire already has [HangFire].[Job]:
     - Hangfire's job state is the framework's concern (worker visibility,
       retries, dashboard). The operator needs different shape: who asked,
       what filter, what file, did it succeed, can I download it again.
     - Hangfire prunes Succeeded jobs by default after ~1 day; we want a
       longer trail for the My Exports list.
     - Cleanest privacy boundary: per-user scoping at the controller is
       a simple WHERE on RequesterUserId; doing the same against
       Hangfire's internal job payload would be fragile.

   PK = Id is the export jobId the service generates up-front (Guid). Same
   value goes into the file path (transactions-{jobId}.xlsx) and the
   signed download URL. Hangfire retries overwrite the same log row's
   Status/StartedAt/CompletedAt — no row-per-attempt.

   Status state machine:
     queued     → set on InsertQueued (service.Enqueue* hand-off)
     running    → set on UpdateRunning (job's first action in RunAsync)
     succeeded  → set on UpdateSucceeded after file + email
     failed     → set on UpdateFailed in the job's catch block
     expired    → controller-side derived state when file no longer on disk
                  (file lifetime = ExportOptions.FileLifetime, default 24h);
                  NOT a row update — we just present succeeded jobs whose
                  files are gone as expired in the API response.

   Index design:
     PK on Id covers the "look up a specific job by id" path (download
     button on the My Exports list).
     IX_ExportJobsLog_UserDate on (RequesterUserId, EnqueuedAt DESC)
     covers the dominant list query — "show me my recent exports".

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.tables WHERE name = 'ExportJobsLog' AND schema_id = SCHEMA_ID('dbo')
)
BEGIN
    PRINT 'Creating dbo.ExportJobsLog...';
    CREATE TABLE dbo.ExportJobsLog
    (
        Id              UNIQUEIDENTIFIER NOT NULL
            CONSTRAINT PK_ExportJobsLog PRIMARY KEY,
        RequesterUserId UNIQUEIDENTIFIER NOT NULL,
        RequesterEmail  NVARCHAR(160)    NOT NULL,
        RequesterName   NVARCHAR(120)    NOT NULL,
        JobType         VARCHAR(32)      NOT NULL,    -- 'transactions' | 'pos' | 'audit-log'
        FilterJson      NVARCHAR(MAX)    NULL,        -- snapshot for "what was filtered"
        Status          VARCHAR(16)      NOT NULL,    -- 'queued' | 'running' | 'succeeded' | 'failed'
        EnqueuedAt      DATETIME2(0)     NOT NULL CONSTRAINT DF_ExportJobsLog_EnqueuedAt DEFAULT SYSUTCDATETIME(),
        StartedAt       DATETIME2(0)     NULL,
        CompletedAt     DATETIME2(0)     NULL,
        FileName        NVARCHAR(256)    NULL,
        RowsExported        INT              NULL,
        ErrorMessage    NVARCHAR(2000)   NULL
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_ExportJobsLog_UserDate'
      AND object_id = OBJECT_ID('dbo.ExportJobsLog')
)
BEGIN
    PRINT 'Creating IX_ExportJobsLog_UserDate (RequesterUserId, EnqueuedAt DESC)...';
    CREATE NONCLUSTERED INDEX IX_ExportJobsLog_UserDate
        ON dbo.ExportJobsLog (RequesterUserId, EnqueuedAt DESC)
        INCLUDE (JobType, Status, FileName, RowsExported);
END
GO

PRINT '020_export_jobs_log.sql complete (Phase 8.5).';
GO
