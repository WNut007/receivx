/* ============================================================================
   ReceivingOps — 006_seed_pulls_and_items.sql
   ----------------------------------------------------------------------------
   12 pulls (PL-2840 through PL-2851) + items + windows + ~20 receipts.

     • Metadata for all 12 pulls matches pull-controller-v2.html seed array
       (status, date, warehouse, item count, expected/received totals).
     • PL-2847 carries the FULL 8-item set + per-hour schedule from
       receiving-mockup-v2-fullreceived.html so the Receiving page works.
     • Other pulls carry a SINGLE representative item + window sized so the
       vw_PullProgress totals match the mockup's dashboard cards.
     • Receipts seeded for PL-2847 only, including two reversal pairs per §4.11:
         r-1005 (1500 RES-10K hour 7) → r-1007 (-1500, qc-fail)
         r-2002 (2000 RES-10K hour 11) → r-2003 (-2000, miscount) → r-2004 (200, correction)
     • Closed pulls (PL-2840, PL-2841, PL-2842) carry ClosedAt/ClosedBy/SignatureSvg.

   Idempotent: every INSERT is guarded by IF NOT EXISTS. PullItemWindows.ReceivedQty
   is set via DB-side recalculation against vw_PullItemReceived AFTER the receipts
   are inserted, so re-runs converge to the correct cache value.
   ============================================================================ */

USE [ReceivingOps];
GO

-- sqlcmd defaults QUOTED_IDENTIFIER OFF; filtered indexes (IX_Receipts_Reverses)
-- require it ON for any INSERT/UPDATE against the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

------------------------------------------------------------------------------
-- Stable GUIDs reused from earlier seed files
------------------------------------------------------------------------------
DECLARE @uSadmin     UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000001';
DECLARE @uSwattana   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000002';
DECLARE @uPsomchai   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000003';
DECLARE @uNpatcharin UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000004';
DECLARE @uKanucha    UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000005';

DECLARE @wBkk      UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000001';
DECLARE @wChonburi UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000002';
DECLARE @wRayong   UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000003';

-- GUIDs for the 12 pulls. Last segment = pull number (4 hex digits).
DECLARE @p2840 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002840';
DECLARE @p2841 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002841';
DECLARE @p2842 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002842';
DECLARE @p2843 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002843';
DECLARE @p2844 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002844';
DECLARE @p2845 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002845';
DECLARE @p2846 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002846';
DECLARE @p2847 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002847';
DECLARE @p2848 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002848';
DECLARE @p2849 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002849';
DECLARE @p2850 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002850';
DECLARE @p2851 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002851';

