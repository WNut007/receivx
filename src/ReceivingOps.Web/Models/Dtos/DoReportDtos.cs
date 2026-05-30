using ReceivingOps.Web.Models;

namespace ReceivingOps.Web.Models.Dtos;

/// <summary>
/// Aggregated Delivery Order report data — what both the HTML preview
/// partial and the PDF builder consume.
///
/// Phase 14: a DO is now identified by the triple
/// (VendorCode × SubInventory × ToLocation). One pull may spawn multiple
/// DOs when its receipts span multiple vendors, source sub-inventories,
/// or destination locations. Lines within a DO carry their own PoNumber
/// (via PoLineRef) so the operator can trace each row back to a
/// purchase order on paper.
///
/// Originally v2.x Phase 7.4 grouped by PO alone; the Phase 14 schema
/// move (vendor → POL) made that grouping wrong for mixed-vendor POs.
/// </summary>
public class DoReportData
{
    public DoPullHeader Pull   { get; set; } = new();
    public List<DoOrder> Orders { get; set; } = new();
    public CompanyInfo Company { get; set; } = new();
}

public class DoPullHeader
{
    public Guid Id { get; set; }
    public string PullNumber { get; set; } = "";
    public DateTime PullDate { get; set; }
    public string? ReferenceNumber { get; set; }
    public string WarehouseCode { get; set; } = "";
    public string WarehouseName { get; set; } = "";
    public DateTime? ClosedAt { get; set; }
    public string? ClosedByName { get; set; }
    public string? ClosedByRole { get; set; }
    /// <summary>
    /// Inline &lt;svg&gt; markup or data: URL (matches Pulls.SignatureSvg shape
    /// — same field the dashboard drawer renders). The DO footer's
    /// "AUTHORIZED BY" block draws it on a white-card surface so dark
    /// strokes stay legible across the midnight/slate themes.
    /// </summary>
    public string? SignatureSvg { get; set; }
    /// <summary>Net delivered qty across every DO/line. Drives the toolbar caption.</summary>
    public int TotalQty { get; set; }
}

/// <summary>
/// One Delivery Order — Phase 14: identified by the triple
/// (VendorCode × SubInventory × ToLocation). Lines may come from multiple
/// purchase orders; each carries its own PoLineRef so the source PO is
/// preserved at line grain.
/// </summary>
public class DoOrder
{
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    /// <summary>Source sub-inventory (the "from" side of the move).</summary>
    public string? SubInventory { get; set; }
    /// <summary>Destination location (the "to" side of the move).</summary>
    public string? ToLocation { get; set; }
    public List<DoLine> Lines { get; set; } = new();
    /// <summary>Sum of TotalQty across lines for this DO.</summary>
    public int TotalQty { get; set; }
}

/// <summary>One row on a Delivery Order — aggregated by (ItemCode × PoLineNumber).</summary>
public class DoLine
{
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public int PoLineNumber { get; set; }
    /// <summary>Display label e.g. "PO-0001XX·L2".</summary>
    public string PoLineRef { get; set; } = "";
    /// <summary>Net qty after aggregating across hours + reversals.</summary>
    public int TotalQty { get; set; }

    // ERP-sourced PoLine attributes surfaced on the DO at line grain.
    // Sourced via MAX(pol.X) in GetDoReportRowsAsync — invariant per
    // (PoId, LineNumber) so the aggregation is exact, not lossy.
    public string? PalletId { get; set; }
    public string? OrderId { get; set; }
    public string? InvoiceNo { get; set; }
    public string? KanbanNo { get; set; }
    public string? SubInventory { get; set; }
    public string? ToLocation { get; set; }
    public string? AsnNo { get; set; }
    public string? OrderRound { get; set; }
}

/// <summary>
/// Flat row returned by the aggregation query — one per
/// (VendorCode × SubInventory × ToLocation × PO × ItemCode × PoLineNumber).
/// The service groups these by (VendorCode, SubInventory, ToLocation) into
/// DoOrders, with each row contributing one DoLine that carries its own
/// PoNumber + PoLineNumber for the PoLineRef display.
/// </summary>
public class DoReportRow
{
    // Grouping keys (Phase 14 — DO identity = this triple).
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public string? SubInventory { get; set; }
    public string? ToLocation { get; set; }

    // Per-line context — PoNumber is kept so PoLineRef can identify the
    // source PO on each line even when a DO spans multiple POs.
    public Guid PoId { get; set; }
    public string PoNumber { get; set; } = "";
    public int PoLineNumber { get; set; }
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public int TotalQty { get; set; }

    // Remaining ERP-sourced PoLine attributes (MAX() over the aggregation
    // grain — invariant per (PoId, LineNumber) so MAX is exact).
    public string? PalletId { get; set; }
    public string? OrderId { get; set; }
    public string? InvoiceNo { get; set; }
    public string? KanbanNo { get; set; }
    public string? AsnNo { get; set; }
    public string? OrderRound { get; set; }
}
