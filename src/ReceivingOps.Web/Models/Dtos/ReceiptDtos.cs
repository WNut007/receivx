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
    public string Scope { get; set; } = "warehouse-wide";  // "warehouse-wide" | "pull-locked"
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
    public string ItemCode { get; set; } = "";
    public string ItemDescription { get; set; } = "";

    // §4.8 v2 — PO context. Mandatory on every row post-Phase-1b.
    public Guid PurchaseOrderId { get; set; }
    public string PoNumber { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
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
}