------------------------------------------------------------------------------
-- 1. Pulls (12)
------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2851')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy)
    VALUES (@p2851, 'PL-2851', @wBkk, '2026-03-18', 'pending', '19:00', 'urgent', @uSwattana);

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2850')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy)
    VALUES (@p2850, 'PL-2850', @wChonburi, '2026-03-18', 'pending', '18:30', NULL, @uNpatcharin);

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2849')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy)
    VALUES (@p2849, 'PL-2849', @wRayong, '2026-03-18', 'pending', '17:00', NULL, @uKanucha);

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2848')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy, FirstReceiptAt, LastActivityAt)
    VALUES (@p2848, 'PL-2848', @wBkk, '2026-03-18', 'in_progress', '16:00', NULL, @uPsomchai,
            '2026-03-18T01:12:00', '2026-03-18T07:05:00');  -- 08:12 ICT = 01:12 UTC, 14:05 ICT = 07:05 UTC

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2847')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy, FirstReceiptAt, LastActivityAt)
    VALUES (@p2847, 'PL-2847', @wBkk, '2026-03-18', 'in_progress', '15:00', 'urgent', @uSwattana,
            '2026-03-18T00:24:00', '2026-03-18T07:18:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2846')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy, FirstReceiptAt, LastActivityAt)
    VALUES (@p2846, 'PL-2846', @wBkk, '2026-03-17', 'in_progress', 'Today 16:00', 'late', @uPsomchai,
            '2026-03-17T02:01:00', '2026-03-17T06:42:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2844')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy, FirstReceiptAt, LastActivityAt)
    VALUES (@p2844, 'PL-2844', @wChonburi, '2026-03-17', 'in_progress', 'Today 17:00', NULL, @uNpatcharin,
            '2026-03-17T03:30:00', '2026-03-17T05:15:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2845')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Notes, CreatedBy, FirstReceiptAt, LastActivityAt)
    VALUES (@p2845, 'PL-2845', @wBkk, '2026-03-16', 'fully_received', NULL, @uSwattana,
            '2026-03-16T01:00:00', '2026-03-16T06:50:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2843')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Notes, CreatedBy, FirstReceiptAt, LastActivityAt)
    VALUES (@p2843, 'PL-2843', @wRayong, '2026-03-16', 'fully_received', NULL, @uKanucha,
            '2026-03-16T02:15:00', '2026-03-16T07:20:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2842')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Notes, CreatedBy, FirstReceiptAt, LastActivityAt, ClosedAt, ClosedBy, SignatureSvg)
    VALUES (@p2842, 'PL-2842', @wBkk, '2026-03-15', 'closed', NULL, @uSwattana,
            '2026-03-15T00:48:00', '2026-03-15T09:10:00',
            '2026-03-15T09:10:00', @uSwattana,
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2841')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Notes, CreatedBy, FirstReceiptAt, LastActivityAt, ClosedAt, ClosedBy, SignatureSvg)
    VALUES (@p2841, 'PL-2841', @wChonburi, '2026-03-12', 'closed', NULL, @uNpatcharin,
            '2026-03-12T01:20:00', '2026-03-12T08:45:00',
            '2026-03-12T08:45:00', @uNpatcharin,
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2840')
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Notes, CreatedBy, FirstReceiptAt, LastActivityAt, ClosedAt, ClosedBy, SignatureSvg)
    VALUES (@p2840, 'PL-2840', @wBkk, '2026-03-10', 'closed', NULL, @uPsomchai,
            '2026-03-10T00:30:00', '2026-03-10T09:55:00',
            '2026-03-10T09:55:00', @uPsomchai,
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

PRINT '12 Pulls seeded.';
GO

------------------------------------------------------------------------------
-- 2. PullItems for PL-2847 — full 8-item set from receiving mockup
------------------------------------------------------------------------------
DECLARE @p2847 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002847';

-- Item GUIDs: 4th group encodes pull number (e.g. 2847), suffix counts items.
DECLARE @i2847_1 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000001'; -- PCBA-AX450-R2
DECLARE @i2847_2 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000002'; -- PCBA-AX451-R2
DECLARE @i2847_3 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000003'; -- CAP-470UF-25V
DECLARE @i2847_4 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000004'; -- RES-10K-1%
DECLARE @i2847_5 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000005'; -- MOSFET-N-30V (canceled)
DECLARE @i2847_6 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000006'; -- CONN-USB-C-16
DECLARE @i2847_7 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000007'; -- LCD-3.5-IPS (new)
DECLARE @i2847_8 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000008'; -- SHIELD-RF-A1

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2847_1)
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Tag, Status, Remark, SortOrder)
    VALUES (@i2847_1, @p2847, 'PCBA-AX450-R2', N'Main Logic Board · Rev 2',     'FXL-002', N'Foxlink Electronics', 'pcba', 'normal',   N'Priority — line A', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2847_2)
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Tag, Status, Remark, SortOrder)
    VALUES (@i2847_2, @p2847, 'PCBA-AX451-R2', N'Daughter Board · Swap pair',   'FXL-002', N'Foxlink Electronics', 'swap', 'normal',   N'Pairs with AX450',  2);

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2847_3)
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Tag, Status, Remark, SortOrder)
    VALUES (@i2847_3, @p2847, 'CAP-470UF-25V', N'Electrolytic Capacitor',       'NCC-114', N'Nichicon Asia',       NULL,   'normal',   N'—',                  3);

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2847_4)
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Tag, Status, Remark, SortOrder)
    VALUES (@i2847_4, @p2847, 'RES-10K-1%',    N'Precision Resistor SMD',       'YAG-088', N'Yageo Corp',          NULL,   'normal',   N'Reel · 5000',        4);

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2847_5)
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Tag, Status, Remark, SortOrder)
    VALUES (@i2847_5, @p2847, 'MOSFET-N-30V',  N'Power MOSFET TO-220',          'INF-201', N'Infineon Tech',       NULL,   'canceled', N'Vendor cancel',      5);

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2847_6)
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Tag, Status, Remark, SortOrder)
    VALUES (@i2847_6, @p2847, 'CONN-USB-C-16', N'USB-C Connector 16-pin',       'JST-040', N'J.S.T. Mfg',          NULL,   'normal',   N'—',                  6);

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2847_7)
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Tag, Status, Remark, SortOrder)
    VALUES (@i2847_7, @p2847, 'LCD-3.5-IPS',   N'3.5" IPS Display Module',      'TVE-555', N'Truly Display',       NULL,   'new',      N'Added today',        7);

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2847_8)
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Tag, Status, Remark, SortOrder)
    VALUES (@i2847_8, @p2847, 'SHIELD-RF-A1',  N'RF Shield Can Type-A',         'ALP-919', N'Alps Alpine',         NULL,   'normal',   N'Match w/ PCBA',      8);

