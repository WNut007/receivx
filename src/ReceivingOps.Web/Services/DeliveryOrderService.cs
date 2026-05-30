using System.Data;
using System.Drawing;
using System.IO;
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
/// v2.x Phase 7.4 — DoReportData is the single source of truth; both the
/// HTML preview partial and the FastReport PDF builder consume it. One
/// A4 page per DoOrder, aggregated by (Item × PoLineNumber). No hour
/// column on the printed paper (matches the HTML preview).
///
/// Signature rendering: PNG dataURL ("data:image/png;base64,...") is
/// decoded and embedded above the AUTHORIZED BY divider as a FastReport
/// PictureObject. Inline SVG markup is skipped — System.Drawing.Common
/// can't parse SVG, so adding inline-SVG support would need SkiaSharp or
/// Svg.NET. In both cases the text block (closer name + role + timestamp)
/// still renders, so a broken or absent signature image never blocks the
/// printed authorization marker.
/// </summary>
public class DeliveryOrderService : IDeliveryOrderService
{
    private readonly IPullRepository _pulls;
    private readonly CompanyInfo _company;

    public DeliveryOrderService(
        IPullRepository pulls,
        IOptions<CompanyInfo> company)
    {
        _pulls = pulls;
        _company = company.Value;
    }

    // v2.x Phase 7.4 — single source of truth for both the HTML preview
    // partial AND the FastReport PDF builder. Eligibility checks happen
    // here so neither downstream caller has to duplicate them.
    public async Task<DoReportData> GetReportDataAsync(Guid pullId, CancellationToken ct = default)
    {
        var pull = await _pulls.GetByIdAsync(pullId, ct)
            ?? throw new NotFoundException("Pull not found");

        if (!string.Equals(pull.Status, "closed", StringComparison.Ordinal))
            throw new BusinessException(
                "Delivery Order can only be rendered for closed pulls. " +
                "Close the pull first (it must be fully received and signed off).");

        var rows = await _pulls.GetDoReportRowsAsync(pullId, ct);
        if (rows.Count == 0)
            throw new BusinessException(
                "This pull has no delivered receipts. A Delivery Order requires at least one " +
                "non-cancelled receipt to render.");

        // Phase 14: DO grouping key = (VendorCode × SubInventory × ToLocation).
        // The SQL projects each row with its own PoNumber so each DoLine
        // carries a PoLineRef back to its source purchase order. Null parts
        // of the grouping key collapse to empty string for the GroupBy
        // (LINQ's GroupBy treats null and "" as distinct otherwise; here we
        // want all null-vendor lines to share one DO, not split per-row).
        var orders = rows
            .GroupBy(r => new
            {
                VendorCode   = r.VendorCode   ?? "",
                VendorName   = r.VendorName   ?? "",
                SubInventory = r.SubInventory ?? "",
                ToLocation   = r.ToLocation   ?? "",
            })
            .Select(g =>
            {
                var lines = g.Select(r => new DoLine
                {
                    ItemCode     = r.ItemCode,
                    Description  = r.Description,
                    PoLineNumber = r.PoLineNumber,
                    PoLineRef    = $"{r.PoNumber}·L{r.PoLineNumber}",
                    TotalQty     = r.TotalQty,
                    PalletId     = r.PalletId,
                    OrderId      = r.OrderId,
                    InvoiceNo    = r.InvoiceNo,
                    KanbanNo     = r.KanbanNo,
                    SubInventory = g.Key.SubInventory.Length == 0 ? null : g.Key.SubInventory,
                    ToLocation   = g.Key.ToLocation.Length   == 0 ? null : g.Key.ToLocation,
                    AsnNo        = r.AsnNo,
                    OrderRound   = r.OrderRound,
                }).ToList();
                return new DoOrder
                {
                    VendorCode   = g.Key.VendorCode.Length   == 0 ? null : g.Key.VendorCode,
                    VendorName   = g.Key.VendorName.Length   == 0 ? null : g.Key.VendorName,
                    SubInventory = g.Key.SubInventory.Length == 0 ? null : g.Key.SubInventory,
                    ToLocation   = g.Key.ToLocation.Length   == 0 ? null : g.Key.ToLocation,
                    Lines        = lines,
                    TotalQty     = lines.Sum(l => l.TotalQty),
                };
            })
            .OrderBy(o => o.VendorCode ?? "")
                .ThenBy(o => o.SubInventory ?? "")
                .ThenBy(o => o.ToLocation ?? "")
            .ToList();

        return new DoReportData
        {
            Pull = new DoPullHeader
            {
                Id              = pull.Id,
                PullNumber      = pull.PullNumber,
                PullDate        = pull.PullDate,
                ReferenceNumber = pull.ReferenceNumber,
                WarehouseCode   = pull.WarehouseCode,
                WarehouseName   = pull.WarehouseName,
                ClosedAt        = pull.ClosedAt,
                ClosedByName    = pull.ClosedByName,
                ClosedByRole    = pull.ClosedByRole,
                SignatureSvg    = pull.SignatureSvg,
                TotalQty        = orders.Sum(o => o.TotalQty),
            },
            Orders  = orders,
            Company = _company,
        };
    }

