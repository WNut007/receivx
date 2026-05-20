namespace ReceivingOps.Web.Models.Dtos;

/// <summary>POST /api/receipts body. Cap-at-expected and pull-not-closed are enforced server-side (§7.1, §7.12).</summary>
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

public class ReceiveResult
{
    public Guid ReceiptId { get; set; }
    public int NewReceivedQty { get; set; }   // post-transaction PullItemWindows.ReceivedQty
}

/// <summary>POST /api/receipts/{id}/cancel body. Reason is required (§7.3).</summary>
public class CancelRequest
{
    public string Reason { get; set; } = "";   // miscount|wrong-item|qc-fail|duplicate|other
    public string? Note { get; set; }
}

public class CancelResult
{
    public Guid ReversalReceiptId { get; set; }
    public int NewReceivedQty { get; set; }
}

/// <summary>Query parameters for /api/transactions (§6 cross-pull journal).</summary>
public record TransactionsQuery(
    Guid? WarehouseId,
    string? WarehouseCode,    // accepted alongside WarehouseId — UI sends "WH-01"
    DateTime? DateFrom,
    DateTime? DateTo,
    string? Kind,             // receive|voided|reversal
    Guid? OperatorId,
    string? ReceivedByName,   // dropdown uses display names (no users API yet)
    string? PullNumber,
    string? ItemCode,
    int? Hour,
    string? Q,                // multi-token AND match
    int Take,                 // page size; controller clamps to a sane range
    int Skip)
{
    public TransactionsQuery() : this(null, null, null, null, null, null, null, null, null, null, null, 50, 0) {}
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
