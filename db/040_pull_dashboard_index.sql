/* ============================================================================
   ReceivingOps — 040_pull_dashboard_index.sql  (Pull Controller dashboard paging)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. One non-clustered index to support the paginated
   Pull Controller dashboard (GET /api/pulls → QueryDashboardAsync).

   WHY
   ---
   The dashboard's heaviest case is an admin viewing "All warehouses" over a
   date range. That path filters/sorts on PullDate with NO leading WarehouseId,
   so the existing IX_Pulls_WhDate (WarehouseId, PullDate) cannot seek — the
   optimizer clustered-index-scans dbo.Pulls for both the 20-row page slice
   (ORDER BY PullDate DESC) and the full-set COUNT/SUM aggregate tiles.

   IX_Pulls_Date leads with PullDate DESC so the date-range seek + the
   ORDER BY PullDate DESC, PullNumber DESC page slice are both served directly.
   Warehouse-scoped (non-admin) queries keep using IX_Pulls_WhDate.

   INCLUDE LIST — matched to the QueryDashboardAsync predicate/sort set:
     - WarehouseId   : non-admin id-force predicate (p.WarehouseId = @WarehouseId)
     - Status        : the CASE WHEN status = ... tile/column SUMs
     - LockPoByPull  : §3.5 lock filter predicate (p.LockPoByPull = @Lock)
     - PullNumber    : ORDER BY tiebreaker (UNIQUE → stable OFFSET paging) + search
   These four are every dbo.Pulls column the driving scan touches for the
   aggregate and the page ordering, so the aggregate is covered (no heap/CX
   lookups for the counters). The 20 page rows still do lookups for the wider
   SummarySelect projection — acceptable at 20 rows.

   Warehouse filter-by-CODE (admin) and the operator search term hit
   dbo.Warehouses / dbo.Users via joins, not dbo.Pulls, so they are not
   (and cannot be) part of this index.

   EDITION / ONLINE — reviewer decision, NOT assumed here:
     Run  SELECT SERVERPROPERTY('Edition'), SERVERPROPERTY('ProductVersion');
     - Standard: leave this file as-is. The CREATE takes a schema-modify lock
       on dbo.Pulls for the duration of the build — apply in a maintenance
       window.
     - Enterprise: the ", ONLINE = ON" line in the WITH clause below is ENABLED
       so the build does not block readers/writers on dbo.Pulls.
   Prod confirmed Enterprise (16.0.1000.6) → ONLINE = ON is active below.

   Idempotent — safe to re-run. Read-only reviewers: this file has NOT been
   executed against any database; apply it manually after review.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

-- ---------- IX_Pulls_Date (PullDate-leading, covering INCLUDE) ----------
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Pulls_Date'
      AND object_id = OBJECT_ID('dbo.Pulls')
)
BEGIN
    PRINT 'Creating IX_Pulls_Date (PullDate DESC) INCLUDE (WarehouseId, Status, LockPoByPull, PullNumber)...';
    CREATE NONCLUSTERED INDEX IX_Pulls_Date
        ON dbo.Pulls (PullDate DESC)
        INCLUDE (WarehouseId, Status, LockPoByPull, PullNumber)
        WITH (
            FILLFACTOR = 90
            , ONLINE = ON   -- ENTERPRISE ONLY (confirmed prod: SQL Server 2022 Enterprise 16.0.1000.6) — builds without locking dbo.Pulls
        )
        ON [PRIMARY];
END
ELSE
    PRINT 'IX_Pulls_Date already exists — skipping.';
GO

PRINT '040_pull_dashboard_index.sql complete (Pull Controller dashboard paging).';
GO
