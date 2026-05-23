using System.Data;
using System.Drawing;
using FastReport;
using FastReport.Utils;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// Builds the Delivery Order report programmatically (no .frx template
/// file authored — operators can drop in a designer-built template later
/// by switching the build to report.Load(path) + report.RegisterData).
///
/// Layout (single page, A4 portrait):
///   ReportTitle: company header + DO meta + vendor/warehouse blocks
///                + reference number
///   DataBand:    one row per allocation slice (ItemCode + Description
///                + PO·Line + Hour + QtyReceived)
///   ReportSummary: total qty + closed-by/role/timestamp text
///
/// Signature SVG is intentionally NOT rendered on the DO — the drawer
/// already shows it with a Download PNG affordance; a SVG-to-PNG
/// conversion for embedding into the report would need a separate
/// rendering library (System.Drawing.Common can't parse SVG). Closer
/// name + role + timestamp serve as the printed authorization marker.
/// </summary>
public class DeliveryOrderService : IDeliveryOrderService
{
    private readonly IPullRepository _pulls;
    private readonly IReceiptRepository _receipts;
    private readonly CompanyInfo _company;

    public DeliveryOrderService(
        IPullRepository pulls,
        IReceiptRepository receipts,
        IOptions<CompanyInfo> company)
    {
        _pulls = pulls;
        _receipts = receipts;
        _company = company.Value;
    }

    public async Task<Report> BuildAsync(Guid pullId, CancellationToken ct = default)
    {
        var pull = await _pulls.GetByIdAsync(pullId, ct)
            ?? throw new NotFoundException("Pull not found");

        if (!string.Equals(pull.Status, "closed", StringComparison.Ordinal))
            throw new BusinessException(
                "Delivery Order can only be rendered for closed pulls. " +
                "Close the pull first (it must be fully received and signed off).");

        var journal = await _receipts.GetJournalForPullAsync(pullId, ct);
        // DO = proof of delivery. Skip reversal rows + voided originals so the
        // report shows the net actual delivery (positive rows that survived).
        var lines = journal
            .Where(r => r.Kind == "receive" && r.QtyReceived > 0)
            .OrderBy(r => r.PoNumber)
            .ThenBy(r => r.PoLineNumber)
            .ThenBy(r => r.HourOfDay)
            .ThenBy(r => r.ReceivedAt)
            .ToList();

        if (lines.Count == 0)
            throw new BusinessException(
                "This pull has no delivered receipts. A Delivery Order requires at least one " +
                "non-cancelled receipt to render.");

        return Build(pull, lines);
    }

