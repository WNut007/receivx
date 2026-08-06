/* ============================================================================
   ReceivingOps — 048_lockhourcap_default_unlocked.sql
   ----------------------------------------------------------------------------
   Re-points dbo.Pulls.LockHourCap's DEFAULT from 1 (locked) to 0 (unlocked).

   EXISTING ROWS ARE NOT TOUCHED. No UPDATE runs here. Every pull that is
   locked today stays locked; whether to unlock them is an operational decision
   and is deliberately not taken by a migration.

   WHY
   ---
   db/017 introduced the column with DEFAULT 1, described as "strict by
   default". In practice the hour cap is now set on essentially every pull in
   the system, which makes it a constant rather than a control: at the time of
   writing, 11,621 of 11,661 pulls on the dev database carry LockHourCap = 1,
   and 11,587 of the 11,588 open pulls with outstanding work. A flag that is
   true everywhere expresses no decision.

   *** READ THIS BEFORE ASSUMING THIS MIGRATION CHANGES ANYTHING ***
   ------------------------------------------------------------------
   This DEFAULT is not what produces locked pulls. Every code path that
   inserts a pull writes the column EXPLICITLY, so the default never fires:

     1. Services/ErpSync/ErpUpsertService.cs:189
        INSERT INTO dbo.Pulls (..., LockPoByPull, LockHourCap, ...)
        VALUES (..., 1, 1, NULL);
        A hardcoded literal. Every ERP-synced pull — which is nearly all of
        them — is locked by this line, not by any default.

     2. Services/PullAdminService.cs:49,54
        Writes @LockHourCap from req.LockHourCap, and
        Models/Dtos/PullDtos.cs:229 declares
        `public bool LockHourCap { get; set; } = true;`
        so an API caller that omits the field still gets a locked pull.

     3. wwwroot/js/dashboard.js:123
        `lockHourCap: s.lockHourCap === undefined ? true : !!s.lockHourCap`
        The client applies the same true-by-default a third time.

   So this migration on its own changes the behaviour of NO existing code path.
   It only affects a raw INSERT that omits the column — a hand-written seed
   script, or future code that relies on the schema default rather than
   restating it. It is worth doing because the schema should not assert
   "locked" as the system's opinion while the intended default is the opposite,
   but it is necessary rather than sufficient: to actually change what new
   pulls get, the three sites above have to change, and that is an application
   decision, not a schema one.

   Idempotent — re-running is a no-op once the default reads ((0)).
   Reversible — re-create the constraint with DEFAULT 1 to undo.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

DECLARE @name  sysname = NULL;
DECLARE @defn  nvarchar(max) = NULL;

SELECT @name = dc.name, @defn = dc.definition
FROM   sys.default_constraints dc
JOIN   sys.columns c
       ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
WHERE  dc.parent_object_id = OBJECT_ID('dbo.Pulls')
  AND  c.name = 'LockHourCap';

IF @name IS NULL
BEGIN
    PRINT 'No default constraint on dbo.Pulls.LockHourCap — adding DF_Pulls_LockHourCap DEFAULT 0.';
    ALTER TABLE dbo.Pulls
        ADD CONSTRAINT DF_Pulls_LockHourCap DEFAULT (0) FOR LockHourCap;
END
ELSE IF REPLACE(REPLACE(@defn, '(', ''), ')', '') = '0'
BEGIN
    PRINT 'dbo.Pulls.LockHourCap already defaults to 0 — no change.';
END
ELSE
BEGIN
    PRINT CONCAT('Re-pointing ', @name, ' from ', @defn, ' to ((0))...');
    -- The constraint name is read from the catalog rather than assumed: db/017
    -- named it DF_Pulls_LockHourCap, but a column added without an explicit
    -- name would carry a system-generated one, and dropping the wrong object
    -- is not a mistake worth risking for the sake of a literal.
    DECLARE @sql nvarchar(max) =
        N'ALTER TABLE dbo.Pulls DROP CONSTRAINT ' + QUOTENAME(@name) + N';';
    EXEC sp_executesql @sql;

    ALTER TABLE dbo.Pulls
        ADD CONSTRAINT DF_Pulls_LockHourCap DEFAULT (0) FOR LockHourCap;
END
GO

------------------------------------------------------------------------------
-- Post-conditions: the default reads 0, and NO existing row moved.
------------------------------------------------------------------------------
DECLARE @after nvarchar(max) = (
    SELECT dc.definition
    FROM   sys.default_constraints dc
    JOIN   sys.columns c
           ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE  dc.parent_object_id = OBJECT_ID('dbo.Pulls') AND c.name = 'LockHourCap');

IF @after IS NULL OR REPLACE(REPLACE(@after, '(', ''), ')', '') <> '0'
    THROW 50048, 'db/048 post-check FAILED: LockHourCap does not default to 0.', 1;

-- Counts go into variables first: PRINT takes a scalar expression, and a
-- subquery inside CONCAT here is a parse error (Msg 1046), not a runtime one —
-- it fails the batch even though the DDL above already succeeded.
DECLARE @locked int   = (SELECT COUNT(*) FROM dbo.Pulls WHERE LockHourCap = 1);
DECLARE @unlocked int = (SELECT COUNT(*) FROM dbo.Pulls WHERE LockHourCap = 0);

PRINT CONCAT('db/048 post-check passed. Default is now ', @after,
             '. Locked pulls: ', @locked,
             ', unlocked pulls: ', @unlocked,
             ' (existing rows untouched).');
GO

PRINT '048_lockhourcap_default_unlocked.sql complete.';
GO
