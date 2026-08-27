/* ============================================================================
   ReceivingOps — migration state probe   (READ-ONLY)
   ----------------------------------------------------------------------------
   PURPOSE
     This project has NO migration ledger table. The only available evidence of
     which migrations have been applied is the presence of the schema object (or
     the data effect) that each one produces. This script probes for them and
     prints a per-migration verdict.

     Run it on the PRODUCTION box and paste the whole output back.

   READ-ONLY
     SELECTs against sys / INFORMATION_SCHEMA catalog views and COUNT(*) over
     existing rows. Makes NO changes of any kind. Safe to run against production
     any number of times.

   WHY IT MATTERS RIGHT NOW
     db/ contains two duplicate-number collisions. Each number was used twice by
     two unrelated migrations:

       040  ->  040_pull_dashboard_index.sql            (untracked in git)
                040_purchase_order_lines_source_po_no.sql  (tracked)
       041  ->  041_backfill_composite_itemcode.sql     (tracked)
                041_vw_transactions_journal_ktf.sql     (untracked in git)

     These are NOT being renumbered — they may already be applied on production
     under their current names, and with no ledger there is nothing to correct
     against. Renaming an applied migration is how a second db/046 incident
     happens. Instead, probes 040a/040b and 041a/041b below report which member
     of each pair is live, independently.

   HOW TO RUN
     sqlcmd -S <prod-server> -d ReceivingOps -W -s " | " -i db\probe-migrations.sql
     (add -U/-P, or -E for Windows auth, as appropriate for the prod host)

   INTERPRETING RESULT SET 2
     APPLIED                 the object/data effect is present
     missing                 not applied
     view exists, older rev  the view is there but predates this revision
     NOT APPLIED (n rows...) data-only migration whose effect has not landed
   ============================================================================ */
SET NOCOUNT ON;
GO

