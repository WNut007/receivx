/* ============================================================================
   ReceivingOps — 026_rename_trailid_to_trialid.sql  (v2.3.2 — typo fix)
   ----------------------------------------------------------------------------
   Phase 9.1 shipped the column as `TrailId` (T-R-A-I-L). Correct spelling is
   `TrialId` (T-R-I-A-L, manufacturing trial). Rename the column on
   dbo.PullItems so the schema matches the intent.

   sp_rename does NOT update view bindings — vw_TransactionsJournal still
   references pi.TrailId after this migration runs and would become invalid
   until db/027 (CREATE OR ALTER VIEW) redefines it against TrialId. The two
   migrations are intended to run together; do not stop between them on a
   live deployment.

   Idempotent — runs the rename only if TrailId exists; no-ops if already
   applied (TrialId present) or in an unexpected mixed state.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.PullItems', 'TrailId') IS NOT NULL
   AND COL_LENGTH('dbo.PullItems', 'TrialId') IS NULL
BEGIN
    PRINT 'Renaming PullItems.TrailId -> TrialId...';
    EXEC sp_rename 'dbo.PullItems.TrailId', 'TrialId', 'COLUMN';
END
ELSE IF COL_LENGTH('dbo.PullItems', 'TrialId') IS NOT NULL
BEGIN
    PRINT 'PullItems.TrialId already present — no-op.';
END
ELSE
BEGIN
    -- Neither column found: db/024 was never applied. Don't try to invent
    -- the rename; surface the misconfiguration so the operator runs 024 first.
    THROW 50001, 'Neither TrailId nor TrialId exists on dbo.PullItems; run db/024 first.', 1;
END
GO

PRINT '026_rename_trailid_to_trialid.sql complete.';
GO