    public async Task<Report> BuildAsync(Guid pullId, CancellationToken ct = default)
    {
        var data = await GetReportDataAsync(pullId, ct);
        return Build(data);
    }

    // ------------------------------------------------------------------
    // Report builder — one A4 portrait page per DoOrder. A pull that
    // touched two POs ships a 2-page PDF; one DO per page so each is
    // self-contained for mail/email/print.
    //
    // Layout per page:
    //   Title band: company header + DO# + pull context
    //                + vendor + warehouse + reference
    //                + table header (Item · Description · PO·Line · Qty —
    //                  no hour column, lines are pre-aggregated)
    //   Data band:  one row per DoLine
    //   Summary:    per-DO total (right under the last line)
    //   Page foot:  RECEIVED BY + AUTHORIZED BY blocks + PNG signature,
    //               anchored to the bottom of every printed page so
    //               multi-page DOs carry an auth marker on each detachable
    //               sheet. Engine emits this via ShowPageFooter() in
    //               ReportEngine.Pages; PDFSimpleExport renders whatever
    //               the engine emits.
    // ------------------------------------------------------------------
    private Report Build(DoReportData data)
    {
        var report = new Report();
        for (int i = 0; i < data.Orders.Count; i++)
        {
            AddOrderPage(report, data, data.Orders[i], i);
        }
        report.Prepare();
        return report;
    }