------------------------------------------------------------------------------
-- 0. Confirm there really is no migration ledger to read instead.
--    NOTE: '%\_\_EF%' is escaped — an unescaped '_' is a single-char wildcard
--    in T-SQL LIKE and produces false positives (it matches 'UserPreferences').
------------------------------------------------------------------------------
SELECT 'LEDGER-SEARCH' AS Probe,
       ISNULL((SELECT STRING_AGG(name, ', ')
               FROM sys.tables
               WHERE name LIKE '%migration%'
                  OR name LIKE '%SchemaVersion%'
                  OR name LIKE '%\_\_EF%' ESCAPE '\'),
              '(none - no ledger table exists; object probing is the only evidence)') AS Result;
GO

------------------------------------------------------------------------------
-- 1. Per-migration probe, 039 -> 046.
------------------------------------------------------------------------------
SELECT Probe, Object, Status FROM (
    SELECT '039  warehouses_logo' AS Probe,
           'Warehouses.LogoDataUrl' AS Object,
           CASE WHEN COL_LENGTH('dbo.Warehouses','LogoDataUrl') IS NOT NULL
                THEN 'APPLIED' ELSE 'missing' END AS Status, 1 AS Ord

    -- ---- 040 COLLISION: two different migrations share this number ----
    UNION ALL SELECT '040a pull_dashboard_index      [COLLISION]',
           'index IX_Pulls_Date on dbo.Pulls',
           CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                             WHERE name = 'IX_Pulls_Date'
                               AND object_id = OBJECT_ID('dbo.Pulls'))
                THEN 'APPLIED' ELSE 'missing' END, 2
    UNION ALL SELECT '040b purchase_order_lines_source_po_no [COLLISION]',
           'PurchaseOrderLines.SourcePoNo',
           CASE WHEN COL_LENGTH('dbo.PurchaseOrderLines','SourcePoNo') IS NOT NULL
                THEN 'APPLIED' ELSE 'missing' END, 3

    -- ---- 041 COLLISION: two different migrations share this number ----
    -- 041a is data-only: it rewrites composite PullItems.ItemCode ('SKU-TRIAL')
    -- down to the bare SKU. Idempotent, so "no fixable composites left" ==
    -- applied (or there was nothing to fix on this database).
    --
    -- The predicate below is lifted VERBATIM from step 1a of
    -- db/041_backfill_composite_itemcode.sql. Do not simplify it to
    -- "ItemCode LIKE '%-%'" — bare SKUs in this catalogue are themselves
    -- hyphenated (CAP-470UF-25V), so the loose form reports thousands of
    -- false positives. Only a code that ends with '-' + its own TrialId AND
    -- whose stripped form matches a PO line is a genuine fixable composite.
    UNION ALL SELECT '041a backfill_composite_itemcode [COLLISION]',
           'fixable composite PullItems.ItemCode remaining',
           CASE WHEN (SELECT COUNT(*) FROM dbo.PullItems pi
                      WHERE pi.ItemCode LIKE '%-%'
                        AND pi.TrialId IS NOT NULL
                        AND pi.ItemCode LIKE '%-' + pi.TrialId
                        AND EXISTS (SELECT 1 FROM dbo.Pulls p
                                    JOIN dbo.PurchaseOrders po
                                      ON (po.PullId = p.Id OR po.PullExternalRef = p.PullNumber)
                                    JOIN dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.Id
                                    WHERE p.Id = pi.PullId
                                      AND pol.ItemCode = LEFT(pi.ItemCode,
                                            LEN(pi.ItemCode) - LEN(pi.TrialId) - 1))
                        AND NOT EXISTS (SELECT 1 FROM dbo.Pulls p
                                        JOIN dbo.PurchaseOrders po
                                          ON (po.PullId = p.Id OR po.PullExternalRef = p.PullNumber)
                                        JOIN dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.Id
                                        WHERE p.Id = pi.PullId
                                          AND pol.ItemCode = pi.ItemCode)) = 0
                THEN 'APPLIED (or nothing fixable on this DB)'
                ELSE CONCAT('NOT APPLIED (',
                            (SELECT COUNT(*) FROM dbo.PullItems pi
                             WHERE pi.ItemCode LIKE '%-%'
                               AND pi.TrialId IS NOT NULL
                               AND pi.ItemCode LIKE '%-' + pi.TrialId
                               AND EXISTS (SELECT 1 FROM dbo.Pulls p
                                           JOIN dbo.PurchaseOrders po
                                             ON (po.PullId = p.Id OR po.PullExternalRef = p.PullNumber)
                                           JOIN dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.Id
                                           WHERE p.Id = pi.PullId
                                             AND pol.ItemCode = LEFT(pi.ItemCode,
                                                   LEN(pi.ItemCode) - LEN(pi.TrialId) - 1))
                               AND NOT EXISTS (SELECT 1 FROM dbo.Pulls p
                                               JOIN dbo.PurchaseOrders po
                                                 ON (po.PullId = p.Id OR po.PullExternalRef = p.PullNumber)
                                               JOIN dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.Id
                                               WHERE p.Id = pi.PullId
                                                 AND pol.ItemCode = pi.ItemCode)),
                            ' fixable composite(s) remain)') END, 4
    UNION ALL SELECT '041b vw_transactions_journal_ktf [COLLISION]',
           'dbo.vw_TransactionsJournal (KTF revision)',
           CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules m
                             WHERE m.object_id = OBJECT_ID('dbo.vw_TransactionsJournal')
                               AND m.definition LIKE '%KTF%')
                THEN 'APPLIED'
                WHEN OBJECT_ID('dbo.vw_TransactionsJournal') IS NOT NULL
                THEN 'view exists, older revision'
                ELSE 'missing' END, 5

    UNION ALL SELECT '042  pull_signatures_and_signer_roles',
           'dbo.PullSignatures (table)',
           CASE WHEN OBJECT_ID('dbo.PullSignatures') IS NOT NULL
                THEN 'APPLIED' ELSE 'missing' END, 6
    UNION ALL SELECT '043  signing_capability_separate',
           'UWA.CanSignCustomer / CanSignWarehouse / CanSignProduction',
           CASE WHEN COL_LENGTH('dbo.UserWarehouseAssignments','CanSignCustomer')   IS NOT NULL
                 AND COL_LENGTH('dbo.UserWarehouseAssignments','CanSignWarehouse')  IS NOT NULL
                 AND COL_LENGTH('dbo.UserWarehouseAssignments','CanSignProduction') IS NOT NULL
                THEN 'APPLIED' ELSE 'missing' END, 7
    -- 044 is data-only: flips CanSignWarehouse = 1 for every supervisor row.
    UNION ALL SELECT '044  backfill_supervisor_can_sign',
           'supervisor rows still at CanSignWarehouse = 0',
           CASE WHEN COL_LENGTH('dbo.UserWarehouseAssignments','CanSignWarehouse') IS NULL
                THEN 'n/a - 043 not applied yet'
                WHEN (SELECT COUNT(*) FROM dbo.UserWarehouseAssignments
                      WHERE Role = 'supervisor' AND CanSignWarehouse = 0) = 0
                THEN 'APPLIED (no supervisor left unflipped)'
                ELSE CONCAT('NOT APPLIED (',
                            (SELECT COUNT(*) FROM dbo.UserWarehouseAssignments
                             WHERE Role = 'supervisor' AND CanSignWarehouse = 0),
                            ' supervisor row(s) still 0)') END, 8
    UNION ALL SELECT '045  pull_signature_svg',
           'PullSignatures.SignatureSvg',
           CASE WHEN OBJECT_ID('dbo.PullSignatures') IS NULL THEN 'n/a - 042 not applied yet'
                WHEN COL_LENGTH('dbo.PullSignatures','SignatureSvg') IS NOT NULL
                THEN 'APPLIED' ELSE 'missing' END, 9
    UNION ALL SELECT '046  po_import_log_skipped',
           'PoImportLog.PosSkipped + SkippedPoNumbers',
           CASE WHEN COL_LENGTH('dbo.PoImportLog','PosSkipped')       IS NOT NULL
                 AND COL_LENGTH('dbo.PoImportLog','SkippedPoNumbers') IS NOT NULL
                THEN 'APPLIED' ELSE 'missing' END, 10
) x ORDER BY Ord;
GO

