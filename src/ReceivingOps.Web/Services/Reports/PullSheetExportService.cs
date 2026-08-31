using ClosedXML.Excel;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services.Reports;

/// <summary>
/// Query + workbook builder behind Reports → Pull Sheets and the per-pull
/// Export button. See <see cref="IPullSheetExportService"/> for the contract.
/// </summary>
public class PullSheetExportService : IPullSheetExportService
{
    private readonly IPullSheetReportRepository _repo;

    public PullSheetExportService(IPullSheetReportRepository repo) => _repo = repo;

    // ---- Formats -----------------------------------------------------------
    // Progress is stored as a FRACTION under this format, never as an integer
    // under General. "50" in a General cell reads as either 50% or 50 units
    // depending on who opens it; 0.5 under "0.0%" cannot be misread, and it
    // averages and charts correctly downstream.
    private const string PercentFormat = "0.0%";
    private const string QtyFormat = "#,##0";
    private const string DateFormat = "yyyy-mm-dd";

    // ======================================================================
    // Query
    // ======================================================================

    public async Task<PullSheetResult> QueryAsync(
        PullSheetCriteria criteria, CancellationToken ct = default)
    {
        var detail = await _repo.GetDetailRowsAsync(criteria, ct);

        var result = new PullSheetResult
        {
            Detail = detail,
            Date = criteria.Date,
        };

        // ---- Criteria description -----------------------------------------
        if (criteria.PullId is null)
        {
            var period = ReceivingPeriods.ByKey(criteria.PeriodKey)
                ?? throw new ArgumentException(
                    $"Unknown period '{criteria.PeriodKey}'.", nameof(criteria));

            result.PeriodLabel = period.Label;
            result.PeriodHours = string.Join(", ",
                period.Hours.Select(h => $"{h:00}:00"));

            // Spelled out rather than implied: on a Night export the reader is
            // looking at two calendar dates, and the Header sheet is the only
            // place that says so.
            var segments = PullSheetReportRepository.BuildDateSegments(period, criteria.Date);
            result.PeriodDateRange = string.Join("  +  ", segments.Select(s =>
                $"{s.Date:yyyy-MM-dd} h{string.Join("/", s.Hours.Select(h => h.ToString("00")))}"));
        }
        else
        {
            result.PeriodLabel = "All day";
            result.PeriodHours = "00:00-23:00";
            result.PeriodDateRange = detail.Count > 0
                ? $"{detail[0].PullDate:yyyy-MM-dd}"
                : criteria.Date.ToString("yyyy-MM-dd");
        }

        // Warehouse identity comes off the rows so it is what the data says,
        // not what the filter asked for. Mixed only when no warehouse filter
        // was applied and pulls from several warehouses landed in range.
        var warehouses = detail.Select(r => r.WarehouseCode).Distinct().ToList();
        result.WarehouseCode = warehouses.Count == 1 ? warehouses[0]
            : warehouses.Count == 0 ? "" : "(multiple)";
        var whNames = detail.Select(r => r.WarehouseName).Distinct().ToList();
        result.WarehouseName = whNames.Count == 1 ? whNames[0] : "";

        result.PullNumbers = detail.Select(r => r.PullNumber).Distinct()
            .OrderBy(n => n, StringComparer.Ordinal).ToList();

        // ---- Item counts ----------------------------------------------------
        // Distinct (pull, item) inside the period — an item scheduled twice in
        // the same period is one item, and the same code on two pulls is two.
        var itemKeys = detail
            .Select(r => (r.PullNumber, r.ItemCode, r.RowStatus))
            .Distinct().ToList();
        result.ActiveItems = itemKeys.Count(k =>
            !k.RowStatus.Equals("canceled", StringComparison.OrdinalIgnoreCase));
        result.CanceledItems = itemKeys.Count(k =>
            k.RowStatus.Equals("canceled", StringComparison.OrdinalIgnoreCase));
        result.NewItems = itemKeys.Count(k =>
            k.RowStatus.Equals("new", StringComparison.OrdinalIgnoreCase));

        result.Summary = BuildSummary(detail);
        result.GrandTotal = BuildGrandTotal(detail);
        return result;
    }

