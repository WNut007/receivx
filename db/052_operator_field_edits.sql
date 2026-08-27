/* ============================================================================
   ReceivingOps — 052_operator_field_edits.sql
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. One new table, one column on dbo.PullItems, three
   columns on dbo.ErpSyncLog, and one idempotent backfill.

     dbo.OperatorFieldEdits              (new table)
     dbo.PullItems
       Origin                 VARCHAR(16)   NULL
     dbo.ErpSyncLog
       FieldsSkippedCount     INT           NULL
       FieldsWrittenCount     INT           NULL
       FieldProtectionTotals  NVARCHAR(MAX) NULL

   ---------------------------------------------------------------------------
   DEPLOY ORDER — RUN THIS FILE ON PRODUCTION *BEFORE* deploy.ps1
   ---------------------------------------------------------------------------
   deploy.ps1 does NOT run migrations and its auto-rollback restores the DLL,
   not the schema. db/046 went out the other way round and the import path
   threw on a missing column until someone ran the migration by hand.

   The build shipping with this migration SELECTs dbo.OperatorFieldEdits on
   every ERP-sync pull, SELECTs dbo.PullItems.Origin on the cancel path, and
   UPDATEs the three ErpSyncLog columns at the end of each run. All of it is
   absent from the currently deployed DLL, so:

     1. Run this file on production.
     2. Verify — all five must return a non-NULL value:

            SELECT OBJECT_ID('dbo.OperatorFieldEdits')              AS EditsTable,
                   COL_LENGTH('dbo.PullItems', 'Origin')            AS ItemOrigin,
                   COL_LENGTH('dbo.ErpSyncLog','FieldsSkippedCount')    AS Skipped,
                   COL_LENGTH('dbo.ErpSyncLog','FieldsWrittenCount')    AS Written,
                   COL_LENGTH('dbo.ErpSyncLog','FieldProtectionTotals') AS Totals;

     3. Then run deploy.ps1.
     4. Restart, so IOptions and the Hangfire worker pick the new build up.

   Running step 1 early is safe. The new table is only ever read by the new
   build; the three added columns are nullable with no default; and every
   INSERT the CURRENTLY DEPLOYED DLL issues names its columns explicitly and
   omits Origin. There is no window in which the old DLL breaks.

   ---------------------------------------------------------------------------
   WHAT THIS IS FOR
   ---------------------------------------------------------------------------
   Once data is in Receivx, it belongs to Receivx. ERP sync populates a pull
   initially; after that, anything an operator changes is authoritative and no
   later sync may overwrite it.

   Semantics are "the operator wins PERMANENTLY" — a field an operator has
   edited is never written by ETL again for the life of that pull, even if ERP
   later sends a different value. This is deliberately NOT "wins until ERP
   changes"; there is no comparison against the ERP value at read time and no
   conflict flag. Both alternatives were considered and rejected.

   Protection is FIELD-level, not row-level: editing Remark must not freeze
   ExpectedQty. Twelve fields are protectable, being every field an operator
   can change that ETL also writes:

     dbo.Pulls             PullDate
     dbo.PullItems         Description, VendorCode, Remark,
                           ProductFamily, FromSubInventory, ToSubInventory,
                           SpecialControl, TrialId, Location, Phase
     dbo.PullItemWindows   ExpectedQty

   Fields an operator can edit that ETL never writes (Eta, Notes,
   ReferenceNumber, VendorName, Tag, and the window close/variance columns)
   need no protection and are not recorded here. PullItems.SortOrder is
   neither operator-editable nor ETL-updated today; if a reorder endpoint is
   ever added it must mark ownership like the others.

   The pre-existing STATIC protected-column list in ErpUpsertService is
   unchanged and stays authoritative for the fields it names (Pulls.Status,
   ClosedAt, SignatureSvg, PullItemWindows.ReceivedQty, and so on). That list
   is a compile-time constant about columns ETL must NEVER write for anyone.
   This table is the per-row, per-field, runtime complement to it. The two do
   not overlap and neither replaces the other.

   ---------------------------------------------------------------------------
   DECISION — UN-EDITING: A FIELD STAYS OWNED
   ---------------------------------------------------------------------------
   If an operator edits Remark and then sets it back to the value ERP
   originally supplied, the field REMAINS owned and ETL still will not write
   it. Ownership is never released; there is no DELETE from this table on any
   code path.

   The operator made a deliberate choice, and silently handing the field back
   to ERP control because the value happens to coincide today would mean the
   next sync that changes it overwrites a decision the operator believes they
   still hold. LastEditedAt moves on such a write; the row is never removed.

   ---------------------------------------------------------------------------
   DECISION — OWNERSHIP IS RECORDED FROM A VALUE DIFF, NEVER FROM PRESENCE
   ---------------------------------------------------------------------------
   The operator endpoints are bulk-overwrite PUTs: every request carries every
   field, and a blank means NULL. "The request included Remark" is therefore
   true on every single call and says nothing about whether the operator
   changed it.

   Rows are written here only for fields whose value actually CHANGED, decided
   by comparing old against new inside the write transaction. Recording on
   request presence instead would freeze all six fields of an item on the first
   PUT of any kind, turning field-level protection into row-level protection
   while every test still passed.

   ---------------------------------------------------------------------------
   DECISION — BACKFILL: EVERY PRE-MIGRATION ROW IS TREATED AS UNTOUCHED
   ---------------------------------------------------------------------------
   dbo.OperatorFieldEdits is created EMPTY and is not backfilled.

   No history exists for edits made before this migration — the audit trail
   records that an item was updated but never which fields or what values (see
   PullItemAdminService's audit message), so there is nothing to reconstruct
   from. Every row that predates this migration is therefore treated as
   untouched and remains fully writable by ETL, exactly as it is today.

   The practical consequence is accepted deliberately: an operator remark
   entered last week is still overwritable until someone edits it again, at
   which point it becomes owned. Protection starts now and is not retroactive.

   dbo.PullItems.Origin IS backfilled, because there the evidence does exist —
   see below.
   ============================================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------------------------------------------------------------------------
   1. dbo.OperatorFieldEdits
   ---------------------------------------------------------------------------
   One row per (row, field) an operator has changed. Field-level granularity
   with no schema churn when a new editable field appears later: FieldName is
   DATA, so a new field costs one call at its write site and no migration.

   The clustered PK is (EntityType, EntityId, FieldName) so the ETL's read —
   "every mark for this pull's rows" — is a range seek per entity, and the
   per-field upsert on the write side is a single-row seek. There is no
   surrogate key: the natural key is the identity of the fact.
--------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.OperatorFieldEdits', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.OperatorFieldEdits
    (
        -- 'Pull' | 'PullItem' | 'PullItemWindow'. Not an FK: three parent
        -- tables cannot be referenced by one column, and the rows are
        -- deliberately allowed to outlive a deleted parent (an operator
        -- deleting an item then ERP re-adding it must not silently hand the
        -- new row's fields back to ETL under a recycled GUID -- NEWID() makes
        -- that impossible in practice, but the ordering is stated on purpose).
        EntityType    VARCHAR(20)      NOT NULL,
        EntityId      UNIQUEIDENTIFIER NOT NULL,

        -- The column name as it appears in the table, e.g. 'Remark',
        -- 'ExpectedQty'. Never operator input: the writing code passes a
        -- compile-time constant, so this can be interpolated into the ETL's
        -- dynamic SET clause without an injection surface.
        FieldName     VARCHAR(64)      NOT NULL,

        FirstEditedAt DATETIME2(3)     NOT NULL CONSTRAINT DF_OFE_FirstEditedAt DEFAULT SYSUTCDATETIME(),
        FirstEditedBy UNIQUEIDENTIFIER NULL,
        LastEditedAt  DATETIME2(3)     NOT NULL CONSTRAINT DF_OFE_LastEditedAt  DEFAULT SYSUTCDATETIME(),
        LastEditedBy  UNIQUEIDENTIFIER NULL,

        CONSTRAINT PK_OperatorFieldEdits PRIMARY KEY CLUSTERED (EntityType, EntityId, FieldName),
        CONSTRAINT CK_OFE_EntityType CHECK (EntityType IN ('Pull', 'PullItem', 'PullItemWindow'))
    );

    PRINT 'db/052: created dbo.OperatorFieldEdits';
END
ELSE
    PRINT 'db/052: dbo.OperatorFieldEdits already exists — skipped';
GO

/* Covering index for the forensic query this table exists to make possible:
   "which fields have operators been overriding, and when". The PK serves the
   ETL read; this serves the human one. */
