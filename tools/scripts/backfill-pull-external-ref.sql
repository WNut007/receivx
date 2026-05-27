/* ============================================================================
   backfill-pull-external-ref.sql  (Phase 12 follow-up, A1)
   ----------------------------------------------------------------------------
   ONE-TIME manual backfill. NOT auto-applied by deploy. Operator review
   required before the UPDATE is uncommented.

   Context: v3.2 shipped Phase 12 PO import with PullId=NULL on every
   imported PO. db/033 added the parallel PullExternalRef column, and
   PoImportJob (post-A1 commit 500154b) populates it = PoNumber on every
   new import. POs that were imported BEFORE A1 landed need a one-shot
   backfill to make their LinkedPull UI render and FIFO §7.15 lookup work.

   Scope: only POs where BOTH PullId IS NULL (no FK link) AND
   PullExternalRef IS NULL (not yet backfilled). Adjust the date window
   to match when Phase 12 imports started in your environment (commit
   4cc53f2 added db/030 on 2026-05-27; production rollout date may
   differ).

   Idempotent — re-running after a partial run only touches rows that
   are still NULL.
   ============================================================================ */

SET NOCOUNT ON;
USE [ReceivingOps];
GO

-- ---------------------------------------------------------------------------
-- DRY-RUN: preview the rows that WILL be updated.
-- Verify these are all Phase 12 imports + none are genuine cross-pool POs
-- that an admin created via /Pos with PullId left intentionally NULL.
-- ---------------------------------------------------------------------------
PRINT '== Dry-run sample (first 20 rows that would be backfilled) ==';
SELECT TOP 20
    po.PoNumber, po.CreatedAt, po.PullId, po.PullExternalRef,
    u.Username AS CreatedByUsername
FROM   dbo.PurchaseOrders po
LEFT  JOIN dbo.Users u ON u.Id = po.CreatedBy
WHERE  po.PullId IS NULL
  AND  po.PullExternalRef IS NULL
  AND  po.CreatedAt >= '2026-05-27 00:00:00'   -- adjust to your Phase 12 cutover
ORDER BY po.CreatedAt;
GO

PRINT '== Count of rows that would be backfilled ==';
SELECT COUNT(*) AS RowsToBackfill
FROM   dbo.PurchaseOrders
WHERE  PullId IS NULL
  AND  PullExternalRef IS NULL
  AND  CreatedAt >= '2026-05-27 00:00:00';
GO

-- ---------------------------------------------------------------------------
-- EXECUTE: uncomment AFTER reviewing the dry-run rows. Wrapped in an
-- explicit transaction so an operator-side abort (Ctrl-C) doesn't leave
-- a partial update in an awkward state.
-- ---------------------------------------------------------------------------
/*
BEGIN TRANSACTION;

UPDATE dbo.PurchaseOrders
SET    PullExternalRef = PoNumber
WHERE  PullId IS NULL
  AND  PullExternalRef IS NULL
  AND  CreatedAt >= '2026-05-27 00:00:00';

DECLARE @rows INT = @@ROWCOUNT;
PRINT 'Backfilled PullExternalRef on ' + CAST(@rows AS NVARCHAR(10)) + ' rows.';

-- Sanity check before committing — at least one row should now have
-- PullExternalRef populated, and none should mismatch PoNumber.
DECLARE @mismatch INT = (
    SELECT COUNT(*)
    FROM   dbo.PurchaseOrders
    WHERE  PullExternalRef IS NOT NULL
      AND  PullExternalRef <> PoNumber
);
IF @mismatch > 0
BEGIN
    PRINT 'ABORT: ' + CAST(@mismatch AS NVARCHAR(10)) + ' rows have PullExternalRef <> PoNumber. Rolling back.';
    ROLLBACK;
END
ELSE
BEGIN
    COMMIT;
    PRINT 'Backfill committed.';
END
*/

PRINT '== Backfill script complete (review-only — execute block is commented) ==';
GO
