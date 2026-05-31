using ReceivingOps.Web.Models;

namespace ReceivingOps.Web.Models.Dtos;

/// <summary>
/// Aggregated Delivery Order report data — what both the HTML preview
/// partial and the PDF builder consume.
///
/// DO identity = (VendorCode × SubInventory × ToLocation × InvoiceNo).
/// One pull may spawn multiple DOs when its receipts span multiple
/// vendors, source sub-inventories, destination locations, or invoices.
/// Lines within a DO carry their own PoNumber (via PoLineRef) so the
/// operator can trace each row back to a purchase order on paper.
///
/// Originally v2.x Phase 7.4 grouped by PO alone; Phase 14 split vendor
/// to a per-line attribute and reshaped the key around movement direction;
/// invoice was added later so two distinct invoices under the same
/// vendor / sub / to-loc tuple split into separate one-page DOs.
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
    /// <summary>Free-text warehouse address (DSV header "Delivery To" block).</summary>
    public string? WarehouseAddress { get; set; }
    /// <summary>
    /// Per-warehouse logo as a data URL ("data:image/png;base64,...").
    /// Null when the pull's warehouse has no logo set; renderers fall
    /// back to the global CompanyInfo branding in that case.
    /// </summary>
    public string? WarehouseLogoDataUrl { get; set; }
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
/// One Delivery Order — identified by the tuple
/// (VendorCode × SubInventory × ToLocation × InvoiceNo). Lines may come
/// from multiple purchase orders; each carries its own PoLineRef so the
/// source PO is preserved at line grain.
/// </summary>
public class DoOrder
{
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    /// <summary>Source sub-inventory (the "from" side of the move).</summary>
    public string? SubInventory { get; set; }
    /// <summary>Destination location (the "to" side of the move).</summary>
    public string? ToLocation { get; set; }
    /// <summary>Vendor invoice number this DO settles against.</summary>
    public string? InvoiceNo { get; set; }
    /// <summary>
    /// Source PO number — denormalized onto the DO header because every
    /// DSV-style delivery note carries a single PO# at the top. DOs in
    /// Receivx may span multiple POs in unusual mixed-vendor / mixed-
    /// invoice arrangements, but the dominant (lowest-numbered) PO is
    /// surfaced here so the header isn't empty. Per-line PO is still
    /// available via DoLine.PoLineRef when needed.
    /// </summary>
    public string? HeaderPoNumber { get; set; }
    /// <summary>
    /// Deterministic per-DO identifier ("Delivery Note No"), derived from
    /// (Pull.Id, DoOrder index within the pull) — 8 hex chars of Pull.Id
    /// + DO letter (A,B,C…). Stable across re-renders, no schema change.
    /// Displayed concatenated with InvoiceNo per Q5a: "{DN}+{InvoiceNo}".
    /// </summary>
    public string DeliveryNoteNo { get; set; } = "";
    /// <summary>
    /// Latest non-reversed receipt timestamp for the lines on this DO.
    /// Sourced via MAX(r.ReceivedAt) WHERE r.ReversedById IS NULL.
    /// Drives the DSV "STORING NOTE — Date Received" field.
    /// </summary>
    public DateTime? LastReceivedAt { get; set; }
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
    /// <summary>
    /// Latest non-reversed receipt timestamp for this row's lines. The
    /// service re-MAXes across lines when populating DoOrder.LastReceivedAt.
    /// </summary>
    public DateTime? LastReceivedAt { get; set; }

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
/// (VendorCode × SubInventory × ToLocation × InvoiceNo × PO × ItemCode × PoLineNumber).
/// The service groups these by the (Vendor, SubInventory, ToLocation,
/// InvoiceNo) tuple into DoOrders; each row contributes one DoLine that
/// carries its own PoNumber + PoLineNumber for the PoLineRef display.
/// </summary>
public class DoReportRow
{
    // Grouping keys — DO identity = (VendorCode, SubInventory, ToLocation, InvoiceNo).
    // VendorName tags along under (VendorCode, VendorName) to surface the
    // display name without a second lookup.
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public string? SubInventory { get; set; }
    public string? ToLocation { get; set; }
    public string? InvoiceNo { get; set; }

    // Per-line context — PoNumber is kept so PoLineRef can identify the
    // source PO on each line even when a DO spans multiple POs.
    public Guid PoId { get; set; }
    public string PoNumber { get; set; } = "";
    public int PoLineNumber { get; set; }
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public int TotalQty { get; set; }
    /// <summary>
    /// Latest non-reversed receipt timestamp for this row. MAX'd in SQL;
    /// service re-MAXes across rows when computing DoOrder.LastReceivedAt.
    /// </summary>
    public DateTime? LastReceivedAt { get; set; }

    // Remaining ERP-sourced PoLine attributes (MAX() over the aggregation
    // grain — invariant per (PoId, LineNumber) so MAX is exact).
    public string? PalletId { get; set; }
    public string? OrderId { get; set; }
    public string? KanbanNo { get; set; }
    public string? AsnNo { get; set; }
    public string? OrderRound { get; set; }
}