    private void AddOrderPage(Report report, DoReportData data, DoOrder order, int idx)
    {
        var page = new ReportPage
        {
            Name = $"DOPage{idx}",
            PaperWidth  = 210,   // A4 portrait, millimeters
            PaperHeight = 297,
            LeftMargin = 15, RightMargin = 15, TopMargin = 15, BottomMargin = 15,
        };
        report.Pages.Add(page);

        // ----- Title band -----
        // Phase 14 adds a FROM/TO row between Vendor/Warehouse and Reference,
        // pushing the table header down ~12mm — band height grew accordingly.
        var titleBand = new ReportTitleBand
        {
            Name = $"Title{idx}",
            Height = Units.Millimeters * 82f,
        };
        page.ReportTitle = titleBand;

        // Heading: company name (left) + DELIVERY ORDER (right).
        // Phase 14: no PoNumber on the header — the DO is identified by its
        // (Vendor × FromSub × ToLoc) triple, displayed in the metadata rows
        // below. The right-hand DoMeta block carries pull context only.
        titleBand.Objects.Add(MakeText($"CompanyName{idx}", 0, 0, 110, 8,
            data.Company.Name, fontSize: 14f, bold: true));
        titleBand.Objects.Add(MakeText($"DoTitle{idx}", 110, 0, 70, 8,
            "DELIVERY ORDER", fontSize: 16f, bold: true, align: HorzAlign.Right));

        // Sub-row: company meta (left) + pull context (right)
        titleBand.Objects.Add(MakeText($"CompanyMeta{idx}", 0, 9, 110, 14,
            BuildCompanyMeta(), fontSize: 9f));
        titleBand.Objects.Add(MakeText($"DoMeta{idx}", 110, 9, 70, 22,
            $"Pull: {data.Pull.PullNumber}\n" +
            $"Pull date: {data.Pull.PullDate:yyyy-MM-dd}\n" +
            (data.Pull.ClosedAt.HasValue ? $"Closed: {data.Pull.ClosedAt.Value:yyyy-MM-dd HH:mm} UTC" : ""),
            fontSize: 9f, align: HorzAlign.Right));

        titleBand.Objects.Add(MakeHRule($"Rule1_{idx}", 0, 25, 180));

        // Vendor (left) + Warehouse (right)
        titleBand.Objects.Add(MakeText($"VendorLabel{idx}", 0, 28, 85, 5, "VENDOR", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"VendorValue{idx}", 0, 33, 85, 10,
            VendorDisplay(order), fontSize: 10f));

        titleBand.Objects.Add(MakeText($"WhLabel{idx}", 95, 28, 85, 5, "WAREHOUSE", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"WhValue{idx}", 95, 33, 85, 10,
            $"{data.Pull.WarehouseCode} · {data.Pull.WarehouseName}", fontSize: 10f));

        // Phase 14: FROM SUBINVENTORY (left) + TO LOCATION (right) — the
        // movement direction this DO documents. Sits below the Vendor /
        // Warehouse band (which ends near y=43) with a small gap.
        titleBand.Objects.Add(MakeText($"FromLabel{idx}", 0, 45, 85, 5, "FROM SUBINVENTORY", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"FromValue{idx}", 0, 50, 85, 6,
            string.IsNullOrWhiteSpace(order.SubInventory) ? "—" : order.SubInventory,
            fontSize: 10f));

        titleBand.Objects.Add(MakeText($"ToLabel{idx}", 95, 45, 85, 5, "TO LOCATION", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"ToValue{idx}", 95, 50, 85, 6,
            string.IsNullOrWhiteSpace(order.ToLocation) ? "—" : order.ToLocation,
            fontSize: 10f));

        // Reference (full width)
        titleBand.Objects.Add(MakeText($"RefLabel{idx}", 0, 60, 180, 5, "REFERENCE", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"RefValue{idx}", 0, 65, 180, 6,
            string.IsNullOrWhiteSpace(data.Pull.ReferenceNumber) ? "—" : data.Pull.ReferenceNumber,
            fontSize: 11f, bold: true));

        // Table header (no HOUR column — aggregated). Pushed down to clear
        // the new FROM/TO row above.
        titleBand.Objects.Add(MakeHRule($"Rule2_{idx}", 0, 74, 180));
        titleBand.Objects.Add(MakeText($"HdrItem{idx}",  0,  75, 35, 6, "ITEM",        fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"HdrDesc{idx}", 35,  75, 85, 6, "DESCRIPTION", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"HdrPo{idx}",  120,  75, 40, 6, "PO · LINE",   fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"HdrQty{idx}", 160,  75, 20, 6, "QTY",         fontSize: 8f, bold: true, align: HorzAlign.Right));

        // ----- Data band: one row per aggregated line -----
        // 12 mm height = primary cells row (5 mm) + ERP detail strip (~6 mm).
        // The detail TextObject uses CanGrow so a row that wraps to a second
        // text line still fits inside the allotted height.
        var dataBand = new DataBand
        {
            Name = $"DeliveryRows{idx}",
            Height = Units.Millimeters * 12f,
        };
        page.AddChild(dataBand);

        var dsName = $"Lines{idx}";
        var table = new DataTable(dsName);
        table.Columns.Add("ItemCode",    typeof(string));
        table.Columns.Add("Description", typeof(string));
        table.Columns.Add("PoLineRef",   typeof(string));
        table.Columns.Add("TotalQty",    typeof(int));
        table.Columns.Add("PalletId",     typeof(string));
        table.Columns.Add("OrderId",      typeof(string));
        table.Columns.Add("InvoiceNo",    typeof(string));
        table.Columns.Add("KanbanNo",     typeof(string));
        table.Columns.Add("SubInventory", typeof(string));
        table.Columns.Add("ToLocation",   typeof(string));
        table.Columns.Add("AsnNo",        typeof(string));
        table.Columns.Add("OrderRound",   typeof(string));
        foreach (var line in order.Lines)
        {
            // Persist "—" for nulls so empty PoLine fields are visually
            // distinguishable from a rendering bug in the PDF.
            table.Rows.Add(
                line.ItemCode, line.Description, line.PoLineRef, line.TotalQty,
                line.PalletId     ?? "—",
                line.OrderId      ?? "—",
                line.InvoiceNo    ?? "—",
                line.KanbanNo     ?? "—",
                line.SubInventory ?? "—",
                line.ToLocation   ?? "—",
                line.AsnNo        ?? "—",
                line.OrderRound   ?? "—");
        }
        report.RegisterData(table, dsName);
        var ds = report.GetDataSource(dsName)
            ?? throw new InvalidOperationException($"DataSource '{dsName}' did not register.");
        ds.Enabled = true;
        dataBand.DataSource = ds;

        dataBand.Objects.Add(MakeText($"ColItem{idx}",   0, 0, 35, 5, $"[{dsName}.ItemCode]",    fontSize: 9f));
        dataBand.Objects.Add(MakeText($"ColDesc{idx}",  35, 0, 85, 5, $"[{dsName}.Description]", fontSize: 9f));
        dataBand.Objects.Add(MakeText($"ColPo{idx}",   120, 0, 40, 5, $"[{dsName}.PoLineRef]",   fontSize: 9f));
        dataBand.Objects.Add(MakeText($"ColQty{idx}",  160, 0, 20, 5, $"[{dsName}.TotalQty]",    fontSize: 9f, align: HorzAlign.Right));

        // ERP detail strip — one text block below the primary cells.
        // Verify-grade layout only; this is single-line at 7 pt and will
        // wrap (CanGrow) if a value is long. Polish deferred.
        var detailText =
            $"Pallet [{dsName}.PalletId]   Order [{dsName}.OrderId]   " +
            $"Invoice [{dsName}.InvoiceNo]   Kanban [{dsName}.KanbanNo]   " +
            $"Sub-Inv [{dsName}.SubInventory]   To-Loc [{dsName}.ToLocation]   " +
            $"ASN [{dsName}.AsnNo]   Round [{dsName}.OrderRound]";
        dataBand.Objects.Add(MakeText($"ColDetail{idx}", 0, 6, 180, 5, detailText, fontSize: 7f));

        // ----- Summary band: per-DO total only (10mm). Sits right under
        // the last data row on the last page; auth block lives in the
        // PageFooterBand below so multi-page DOs carry sig on every page.
        var summaryBand = new ReportSummaryBand
        {
            Name = $"Summary{idx}",
            Height = Units.Millimeters * 10f,
        };
        page.ReportSummary = summaryBand;

        summaryBand.Objects.Add(MakeHRule($"RuleTotal{idx}", 0, 1, 180));
        summaryBand.Objects.Add(MakeText($"TotalLabel{idx}", 100, 3, 50, 6,
            "TOTAL DELIVERED", fontSize: 9f, bold: true, align: HorzAlign.Right));
        summaryBand.Objects.Add(MakeText($"TotalValue{idx}", 150, 3, 30, 6,
            $"{order.TotalQty:N0} pcs", fontSize: 11f, bold: true, align: HorzAlign.Right));

        // ----- Page footer: close-auth + PNG signature, anchored to bottom
        // of every printed page (multi-page DOs carry the auth marker on
        // each detachable sheet). Y origin is the top of the footer band.
        var pageFooter = new PageFooterBand
        {
            Name = $"PageFooter{idx}",
            Height = Units.Millimeters * 35f,
        };
        page.PageFooter = pageFooter;

        var closedFmt = data.Pull.ClosedAt.HasValue
            ? $"Closed {data.Pull.ClosedAt.Value:yyyy-MM-dd HH:mm} UTC"
            : "";

        // PNG signature image sits ABOVE the AUTHORIZED BY divider rule;
        // text-block flows below it. AddSignaturePicture preserved verbatim
        // from v3.3 ship — call site only relocated.
        var sigPng = DecodeSignaturePng(data.Pull.SignatureSvg);
        if (sigPng is not null)
        {
            try { pageFooter.Objects.Add(MakeSignaturePicture($"AuthSig{idx}", 95, 0, 85, 8, sigPng)); }
            catch (ArgumentException) { /* malformed PNG — fall back to text-only */ }
            catch (OutOfMemoryException) { /* GDI+ throws this for invalid image streams */ }
        }

        // Divider rules (top of text block on each side)
        pageFooter.Objects.Add(MakeHRule($"RuleRcv{idx}",  0, 9,  85));
        pageFooter.Objects.Add(MakeHRule($"RuleAuth{idx}", 95, 9, 85));

        // LEFT: RECEIVED BY (physical signature happens on paper above the rule)
        pageFooter.Objects.Add(MakeText($"RcvLabel{idx}",  0, 11, 85, 5,
            "RECEIVED BY", fontSize: 8f, bold: true));
        pageFooter.Objects.Add(MakeText($"RcvName{idx}",   0, 16, 85, 6,
            data.Pull.ClosedByName ?? "—", fontSize: 11f, bold: true));
        pageFooter.Objects.Add(MakeText($"RcvTime{idx}",   0, 22, 85, 5,
            closedFmt, fontSize: 8f));

        // RIGHT: AUTHORIZED BY (closer of the pull — name + role + time)
        pageFooter.Objects.Add(MakeText($"AuthLabel{idx}", 95, 11, 85, 5,
            "AUTHORIZED BY", fontSize: 8f, bold: true));
        pageFooter.Objects.Add(MakeText($"AuthName{idx}",  95, 16, 85, 6,
            data.Pull.ClosedByName ?? "—", fontSize: 11f, bold: true));
        pageFooter.Objects.Add(MakeText($"AuthRole{idx}",  95, 22, 85, 5,
            string.IsNullOrEmpty(data.Pull.ClosedByRole) ? "" : data.Pull.ClosedByRole.ToUpperInvariant(),
            fontSize: 8f));
        pageFooter.Objects.Add(MakeText($"AuthTime{idx}",  95, 27, 85, 5,
            closedFmt, fontSize: 8f));
    }

