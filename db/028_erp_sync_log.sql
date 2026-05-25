/* ============================================================================
   ReceivingOps — 028_erp_sync_log.sql  (Phase 10.6 — sync history page)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Creates dbo.ErpSyncLog — the operator-visible
   trail for every ErpSyncJob fire (recurring or manual).

   Parallel to dbo.ExportJobsLog from Phase 8.5. Same lifecycle pattern:
     INSERT at run-start (Status='running')
     UPDATE at run-end   (Status='succeeded', totals, CompletedAt)
     UPDATE on failure   (Status='failed', ErrorMessage, CompletedAt)

   Why a denormalized side-table when 10.5 already writes per-pull rows
   into dbo.AuditLog:
     - Audit row grouping by runId requires Message LIKE '%[run <guid>]%'
       — fine for occasional drill-down, painful for the paginated list.
     - The status page query is "give me the last N runs with their
       totals". A summary table answers that with a single index seek.
     - Per-pull rows in AuditLog stay the detailed view (10.6 drill-down
       page reads them via JOIN on the runId).

   Status state machine:
     running     -> InsertStartAsync
     succeeded   -> MarkSucceededAsync
     failed      -> MarkFailedAsync (catastrophic; per-pull errors live
                                     in AuditLog and increment Errors)

   Index design:
     PK on RunId — natural identifier; matches the Guid stamped into
     AuditLog messages so a drill-down JOINs cheaply.
     IX_ErpSyncLog_StartedAt (DESC) covers the dominant list query.

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.tables WHERE name = 'ErpSyncLog' AND schema_id = SCHEMA_ID('dbo')
)
BEGIN
    PRINT 'Creating dbo.ErpSyncLog...';
    CREATE TABLE dbo.ErpSyncLog
    (
        RunId               UNIQUEIDENTIFIER NOT NULL
            CONSTRAINT PK_ErpSyncLog PRIMARY KEY,
        -- Trigger source: 'recurring' or 'manual'. Short fixed set.
        TriggeredBy         VARCHAR(16)      NOT NULL,
        -- Operator display name ('[system]' for recurring); the actor
        -- field on the corresponding AuditLog rows matches this.
        ActorName           NVARCHAR(160)    NOT NULL,
        -- Target warehouse + backfill window captured at start.
        WarehouseId         UNIQUEIDENTIFIER NOT NULL,
        BackfillDays        INT              NOT NULL,
        Status              VARCHAR(16)      NOT NULL,  -- running|succeeded|failed
        StartedAt           DATETIME2(0)     NOT NULL CONSTRAINT DF_ErpSyncLog_StartedAt DEFAULT SYSUTCDATETIME(),
        CompletedAt         DATETIME2(0)     NULL,
        ElapsedMs           INT              NULL,
        -- Aggregated counters from ErpUpsertResult. NULL while running.
        SourceRowCount      INT              NULL,
        DraftPullCount      INT              NULL,
        Created             INT              NULL,
        Updated             INT              NULL,
        SkippedClosed       INT              NULL,
        Errors              INT              NULL,
        ItemsAdded          INT              NULL,
        ItemsCanceled       INT              NULL,
        -- Catastrophic-error detail (per-pull errors live in AuditLog).
        ErrorMessage        NVARCHAR(2000)   NULL
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_ErpSyncLog_StartedAt'
      AND object_id = OBJECT_ID('dbo.ErpSyncLog')
)
BEGIN
    PRINT 'Creating IX_ErpSyncLog_StartedAt (StartedAt DESC)...';
    CREATE NONCLUSTERED INDEX IX_ErpSyncLog_StartedAt
        ON dbo.ErpSyncLog (StartedAt DESC)
        INCLUDE (Status, TriggeredBy, ActorName, WarehouseId,
                 Created, Updated, SkippedClosed, Errors);
END
GO

PRINT '028_erp_sync_log.sql complete (Phase 10.6).';
GO
