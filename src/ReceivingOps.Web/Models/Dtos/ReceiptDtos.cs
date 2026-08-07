namespace ReceivingOps.Web.Models.Dtos;

/// <summary>POST /api/receipts body. PO line is chosen server-side by FIFO (§7.14).
/// The pull-not-closed gate (§7.12) and PO cap (§7.1) are enforced server-side.</summary>
public class ReceiveRequest
{
    public Guid PullItemId { get; set; }
    public byte HourOfDay { get; set; }
    public int Qty { get; set; }
    public string? LotBatch { get; set; }
    public string? PalletId { get; set; }
    public string? BinLocation { get; set; }
    public string? QcStatus { get; set; }   // null → defaults to 'pending'
    public string? Note { get; set; }

    /// <summary>
    /// db/047 — operator ticked "this is the final receipt; close the line at this quantity".
    /// Defaults false, so existing callers that never send it keep today's behaviour exactly.
    ///
    /// Semantics (brief §6, and deliberately asymmetric):
    ///   • Qty &lt; outstanding, false → ordinary partial, line stays open. Unchanged.
    ///   • Qty &lt; outstanding, true  → short close: line closed at the actual figure.
    ///   • Qty &gt; outstanding, false → refused 400 OVER_RECEIPT_NOT_ACCEPTED.
    ///   • Qty &gt; outstanding, true  → over-receipt recorded, line closed.
    ///   • Qty = 0, true             → close-only. Writes NO Receipts row (§2d).
    ///
    /// Under is ambiguous ("the rest arrives Thursday" vs "that's all we're getting"), so the
    /// flag stays optional there and must never be inferred. Over has one reading, so the
    /// flag is mandatory. <see cref="Note"/> is required whenever this is true — it is the
    /// audit reason and is copied to PullItemWindows.ClosedReason.
    /// </summary>
    public bool VarianceAccepted { get; set; }
}

/// <summary>One slice of a FIFO-allocated receive — exactly one PO line consumed.</summary>
public class AllocationResult
{
    public Guid ReceiptId { get; set; }
    public Guid PurchaseOrderId { get; set; }
    public string PoNumber { get; set; } = "";
    public Guid PurchaseOrderLineId { get; set; }
    public int PoLineNumber { get; set; }
    public int Qty { get; set; }

    /// <summary>
    /// False when this slice was drawn from a PO that is not linked to the pull —
    /// a variance overflow allocation (§4.1). The modal marks these so the operator
    /// sees they are drawing on another PO before confirming, not after.
    /// Always true on the normal path and in warehouse-wide (Mode A) receives.
    /// </summary>
    public bool IsPullLinked { get; set; } = true;
}

/// <summary>
/// Response from POST /api/receipts. One call may produce multiple receipt rows
/// when the FIFO allocator splits qty across PO lines (§7.2a).
/// </summary>
public class ReceiveResult
{
    public List<AllocationResult> Allocations { get; set; } = new();
    public int TotalQty { get; set; }            // SUM of Allocations[].Qty
    public int NewReceivedQty { get; set; }      // post-tx PullItemWindows.ReceivedQty for the target hour
    public bool FullyReceived { get; set; }      // whether the pull is now fully received

    /// <summary>
    /// db/047 — recomputed outstanding for the target window AFTER this receive, as
    /// MAX(0, Expected - Received). Never negative, even on an over-receipt (§5).
    /// Returned so the caller can update without a refetch (§6).
    /// </summary>
    public int NewOutstanding { get; set; }

    /// <summary>db/047 — the window's IsClosed state after this receive.</summary>
    public bool IsClosed { get; set; }

    /// <summary>
    /// db/047 — signed variance actually persisted: positive = over, negative = short,
    /// null when this was an ordinary partial or an exact completion. Set on exactly one
    /// Receipts row per confirm even when the FIFO walk splits across PO lines (§2c).
    /// </summary>
    public int? VarianceQty { get; set; }
}

/// <summary>
/// GET /api/receipts/preview output (§7.2). Same FIFO algorithm as the
/// transactional path, but read-only and lock-free. Modal calls this on
/// debounced qty input so the operator sees the plan before clicking Confirm.
/// </summary>
/// <remarks>
/// §3.5 — Preview throws 409 on insufficient capacity (no more Shortage on the wire);
/// Shortage stays 0 on success and is kept only for transitional UI compatibility.
/// Scope tells callers which FIFO scope was used.
/// </remarks>
public class ReceivePreviewResult
{
    public List<AllocationResult> Allocations { get; set; } = new();
    public int TotalAllocatable { get; set; }    // SUM of remaining across all visible lines for this (warehouse,item) under the active scope
    public int Shortage { get; set; }            // always 0 on success in v2 — kept for transitional UI compatibility
    // "warehouse-wide" | "pull-locked" | "pull-locked + variance overflow"
    // The third value means at least one slice of the plan came from a PO line that is
    // NOT linked to this pull (§5.1). Decided from the plan, never from the request flag.
    public string Scope { get; set; } = "warehouse-wide";
}