IF OBJECT_ID('dbo.OperatorFieldEdits', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'IX_OFE_FieldName_LastEdited'
                     AND object_id = OBJECT_ID('dbo.OperatorFieldEdits'))
BEGIN
    CREATE INDEX IX_OFE_FieldName_LastEdited
        ON dbo.OperatorFieldEdits (FieldName, LastEditedAt DESC)
        INCLUDE (EntityType, EntityId, LastEditedBy);
    PRINT 'db/052: created IX_OFE_FieldName_LastEdited';
END
ELSE
    PRINT 'db/052: IX_OFE_FieldName_LastEdited already present — skipped';
GO

/* ---------------------------------------------------------------------------
   2. dbo.PullItems.Origin
   ---------------------------------------------------------------------------
   Provenance, so the ETL cancel path can tell an operator-created item from an
   ERP-sourced one. Same name, same width, same NULL-means-ordinary convention
   as db/050's Pulls.Origin and PurchaseOrders.Origin.

     NULL         ERP-fed, or created before this migration
     'operator'   created by an operator through the API
     'po-import'  created by the WIP pull synthesis

   Items in the DB but absent from the ERP draft are flipped to
   Status='canceled'. An operator-created item is BY DEFINITION never in the
   draft, so before this column it was canceled on the next in-window sync --
   one traceable victim in production (WIDGET-1000 on pull 0000015899, created
   2026-06-11 08:32:46, canceled by the 09:00:14 run 28 minutes later).

   This also closes a design inconsistency: the update path already preserves
   PullItems.Status so ETL does not override an operator's decision, while the
   missing-from-draft path overrode that same column.
--------------------------------------------------------------------------- */
IF COL_LENGTH('dbo.PullItems', 'Origin') IS NULL
BEGIN
    ALTER TABLE dbo.PullItems ADD Origin VARCHAR(16) NULL;
    PRINT 'db/052: added dbo.PullItems.Origin';
