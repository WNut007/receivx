/* ============================================================================
   ReceivingOps — 049_pull_item_windows_variance_reason_code.sql
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. ONE column on dbo.PullItemWindows. No index, no
   constraint, no default, no backfill.

     dbo.PullItemWindows
       VarianceReasonCode  NVARCHAR(32) NULL

   ---------------------------------------------------------------------------
   DEPLOY ORDER — RUN THIS FILE ON PRODUCTION *BEFORE* deploy.ps1
   ---------------------------------------------------------------------------
   deploy.ps1 does NOT run migrations, and its auto-rollback restores the DLL,
   not the schema. On 2026-08-07 a DLL went out against an unmigrated schema and
   /api/pulls returned 500 on "Invalid column name 'IsClosed'" until the
   migration was run by hand. Same failure mode is in play here.

     1. Run this file on production.
     2. Verify — this must return 64, not NULL:

            SELECT COL_LENGTH('dbo.PullItemWindows', 'VarianceReasonCode');

        (64 = 32 NVARCHAR characters at 2 bytes each. COL_LENGTH reports BYTES.
        Any non-NULL value means the column exists; NULL means it does not and
        the deploy must not proceed.)

     3. Then run deploy.ps1.

   Running this early is safe. The column is nullable with no default and every
   INSERT the CURRENTLY DEPLOYED DLL issues names its columns explicitly and
   omits this one, so the deployed build keeps working unchanged between step 1
   and step 3. There is no rollback risk and no window where the old DLL breaks.

   ---------------------------------------------------------------------------
   WHY A COLUMN AND NOT A PREFIX INTO ClosedReason
   ---------------------------------------------------------------------------
   The point of the change is to be able to GROUP BY the reason. A code that has
   to be parsed back out of a sentence is not structured data. ClosedReason
   continues to hold the operator's free text exactly as today; this column does
   not replace it, it makes it optional for every code except OTHER.

   WINDOW GRAIN, NOT RECEIPT GRAIN
   -------------------------------
   This sits beside ClosedBy / ClosedAt / ClosedReason on dbo.PullItemWindows,
   which are already the window's close-audit record, and accepting a variance
   always closes the line. There is deliberately NO parallel column on
   dbo.Receipts: a single confirm can write several receipt rows (the FIFO walk
   splits across PO lines), so a receipt-grain code would have to be duplicated
   across slices and would then face exactly the orphaning problem that
   VarianceQty just had to be fixed for — see ReceiptService CancelAsync step 8c
   and db/047_STATUS.md.

   NVARCHAR(32) — wider than needed, on purpose
   --------------------------------------------
   The longest code in the fixed set is DAMAGED_PARTIAL_RETURN at 22 characters.
   32 leaves room for a future addition without a schema change.

   NULLABLE, NO DEFAULT, NO BACKFILL
   ---------------------------------
   Windows closed before this migration genuinely have no reason code. NULL
   means "closed before reason codes existed" and is its own bucket. It must
   never be folded into OTHER — that would fabricate an operator decision that
   was never made, and would silently corrupt the first report that groups on
   this column.

   NO CHECK CONSTRAINT — DELIBERATE, DO NOT "FIX" THIS
   ---------------------------------------------------
   The allowed set is validated in the application, which is where the
   direction rule also lives (OVER_DELIVERY is invalid on a short close, and no
   CHECK constraint can express that — it depends on ExpectedQty vs the receipt
   total at the moment of the close). Pinning the values here would mean a
   future code addition needs a migration to DROP and re-ADD a constraint, for
   no validation the application does not already perform. A later reader
   noticing the absence should leave it absent.

   NO INDEX — DELIBERATE
   ---------------------
   Nothing groups on this column yet; consuming the data is explicitly separate
   work. Add a filtered index when a real report groups on it AND the row count
   justifies it. Note the same SET-option caveat db/047 recorded: a filtered
   index imposes requirements on every subsequent writer of this table,
   including the ERP sync (ErpUpsertService.cs), so it is not a free addition.

   db/047 WAS CHECKED AND NEEDS NO CORRECTION
   ------------------------------------------
   An earlier draft of this work expected db/047 to declare ClosedBy as
   NVARCHAR(100) and ClosedReason as NVARCHAR(500), diverging from production.
   It does not. As committed, db/047 declares:

       ClosedBy      UNIQUEIDENTIFIER NULL   (line 223)
       ClosedReason  NVARCHAR(1000)   NULL   (line 236)

   which matches production exactly, with the header block and the @missing
   post-check in agreement. A fresh install already lands on the production
   shape. No corrective ALTER appears in this file, and none is needed —
   verified 2026-08-08.

   Idempotent — COL_LENGTH guard. Safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- 1. dbo.PullItemWindows — structured reason code for an accepted variance
------------------------------------------------------------------------------
IF COL_LENGTH('dbo.PullItemWindows', 'VarianceReasonCode') IS NULL
BEGIN
    PRINT 'Adding PullItemWindows.VarianceReasonCode (NVARCHAR(32) NULL)...';
    -- Stable identifier, never displayed raw. Labels live in one map in the
    -- application; nothing keys off a label.
    ALTER TABLE dbo.PullItemWindows ADD VarianceReasonCode NVARCHAR(32) NULL;
END
ELSE
BEGIN
    PRINT 'PullItemWindows.VarianceReasonCode already exists — no change.';
END
GO

------------------------------------------------------------------------------
-- 2. Post-conditions.
------------------------------------------------------------------------------
IF COL_LENGTH('dbo.PullItemWindows', 'VarianceReasonCode') IS NULL
    THROW 50049, 'db/049 post-check FAILED: VarianceReasonCode is missing.', 1;

-- Nullable is load-bearing: pre-existing closed windows must stay NULL.
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.PullItemWindows')
             AND name = N'VarianceReasonCode'
             AND is_nullable = 0)
    THROW 50049, 'db/049 post-check FAILED: VarianceReasonCode must be NULLABLE.', 1;

-- No CHECK constraint may reference this column (see the header).
IF EXISTS (SELECT 1
           FROM sys.check_constraints cc
           INNER JOIN sys.columns c
                   ON c.object_id = cc.parent_object_id
                  AND c.column_id = cc.parent_column_id
           WHERE cc.parent_object_id = OBJECT_ID('dbo.PullItemWindows')
             AND c.name = N'VarianceReasonCode')
    THROW 50049, 'db/049 post-check FAILED: a CHECK constraint references VarianceReasonCode — see the header, this is deliberate.', 1;

-- The db/047 close-audit columns must be intact and at production shape.
IF COL_LENGTH('dbo.PullItemWindows', 'ClosedReason') <> 2000   -- NVARCHAR(1000) = 2000 bytes
    THROW 50049, 'db/049 post-check FAILED: ClosedReason is not NVARCHAR(1000) — db/047 did not apply as written.', 1;

PRINT 'db/049 post-check passed: VarianceReasonCode present, nullable, unconstrained; db/047 columns intact.';
GO

PRINT '049_pull_item_windows_variance_reason_code.sql complete (variance reason code).';
GO
