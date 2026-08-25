namespace ReceivingOps.Web.Models.Dtos;

/// <summary>
/// What to put in a pull-sheet workbook. The one input to
/// <c>IPullSheetExportService</c>, so the report path and the per-pull path
/// differ only in how they fill this in — never in how the workbook is built.
///
/// Two mutually exclusive modes:
///   * period mode — Warehouse + Date + Period (+ optional Status), the
///     Reports → Pull Sheets surface.
///   * single-pull mode — <see cref="PullId"/> set, everything else ignored,
///     the Receiving Console's Export button. All 24 hours, one pull.
/// </summary>
public sealed class PullSheetCriteria
{
    /// <summary>Single-pull mode when set; period mode when null.</summary>
    public Guid? PullId { get; set; }

    public Guid? WarehouseId { get; set; }

    /// <summary>Date D. In period mode Night also reads D+1; see the repository.</summary>
    public DateOnly Date { get; set; }

    /// <summary>Key from <c>ReceivingPeriods</c>. Null in single-pull mode.</summary>
    public string? PeriodKey { get; set; }

    /// <summary>
    /// Optional Pulls.Status filter. Null/empty = every status, OPEN INCLUDED —
    /// which is the point of this report and the one way it differs hardest
    /// from the Delivery Orders section next to it.
    /// </summary>
    public string? Status { get; set; }

    /// <summary>Display name stamped on the Header sheet.</summary>
    public string ExportedBy { get; set; } = "";
}

/// <summary>A generated workbook plus the name to serve it under.</summary>
public sealed record PullSheetWorkbook(byte[] Content, string FileName);

/// <summary>Detail grain — one row per (pull, item, window).</summary>
public sealed class PullSheetDetailRow
{
    public string PullNumber { get; set; } = "";
    public string WarehouseCode { get; set; } = "";
    public string WarehouseName { get; set; } = "";
    /// <summary>DATE column. DateTime to match every other pull DTO in the project.</summary>
    public DateTime PullDate { get; set; }
    public string PullStatus { get; set; } = "";
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public string? Tag { get; set; }
    public string RowStatus { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }

    /// <summary>
    /// ERP-sourced, from <c>dbo.PurchaseOrderLines.Building</c> (db/021), read-only
    /// here -- Receivx has no write path for it and this report does not add one.
    ///
    /// <para>Resolved by the repository OUTER APPLY, already collapsed across every
    /// PO line the item reaches: a single agreed value, <c>*mixed*</c> when they
    /// disagree, or NULL when nothing matched. NULL renders as an em-dash on screen
    /// and as an empty cell in the workbook, like every other unset ERP field in
    /// this codebase.</para>
    /// </summary>
    public string? Building { get; set; }

    public string? Remark { get; set; }
    public int HourOfDay { get; set; }
    public int ExpectedQty { get; set; }
    public int ReceivedQty { get; set; }
    public bool IsClosed { get; set; }

    /// <summary>
    /// Nothing scheduled is nothing owed; a closed window is written off; a
    /// filled window is done. Mirrors isSettled() in receiving.js.
    /// </summary>
    public bool IsSettled => ExpectedQty <= 0 || IsClosed || ReceivedQty >= ExpectedQty;

    /// <summary>
    /// Units still genuinely expected — ZERO for a settled window whatever the
    /// arithmetic says. A short close writes the shortfall off, it does not
    /// leave it owed, and reporting it as outstanding would overstate the work
    /// still coming on every sheet containing a written-off line.
    ///
    /// This is the same rule as slotOutstanding() in receiving.js, so the
    /// exported figure and the figure on the receiving grid agree.
    /// </summary>
    public int Outstanding => IsSettled ? 0 : Math.Max(0, ExpectedQty - ReceivedQty);

    /// <summary>Fraction 0.0-1.0. Written under an Excel percent format, never pre-multiplied.</summary>
    public double Progress => ExpectedQty > 0 ? (double)ReceivedQty / ExpectedQty : 0d;

    /// <summary>
    /// Mirrors the receiving grid's cell states, and the wording the single-pull
    /// export has always used. "Closed short" is deliberately not "Partial": a
    /// written-off window is settled, and calling it partial tells the reader a
    /// delivery is still coming when it is not.
    /// </summary>
    public string CellStatus =>
        RowStatus.Equals("canceled", StringComparison.OrdinalIgnoreCase) ? "Canceled"
        : ReceivedQty >= ExpectedQty ? "Complete"
        : IsClosed ? "Closed short"
        : ReceivedQty > 0 ? "Partial"
        : "Pending";
}

/// <summary>
/// Summary grain — one row per (pull, item), aggregating ONLY that item's
/// windows inside the selected period. Stays pull-grained on purpose: the same
/// item code on two pulls is two rows, so every figure traces back to a pull.
/// Cross-pull totals live on the Grand Total sheet instead.
/// </summary>
public sealed class PullSheetSummaryRow
{
    public string PullNumber { get; set; } = "";
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public string? Tag { get; set; }
    public string RowStatus { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }

