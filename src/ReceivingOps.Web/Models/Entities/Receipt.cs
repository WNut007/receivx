namespace ReceivingOps.Web.Models.Entities;

public class Receipt
{
    public Guid Id { get; set; }
    public Guid PullItemId { get; set; }
    public byte HourOfDay { get; set; }
    public int QtyReceived { get; set; }       // positive = receive, negative = reversal
    public string? LotBatch { get; set; }
    public string? PalletId { get; set; }
    public string? BinLocation { get; set; }
    public string QcStatus { get; set; } = "pending";  // pending|passed|hold|rejected
    public string? Note { get; set; }
    public Guid ReceivedBy { get; set; }
    public DateTime ReceivedAt { get; set; }

    public Guid? ReversesReceiptId { get; set; }       // this row IS a reversal
    public Guid? ReversedById { get; set; }            // this row HAS BEEN voided
    public string? CancelReason { get; set; }          // miscount|wrong-item|qc-fail|duplicate|other
}
