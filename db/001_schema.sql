/* ============================================================================
   ReceivingOps — 001_schema.sql
   ----------------------------------------------------------------------------
   Idempotent migration script. Safe to re-run; each object is guarded by
   an existence check so partial runs and re-applications don't fail.

   Run order:
     1. Connect to [master] (or any DB) — script creates [ReceivingOps] if
        missing, then USEs it.
     2. Tables in dependency order (parents before children).
     3. Foreign keys that close the cycle (Warehouses.ManagerId → Users).
     4. Secondary indexes.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

------------------------------------------------------------------------------
-- 0. Database
------------------------------------------------------------------------------
IF DB_ID(N'ReceivingOps') IS NULL
BEGIN
    PRINT 'Creating database [ReceivingOps]...';
    CREATE DATABASE [ReceivingOps];
END
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- §4.1 Warehouses
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.Warehouses', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.Warehouses...';
    CREATE TABLE dbo.Warehouses (
        Id          UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
        Code        VARCHAR(16)      NOT NULL UNIQUE,
        Name        NVARCHAR(120)    NOT NULL,
        City        NVARCHAR(80)     NULL,
        Country     CHAR(2)          NULL,
        Address     NVARCHAR(255)    NULL,
        Capacity    INT              NOT NULL DEFAULT 0,
        Timezone    VARCHAR(64)      NOT NULL DEFAULT 'Asia/Bangkok',
        ManagerId   UNIQUEIDENTIFIER NULL,
        Phone       VARCHAR(32)      NULL,
        IsActive    BIT              NOT NULL DEFAULT 1,
        CreatedAt   DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
        UpdatedAt   DATETIME2(0)     NULL
    );
END
GO

------------------------------------------------------------------------------
-- §4.2 Users
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.Users', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.Users...';
    CREATE TABLE dbo.Users (
        Id            UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
        Username      VARCHAR(64)      NOT NULL UNIQUE,
        Name          NVARCHAR(120)    NOT NULL,
        Email         NVARCHAR(160)    NULL,
        Phone         VARCHAR(32)      NULL,
        Role          VARCHAR(20)      NOT NULL
                       CONSTRAINT CK_Users_Role
                       CHECK (Role IN ('admin','supervisor','operator','viewer')),
        PasswordHash  NVARCHAR(512)    NOT NULL,
        IsActive      BIT              NOT NULL DEFAULT 1,
        LastSignInAt  DATETIME2(0)     NULL,
        CreatedAt     DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
        UpdatedAt     DATETIME2(0)     NULL
    );
END
GO

-- Close the cycle: Warehouses.ManagerId → Users.Id (added after Users exists)
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = N'FK_Warehouses_Manager'
      AND parent_object_id = OBJECT_ID(N'dbo.Warehouses')
)
BEGIN
    PRINT 'Adding FK_Warehouses_Manager...';
    ALTER TABLE dbo.Warehouses
      ADD CONSTRAINT FK_Warehouses_Manager
      FOREIGN KEY (ManagerId) REFERENCES dbo.Users(Id) ON DELETE SET NULL;
END
GO

------------------------------------------------------------------------------
-- §4.3 UserWarehouseAssignments (N:M with role per assignment)
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.UserWarehouseAssignments', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.UserWarehouseAssignments...';
    CREATE TABLE dbo.UserWarehouseAssignments (
        UserId      UNIQUEIDENTIFIER NOT NULL,
        WarehouseId UNIQUEIDENTIFIER NOT NULL,
        Role        VARCHAR(20)      NOT NULL
                     CONSTRAINT CK_UWA_Role
                     CHECK (Role IN ('admin','supervisor','operator','viewer')),
        AssignedAt  DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_UserWarehouse PRIMARY KEY (UserId, WarehouseId),
        CONSTRAINT FK_UWA_User      FOREIGN KEY (UserId)      REFERENCES dbo.Users(Id)      ON DELETE CASCADE,
        CONSTRAINT FK_UWA_Warehouse FOREIGN KEY (WarehouseId) REFERENCES dbo.Warehouses(Id) ON DELETE CASCADE
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_UWA_Warehouse'
      AND object_id = OBJECT_ID(N'dbo.UserWarehouseAssignments')
)
BEGIN
    PRINT 'Creating index IX_UWA_Warehouse...';
    CREATE INDEX IX_UWA_Warehouse ON dbo.UserWarehouseAssignments(WarehouseId);
END
GO

------------------------------------------------------------------------------
-- §4.4 Pulls (with close + reopen history fields)
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.Pulls', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.Pulls...';
    CREATE TABLE dbo.Pulls (
        Id             UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
        PullNumber     VARCHAR(32)      NOT NULL UNIQUE,
        WarehouseId    UNIQUEIDENTIFIER NOT NULL,
        PullDate       DATE             NOT NULL,
        Status         VARCHAR(20)      NOT NULL
                        CONSTRAINT CK_Pulls_Status
                        CHECK (Status IN ('pending','in_progress','fully_received','closed')),
        Eta            VARCHAR(64)      NULL,
        Notes          NVARCHAR(500)    NULL,
        CreatedBy      UNIQUEIDENTIFIER NULL,
        CreatedAt      DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
        FirstReceiptAt DATETIME2(0)     NULL,
        LastActivityAt DATETIME2(0)     NULL,
        -- Close fields (set on close; PRESERVED across reopen so the history isn't lost)
        ClosedAt       DATETIME2(0)     NULL,
        ClosedBy       UNIQUEIDENTIFIER NULL,
        SignatureSvg   NVARCHAR(MAX)    NULL,
        -- Reopen fields (set when supervisor unlocks a closed pull)
        ReopenedAt     DATETIME2(0)     NULL,
        ReopenedBy     UNIQUEIDENTIFIER NULL,
        ReopenReason   NVARCHAR(500)    NULL,
        CONSTRAINT FK_Pulls_Warehouse  FOREIGN KEY (WarehouseId) REFERENCES dbo.Warehouses(Id),
        CONSTRAINT FK_Pulls_CreatedBy  FOREIGN KEY (CreatedBy)   REFERENCES dbo.Users(Id),
        CONSTRAINT FK_Pulls_ClosedBy   FOREIGN KEY (ClosedBy)    REFERENCES dbo.Users(Id),
        CONSTRAINT FK_Pulls_ReopenedBy FOREIGN KEY (ReopenedBy)  REFERENCES dbo.Users(Id)
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_Pulls_WhDate'
      AND object_id = OBJECT_ID(N'dbo.Pulls')
)
BEGIN
    PRINT 'Creating index IX_Pulls_WhDate...';
    CREATE INDEX IX_Pulls_WhDate ON dbo.Pulls(WarehouseId, PullDate);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_Pulls_Status'
      AND object_id = OBJECT_ID(N'dbo.Pulls')
)
BEGIN
    PRINT 'Creating index IX_Pulls_Status...';
    CREATE INDEX IX_Pulls_Status ON dbo.Pulls(Status);
END
GO

------------------------------------------------------------------------------
-- §4.5 PullItems
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.PullItems', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.PullItems...';
    CREATE TABLE dbo.PullItems (
        Id          UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
        PullId      UNIQUEIDENTIFIER NOT NULL,
        ItemCode    VARCHAR(64)      NOT NULL,
        Description NVARCHAR(255)    NOT NULL,
        VendorCode  VARCHAR(64)      NULL,
        VendorName  NVARCHAR(160)    NULL,
        Tag         VARCHAR(16)      NULL
                     CONSTRAINT CK_PullItems_Tag
                     CHECK (Tag IN ('pcba','swap') OR Tag IS NULL),
        Status      VARCHAR(16)      NOT NULL DEFAULT 'normal'
                     CONSTRAINT CK_PullItems_Status
                     CHECK (Status IN ('normal','new','canceled')),
        Remark      NVARCHAR(255)    NULL,
        SortOrder   INT              NOT NULL DEFAULT 0,
        CONSTRAINT FK_PullItems_Pull FOREIGN KEY (PullId) REFERENCES dbo.Pulls(Id) ON DELETE CASCADE
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_PullItems_Pull'
      AND object_id = OBJECT_ID(N'dbo.PullItems')
)
BEGIN
    PRINT 'Creating index IX_PullItems_Pull...';
    CREATE INDEX IX_PullItems_Pull ON dbo.PullItems(PullId);
END
GO

------------------------------------------------------------------------------
-- §4.6 PullItemWindows — expected qty per hour
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.PullItemWindows', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.PullItemWindows...';
    CREATE TABLE dbo.PullItemWindows (
        Id          UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
        PullItemId  UNIQUEIDENTIFIER NOT NULL,
        HourOfDay   TINYINT          NOT NULL
                     CONSTRAINT CK_PIW_Hour
                     CHECK (HourOfDay BETWEEN 0 AND 23),
        ExpectedQty INT              NOT NULL DEFAULT 0,
        ReceivedQty INT              NOT NULL DEFAULT 0,  -- denormalized cache; truth = vw_PullItemReceived
        CONSTRAINT FK_PIW_PullItem FOREIGN KEY (PullItemId) REFERENCES dbo.PullItems(Id) ON DELETE CASCADE,
        CONSTRAINT UQ_PIW_Hour     UNIQUE (PullItemId, HourOfDay),
        CONSTRAINT CK_PIW_Caps     CHECK (ReceivedQty <= ExpectedQty AND ReceivedQty >= 0)
    );
END
GO

------------------------------------------------------------------------------
-- §4.7 Receipts — append-only, reverse-entry
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.Receipts', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.Receipts...';
    CREATE TABLE dbo.Receipts (
        Id                UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
        PullItemId        UNIQUEIDENTIFIER NOT NULL,
        HourOfDay         TINYINT          NOT NULL
                           CONSTRAINT CK_Receipts_Hour
                           CHECK (HourOfDay BETWEEN 0 AND 23),
        QtyReceived       INT              NOT NULL
                           CONSTRAINT CK_Receipts_QtyNonZero
                           CHECK (QtyReceived <> 0),
        LotBatch          VARCHAR(64)      NULL,
        PalletId          VARCHAR(64)      NULL,
        BinLocation       VARCHAR(64)      NULL,
        QcStatus          VARCHAR(32)      NOT NULL DEFAULT 'pending'
                           CONSTRAINT CK_Receipts_Qc
                           CHECK (QcStatus IN ('pending','passed','hold','rejected')),
        Note              NVARCHAR(500)    NULL,
        ReceivedBy        UNIQUEIDENTIFIER NOT NULL,
        ReceivedAt        DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),

        -- Reverse-entry linkage:
        ReversesReceiptId UNIQUEIDENTIFIER NULL,    -- this row IS a reversal → points to original
        ReversedById      UNIQUEIDENTIFIER NULL,    -- this row HAS BEEN voided → points to its reversal
        CancelReason      VARCHAR(32)      NULL
                           CONSTRAINT CK_Receipts_CancelReason
                           CHECK (CancelReason IN ('miscount','wrong-item','qc-fail','duplicate','other') OR CancelReason IS NULL),

        CONSTRAINT FK_Receipts_Item     FOREIGN KEY (PullItemId)        REFERENCES dbo.PullItems(Id),
        CONSTRAINT FK_Receipts_User     FOREIGN KEY (ReceivedBy)        REFERENCES dbo.Users(Id),
        CONSTRAINT FK_Receipts_Reverses FOREIGN KEY (ReversesReceiptId) REFERENCES dbo.Receipts(Id),
        CONSTRAINT FK_Receipts_Reversed FOREIGN KEY (ReversedById)      REFERENCES dbo.Receipts(Id),

        -- Either a positive (real receive) or negative (reversal) — never the other way around:
        CONSTRAINT CK_Receipts_ReversalIntegrity CHECK (
            (ReversesReceiptId IS NULL AND QtyReceived > 0) OR
            (ReversesReceiptId IS NOT NULL AND QtyReceived < 0)
        )
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_Receipts_PullItem'
      AND object_id = OBJECT_ID(N'dbo.Receipts')
)
BEGIN
    PRINT 'Creating index IX_Receipts_PullItem...';
    CREATE INDEX IX_Receipts_PullItem ON dbo.Receipts(PullItemId, HourOfDay);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_Receipts_When'
      AND object_id = OBJECT_ID(N'dbo.Receipts')
)
BEGIN
    PRINT 'Creating index IX_Receipts_When...';
    CREATE INDEX IX_Receipts_When ON dbo.Receipts(ReceivedAt);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_Receipts_Reverses'
      AND object_id = OBJECT_ID(N'dbo.Receipts')
)
BEGIN
    PRINT 'Creating filtered index IX_Receipts_Reverses...';
    CREATE INDEX IX_Receipts_Reverses ON dbo.Receipts(ReversesReceiptId)
        WHERE ReversesReceiptId IS NOT NULL;
END
GO

------------------------------------------------------------------------------
-- §4.9 AuditLog — append-only
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.AuditLog...';
    CREATE TABLE dbo.AuditLog (
        Id          BIGINT IDENTITY(1,1) PRIMARY KEY,
        ActionType  VARCHAR(16)      NOT NULL,    -- create|update|delete|assign|login|logout|receive|cancel|close|reopen
        EntityType  VARCHAR(32)      NULL,        -- User|Warehouse|Pull|Receipt|...
        EntityId    VARCHAR(64)      NULL,
        Message     NVARCHAR(1000)   NOT NULL,
        ActorUserId UNIQUEIDENTIFIER NULL,
        ActorName   NVARCHAR(160)    NULL,        -- denormalized; survives user deletion
        IpAddress   VARCHAR(64)      NULL,
        OccurredAt  DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Audit_Actor FOREIGN KEY (ActorUserId) REFERENCES dbo.Users(Id) ON DELETE SET NULL
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_Audit_When'
      AND object_id = OBJECT_ID(N'dbo.AuditLog')
)
BEGIN
    PRINT 'Creating index IX_Audit_When...';
    CREATE INDEX IX_Audit_When ON dbo.AuditLog(OccurredAt DESC);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_Audit_Action'
      AND object_id = OBJECT_ID(N'dbo.AuditLog')
)
BEGIN
    PRINT 'Creating index IX_Audit_Action...';
    CREATE INDEX IX_Audit_Action ON dbo.AuditLog(ActionType, OccurredAt DESC);
END
GO

------------------------------------------------------------------------------
-- §4.10 UserPreferences
------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.UserPreferences', N'U') IS NULL
BEGIN
    PRINT 'Creating table dbo.UserPreferences...';
    CREATE TABLE dbo.UserPreferences (
        UserId       UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        Theme        VARCHAR(16)      NOT NULL DEFAULT 'light'
                      CONSTRAINT CK_Prefs_Theme
                      CHECK (Theme IN ('light','midnight','slate')),
        NavPosition  VARCHAR(16)      NOT NULL DEFAULT 'horizontal'
                      CONSTRAINT CK_Prefs_NavPosition
                      CHECK (NavPosition IN ('horizontal','vertical')),
        NavBehavior  VARCHAR(16)      NOT NULL DEFAULT 'sticky'
                      CONSTRAINT CK_Prefs_NavBehavior
                      CHECK (NavBehavior IN ('sticky','auto-hide','static')),
        NavCollapsed BIT              NOT NULL DEFAULT 0,
        UpdatedAt    DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Prefs_User FOREIGN KEY (UserId) REFERENCES dbo.Users(Id) ON DELETE CASCADE
    );
END
GO

PRINT '001_schema.sql complete.';
GO
