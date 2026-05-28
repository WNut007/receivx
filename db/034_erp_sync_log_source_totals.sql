/* ============================================================================
   ReceivingOps — 034_erp_sync_log_source_totals.sql  (Phase 13.1 — dual-source ERP)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Adds dbo.ErpSyncLog.SourceTotals (NVARCHAR(MAX) NULL).

   Phase 13 introduces a second ERP source table (PRB_PRS) alongside the
   existing BPI_PRS reader. A single ErpSyncJob fire now iterates the
   enabled sources serially under one mutex acquisition + one RunId.
   The existing scalar columns (Created/Updated/SkippedClosed/Errors/etc.)
   become the aggregate ACROSS sources — keeps backwards-compat with the
   v3.2 status page query shape unchanged.

   SourceTotals is the per-source breakdown stored as a small JSON blob,
   e.g. {"BPI_PRS":{"created":3,"updated":12,"skipped":0,"errors":0,"itemsAdded":2,"itemsCanceled":1},"PRB_PRS":{...}}
   Status-page drill-down renders the per-source split; consumers that
   want the cumulative numbers keep using the scalar columns.

   Why a single JSON column instead of new scalar columns or a child table:
     - Scalar columns × 2 sources × 8 counters = 16 new columns; doubles
       on every future source. JSON is one column, one schema change.
     - Child table is overkill — totals are read together with the parent
       row 100% of the time; no query benefits from normalization.
     - SQL Server's JSON support (OPENJSON, JSON_VALUE) is good enough
       for the rare ad-hoc query; the typical UI path just deserializes
       in C#.

   Idempotent — COL_LENGTH guard. Safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.ErpSyncLog', 'SourceTotals') IS NULL
BEGIN
    PRINT 'Adding ErpSyncLog.SourceTotals (NVARCHAR(MAX) NULL)...';
    ALTER TABLE dbo.ErpSyncLog ADD SourceTotals NVARCHAR(MAX) NULL;
END
ELSE
BEGIN
    PRINT 'ErpSyncLog.SourceTotals already exists — no change.';
END
GO

PRINT '034_erp_sync_log_source_totals.sql complete (Phase 13.1).';
GO
