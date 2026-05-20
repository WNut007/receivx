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
}