    /// <summary>
    /// One row per (pull, item), summing ONLY the windows already filtered into
    /// <paramref name="detail"/> — that is, only those inside the period.
    ///
    /// This is where this report goes silently wrong if it is written the
    /// obvious way. An item with windows at 09:00 and 15:00 must show its
    /// 09:00 quantity in Morning, not its pull total. Because the totals come
    /// off the period-filtered detail rows and never re-read the item, that
    /// cannot happen here.
    /// </summary>
    private static List<PullSheetSummaryRow> BuildSummary(List<PullSheetDetailRow> detail) =>
        detail
            .GroupBy(r => (r.PullNumber, r.ItemCode, r.VendorCode))
            .Select(g =>
            {
                var first = g.First();
                return new PullSheetSummaryRow
                {
                    PullNumber = first.PullNumber,
                    ItemCode = first.ItemCode,
                    Description = first.Description,
                    Tag = first.Tag,
                    RowStatus = first.RowStatus,
                    VendorCode = first.VendorCode,
                    // Both already collapsed per pull item by the repository --
                    // vendor warehouse-wide, building against the pull's own PO --
                    // and the group key is that same item, so every row here carries
                    // the same value. Taking the first is reading it, not choosing.
                    VendorName = first.VendorName,
                    Building = first.Building,
                    ExpectedQty = g.Sum(r => r.ExpectedQty),
                    ReceivedQty = g.Sum(r => r.ReceivedQty),
                    // Summed per window, so a closed-short window contributes 0
                    // rather than its written-off shortfall.
                    Outstanding = g.Sum(r => r.Outstanding),
                    Windows = g.Count(),
                    SettledWindows = g.Count(r => r.IsSettled),
                };
            })
            .OrderBy(r => r.PullNumber, StringComparer.Ordinal)
            .ThenBy(r => r.ItemCode, StringComparer.Ordinal)
            .ToList();

    /// <summary>
    /// One row per item code across every pull in the period. The only place
    /// cross-pull addition happens, which is what lets Summary stay traceable.
    /// </summary>
    private static List<PullSheetGrandTotalRow> BuildGrandTotal(List<PullSheetDetailRow> detail) =>
        detail
            // Cancelled lines count for nothing, so they are excluded here
            // BEFORE grouping. This sheet has no status column -- unlike Summary,
            // whose rows carry RowStatus and render as "Canceled" -- so a
            // cancelled line's quantity merged into an item's cross-pull total
            // with nothing on the row to say it was there. Measured on production
            // 2026-08-31: 2,633 cancelled items carrying ~2.58M expected units
            // were eligible to inflate this sheet.
            //
            // Filtered here rather than in the repository on purpose: Summary and
            // Detail both need the cancelled rows in order to show them as
            // cancelled, and only this aggregation must drop them.
            .Where(r => !r.RowStatus.Equals("canceled", StringComparison.OrdinalIgnoreCase))
            .GroupBy(r => r.ItemCode, StringComparer.Ordinal)
            .Select(g => new PullSheetGrandTotalRow
            {
                ItemCode = g.Key,
                // Longest description wins: NBSP-padded variants of the same
                // code exist in the data, and the trimmed short one carries no
                // less meaning than the padded long one.
                Description = g.Select(r => r.Description ?? "")
                               .OrderByDescending(d => d.Trim().Length).First(),
                // Both of these are collapsed a SECOND time, now ACROSS pulls.
                // The repository collapsed within each pull item; this group spans
                // every pull in the period, so an item delivered to B2 on one pull
                // and B4 on another reads *mixed* here while both Summary rows keep
                // their own value. Summary stays traceable, Grand Total stays honest.
                //
                // Vendor used to take the first non-blank instead, which named one
                // supplier for a dual-sourced part as though it were the only one:
                // 18 of 128 item codes in Evening 2026-08-25 reach more than one
                // vendor. Picking one of two real vendors is a wrong answer, not a
                // partial one -- the same argument that has always governed Building.
                VendorName = CollapseText(g.Select(r => r.VendorName)),
                Building   = CollapseText(g.Select(r => r.Building)),
                ExpectedQty = g.Sum(r => r.ExpectedQty),
                ReceivedQty = g.Sum(r => r.ReceivedQty),
                Outstanding = g.Sum(r => r.Outstanding),
            })
            .OrderBy(r => r.ItemCode, StringComparer.Ordinal)
            .ToList();

    // ======================================================================
    // Workbook
    // ======================================================================

    public PullSheetWorkbook Build(PullSheetResult result, PullSheetCriteria criteria)
    {
        using var wb = new XLWorkbook();

        BuildHeaderSheet(wb, result, criteria);
        BuildSummarySheet(wb, result);
        BuildDetailSheet(wb, result);
        BuildGrandTotalSheet(wb, result);

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return new PullSheetWorkbook(ms.ToArray(), BuildFileName(result, criteria));
    }

