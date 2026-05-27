/* ============================================================================
   ReceivingOps — 032_audit_action_type_widen.sql  (Phase 12.7)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Widens dbo.AuditLog.ActionType from VARCHAR(16)
   to VARCHAR(32).

   The Phase 12.5 audit ActionTypes — 'po-import-confirmed' (19),
   'po-import-succeeded' (19), 'po-import-failed' (16) — overflowed the
   original 16-char column from db/001. Inserts were silently swallowed
   by IAuditService (§8 audit-never-rolls-back-business-actions) so the
   import succeeded with a broken audit trail. Surfaced by the Phase 12.7
   integration smoke; latent in 12.5's source-level smoke which only
   verified the strings appeared in the source, not that they survived
   the INSERT.

   VARCHAR(32) leaves comfortable headroom — current usage maxes at
   13-19 chars across the entire codebase ('po-import-confirmed',
   'po-import-succeeded', 'config-delete', 'etl-skip', etc.) and ASCII-
   only action tokens don't need NVARCHAR.

   IX_Audit_Action ON (ActionType, OccurredAt DESC) — SQL Server widens
   the index leaf entries transparently on ALTER COLUMN when the change
   is non-narrowing. No DROP/CREATE INDEX needed.

   Idempotent — COL_LENGTH guard. Safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

-- COL_LENGTH returns the byte length, which for VARCHAR equals the
-- declared character length. < 32 catches the original 16-byte definition
-- and any prior widen to anything narrower than 32.
IF COL_LENGTH('dbo.AuditLog', 'ActionType') < 32
BEGIN
    PRINT 'Widening dbo.AuditLog.ActionType from VARCHAR(16) to VARCHAR(32)...';
    ALTER TABLE dbo.AuditLog
        ALTER COLUMN ActionType VARCHAR(32) NOT NULL;
END
ELSE
BEGIN
    PRINT 'dbo.AuditLog.ActionType already >= VARCHAR(32) — no change.';
END
GO

PRINT '032_audit_action_type_widen.sql complete (Phase 12.7).';
GO