    /// <summary>
    /// Collapsed within THIS pull item -- see <see cref="PullSheetDetailRow.Building"/>.
    /// Every window of one pull item resolves through the same key, so the value is
    /// taken from the group rather than re-collapsed here.
    /// </summary>
    public string? Building { get; set; }

    public int ExpectedQty { get; set; }
    public int ReceivedQty { get; set; }
    public int Windows { get; set; }
    public int SettledWindows { get; set; }

    /// <summary>
    /// SUM of the windows' own Outstanding, not ExpectedQty - ReceivedQty.
    /// Re-deriving it from the totals would resurrect the shortfall of every
    /// window that was closed short, because that write-off is only visible per
    /// window. Set by the service from the detail rows.
    /// </summary>
    public int Outstanding { get; set; }

    public double Progress => ExpectedQty > 0 ? (double)ReceivedQty / ExpectedQty : 0d;

    public string ItemStatus =>
        RowStatus.Equals("canceled", StringComparison.OrdinalIgnoreCase) ? "Canceled"
        : ExpectedQty == 0 ? "No schedule"
        : ReceivedQty >= ExpectedQty ? "Fully received"
        : SettledWindows == Windows ? "Closed short"
        : ReceivedQty > 0 ? "Outstanding"
        : "Pending";
}

/// <summary>Grand Total grain — one row per item code across every pull in the period.</summary>
public sealed class PullSheetGrandTotalRow
{
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public string? VendorName { get; set; }

    /// <summary>
    /// Collapsed across the WHOLE PERIOD, not within one pull. An item received
    /// into two buildings in the same period reads <c>*mixed*</c> here while the
    /// per-pull Summary rows still show their own distinct values -- Summary stays
    /// traceable, Grand Total stays honest.
    /// </summary>
    public string? Building { get; set; }

    public int ExpectedQty { get; set; }
    public int ReceivedQty { get; set; }

    /// <summary>SUM of the windows' own Outstanding — see PullSheetSummaryRow.Outstanding.</summary>
    public int Outstanding { get; set; }

    public double Progress => ExpectedQty > 0 ? (double)ReceivedQty / ExpectedQty : 0d;
}

/// <summary>
/// Everything one criteria resolves to. Preview and export are rendered from
/// the SAME instance of this — a preview that disagreed with the file it
/// promises would be worse than showing no preview at all.
/// </summary>
public sealed class PullSheetResult
{
    public List<PullSheetDetailRow> Detail { get; set; } = new();
    public List<PullSheetSummaryRow> Summary { get; set; } = new();
    public List<PullSheetGrandTotalRow> GrandTotal { get; set; } = new();

    /// <summary>Distinct pull numbers included, in display order.</summary>
    public List<string> PullNumbers { get; set; } = new();

    public string WarehouseCode { get; set; } = "";
    public string WarehouseName { get; set; } = "";
    public string PeriodLabel { get; set; } = "";
    public string PeriodHours { get; set; } = "";
    public string PeriodDateRange { get; set; } = "";
    public DateOnly Date { get; set; }

    public int ActiveItems { get; set; }
    public int CanceledItems { get; set; }
    public int NewItems { get; set; }

    public int TotalExpected => Detail.Sum(r => r.ExpectedQty);
    public int TotalReceived => Detail.Sum(r => r.ReceivedQty);
    public int PullCount => PullNumbers.Count;
}

/// <summary>What the Reports page renders above the export button.</summary>
public sealed class PullSheetPreviewResponse
{
    public int PullCount { get; set; }
    public int ItemCount { get; set; }
    public int TotalExpected { get; set; }
    public int TotalReceived { get; set; }
    public int DetailRowCount { get; set; }
    public int SummaryRowCount { get; set; }

    /// <summary>First page of Summary rows; <see cref="SummaryRowCount"/> is the true total.</summary>
    public List<PullSheetPreviewRow> SummaryPreview { get; set; } = new();

    public string PeriodLabel { get; set; } = "";
    public string PeriodHours { get; set; } = "";
    public string PeriodDateRange { get; set; } = "";
    public List<string> PullNumbers { get; set; } = new();

    /// <summary>True when the export would be refused for size; Message says why.</summary>
    public bool ExceedsRowLimit { get; set; }
    public string? Message { get; set; }
}

/// <summary>One preview table row — the Summary columns worth showing on screen.</summary>
public sealed class PullSheetPreviewRow
{
    public string PullNumber { get; set; } = "";
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public string? VendorName { get; set; }

    /// <summary>Null renders as an em-dash in the preview table -- see the Summary row.</summary>
    public string? Building { get; set; }

    public int ExpectedQty { get; set; }
    public int ReceivedQty { get; set; }
    public int Outstanding { get; set; }
    public double Progress { get; set; }
    public string ItemStatus { get; set; } = "";
}
