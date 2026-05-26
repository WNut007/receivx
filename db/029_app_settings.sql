/* ============================================================================
   ReceivingOps — 029_app_settings.sql  (Phase 11.1 — config UI storage)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Creates dbo.AppSettings — the persistence layer for
   admin-edited configuration values that previously lived in appsettings.json
   + user-secrets only (Smtp:*, ErpDb:ConnectionString, Exports:*, ErpSync:*).

   Phase 11 design:
     - Non-secret values live in [Value]              (plaintext NVARCHAR(MAX))
     - Secret values live in [EncryptedValue]         (VARBINARY(MAX), encrypted
                                                        via ASP.NET Data Protection)
     - IsSecret pins the classification per key. CHECK constraint enforces the
       Value-XOR-EncryptedValue invariant so a secret never accidentally lands
       in the plaintext column.
     - Cleared settings (Value AND EncryptedValue both NULL) are allowed so
       the row can survive a temporary unset without losing the IsSecret flag.

   Precedence at read-time (implemented in C# AppSettingsService — not in SQL):
     env vars > this table > user-secrets > appsettings.json

   Bootstrap exclusions (NEVER written here):
     - ConnectionStrings:Default     -- chicken-and-egg: we read this row from
                                       the same DB the connection string opens
     - DataProtection:KeyDirectory   -- needed before any decrypt can happen
     - ASPNETCORE_ENVIRONMENT        -- process-level env, not app config

   Audit:
     Every set/delete writes a dbo.AuditLog row via IAuditService. The audit
     message NEVER contains a secret value (only the key + "[secret]" marker).

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.tables WHERE name = 'AppSettings' AND schema_id = SCHEMA_ID('dbo')
)
BEGIN
    PRINT 'Creating dbo.AppSettings...';
    CREATE TABLE dbo.AppSettings
    (
        [Key]              NVARCHAR(100)  NOT NULL
            CONSTRAINT PK_AppSettings PRIMARY KEY,
        [Value]            NVARCHAR(MAX)  NULL,
        EncryptedValue     VARBINARY(MAX) NULL,
        IsSecret           BIT            NOT NULL
            CONSTRAINT DF_AppSettings_IsSecret DEFAULT 0,
        UpdatedAt          DATETIME2(0)   NOT NULL
            CONSTRAINT DF_AppSettings_UpdatedAt DEFAULT SYSUTCDATETIME(),
        UpdatedBy          NVARCHAR(160)  NOT NULL,
        PreviousValueHash  NVARCHAR(64)   NULL,  -- SHA-256 hex of prior bytes (audit aid; never plaintext)

        CONSTRAINT CK_AppSettings_ValueOrEncrypted CHECK (
               (IsSecret = 0 AND [Value] IS NOT NULL AND EncryptedValue IS NULL)
            OR (IsSecret = 1 AND [Value] IS NULL     AND EncryptedValue IS NOT NULL)
            OR ([Value] IS NULL AND EncryptedValue IS NULL)   -- cleared; IsSecret retained
        )
    );
END
GO

PRINT '029_app_settings.sql complete (Phase 11.1).';
GO
