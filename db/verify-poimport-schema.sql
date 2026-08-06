/* ============================================================================
   ReceivingOps — verify-poimport-schema.sql   (READ-ONLY)
   ----------------------------------------------------------------------------
   Reports whether every column / index the PO-import "confirm -> Stage 2
   insert" path (deployed commit f314610) depends on is present on this
   database. Run it BEFORE the hotfix to see the drift, and AFTER to confirm
   zero remaining gaps.

   READ-ONLY: only SELECTs INFORMATION_SCHEMA / sys catalog views. Makes NO
   changes. Safe to run against production any number of times.

   Interpreting the output:
     Result set 1  Columns   — one row per expected column; Status = OK |
                               MISSING | TYPE-MISMATCH (info only — the hotfix
                               only ADDs, it never re-types an existing column).
     Result set 2  Indexes   — supporting filtered indexes (fidelity, not
                               correctness-critical).
     Result set 3  ActionType width — AuditLog.ActionType must be >= 32.
     Final PRINT   — PASS (0 missing) or FAIL (n missing) headline.
   ============================================================================ */

SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- Expected column manifest (must match db/prod-hotfix-poimport-schema.sql).
------------------------------------------------------------------------------
DECLARE @Expected TABLE (
    TableName    SYSNAME,
    ColName      SYSNAME,
    ExpectedType NVARCHAR(50),   -- friendly form, e.g. NVARCHAR(50), NVARCHAR(MAX), DATE
    Source       NVARCHAR(20)
);

INSERT INTO @Expected (TableName, ColName, ExpectedType, Source) VALUES
    -- dbo.PoImportLog (db/046) — the columns in the current prod error
    (N'PoImportLog', N'PosSkipped',       N'INT',           N'db/046'),
    (N'PoImportLog', N'SkippedPoNumbers', N'NVARCHAR(MAX)', N'db/046'),
    -- dbo.PurchaseOrders (db/033)
    (N'PurchaseOrders', N'PullExternalRef', N'NVARCHAR(50)', N'db/033'),
    -- dbo.PurchaseOrderLines (db/021 — 20 ERP fields)
    (N'PurchaseOrderLines', N'InvoiceNo',                N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'KanbanNo',                 N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'AsnNo',                    N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'PCCNo',                    N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'BatchNo',                  N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'ManufacturingControlNo',   N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'ManufacturingReferenceNo', N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'CustomerReferenceNo',      N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'ExportDeclarationNo',      N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'VendorItem',               N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'PalletId',                 N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'VmiPalletId',              N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'Location',                 N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'Building',                 N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'SubInventory',             N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'ToLocation',               N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'ProductionLine',           N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'OrderRound',               N'NVARCHAR(50)',  N'db/021'),
    (N'PurchaseOrderLines', N'DeliveryDate',             N'DATE',          N'db/021'),
    (N'PurchaseOrderLines', N'Note',                     N'NVARCHAR(500)', N'db/021'),
    -- dbo.PurchaseOrderLines (db/031 OrderId, db/040 SourcePoNo, db/036 vendor)
    (N'PurchaseOrderLines', N'OrderId',    N'NVARCHAR(50)',  N'db/031'),
    (N'PurchaseOrderLines', N'SourcePoNo', N'NVARCHAR(50)',  N'db/040'),
    (N'PurchaseOrderLines', N'VendorCode', N'VARCHAR(64)',   N'db/036'),
    (N'PurchaseOrderLines', N'VendorName', N'NVARCHAR(160)', N'db/036');

