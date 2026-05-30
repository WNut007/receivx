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
     1. Receipts has TWO self-ref FKs — ReversesReceiptId AND ReversedById,
        both NO_ACTION. A reversal row points its ReversesReceiptId at the
        original; the original carries ReversedById pointing back at the
        reversal. A single-pass DELETE FROM Receipts processes rows in an
        undefined order — whichever side is processed first will violate
        the still-live FK from its pair. Both columns must be nulled
        before the row delete.
     2. Receipts → PullItemWindows → PullItems → Pulls
     3. PurchaseOrderLines → PurchaseOrders (POL also cascades from PO
        per FK_POL_PurchaseOrder; explicit DELETE first is clearer in
        the audit trail and survives any future schema change that
        drops the cascade).
     4. PoImportLog, ErpSyncLog, AuditLog — leaves, no FK pressure.

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
    RAISERROR(
        'db/035 refuses to run on server %s. Phase 14 wipe is dev-only (LAPTOP-CSB3KO3E). '
        + 'Edit the allowed name in db/035 if intentional.',
        16, 1, @ServerName);
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

    -- 1. Break both Receipts self-refs so the row delete can proceed.
    --    See header §1 for why both columns must be nulled.
    PRINT 'Nulling Receipts self-ref FKs (ReversesReceiptId + ReversedById)...';
    UPDATE dbo.Receipts SET ReversesReceiptId = NULL WHERE ReversesReceiptId IS NOT NULL;
    UPDATE dbo.Receipts SET ReversedById     = NULL WHERE ReversedById     IS NOT NULL;

    -- 2. Receive transactions + planning hierarchy.
    PRINT 'Deleting Receipts...';           DELETE FROM dbo.Receipts;
    PRINT 'Deleting PullItemWindows...';    DELETE FROM dbo.PullItemWindows;
    PRINT 'Deleting PullItems...';          DELETE FROM dbo.PullItems;
    PRINT 'Deleting Pulls...';              DELETE FROM dbo.Pulls;

    -- 3. PO hierarchy (POL first; cascade is defensive but explicit is auditable).
    PRINT 'Deleting PurchaseOrderLines...'; DELETE FROM dbo.PurchaseOrderLines;
    PRINT 'Deleting PurchaseOrders...';     DELETE FROM dbo.PurchaseOrders;

    -- 4. Leaf logs.
    PRINT 'Deleting PoImportLog...';        DELETE FROM dbo.PoImportLog;
    PRINT 'Deleting ErpSyncLog...';         DELETE FROM dbo.ErpSyncLog;
    PRINT 'Deleting AuditLog...';           DELETE FROM dbo.AuditLog;

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
