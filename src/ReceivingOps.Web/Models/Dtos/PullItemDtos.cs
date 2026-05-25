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

/// <summary>
/// POST /api/pulls/{id}/items/{itemId}/windows — add one hour window.
/// HourOfDay must be 0..23 and unique on the item (UQ_PIW_Hour at DB; the
/// service surfaces the violation as 409 with a friendlier message).
/// ExpectedQty must be positive.
/// </summary>
public class PullItemWindowCreateRequest
{
    public byte HourOfDay { get; set; }
    public int ExpectedQty { get; set; }
}

/// <summary>
/// PUT /api/pulls/{id}/items/{itemId}/windows/{hour} — edit ExpectedQty
/// for an existing hour. HourOfDay is implicit (from the route) and
/// immutable through this endpoint — to "move" a window across hours,
/// delete the old hour and POST a new one.
///
/// Refused (409) when:
///   • new ExpectedQty &lt; existing ReceivedQty (would violate CK_PIW_Caps,
///     and would silently invalidate receipts already booked against it).
/// </summary>
public class PullItemWindowUpdateRequest
{
    public int ExpectedQty { get; set; }
}

/// <summary>
/// Phase 9.1 — PUT /api/pulls/{id}/items/{itemId}/extended-fields body.
/// All 7 fields are nullable strings (NVARCHAR(50) at the DB); blanks
/// from the UI are coerced to null at the controller. The endpoint
/// always overwrites the full set (no partial PATCH) so the request
/// shape matches what an ERP push will eventually send.
/// </summary>
public class PullItemExtendedFieldsUpdateRequest
{
    public string? ProductFamily { get; set; }
    public string? FromSubInventory { get; set; }
    public string? ToSubInventory { get; set; }
    public string? SpecialControl { get; set; }
    public string? TrialId { get; set; }
    public string? Location { get; set; }
    public string? Phase { get; set; }
}