PRINT 'PL-2847: 8 items seeded.';
GO

------------------------------------------------------------------------------
-- 3. PullItemWindows for PL-2847 — per-hour schedules from receiving mockup
--    ReceivedQty is left at 0 here; it's recalculated from receipts at the end.
------------------------------------------------------------------------------
DECLARE @i2847_1 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000001';
DECLARE @i2847_2 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000002';
DECLARE @i2847_3 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000003';
DECLARE @i2847_4 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000004';
DECLARE @i2847_5 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000005';
DECLARE @i2847_6 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000006';
DECLARE @i2847_7 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000007';
DECLARE @i2847_8 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000008';

-- Idempotent helper: insert window only when (item, hour) doesn't exist
;WITH src(PullItemId, HourOfDay, ExpectedQty) AS (SELECT * FROM (VALUES
    -- PCBA-AX450-R2
    (@i2847_1, CAST(7 AS TINYINT),  300), (@i2847_1, 8,  300), (@i2847_1, 9,  200), (@i2847_1, 10, 200),
    (@i2847_1, 11, 300), (@i2847_1, 12, 1000),(@i2847_1, 14, 500), (@i2847_1, 15, 400),
    (@i2847_1, 16, 400), (@i2847_1, 17, 600), (@i2847_1, 18, 600), (@i2847_1, 19, 300),
    (@i2847_1, 20, 300), (@i2847_1, 22, 200),
    -- PCBA-AX451-R2
    (@i2847_2, 7,  300), (@i2847_2, 9,  200), (@i2847_2, 10, 200), (@i2847_2, 11, 300),
    (@i2847_2, 12, 1000),(@i2847_2, 14, 500), (@i2847_2, 15, 400), (@i2847_2, 16, 400),
    (@i2847_2, 17, 400), (@i2847_2, 20, 600), (@i2847_2, 21, 300),
    -- CAP-470UF-25V
    (@i2847_3, 7,  1500),(@i2847_3, 8,  1500),(@i2847_3, 9,  1500),(@i2847_3, 11, 2000),
    (@i2847_3, 12, 2000),(@i2847_3, 13, 1500),(@i2847_3, 15, 1000),(@i2847_3, 16, 1000),
    (@i2847_3, 17, 1500),(@i2847_3, 18, 1500),(@i2847_3, 23, 800), (@i2847_3, 0,  800),
    (@i2847_3, 1,  600),
    -- RES-10K-1%
    (@i2847_4, 7,  5000),(@i2847_4, 9,  3000),(@i2847_4, 11, 5000),(@i2847_4, 13, 5000),
    (@i2847_4, 15, 2000),(@i2847_4, 17, 5000),(@i2847_4, 20, 3000),(@i2847_4, 4,  2000),
    -- MOSFET-N-30V (canceled — excluded from totals but still tracked)
    (@i2847_5, 12, 500), (@i2847_5, 13, 500), (@i2847_5, 14, 500), (@i2847_5, 15, 500),
    (@i2847_5, 16, 500),
    -- CONN-USB-C-16
    (@i2847_6, 7,  200), (@i2847_6, 8,  200), (@i2847_6, 12, 200), (@i2847_6, 13, 200),
    (@i2847_6, 14, 200), (@i2847_6, 15, 200), (@i2847_6, 16, 200), (@i2847_6, 18, 200),
    (@i2847_6, 19, 100), (@i2847_6, 20, 100),
    -- LCD-3.5-IPS (new)
    (@i2847_7, 7,  50),  (@i2847_7, 8,  50),  (@i2847_7, 9,  50),  (@i2847_7, 10, 50),
    (@i2847_7, 11, 50),  (@i2847_7, 12, 50),  (@i2847_7, 13, 50),  (@i2847_7, 14, 50),
    (@i2847_7, 15, 50),  (@i2847_7, 16, 50),  (@i2847_7, 17, 50),  (@i2847_7, 18, 50),
    (@i2847_7, 19, 30),  (@i2847_7, 20, 30),  (@i2847_7, 3,  20),  (@i2847_7, 4,  20),
    -- SHIELD-RF-A1
    (@i2847_8, 7,  300), (@i2847_8, 8,  300), (@i2847_8, 10, 300), (@i2847_8, 11, 300),
    (@i2847_8, 12, 300), (@i2847_8, 13, 300), (@i2847_8, 14, 300), (@i2847_8, 15, 300),
    (@i2847_8, 16, 300), (@i2847_8, 17, 300), (@i2847_8, 21, 300), (@i2847_8, 22, 300)
) AS v(PullItemId, HourOfDay, ExpectedQty))
INSERT INTO dbo.PullItemWindows (PullItemId, HourOfDay, ExpectedQty)
SELECT s.PullItemId, s.HourOfDay, s.ExpectedQty
FROM   src s
WHERE  NOT EXISTS (SELECT 1 FROM dbo.PullItemWindows w
                   WHERE w.PullItemId = s.PullItemId AND w.HourOfDay = s.HourOfDay);