END
ELSE
    PRINT 'db/052: dbo.PullItems.Origin already exists — skipped';
GO

/* ---------------------------------------------------------------------------
   2b. Backfill dbo.PullItems.Origin = 'operator' from the audit trail
   ---------------------------------------------------------------------------
   Unlike the field-edit history, this evidence DOES exist and is exact.
   PullItemAdminService writes ActionType='create' / EntityType='PullItem'
   through the request-scoped audit path, while the ETL writes 'etl-create'
   and the WIP synthesis writes 'pull-synthesized'. So an audit row with
   ActionType='create' and EntityType='PullItem' identifies an operator-created
   item unambiguously, with no heuristic.

   Idempotent: the WHERE clause skips anything already stamped, so re-running
   is a no-op. It never clears an Origin and never stamps a row the audit does
   not vouch for.

   Deliberately NOT done here: un-cancelling items this backfill now exempts.
   WIDGET-1000 stays Status='canceled'. That is business data, and the operator
   who owns it can un-cancel it through the UI if they still want it.
--------------------------------------------------------------------------- */
UPDATE pi
   SET pi.Origin = 'operator'
  FROM dbo.PullItems pi
 WHERE pi.Origin IS NULL
   AND EXISTS (SELECT 1
                 FROM dbo.AuditLog a
                WHERE a.EntityType = 'PullItem'
                  AND a.ActionType = 'create'
                  AND a.EntityId   = CONVERT(VARCHAR(36), pi.Id));

