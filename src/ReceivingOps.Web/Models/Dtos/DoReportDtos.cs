using ReceivingOps.Web.Models;

namespace ReceivingOps.Web.Models.Dtos;

/// <summary>
/// Aggregated Delivery Order report data — what both the HTML preview
/// partial and the PDF builder consume. One DO per PO that the pull
/// touched; lines within a DO are aggregated by (ItemCode × PoLineNumber)
/// with SUM(QtyReceived). v2.x Phase 7.4.
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

/// <summary>One Delivery Order = one PO's slice of the pull.</summary>
public class DoOrder
{
    public Guid PoId { get; set; }
    public string PoNumber { get; set; } = "";
    public DateTime OrderDate { get; set; }
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public List<DoLine> Lines { get; set; } = new();
    /// <summary>Sum of TotalQty across lines for this PO.</summary>
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
/// (PO × ItemCode × PoLineNumber). The service groups these by PoId into
/// DoOrder.Lines before serving the DTO.
/// </summary>
public class DoReportRow
{
    public Guid PoId { get; set; }
    public string PoNumber { get; set; } = "";
    public DateTime OrderDate { get; set; }
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public int PoLineNumber { get; set; }
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public int TotalQty { get; set; }

    // ERP-sourced PoLine attributes (MAX() over the aggregation grain).
    public string? PalletId { get; set; }
    public string? OrderId { get; set; }
    public string? InvoiceNo { get; set; }
    public string? KanbanNo { get; set; }
    public string? SubInventory { get; set; }
    public string? ToLocation { get; set; }
    public string? AsnNo { get; set; }
    public string? OrderRound { get; set; }
}