    /// <summary>Vendor display fallback chain: Name → Code → em-dash. Same as the HTML partial.</summary>
    private static string VendorDisplay(DoOrder order)
    {
        if (!string.IsNullOrWhiteSpace(order.VendorName)) return order.VendorName!;
        if (!string.IsNullOrWhiteSpace(order.VendorCode)) return order.VendorCode!;
        return "—";
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

    /// <summary>
    /// Decodes a "data:image/png;base64,..." signature dataURL into raw PNG
    /// bytes. Returns null for null/empty input, inline SVG strings, other
    /// dataURL flavors, or malformed base64 — caller falls back to text-only.
    /// </summary>
    private static byte[]? DecodeSignaturePng(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        const string prefix = "data:image/png;base64,";
        if (!raw.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return null;
        try { return Convert.FromBase64String(raw.Substring(prefix.Length)); }
        catch (FormatException) { return null; }
    }

    /// <summary>
    /// Decodes the PNG and pre-flattens it onto a white 24bpp canvas. Two
    /// reasons: (1) PDFSimpleExport rasterizes pages to a JPEG and JPEG has
    /// no alpha — transparent PNG pixels collapse to black, not white, in
    /// the export pipeline, so we must flatten ourselves. (2) Copying away
    /// from the MemoryStream lets us dispose the stream immediately without
    /// GDI+ later failing on a closed source.
    /// </summary>
    private static PictureObject MakeSignaturePicture(string name, float xMm, float yMm,
                                                      float wMm, float hMm, byte[] pngBytes)
    {
        Bitmap flat;
        using (var ms = new MemoryStream(pngBytes))
        using (var loaded = Image.FromStream(ms))
        {
            flat = new Bitmap(loaded.Width, loaded.Height,
                              System.Drawing.Imaging.PixelFormat.Format24bppRgb);
            using var g = Graphics.FromImage(flat);
            g.Clear(Color.White);
            g.DrawImage(loaded, 0, 0, loaded.Width, loaded.Height);
        }
        return new PictureObject
        {
            Name = name,
            Bounds = new RectangleF(
                Units.Millimeters * xMm,
                Units.Millimeters * yMm,
                Units.Millimeters * wMm,
                Units.Millimeters * hMm),
            // FastReport.Compat shims this enum under System.Windows.Forms;
            // qualify to avoid a missing-namespace error.
            SizeMode = System.Windows.Forms.PictureBoxSizeMode.Zoom,
            Image = flat,
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

}
