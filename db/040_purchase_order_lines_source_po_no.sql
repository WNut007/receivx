/* ============================================================================
   ReceivingOps — 040_purchase_order_lines_source_po_no.sql
   ----------------------------------------------------------------------------
   ADDITIVE, NON-BREAKING. Single nullable column on dbo.PurchaseOrderLines.

   The PO Excel import source spreadsheet carries a "PO" column (e.g.
   "TH5805-P230603") that is the actual upstream purchase-order number.
   Per the v3.2 mapping audit (decision C1=A) the importer takes
   "PULL SHEET ID / PRS NO" as PurchaseOrders.PoNumber and deliberately
   IGNORED the "PO" column — so the real PO number was dropped on every
   import. This migration gives it a home.

   Field mapping:
     "PO"  ->  PurchaseOrderLines.SourcePoNo   (this migration)

   Line grain, not header: like vendor (Phase 14, db/036) the source PO
   can differ across lines that share one PRS_ID, so it belongs on the
   line. NVARCHAR(50) matches the other ERP-sourced tracking columns
   from db/021.

   No index — same rationale as db/021 / db/031. Speculative indexes
   before the query pattern is known waste write throughput on a cold
   column. /Pos detail, the Phase 9.2 edit modal, and the Excel export
   surface it via the existing PoLineRow / PoLineExportRow projections.

   Idempotent — safe to re-run (COL_LENGTH guard).
   ============================================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE [ReceivingOps];
GO

IF COL_LENGTH('dbo.PurchaseOrderLines', 'SourcePoNo') IS NULL
BEGIN
    PRINT 'Adding PurchaseOrderLines.SourcePoNo (NVARCHAR(50) NULL)...';
    ALTER TABLE dbo.PurchaseOrderLines ADD SourcePoNo NVARCHAR(50) NULL;
END
GO

PRINT '040_purchase_order_lines_source_po_no.sql complete.';
GO
