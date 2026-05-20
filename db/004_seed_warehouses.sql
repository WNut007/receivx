/* ============================================================================
   ReceivingOps — 004_seed_warehouses.sql
   ----------------------------------------------------------------------------
   Four warehouses per §4.11 / masters.html seed:
     WH-01 Bangkok Main (active)
     WH-02 Chonburi     (active)
     WH-03 Rayong       (active)
     WH-04 Hanoi DC     (inactive)

   Idempotent: keyed by Code (UNIQUE).
   ============================================================================ */

USE [ReceivingOps];
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

DECLARE @wBkk     UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000001';
DECLARE @wChonburi UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000002';
DECLARE @wRayong  UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000003';
DECLARE @wHanoi   UNIQUEIDENTIFIER = '22222222-2222-2222-2222-000000000004';

IF NOT EXISTS (SELECT 1 FROM dbo.Warehouses WHERE Code = 'WH-01')
    INSERT INTO dbo.Warehouses (Id, Code, Name, City, Country, Address, Capacity, Timezone, Phone, IsActive)
    VALUES (@wBkk, 'WH-01', 'Bangkok Main', 'Bangkok', 'TH', '101 Lat Krabang Industrial Estate', 12000, 'Asia/Bangkok', '+66 2 555 0101', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Warehouses WHERE Code = 'WH-02')
    INSERT INTO dbo.Warehouses (Id, Code, Name, City, Country, Address, Capacity, Timezone, Phone, IsActive)
    VALUES (@wChonburi, 'WH-02', 'Chonburi', 'Chonburi', 'TH', '88 Amata City Industrial Park', 9000, 'Asia/Bangkok', '+66 38 555 0202', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Warehouses WHERE Code = 'WH-03')
    INSERT INTO dbo.Warehouses (Id, Code, Name, City, Country, Address, Capacity, Timezone, Phone, IsActive)
    VALUES (@wRayong, 'WH-03', 'Rayong', 'Rayong', 'TH', '42 Map Ta Phut Industrial Estate', 6500, 'Asia/Bangkok', '+66 38 555 0303', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Warehouses WHERE Code = 'WH-04')
    INSERT INTO dbo.Warehouses (Id, Code, Name, City, Country, Address, Capacity, Timezone, Phone, IsActive)
    VALUES (@wHanoi, 'WH-04', 'Hanoi DC', 'Hanoi', 'VN', 'Bac Ninh Industrial Zone', 4500, 'Asia/Ho_Chi_Minh', '+84 24 555 0404', 0);

PRINT '004_seed_warehouses.sql complete — 4 warehouses.';
GO
