/* ============================================================================
   db/053 — covering columns for the server-side Closed Pulls filters.

   Context: the /Reports "Closed Pulls" filter bar used to run in the browser
   over whichever ~50 rows were already in the DOM. It now runs in SQL
   (PullRepository.GetClosedWithReceiptsAsync), which adds two EXISTS probes to
   a query an operator re-runs on every debounced keystroke:

       EXISTS (SELECT 1 FROM dbo.PullItems pi
               WHERE pi.PullId = p.Id AND pi.ItemCode LIKE @Q)

       EXISTS (SELECT 1 FROM dbo.Receipts r
               JOIN dbo.PullItems pi2     ON pi2.Id = r.PullItemId
               JOIN dbo.PurchaseOrders po ON po.Id  = r.PurchaseOrderId
               WHERE pi2.PullId = p.Id AND po.PoNumber LIKE @Q)

   Both seek an existing index and then pay a key lookup per row for one column
   that is not in it. This migration adds those two columns as INCLUDEs.

   NO new indexes are created — both are rebuilds of existing ones with
   DROP_EXISTING = ON, which preserves the name, the key columns and anything
   referencing them.

   Nothing else in this change set needs an index: the pull-number and date
   predicates are already served by IX_Pulls_ClosedAt (filtered Status='closed',
   key ClosedAt, INCLUDE PullDate/PullNumber/Status/WarehouseId), which also
   matches the list's ORDER BY ClosedAt DESC, PullDate DESC; the signature
   predicates seek UQ_PullSig_Party, and UQ_PullSig_Party caps dbo.PullSignatures
   at three rows per pull.

   Idempotent: re-running is a no-op once both INCLUDEs are present.

   DEPLOY ORDER: this migration must run on the target database BEFORE the new
   DLL is deployed. The queries are correct without it — only slower.
   ========================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* dbo.Receipts carries a filtered index (IX_Receipts_Reverses), and SQL Server
   refuses CREATE INDEX on any table that has one unless QUOTED_IDENTIFIER and
   ANSI_NULLS are ON (msg 1934). sqlcmd runs with QUOTED_IDENTIFIER OFF by
   default, so set them explicitly rather than relying on the client. These must
   be re-stated in every batch — GO resets them. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------------
   1. IX_PullItems_Pull — add ItemCode as an INCLUDE.
      Key stays (PullId). The item-code search seeks PullId and currently looks
      up ItemCode from the clustered index for every item on every candidate
      pull.
   ------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('dbo.PullItems') AND name = 'IX_PullItems_Pull')
   AND NOT EXISTS (
       SELECT 1
       FROM   sys.index_columns ic
       JOIN   sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
       WHERE  ic.object_id = OBJECT_ID('dbo.PullItems')
         AND  ic.index_id  = (SELECT index_id FROM sys.indexes
                              WHERE object_id = OBJECT_ID('dbo.PullItems')
                                AND name = 'IX_PullItems_Pull')
         AND  ic.is_included_column = 1
         AND  c.name = 'ItemCode')
BEGIN
    PRINT 'db/053: rebuilding IX_PullItems_Pull with INCLUDE (ItemCode)';
    CREATE NONCLUSTERED INDEX IX_PullItems_Pull
        ON dbo.PullItems (PullId)
        INCLUDE (ItemCode)
        WITH (DROP_EXISTING = ON);
END
ELSE
    PRINT 'db/053: IX_PullItems_Pull already covers ItemCode - skipped';
GO

/* ---------------------------------------------------------------------------
   2. IX_Receipts_PullItem — add PurchaseOrderId as an INCLUDE.
      Key stays (PullItemId, HourOfDay). The PO-number search walks
      PullItems -> Receipts -> PurchaseOrders; without this it looks up
      PurchaseOrderId from the clustered index for every receipt it touches.
   ------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('dbo.Receipts') AND name = 'IX_Receipts_PullItem')
   AND NOT EXISTS (
       SELECT 1
       FROM   sys.index_columns ic
       JOIN   sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
       WHERE  ic.object_id = OBJECT_ID('dbo.Receipts')
         AND  ic.index_id  = (SELECT index_id FROM sys.indexes
                              WHERE object_id = OBJECT_ID('dbo.Receipts')
                                AND name = 'IX_Receipts_PullItem')
         AND  ic.is_included_column = 1
         AND  c.name = 'PurchaseOrderId')
BEGIN
    PRINT 'db/053: rebuilding IX_Receipts_PullItem with INCLUDE (PurchaseOrderId)';
    CREATE NONCLUSTERED INDEX IX_Receipts_PullItem
        ON dbo.Receipts (PullItemId, HourOfDay)
        INCLUDE (PurchaseOrderId)
        WITH (DROP_EXISTING = ON);
END
ELSE
    PRINT 'db/053: IX_Receipts_PullItem already covers PurchaseOrderId - skipped';
GO

/* ---------------------------------------------------------------------------
   3. Verification. Both must report 1; the migration is pointless otherwise.
   ------------------------------------------------------------------------- */
SELECT
    CAST(CASE WHEN EXISTS (
        SELECT 1 FROM sys.index_columns ic
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        WHERE i.object_id = OBJECT_ID('dbo.PullItems') AND i.name = 'IX_PullItems_Pull'
          AND ic.is_included_column = 1 AND c.name = 'ItemCode') THEN 1 ELSE 0 END AS bit)
        AS PullItems_Covers_ItemCode,
    CAST(CASE WHEN EXISTS (
        SELECT 1 FROM sys.index_columns ic
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        WHERE i.object_id = OBJECT_ID('dbo.Receipts') AND i.name = 'IX_Receipts_PullItem'
          AND ic.is_included_column = 1 AND c.name = 'PurchaseOrderId') THEN 1 ELSE 0 END AS bit)
        AS Receipts_Covers_PurchaseOrderId;
GO
