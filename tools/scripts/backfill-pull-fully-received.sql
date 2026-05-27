/* ============================================================================
   backfill-pull-fully-received.sql  (post-v3.2 follow-up)
   ----------------------------------------------------------------------------
   ONE-TIME manual backfill. NOT auto-applied by deploy. Operator review
   required before the UPDATE is uncommented.

   Context: ReceiveAsync's Pulls UPDATE did not have a forward transition
   from in_progress to fully_received until commit 4a91883. Pulls whose
   last window filled before the fix is in place stayed at Status =
   'in_progress' permanently, invisible to the dashboard's "FULLY
   RECEIVED" kanban tab even though vw_PullProgress reports them at
   100% (IsFullyReceived = 1).

   This script identifies + transitions those stuck pulls in a single
   set-based UPDATE. Idempotent — re-running after partial completion
   only touches rows that still meet both conditions (Status='in_progress'
   AND no outstanding windows).

   Scope guards:
     - Excludes canceled PullItems from the totals (mirrors the
       outstandingWindows query in ReceiveAsync lines 385-391).
     - Requires SUM(ExpectedQty) > 0 so pulls with zero-expected windows
       (degenerate fixtures) are not flipped to fully_received.
     - Does NOT touch ClosedAt / ClosedBy / SignatureSvg — those belong
       to CloseService.CloseAsync, not this status transition.
   ============================================================================ */

SET NOCOUNT ON;
USE [ReceivingOps];
GO

-- ---------------------------------------------------------------------------
-- DRY-RUN: identify stuck pulls. Verify each row before uncommenting the
-- UPDATE block below. Pull 0000009383 + any other Phase 12-era imports
-- with completed receives should appear here.
-- ---------------------------------------------------------------------------
PRINT '== Dry-run: stuck pulls that WOULD be transitioned ==';
SELECT
    p.Id,
    p.PullNumber,
    p.Status,
    p.CreatedAt,
    p.LastActivityAt,
    SUM(piw.ExpectedQty) AS TotalExpected,
    SUM(piw.ReceivedQty) AS TotalReceived
FROM   dbo.Pulls p
INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id AND pi.Status <> 'canceled'
INNER JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
WHERE  p.Status = 'in_progress'
GROUP BY p.Id, p.PullNumber, p.Status, p.CreatedAt, p.LastActivityAt
HAVING SUM(piw.ExpectedQty) = SUM(piw.ReceivedQty)
   AND SUM(piw.ExpectedQty) > 0
ORDER BY p.LastActivityAt DESC;
GO

PRINT '== Count of stuck pulls ==';
SELECT COUNT(DISTINCT p.Id) AS RowsToBackfill
FROM   dbo.Pulls p
INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id AND pi.Status <> 'canceled'
INNER JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
WHERE  p.Status = 'in_progress'
GROUP BY p.Id
HAVING SUM(piw.ExpectedQty) = SUM(piw.ReceivedQty)
   AND SUM(piw.ExpectedQty) > 0;
GO

-- ---------------------------------------------------------------------------
-- EXECUTE: uncomment AFTER reviewing dry-run rows. Wrapped in an explicit
-- transaction so an operator-side abort doesn't leave a partial state.
-- Audit rows for each transitioned pull are written by hand so the trail
-- matches the runtime path (ActionType 'pull-fully-received', EntityType
-- 'Pull', message attributes the backfill source).
-- ---------------------------------------------------------------------------
/*
BEGIN TRANSACTION;

DECLARE @backfilled TABLE (
    PullId UNIQUEIDENTIFIER NOT NULL,
    PullNumber NVARCHAR(50) NOT NULL
);

UPDATE p
   SET p.Status         = 'fully_received',
       p.LastActivityAt = SYSUTCDATETIME()
OUTPUT INSERTED.Id, INSERTED.PullNumber INTO @backfilled (PullId, PullNumber)
FROM   dbo.Pulls p
WHERE  p.Status = 'in_progress'
  AND  p.Id IN (
      SELECT pi.PullId
      FROM   dbo.PullItems pi
      INNER JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
      WHERE  pi.Status <> 'canceled'
      GROUP BY pi.PullId
      HAVING SUM(piw.ExpectedQty) = SUM(piw.ReceivedQty)
         AND SUM(piw.ExpectedQty) > 0
  );

DECLARE @rows INT = @@ROWCOUNT;
PRINT 'Backfilled ' + CAST(@rows AS NVARCHAR(10)) + ' stuck pulls to fully_received.';

-- Match the runtime audit row shape so the trail looks the same as if
-- ReceiveAsync had emitted it at receive time.
INSERT INTO dbo.AuditLog
    (ActionType, EntityType, EntityId, Message, ActorUserId, ActorName, IpAddress)
SELECT
    'pull-fully-received',
    'Pull',
    CAST(b.PullId AS NVARCHAR(64)),
    'Pull ' + b.PullNumber + ' reached fully_received — backfilled by '
        + 'tools/scripts/backfill-pull-fully-received.sql (pre-4a91883 stuck state)',
    NULL,
    '[backfill]',
    NULL
FROM @backfilled b;

-- Sanity: confirm we did not touch pulls that should not have been touched.
DECLARE @bad INT = (
    SELECT COUNT(*) FROM dbo.Pulls p
    INNER JOIN @backfilled b ON b.PullId = p.Id
    WHERE  p.Status <> 'fully_received'
       OR  p.ClosedAt IS NOT NULL
);
IF @bad > 0
BEGIN
    PRINT 'ABORT: ' + CAST(@bad AS NVARCHAR(10)) + ' pulls landed in unexpected state. Rolling back.';
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
