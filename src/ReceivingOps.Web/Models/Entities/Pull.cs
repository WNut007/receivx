namespace ReceivingOps.Web.Models.Entities;

public class Pull
{
    public Guid Id { get; set; }
    public string PullNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public DateTime PullDate { get; set; }
    public string Status { get; set; } = "pending";  // pending|in_progress|fully_received|closed
    public string? Eta { get; set; }
    public string? Notes { get; set; }
    public Guid? CreatedBy { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? FirstReceiptAt { get; set; }
    public DateTime? LastActivityAt { get; set; }
    public DateTime? ClosedAt { get; set; }
    public Guid? ClosedBy { get; set; }
    public string? SignatureSvg { get; set; }
    public DateTime? ReopenedAt { get; set; }
    public Guid? ReopenedBy { get; set; }
    public string? ReopenReason { get; set; }
    // §3.5 — when true, FIFO scope is restricted to POs linked to this pull (PO.PullId = this.Id).
    // Default false = warehouse-wide FIFO (backward compat). Immutable after pull creation.
    public bool LockPoByPull { get; set; }

    // v2.1 Phase 6 — when true, ReceiveAsync rejects qty > (window.ExpectedQty -
    // window.ReceivedQty) with 409. When false, per-hour ExpectedQty is a planning
    // hint and the PO is the only hard cap (legacy §7.1 v2 behavior).
    // Default true = strict. Immutable after pull creation.
    public bool LockHourCap { get; set; }
}
