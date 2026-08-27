/* ============================================================================
   ReceivingOps — prod-hotfix-poimport-schema.sql
   ----------------------------------------------------------------------------
   PURPOSE
     Reconcile the PRODUCTION ReceivingOps database schema with what the
     deployed application binary (commit f314610) requires for the PO Excel
     import "confirm -> Stage 2 insert" path.

     Prod currently throws:
         SqlException 207 "Invalid column name 'PosSkipped' / 'SkippedPoNumbers'"
         at PoImportLogRepository.GetByRunIdAsync, called from
         PoImportController.Confirm.

     Root cause: schema migrations were applied to the local dev database but
     never applied to prod. The deployed code expects columns that several
     un-applied migrations added. This script applies ONLY the additive,
     non-breaking column/index changes the import path depends on.

   WHAT THIS SCRIPT COVERS  (every column the confirm + PoImportJob path
   reads or writes — so you don't fix one missing column and hit the next)

     dbo.PoImportLog        (db/046)  PosSkipped, SkippedPoNumbers
                                      -- the columns in the current error
     dbo.PurchaseOrders     (db/033)  PullExternalRef  (+ IX_PO_PullExternalRef)
     dbo.PurchaseOrderLines (db/021)  20 ERP fields (InvoiceNo..Note)
                            (db/031)  OrderId
                            (db/040)  SourcePoNo
                            (db/036)  VendorCode, VendorName (+ IX_POL_Vendor)
     dbo.AuditLog           (db/032)  widen ActionType VARCHAR(16) -> VARCHAR(32)
                                      -- 'po-import-confirmed' etc. are 19 chars

   DELIBERATELY EXCLUDED (see the summary the assistant provided)
     - db/036 steps 2a/2b (re-ALTER vw_TransactionsJournal +
       vw_PurchaseOrderAvailability to source vendor from POL) and
       db/036 step 4 (DROP PurchaseOrders.VendorCode/VendorName).
       Reason: the import path does not read those views, dropping columns
       violates the no-DROP posture, and the "old" views keep working because
       the PO-header vendor columns still exist. Complete the Phase 14 vendor
       move (full db/036) in a planned maintenance window, NOT this hotfix.

   SAFETY
     - Idempotent: every change is guarded (COL_LENGTH / sys.indexes). Re-running
       is a clean no-op.
     - ADD COLUMN only, all NULLable — metadata-only, no table rewrite, no data
       loss. No DROP / TRUNCATE / DELETE anywhere.
     - Single explicit transaction with TRY/CATCH + XACT_ABORT; any error rolls
       the WHOLE thing back and re-raises.
     - Aborts up front with a clear message if a required BASE table is missing
       (that would indicate deeper drift than this hotfix is scoped to fix).

   ----------------------------------------------------------------------------
   *** RUN A FULL BACKUP FIRST ***  (this line is COMMENTED OUT on purpose —
   review the path/edition options, then run it yourself before the hotfix):

   -- BACKUP DATABASE [ReceivingOps]
   --     TO DISK = N'C:\Backups\ReceivingOps_prehotfix_poimport.bak'
   --     WITH INIT, CHECKSUM, STATS = 10,
   --          NAME = N'ReceivingOps full backup before PO-import schema hotfix';
   -- GO

   RUN ORDER
     1. BACKUP DATABASE (the commented command above)
     2. db/verify-poimport-schema.sql        (see the drift BEFORE)
     3. db/prod-hotfix-poimport-schema.sql   (THIS script)
     4. db/verify-poimport-schema.sql        (confirm 0 missing AFTER)
     5. Browser: re-run the import and click Confirm -> expect HTTP 202
   ============================================================================ */

-- The six SET options a filtered-index CREATE requires, all ON, plus
-- NUMERIC_ROUNDABORT OFF. SSMS defaults these correctly; sqlcmd does not
-- (QUOTED_IDENTIFIER defaults OFF there) — so set them explicitly to make
-- step 3's filtered indexes create reliably under either client.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

SET XACT_ABORT ON;
GO