PRINT 'PL-2847: per-hour windows seeded.';
GO

------------------------------------------------------------------------------
-- 4. Other pulls — one synthetic item + one window each so totals match
--    the mockup dashboard cards (vw_PullProgress reads these).
--    Format: ItemCode = 'SUMMARY', Expected = mockup.expected.
------------------------------------------------------------------------------
DECLARE @p2840 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002840';
DECLARE @p2841 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002841';
DECLARE @p2842 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002842';
DECLARE @p2843 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002843';
DECLARE @p2844 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002844';
DECLARE @p2845 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002845';
DECLARE @p2846 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002846';
DECLARE @p2848 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002848';
DECLARE @p2849 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002849';
DECLARE @p2850 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002850';
DECLARE @p2851 UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002851';

-- Single SUMMARY item + window per pull. Window receivedQty is set later from receipts.
;WITH src(PullId, ItemGuid, Expected) AS (SELECT * FROM (VALUES
    (@p2840, CAST('44444444-4444-4444-2840-000000000001' AS UNIQUEIDENTIFIER), 11000),
    (@p2841, CAST('44444444-4444-4444-2841-000000000001' AS UNIQUEIDENTIFIER),  4000),
    (@p2842, CAST('44444444-4444-4444-2842-000000000001' AS UNIQUEIDENTIFIER),  7200),
    (@p2843, CAST('44444444-4444-4444-2843-000000000001' AS UNIQUEIDENTIFIER),   600),
    (@p2844, CAST('44444444-4444-4444-2844-000000000001' AS UNIQUEIDENTIFIER),  3200),
    (@p2845, CAST('44444444-4444-4444-2845-000000000001' AS UNIQUEIDENTIFIER),  5500),
    (@p2846, CAST('44444444-4444-4444-2846-000000000001' AS UNIQUEIDENTIFIER),  4900),
    (@p2848, CAST('44444444-4444-4444-2848-000000000001' AS UNIQUEIDENTIFIER),  6800),
    (@p2849, CAST('44444444-4444-4444-2849-000000000001' AS UNIQUEIDENTIFIER),   180),
    (@p2850, CAST('44444444-4444-4444-2850-000000000001' AS UNIQUEIDENTIFIER),  2800),
    (@p2851, CAST('44444444-4444-4444-2851-000000000001' AS UNIQUEIDENTIFIER),  4200)
) AS v(PullId, ItemGuid, Expected))
INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, Status, SortOrder)
SELECT s.ItemGuid, s.PullId, 'SUMMARY', N'Summary row · see dashboard for breakdown', 'normal', 1
FROM   src s
WHERE  NOT EXISTS (SELECT 1 FROM dbo.PullItems pi WHERE pi.Id = s.ItemGuid);

