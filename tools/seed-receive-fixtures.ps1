# Restores the db/006 fixtures the receive-path smokes depend on.
#
# WHY THIS EXISTS
# ---------------
# db/035 (Phase 14 destructive wipe) removed every Pulls row. db/006 seeded
# PL-2840..PL-2851 with fixed GUIDs, and several smokes address those GUIDs
# directly. Only PL-2847 was ever restored (by db/038), so smoke-receive and
# smoke-close-reopen have been failing in SETUP — not on an assertion — ever
# since. A suite that dies before its first assertion provides no coverage,
# which meant the receive path had none.
#
# WHY NOT JUST RE-RUN db/006
# --------------------------
# It is idempotent, but it is no longer schema-compatible:
#   • its dbo.Receipts INSERTs omit PurchaseOrderId / PurchaseOrderLineId, which
#     db/011 made NOT NULL in the v2 strict schema;
#   • it references vendor columns on dbo.PurchaseOrders that db/036 dropped when
#     vendor moved to the line.
# Re-running it would fail partway and leave the database in a worse state than
# the gap it was meant to close. This script restores only the subset the receive
# smokes address, in a shape the current schema accepts.
#
# WHAT IT SEEDS (idempotent — safe to re-run, guards on every INSERT):
#   • PL-2840  WH-01 Bangkok   closed          SUMMARY window hour 12, expected 11000
#   • PL-2843  WH-03 Rayong    fully_received  SUMMARY window hour 12, expected   600
#   • PL-2844  WH-02 Chonburi  in_progress     SUMMARY window hour 12, expected  3200
#   • SUMMARY PO cover in WH-02 and WH-03 (WH-01 already has PO-SEED-SUMMARY-WH01).
#     Without it the receives allocate nothing: these pulls are Mode A
#     (LockPoByPull = 0), so FIFO is warehouse-wide and still needs a PO in THAT
#     warehouse carrying the SUMMARY item.
#
# Values are copied from db/006 verbatim (GUIDs, dates, quantities, authors) so the
# smokes see the fixture they were written against, not an approximation of it.
#
# Not in the smoke battery — a fixture restorer, run on demand.

$ErrorActionPreference = 'Stop'

$sql = @'
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;

DECLARE @uPsomchai   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000003';
DECLARE @uNpatcharin UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000004';
DECLARE @uKanucha    UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000005';
DECLARE @uSadmin     UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000001';

DECLARE @wBkk      UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000001';
DECLARE @wChonburi UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000002';
DECLARE @wRayong   UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000003';

DECLARE @p2840 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002840';
DECLARE @p2843 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002843';
DECLARE @p2844 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002844';

DECLARE @sig NVARCHAR(MAX) =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

-------------------------------------------------------------------- 1. Pulls
IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2840')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Notes, CreatedBy,
                           FirstReceiptAt, LastActivityAt, ClosedAt, ClosedBy, SignatureSvg)
    VALUES (@p2840, 'PL-2840', @wBkk, '2026-03-10', 'closed', NULL, @uPsomchai,
            '2026-03-10T00:30:00', '2026-03-10T09:55:00',
            '2026-03-10T09:55:00', @uPsomchai, @sig);

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2843')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Notes, CreatedBy,
                           FirstReceiptAt, LastActivityAt)
    VALUES (@p2843, 'PL-2843', @wRayong, '2026-03-16', 'fully_received', NULL, @uKanucha,
            '2026-03-16T02:15:00', '2026-03-16T07:20:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2844')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy,
                           FirstReceiptAt, LastActivityAt)
    VALUES (@p2844, 'PL-2844', @wChonburi, '2026-03-17', 'in_progress', 'Today 17:00', NULL, @uNpatcharin,
            '2026-03-17T03:30:00', '2026-03-17T05:15:00');

--------------------------------------------------- 2. SUMMARY items + windows
;WITH src(PullId, ItemGuid, Expected) AS (SELECT * FROM (VALUES
    (@p2840, CAST('44444444-4444-4444-2840-000000000001' AS UNIQUEIDENTIFIER), 11000),
    (@p2843, CAST('44444444-4444-4444-2843-000000000001' AS UNIQUEIDENTIFIER),   600),
    (@p2844, CAST('44444444-4444-4444-2844-000000000001' AS UNIQUEIDENTIFIER),  3200)
) AS v(PullId, ItemGuid, Expected))
INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, Status, SortOrder)
SELECT s.ItemGuid, s.PullId, 'SUMMARY', N'Summary row · see dashboard for breakdown', 'normal', 1
FROM   src s
WHERE  NOT EXISTS (SELECT 1 FROM dbo.PullItems pi WHERE pi.Id = s.ItemGuid);

