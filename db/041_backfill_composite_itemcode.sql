/* ============================================================================
   db/041 — Backfill composite PullItems.ItemCode -> bare SKU (SCOPED)
   ----------------------------------------------------------------------------
   Closes the data half of the §7.15 receive-link bug fixed forward in
   commit "fix(erp-sync): ItemCode = trimmed SKU only". The ERP sync used to
   synthesize ItemCode = SKU + '-' + TRIAL_ID; PurchaseOrderLines.ItemCode is
   the bare SKU (from the Excel import), so the FIFO match never fired and
   receiving was blocked with "No PO linked to this pull."

   SCOPE — deliberately narrow. Of ~23,302 dashed PullItems, this migration
   touches ONLY the 1,821 "fixable" items (≈415 (PullId, BareSku) groups across
   ≈210 pulls) defined as:
       * ItemCode contains '-', TrialId IS NOT NULL, and ItemCode ends with
         '-' + TrialId  (so the bare SKU is recoverable by stripping the
         TrialId suffix — NOT a fragile first-dash split: 4,772 legitimate
         POL.ItemCodes themselves contain dashes), AND
       * the suffix-stripped SKU matches a real PurchaseOrderLines.ItemCode for
         a PO linked to the pull (po.PullId = pull OR po.PullExternalRef =
         PullNumber), AND
       * the CURRENT composite ItemCode does NOT already match a PO line
         (excludes the 1,024 legitimate dashed SKUs that already receive fine).

   EXPLICITLY OUT OF SCOPE (left untouched):
       * 1,024 dashed items that already match a PO line (legit dashed SKUs).
       * 20,457 "orphan" dashed items with NO PO line for their pull — that is
         a "PO not imported yet" problem, not an ItemCode problem; renaming
         them would be a blind guess and wouldn't link anything today.

   MERGE SEMANTICS — multiple TRIAL_ID variants of one SKU collapse to a single
   PullItem (matching the now-fixed ERP sync + the (PullId, ItemCode) upsert
   key, which has NO DB-level unique constraint — enforced at the app layer).
   Within each (PullId, BareSku) group:
       * Survivor = a pre-existing BARE PullItem at that SKU if one already
         coexists; otherwise the deterministic-first composite (SortOrder,
         ItemCode, Id). Preferring the bare row avoids creating a duplicate
         (PullId, ItemCode).
       * Non-survivor windows are summed into the survivor by hour-of-day
         (respects UQ_PIW_Hour); non-survivor PullItems are deleted.
       * No Receipts are re-pointed: the fixable set has 0 receipts (verified
         analytically AND re-asserted below — the migration ABORTS if any are
         found, since that would mean receive history needs manual handling).

   SAFETY — single transaction (XACT_ABORT + TRY/CATCH, all-or-nothing).
   IDEMPOTENT — re-run is a no-op: after the first run the composites are gone,
   so the fixable set populates empty and every statement no-ops.

   REVIEW BEFORE RUNNING. This MERGES and DELETES rows.
   ============================================================================ */

