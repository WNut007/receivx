namespace ReceivingOps.Web.Models.Dtos;

// ---------------------------------------------------------------------------
// v2.1 PullItem admin write surface — retires tools/add-pull-item.ps1.
// Read shape (PullItemDto, PullItemWindowDto) lives in PullDtos.cs and is
// reused as the response body for POST/PUT and the list endpoint.
// ---------------------------------------------------------------------------

/// <summary>
/// POST /api/pulls/{id}/items — create a new PullItem on an open pull.
/// (PullId, ItemCode) is the natural key; the service rejects duplicates
/// with 409 (no DB UNIQUE — pre-check is the app-level enforcement).
/// Windows are required (at least one) and define the per-hour expected
/// qty. Each HourOfDay must be 0..23 and unique within the request.
/// </summary>
public class PullItemCreateRequest
{
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public string? Tag { get; set; }                          // pcba|swap|null
    public string? Remark { get; set; }
    public List<PullItemWindowInput> Windows { get; set; } = new();
}

/// <summary>
/// PUT /api/pulls/{id}/items/{itemId} — edit Description/Vendor/Tag/Status/Remark.
/// ItemCode is intentionally absent (the natural key is immutable post-create —
/// receivers may already reference it). Windows go through the sub-resource
/// at /api/pulls/{id}/items/{itemId}/windows (Phase 6.2). SortOrder is
/// managed implicitly by Create (MAX+1); a drag-to-reorder pass is deferred.
/// </summary>
public class PullItemUpdateRequest
{
    public string Description { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public string? Tag { get; set; }                          // pcba|swap|null
    public string Status { get; set; } = "normal";            // normal|new|canceled
    public string? Remark { get; set; }
}

/// <summary>
/// Inline window spec for PullItemCreateRequest. HourOfDay 0..23 unique
/// per request; ExpectedQty must be positive.
/// </summary>
public class PullItemWindowInput
{
    public byte HourOfDay { get; set; }
    public int ExpectedQty { get; set; }
}