BEGIN TRY
    BEGIN TRANSACTION;

    ------------------------------------------------------------------------
    -- 0. Precondition: the BASE tables must already exist. This hotfix only
    --    adds columns/indexes; it does NOT create tables. A missing base
    --    table means prod is drifted further back than this hotfix covers
    --    (e.g. db/030 PoImportLog itself never ran) — stop and escalate.
    ------------------------------------------------------------------------
    DECLARE @missingTables NVARCHAR(1000) = N'';

    IF OBJECT_ID(N'dbo.PoImportLog',        N'U') IS NULL SET @missingTables += N'dbo.PoImportLog, ';
    IF OBJECT_ID(N'dbo.PurchaseOrders',     N'U') IS NULL SET @missingTables += N'dbo.PurchaseOrders, ';
    IF OBJECT_ID(N'dbo.PurchaseOrderLines', N'U') IS NULL SET @missingTables += N'dbo.PurchaseOrderLines, ';
    IF OBJECT_ID(N'dbo.AuditLog',           N'U') IS NULL SET @missingTables += N'dbo.AuditLog, ';

    IF LEN(@missingTables) > 0
    BEGIN
        DECLARE @msg NVARCHAR(1200) =
            N'ABORT: required base table(s) missing: '
            + LEFT(@missingTables, LEN(@missingTables) - 1)
            + N'. This hotfix only ADDS columns; run the base creation migration(s) first (e.g. db/030).';
        THROW 50001, @msg, 1;
    END

    ------------------------------------------------------------------------
    -- 1. Additive NULLable columns (metadata-only). Driven from an explicit
    --    manifest so a reviewer can eyeball the full (table, column, type)
    --    set at a glance. Each ADD is guarded by COL_LENGTH and executed via
    --    sp_executesql so a freshly-added column is never referenced at
    --    parse time.
    ------------------------------------------------------------------------
    DECLARE @Cols TABLE (
        Seq       INT IDENTITY(1,1) PRIMARY KEY,
        TableName SYSNAME,
        ColName   SYSNAME,
        ColType   NVARCHAR(50)   -- type only; ' NULL' is appended below
    );

    -- dbo.PoImportLog  (db/046 — the columns in the current prod error)
    INSERT INTO @Cols (TableName, ColName, ColType) VALUES
        (N'PoImportLog', N'PosSkipped',       N'INT'),
        (N'PoImportLog', N'SkippedPoNumbers', N'NVARCHAR(MAX)');

    -- dbo.PurchaseOrders  (db/033)
    INSERT INTO @Cols (TableName, ColName, ColType) VALUES
        (N'PurchaseOrders', N'PullExternalRef', N'NVARCHAR(50)');

    -- dbo.PurchaseOrderLines  (db/021 — 20 ERP-sourced fields)
    INSERT INTO @Cols (TableName, ColName, ColType) VALUES
        (N'PurchaseOrderLines', N'InvoiceNo',                N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'KanbanNo',                 N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'AsnNo',                    N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'PCCNo',                    N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'BatchNo',                  N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'ManufacturingControlNo',   N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'ManufacturingReferenceNo', N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'CustomerReferenceNo',      N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'ExportDeclarationNo',      N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'VendorItem',               N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'PalletId',                 N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'VmiPalletId',              N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'Location',                 N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'Building',                 N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'SubInventory',             N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'ToLocation',               N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'ProductionLine',           N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'OrderRound',               N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'DeliveryDate',             N'DATE'),
        (N'PurchaseOrderLines', N'Note',                     N'NVARCHAR(500)');

    -- dbo.PurchaseOrderLines  (db/031 OrderId, db/040 SourcePoNo, db/036 vendor)
    INSERT INTO @Cols (TableName, ColName, ColType) VALUES
        (N'PurchaseOrderLines', N'OrderId',    N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'SourcePoNo', N'NVARCHAR(50)'),
        (N'PurchaseOrderLines', N'VendorCode', N'VARCHAR(64)'),
        (N'PurchaseOrderLines', N'VendorName', N'NVARCHAR(160)');

    DECLARE @seq INT, @tbl SYSNAME, @col SYSNAME, @type NVARCHAR(50);
    DECLARE @sql NVARCHAR(MAX), @qualified NVARCHAR(300);
    DECLARE @added INT = 0, @already INT = 0;

    DECLARE col_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT Seq, TableName, ColName, ColType FROM @Cols ORDER BY Seq;
    OPEN col_cur;
    FETCH NEXT FROM col_cur INTO @seq, @tbl, @col, @type;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @qualified = N'dbo.' + @tbl;
        IF COL_LENGTH(@qualified, @col) IS NULL
        BEGIN
            SET @sql = N'ALTER TABLE ' + QUOTENAME(N'dbo') + N'.' + QUOTENAME(@tbl)
                     + N' ADD ' + QUOTENAME(@col) + N' ' + @type + N' NULL;';
            EXEC sys.sp_executesql @sql;
            PRINT N'  [ADD]  dbo.' + @tbl + N'.' + @col + N' ' + @type + N' NULL';
            SET @added += 1;
        END
        ELSE
        BEGIN
            PRINT N'  [skip] dbo.' + @tbl + N'.' + @col + N' already exists';
            SET @already += 1;
        END
        FETCH NEXT FROM col_cur INTO @seq, @tbl, @col, @type;
    END
    CLOSE col_cur;
    DEALLOCATE col_cur;

    ------------------------------------------------------------------------
    -- 2. dbo.AuditLog.ActionType widen VARCHAR(16) -> VARCHAR(32)  (db/032)
    --    The import path writes 'po-import-confirmed' (19), 'po-import-
    --    succeeded' (19), 'po-import-partial' (17). Under a 16-char column
    --    these INSERTs raise 2628 and IAuditService swallows them, leaving a
    --    broken audit trail. COL_LENGTH is the byte length = declared length
    --    for VARCHAR, so < 32 catches the original 16 and any narrower widen.
    ------------------------------------------------------------------------
    IF COL_LENGTH(N'dbo.AuditLog', N'ActionType') < 32
    BEGIN
        EXEC sys.sp_executesql
            N'ALTER TABLE dbo.AuditLog ALTER COLUMN ActionType VARCHAR(32) NOT NULL;';
        PRINT N'  [ALTER] dbo.AuditLog.ActionType widened to VARCHAR(32) NOT NULL';
    END
    ELSE
    BEGIN
        PRINT N'  [skip]  dbo.AuditLog.ActionType already >= VARCHAR(32)';
    END

    ------------------------------------------------------------------------
    -- 3. Supporting filtered indexes (schema fidelity with db/033 + db/036).
    --    NOT required for the import to SUCCEED — they optimize the receive
    --    FIFO scan and the DO vendor grouping. Both are filtered WHERE NOT
    --    NULL, so on freshly-added (all-NULL) columns they are essentially
    --    empty and create instantly. Executed via sp_executesql because they
    --    reference columns that may have been added in step 1 above.
    ------------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM sys.indexes
        WHERE name = N'IX_PO_PullExternalRef'
          AND object_id = OBJECT_ID(N'dbo.PurchaseOrders'))
    BEGIN
        EXEC sys.sp_executesql
            N'CREATE INDEX IX_PO_PullExternalRef
                  ON dbo.PurchaseOrders (WarehouseId, PullExternalRef)
                  WHERE PullExternalRef IS NOT NULL;';
        PRINT N'  [INDEX] created IX_PO_PullExternalRef';
    END
    ELSE
    BEGIN
        PRINT N'  [skip]  IX_PO_PullExternalRef already exists';
    END

    IF NOT EXISTS (
        SELECT 1 FROM sys.indexes
        WHERE name = N'IX_POL_Vendor'
          AND object_id = OBJECT_ID(N'dbo.PurchaseOrderLines'))
    BEGIN
        EXEC sys.sp_executesql
            N'CREATE INDEX IX_POL_Vendor
                  ON dbo.PurchaseOrderLines (VendorCode)
                  WHERE VendorCode IS NOT NULL;';
        PRINT N'  [INDEX] created IX_POL_Vendor';
    END
    ELSE
    BEGIN
        PRINT N'  [skip]  IX_POL_Vendor already exists';
    END

    COMMIT TRANSACTION;

    PRINT N'============================================================';
    PRINT N'SUCCESS: PO-import schema hotfix committed.';
    PRINT N'  Columns added this run : ' + CAST(@added   AS NVARCHAR(10));
    PRINT N'  Columns already present: ' + CAST(@already AS NVARCHAR(10));
    PRINT N'Next: run db/verify-poimport-schema.sql, then test Confirm -> 202.';
    PRINT N'============================================================';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    PRINT N'============================================================';
    PRINT N'FAILED: hotfix rolled back — NO changes were applied.';
    PRINT N'  Error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10))
        + N' line ' + CAST(ERROR_LINE() AS NVARCHAR(10))
        + N': ' + ERROR_MESSAGE();
    PRINT N'============================================================';

    THROW;  -- re-raise so SSMS/sqlcmd reports a non-zero result
END CATCH;
GO
