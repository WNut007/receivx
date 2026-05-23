namespace ReceivingOps.Web.Models.Dtos;

/// <summary>Pull summary for the dashboard card. Merges Pulls row + vw_PullProgress totals + counts.</summary>
public class PullSummary
{
    public Guid Id { get; set; }
    public string PullNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string WarehouseCode { get; set; } = "";
    public string WarehouseName { get; set; } = "";
    public DateTime PullDate { get; set; }
    public string Status { get; set; } = "pending";
    public string? Eta { get; set; }
    public string? Notes { get; set; }                  // mockup uses this as a tag (urgent|late|...)
    public string? CreatedByName { get; set; }
    public DateTime? FirstReceiptAt { get; set; }
    public DateTime? LastActivityAt { get; set; }
    public DateTime? ClosedAt { get; set; }
    public string? ClosedByName { get; set; }
    public bool IsReopened { get; set; }

    public int TotalExpected { get; set; }
    public int TotalReceived { get; set; }
    public int ItemCount { get; set; }
    public int CanceledCount { get; set; }
    public int NewCount { get; set; }
    public int WindowsTotal { get; set; }
    public int WindowsPending { get; set; }

    // §3.5 — per-pull strict-mode flag. Default false = warehouse-wide FIFO.
    // Set at create-time; immutable thereafter (PUT refuses any change).
    public bool LockPoByPull { get; set; }

    // v2.1 Phase 6 — per-pull strict hour-cap flag. Default true = receive rejected
    // (409) when qty would push window.ReceivedQty past window.ExpectedQty. When
    // false, the legacy §7.1 v2 behavior holds — per-hour ExpectedQty is a planning
    // hint and only the PO capacity is a hard cap. Immutable after create (PUT 409).
    public bool LockHourCap { get; set; }
}

public class PullDetail : PullSummary
{
    public List<PullItemDto> Items { get; set; } = new();
}

public class PullItemDto
{
    public Guid Id { get; set; }
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public string? Tag { get; set; }
    public string Status { get; set; } = "normal";
    public string? Remark { get; set; }
    public int SortOrder { get; set; }
    public List<PullItemWindowDto> Windows { get; set; } = new();
}

public class PullItemWindowDto
{
    public byte HourOfDay { get; set; }
    public int ExpectedQty { get; set; }
    public int ReceivedQty { get; set; }
}

/// <summary>Query parameters for /api/pulls.</summary>
public record PullQuery(
    Guid? WarehouseId,
    DateOnly? DateFrom,
    DateOnly? DateTo,
    string? Status,
    string? Q);

/// <summary>
/// Lightweight pull row returned by GET /api/pulls/search — the typeahead
/// that powers the §3.5 linked-pull picker on /Pos's New PO modal. Scoped
/// to the requested warehouse and restricted to open pulls (pending +
/// in_progress) so the picker can never surface a pull that POs are
/// forbidden to link to. Capped at 10 rows by default (max 25).
/// </summary>
public class PullSearchResult
{
    public Guid Id { get; set; }
    public string PullNumber { get; set; } = "";
    public DateTime PullDate { get; set; }
    public string Status { get; set; } = "";
    public bool LockPoByPull { get; set; }
    public int ItemCount { get; set; }
}

/// <summary>POST /api/pulls/{id}/close body (§7.4). SignatureSvg is the base64-encoded canvas image; max 200 KB.</summary>
public class CloseRequest
{
    public string SignatureSvg { get; set; } = "";
}

public class CloseResult
{
    public Guid PullId { get; set; }
    public DateTime ClosedAt { get; set; }
    public int TotalReceived { get; set; }
}

/// <summary>POST /api/pulls/{id}/reopen body (§7.5). Reason is required; max 500 chars after trim.</summary>
public class ReopenRequest
{
    public string Reason { get; set; } = "";
}

public class ReopenResult
{
    public Guid PullId { get; set; }
    public DateTime ReopenedAt { get; set; }
}

// ---------------------------------------------------------------------------
// §3.5 / §7.x admin write surface — POST /api/pulls + PUT /api/pulls/{id}
// ---------------------------------------------------------------------------

/// <summary>POST /api/pulls body. LockPoByPull defaults to false; if set, it's locked in at create and cannot change later.</summary>
public class PullCreateRequest
{
    public string PullNumber { get; set; } = "";       // human-readable business key, UNIQUE
    public Guid WarehouseId { get; set; }
    public DateTime PullDate { get; set; }
    public string? Eta { get; set; }
    public string? Notes { get; set; }
    public bool LockPoByPull { get; set; } = true;     // v2.1 — strict by default; immutable after create (§7.15)
    public bool LockHourCap { get; set; } = true;      // v2.1 Phase 6 — strict by default; immutable after create
}

/// <summary>
/// PUT /api/pulls/{id} body. Edit-only — status transitions go through close/reopen.
/// PullNumber + WarehouseId are intentionally absent (the business key + warehouse scope are immutable).
/// LockPoByPull MUST echo the current value; any mismatch yields 409 (§3.5).
/// </summary>
public class PullUpdateRequest
{
    public DateTime PullDate { get; set; }
    public string? Eta { get; set; }
    public string? Notes { get; set; }
    public bool LockPoByPull { get; set; }             // §3.5 — must echo; mismatch → 409
    public bool LockHourCap { get; set; } = true;      // v2.1 Phase 6 — must echo current value; mismatch → 409
}
