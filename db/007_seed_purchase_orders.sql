/* ============================================================================
   ReceivingOps — 007_seed_purchase_orders.sql  (Phase 2 of v2 migration)
   ----------------------------------------------------------------------------
   Seed PurchaseOrders + PurchaseOrderLines that the existing 18 planned PL-2847
   receipts will backfill into.

   Catalog (no SUMMARY — that item is a smoke-residue artifact; 012 wipes it):
     WH-01: PO-2312-091 (historical closed, demo) + PO-2401-018 (primary
            backfill target — every PL-2847 positive lands here) +
            PO-2401-019, PO-2403-044 (extra capacity for future FIFO-split demo)
     WH-02: PO-2402-022, PO-2402-023, PO-2403-051 (future demos, no backfill)
     WH-03: PO-2402-031, PO-2402-032, PO-2403-061 (future demos)
     WH-04: PO-2401-010 (inactive warehouse — coverage only)

   IDs use deterministic series:
     PurchaseOrders        → 66666666-6666-6666-6666-<seq>
     PurchaseOrderLines    → 77777777-7777-7777-7777-<po-seq><line-seq>
   Smoke tests reference PoNumber (business key), not these GUIDs.

   Idempotent: every INSERT is guarded by a NOT EXISTS check.

   Note (v2 §4.5a behavior): after backfill, every historical receipt sits on
   the *oldest* open PO line for its item. Multi-PO FIFO splitting is visible
   only on receives placed AFTER the v2 cutover — that's natural behavior, not
   a data bug. The 3-PO RES-10K-1% chain on WH-01 demonstrates the split path
   the moment any new receive consumes the rest of PO-2401-018 L4.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- Warehouse IDs (must match db/004_seed_warehouses.sql)
--   WH-01 22222222-2222-2222-2222-000000000001
--   WH-02 22222222-2222-2222-2222-000000000002
--   WH-03 22222222-2222-2222-2222-000000000003
--   WH-04 22222222-2222-2222-2222-000000000004
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- WH-01 POs
------------------------------------------------------------------------------

-- PO-2312-091 — historical closed (demo of closed-PO appearance)
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2312-091')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000001', 'PO-2312-091',
            '22222222-2222-2222-2222-000000000001',
            'V-ACME', N'Acme Components Ltd',
            '2023-12-01', '2024-01-05', 'closed',
            N'Historical PO — fully received in 2023', NULL,
            '2023-12-01T00:00:00', '2024-01-05T00:00:00');
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-010100000001')
BEGIN
    -- L1: pre-received in full (1000/1000) to demonstrate closed-PO state
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-010100000001',
            '66666666-6666-6666-6666-000000000001',
            1, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2 - 1.5GHz', 1000, 1000);
END
GO

-- PO-2401-018 — primary backfill target. Every PL-2847 positive lands on these lines.
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2401-018')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000002', 'PO-2401-018',
            '22222222-2222-2222-2222-000000000001',
            'V-ACME', N'Acme Components Ltd',
            '2026-01-15', '2026-03-15', 'open',
            N'Primary WH-01 PO — covers PL-2847 plan', NULL,
            '2026-01-15T00:00:00', NULL);
END
GO

-- PO-2401-018 lines (ReceivedQty = 0 here; backfill populates after delete-smoke step)
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-020100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-020100000001', '66666666-6666-6666-6666-000000000002', 1, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2 - 1.5GHz',          5500, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-020100000002')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-020100000002', '66666666-6666-6666-6666-000000000002', 2, 'PCBA-AX451-R2', N'PCBA AX451 Rev 2 - 1.8GHz',          2000, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-020100000003')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-020100000003', '66666666-6666-6666-6666-000000000002', 3, 'CAP-470UF-25V', N'Capacitor 470µF 25V',                7000, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-020100000004')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-020100000004', '66666666-6666-6666-6666-000000000002', 4, 'RES-10K-1%',    N'Resistor 10kΩ 1% 0805',            20000, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-020100000005')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-020100000005', '66666666-6666-6666-6666-000000000002', 5, 'CONN-USB-C-16', N'USB-C 16-pin connector',              500, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-020100000006')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-020100000006', '66666666-6666-6666-6666-000000000002', 6, 'LCD-3.5-IPS',   N'LCD 3.5" IPS',                         100, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-020100000007')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-020100000007', '66666666-6666-6666-6666-000000000002', 7, 'SHIELD-RF-A1',  N'RF shield A1',                         500, 0);
END
GO

-- PO-2401-019 — second-oldest WH-01 PO; future FIFO split target for RES-10K-1% + extra PCBA capacity
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2401-019')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000003', 'PO-2401-019',
            '22222222-2222-2222-2222-000000000001',
            'V-NEXTRON', N'Nextron Electronics',
            '2026-01-22', '2026-03-22', 'open',
            N'Extra WH-01 capacity — FIFO split demo source', NULL,
            '2026-01-22T00:00:00', NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-030100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-030100000001', '66666666-6666-6666-6666-000000000003', 1, 'RES-10K-1%',    N'Resistor 10kΩ 1% 0805', 5000, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-030100000002')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-030100000002', '66666666-6666-6666-6666-000000000003', 2, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2',     2000, 0);
END
GO

-- PO-2403-044 — newest WH-01 PO; third FIFO target for RES-10K-1%
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2403-044')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000004', 'PO-2403-044',
            '22222222-2222-2222-2222-000000000001',
            'V-FORTIS', N'Fortis Microparts',
            '2026-03-08', '2026-04-15', 'open',
            N'Newest WH-01 PO — third FIFO target', NULL,
            '2026-03-08T00:00:00', NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-040100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-040100000001', '66666666-6666-6666-6666-000000000004', 1, 'RES-10K-1%',    N'Resistor 10kΩ 1% 0805', 3000, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-040100000002')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-040100000002', '66666666-6666-6666-6666-000000000004', 2, 'CAP-470UF-25V', N'Capacitor 470µF 25V',   2000, 0);
END
GO

------------------------------------------------------------------------------
-- WH-02 POs (no historical receipts — future demos only)
------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2402-022')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000005', 'PO-2402-022',
            '22222222-2222-2222-2222-000000000002',
            'V-ACME', N'Acme Components Ltd',
            '2026-02-01', '2026-04-01', 'open',
            N'WH-02 baseline PO', NULL,
            '2026-02-01T00:00:00', NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-050100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-050100000001', '66666666-6666-6666-6666-000000000005', 1, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2', 1000, 0);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2402-023')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000006', 'PO-2402-023',
            '22222222-2222-2222-2222-000000000002',
            'V-NEXTRON', N'Nextron Electronics',
            '2026-02-10', '2026-04-10', 'open',
            N'WH-02 mid-tier PO', NULL,
            '2026-02-10T00:00:00', NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-060100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-060100000001', '66666666-6666-6666-6666-000000000006', 1, 'CAP-470UF-25V', N'Capacitor 470µF 25V', 2000, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-060100000002')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-060100000002', '66666666-6666-6666-6666-000000000006', 2, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2',    1000, 0);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2403-051')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000007', 'PO-2403-051',
            '22222222-2222-2222-2222-000000000002',
            'V-FORTIS', N'Fortis Microparts',
            '2026-03-05', '2026-04-20', 'open',
            N'WH-02 newest PO', NULL,
            '2026-03-05T00:00:00', NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-070100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-070100000001', '66666666-6666-6666-6666-000000000007', 1, 'RES-10K-1%', N'Resistor 10kΩ 1% 0805', 3000, 0);
END
GO

------------------------------------------------------------------------------
-- WH-03 POs
------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2402-031')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000008', 'PO-2402-031',
            '22222222-2222-2222-2222-000000000003',
            'V-ACME', N'Acme Components Ltd',
            '2026-02-15', '2026-04-15', 'open',
            N'WH-03 baseline PO', NULL,
            '2026-02-15T00:00:00', NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-080100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-080100000001', '66666666-6666-6666-6666-000000000008', 1, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2', 2000, 0);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2402-032')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000009', 'PO-2402-032',
            '22222222-2222-2222-2222-000000000003',
            'V-NEXTRON', N'Nextron Electronics',
            '2026-02-20', '2026-04-20', 'open',
            N'WH-03 mid-tier PO', NULL,
            '2026-02-20T00:00:00', NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-090100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-090100000001', '66666666-6666-6666-6666-000000000009', 1, 'RES-10K-1%',    N'Resistor 10kΩ 1% 0805', 5000, 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-090100000002')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-090100000002', '66666666-6666-6666-6666-000000000009', 2, 'CAP-470UF-25V', N'Capacitor 470µF 25V',   1500, 0);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2403-061')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000010', 'PO-2403-061',
            '22222222-2222-2222-2222-000000000003',
            'V-FORTIS', N'Fortis Microparts',
            '2026-03-12', '2026-04-30', 'open',
            N'WH-03 newest PO', NULL,
            '2026-03-12T00:00:00', NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-100100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-100100000001', '66666666-6666-6666-6666-000000000010', 1, 'PCBA-AX451-R2', N'PCBA AX451 Rev 2', 1500, 0);
END
GO

------------------------------------------------------------------------------
-- WH-04 PO (inactive warehouse — schema coverage only, never receives)
------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrders WHERE PoNumber = 'PO-2401-010')
BEGIN
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, VendorCode, VendorName, OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, ClosedAt)
    VALUES ('66666666-6666-6666-6666-000000000011', 'PO-2401-010',
            '22222222-2222-2222-2222-000000000004',
            'V-ACME', N'Acme Components Ltd',
            '2026-01-10', '2026-03-10', 'open',
            N'WH-04 PO (warehouse inactive)', NULL,
            '2026-01-10T00:00:00', NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines WHERE Id = '77777777-7777-7777-7777-110100000001')
BEGIN
    INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
    VALUES ('77777777-7777-7777-7777-110100000001', '66666666-6666-6666-6666-000000000011', 1, 'PCBA-AX450-R2', N'PCBA AX450 Rev 2', 1000, 0);
END
GO

PRINT '007_seed_purchase_orders.sql complete — 11 POs, 22 PO lines.';
GO