;WITH src(ItemGuid, Expected) AS (SELECT * FROM (VALUES
    (CAST('44444444-4444-4444-2840-000000000001' AS UNIQUEIDENTIFIER), 11000),
    (CAST('44444444-4444-4444-2843-000000000001' AS UNIQUEIDENTIFIER),   600),
    (CAST('44444444-4444-4444-2844-000000000001' AS UNIQUEIDENTIFIER),  3200)
) AS v(ItemGuid, Expected))
INSERT INTO dbo.PullItemWindows (PullItemId, HourOfDay, ExpectedQty)
SELECT s.ItemGuid, CAST(12 AS TINYINT), s.Expected
FROM   src s
WHERE  NOT EXISTS (SELECT 1 FROM dbo.PullItemWindows w
                   WHERE w.PullItemId = s.ItemGuid AND w.HourOfDay = 12);

------------------------------------------- 3. SUMMARY PO cover for WH-02/WH-03
-- Mode A pulls walk FIFO warehouse-wide, so the cover must live in the SAME
-- warehouse as the pull. WH-01 already has PO-SEED-SUMMARY-WH01 from db/014.
;WITH src(PoNumber, Wh) AS (SELECT * FROM (VALUES
    ('PO-SEED-SUMMARY-WH02', @wChonburi),
    ('PO-SEED-SUMMARY-WH03', @wRayong)
) AS v(PoNumber, Wh))
INSERT INTO dbo.PurchaseOrders (PoNumber, WarehouseId, OrderDate, Status, CreatedBy)
SELECT s.PoNumber, s.Wh, '2026-03-01', 'open', @uSadmin
FROM   src s
WHERE  NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders po WHERE po.PoNumber = s.PoNumber);

INSERT INTO dbo.PurchaseOrderLines
    (PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName)
SELECT po.Id, 1, 'SUMMARY', N'Smoke sandbox cover for SUMMARY', 50000, 0, 'COI-SEEDVENDOR', N'Seed Vendor'
FROM   dbo.PurchaseOrders po
WHERE  po.PoNumber IN ('PO-SEED-SUMMARY-WH02','PO-SEED-SUMMARY-WH03')
  AND  NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol
                   WHERE pol.PurchaseOrderId = po.Id AND pol.ItemCode = 'SUMMARY');

------------------------------------------------------------------ 4. Reset
-- These smokes were written against a freshly-seeded database and do not reset
-- their own window state, so each run accumulates: smoke-receive asserts
-- newReceivedQty = 100 and sees 100, then 200, then 300 on successive runs.
-- Restoring the fixture therefore has to mean restoring it to ZERO, not merely
-- creating it — otherwise the second run of the suite fails for a reason that
-- has nothing to do with the code under test.
DECLARE @items TABLE (Id UNIQUEIDENTIFIER PRIMARY KEY);
INSERT INTO @items (Id) VALUES
    ('44444444-4444-4444-2840-000000000001'),
    ('44444444-4444-4444-2843-000000000001'),
    ('44444444-4444-4444-2844-000000000001');

-- Remember the PO lines these receipts consumed, then set them back from truth.
DECLARE @lines TABLE (LineId UNIQUEIDENTIFIER PRIMARY KEY);
INSERT INTO @lines (LineId)
SELECT DISTINCT r.PurchaseOrderLineId FROM dbo.Receipts r
WHERE r.PullItemId IN (SELECT Id FROM @items) AND r.PurchaseOrderLineId IS NOT NULL;

-- Order matters, in both directions of the self-reference:
--   original.ReversedById      -> reversal.Id   (FK_Receipts_Reversed)
--   reversal.ReversesReceiptId -> original.Id   (FK_Receipts_Reverses)
-- So the back-link must be cleared BEFORE the reversal can be deleted, and the
-- reversal must go before its original. Deleting children-first alone fails.
-- ReversedById is nullable and carries no CHECK, unlike ReversesReceiptId (§7.10).
UPDATE dbo.Receipts SET ReversedById = NULL WHERE PullItemId IN (SELECT Id FROM @items);
DELETE FROM dbo.Receipts
 WHERE PullItemId IN (SELECT Id FROM @items) AND ReversesReceiptId IS NOT NULL;
DELETE FROM dbo.Receipts WHERE PullItemId IN (SELECT Id FROM @items);

UPDATE pol SET ReceivedQty = ISNULL(t.Qty, 0)
FROM dbo.PurchaseOrderLines pol
INNER JOIN @lines l ON l.LineId = pol.Id
OUTER APPLY (SELECT SUM(r.QtyReceived) AS Qty FROM dbo.Receipts r
             WHERE r.PurchaseOrderLineId = pol.Id) t;

UPDATE po SET Status = 'open', ClosedAt = NULL
FROM dbo.PurchaseOrders po
WHERE po.Status = 'closed'
  AND EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol
              INNER JOIN @lines l ON l.LineId = pol.Id
              WHERE pol.PurchaseOrderId = po.Id AND pol.OrderedQty > pol.ReceivedQty);