    // ------------------------------------------------------------------
    // Report builder. Plain System.Drawing units (mm via Units helper)
    // throughout so the layout matches what a designer-built template
    // would look like when imported later.
    // ------------------------------------------------------------------
    private Report Build(PullDetail pull, IReadOnlyList<ReceiptJournalRow> lines)
    {
        var report = new Report();
        var page = new ReportPage
        {
            Name = "DOPage",
            PaperWidth  = 210,   // A4 portrait, millimeters
            PaperHeight = 297,
            LeftMargin = 15, RightMargin = 15, TopMargin = 15, BottomMargin = 15,
        };
        report.Pages.Add(page);

        // ----- Title band: company header + DO meta + vendor/warehouse + reference -----
        var titleBand = new ReportTitleBand
        {
            Name = "ReportTitle1",
            Height = Units.Millimeters * 70f,
        };
        page.ReportTitle = titleBand;

        // Heading row — company name (left) + DO title (right)
        titleBand.Objects.Add(MakeText("CompanyName", 0, 0, 110, 8,
            _company.Name, fontSize: 14f, bold: true));
        titleBand.Objects.Add(MakeText("DoTitle", 110, 0, 70, 8,
            "DELIVERY ORDER", fontSize: 16f, bold: true, align: HorzAlign.Right));

        // Company sub-line
        titleBand.Objects.Add(MakeText("CompanyMeta", 0, 9, 110, 12,
            BuildCompanyMeta(), fontSize: 9f));

        // DO meta block (right column)
        titleBand.Objects.Add(MakeText("DoMeta", 110, 9, 70, 24,
            $"DO #: {pull.PullNumber}\n" +
            $"Pull date: {pull.PullDate:yyyy-MM-dd}\n" +
            (pull.ClosedAt.HasValue ? $"Closed: {pull.ClosedAt.Value:yyyy-MM-dd HH:mm} UTC" : ""),
            fontSize: 9f, align: HorzAlign.Right));

        // Divider
        titleBand.Objects.Add(MakeHRule("Rule1", 0, 25, 180));

        // Vendor block (left half)
        var vendorBlock = BuildVendorBlock(lines);
        titleBand.Objects.Add(MakeText("VendorLabel", 0, 28, 85, 5, "VENDOR", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText("VendorValue", 0, 33, 85, 10, vendorBlock, fontSize: 10f));

        // Warehouse block (right half)
        titleBand.Objects.Add(MakeText("WhLabel", 95, 28, 85, 5, "WAREHOUSE", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText("WhValue", 95, 33, 85, 10,
            $"{pull.WarehouseCode} · {pull.WarehouseName}",
            fontSize: 10f));

        // Reference block (full width)
        titleBand.Objects.Add(MakeText("RefLabel", 0, 48, 180, 5, "REFERENCE", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText("RefValue", 0, 53, 180, 6,
            string.IsNullOrWhiteSpace(pull.ReferenceNumber) ? "(none)" : pull.ReferenceNumber,
            fontSize: 11f, bold: true));

        // Table header row (sits at the bottom of the title band; the
        // DataBand below renders rows beneath it).
        titleBand.Objects.Add(MakeHRule("Rule2", 0, 63, 180));
        titleBand.Objects.Add(MakeText("HdrItem",  0,  64, 30, 6, "ITEM",        fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText("HdrDesc", 30,  64, 70, 6, "DESCRIPTION", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText("HdrPo",  100,  64, 35, 6, "PO · LINE",   fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText("HdrHr",  135,  64, 15, 6, "HOUR",        fontSize: 8f, bold: true, align: HorzAlign.Right));
        titleBand.Objects.Add(MakeText("HdrQty", 150,  64, 30, 6, "QTY",         fontSize: 8f, bold: true, align: HorzAlign.Right));

        // ----- Data band: one row per delivery slice -----
        var dataBand = new DataBand
        {
            Name = "DeliveryRows",
            Height = Units.Millimeters * 6f,
        };
        page.AddChild(dataBand);

        // Register as a DataTable. The business-object overload
        // (RegisterData<T>(IEnumerable<T>, string)) does not reliably register
        // a retrievable DataSource in FastReport.OpenSource — GetDataSource
        // returns null. A DataTable round-trips cleanly.
        var table = new DataTable("Lines");
        table.Columns.Add("ItemCode",        typeof(string));
        table.Columns.Add("ItemDescription", typeof(string));
        table.Columns.Add("PoNumber",        typeof(string));
        table.Columns.Add("PoLineNumber",    typeof(int));
        table.Columns.Add("HourOfDay",       typeof(int));
        table.Columns.Add("QtyReceived",     typeof(int));
        foreach (var r in lines)
        {
            table.Rows.Add(
                r.ItemCode, r.ItemDescription, r.PoNumber, r.PoLineNumber,
                (int)r.HourOfDay, r.QtyReceived);
        }
        report.RegisterData(table, "Lines");
        var ds = report.GetDataSource("Lines")
            ?? throw new InvalidOperationException("DataSource 'Lines' did not register.");
        ds.Enabled = true;
        dataBand.DataSource = ds;

        dataBand.Objects.Add(MakeText("ColItem",   0, 0, 30, 5, "[Lines.ItemCode]",        fontSize: 9f));
        dataBand.Objects.Add(MakeText("ColDesc",  30, 0, 70, 5, "[Lines.ItemDescription]", fontSize: 9f));
        dataBand.Objects.Add(MakeText("ColPo",   100, 0, 35, 5, "[Lines.PoNumber]·L[Lines.PoLineNumber]", fontSize: 9f));
        dataBand.Objects.Add(MakeText("ColHr",   135, 0, 15, 5, "[Lines.HourOfDay]:00",    fontSize: 9f, align: HorzAlign.Right));
        dataBand.Objects.Add(MakeText("ColQty",  150, 0, 30, 5, "[Lines.QtyReceived]",     fontSize: 9f, align: HorzAlign.Right));

        // ----- Summary band: total + close-auth text block -----
        var summaryBand = new ReportSummaryBand
        {
            Name = "ReportSummary1",
            Height = Units.Millimeters * 40f,
        };
        page.ReportSummary = summaryBand;

        var totalQty = lines.Sum(r => r.QtyReceived);
        summaryBand.Objects.Add(MakeHRule("RuleTotal", 0, 1, 180));
        summaryBand.Objects.Add(MakeText("TotalLabel", 100, 3, 50, 6,
            "TOTAL DELIVERED", fontSize: 9f, bold: true, align: HorzAlign.Right));
        summaryBand.Objects.Add(MakeText("TotalValue", 150, 3, 30, 6,
            $"{totalQty:N0} pcs", fontSize: 11f, bold: true, align: HorzAlign.Right));

        // Close-auth text block (signature image deliberately omitted —
        // see class summary).
        summaryBand.Objects.Add(MakeHRule("RuleAuth", 0, 17, 180));
        summaryBand.Objects.Add(MakeText("AuthLabel", 0, 19, 90, 5,
            "AUTHORIZED BY", fontSize: 8f, bold: true));
        summaryBand.Objects.Add(MakeText("AuthName", 0, 24, 90, 6,
            pull.ClosedByName ?? "(unknown)", fontSize: 11f, bold: true));
        summaryBand.Objects.Add(MakeText("AuthRole", 0, 30, 90, 5,
            string.IsNullOrEmpty(pull.ClosedByRole) ? "" : pull.ClosedByRole.ToUpperInvariant(),
            fontSize: 8f));
        summaryBand.Objects.Add(MakeText("AuthTime", 0, 35, 90, 5,
            pull.ClosedAt.HasValue ? $"Closed {pull.ClosedAt.Value:yyyy-MM-dd HH:mm} UTC" : "",
            fontSize: 8f));

        report.Prepare();
        return report;
    }

    // ------------------------------------------------------------------
    // Tiny builders (keep the Build method readable)
    // ------------------------------------------------------------------
    private static TextObject MakeText(string name, float xMm, float yMm, float wMm, float hMm,
                                       string text, float fontSize, bool bold = false,
                                       HorzAlign align = HorzAlign.Left)
    {
        var style = bold ? FontStyle.Bold : FontStyle.Regular;
        return new TextObject
        {
            Name = name,
            Bounds = new RectangleF(
                Units.Millimeters * xMm,
                Units.Millimeters * yMm,
                Units.Millimeters * wMm,
                Units.Millimeters * hMm),
            Text = text,
            Font = new Font("Arial", fontSize, style),
            HorzAlign = align,
            VertAlign = VertAlign.Top,
            CanGrow = true,
        };
    }

    private static LineObject MakeHRule(string name, float xMm, float yMm, float wMm)
    {
        return new LineObject
        {
            Name = name,
            Bounds = new RectangleF(
                Units.Millimeters * xMm,
                Units.Millimeters * yMm,
                Units.Millimeters * wMm,
                0),
            Border = { Lines = BorderLines.Top, Width = 0.5f },
        };
    }

    private string BuildCompanyMeta()
    {
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(_company.Address)) parts.Add(_company.Address);
        if (!string.IsNullOrWhiteSpace(_company.Phone))   parts.Add($"Tel: {_company.Phone}");
        if (!string.IsNullOrWhiteSpace(_company.TaxId))   parts.Add($"Tax ID: {_company.TaxId}");
        return string.Join("\n", parts);
    }

    private static string BuildVendorBlock(IReadOnlyList<ReceiptJournalRow> lines)
    {
        // A pull can land receipts from multiple POs (warehouse-wide FIFO) so
        // multiple vendors are possible. Group distinct vendor identifiers
        // and join with newlines so the DO names every supplier whose stock
        // is being acknowledged.
        var vendors = lines
            .Select(r => new { r.VendorCode, r.VendorName })
            .Where(v => !string.IsNullOrWhiteSpace(v.VendorCode) || !string.IsNullOrWhiteSpace(v.VendorName))
            .Distinct()
            .Select(v => $"{v.VendorCode} · {v.VendorName}".Trim(' ', '·'))
            .ToList();
        return vendors.Count > 0 ? string.Join("\n", vendors) : "(unknown vendor)";
    }
}
