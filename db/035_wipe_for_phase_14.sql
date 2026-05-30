/* ============================================================================
   ReceivingOps — 035_wipe_for_phase_14.sql  (Phase 14 — destructive)
   ----------------------------------------------------------------------------
   DESTRUCTIVE. Clears all transactional + planning data ahead of the
   Phase 14 vendor schema move (db/036). Locked decision Q1=C from the
   handoff: wipe and start clean; only dev env is in scope (no prod yet).

   WIPED (clears row data, keeps tables + indexes):
     dbo.Receipts            — append-only transactions
     dbo.PullItemWindows     — per-hour qty plan (FK to PullItems)
     dbo.PullItems           — items on each pull (FK to Pulls)
     dbo.Pulls               — receive plans
     dbo.PurchaseOrderLines  — PO line items (cascades from PO anyway)
     dbo.PurchaseOrders      — PO headers
     dbo.PoImportLog         — Phase 12 import run history
     dbo.ErpSyncLog          — Phase 10 + 13 ETL run history
     dbo.AuditLog            — all audit rows (operators see a fresh slate)

   KEPT (NOT wiped):
     dbo.AppSettings         — Phase 11 config (incl. encrypted secrets)
     dbo.Warehouses          — seed-time bootstrap
     dbo.Users               — operator accounts
     [HangFire].*            — recurring job schedule + retry state.
                               Wiping it would lose the ERP sync recurring
                               registration and force a /Config visit to
                               re-register. Not load-bearing for Phase 14.

   FK-safe deletion order (children → parents) so each DELETE never violates
   a foreign key:
     1. Receipts is special. The table has TWO self-ref FKs
        (ReversesReceiptId, ReversedById, both NO_ACTION) so a single-pass
        DELETE will violate whichever side gets processed first. The
        obvious workaround — null both columns before the delete — does
        not work because CK_Receipts_ReversalIntegrity (§7.10) requires
        a negative-qty row to keep ReversesReceiptId non-null.
        Resolution: temporarily disable every constraint on Receipts with
        NOCHECK CONSTRAINT ALL, DELETE, then re-enable WITH CHECK CHECK
        CONSTRAINT ALL. The post-wipe table is empty, so the re-enable
        revalidates trivially and the constraints' trusted state (used
        by the optimizer for view/query plans) is preserved.
     2. Receipts → PullItemWindows → PullItems
        (FK_Receipts_Item: Receipts → PullItems;
         FK_PIW_PullItem: PullItemWindows → PullItems;
         FK_PullItems_Pull: PullItems → Pulls — so PullItems must clear
         before Pulls, but POs also reference Pulls via FK_PO_Pull,
         so Pulls cannot drop until BOTH PullItems AND POs are gone.)
     3. PurchaseOrderLines → PurchaseOrders (POL cascades from PO via
        FK_POL_PurchaseOrder; explicit DELETE first is clearer in the
        audit trail and survives any future schema change that drops
        the cascade).
     4. Pulls — only after PullItems AND PurchaseOrders are empty,
        because both reference Pulls.Id (FK_PullItems_Pull and
        FK_PO_Pull respectively).
     5. PoImportLog, ErpSyncLog, AuditLog — leaves, no FK pressure
        from anything that we just wiped.

   Production guard:
     Hard-coded ServerName check. Aborts with RAISERROR if the script
     ever lands on a host other than the dev workstation. This is the
     belt; the brace is the human reviewer of the apply order. Bump
     the allowed name (or remove the gate) when the prod migration
     story is ready.

   Idempotent: a re-run is a no-op (every table is already empty).
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- Production guard.
------------------------------------------------------------------------------
DECLARE @ServerName SYSNAME = CAST(SERVERPROPERTY('ServerName') AS SYSNAME);
IF @ServerName <> N'LAPTOP-CSB3KO3E'
BEGIN
    RAISERROR('db/035 refuses to run on server %s. Phase 14 wipe is dev-only (LAPTOP-CSB3KO3E). Edit the allowed name in db/035 if intentional.', 16, 1, @ServerName);
    RETURN;
END
PRINT 'Pre-flight OK — running on dev (LAPTOP-CSB3KO3E).';
GO

------------------------------------------------------------------------------
-- Snapshot row counts before the wipe so the operator sees what got cleared.
------------------------------------------------------------------------------
PRINT '--- BEFORE ---';
SELECT 'Receipts'           AS TableName, COUNT(*) AS Rows FROM dbo.Receipts
UNION ALL SELECT 'PullItemWindows',     COUNT(*) FROM dbo.PullItemWindows
UNION ALL SELECT 'PullItems',           COUNT(*) FROM dbo.PullItems
UNION ALL SELECT 'Pulls',               COUNT(*) FROM dbo.Pulls
UNION ALL SELECT 'PurchaseOrderLines',  COUNT(*) FROM dbo.PurchaseOrderLines
UNION ALL SELECT 'PurchaseOrders',      COUNT(*) FROM dbo.PurchaseOrders
UNION ALL SELECT 'PoImportLog',         COUNT(*) FROM dbo.PoImportLog
UNION ALL SELECT 'ErpSyncLog',          COUNT(*) FROM dbo.ErpSyncLog
UNION ALL SELECT 'AuditLog',            COUNT(*) FROM dbo.AuditLog;
GO

------------------------------------------------------------------------------
-- Wipe in one transaction. Either all tables clear or none do.
------------------------------------------------------------------------------
BEGIN TRY
    BEGIN TRAN;

    -- 1. Suspend Receipts constraints so the bulk delete bypasses both
    --    self-ref FKs and the §7.10 CHECK. See header §1 for the rationale.
    PRINT 'Disabling Receipts constraints for bulk delete...';
    ALTER TABLE dbo.Receipts NOCHECK CONSTRAINT ALL;

    -- 2. Receive transactions + PullItem hierarchy.
    PRINT 'Deleting Receipts...';           DELETE FROM dbo.Receipts;
    PRINT 'Deleting PullItemWindows...';    DELETE FROM dbo.PullItemWindows;
    PRINT 'Deleting PullItems...';          DELETE FROM dbo.PullItems;

    -- 3. PO hierarchy (POL first; cascade is defensive but explicit is auditable).
    PRINT 'Deleting PurchaseOrderLines...'; DELETE FROM dbo.PurchaseOrderLines;
    PRINT 'Deleting PurchaseOrders...';     DELETE FROM dbo.PurchaseOrders;

    -- 4. Pulls — only safe now that both PullItems and POs are gone.
    PRINT 'Deleting Pulls...';              DELETE FROM dbo.Pulls;

    -- 5. Leaf logs.
    PRINT 'Deleting PoImportLog...';        DELETE FROM dbo.PoImportLog;
    PRINT 'Deleting ErpSyncLog...';         DELETE FROM dbo.ErpSyncLog;
    PRINT 'Deleting AuditLog...';           DELETE FROM dbo.AuditLog;

    -- 6. Re-arm Receipts constraints. WITH CHECK CHECK validates and
    --    restores the trusted state (empty table → trivially valid).
    PRINT 'Re-enabling Receipts constraints (WITH CHECK CHECK)...';
    ALTER TABLE dbo.Receipts WITH CHECK CHECK CONSTRAINT ALL;

    COMMIT TRAN;
    PRINT 'Wipe transaction committed.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRAN;
    DECLARE @ErrMsg NVARCHAR(2048) = ERROR_MESSAGE();
    RAISERROR('db/035 wipe rolled back: %s', 16, 1, @ErrMsg);
    RETURN;
END CATCH
GO

------------------------------------------------------------------------------
-- Verification — every wiped table should report 0; kept tables show > 0.
------------------------------------------------------------------------------
PRINT '--- AFTER ---';
SELECT 'Receipts'           AS TableName, COUNT(*) AS Rows FROM dbo.Receipts
UNION ALL SELECT 'PullItemWindows',     COUNT(*) FROM dbo.PullItemWindows
UNION ALL SELECT 'PullItems',           COUNT(*) FROM dbo.PullItems
UNION ALL SELECT 'Pulls',               COUNT(*) FROM dbo.Pulls
UNION ALL SELECT 'PurchaseOrderLines',  COUNT(*) FROM dbo.PurchaseOrderLines
UNION ALL SELECT 'PurchaseOrders',      COUNT(*) FROM dbo.PurchaseOrders
UNION ALL SELECT 'PoImportLog',         COUNT(*) FROM dbo.PoImportLog
UNION ALL SELECT 'ErpSyncLog',          COUNT(*) FROM dbo.ErpSyncLog
UNION ALL SELECT 'AuditLog',            COUNT(*) FROM dbo.AuditLog
UNION ALL SELECT 'AppSettings (kept)',  COUNT(*) FROM dbo.AppSettings
UNION ALL SELECT 'Warehouses (kept)',   COUNT(*) FROM dbo.Warehouses
UNION ALL SELECT 'Users (kept)',        COUNT(*) FROM dbo.Users;
GO

PRINT '035_wipe_for_phase_14.sql complete. Run db/036 next to move vendor to POL.';
GO
