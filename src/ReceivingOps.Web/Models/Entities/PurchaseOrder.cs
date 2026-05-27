namespace ReceivingOps.Web.Models.Entities;

public class PurchaseOrder
{
    public Guid Id { get; set; }
    public string PoNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public DateTime OrderDate { get; set; }       // the FIFO key for allocation
    public DateTime? ExpectedDate { get; set; }
    public string Status { get; set; } = "open";  // open|closed|canceled
    public string? Notes { get; set; }
    public Guid? CreatedBy { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? ClosedAt { get; set; }
    // §3.5 — optional link to a Pull. When set, the linked Pull may restrict FIFO scope
    // to its own POs (see Pulls.LockPoByPull). Immutable after PO creation.
    public Guid? PullId { get; set; }

    // db/033 — denormalized external pull reference (PRS_ID from Phase 12
    // import). Independent of PullId/FK_PO_Pull. Receive flow (§7.15)
    // matches this against the receiving Pull's PullNumber when PullId
    // is NULL, letting an imported PO join a live receive without a
    // Pulls row ever existing for that PRS_ID.
    public string? PullExternalRef { get; set; }
}
