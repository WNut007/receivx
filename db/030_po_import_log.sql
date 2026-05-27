/* ============================================================================
   ReceivingOps — 030_po_import_log.sql  (Phase 12.1 — PO Excel import)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Creates dbo.PoImportLog — the operator-visible
   trail for every PO Excel import job (Phase 12).

   Parallel to dbo.ExportJobsLog (Phase 8.5) + dbo.ErpSyncLog (Phase 10.6).
   Same lifecycle pattern: a row is INSERTed at upload, then UPDATEd through
   the Hangfire job state machine.

   Status state machine:
     validating         -> file received, pre-flight parser running
     validation_failed  -> Stage 1 rejected the file (bad rows / dup PoNumbers)
     validated          -> Stage 1 passed; awaiting operator confirm
     queued             -> operator confirmed; Hangfire enqueued
     running            -> Hangfire worker started RunAsync
     succeeded          -> atomic insert tx committed
     failed             -> catastrophic error (re-validation or DB error)

   Why a denormalized side-table when per-row issues could live in AuditLog:
     - The /Imports list is "give me the last N imports with their totals".
       A summary table answers that with one index seek.
     - ValidationErrors is JSON so the detail page can render the row list
       without a separate child table.
     - Per-row mutations (the inserts themselves) still go through
       IAuditService for the standard who-did-what trail.

   Index design:
     PK on RunId (clustered) — natural identifier; matches the GUID that
     the Hangfire job ID + audit messages carry.
     IX_PoImportLog_SubmittedAt (DESC) covers the dominant list query.
     IX_PoImportLog_WarehouseId_Submitted covers warehouse-scoped lists
       (supervisor/operator view).
     IX_PoImportLog_Status_Submitted covers status filters + auto-refresh
       polling for in-flight jobs.

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.tables WHERE name = 'PoImportLog' AND schema_id = SCHEMA_ID('dbo')
)
BEGIN
    PRINT 'Creating dbo.PoImportLog...';
    CREATE TABLE dbo.PoImportLog
    (
        RunId                  UNIQUEIDENTIFIER NOT NULL
            CONSTRAINT PK_PoImportLog PRIMARY KEY
            CONSTRAINT DF_PoImportLog_RunId DEFAULT NEWID(),
        -- Uploader identity (captured at submit, since worker thread loses HttpContext)
        UploadedBy             NVARCHAR(160)    NOT NULL,
        UploadedByUserId       UNIQUEIDENTIFIER NOT NULL,
        UploadedByRole         NVARCHAR(50)     NOT NULL,
        -- Target warehouse (from logged-in user; spec forbids file-supplied WH)
        WarehouseId            UNIQUEIDENTIFIER NOT NULL,
        -- File metadata
        FileName               NVARCHAR(255)    NOT NULL,
        FileSizeBytes          BIGINT           NOT NULL,
        StoragePath            NVARCHAR(500)    NOT NULL,
        Status                 NVARCHAR(20)     NOT NULL
            CONSTRAINT DF_PoImportLog_Status DEFAULT 'queued',
        -- Lifecycle timestamps
        SubmittedAt            DATETIME2(0)     NOT NULL
            CONSTRAINT DF_PoImportLog_SubmittedAt DEFAULT SYSUTCDATETIME(),
        StartedAt              DATETIME2(0)     NULL,
        CompletedAt            DATETIME2(0)     NULL,
        ElapsedMs              INT              NULL,
        -- Stage 1 (pre-flight validation) results
        TotalRowsRead          INT              NULL,
        ValidationErrorCount   INT              NULL,
        ValidationErrors       NVARCHAR(MAX)    NULL,  -- JSON array
        -- Stage 2 (atomic insert) results — only set on Status='succeeded'
        PosInserted            INT              NULL,
        LinesInserted          INT              NULL,
        -- Catastrophic-error detail (per-row issues live in ValidationErrors)
        ErrorMessage           NVARCHAR(MAX)    NULL,
        -- Cross-ref to Hangfire's own job ID for dashboard drill-down
        HangfireJobId          NVARCHAR(50)     NULL
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_PoImportLog_SubmittedAt'
      AND object_id = OBJECT_ID('dbo.PoImportLog')
)
BEGIN
    PRINT 'Creating IX_PoImportLog_SubmittedAt (SubmittedAt DESC)...';
    CREATE NONCLUSTERED INDEX IX_PoImportLog_SubmittedAt
        ON dbo.PoImportLog (SubmittedAt DESC);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_PoImportLog_WarehouseId_Submitted'
      AND object_id = OBJECT_ID('dbo.PoImportLog')
)
BEGIN
    PRINT 'Creating IX_PoImportLog_WarehouseId_Submitted (WarehouseId, SubmittedAt DESC)...';
    CREATE NONCLUSTERED INDEX IX_PoImportLog_WarehouseId_Submitted
        ON dbo.PoImportLog (WarehouseId, SubmittedAt DESC);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_PoImportLog_Status_Submitted'
      AND object_id = OBJECT_ID('dbo.PoImportLog')
)
BEGIN
    PRINT 'Creating IX_PoImportLog_Status_Submitted (Status, SubmittedAt DESC)...';
    CREATE NONCLUSTERED INDEX IX_PoImportLog_Status_Submitted
        ON dbo.PoImportLog (Status, SubmittedAt DESC);
END
GO

PRINT '030_po_import_log.sql complete (Phase 12.1).';
GO
