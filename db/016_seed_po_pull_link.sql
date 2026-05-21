/* ============================================================================
   ReceivingOps — 016_seed_po_pull_link.sql  (Phase 3.5 seed)
   ----------------------------------------------------------------------------
   Demo data for the configurable PO-pull lock added in 015:

     A. Link PO-2401-018 → PL-2847 (LockPoByPull = 0, default).
        Demonstrates the "linked but unlocked" case — PullId carries metadata
        for reporting/UI, FIFO scope stays warehouse-wide.

     B. PO-2401-019, PO-2403-044 stay PullId = NULL (cross-pull pool — the
        common case; nothing to do).

     C. Create PL-2900 with LockPoByPull = 1 (strict mode) + dedicated
        PO-2405-001 linked to it. Demonstrates the "linked + locked" case
        where FIFO is restricted to the pull's own POs.

   Idempotent — every write is guarded.

   GUID conventions (re-used from earlier seed files):
     Pulls               → 33333333-3333-3333-3333-<pull-number>
     PullItems           → 44444444-4444-4444-<pullnum>-<item-seq>
     Receipts            → 55555555-5555-5555-5555-<receipt-seq>
     PurchaseOrders      → 66666666-6666-6666-6666-<seq>
     PurchaseOrderLines  → 77777777-7777-7777-7777-<po-seq><line-seq>
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- Stable IDs
------------------------------------------------------------------------------
DECLARE @wBkk     UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000001';
DECLARE @uSwattana UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000002';

DECLARE @p2847    UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002847';
DECLARE @po018Id  UNIQUEIDENTIFIER = '66666666-6666-6666-6666-000000000002'; -- PO-2401-018

DECLARE @p2900    UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002900';
DECLARE @po501Id  UNIQUEIDENTIFIER = '66666666-6666-6666-6666-000000000012'; -- PO-2405-001
DECLARE @po501L1  UNIQUEIDENTIFIER = '77777777-7777-7777-7777-120100000001';
DECLARE @i2900_1  UNIQUEIDENTIFIER = '44444444-4444-4444-2900-000000000001';

------------------------------------------------------------------------------
-- A. Link PO-2401-018 → PL-2847 (only if currently NULL — idempotent)
------------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM dbo.PurchaseOrders
    WHERE Id = @po018Id AND PullId IS NULL
)
BEGIN
    PRINT 'Linking PO-2401-018 to PL-2847 (linked, unlocked demo)...';
    UPDATE dbo.PurchaseOrders SET PullId = @p2847 WHERE Id = @po018Id;
END
GO

------------------------------------------------------------------------------
-- C. PL-2900 — strict-mode pull (LockPoByPull = 1)
------------------------------------------------------------------------------
DECLARE @wBkk     UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000001';
DECLARE @uSwattana UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000002';
DECLARE @p2900    UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002900';

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2900')
BEGIN
    PRINT 'Creating PL-2900 (LockPoByPull=1, strict-mode demo)...';
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy, LockPoByPull)
    VALUES (@p2900, 'PL-2900', @wBkk, '2026-05-22', 'pending', '14:00',
            N'Strict-mode demo: PO-linked FIFO', @uSwattana, 1);
END
GO

------------------------------------------------------------------------------
-- PL-2900 PullItem + window (single PCBA-AX450-R2 item, 500 pcs at hour 12)
------------------------------------------------------------------------------
DECLARE @p2900    UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002900';
DECLARE @i2900_1  UNIQUEIDENTIFIER = '44444444-4444-4444-2900-000000000001';

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2900_1)
BEGIN
    PRINT 'Creating PL-2900 PullItem (PCBA-AX450-R2)...';
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Status, SortOrder)
    VALUES (@i2900_1, @p2900, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2 - 1.5GHz',
            'V-FORTIS', N'Fortis Microparts', 'normal', 1);
END
GO

DECLARE @i2900_1  UNIQUEIDENTIFIER = '44444444-4444-4444-2900-000000000001';

IF NOT EXISTS (
    SELECT 1 FROM dbo.PullItemWindows
    WHERE PullItemId = @i2900_1 AND HourOfDay = 12
)
BEGIN
    PRINT 'Creating PL-2900 PullItemWindow (hour 12 / 500 pcs)...';
    INSERT INTO dbo.PullItemWindows (PullItemId, HourOfDay, ExpectedQty)
    VALUES (@i2900_1, 12, 500);
END
GO

------------------------------------------------------------------------------
-- PO-2405-001 — dedicated PO for PL-2900 (PullId set at create-time)
------------------------------------------------------------------------------
DECLARE @wBkk     UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000001';
DECLARE @p2900    UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002900';
DECLARE @po501Id  UNIQUEIDENTIFIER = '66666666-6666-6666-6666-000000000012';

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2405-001')
BEGIN
    PRINT 'Creating PO-2405-001 (dedicated to PL-2900)...';
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, PullId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt)
    VALUES (@po501Id, 'PO-2405-001', @wBkk, @p2900,
            'V-FORTIS', N'Fortis Microparts',
            '2026-05-10', '2026-05-22', 'open',
            N'Dedicated PO for PL-2900 strict-mode demo', NULL,
            '2026-05-10T00:00:00');
END
GO

DECLARE @po501Id  UNIQUEIDENTIFIER = '66666666-6666-6666-6666-000000000012';
DECLARE @po501L1  UNIQUEIDENTIFIER = '77777777-7777-7777-7777-120100000001';

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = @po501L1)
BEGIN
    PRINT 'Creating PO-2405-001 line 1 (PCBA-AX450-R2 / 500 pcs)...';
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES (@po501L1, @po501Id, 1, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2 - 1.5GHz', 500, 0);
END
GO

------------------------------------------------------------------------------
-- D. PL-2901 — strict-mode pull with NO linked PO (test fixture for
--    "No PO linked to this pull" 409 path in Preview/Receive)
------------------------------------------------------------------------------
DECLARE @wBkk     UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000001';
DECLARE @uSwattana UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000002';
DECLARE @p2901    UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002901';
DECLARE @i2901_1  UNIQUEIDENTIFIER = '44444444-4444-4444-2901-000000000001';

IF NOT EXISTS (SELECT 1 FROM dbo.Pulls WHERE PullNumber = 'PL-2901')
BEGIN
    PRINT 'Creating PL-2901 (lock=1, NO linked PO — empty-lines test fixture)...';
    INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, Eta, Notes, CreatedBy, LockPoByPull)
    VALUES (@p2901, 'PL-2901', @wBkk, '2026-05-22', 'pending', '15:00',
            N'Strict-mode + unlinked: tests "No PO linked" 409', @uSwattana, 1);
END
GO

DECLARE @p2901    UNIQUEIDENTIFIER = '33333333-3333-3333-3333-000000002901';
DECLARE @i2901_1  UNIQUEIDENTIFIER = '44444444-4444-4444-2901-000000000001';

IF NOT EXISTS (SELECT 1 FROM dbo.PullItems WHERE Id = @i2901_1)
BEGIN
    PRINT 'Creating PL-2901 PullItem (PCBA-AX450-R2, no PO will be linked)...';
    INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Status, SortOrder)
    VALUES (@i2901_1, @p2901, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2 - 1.5GHz',
            'V-FORTIS', N'Fortis Microparts', 'normal', 1);
END
GO

DECLARE @i2901_1  UNIQUEIDENTIFIER = '44444444-4444-4444-2901-000000000001';

IF NOT EXISTS (
    SELECT 1 FROM dbo.PullItemWindows
    WHERE PullItemId = @i2901_1 AND HourOfDay = 12
)
BEGIN
    PRINT 'Creating PL-2901 PullItemWindow (hour 12 / 100 pcs)...';
    INSERT INTO dbo.PullItemWindows (PullItemId, HourOfDay, ExpectedQty)
    VALUES (@i2901_1, 12, 100);
END
GO

PRINT '016_seed_po_pull_link.sql complete — PL-2847/2900/2901 seed in place.';
GO
