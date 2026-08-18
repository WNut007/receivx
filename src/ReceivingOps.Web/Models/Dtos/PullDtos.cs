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
    // v2.x — global Role (admin/supervisor/operator) of the user who closed.
    // Null on open pulls + on closed pulls where the closer record was deleted.
    public string? ClosedByRole { get; set; }
    // v2.x — base64 PNG / inline SVG / canvas-encoded signature captured at close
    // time. NVARCHAR(MAX) in DB; only populated when status === 'closed'.
    public string? SignatureSvg { get; set; }
    // v2.x Phase 7.1 — free-text reference (vendor invoice / delivery batch ID).
    // Pull-level; editable post-create. Surfaces on the DO render + Reports list.
    public string? ReferenceNumber { get; set; }

    // db/050 — provenance. NULL for ERP-fed and hand-created pulls (the
    // overwhelming majority); 'po-import' for pulls the WIP synthesis built
    // from an Excel import, because the ERP sends no Receive feed for WIP
    // storer codes. Surfaced in the drawer so a pull carrying a PO nobody in
    // procurement issued explains itself.
    public string? Origin { get; set; }

    public bool IsReopened { get; set; }

    public int TotalExpected { get; set; }
    public int TotalReceived { get; set; }
    public int ItemCount { get; set; }
    public int CanceledCount { get; set; }
    public int NewCount { get; set; }
    public int WindowsTotal { get; set; }
    public int WindowsPending { get; set; }

    // Phase 7c — digital-signature progress (3 fixed parties: Customer /
    // Warehouse / Production). SignedCount is the "N" in the N/3 badge;
    // the per-party bits feed the left-menu chips + the per-role filter.
    // Warehouse is auto-signed at close (7b); Customer/Production via sign.
    public int SignedCount { get; set; }
    public bool CustomerSigned { get; set; }
    public bool WarehouseSigned { get; set; }
    public bool ProductionSigned { get; set; }
    // Computed (get-only → ignored by Dapper, serialized to JSON for the UI).
    public bool IsComplete => SignedCount >= 3;
    public List<string> SignedParties
    {
        get
        {
            var list = new List<string>(3);
            if (CustomerSigned)   list.Add("Customer");
            if (WarehouseSigned)  list.Add("Warehouse");
            if (ProductionSigned) list.Add("Production");
            return list;
        }
    }

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

    // Phase 9.1 — ERP-sourced extended fields. All nullable; editable via the
    // PUT /api/pulls/{id}/items/{itemId}/extended-fields endpoint when ERP
    // hasn't pushed them yet. JSON keys ride the project's camelCase
    // serializer (productFamily, fromSubInventory, ...).
    public string? ProductFamily { get; set; }
    public string? FromSubInventory { get; set; }
    public string? ToSubInventory { get; set; }
    public string? SpecialControl { get; set; }
    public string? TrialId { get; set; }
    public string? Location { get; set; }
    public string? Phase { get; set; }
}

public class PullItemWindowDto
{
    public byte HourOfDay { get; set; }
    public int ExpectedQty { get; set; }
    public int ReceivedQty { get; set; }

    // db/047 — close state. Without IsClosed on the wire the grid cannot tell a
    // short-closed line from a partial still waiting on a delivery: both render
    // "400 / 1,000". ClosedAt/ClosedReason feed the closed-state modal, which has to
    // show what it is offering to undo.
    //
    // ClosedBy is deliberately NOT surfaced: it is a Users.Id GUID that would need a
    // join to render as a name, and the audit row already carries the attribution.
    //
    // Every consumer of this DTO is fed from the two assembly sites in PullRepository
    // (GetByIdAsync's inline loop and AssembleItems), including the three PullItem
    // admin endpoints — ListWindows, AddWindow and UpdateWindow all re-read through
    // GetItemByIdAsync rather than hand-constructing. So populating the source
    // populates them all; none can report a stale IsClosed = false.
    public bool IsClosed { get; set; }
    public DateTime? ClosedAt { get; set; }
    public string? ClosedReason { get; set; }

    // db/049 — structured reason for the accepted variance that closed this window.
    // NULL on open windows, and also on windows closed BEFORE db/049 shipped: that NULL
    // means "closed before reason codes existed" and is its own bucket, never OTHER.
    public string? VarianceReasonCode { get; set; }

    // Display label for the code above, resolved server-side from the one map in
    // VarianceReasonCodes. Sent alongside the code so the client never has to hold a
    // second copy of the labels — and so it can never render a raw code by accident.
    public string? VarianceReasonLabel { get; set; }
}

/// <summary>Query parameters for /api/pulls.</summary>
/// <remarks>
/// Warehouse is expressed as TWO mutually-exclusive, null-guarded Guid filters,
/// both keyed on Pulls.WarehouseId so they hit IX_Pulls_Date's INCLUDE(WarehouseId)
/// with no join to dbo.Warehouses on the hot aggregate path:
///   • <see cref="WarehouseId"/>        — admin's resolved warehouse (null = "All warehouses" ⇒ NO predicate)
///   • <see cref="SessionWarehouseId"/> — non-admin's session warehouse force (null for admins)
/// The controller sets at most one of them.
/// </remarks>
public record PullQuery(
    Guid? WarehouseId,
    Guid? SessionWarehouseId,
    DateOnly? DateFrom,
    DateOnly? DateTo,
    string? Status,
    string? Q,
    bool? LockPoByPull,
    int Page = 1,
    int PageSize = 20);

/// <summary>
/// Dashboard summary tiles + per-status column badges, aggregated over the
/// FULL filtered set (NOT the paged rows). One row from the aggregate query.
/// </summary>
public class PullDashboardAggregates
{
    public int TotalPulls { get; set; }      // COUNT(*) over the filter → "Total Pulls" tile + page Total
    public int Pending { get; set; }         // column badge
    public int InProgress { get; set; }      // "In Progress" tile + column badge
    public int FullyReceived { get; set; }   // "Ready to Close" tile + column badge
    public int Closed { get; set; }          // column badge
    public int ItemsTotal { get; set; }      // Σ (all PullItems per pull, active + canceled) → "Items · Today" tile
    public int ReceivedTotal { get; set; }   // Σ vp.TotalReceived → Throughput units
    public int ExpectedTotal { get; set; }   // Σ vp.TotalExpected → Throughput % denominator
}

/// <summary>Envelope for GET /api/pulls: one page of cards + full-set aggregates.</summary>
public class PullDashboardResponse
{
    public IReadOnlyList<PullSummary> Items { get; set; } = Array.Empty<PullSummary>();
    public int Page { get; set; }
    public int PageSize { get; set; }
    public int Total { get; set; }           // == Aggregates.TotalPulls (same WHERE)
    public bool HasMore => Page * PageSize < Total;
    public PullDashboardAggregates Aggregates { get; set; } = new();
}

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
    public string? ReferenceNumber { get; set; }       // v2.x Phase 7.1 — optional vendor invoice / delivery batch ID
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
    public string? ReferenceNumber { get; set; }       // v2.x Phase 7.1 — editable post-create; vendors revise invoices
}
