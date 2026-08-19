/* ============================================================================
   ReceivingOps — 051_relax_pol_received_cap.sql
   ----------------------------------------------------------------------------
   ONE constraint, re-defined. No column, no index, no data change, no backfill.

     dbo.PurchaseOrderLines
       CK_POL_Caps   BEFORE  (ReceivedQty <= OrderedQty AND ReceivedQty >= 0)
                     AFTER   (ReceivedQty >= 0)

   The upper bound against OrderedQty is dropped. THE LOWER BOUND SURVIVES.

   ---------------------------------------------------------------------------
   DEPLOY ORDER — RUN THIS FILE ON PRODUCTION *BEFORE* the deploy
   ---------------------------------------------------------------------------
   Nut deploys by hand: publish on the dev machine, robocopy to
   C:\Programs\ReceivingOps with /XF web.config, app pool stopped and started
   around the copy. deploy.ps1 is not used and does not run migrations either
   way, so this file is a manual step and nothing will run it for you.

     1. Run this file on production.
     2. Verify — paste this and expect exactly the three values commented:

            SELECT c.definition                                   AS Definition,
                   CAST(c.is_disabled   AS INT)                   AS Disabled,
                   CAST(c.is_not_trusted AS INT)                  AS NotTrusted
            FROM   sys.check_constraints c
            WHERE  c.parent_object_id = OBJECT_ID('dbo.PurchaseOrderLines')
              AND  c.name = 'CK_POL_Caps';

            -- Definition  ([ReceivedQty]>=(0))
            -- Disabled    0
            -- NotTrusted  0

        Definition must NOT still mention OrderedQty, and must still mention
        ReceivedQty >= 0. Disabled or NotTrusted returning 1 means the
        constraint is not enforcing and the deploy must not proceed.

     3. Then deploy.

   Running this early is safe and changes nothing until the new build lands.
   The CURRENTLY DEPLOYED DLL never writes a ReceivedQty above OrderedQty —
   BuildAllocationPlan caps every allocation at that line's own remaining, and
   the overflow walk this release removes exists precisely to avoid exceeding
   it. So between step 1 and step 3 the live build behaves identically. There
   is no window where the old DLL breaks, and no rollback risk: reverting the
   DLL without reverting this file is also safe, for the same reason.

   ---------------------------------------------------------------------------
   WHY THE CAP IS BEING RELAXED
   ---------------------------------------------------------------------------
   An over-receipt stays on the PO line belonging to the pull being received.
   Receiving 501 against a line ordered at 500 records 501 on THAT line. It
   does not consume any other purchase order.

   CK_POL_Caps is what made that impossible, and is the reason the overflow
   walk existed: unable to write 501, the allocator spilled the excess into
   whatever other open line for the same vendor had room. Observed on
   production pull 0000028773 — one SKU, one window, 501 against 500. The walk
   put 500 on the pull's own PO and sent the remaining 1 to TH5805-P233094, a
   PO belonging to pull 0000015008. Two Receipts rows against two different
   purchase orders for what the operator experienced as one receive, and a
   Delivery Note that printed as two pages with different ASN, invoice and PO
   on each.

   ReceivedQty now means what it says: the figure actually received against
   that line, which may exceed what was ordered.

   NO SECOND COLUMN — DELIBERATE, DO NOT "FIX" THIS
   ------------------------------------------------
   An OverReceivedQty column was considered and rejected. It would keep every
   subtraction-based report working untouched, but then every place wanting the
   real received figure has to remember to add two columns, and any that forgot
   would silently under-report. A negative OrderedQty - ReceivedQty is visible
   the moment anyone looks at it; a quietly missing unit is not. Where a report
   needs the overage broken out, DERIVE it so it cannot disagree with the
   stored figure:

       CASE WHEN pol.ReceivedQty > pol.OrderedQty
            THEN pol.ReceivedQty - pol.OrderedQty ELSE 0 END

   THE LOWER BOUND IS LOAD-BEARING — DO NOT DROP IT WITH THE UPPER
   --------------------------------------------------------------
   ReceiptService.CancelAsync step 6 is a blind subtraction:

       UPDATE dbo.PurchaseOrderLines SET ReceivedQty = ReceivedQty - @Qty
        WHERE Id = @LineId;

   There is no floor anywhere in application code beneath it. This constraint
   is the only thing standing between a cancel-arithmetic bug and a negative
   ReceivedQty, and a DROP-and-recreate that quietly loses the >= 0 half would
   remove it without any test noticing until the data was already wrong.

   WHAT REPLACES THE DROPPED UPPER BOUND
   -------------------------------------
   Two application-layer guards ship in the same build, because a relaxed
   constraint makes the allocation plan the sole author of truth and a plan bug
   would otherwise write silently:

     * ReceiptService asserts the plan before writing — quantity is conserved,
       at most ONE line exceeds its OrderedQty, it is the last line walked, and
       that line belongs to the pull item's own storer.
     * The per-line UPDATE carries its own predicate, so the cap still binds on
       every line EXCEPT the one the plan designated to absorb the overage.

   Neither is a substitute for this file; both assume it has run.

   NO BACKFILL — no existing row changes. Rows already spread across POs by the
   overflow walk are left exactly as they are; repairing them is out of scope.

   Idempotent — sys.check_constraints guard on the definition text. Safe to
   re-run: a second run finds the relaxed definition already in place and does
   nothing.
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

------------------------------------------------------------------------------
-- 1. Re-define CK_POL_Caps — drop the OrderedQty upper bound, keep the floor
--
--    Guarded on the DEFINITION, not merely on the name: the constraint exists
--    both before and after this migration, so an EXISTS-by-name check would
--    make the file a no-op on its first run. The marker is whether the
--    definition still references OrderedQty.
------------------------------------------------------------------------------
IF EXISTS (
    SELECT 1
    FROM   sys.check_constraints c
    WHERE  c.parent_object_id = OBJECT_ID('dbo.PurchaseOrderLines')
      AND  c.name = 'CK_POL_Caps'
      AND  c.definition LIKE '%OrderedQty%'
)
BEGIN
    ALTER TABLE dbo.PurchaseOrderLines DROP CONSTRAINT CK_POL_Caps;

    -- WITH CHECK: validate every existing row on the way in, so the constraint
    -- lands trusted and the optimizer may keep using it. No row can fail — the
    -- new predicate is strictly weaker than the one just dropped — but an
    -- untrusted constraint is a silent downgrade and worth refusing.
    ALTER TABLE dbo.PurchaseOrderLines WITH CHECK
        ADD CONSTRAINT CK_POL_Caps CHECK (ReceivedQty >= 0);

    PRINT 'db/051: CK_POL_Caps relaxed - ReceivedQty may now exceed OrderedQty; floor kept at 0';
END
ELSE IF EXISTS (
    SELECT 1 FROM sys.check_constraints c
    WHERE  c.parent_object_id = OBJECT_ID('dbo.PurchaseOrderLines')
      AND  c.name = 'CK_POL_Caps'
)
    PRINT 'db/051: CK_POL_Caps already relaxed - no action';
ELSE
    PRINT 'db/051: WARNING - CK_POL_Caps not found at all; post-check below will fail';
GO

------------------------------------------------------------------------------
-- 2. Post-check — behavioural, not just structural.
--
--    Asserting the definition text alone would pass against a constraint that
--    was disabled or left untrusted, so this exercises the constraint: one
--    write that must now be ACCEPTED and one that must still be REJECTED.
--    Both run inside a transaction that is always rolled back, so the table is
--    untouched either way.
------------------------------------------------------------------------------
DECLARE @problems NVARCHAR(1000) = N'';
DECLARE @def      NVARCHAR(400);
DECLARE @disabled INT, @untrusted INT;

SELECT @def       = c.definition,
       @disabled  = CAST(c.is_disabled    AS INT),
       @untrusted = CAST(c.is_not_trusted AS INT)
FROM   sys.check_constraints c
WHERE  c.parent_object_id = OBJECT_ID('dbo.PurchaseOrderLines')
  AND  c.name = 'CK_POL_Caps';

IF @def IS NULL
    SET @problems = @problems + N'[CK_POL_Caps missing] ';
ELSE
BEGIN
    IF @def LIKE '%OrderedQty%'
        SET @problems = @problems + N'[still references OrderedQty] ';
    IF @def NOT LIKE '%ReceivedQty%'
        SET @problems = @problems + N'[lost the ReceivedQty floor] ';
    IF @disabled  = 1 SET @problems = @problems + N'[disabled] ';
    IF @untrusted = 1 SET @problems = @problems + N'[not trusted] ';
END

-- 2a. An over-receipt must now be ACCEPTED.
--     Probed on a real row so the check exercises the shipped table rather
--     than a temp table that shares nothing with it. Always rolled back.
IF @problems = N'' AND EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines)
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE TOP (1) dbo.PurchaseOrderLines SET ReceivedQty = OrderedQty + 1;
        ROLLBACK TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @problems = @problems + N'[rejects ReceivedQty > OrderedQty: '
                      + ERROR_MESSAGE() + N'] ';
    END CATCH
END

-- 2b. A negative must still be REJECTED. A silent success here means the
--     floor was lost with the ceiling, and CancelAsync has nothing beneath it.
IF @problems = N'' AND EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines)
BEGIN
    DECLARE @negativeAccepted BIT = 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE TOP (1) dbo.PurchaseOrderLines SET ReceivedQty = -1;
        ROLLBACK TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @negativeAccepted = 0;   -- rejected, which is correct
    END CATCH

    IF @negativeAccepted = 1
        SET @problems = @problems + N'[accepts negative ReceivedQty — floor lost] ';
END

IF LEN(@problems) > 0
BEGIN
    RAISERROR('db/051 FAILED — %s', 16, 1, @problems);
    RETURN;
END

PRINT 'db/051: OK - over-receipt accepted, negative rejected, constraint trusted.';
GO

------------------------------------------------------------------------------
-- 3. Verification (same query as the header; run it after the file)
------------------------------------------------------------------------------
SELECT c.definition                    AS Definition,   -- expect ([ReceivedQty]>=(0))
       CAST(c.is_disabled    AS INT)   AS Disabled,     -- expect 0
       CAST(c.is_not_trusted AS INT)   AS NotTrusted    -- expect 0
FROM   sys.check_constraints c
WHERE  c.parent_object_id = OBJECT_ID('dbo.PurchaseOrderLines')
  AND  c.name = 'CK_POL_Caps';
GO
