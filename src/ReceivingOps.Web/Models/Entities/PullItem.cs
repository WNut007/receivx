namespace ReceivingOps.Web.Models.Entities;

public class PullItem
{
    public Guid Id { get; set; }
    public Guid PullId { get; set; }
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public string? Tag { get; set; }            // pcba|swap|null
    public string Status { get; set; } = "normal";  // normal|new|canceled
    public string? Remark { get; set; }
    public int SortOrder { get; set; }

    // Phase 9.1 — ERP-sourced metadata (editable until the Phase 10 push lands).
    public string? ProductFamily { get; set; }
    public string? FromSubInventory { get; set; }
    public string? ToSubInventory { get; set; }
    public string? SpecialControl { get; set; }
    public string? TrialId { get; set; }
    public string? Location { get; set; }
    public string? Phase { get; set; }
}