;WITH src(ItemGuid, Expected) AS (SELECT * FROM (VALUES
    (CAST('44444444-4444-4444-2840-000000000001' AS UNIQUEIDENTIFIER), 11000),
    (CAST('44444444-4444-4444-2841-000000000001' AS UNIQUEIDENTIFIER),  4000),
    (CAST('44444444-4444-4444-2842-000000000001' AS UNIQUEIDENTIFIER),  7200),
    (CAST('44444444-4444-4444-2843-000000000001' AS UNIQUEIDENTIFIER),   600),
    (CAST('44444444-4444-4444-2844-000000000001' AS UNIQUEIDENTIFIER),  3200),
    (CAST('44444444-4444-4444-2845-000000000001' AS UNIQUEIDENTIFIER),  5500),
    (CAST('44444444-4444-4444-2846-000000000001' AS UNIQUEIDENTIFIER),  4900),
    (CAST('44444444-4444-4444-2848-000000000001' AS UNIQUEIDENTIFIER),  6800),
    (CAST('44444444-4444-4444-2849-000000000001' AS UNIQUEIDENTIFIER),   180),
    (CAST('44444444-4444-4444-2850-000000000001' AS UNIQUEIDENTIFIER),  2800),
    (CAST('44444444-4444-4444-2851-000000000001' AS UNIQUEIDENTIFIER),  4200)
) AS v(ItemGuid, Expected))
INSERT INTO dbo.PullItemWindows (PullItemId, HourOfDay, ExpectedQty)
SELECT s.ItemGuid, CAST(12 AS TINYINT), s.Expected
FROM   src s
WHERE  NOT EXISTS (SELECT 1 FROM dbo.PullItemWindows w
                   WHERE w.PullItemId = s.ItemGuid AND w.HourOfDay = 12);

PRINT '11 SUMMARY items + windows seeded for non-PL-2847 pulls.';
GO

------------------------------------------------------------------------------
-- 5. Receipts — ~20 for PL-2847 including 2 reversal pairs (§4.11)
------------------------------------------------------------------------------
DECLARE @uSwattana   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000002';
DECLARE @uPsomchai   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000003';
DECLARE @uNpatcharin UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000004';

