namespace ReceivingOps.Web.Models.Entities;

public class PurchaseOrderLine
{
    public Guid Id { get; set; }
    public Guid PurchaseOrderId { get; set; }
    public int LineNumber { get; set; }
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public int OrderedQty { get; set; }
    public int ReceivedQty { get; set; }   // denormalized cache; truth = SUM(Receipts.QtyReceived) for this line

    // Phase 14 (db/036): vendor moved from PurchaseOrders header to the line
    // so a single PO can carry mixed vendors. Sized VARCHAR(64) / NVARCHAR(160)
    // to match the columns that were dropped from PurchaseOrders.
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
}
