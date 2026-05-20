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
}