    /// <summary>
    /// "{warehouse}_{date}_{period}.xlsx" — e.g. WH-BPI_2026-08-20_Night.xlsx.
    /// Single-pull exports keep the shape the button has always produced,
    /// "{pull}_{date}.xlsx", so saved links and folder sorts do not break.
    /// </summary>
    private static string BuildFileName(PullSheetResult result, PullSheetCriteria criteria)
    {
        if (criteria.PullId is not null)
        {
            var pull = result.PullNumbers.FirstOrDefault() ?? "pull";
            return $"{Sanitize(pull)}_{result.Date:yyyy-MM-dd}.xlsx";
        }

        var wh = string.IsNullOrWhiteSpace(result.WarehouseCode) ? "all" : result.WarehouseCode;
        return $"{Sanitize(wh)}_{criteria.Date:yyyy-MM-dd}_{Sanitize(result.PeriodLabel)}.xlsx";
    }

    private static string Sanitize(string s)
    {
        var cleaned = new string(Normalize(s)
            .Select(c => Path.GetInvalidFileNameChars().Contains(c) || c == ' ' ? '-' : c)
            .ToArray());
        return string.IsNullOrWhiteSpace(cleaned) ? "export" : cleaned;
    }

    // ---- Sheet 1: Header ---------------------------------------------------

