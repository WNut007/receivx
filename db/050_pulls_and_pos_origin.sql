/* ============================================================================
   ReceivingOps — 050_pulls_and_pos_origin.sql
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. ONE column on each of two tables. No index, no
   constraint, no default, no backfill.

     dbo.Pulls
       Origin            VARCHAR(16) NULL
     dbo.PurchaseOrders
       Origin            VARCHAR(16) NULL

   ---------------------------------------------------------------------------
   DEPLOY ORDER — RUN THIS FILE ON PRODUCTION *BEFORE* deploy.ps1
   ---------------------------------------------------------------------------
   deploy.ps1 does NOT run migrations, and its auto-rollback restores the DLL,
   not the schema. On 2026-08-07 a DLL went out against an unmigrated schema and
   /api/pulls returned 500 on "Invalid column name 'IsClosed'" until the
   migration was run by hand. Same failure mode is in play here: the build that
   ships with this migration SELECTs Pulls.Origin on the ERP-sync path and
   INSERTs both columns on the WIP synthesis path.

     1. Run this file on production.
     2. Verify — this must return 16 and 16, not NULL:

            SELECT COL_LENGTH('dbo.Pulls',          'Origin') AS PullsOrigin,
                   COL_LENGTH('dbo.PurchaseOrders', 'Origin') AS PosOrigin;

        (16 = 16 VARCHAR characters at 1 byte each. COL_LENGTH reports BYTES.
        Any non-NULL value means the column exists; NULL means it does not and
        the deploy must not proceed.)

     3. Then run deploy.ps1.

   Running this early is safe. Both columns are nullable with no default, and
   every INSERT the CURRENTLY DEPLOYED DLL issues names its columns explicitly
   and omits these, so the deployed build keeps working unchanged between step 1
   and step 3. There is no rollback risk and no window where the old DLL breaks.

   ---------------------------------------------------------------------------
   WHAT THE COLUMN IS FOR
   ---------------------------------------------------------------------------
   For pull sheets whose STORER CODE contains WIP, the ERP never sends the
   Receive feed: the PO import lands the lines but no Pulls / PullItems /
   PullItemWindows rows ever appear, so the goods arrive and the warehouse has
   nothing to receive against. Measured on the 2026-08-16 production export:
   647 of 4,401 rows across 25 pull sheets, 68,579 units, zero of which have a
   Pulls row in Receivx.

   The import now builds that pull structure itself, and creates the
   purchase-order side to go with it (Receipts.PurchaseOrderLineId is NOT NULL,
   so a receipt has nowhere to land without a PO line). Those rows are real
   inventory records that no procurement document backs. Origin is how someone
   asking "why does pull 0000028073 have a PO nobody in procurement remembers
   issuing" finds the answer without reading source.

     NULL          — ERP-fed, hand-created, or created before this migration.
                     The overwhelming majority of rows, now and later.
     'po-import'   — synthesised by the PO Excel import (WIP pull sheets).

   ---------------------------------------------------------------------------
   VARCHAR(16), NULLABLE, NO DEFAULT, NO BACKFILL
   ---------------------------------------------------------------------------
   NULL is not "unknown origin" — it is the ordinary case, and it must stay the
   ordinary case. Backfilling existing rows with 'erp' would be inventing a
   provenance record for ~12,300 pulls that nobody actually observed, and the
   application never needs to distinguish "ERP-fed" from "hand-created" — only
   "synthesised by the importer" from "everything else".

   VARCHAR, not NVARCHAR: the values are machine tokens written by the
   application, never operator text, and never displayed untranslated.
   16 characters leaves room for a second origin token without a schema change.

   NO CHECK CONSTRAINT — DELIBERATE, DO NOT "FIX" THIS
   ---------------------------------------------------
   Same reasoning db/049 recorded for VarianceReasonCode: the allowed set lives
   in the application (WipPullSynthesis.OriginPoImport), and pinning it here
   would make a future origin token require a migration to DROP and re-ADD a
   constraint, for no validation the application does not already perform.

   NO INDEX — DELIBERATE
   ---------------------
   Nothing filters on Origin yet. The ERP-sync read that consults it
   (ErpUpsertService, cancel path) has already located its row by PullNumber
   under UPDLOCK and reads Origin off that row. A filtered index here would also
   impose SET-option requirements on every subsequent writer of dbo.Pulls —
   including the ERP sync — which is not a free addition. Add one when a real
   report filters on it AND the row count justifies it.

   WHY BOTH TABLES AND NOT JUST Pulls
   ----------------------------------
   The synthesised PO is reachable from the pull via PurchaseOrders.PullId, so a
   Pulls-only flag is technically sufficient. It is not operationally
   sufficient: procurement reads /Pos, and a PO whose provenance can only be
   established by joining to another table is a PO whose provenance nobody
   establishes. The repair path (pull missing, PO already imported) deliberately
   leaves the pre-existing PO untouched — including its Origin — because
   PurchaseOrders.PullId is immutable after create (§7.15) and rewriting an
   existing PO's provenance would be a claim about history the importer cannot
   make. Those POs stay NULL and the pull carries the marker.

   Idempotent — COL_LENGTH guards. Safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- 1. dbo.Pulls — provenance marker
------------------------------------------------------------------------------
IF COL_LENGTH('dbo.Pulls', 'Origin') IS NULL
BEGIN
    ALTER TABLE dbo.Pulls ADD Origin VARCHAR(16) NULL;
    PRINT 'db/050: added dbo.Pulls.Origin VARCHAR(16) NULL';
END
ELSE
    PRINT 'db/050: dbo.Pulls.Origin already present — no action';
GO

------------------------------------------------------------------------------
-- 2. dbo.PurchaseOrders — provenance marker
------------------------------------------------------------------------------
IF COL_LENGTH('dbo.PurchaseOrders', 'Origin') IS NULL
BEGIN
    ALTER TABLE dbo.PurchaseOrders ADD Origin VARCHAR(16) NULL;
    PRINT 'db/050: added dbo.PurchaseOrders.Origin VARCHAR(16) NULL';
END
ELSE
    PRINT 'db/050: dbo.PurchaseOrders.Origin already present — no action';
GO

------------------------------------------------------------------------------
-- 3. Post-check — fails loudly rather than leaving a half-applied migration
------------------------------------------------------------------------------
DECLARE @missing NVARCHAR(400) = N'';

IF COL_LENGTH('dbo.Pulls', 'Origin') IS NULL
    SET @missing = @missing + N'dbo.Pulls.Origin ';
IF COL_LENGTH('dbo.PurchaseOrders', 'Origin') IS NULL
    SET @missing = @missing + N'dbo.PurchaseOrders.Origin ';

IF LEN(@missing) > 0
BEGIN
    RAISERROR('db/050 FAILED — column(s) still missing: %s', 16, 1, @missing);
    RETURN;
END

PRINT 'db/050: OK — both Origin columns present.';
GO

------------------------------------------------------------------------------
-- 4. Verification (same query as the header; run it after the file)
------------------------------------------------------------------------------
SELECT COL_LENGTH('dbo.Pulls',          'Origin') AS PullsOrigin,   -- expect 16
       COL_LENGTH('dbo.PurchaseOrders', 'Origin') AS PosOrigin;     -- expect 16
GO