DECLARE @i2847_1 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000001'; -- PCBA-AX450-R2
DECLARE @i2847_2 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000002'; -- PCBA-AX451-R2
DECLARE @i2847_3 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000003'; -- CAP-470UF-25V
DECLARE @i2847_4 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000004'; -- RES-10K-1%
DECLARE @i2847_6 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000006'; -- CONN-USB-C-16
DECLARE @i2847_7 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000007'; -- LCD-3.5-IPS
DECLARE @i2847_8 UNIQUEIDENTIFIER = '44444444-4444-4444-2847-000000000008'; -- SHIELD-RF-A1

-- Stable receipt GUIDs: suffix encodes the legacy mockup id (r-1001 etc).
DECLARE @r1001 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001001';
DECLARE @r1002 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001002';
DECLARE @r1003 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001003';
DECLARE @r1004 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001004';
DECLARE @r1005 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001005'; -- QC-fail target (5000 RES @ hour 7)
DECLARE @r1006 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001006';
DECLARE @r1007 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001007'; -- QC-fail reversal of r-1005
DECLARE @r1008 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001008';
DECLARE @r1009 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001009';
DECLARE @r1010 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001010';
DECLARE @r1011 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001011';
DECLARE @r1012 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001012';
DECLARE @r1013 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001013';
DECLARE @r1014 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001014';
DECLARE @r1015 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000001015';
DECLARE @r2002 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000002002'; -- Miscount target (2000 RES @ hour 11)
DECLARE @r2003 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000002003'; -- Miscount reversal of r-2002
DECLARE @r2004 UNIQUEIDENTIFIER = '55555555-5555-5555-5555-000000002004'; -- Correction: 200, the right qty

-- PCBA-AX450-R2 receipts (Swattana)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1001)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1001, @i2847_1, 7,  300, 'LOT-2401-018', 'PLT-00470', 'A-12-01', 'passed', @uSwattana, '2026-03-18T00:24:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1002)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1002, @i2847_1, 8,  300, 'LOT-2401-018', 'PLT-00471', 'A-12-01', 'passed', @uSwattana, '2026-03-18T01:24:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1003)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1003, @i2847_1, 12, 1000,'LOT-2401-018', 'PLT-00472', 'A-12-02', 'passed', @uSwattana, '2026-03-18T05:30:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1004)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1004, @i2847_1, 14, 500, 'LOT-2401-019', 'PLT-00475', 'A-12-02', 'passed', @uSwattana, '2026-03-18T07:18:00');

-- PCBA-AX451-R2 receipts
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1008)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1008, @i2847_2, 7,  300, 'LOT-2401-020', 'PLT-00476', 'A-13-01', 'passed', @uSwattana, '2026-03-18T00:35:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1009)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1009, @i2847_2, 12, 1000,'LOT-2401-020', 'PLT-00477', 'A-13-01', 'passed', @uSwattana, '2026-03-18T05:40:00');

-- CAP-470UF-25V receipts (Psomchai handles)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1010)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1010, @i2847_3, 7,  1500,'LOT-2403-044', 'PLT-00478', 'B-05-03', 'passed', @uPsomchai, '2026-03-18T00:45:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1011)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1011, @i2847_3, 11, 2000,'LOT-2403-044', 'PLT-00479', 'B-05-03', 'passed', @uPsomchai, '2026-03-18T04:50:00');

-- RES-10K-1% receipts
-- r-1005: original 5000 @ hour 7 — will be QC-fail reversed by r-1007 (results in net 0 @ hour 7)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1005)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, Note, ReceivedBy, ReceivedAt)
    VALUES (@r1005, @i2847_4, 7,  5000, 'LOT-2403-051', 'PLT-00480', 'C-02-01', 'rejected', N'Failed visual QC — surface defects', @uNpatcharin, '2026-03-18T00:55:00');

-- r-1006: legitimate receipt @ hour 9 (3000)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1006)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1006, @i2847_4, 9,  3000, 'LOT-2403-052', 'PLT-00481', 'C-02-01', 'passed', @uNpatcharin, '2026-03-18T02:40:00');

