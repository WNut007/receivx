/* ============================================================================
   ReceivingOps — 018_pulls_reference_number.sql  (Phase 7.1 of v2.x — Reports)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Per-pull free-text reference identifier (typically
   a vendor invoice number or external delivery-batch ID) — surfaces in the
   Reports view (Phase 7.2+) and as a filter on the closed-pulls list that
   feeds the DO render.

     1. ALTER Pulls ADD ReferenceNumber NVARCHAR(64) NULL
        (NULL on the column lets existing pulls stay un-flagged — backfill
         is intentionally NOT done; operators fill it in for new pulls
         and can edit it later on existing ones via the create/edit modal.)

   Semantics:
     - Reference is pull-level, not PO-level. One pull = one reference.
       Multiple POs landing into the same pull share the reference; this
       matches how vendors typically issue a single invoice covering a
       multi-PO delivery batch.
     - Editable post-create (unlike LockPoByPull / LockHourCap which are
       immutable). Vendors revise invoices; the system needs to follow.
     - 64 chars is enough headroom for any practical invoice ID without
       turning the column into a free-text dump.

   Naming note: this migration takes the db/018 slot. The "Pulls.CloseNote"
   migration mentioned in CLAUDE.md v2.x backlog (deferred from v2.1.1) is
   re-slotted to db/019_pulls_close_note.sql when it lands.

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE Name = N'ReferenceNumber'
      AND Object_ID = OBJECT_ID(N'dbo.Pulls')
)
BEGIN
    PRINT 'Adding Pulls.ReferenceNumber (NVARCHAR(64) NULL)...';
    ALTER TABLE dbo.Pulls
      ADD ReferenceNumber NVARCHAR(64) NULL;
END
GO

PRINT '018_pulls_reference_number.sql complete (Phase 7.1).';
GO