UPDATE dbo.PullItemWindows
   SET ReceivedQty = 0, IsClosed = 0, ClosedAt = NULL, ClosedBy = NULL, ClosedReason = NULL
 WHERE PullItemId IN (SELECT Id FROM @items);

-- Restore each pull's seeded status (smoke-close-reopen closes PL-2843; a
-- previous run must not leave it closed for the next).
UPDATE dbo.Pulls SET Status = 'fully_received', ClosedAt = NULL, ClosedBy = NULL,
       SignatureSvg = NULL, ReopenedAt = NULL, ReopenedBy = NULL, ReopenReason = NULL
 WHERE Id = @p2843;
UPDATE dbo.Pulls SET Status = 'in_progress' WHERE Id = @p2844;
UPDATE dbo.Pulls SET Status = 'closed', ClosedAt = '2026-03-10T09:55:00',
       ClosedBy = @uPsomchai, SignatureSvg = @sig
 WHERE Id = @p2840;

DELETE FROM dbo.AuditLog WHERE EntityType = 'Pull'
  AND EntityId IN (CAST(@p2840 AS NVARCHAR(50)), CAST(@p2843 AS NVARCHAR(50)), CAST(@p2844 AS NVARCHAR(50)));

----------------------------------------- 4b. PL-2900 / PO-2405-001 seed state
-- db/016 seeds PO-2405-001 as 'open' with 500 pcs unreceived, dedicated to the
-- strict-mode pull PL-2900. Successive smoke runs received against it until the
-- line filled and §7.2 step 5 auto-closed the PO — after which
-- ReadOpenPoLinesAsync (which filters po.Status = 'open') returns nothing and
-- smoke-phase-4a step (b) fails with "No PO linked to this pull".
--
-- That is run drift, not a wipe, so restoring it is the same kind of reset as
-- above. LockHourCap is deliberately NOT touched here: smoke-hourcap-6.5 test 10
-- asserts PL-2900/PL-2901 carry LockHourCap = 1 as a property of the db/017
-- backfill, and db/048 has since made unlocked the default. Writing a 1 onto
-- rows the backfill never touched would manufacture the very evidence the test
-- is checking for. That assertion needs a decision, not a fixture poke.
DECLARE @p2900   UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002900';
DECLARE @i2900_1 UNIQUEIDENTIFIER = '44444444-4444-4444-2900-000000000001';
DECLARE @po501L1 UNIQUEIDENTIFIER = '77777777-7777-7777-7777-120100000001';

IF EXISTS (SELECT 1 FROM dbo.Pulls WHERE Id = @p2900)
BEGIN
    UPDATE dbo.Receipts SET ReversedById = NULL WHERE PullItemId = @i2900_1;
    DELETE FROM dbo.Receipts WHERE PullItemId = @i2900_1 AND ReversesReceiptId IS NOT NULL;
    DELETE FROM dbo.Receipts WHERE PullItemId = @i2900_1;

    UPDATE dbo.PullItemWindows
       SET ReceivedQty = 0, IsClosed = 0, ClosedAt = NULL, ClosedBy = NULL, ClosedReason = NULL
     WHERE PullItemId = @i2900_1;

    UPDATE dbo.PurchaseOrderLines SET ReceivedQty = 0 WHERE Id = @po501L1;
    UPDATE dbo.PurchaseOrders SET Status = 'open', ClosedAt = NULL WHERE PoNumber = 'PO-2405-001';
    UPDATE dbo.Pulls SET Status = 'pending', FirstReceiptAt = NULL WHERE Id = @p2900;
END

--------------------------------------------------------------------- 5. Report
SELECT p.PullNumber, w.Code AS Wh, p.Status, p.LockPoByPull, p.LockHourCap,
       piw.HourOfDay, piw.ExpectedQty, piw.ReceivedQty
FROM   dbo.Pulls p
JOIN   dbo.Warehouses w ON w.Id = p.WarehouseId
JOIN   dbo.PullItems pi ON pi.PullId = p.Id
JOIN   dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
WHERE  p.PullNumber IN ('PL-2840','PL-2843','PL-2844')
ORDER BY p.PullNumber;
'@

# Via a temp file rather than -Q. sqlcmd re-tokenizes the -Q argument and treats a
# bare "/" inside it as a switch prefix, so a comment like "PL-2900 / PO-2405-001"
# aborts the whole run with "'-' or '/' does not have an associated argument" —
# before executing any SQL at all. -i has no such hazard and the failure mode is
# silent enough (exit 1, no SQL run) to be worth avoiding permanently.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("seed-receive-fixtures-{0}.sql" -f [guid]::NewGuid())
try {
    Set-Content -Path $tmp -Value $sql -Encoding UTF8
    $out = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -W -i $tmp 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host ($out | Out-String) -ForegroundColor Red; throw 'seed failed' }
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}
Write-Host ($out | Out-String)
Write-Host 'Receive fixtures restored (idempotent).' -ForegroundColor Green