------------------------------------------------------------------------------
-- Result set 1 — column presence + type.
--   Actual friendly type is reconstructed from INFORMATION_SCHEMA so it can be
--   compared to ExpectedType. CHARACTER_MAXIMUM_LENGTH = -1 means MAX.
------------------------------------------------------------------------------
SELECT
    e.Source,
    e.TableName,
    e.ColName,
    e.ExpectedType,
    ActualType =
        CASE
            WHEN c.DATA_TYPE IS NULL THEN N'(absent)'
            WHEN c.CHARACTER_MAXIMUM_LENGTH = -1
                THEN UPPER(c.DATA_TYPE) + N'(MAX)'
            WHEN c.CHARACTER_MAXIMUM_LENGTH IS NOT NULL
                THEN UPPER(c.DATA_TYPE) + N'(' + CAST(c.CHARACTER_MAXIMUM_LENGTH AS NVARCHAR(10)) + N')'
            ELSE UPPER(c.DATA_TYPE)
        END,
    Status =
        CASE
            WHEN c.DATA_TYPE IS NULL THEN N'MISSING'
            WHEN UPPER(REPLACE(e.ExpectedType, N' ', N'')) <>
                 CASE
                     WHEN c.CHARACTER_MAXIMUM_LENGTH = -1
                         THEN UPPER(c.DATA_TYPE) + N'(MAX)'
                     WHEN c.CHARACTER_MAXIMUM_LENGTH IS NOT NULL
                         THEN UPPER(c.DATA_TYPE) + N'(' + CAST(c.CHARACTER_MAXIMUM_LENGTH AS NVARCHAR(10)) + N')'
                     ELSE UPPER(c.DATA_TYPE)
                 END
                THEN N'TYPE-MISMATCH'
            ELSE N'OK'
        END
FROM @Expected e
LEFT JOIN INFORMATION_SCHEMA.COLUMNS c
       ON c.TABLE_SCHEMA = N'dbo'
      AND c.TABLE_NAME   = e.TableName
      AND c.COLUMN_NAME  = e.ColName
ORDER BY
    CASE WHEN c.DATA_TYPE IS NULL THEN 0 ELSE 1 END,  -- missing first
    e.TableName, e.ColName;

------------------------------------------------------------------------------
-- Result set 2 — supporting filtered indexes (fidelity, not correctness).
------------------------------------------------------------------------------
SELECT
    IndexName = x.name,
    OnTable   = t.name,
    Status    = CASE WHEN i.name IS NULL THEN N'MISSING' ELSE N'OK' END
FROM (VALUES
        (N'IX_PO_PullExternalRef', N'PurchaseOrders'),
        (N'IX_POL_Vendor',         N'PurchaseOrderLines')
     ) AS x(name, tbl)
JOIN sys.tables t ON t.name = x.tbl AND t.schema_id = SCHEMA_ID(N'dbo')
LEFT JOIN sys.indexes i ON i.name = x.name AND i.object_id = t.object_id
ORDER BY x.name;

------------------------------------------------------------------------------
-- Result set 3 — AuditLog.ActionType must be wide enough for the import
-- ActionType strings (max 19 chars) — expect >= 32.
------------------------------------------------------------------------------
SELECT
    [Column]     = N'dbo.AuditLog.ActionType',
    DataType     = UPPER(DATA_TYPE),
    MaxLength    = CHARACTER_MAXIMUM_LENGTH,
    Status       = CASE WHEN CHARACTER_MAXIMUM_LENGTH >= 32 THEN N'OK' ELSE N'TOO NARROW' END
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = N'dbo' AND TABLE_NAME = N'AuditLog' AND COLUMN_NAME = N'ActionType';

------------------------------------------------------------------------------
-- Headline verdict.
------------------------------------------------------------------------------
DECLARE @missing INT = (
    SELECT COUNT(*)
    FROM @Expected e
    LEFT JOIN INFORMATION_SCHEMA.COLUMNS c
           ON c.TABLE_SCHEMA = N'dbo' AND c.TABLE_NAME = e.TableName AND c.COLUMN_NAME = e.ColName
    WHERE c.DATA_TYPE IS NULL
);
DECLARE @auditTooNarrow INT = (
    SELECT COUNT(*)
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = N'dbo' AND TABLE_NAME = N'AuditLog' AND COLUMN_NAME = N'ActionType'
      AND CHARACTER_MAXIMUM_LENGTH < 32
);

PRINT N'============================================================';
IF @missing = 0 AND @auditTooNarrow = 0
    PRINT N'PASS: all expected PO-import columns present; ActionType wide enough.';
ELSE
    PRINT N'FAIL: ' + CAST(@missing AS NVARCHAR(10)) + N' column(s) MISSING'
        + CASE WHEN @auditTooNarrow > 0 THEN N' + AuditLog.ActionType TOO NARROW' ELSE N'' END
        + N'. Run db/prod-hotfix-poimport-schema.sql.';
PRINT N'============================================================';
GO