/// <summary>
/// db/047 §2d — POST /api/receipts/reopen body. Clears the close flags on one window.
///
/// Exists because a zero-quantity close writes no <c>Receipts</c> row, so there is nothing
/// to reverse: without this the line would be permanently closed with no route back. It is
/// deliberately available for ANY closed window, not only zero-closed ones — a line closed
/// by a short receipt can be reopened this way too, and reversing that receipt remains the
/// other route.
///
/// The window is identified by (PullItemId, HourOfDay) because <c>Receipts</c> carries no
/// PullItemWindowId and the rest of the receive path keys on the same pair.
/// </summary>
public class ReopenWindowRequest
{
    public Guid PullItemId { get; set; }
    public byte HourOfDay { get; set; }

    /// <summary>Required. Reopening is a correction and must be attributable (§2d).</summary>
    public string Reason { get; set; } = "";
}

public class ReopenWindowResult
{
    public Guid PullItemId { get; set; }
    public byte HourOfDay { get; set; }
    public bool IsClosed { get; set; }        // always false on success
    public int NewOutstanding { get; set; }   // MAX(0, Expected - Received)
}

/// <summary>POST /api/receipts/{id}/cancel body. Reason is required (§7.3).</summary>
public class CancelRequest
{
    public string Reason { get; set; } = "";   // miscount|wrong-item|qc-fail|duplicate|other
    public string? Note { get; set; }
}

/// <summary>The PO line that just got its qty restored by a cancel (§7.3).</summary>
public class PoLineRestored
{
    public Guid PurchaseOrderId { get; set; }
    public string PoNumber { get; set; } = "";
    public Guid PurchaseOrderLineId { get; set; }
    public int LineNumber { get; set; }
    public int NewRemainingQty { get; set; }
}

public class CancelResult
{
    public Guid ReversalReceiptId { get; set; }
    public int NewReceivedQty { get; set; }
    public PoLineRestored? PoLineRestored { get; set; }
}

/// <summary>Query parameters for /api/transactions (§6 cross-pull journal).</summary>
public record TransactionsQuery(
    Guid? WarehouseId,
    string? WarehouseCode,
    DateTime? DateFrom,
    DateTime? DateTo,
    string? Kind,             // receive|voided|reversal
    Guid? OperatorId,
    string? ReceivedByName,
    string? PullNumber,
    string? PoNumber,         // §6 v2 — structured filter for the new PO context column
    string? ItemCode,
    int? Hour,
    string? Q,                // multi-token AND match (now includes PoNumber + VendorName, §6 v2)
    int Take,
    int Skip)
{
    public TransactionsQuery() : this(null, null, null, null, null, null, null, null, null, null, null, null, 50, 0) {}
}

public class PagedTransactions
{
    public IReadOnlyList<ReceiptJournalRow> Rows { get; set; } = Array.Empty<ReceiptJournalRow>();
    public int Total { get; set; }
    public int Take  { get; set; }
    public int Skip  { get; set; }
}

/// <summary>Row from vw_TransactionsJournal — used by the drawer + Receive Goods modal embedded list.</summary>
public class ReceiptJournalRow
{
    public Guid Id { get; set; }
    public Guid PullItemId { get; set; }
    public Guid PullId { get; set; }
    public string PullNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string WarehouseCode { get; set; } = "";
    public string WarehouseName { get; set; } = "";

    /// <summary>
    /// db/041 — IANA id from dbo.Warehouses.Timezone (default 'Asia/Bangkok').
    /// ReceivedAt is UTC; the KTF export renders Date/SHIFT/Time in this zone.
    /// Nullable defensively: the column is NOT NULL, but an unrecognised id
    /// falls back rather than throwing (see KtfExportJob.ResolveZone).
    /// </summary>
    public string? WarehouseTimezone { get; set; }

    public string ItemCode { get; set; } = "";
    public string ItemDescription { get; set; } = "";

    // §4.8 v2 — PO context. Mandatory on every row post-Phase-1b.
    public Guid PurchaseOrderId { get; set; }
    public string PoNumber { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }

    /// <summary>db/041 — PurchaseOrderLines.InvoiceNo (db/021). Feeds the KTF "INV." column.</summary>
    public string? InvoiceNo { get; set; }

    public Guid PurchaseOrderLineId { get; set; }
    public int PoLineNumber { get; set; }

    public byte HourOfDay { get; set; }
    public int QtyReceived { get; set; }
    public string? LotBatch { get; set; }
    public string? PalletId { get; set; }
    public string? BinLocation { get; set; }
    public string QcStatus { get; set; } = "pending";
    public string? Note { get; set; }
    public Guid ReceivedBy { get; set; }
    public string ReceivedByName { get; set; } = "";
    public DateTime ReceivedAt { get; set; }
    public Guid? ReversesReceiptId { get; set; }
    public Guid? ReversedById { get; set; }
    public string? CancelReason { get; set; }
    public string Kind { get; set; } = "receive";  // receive|voided|reversal

    // Phase 9.1 — ERP-sourced PullItem fields surfaced via vw_TransactionsJournal
    // (db/025). Optional on the row because PullItems values default to NULL
    // until ERP push fills them. The Transactions Excel export writes them as
    // columns 24..30; on-screen drawer / transactions page ignore them.
    // PullLocation + PullPhase are aliased in the view to dodge name collisions.
    public string? ProductFamily { get; set; }
    public string? FromSubInventory { get; set; }
    public string? ToSubInventory { get; set; }
    public string? SpecialControl { get; set; }
    public string? TrialId { get; set; }
    public string? PullLocation { get; set; }
    public string? PullPhase { get; set; }
}