PRINT 'db/052: backfilled Origin=''operator'' on ' + CONVERT(VARCHAR, @@ROWCOUNT) + ' item(s)';
GO

/* ---------------------------------------------------------------------------
   3. dbo.ErpSyncLog — field-protection reporting
   ---------------------------------------------------------------------------
   Nothing recorded what ETL overwrote, which is why the problem ran for weeks
   unnoticed and why a probe of the audit trail could not answer "when did this
   remark get replaced". Aggregated per RUN, not per field: 469 pulls x ~10
   fields an hour would be 4,690 rows an hour to say almost nothing.

   Two scalars ALONGSIDE the JSON on purpose. ItemsCanceled being a plain
   column is what made "how many items did sync cancel in 30 days" answerable
   in one query during the probe, while a JSON-only figure has to be parsed
   before it can be alerted on or trended. Same lesson applied.

     FieldsSkippedCount     writes suppressed because the field is owned
     FieldsWrittenCount     writes ETL performed
     FieldProtectionTotals  per-field breakdown, shape:
       {
         "skipped": { "Remark": 12, "ExpectedQty": 5 },
         "written": { "Remark": 4501, "PullDate": 469 },
         "rowsWithAnySkip": 18,
         "itemsExemptCreated": 7
       }
--------------------------------------------------------------------------- */
IF COL_LENGTH('dbo.ErpSyncLog', 'FieldsSkippedCount') IS NULL
BEGIN
    ALTER TABLE dbo.ErpSyncLog ADD FieldsSkippedCount INT NULL;
    PRINT 'db/052: added dbo.ErpSyncLog.FieldsSkippedCount';
END
ELSE
    PRINT 'db/052: dbo.ErpSyncLog.FieldsSkippedCount already exists — skipped';
GO

IF COL_LENGTH('dbo.ErpSyncLog', 'FieldsWrittenCount') IS NULL
BEGIN
    ALTER TABLE dbo.ErpSyncLog ADD FieldsWrittenCount INT NULL;
    PRINT 'db/052: added dbo.ErpSyncLog.FieldsWrittenCount';
END
ELSE
    PRINT 'db/052: dbo.ErpSyncLog.FieldsWrittenCount already exists — skipped';
GO

IF COL_LENGTH('dbo.ErpSyncLog', 'FieldProtectionTotals') IS NULL
BEGIN
    ALTER TABLE dbo.ErpSyncLog ADD FieldProtectionTotals NVARCHAR(MAX) NULL;
    PRINT 'db/052: added dbo.ErpSyncLog.FieldProtectionTotals';
END
ELSE
    PRINT 'db/052: dbo.ErpSyncLog.FieldProtectionTotals already exists — skipped';
GO

/* ---------------------------------------------------------------------------
   4. Verification — every one of these must be non-NULL before deploy.ps1
--------------------------------------------------------------------------- */
SELECT OBJECT_ID('dbo.OperatorFieldEdits')                    AS EditsTable,
       COL_LENGTH('dbo.PullItems',  'Origin')                 AS ItemOrigin,
       COL_LENGTH('dbo.ErpSyncLog', 'FieldsSkippedCount')     AS FieldsSkippedCount,
       COL_LENGTH('dbo.ErpSyncLog', 'FieldsWrittenCount')     AS FieldsWrittenCount,
       COL_LENGTH('dbo.ErpSyncLog', 'FieldProtectionTotals')  AS FieldProtectionTotals;
GO