SET XACT_ABORT ON;
SET NOCOUNT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    /* --------------------------------------------------------------------
       Step 1 — assemble the merge members.
       #Members holds every row that participates in a (PullId, BareSku)
       group: the fixable composites (IsDashed=1) plus any pre-existing bare
       PullItem already sitting at the target SKU (IsDashed=0).
       -------------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#Members') IS NOT NULL DROP TABLE #Members;
    CREATE TABLE #Members (
        PullItemId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        PullId     UNIQUEIDENTIFIER NOT NULL,
        BareSku    VARCHAR(64)      NOT NULL,
        IsDashed   BIT              NOT NULL
    );

    /* 1a — the fixable composites (the 1,821).
       Suffix-strip is authoritative because it removes EXACTLY the TrialId
       that was appended; it cannot over-truncate a dashed bare SKU. */
    ;WITH Strip AS (
        SELECT  pi.Id        AS PullItemId,
                pi.PullId,
                pi.ItemCode,
                CAST(LEFT(pi.ItemCode, LEN(pi.ItemCode) - LEN(pi.TrialId) - 1)
                     AS VARCHAR(64)) AS BareSku
        FROM    dbo.PullItems pi
        WHERE   pi.ItemCode LIKE '%-%'
          AND   pi.TrialId IS NOT NULL
          AND   pi.ItemCode LIKE '%-' + pi.TrialId    -- ItemCode ends with -TrialId
    )
    INSERT INTO #Members (PullItemId, PullId, BareSku, IsDashed)
    SELECT s.PullItemId, s.PullId, s.BareSku, 1
    FROM   Strip s
    WHERE  EXISTS (   -- stripped SKU DOES match a PO line for this pull
               SELECT 1
               FROM   dbo.Pulls p
               JOIN   dbo.PurchaseOrders po
                        ON (po.PullId = p.Id OR po.PullExternalRef = p.PullNumber)
               JOIN   dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.Id
               WHERE  p.Id = s.PullId AND pol.ItemCode = s.BareSku)
      AND  NOT EXISTS ( -- current composite ItemCode does NOT already match
               SELECT 1
               FROM   dbo.Pulls p
               JOIN   dbo.PurchaseOrders po
                        ON (po.PullId = p.Id OR po.PullExternalRef = p.PullNumber)
               JOIN   dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.Id
               WHERE  p.Id = s.PullId AND pol.ItemCode = s.ItemCode);

    /* 1b — pre-existing BARE survivors that coexist with the composites above.
       Match on exact ItemCode = BareSku (NOT dash-absence: a bare SKU may
       itself contain a dash). NOT EXISTS guard prevents PK collision. */
    INSERT INTO #Members (PullItemId, PullId, BareSku, IsDashed)
    SELECT pi.Id, pi.PullId, g.BareSku, 0
    FROM   dbo.PullItems pi
    JOIN   (SELECT DISTINCT PullId, BareSku FROM #Members) g
             ON g.PullId = pi.PullId AND g.BareSku = pi.ItemCode
    WHERE  NOT EXISTS (SELECT 1 FROM #Members x WHERE x.PullItemId = pi.Id);

    DECLARE @fixable    INT = (SELECT COUNT(*) FROM #Members WHERE IsDashed = 1);
    DECLARE @groups     INT = (SELECT COUNT(*) FROM (SELECT DISTINCT PullId, BareSku FROM #Members) z);
    DECLARE @bareExist  INT = (SELECT COUNT(*) FROM #Members WHERE IsDashed = 0);
    PRINT CONCAT('db/041: fixable composites = ', @fixable,
                 ', merge groups = ', @groups,
                 ', pre-existing bare survivors = ', @bareExist);

    /* --------------------------------------------------------------------
       Step 2 — pre-flight assertion: ZERO receipts on the fixable composites.
       The analysis showed 0; if that ever changes, abort so receive history
       can be handled deliberately rather than silently dropped.
       -------------------------------------------------------------------- */
    DECLARE @rc INT = (
        SELECT COUNT(*)
        FROM   dbo.Receipts r
        JOIN   #Members m ON m.PullItemId = r.PullItemId AND m.IsDashed = 1);
    IF @rc > 0
    BEGIN
        DECLARE @rcMsg NVARCHAR(200) =
            CONCAT('db/041 ABORT: ', @rc,
                   ' receipt(s) reference fixable composite items (expected 0). Manual review required.');
        THROW 50041, @rcMsg, 1;
    END

    /* --------------------------------------------------------------------
       Step 3 — choose one survivor per (PullId, BareSku).
       Prefer an existing bare row (IsDashed=0); else first composite by
       (SortOrder, ItemCode, Id) for determinism.
       -------------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#Survivor') IS NOT NULL DROP TABLE #Survivor;
    CREATE TABLE #Survivor (
        PullId     UNIQUEIDENTIFIER NOT NULL,
        BareSku    VARCHAR(64)      NOT NULL,
        SurvivorId UNIQUEIDENTIFIER NOT NULL,
        PRIMARY KEY (PullId, BareSku)
    );

    ;WITH Ranked AS (
        SELECT  m.PullItemId, m.PullId, m.BareSku,
                ROW_NUMBER() OVER (
                    PARTITION BY m.PullId, m.BareSku
                    ORDER BY m.IsDashed ASC,           -- bare survivor first
                             pi.SortOrder ASC,
                             pi.ItemCode ASC,
                             m.PullItemId ASC) AS rn
        FROM    #Members m
        JOIN    dbo.PullItems pi ON pi.Id = m.PullItemId
    )
    INSERT INTO #Survivor (PullId, BareSku, SurvivorId)
    SELECT PullId, BareSku, PullItemId FROM Ranked WHERE rn = 1;

    /* Losers = every member that is not its group's survivor. */
    IF OBJECT_ID('tempdb..#Losers') IS NOT NULL DROP TABLE #Losers;
    SELECT m.PullItemId, s.SurvivorId
    INTO   #Losers
    FROM   #Members m
    JOIN   #Survivor s ON s.PullId = m.PullId AND s.BareSku = m.BareSku
    WHERE  m.PullItemId <> s.SurvivorId;

    DECLARE @losers    INT = (SELECT COUNT(*) FROM #Losers);
    DECLARE @survivors INT = (SELECT COUNT(*) FROM #Survivor);

    /* --------------------------------------------------------------------
       Step 4 — fold loser windows into the survivor, by hour-of-day.
       Aggregate first, delete loser windows, then MERGE the aggregate onto
       the survivor (UPDATE existing hour / INSERT missing hour). This handles
       multiple losers sharing a missing hour without tripping UQ_PIW_Hour.
       ReceivedQty is carried (should be 0 across losers) so the fold is lossless.
       -------------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#WinAgg') IS NOT NULL DROP TABLE #WinAgg;
    SELECT  l.SurvivorId,
            w.HourOfDay,
            SUM(w.ExpectedQty) AS ExpectedQty,
            SUM(w.ReceivedQty) AS ReceivedQty
    INTO    #WinAgg
    FROM    #Losers l
    JOIN    dbo.PullItemWindows w ON w.PullItemId = l.PullItemId
    GROUP BY l.SurvivorId, w.HourOfDay;

    DELETE w
    FROM   dbo.PullItemWindows w
    JOIN   #Losers l ON l.PullItemId = w.PullItemId;

    MERGE dbo.PullItemWindows AS tgt
    USING #WinAgg AS src
        ON tgt.PullItemId = src.SurvivorId AND tgt.HourOfDay = src.HourOfDay
    WHEN MATCHED THEN
        UPDATE SET tgt.ExpectedQty = tgt.ExpectedQty + src.ExpectedQty,
                   tgt.ReceivedQty = tgt.ReceivedQty + src.ReceivedQty
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
        VALUES (NEWID(), src.SurvivorId, src.HourOfDay, src.ExpectedQty, src.ReceivedQty);

    /* --------------------------------------------------------------------
       Step 5 — delete loser PullItems (windows gone, 0 receipts asserted).
       -------------------------------------------------------------------- */
    DELETE pi
    FROM   dbo.PullItems pi
    JOIN   #Losers l ON l.PullItemId = pi.Id;

    /* --------------------------------------------------------------------
       Step 6 — rename survivors to the bare SKU.
       No-op for survivors that were already bare. TrialId is left intact
       (lot/trial metadata; matches what the fixed ERP sync now stores).
       -------------------------------------------------------------------- */
    UPDATE pi
    SET    pi.ItemCode = s.BareSku
    FROM   dbo.PullItems pi
    JOIN   #Survivor s ON s.SurvivorId = pi.Id
    WHERE  pi.ItemCode <> s.BareSku;

    /* --------------------------------------------------------------------
       Step 7 — verification (abort the whole tx on any failure).
       -------------------------------------------------------------------- */

    -- 7a. Every survivor must now match a PO line.
    DECLARE @unmatched INT = (
        SELECT COUNT(*)
        FROM   #Survivor s
        JOIN   dbo.PullItems pi ON pi.Id = s.SurvivorId
        WHERE  NOT EXISTS (
                   SELECT 1
                   FROM   dbo.Pulls p
                   JOIN   dbo.PurchaseOrders po
                            ON (po.PullId = p.Id OR po.PullExternalRef = p.PullNumber)
                   JOIN   dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.Id
                   WHERE  p.Id = pi.PullId AND pol.ItemCode = pi.ItemCode));
    IF @unmatched > 0
        THROW 50042, 'db/041 ABORT: one or more survivors do not match a PO line post-merge.', 1;

    -- 7b. No duplicate (PullId, ItemCode) among the groups we touched.
    DECLARE @dups INT = (
        SELECT COUNT(*) FROM (
            SELECT pi.PullId, pi.ItemCode
            FROM   dbo.PullItems pi
            JOIN   #Survivor s ON s.PullId = pi.PullId AND s.BareSku = pi.ItemCode
            GROUP BY pi.PullId, pi.ItemCode
            HAVING COUNT(*) > 1) d);
    IF @dups > 0
        THROW 50043, 'db/041 ABORT: duplicate (PullId, ItemCode) rows exist after merge.', 1;

    -- 7c. No windows orphaned by the loser deletes.
    DECLARE @orphanWin INT = (
        SELECT COUNT(*)
        FROM   dbo.PullItemWindows w
        WHERE  NOT EXISTS (SELECT 1 FROM dbo.PullItems pi WHERE pi.Id = w.PullItemId));
    IF @orphanWin > 0
        THROW 50044, 'db/041 ABORT: orphaned PullItemWindows rows detected.', 1;

    PRINT CONCAT('db/041 OK: survivors = ', @survivors,
                 ', loser items deleted = ', @losers,
                 ', all survivors PO-matched, no dup/orphan.');

    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH;
