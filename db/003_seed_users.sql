/* ============================================================================
   ReceivingOps — 003_seed_users.sql
   ----------------------------------------------------------------------------
   Six demo users matching the mockup (login.html demo credentials block).
   Passwords are hashed PBKDF2 via PasswordHasher<T> — never store plaintext.

   Plaintext mapping (regenerate with tools/HashPassword to rotate):
     sadmin      → admin
     swattana    → demo1234
     psomchai    → demo1234
     npatcharin  → demo1234
     kanucha     → demo1234
     tviewer     → demo1234 (IsActive = 0)

   Idempotent: re-running is a no-op for existing usernames.
   ============================================================================ */

USE [ReceivingOps];
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

-- Stable GUIDs so later seeds (assignments, pulls.CreatedBy, receipts.ReceivedBy)
-- can reference them deterministically across re-runs.
DECLARE @uSadmin     UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000001';
DECLARE @uSwattana   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000002';
DECLARE @uPsomchai   UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000003';
DECLARE @uNpatcharin UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000004';
DECLARE @uKanucha    UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000005';
DECLARE @uTviewer    UNIQUEIDENTIFIER = '11111111-1111-1111-1111-000000000006';

IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Username = 'sadmin')
    INSERT INTO dbo.Users (Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive)
    VALUES (@uSadmin, 'sadmin', 'System Admin', 'admin@company.com', NULL, 'admin',
            'AQAAAAIAAYagAAAAEJX8Fzz9xZZrfNzghoV/XXLeepFuSFitG2QanRc7ZsX76JZjtIj4GH3TtGxE3RFnng==', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Username = 'swattana')
    INSERT INTO dbo.Users (Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive)
    VALUES (@uSwattana, 'swattana', 'S. Wattana', 'swattana@company.com', NULL, 'supervisor',
            'AQAAAAIAAYagAAAAEMdixC6LiBtORd1eUFugyb21/kXGKqaChwTKCGAvQqVUgZVtJWOBcNY4qHOM1mKH8A==', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Username = 'psomchai')
    INSERT INTO dbo.Users (Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive)
    VALUES (@uPsomchai, 'psomchai', 'P. Somchai', 'psomchai@company.com', NULL, 'supervisor',
            'AQAAAAIAAYagAAAAEHNT1bvywZdvCsrXKfLglpoM//khdM803E9avPZWMxOBtZhwI0V/Nuyfoo2FIxvu5Q==', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Username = 'npatcharin')
    INSERT INTO dbo.Users (Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive)
    VALUES (@uNpatcharin, 'npatcharin', 'N. Patcharin', 'npatcharin@company.com', NULL, 'operator',
            'AQAAAAIAAYagAAAAEOeXMTWvhi6OCJ7ikqXVcOmrWO2GSK6eiVe7bIly0Mx/a9UonXrMzs+fHx3Szc1qRg==', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Username = 'kanucha')
    INSERT INTO dbo.Users (Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive)
    VALUES (@uKanucha, 'kanucha', 'K. Anucha', 'kanucha@company.com', NULL, 'operator',
            'AQAAAAIAAYagAAAAEEJRfB8YfSPj6riU2aAiWwm8uS2ISH4aLpNIP9GPGQQV9A54prkQPIu2oRlZyocvKA==', 1);

IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Username = 'tviewer')
    INSERT INTO dbo.Users (Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive)
    VALUES (@uTviewer, 'tviewer', 'T. Viewer', 'tviewer@company.com', NULL, 'viewer',
            'AQAAAAIAAYagAAAAEGRYu5UMNL7y5TkwzLaYH/Lnw8uCoNyEo99y7K2dg2WhAsz/G6JDs81ngFZkuy2J7g==', 0);

PRINT '003_seed_users.sql complete — 6 users.';
GO