------------------------------------------------------------------------------
-- 2. FORWARD CHECK — is migration number 047 genuinely free on this database?
--    Every column below is introduced by the pending "accept variance" change.
--    All five must read 'absent (expected)'. Any 'ALREADY EXISTS' means some
--    variant of this change is already on production and 047 must NOT be used.
------------------------------------------------------------------------------
SELECT 'FORWARD-CHECK' AS Probe, Object, Status FROM (
    SELECT 'Receipts.VarianceAccepted' AS Object,
           CASE WHEN COL_LENGTH('dbo.Receipts','VarianceAccepted') IS NOT NULL
                THEN '** ALREADY EXISTS **' ELSE 'absent (expected)' END AS Status, 1 AS Ord
    UNION ALL SELECT 'Receipts.VarianceQty',
           CASE WHEN COL_LENGTH('dbo.Receipts','VarianceQty') IS NOT NULL
                THEN '** ALREADY EXISTS **' ELSE 'absent (expected)' END, 2
    UNION ALL SELECT 'PullItemWindows.IsClosed',
           CASE WHEN COL_LENGTH('dbo.PullItemWindows','IsClosed') IS NOT NULL
                THEN '** ALREADY EXISTS **' ELSE 'absent (expected)' END, 3
    UNION ALL SELECT 'PullItems.IsClosed',
           CASE WHEN COL_LENGTH('dbo.PullItems','IsClosed') IS NOT NULL
                THEN '** ALREADY EXISTS **' ELSE 'absent (expected)' END, 4
    UNION ALL SELECT 'PurchaseOrderLines.IsClosed',
           CASE WHEN COL_LENGTH('dbo.PurchaseOrderLines','IsClosed') IS NOT NULL
                THEN '** ALREADY EXISTS **' ELSE 'absent (expected)' END, 5
) y ORDER BY Ord;
GO

------------------------------------------------------------------------------
-- 3. Newest user objects. This is the catch-all: it surfaces any migration
--    applied to production that has NO corresponding file in db/ — the exact
--    drift the pre-flight is guarding against. Anything here dated after
--    2026-07-30 that is not explained by db/039..046 needs investigating
--    before a new migration number is chosen.
------------------------------------------------------------------------------
SELECT TOP 30 'RECENT-OBJECTS' AS Probe, o.name AS ObjectName, o.type_desc AS Kind,
       CONVERT(varchar(19), o.create_date, 120) AS CreatedUtc,
       CONVERT(varchar(19), o.modify_date, 120) AS ModifiedUtc
FROM sys.objects o
WHERE o.is_ms_shipped = 0 AND o.schema_id = SCHEMA_ID('dbo')
ORDER BY o.create_date DESC;
GO

------------------------------------------------------------------------------
-- 4. Trailing columns on the tables this change will touch. sys.columns has no
--    create_date, so the highest column_id is the most recently added column.
------------------------------------------------------------------------------
SELECT 'TRAILING-COLUMNS' AS Probe, t.name AS TableName, c.name AS ColumnName, c.column_id
FROM sys.columns c
JOIN sys.tables t ON t.object_id = c.object_id
WHERE t.name IN ('Receipts','PullItems','PullItemWindows','PurchaseOrderLines','Pulls')
  AND c.column_id >= (SELECT MAX(c2.column_id) - 4
                      FROM sys.columns c2 WHERE c2.object_id = t.object_id)
ORDER BY t.name, c.column_id;
GO
