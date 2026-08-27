/* ============================================================================
   ReceivingOps — 047_receipt_variance_and_line_close.sql  (Accept Variance)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Two columns on dbo.Receipts and four on
   dbo.PullItemWindows. No index, no constraint change — columns only.

     dbo.Receipts
       VarianceAccepted  BIT NOT NULL DEFAULT 0
       VarianceQty       INT NULL              -- signed: + over, - short

     dbo.PullItemWindows
       IsClosed          BIT NOT NULL DEFAULT 0
       ClosedAt          DATETIME2 NULL
       ClosedBy          UNIQUEIDENTIFIER NULL
       ClosedReason      NVARCHAR(1000) NULL

   WHY
   ---
   A delivery that arrives short leaves Expected - Received > 0 forever, so
   the line sits in the pending queue with no way to retire it. IsClosed
   cannot be derived from arithmetic — that is precisely the bug. An operator
   on the final receipt for a SKU ticks "accept variance" and the line closes
   at the actual figure.

   GRAIN — window, not item (brief rev 6 §2c)
   ------------------------------------------
   IsClosed lives on dbo.PullItemWindows. dbo.Receipts has NO
   PullItemWindowId — it stores PullItemId + HourOfDay and resolves the
   window by that pair (see ReceiptService.cs:357-362 and :554-559). So the
   conditional close keys on (PullItemId, HourOfDay), never on a line id.

   The accept-variance affordance is offered ONLY when the parent PullItem
   has exactly one window; a multi-window SKU is refused server-side with
   400 MULTI_WINDOW_NOT_SUPPORTED. Evidence for that being safe: of 2,049
   PullItems created by a live ERP sync on 2026-08-06, spanning 20 distinct
   hours, every single one had exactly one window. The 13 multi-window items
   in the database are all demo (PL-2847) or smoke fixtures. The guard is a
   safety net for BpiPrsSource.cs:155-162, which can still emit a
   multi-window item if upstream ever splits a SKU across times.

   VarianceQty ACROSS FIFO SLICES (brief rev 6 §2c)
   ------------------------------------------------
   ReceiptService.cs:301-318 inserts ONE Receipts row per FIFO allocation
   slice, so a single Confirm can write several rows. The rule:
       VarianceAccepted = 1 on EVERY row written by that confirm;
       VarianceQty      on EXACTLY ONE of them, NULL on the rest.
   That keeps SUM(VarianceQty) over the line correct instead of multiplying
   the variance by the slice count. Reversing ANY row with
   VarianceAccepted = 1 clears IsClosed on the window.

   ZERO-QUANTITY CLOSE WRITES NO RECEIPT ROW (brief rev 6 §2d)
   -----------------------------------------------------------
   This migration deliberately does NOT touch CK_Receipts_QtyNonZero
   (QtyReceived <> 0) or CK_Receipts_ReversalIntegrity. dbo.Receipts is an
   append-only ledger where a row means goods moved; a zero row means
   nothing moved, and that invariant is not weakened for the whole table to
   serve one UI affordance.

   A confirm with Qty = 0 + variance accepted therefore writes NO Receipts
   row at all. It sets IsClosed/ClosedAt/ClosedBy/ClosedReason on the window
   and writes an audit entry. PullItemWindows.ReceivedQty is untouched. The
   Closed* columns below ARE the audit record of who closed the line and why
   — which is why ClosedReason must not truncate (see below).

   Because a zero-close leaves no receipt to reverse, an explicit reopen
   action clears the four Closed* columns under the same conditional-update
   discipline. No schema is needed for it: reopen writes NULL/0 back to
   these same columns and records the reason in dbo.AuditLog.

   COLUMN TYPE NOTES
   -----------------
   ClosedBy is UNIQUEIDENTIFIER, not NVARCHAR. dbo.PullItemWindows has no
   audit columns of its own, so the convention comes from its neighbours:
   Pulls.ClosedBy, Pulls.ReopenedBy, Pulls.CreatedBy and Receipts.ReceivedBy
   are all UNIQUEIDENTIFIER (Users.Id). It is also exactly what
   ReceiptService.CurrentUserId() already returns.

   ClosedReason is NVARCHAR(1000) to match its source, Receipts.Note
   (NVARCHAR(1000)), and its sibling Pulls.ReopenReason (NVARCHAR(1000)).
   At 500 a longer note would either throw "String or binary data would be
   truncated" at close time or silently discard the operator's reason — the
   one thing this column exists to preserve.

   VarianceQty is INT, not DECIMAL: every quantity column in this schema is
   INT and CLAUDE.md carries whole-unit arithmetic as a load-bearing
   invariant. A fractional variance would be the only fractional quantity in
   the system.

   CK_PIW_Caps — DOES NOT EXIST, nothing to relax
   ----------------------------------------------
   db/001_schema.sql:237 defined CK_PIW_Caps as
       CHECK (ReceivedQty <= ExpectedQty AND ReceivedQty >= 0)
   and db/010_schema_v2_additive.sql:125-136 DROPPED it deliberately (§4.6
   v2: the PO is the hard cap, per-hour overage is allowed). Over-receipt on
   a window already violates no constraint.

   Note the consequence: the ReceivedQty >= 0 floor went with it. Nothing in
   the database prevents a negative ReceivedQty. The service layer is the
   ONLY thing enforcing it — treat that as load-bearing when touching the
   cancel path, which decrements the cache at ReceiptService.cs:554-559.

   NO INDEX — COLUMNS ONLY (brief rev 7 §4)
   -----------------------------------------
   An earlier revision called for a filtered IX_PIW_Open on
   (PullItemId) INCLUDE (ExpectedQty, ReceivedQty) WHERE IsClosed = 0.
   Dropped, for three reasons:

     - UQ_PIW_Hour (PullItemId, HourOfDay) already leads on PullItemId, so
       the only thing gained is the INCLUDE and the filter.
     - The table holds ~48,000 rows and nothing suggests any of the five
       pending queries is slow. The brief's wording was "add a filtered
       index IF the pending-lines query is hot" — it isn't.
     - A filtered index imposes SET-option requirements on every subsequent
       INSERT/UPDATE against the table. SqlClient satisfies them by default,
       but the ERP sync also writes PullItemWindows
       (ErpUpsertService.cs:221, :333, :388, :398), and a mismatch there
       would break sync on production.

   So this migration is columns only — the safest shape a migration takes.
   Revisit the index when a query is measurably slow; it can be added
   ONLINE at any time without touching the DLL.

   The conditional close needs no new index regardless: the existing
   UQ_PIW_Hour (PullItemId, HourOfDay) already makes
       WHERE PullItemId = @p AND HourOfDay = @h AND IsClosed = 0
   a unique seek.

   ROLLBACK SAFETY (brief §2)
   --------------------------
   deploy.ps1 does NOT run migrations, and its auto-rollback restores the
   DLL, not the schema — so this migration must be valid against the
   CURRENTLY DEPLOYED DLL as well as the new one. It is:
     - Every INSERT the deployed DLL issues names its columns explicitly and
       omits all six new ones. The two NOT NULL columns carry DEFAULTs, so
       those INSERTs continue to succeed unchanged
       (Receipts: ReceiptService.cs:301-306, :507-514;
        PullItemWindows: PullItemAdminService.cs:68, :221,
        ErpUpsertService.cs:221, :333, :398).
     - No existing column is altered, dropped or re-typed.
     - No CHECK constraint is added, dropped or relaxed.
     - No index is created, so no new SET-option requirement is imposed on
       any writer — including the ERP sync.
   Running this migration BEFORE the DLL is copied is therefore safe, which
   is the order §2 requires.

   Adding a NOT NULL BIT with a DEFAULT is a metadata-only operation on
   SQL Server 2012+ (fixed-length type, constant default), so neither table
   is rewritten and no long lock is taken regardless of row count.

   Idempotent — per-column COL_LENGTH guards and a sys.indexes guard.
   Safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- 1. dbo.Receipts — variance flag + signed variance quantity
------------------------------------------------------------------------------
IF COL_LENGTH('dbo.Receipts', 'VarianceAccepted') IS NULL
BEGIN
    PRINT 'Adding Receipts.VarianceAccepted (BIT NOT NULL DEFAULT 0)...';
    ALTER TABLE dbo.Receipts
        ADD VarianceAccepted BIT NOT NULL
            CONSTRAINT DF_Receipts_VarianceAccepted DEFAULT (0);
END
ELSE
BEGIN
    PRINT 'Receipts.VarianceAccepted already exists — no change.';
END
GO

IF COL_LENGTH('dbo.Receipts', 'VarianceQty') IS NULL
BEGIN
    PRINT 'Adding Receipts.VarianceQty (INT NULL)...';
    -- Signed. Positive = over-receipt, negative = short close. NULL when the
    -- row carries no variance. Set on EXACTLY ONE row per confirm even when
    -- the FIFO walk splits the qty across several PO lines.
    ALTER TABLE dbo.Receipts ADD VarianceQty INT NULL;
END
ELSE
BEGIN
    PRINT 'Receipts.VarianceQty already exists — no change.';
END
GO

------------------------------------------------------------------------------
-- 2. dbo.PullItemWindows — the close flags. Keyed by (PullItemId, HourOfDay).
------------------------------------------------------------------------------
IF COL_LENGTH('dbo.PullItemWindows', 'IsClosed') IS NULL
BEGIN
    PRINT 'Adding PullItemWindows.IsClosed (BIT NOT NULL DEFAULT 0)...';
    ALTER TABLE dbo.PullItemWindows
        ADD IsClosed BIT NOT NULL
            CONSTRAINT DF_PIW_IsClosed DEFAULT (0);
END
ELSE
BEGIN
    PRINT 'PullItemWindows.IsClosed already exists — no change.';
END
GO

IF COL_LENGTH('dbo.PullItemWindows', 'ClosedAt') IS NULL
BEGIN
    PRINT 'Adding PullItemWindows.ClosedAt (DATETIME2 NULL)...';
    ALTER TABLE dbo.PullItemWindows ADD ClosedAt DATETIME2 NULL;
END
ELSE
BEGIN
    PRINT 'PullItemWindows.ClosedAt already exists — no change.';
END
GO

IF COL_LENGTH('dbo.PullItemWindows', 'ClosedBy') IS NULL
BEGIN
    PRINT 'Adding PullItemWindows.ClosedBy (UNIQUEIDENTIFIER NULL)...';
    -- Users.Id, matching Pulls.ClosedBy / Pulls.ReopenedBy / Receipts.ReceivedBy.
    ALTER TABLE dbo.PullItemWindows ADD ClosedBy UNIQUEIDENTIFIER NULL;
END
ELSE
BEGIN
    PRINT 'PullItemWindows.ClosedBy already exists — no change.';
END
GO

IF COL_LENGTH('dbo.PullItemWindows', 'ClosedReason') IS NULL
BEGIN
    PRINT 'Adding PullItemWindows.ClosedReason (NVARCHAR(1000) NULL)...';
    -- Copy of the operator's note at close time. Width matches Receipts.Note,
    -- which is where the value comes from.
    ALTER TABLE dbo.PullItemWindows ADD ClosedReason NVARCHAR(1000) NULL;
END
ELSE
BEGIN
    PRINT 'PullItemWindows.ClosedReason already exists — no change.';
END
GO

------------------------------------------------------------------------------
-- 3. Post-conditions. All six columns present; both ledger CHECKs untouched.
------------------------------------------------------------------------------
DECLARE @missing INT =
      CASE WHEN COL_LENGTH('dbo.Receipts',         'VarianceAccepted') IS NULL THEN 1 ELSE 0 END
    + CASE WHEN COL_LENGTH('dbo.Receipts',         'VarianceQty')      IS NULL THEN 1 ELSE 0 END
    + CASE WHEN COL_LENGTH('dbo.PullItemWindows',  'IsClosed')         IS NULL THEN 1 ELSE 0 END
    + CASE WHEN COL_LENGTH('dbo.PullItemWindows',  'ClosedAt')         IS NULL THEN 1 ELSE 0 END
    + CASE WHEN COL_LENGTH('dbo.PullItemWindows',  'ClosedBy')         IS NULL THEN 1 ELSE 0 END
    + CASE WHEN COL_LENGTH('dbo.PullItemWindows',  'ClosedReason')     IS NULL THEN 1 ELSE 0 END;

IF @missing > 0
    THROW 50047, 'db/047 post-check FAILED: one or more columns are missing.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = N'CK_Receipts_QtyNonZero'
                 AND parent_object_id = OBJECT_ID('dbo.Receipts'))
    THROW 50047, 'db/047 post-check FAILED: CK_Receipts_QtyNonZero is missing — it must NOT be dropped.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = N'CK_Receipts_ReversalIntegrity'
                 AND parent_object_id = OBJECT_ID('dbo.Receipts'))
    THROW 50047, 'db/047 post-check FAILED: CK_Receipts_ReversalIntegrity is missing — it must NOT be dropped.', 1;

PRINT 'db/047 post-check passed: 6 columns present, both ledger CHECKs intact.';
GO

PRINT '047_receipt_variance_and_line_close.sql complete (Accept Variance).';
GO