    private static void BuildHeaderSheet(
        XLWorkbook wb, PullSheetResult result, PullSheetCriteria criteria)
    {
        var ws = wb.Worksheets.Add("Header");

        // No longer a single pull, so this is a criteria block rather than a
        // pull identity block: what was asked for, what it resolved to, and
        // which pulls came back.
        var rows = new List<(string Field, object? Value)>
        {
            ("Warehouse",       Describe(result.WarehouseCode, result.WarehouseName)),
            ("Date",            criteria.Date.ToString("yyyy-MM-dd")),
            ("Period",          result.PeriodLabel),
            ("Period Hours",    result.PeriodHours),
            ("Period Date Range", result.PeriodDateRange),
            ("Status Filter",   string.IsNullOrWhiteSpace(criteria.Status) ? "All statuses (open included)" : criteria.Status),
            ("Pulls Included",  string.Join(", ", result.PullNumbers)),
            ("Pull Count",      result.PullCount),
            ("Active Items",    result.ActiveItems),
            ("Canceled Items",  result.CanceledItems),
            ("New Items",       result.NewItems),
            ("Total Expected",  result.TotalExpected),
            ("Total Received",  result.TotalReceived),
            ("Detail Rows",     result.Detail.Count),
            ("Exported By",     criteria.ExportedBy),
            ("Exported At",     DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")),
        };

        ws.Cell(1, 1).Value = "Field";
        ws.Cell(1, 2).Value = "Value";

        for (var i = 0; i < rows.Count; i++)
        {
            var r = i + 2;
            ws.Cell(r, 1).Value = rows[i].Field;
            var cell = ws.Cell(r, 2);
            if (rows[i].Value is int n)
            {
                cell.Value = n;
                cell.Style.NumberFormat.Format = QtyFormat;
            }
            else
            {
                SetText(cell, rows[i].Value?.ToString());
            }
        }

        ws.Column(1).Width = 22;
        ws.Column(2).Width = 60;
        // Pulls Included can be a long comma list; wrapping keeps it readable
        // instead of running under the edge of the sheet.
        ws.Column(2).Style.Alignment.WrapText = true;
        FinishSheet(ws, rows.Count + 1, 2);
    }

    private static string Describe(string code, string name) =>
        string.IsNullOrWhiteSpace(name) ? code : $"{code} · {name}";

    // ---- Sheet 2: Summary --------------------------------------------------

    private static void BuildSummarySheet(XLWorkbook wb, PullSheetResult result)
    {
        var ws = wb.Worksheets.Add("Summary");

        string[] headers =
        {
            "Pull #", "Period", "Item Code", "Description", "Type", "Row Status",
            "Vendor Code", "Vendor Name", "Building", "Total Expected", "Total Received",
            "Total Outstanding", "Progress %", "Windows", "Item Status",
        };
        WriteHeaders(ws, headers);

        var r = 2;
        foreach (var row in result.Summary)
        {
            var c = 1;
            SetText(ws.Cell(r, c++), row.PullNumber);
            SetText(ws.Cell(r, c++), result.PeriodLabel);
            SetText(ws.Cell(r, c++), row.ItemCode);
            SetText(ws.Cell(r, c++), row.Description);
            SetText(ws.Cell(r, c++), FormatTag(row.Tag));
            SetText(ws.Cell(r, c++), Title(row.RowStatus));
            SetText(ws.Cell(r, c++), row.VendorCode);
            SetText(ws.Cell(r, c++), row.VendorName);
            SetText(ws.Cell(r, c++), row.Building);
            SetQty(ws.Cell(r, c++), row.ExpectedQty);
            SetQty(ws.Cell(r, c++), row.ReceivedQty);
            SetQty(ws.Cell(r, c++), row.Outstanding);
            SetPercent(ws.Cell(r, c++), row.Progress);
            SetQty(ws.Cell(r, c++), row.Windows);
            SetText(ws.Cell(r, c++), row.ItemStatus);
            r++;
        }

        SetWidths(ws, 12, 11, 18, 34, 8, 11, 14, 24, 14, 15, 15, 17, 11, 9, 15);
        FinishSheet(ws, Math.Max(1, r - 1), headers.Length);
    }

    // ---- Sheet 3: Detail ---------------------------------------------------

    private static void BuildDetailSheet(XLWorkbook wb, PullSheetResult result)
    {
        var ws = wb.Worksheets.Add("Detail");

        string[] headers =
        {
            "Pull #", "Period", "Pull Date", "Warehouse", "Item Code", "Description",
            "Type", "Row Status", "Vendor Code", "Vendor Name", "Building", "Remark",
            "Hour", "Expected", "Received", "Outstanding", "Progress %", "Cell Status",
        };
        WriteHeaders(ws, headers);

        var r = 2;
        foreach (var row in result.Detail)
        {
            var c = 1;
            SetText(ws.Cell(r, c++), row.PullNumber);
            SetText(ws.Cell(r, c++), result.PeriodLabel);
            // Real date, not text — a Night export spans two of them and the
            // reader needs to be able to sort and filter on the column.
            var dateCell = ws.Cell(r, c++);
            dateCell.Value = row.PullDate.Date;
            dateCell.Style.NumberFormat.Format = DateFormat;
            SetText(ws.Cell(r, c++), row.WarehouseCode);
            SetText(ws.Cell(r, c++), row.ItemCode);
            SetText(ws.Cell(r, c++), row.Description);
            SetText(ws.Cell(r, c++), FormatTag(row.Tag));
            SetText(ws.Cell(r, c++), Title(row.RowStatus));
            SetText(ws.Cell(r, c++), row.VendorCode);
            SetText(ws.Cell(r, c++), row.VendorName);
            SetText(ws.Cell(r, c++), row.Building);
            SetText(ws.Cell(r, c++), row.Remark);
            SetText(ws.Cell(r, c++), $"{row.HourOfDay:00}:00");
            SetQty(ws.Cell(r, c++), row.ExpectedQty);
            SetQty(ws.Cell(r, c++), row.ReceivedQty);
            SetQty(ws.Cell(r, c++), row.Outstanding);
            SetPercent(ws.Cell(r, c++), row.Progress);
            SetText(ws.Cell(r, c++), row.CellStatus);
            r++;
        }

        SetWidths(ws, 12, 11, 12, 11, 18, 34, 8, 11, 14, 24, 14, 22, 8, 11, 11, 13, 11, 13);
        FinishSheet(ws, Math.Max(1, r - 1), headers.Length);
    }

    // ---- Sheet 4: Grand Total ----------------------------------------------

    private static void BuildGrandTotalSheet(XLWorkbook wb, PullSheetResult result)
    {
        var ws = wb.Worksheets.Add("Grand Total");

        string[] headers =
        {
            "Item Code", "Description", "Vendor", "Building", "Expected", "Received",
            "Outstanding", "Progress %",
        };
        WriteHeaders(ws, headers);

        var r = 2;
        foreach (var row in result.GrandTotal)
        {
            var c = 1;
            SetText(ws.Cell(r, c++), row.ItemCode);
            SetText(ws.Cell(r, c++), row.Description);
            SetText(ws.Cell(r, c++), row.VendorName);
            SetText(ws.Cell(r, c++), row.Building);
            SetQty(ws.Cell(r, c++), row.ExpectedQty);
            SetQty(ws.Cell(r, c++), row.ReceivedQty);
            SetQty(ws.Cell(r, c++), row.Outstanding);
            SetPercent(ws.Cell(r, c++), row.Progress);
            r++;
        }

        SetWidths(ws, 18, 34, 24, 14, 13, 13, 13, 11);
        FinishSheet(ws, Math.Max(1, r - 1), headers.Length);
    }

    // ======================================================================
    // Cell + sheet helpers
    // ======================================================================

    private static void WriteHeaders(IXLWorksheet ws, string[] headers)
    {
        for (var i = 0; i < headers.Length; i++)
            ws.Cell(1, i + 1).Value = headers[i];
    }

    /// <summary>
    /// Bold header row, frozen top row, autofilter across the used range.
    /// Multi-pull output runs to thousands of rows where the single-pull output
    /// ran to dozens, so scrolling the header off screen stopped being harmless.
    /// </summary>
    private static void FinishSheet(IXLWorksheet ws, int lastRow, int lastCol)
    {
        var header = ws.Range(1, 1, 1, lastCol);
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = XLColor.FromHtml("#EFEFEF");
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

        ws.SheetView.FreezeRows(1);
        ws.Range(1, 1, Math.Max(1, lastRow), lastCol).SetAutoFilter();
    }

    private static void SetWidths(IXLWorksheet ws, params double[] widths)
    {
        for (var i = 0; i < widths.Length; i++)
            ws.Column(i + 1).Width = widths[i];
    }

    private static void SetQty(IXLCell cell, int value)
    {
        cell.Value = value;
        cell.Style.NumberFormat.Format = QtyFormat;
    }

    /// <summary>Stores the FRACTION and lets Excel render the percent.</summary>
    private static void SetPercent(IXLCell cell, double fraction)
    {
        cell.Value = fraction;
        cell.Style.NumberFormat.Format = PercentFormat;
    }

    /// <summary>Every string cell in the workbook goes through here.</summary>
    private static void SetText(IXLCell cell, string? value)
    {
        var normalized = Normalize(value);
        if (normalized.Length == 0) cell.Value = string.Empty;
        else cell.SetValue(normalized);
    }

    /// <summary>
    /// Non-breaking space (U+00A0) to a plain space, then trim.
    ///
    /// The ERP feed carries NBSP inside vendor names ("NHK<U+00A0>SPRING") and as
    /// trailing padding on item descriptions. Both look identical to a space on
    /// screen and neither matches one in a VLOOKUP, so a downstream sheet keyed
    /// on these values silently returns #N/A. Measured on production
    /// 2026-08-21: 304 PurchaseOrderLines.VendorName rows and 104
    /// PullItems.Description rows carry one.
    ///
    /// Trimming is part of the fix, not tidiness: converting the trailing NBSP
    /// on "2059-800074-R1A<U+00A0><U+00A0>" to spaces leaves a trailing-space value
    /// that still fails to match "2059-800074-R1A".
    /// </summary>
    /// <summary>U+00A0. Written as an escape so no editor or filter can normalise
    /// the fix away into an ordinary space without the change being visible.</summary>
    private const char Nbsp = '\u00A0';

    internal static string Normalize(string? value) =>
        string.IsNullOrEmpty(value)
            ? string.Empty
            : value.Replace(Nbsp, ' ').Trim();

    /// <summary>
    /// The MIN = MAX collapse in C#, for the second pass Grand Total needs.
    ///
    /// <para>Same three outcomes as the repository OUTER APPLY, and deliberately
    /// the same marker string: one agreed value wins; disagreement is
    /// <c>*mixed*</c>; nothing to say is null, which writes an empty cell. A row
    /// already carrying <c>*mixed*</c> from the per-item collapse propagates,
    /// because a group containing an ambiguous member is itself ambiguous.</para>
    ///
    /// <para>Case-insensitive, matching the database collation the first pass ran
    /// under — comparing Ordinal here would call "B4" and "b4" a disagreement
    /// that SQL had already resolved.</para>
    /// </summary>
    internal static string? CollapseText(IEnumerable<string?> values)
    {
        var distinct = values
            .Select(Normalize)
            .Where(v => v.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(2)
            .ToList();

        return distinct.Count switch
        {
            0 => null,
            1 => distinct[0],
            _ => PullSheetReportRepository.MixedMarker,
        };
    }

    /// <summary>
    /// PullItems.Tag — 'pcba' or 'swap', the column's real and only source.
    /// It reads as empty in most exports because the column is empty in most
    /// rows (2 tagged of 54,560 on production as at 2026-08-21), not because
    /// nothing is wired to it.
    /// </summary>
    private static string FormatTag(string? tag) =>
        string.IsNullOrWhiteSpace(tag) ? "" : tag.ToUpperInvariant();

    private static string Title(string? s) =>
        string.IsNullOrEmpty(s) ? "" : char.ToUpperInvariant(s[0]) + s[1..];
}
