/* ============================================================================
   ReceivingOps — 002_views.sql
   ----------------------------------------------------------------------------
   Idempotent: uses CREATE OR ALTER so re-running just replaces the view.
   These views are the single source of truth for net received qty.
   §7.11: NEVER count receipt rows manually — always read these views.
   ============================================================================ */

USE [ReceivingOps];
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

------------------------------------------------------------------------------
-- §4.8 vw_PullItemReceived
-- Net received per (item, hour) — sums positive (real receipts) and negative
-- (reversal) rows. ALL downstream progress/close calculations use this.
------------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_PullItemReceived AS
SELECT  PullItemId,
        HourOfDay,
        SUM(QtyReceived) AS NetReceived
FROM    dbo.Receipts
GROUP BY PullItemId, HourOfDay;
GO

------------------------------------------------------------------------------
-- §4.8 vw_PullProgress
-- Per-pull progress summary used by the dashboard.
-- Excludes canceled items from totals.
------------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_PullProgress AS
SELECT  p.Id AS PullId,
        p.PullNumber,
        p.Status,
        p.WarehouseId,
        SUM(CASE WHEN pi.Status <> 'canceled' THEN piw.ExpectedQty ELSE 0 END)         AS TotalExpected,
        SUM(CASE WHEN pi.Status <> 'canceled' THEN ISNULL(v.NetReceived, 0) ELSE 0 END) AS TotalReceived,
        COUNT(DISTINCT CASE WHEN pi.Status <> 'canceled' THEN pi.Id END)                AS ActiveItemCount
FROM    dbo.Pulls p
LEFT JOIN dbo.PullItems pi          ON pi.PullId = p.Id
LEFT JOIN dbo.PullItemWindows piw   ON piw.PullItemId = pi.Id
LEFT JOIN dbo.vw_PullItemReceived v ON v.PullItemId = pi.Id AND v.HourOfDay = piw.HourOfDay
GROUP BY p.Id, p.PullNumber, p.Status, p.WarehouseId;
GO

------------------------------------------------------------------------------
-- §4.8 vw_TransactionsJournal
-- Used by both the in-page drawer and the standalone Transactions page.
-- Kind classifier:
--   'reversal' — this row is a reversal (negative qty)
--   'voided'   — this row is the original, already voided by a reversal
--   'receive'  — normal positive receipt, not yet voided
------------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_TransactionsJournal AS
SELECT  r.Id,
        r.PullItemId,
        pi.PullId,
        p.PullNumber,
        p.WarehouseId,
        w.Code           AS WarehouseCode,
        w.Name           AS WarehouseName,
        pi.ItemCode,
        pi.Description   AS ItemDescription,
        r.HourOfDay,
        r.QtyReceived,
        r.LotBatch,
        r.PalletId,
        r.BinLocation,
        r.QcStatus,
        r.Note,
        r.ReceivedBy,
        u.Name           AS ReceivedByName,
        r.ReceivedAt,
        r.ReversesReceiptId,
        r.ReversedById,
        r.CancelReason,
        CASE
            WHEN r.QtyReceived < 0          THEN 'reversal'
            WHEN r.ReversedById IS NOT NULL THEN 'voided'
            ELSE 'receive'
        END AS Kind
FROM    dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p      ON p.Id  = pi.PullId
INNER JOIN dbo.Warehouses w ON w.Id  = p.WarehouseId
INNER JOIN dbo.Users u      ON u.Id  = r.ReceivedBy;
GO

PRINT '002_views.sql complete.';
GO
