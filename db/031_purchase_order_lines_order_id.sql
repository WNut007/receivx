/* ============================================================================
   ReceivingOps — 031_purchase_order_lines_order_id.sql  (Phase 12.1)
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Single nullable column on dbo.PurchaseOrderLines.

   Phase 12 PO Excel import: the source spreadsheet carries two adjacent
   tracking IDs — "ORDER ID" (upstream sales-order ref) and "ASN NO"
   (advanced-ship-notice ref). The original Phase 9 design treated them
   as duplicates and folded both into AsnNo, but per the v3.2 mapping
   audit (decision C2=C, 2026-05-26) they are semantically distinct and
   both need to survive the import.

   Field redistribution:
     "ORDER ID" -> PurchaseOrderLines.OrderId   (this migration)
     "ASN NO"   -> PurchaseOrderLines.AsnNo     (from Phase 9 / db/021)

   No index added — same rationale as db/021. Speculative indexes before
   the query pattern is known waste write throughput on cold columns.
   The /Pos detail surface and Excel export will surface OrderId via the
   existing PoLineRow projection.

   Idempotent — safe to re-run (COL_LENGTH guard).
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'OrderId') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.OrderId (NVARCHAR(50) NULL)...';
    ALTER TABLE dbo.PurchaseOrderLines ADD OrderId NVARCHAR(50) NULL;
END
GO

PRINT '031_purchase_order_lines_order_id.sql complete (Phase 12.1).';
GO