-- r-1007: REVERSAL of r-1005 (qc-fail, -5000)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1007)
BEGIN
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus,
                              Note, ReceivedBy, ReceivedAt, ReversesReceiptId, CancelReason)
    VALUES (@r1007, @i2847_4, 7, -5000, 'LOT-2403-051', 'PLT-00480', 'C-02-01', 'rejected',
            N'Reversed — entire lot failed final QC', @uNpatcharin, '2026-03-18T03:10:00', @r1005, 'qc-fail');
    UPDATE dbo.Receipts SET ReversedById = @r1007 WHERE Id = @r1005;
END;

-- r-1013: hour 13 → 5000
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1013)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1013, @i2847_4, 13, 5000, 'LOT-2403-053', 'PLT-00482', 'C-02-02', 'passed', @uNpatcharin, '2026-03-18T06:15:00');

-- r-2002: original 2000 @ hour 11 — will be MISCOUNT reversed by r-2003, corrected by r-2004
-- Net at hour 11 must respect ExpectedQty=5000 (RES-10K hour 11 e:5000). r-1011 doesn't touch this item;
-- the 200 correction takes RES-10K hour 11 to 200 (within 5000 cap).
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r2002)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r2002, @i2847_4, 11, 2000, 'LOT-2403-052', 'PLT-00483', 'C-02-02', 'passed', @uPsomchai, '2026-03-18T04:30:00');

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r2003)
BEGIN
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus,
                              Note, ReceivedBy, ReceivedAt, ReversesReceiptId, CancelReason)
    VALUES (@r2003, @i2847_4, 11, -2000, 'LOT-2403-052', 'PLT-00483', 'C-02-02', 'passed',
            N'Miscount — actual qty was 200 not 2000', @uPsomchai, '2026-03-18T04:45:00', @r2002, 'miscount');
    UPDATE dbo.Receipts SET ReversedById = @r2003 WHERE Id = @r2002;
END;

IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r2004)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, Note, ReceivedBy, ReceivedAt)
    VALUES (@r2004, @i2847_4, 11, 200, 'LOT-2403-052', 'PLT-00483', 'C-02-02', 'passed', N'Corrected count after miscount', @uPsomchai, '2026-03-18T04:50:00');

-- CONN-USB-C-16
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1012)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1012, @i2847_6, 7,  200, 'LOT-2402-101', 'PLT-00484', 'D-08-01', 'passed', @uSwattana, '2026-03-18T01:00:00');

-- LCD-3.5-IPS (new item)
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1014)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1014, @i2847_7, 7,  50, 'LOT-2404-001', 'PLT-00485', 'E-04-01', 'passed', @uSwattana, '2026-03-18T01:15:00');

-- SHIELD-RF-A1
IF NOT EXISTS (SELECT 1 FROM dbo.Receipts WHERE Id = @r1015)
    INSERT INTO dbo.Receipts (Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation, QcStatus, ReceivedBy, ReceivedAt)
    VALUES (@r1015, @i2847_8, 7,  300, 'LOT-2401-090', 'PLT-00486', 'F-03-01', 'passed', @uSwattana, '2026-03-18T01:30:00');

PRINT 'Receipts seeded for PL-2847 (incl. 2 reversal pairs).';
GO

------------------------------------------------------------------------------
-- 6. Recalculate PullItemWindows.ReceivedQty cache from receipts.
--    §7.11: vw_PullItemReceived is truth; the cache is a denormalized helper
--    that must agree with it. We do this in two passes so CK_PIW_Caps
--    (Received ≤ Expected) cannot trip during the update.
------------------------------------------------------------------------------
UPDATE w
SET    ReceivedQty = ISNULL(v.NetReceived, 0)
FROM   dbo.PullItemWindows w
LEFT JOIN dbo.vw_PullItemReceived v
       ON v.PullItemId = w.PullItemId AND v.HourOfDay = w.HourOfDay;

PRINT 'PullItemWindows.ReceivedQty cache recalculated from receipts.';
GO

PRINT '006_seed_pulls_and_items.sql complete.';
GO
