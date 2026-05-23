/* ============================================================================
   ReceivingOps — 017_add_lockhourcap.sql  (Phase 6.1 of v2.1)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Per-pull configurable hour-cap enforcement.

     1. ALTER Pulls ADD LockHourCap BIT NOT NULL
          + DF_Pulls_LockHourCap DEFAULT 1  (strict by default)

   Behavior recap (enforced in application code in Phase 6.2):
     - LockHourCap = 1: receive(qty) where qty > (window.ExpectedQty -
       window.ReceivedQty)  →  409 "Insufficient hour capacity".
     - LockHourCap = 0: per-hour ExpectedQty is a planning hint; overage
       is allowed when PO has capacity (the legacy §7.1 v2 behavior).

   Migration notes:
     - Existing pulls all inherit DEFAULT 1 (strict). Per user decision —
       any existing over-state stays in the DB (we don't retroactively
       cancel) but FUTURE receives on the same window are now blocked.
     - Like LockPoByPull (§3.5), LockHourCap is set at create-time only.
       Application enforces immutability — PUT /api/pulls echoes the
       current value; mismatch  →  409.

   Idempotent — safe to re-run.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- 1. Pulls.LockHourCap  (NOT NULL, default 1 — applied to existing rows)
------------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE Name = N'LockHourCap'
      AND Object_ID = OBJECT_ID(N'dbo.Pulls')
)
BEGIN
    PRINT 'Adding Pulls.LockHourCap (NOT NULL DEFAULT 1)...';
    ALTER TABLE dbo.Pulls
      ADD LockHourCap BIT NOT NULL
      CONSTRAINT DF_Pulls_LockHourCap DEFAULT 1;
END
GO

PRINT '017_add_lockhourcap.sql complete (Phase 6.1).';
GO
