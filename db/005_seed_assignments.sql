/* ============================================================================
   ReceivingOps — 005_seed_assignments.sql
   ----------------------------------------------------------------------------
   11 user-warehouse assignments per §4.11:
     sadmin     → WH-01, WH-02, WH-03, WH-04 (admin each)              [4 rows]
     swattana   → WH-01 supervisor, WH-02 operator                     [2 rows]
     psomchai   → WH-01 supervisor                                     [1 row]
     npatcharin → WH-02 supervisor, WH-03 operator                     [2 rows]
     kanucha    → WH-03 supervisor                                     [1 row]
     tviewer    → WH-01 viewer                                         [1 row]
                                                                       ---------
                                                                       11 total

   §12 acceptance check #2: typing "swattana" populates dropdown with WH-01 and
   WH-02 (not WH-03; WH-04 excluded as inactive).
   ============================================================================ */

USE [ReceivingOps];
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

-- Reuse the stable GUIDs from 003/004.
DECLARE @uSadmin     UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000001';
DECLARE @uSwattana   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000002';
DECLARE @uPsomchai   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000003';
DECLARE @uNpatcharin UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000004';
DECLARE @uKanucha    UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000005';
DECLARE @uTviewer    UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000006';

DECLARE @wBkk       UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000001';
DECLARE @wChonburi  UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000002';
DECLARE @wRayong    UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000003';
DECLARE @wHanoi     UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000004';

-- sadmin (all 4)
IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uSadmin AND WarehouseId = @wBkk)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uSadmin, @wBkk, 'admin');

IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uSadmin AND WarehouseId = @wChonburi)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uSadmin, @wChonburi, 'admin');

IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uSadmin AND WarehouseId = @wRayong)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uSadmin, @wRayong, 'admin');

IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uSadmin AND WarehouseId = @wHanoi)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uSadmin, @wHanoi, 'admin');

-- swattana
IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uSwattana AND WarehouseId = @wBkk)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uSwattana, @wBkk, 'supervisor');

IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uSwattana AND WarehouseId = @wChonburi)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uSwattana, @wChonburi, 'operator');

-- psomchai
IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uPsomchai AND WarehouseId = @wBkk)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uPsomchai, @wBkk, 'supervisor');

-- npatcharin
IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uNpatcharin AND WarehouseId = @wChonburi)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uNpatcharin, @wChonburi, 'supervisor');

IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uNpatcharin AND WarehouseId = @wRayong)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uNpatcharin, @wRayong, 'operator');

-- kanucha
IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uKanucha AND WarehouseId = @wRayong)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uKanucha, @wRayong, 'supervisor');

-- tviewer
IF NOT EXISTS (SELECT 1 FROM dbo.UserWarehouseAssignments WHERE UserId = @uTviewer AND WarehouseId = @wBkk)
    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role) VALUES (@uTviewer, @wBkk, 'viewer');

PRINT '005_seed_assignments.sql complete — 11 assignments.';
GO
