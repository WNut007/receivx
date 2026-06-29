/* ============================================================================
   ReceivingOps — 044_backfill_supervisor_can_sign_warehouse.sql
   ----------------------------------------------------------------------------
   Phase 7a — backfill the Warehouse signing capability for existing closers.

   WHY: Phase 7a tightens the pull-close gate from CanManagePulls to
   "CanManagePulls AND (admin OR canSign=warehouse)" — the closer is now also
   the Warehouse-box signer (Phase 7b auto-signs the Warehouse party from the
   close). Every user who can close today is a per-warehouse supervisor
   (whRole='supervisor') or a global admin. Admins bypass the bit (decision
   D1a), but supervisors need CanSignWarehouse=1 or they would lose the
   ability to close once the gate tightens.

   FIX: set CanSignWarehouse=1 on every assignment whose operational Role is
   'supervisor' and that doesn't already have it. At authoring time this is
   kanucha (WH-03), npatcharin (WH-02), psomchai (WH-01); swattana (WH-BPI)
   already carries it from earlier manual correction.

   Operators/viewers/admins are NOT touched — operators can't close, viewers
   can't close, admins bypass the bit. Customer/Production capabilities are
   left exactly as-is.

   Idempotent (only flips 0 -> 1; a re-run updates 0 rows). Transactional
   (XACT_ABORT + TRY/CATCH). COL_LENGTH guard ensures db/043 ran first.
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

    /* Prerequisite: db/043 added the CanSignWarehouse column. */
    IF COL_LENGTH('dbo.UserWarehouseAssignments', 'CanSignWarehouse') IS NULL
        THROW 50044, 'db/043 must run before db/044 (CanSignWarehouse column missing).', 1;

    DECLARE @flipped INT;

    UPDATE dbo.UserWarehouseAssignments
       SET CanSignWarehouse = 1
     WHERE Role = 'supervisor'
       AND CanSignWarehouse = 0;

    SET @flipped = @@ROWCOUNT;
    PRINT CONCAT('Supervisor assignments granted CanSignWarehouse: ', @flipped);

    /* Invariant: after this migration no supervisor assignment lacks the bit. */
    IF EXISTS (
        SELECT 1 FROM dbo.UserWarehouseAssignments
        WHERE Role = 'supervisor' AND CanSignWarehouse = 0
    )
        THROW 50044, 'Post-check failed: a supervisor assignment still lacks CanSignWarehouse.', 1;

    COMMIT;
    PRINT 'db/044 committed OK.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    PRINT 'db/044 FAILED — rolled back.';
    THROW;
END CATCH;
GO
