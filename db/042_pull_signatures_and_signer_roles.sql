/* ============================================================================
   ReceivingOps — 042_pull_signatures_and_signer_roles.sql
   ----------------------------------------------------------------------------
   Digital signature feature (3-party, per-warehouse) — Phase 2 schema.

   TWO changes, ONE transaction:

   (1) NEW TABLE dbo.PullSignatures — one signature mark per (Pull x Party).
       Grain is PER-PULL (decided): a pull's 3 party signatures apply to every
       DO the pull spawns. UNIQUE (PullId, Party) enforces "one sign per party
       per pull". SignerName is DENORMALIZED (copied from Users.Name at sign
       time) so the printed/displayed signature survives a later user rename.
       Party is stored Title-case ('Customer','Warehouse','Production'); the
       per-warehouse whRole that AUTHORIZES a sign is the lowercase peer
       ('customer'/'warehouse'/'production') — the sign endpoint (Phase 3)
       maps whRole -> Party.

   (2) WIDEN CK_UWA_Role — Phase 1 (commit 29fe595) added customer/warehouse/
       production as valid assignment (whRole) values in code + Masters UI, but
       the DB CHECK still rejects them, so a signer assignment cannot persist
       yet. Drop + recreate the constraint with the 3 signer roles added.
       Existing rows (admin/supervisor/operator/viewer) all satisfy the widened
       set, so the re-add validates clean. CK_Users_Role is intentionally NOT
       touched — signers keep an operator/viewer GLOBAL role; "signer" is a
       per-warehouse role only.

   No index beyond UQ_PullSig_Party — its index on (PullId, Party) already
   covers the report read (fetch all signatures for a pull).

   FKs use NO ACTION (no ON DELETE): a pull / warehouse / user that owns
   signatures cannot be hard-deleted, preserving signature integrity. Users are
   deactivated (IsActive = 0), not deleted, in normal operation.

   Idempotent — safe to re-run (OBJECT_ID guard on the table; drop-if-exists
   then re-add on the constraint). Transactional (XACT_ABORT + TRY/CATCH).
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

    /* ---- (1) dbo.PullSignatures -------------------------------------- */
    IF OBJECT_ID(N'dbo.PullSignatures', N'U') IS NULL
    BEGIN
        PRINT 'Creating table dbo.PullSignatures...';
        CREATE TABLE dbo.PullSignatures (
            Id           UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID()
                           CONSTRAINT PK_PullSignatures PRIMARY KEY,
            PullId       UNIQUEIDENTIFIER NOT NULL,
            Party        NVARCHAR(20)     NOT NULL,
            WarehouseId  UNIQUEIDENTIFIER NOT NULL,
            SignerUserId UNIQUEIDENTIFIER NOT NULL,
            SignerName   NVARCHAR(120)    NOT NULL,
            SignedAt     DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
            CONSTRAINT FK_PullSig_Pull
                FOREIGN KEY (PullId)       REFERENCES dbo.Pulls(Id),
            CONSTRAINT FK_PullSig_Warehouse
                FOREIGN KEY (WarehouseId)  REFERENCES dbo.Warehouses(Id),
            CONSTRAINT FK_PullSig_User
                FOREIGN KEY (SignerUserId) REFERENCES dbo.Users(Id),
            CONSTRAINT CK_PullSig_Party
                CHECK (Party IN ('Customer','Warehouse','Production')),
            CONSTRAINT UQ_PullSig_Party UNIQUE (PullId, Party)
        );
    END
    ELSE
        PRINT 'dbo.PullSignatures already exists — skipping create.';

    /* ---- (2) Widen CK_UWA_Role (add the 3 signer whRoles) ------------ */
    IF EXISTS (
        SELECT 1 FROM sys.check_constraints
        WHERE name = N'CK_UWA_Role'
          AND parent_object_id = OBJECT_ID(N'dbo.UserWarehouseAssignments')
    )
    BEGIN
        PRINT 'Dropping existing CK_UWA_Role...';
        ALTER TABLE dbo.UserWarehouseAssignments DROP CONSTRAINT CK_UWA_Role;
    END

    PRINT 'Adding widened CK_UWA_Role (incl. customer/warehouse/production)...';
    ALTER TABLE dbo.UserWarehouseAssignments
        ADD CONSTRAINT CK_UWA_Role
        CHECK (Role IN ('admin','supervisor','operator','viewer',
                        'customer','warehouse','production'));

    COMMIT;
    PRINT 'db/042 committed OK.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    PRINT 'db/042 FAILED — rolled back.';
    THROW;
END CATCH;
GO
