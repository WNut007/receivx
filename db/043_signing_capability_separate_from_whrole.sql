/* ============================================================================
   ReceivingOps — 043_signing_capability_separate_from_whrole.sql
   ----------------------------------------------------------------------------
   Phase 6 — separate the digital-signature capability from the operational
   per-warehouse role (whRole). REWORK of db/042's approach.

   WHY: db/042 made customer/warehouse/production VALID whRole *values*. But
   dbo.UserWarehouseAssignments PK is (UserId, WarehouseId) — exactly ONE role
   per user per warehouse — so making someone a signer REPLACED their
   operational role and broke receiving. A user must be able to BOTH receive
   (operator/supervisor) AND sign (customer/warehouse/production) at the same
   warehouse.

   FIX (Option A2): signing is an ADDITIVE per-warehouse capability carried by
   three independent BIT flags on the assignment row, leaving Role purely
   operational again.

   THREE changes, ONE transaction:

   (1) ADD CanSignCustomer / CanSignWarehouse / CanSignProduction BIT NOT NULL
       DEFAULT 0 on dbo.UserWarehouseAssignments. Existing operational rows get
       0 (cannot sign) — correct.

   (2) MIGRATE existing signer rows. Any assignment whose Role is one of the 3
       signer values (created under db/042) is converted in place: set the
       matching CanSign* bit = 1 and set Role to 'operator' (the target use
       case — a signer who also receives; an admin can adjust to
       supervisor/viewer via the Masters UI afterwards). Runs through EXEC
       because the new columns don't exist at batch-compile time. Idempotent:
       after the first run no row carries a signer Role, so a re-run updates
       0 rows.

   (3) RE-TIGHTEN CK_UWA_Role back to operational-only
       ('admin','supervisor','operator','viewer'). Validates clean because step
       (2) already moved every signer row off the signer values. Reverses the
       db/042 widen.

   NOT TOUCHED: dbo.PullSignatures (correct as-is — per-pull x Party, Party
   stored Title-case). CK_Users_Role (global role) — never involved.

   Idempotent (COL_LENGTH guard on the adds; drop-if-exists + re-add on the
   constraint; the row migration self-empties). Transactional
   (XACT_ABORT + TRY/CATCH).
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE [ReceivingOps];
GO

BEGIN TRY
    BEGIN TRANSACTION;

    /* ---- (1) ADD the 3 signing-capability bit columns --------------- */
    IF COL_LENGTH('dbo.UserWarehouseAssignments', 'CanSignCustomer') IS NULL
    BEGIN
        PRINT 'Adding UserWarehouseAssignments.CanSignCustomer...';
        ALTER TABLE dbo.UserWarehouseAssignments
            ADD CanSignCustomer BIT NOT NULL CONSTRAINT DF_UWA_CanSignCustomer DEFAULT 0;
    END

    IF COL_LENGTH('dbo.UserWarehouseAssignments', 'CanSignWarehouse') IS NULL
    BEGIN
        PRINT 'Adding UserWarehouseAssignments.CanSignWarehouse...';
        ALTER TABLE dbo.UserWarehouseAssignments
            ADD CanSignWarehouse BIT NOT NULL CONSTRAINT DF_UWA_CanSignWarehouse DEFAULT 0;
    END

    IF COL_LENGTH('dbo.UserWarehouseAssignments', 'CanSignProduction') IS NULL
    BEGIN
        PRINT 'Adding UserWarehouseAssignments.CanSignProduction...';
        ALTER TABLE dbo.UserWarehouseAssignments
            ADD CanSignProduction BIT NOT NULL CONSTRAINT DF_UWA_CanSignProduction DEFAULT 0;
    END

    /* ---- (2) Migrate existing db/042 signer rows -------------------- */
    /* EXEC: the columns added above don't exist at batch-compile time, so a
       direct UPDATE referencing them would fail to parse. Dynamic SQL defers
       name resolution to execution, inside this same transaction. */
    DECLARE @migrated INT;

    EXEC sp_executesql N'
        UPDATE dbo.UserWarehouseAssignments
           SET CanSignCustomer   = 1, Role = ''operator''
         WHERE Role = ''customer'';
        SET @out = @@ROWCOUNT;',
        N'@out INT OUTPUT', @out = @migrated OUTPUT;
    PRINT CONCAT('Migrated customer-signer rows: ', @migrated);

    EXEC sp_executesql N'
        UPDATE dbo.UserWarehouseAssignments
           SET CanSignWarehouse  = 1, Role = ''operator''
         WHERE Role = ''warehouse'';
        SET @out = @@ROWCOUNT;',
        N'@out INT OUTPUT', @out = @migrated OUTPUT;
    PRINT CONCAT('Migrated warehouse-signer rows: ', @migrated);

    EXEC sp_executesql N'
        UPDATE dbo.UserWarehouseAssignments
           SET CanSignProduction = 1, Role = ''operator''
         WHERE Role = ''production'';
        SET @out = @@ROWCOUNT;',
        N'@out INT OUTPUT', @out = @migrated OUTPUT;
    PRINT CONCAT('Migrated production-signer rows: ', @migrated);

    /* ---- (3) Re-tighten CK_UWA_Role to operational-only ------------- */
    IF EXISTS (
        SELECT 1 FROM sys.check_constraints
        WHERE name = N'CK_UWA_Role'
          AND parent_object_id = OBJECT_ID(N'dbo.UserWarehouseAssignments')
    )
    BEGIN
        PRINT 'Dropping widened CK_UWA_Role...';
        ALTER TABLE dbo.UserWarehouseAssignments DROP CONSTRAINT CK_UWA_Role;
    END

    PRINT 'Re-adding operational-only CK_UWA_Role...';
    ALTER TABLE dbo.UserWarehouseAssignments
        ADD CONSTRAINT CK_UWA_Role
        CHECK (Role IN ('admin','supervisor','operator','viewer'));

    COMMIT;
    PRINT 'db/043 committed OK.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    PRINT 'db/043 FAILED — rolled back.';
    THROW;
END CATCH;
GO
