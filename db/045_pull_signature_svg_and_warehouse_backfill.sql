/* ============================================================================
   ReceivingOps — 045_pull_signature_svg_and_warehouse_backfill.sql
   ----------------------------------------------------------------------------
   Phase 8a — drawn signatures for all 3 parties.

   THREE changes, ONE transaction:

   (1) ADD dbo.PullSignatures.SignatureSvg NVARCHAR(MAX) NULL — the drawn
       signature (a PNG data URL, same shape as the close pad's
       Pulls.SignatureSvg). Nullable: name+date alone still authorizes a box.
       Customer/Production carry the signer's own drawing (Phase 8b/8c);
       Warehouse copies the close drawing (D1).

   (2) BACKFILL Warehouse signature rows for pulls closed BEFORE Phase 7b
       (Bug 1.1). 7b auto-creates the Warehouse row at close; pulls closed
       earlier have none, so their Warehouse box is blank. Insert one
       (PullId,'Warehouse') row per closed pull that lacks it, sourced from
       Pulls.ClosedBy (→ SignerUserId + Users.Name → SignerName), Pulls.ClosedAt
       (→ SignedAt), Pulls.WarehouseId, and Pulls.SignatureSvg (→ the drawing).
       NOT EXISTS guard skips pulls that already have a Warehouse row, so this
       is a no-op on a re-run and never touches post-7b rows.

   (3) COPY the close drawing into EXISTING Warehouse rows that predate this
       column (post-7b rows created before db/045). Only NULL → value, so it's
       idempotent and never overwrites a drawing.

   Steps (2) + (3) reference the column added in (1), so they run through
   sp_executesql — dynamic SQL defers name resolution to execution, inside this
   same transaction (the db/043 pattern).

   Idempotent (COL_LENGTH guard on the add; NOT EXISTS on the insert; NULL-only
   on the update). Transactional (XACT_ABORT + TRY/CATCH).
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

    /* ---- (1) ADD the SignatureSvg column ---------------------------- */
    IF COL_LENGTH('dbo.PullSignatures', 'SignatureSvg') IS NULL
    BEGIN
        PRINT 'Adding PullSignatures.SignatureSvg...';
        ALTER TABLE dbo.PullSignatures ADD SignatureSvg NVARCHAR(MAX) NULL;
    END
    ELSE
        PRINT 'PullSignatures.SignatureSvg already exists — skipping add.';

    /* ---- (2) Backfill Warehouse rows for pre-7b closed pulls --------- */
    DECLARE @inserted INT;
    EXEC sp_executesql N'
        INSERT INTO dbo.PullSignatures
            (PullId, Party, WarehouseId, SignerUserId, SignerName, SignedAt, SignatureSvg)
        SELECT p.Id, ''Warehouse'', p.WarehouseId, p.ClosedBy, u.Name, p.ClosedAt, p.SignatureSvg
        FROM   dbo.Pulls p
        INNER JOIN dbo.Users u ON u.Id = p.ClosedBy
        WHERE  p.Status = ''closed''
          AND  p.ClosedBy IS NOT NULL
          AND  p.ClosedAt IS NOT NULL
          AND  NOT EXISTS (
                   SELECT 1 FROM dbo.PullSignatures ps
                   WHERE ps.PullId = p.Id AND ps.Party = ''Warehouse'');
        SET @out = @@ROWCOUNT;',
        N'@out INT OUTPUT', @out = @inserted OUTPUT;
    PRINT CONCAT('Backfilled Warehouse rows for pre-7b closed pulls: ', @inserted);

    /* ---- (3) Copy close drawing into existing Warehouse rows --------- */
    DECLARE @updated INT;
    EXEC sp_executesql N'
        UPDATE ps
           SET ps.SignatureSvg = p.SignatureSvg
        FROM   dbo.PullSignatures ps
        INNER JOIN dbo.Pulls p ON p.Id = ps.PullId
        WHERE  ps.Party = ''Warehouse''
          AND  ps.SignatureSvg IS NULL
          AND  p.SignatureSvg IS NOT NULL;
        SET @out = @@ROWCOUNT;',
        N'@out INT OUTPUT', @out = @updated OUTPUT;
    PRINT CONCAT('Warehouse rows given the close drawing: ', @updated);

    COMMIT;
    PRINT 'db/045 committed OK.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    PRINT 'db/045 FAILED — rolled back.';
    THROW;
END CATCH;
GO
