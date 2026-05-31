using System.Data;
using System.Drawing;
using System.IO;
using FastReport;
using FastReport.Barcode;
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
    private readonly IWarehouseRepository _warehouses;
    private readonly CompanyInfo _company;
    private readonly IWebHostEnvironment _env;

    public DeliveryOrderService(
        IPullRepository pulls,
        IWarehouseRepository warehouses,
        IOptions<CompanyInfo> company,
        IWebHostEnvironment env)
    {
        _pulls = pulls;
        _warehouses = warehouses;
        _company = company.Value;
        _env = env;
    }

    // ------------------------------------------------------------------
    // Path B scaffold (Stage 1) — designer-driven .frx workflow.
    //
    // Path resolves against ContentRootPath so it works in both dev
    // (project dir) and published output (publish dir — Reports/ ships
    // alongside the binary via the csproj CopyToOutputDirectory rule).
    //
    // Stage 3 auto-generates the .frx on first miss; Stage 4 wires
    // Report.Load() into the build pipeline. The programmatic Build()
    // path below stays authoritative until the Stage 4 cutover so the
    // existing PDF export keeps working during the refactor.
    // ------------------------------------------------------------------
    private string GetFrxPath() =>
        Path.Combine(_env.ContentRootPath, "Reports", "delivery-order.frx");

    private bool FrxExists() => File.Exists(GetFrxPath());

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

        // DO grouping key = (VendorCode × SubInventory × ToLocation × InvoiceNo).
        // The SQL projects each row with its own PoNumber so each DoLine
        // carries a PoLineRef back to its source purchase order. Null parts
        // of the grouping key collapse to empty string for the GroupBy
        // (LINQ's GroupBy treats null and "" as distinct otherwise; here we
        // want all all-null-key lines to share one DO, not split per-row).
        var orders = rows
            .GroupBy(r => new
            {
                VendorCode   = r.VendorCode   ?? "",
                VendorName   = r.VendorName   ?? "",
                SubInventory = r.SubInventory ?? "",
                ToLocation   = r.ToLocation   ?? "",
                InvoiceNo    = r.InvoiceNo    ?? "",
            })
            .Select(g =>
            {
                var lines = g.Select(r => new DoLine
                {
                    ItemCode       = r.ItemCode,
                    Description    = r.Description,
                    PoLineNumber   = r.PoLineNumber,
                    PoLineRef      = $"{r.PoNumber}·L{r.PoLineNumber}",
                    TotalQty       = r.TotalQty,
                    LastReceivedAt = r.LastReceivedAt,
                    PalletId       = r.PalletId,
                    OrderId        = r.OrderId,
                    InvoiceNo      = g.Key.InvoiceNo.Length    == 0 ? null : g.Key.InvoiceNo,
                    KanbanNo       = r.KanbanNo,
                    SubInventory   = g.Key.SubInventory.Length == 0 ? null : g.Key.SubInventory,
                    ToLocation     = g.Key.ToLocation.Length   == 0 ? null : g.Key.ToLocation,
                    AsnNo          = r.AsnNo,
                    OrderRound     = r.OrderRound,
                }).ToList();
                // Dominant PO# for the DSV header — ordinal-min so it's
                // stable when multiple POs feed a single DO (rare but
                // possible under mixed-vendor/invoice arrangements).
                var headerPo = g.Select(r => r.PoNumber)
                                .Where(s => !string.IsNullOrEmpty(s))
                                .OrderBy(s => s, StringComparer.Ordinal)
                                .FirstOrDefault();
                return new DoOrder
                {
                    VendorCode     = g.Key.VendorCode.Length   == 0 ? null : g.Key.VendorCode,
                    VendorName     = g.Key.VendorName.Length   == 0 ? null : g.Key.VendorName,
                    SubInventory   = g.Key.SubInventory.Length == 0 ? null : g.Key.SubInventory,
                    ToLocation     = g.Key.ToLocation.Length   == 0 ? null : g.Key.ToLocation,
                    InvoiceNo      = g.Key.InvoiceNo.Length    == 0 ? null : g.Key.InvoiceNo,
                    HeaderPoNumber = headerPo,
                    LastReceivedAt = lines.Max(l => l.LastReceivedAt),
                    Lines          = lines,
                    TotalQty       = lines.Sum(l => l.TotalQty),
                };
            })
            .OrderBy(o => o.VendorCode ?? "")
                .ThenBy(o => o.SubInventory ?? "")
                .ThenBy(o => o.ToLocation ?? "")
                .ThenBy(o => o.InvoiceNo ?? "")
            .ToList();

        // Delivery Note No — deterministic per-DO id: first 8 hex chars
        // of Pull.Id + DO letter by index. Stable across re-renders, no
        // schema change. Q5a says display as "{DN}+{InvoiceNo}".
        var pullHex = pull.Id.ToString("N").Substring(0, 8).ToUpperInvariant();
        for (int i = 0; i < orders.Count; i++)
        {
            // Letter rolls A..Z, then AA, AB, … for >26 DOs (defensive — DSV
            // delivery notes in practice never spawn this many).
            orders[i].DeliveryNoteNo = pullHex + IndexToLetters(i);
        }

        // Per-warehouse logo + address for the DSV header — null when unset.
        // Warehouse row is small + cached by SQL plan; one round trip per
        // render is acceptable (DO render is operator-initiated, not hot).
        var wh = await _warehouses.GetByIdAsync(pull.WarehouseId, ct);

        return new DoReportData
        {
            Pull = new DoPullHeader
            {
                Id                   = pull.Id,
                PullNumber           = pull.PullNumber,
                PullDate             = pull.PullDate,
                ReferenceNumber      = pull.ReferenceNumber,
                WarehouseCode        = pull.WarehouseCode,
                WarehouseName        = pull.WarehouseName,
                WarehouseAddress     = wh?.Address,
                WarehouseLogoDataUrl = wh?.LogoDataUrl,
                ClosedAt             = pull.ClosedAt,
                ClosedByName         = pull.ClosedByName,
                ClosedByRole         = pull.ClosedByRole,
                SignatureSvg         = pull.SignatureSvg,
                TotalQty             = orders.Sum(o => o.TotalQty),
            },
            Orders  = orders,
            Company = _company,
        };
    }

    /// <summary>
    /// 0 → "A", 1 → "B", … 25 → "Z", 26 → "AA", 27 → "AB", ….
    /// Used only as a per-DO suffix on the Delivery Note No.
    /// </summary>
    private static string IndexToLetters(int idx)
    {
        if (idx < 0) throw new ArgumentOutOfRangeException(nameof(idx));
        var s = "";
        do
        {
            s = (char)('A' + (idx % 26)) + s;
            idx = idx / 26 - 1;
        } while (idx >= 0);
        return s;
    }

    public async Task<Report> BuildAsync(Guid pullId, CancellationToken ct = default)
    {
        var data = await GetReportDataAsync(pullId, ct);
        return Build(data);
    }

    // ------------------------------------------------------------------
    // DSV-style Delivery Note layout — one A4 portrait page per DoOrder.
    // Replaces the legacy v3.x DO layout (kept on `main` at tag v3.4.1).
    //
    // Layout per page (top-down, all mm, page is 180 wide × 267 tall usable):
    //
    //   Title band ~102mm:
    //     0..14   warehouse logo (left)  | DELIVERY NOTE title (center) | DN# (right)
    //     17..28  warehouse code/name + addr (left)  |  Delivery To (right)
    //     32..62  5-row info grid: L=[P/O · PRS · ORDER TYPE · DROP ID · DATE]
    //                              R=[VENDOR ID · VENDOR · FROM · TO · INVOICE]
    //     65..92  3 × Code128 barcodes (PO / PRS / DN)
    //     95..101 column header row (PART NUM · DESC · PALLET · KANBAN · ASN · ROUND · QTY)
    //
    //   Data band: 8mm per line — 7 columns matching the header
    //
    //   Summary band: TOTAL QTY (right-aligned)
    //
    //   Page footer ~60mm:
    //     STORING NOTE strip (Date Received, Delivery Note No + Inv)
    //     Two empty signature boxes (Delivered By / Approved for Delivery By)
    //     "Page X of Y" bottom-right via FastReport system vars
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
            PaperWidth  = 210,
            PaperHeight = 297,
            LeftMargin = 15, RightMargin = 15, TopMargin = 15, BottomMargin = 15,
        };
        report.Pages.Add(page);

        var titleBand = new ReportTitleBand
        {
            Name = $"Title{idx}",
            Height = Units.Millimeters * 102f,
        };
        page.ReportTitle = titleBand;

        // ----- (1) Top strip: logo · DELIVERY NOTE title · DN# -----
        var logoBytes = DecodeLogoBytes(data.Pull.WarehouseLogoDataUrl);
        if (logoBytes is not null)
        {
            try { titleBand.Objects.Add(MakeLogoPicture($"WhLogo{idx}", 0, 0, 35, 14, logoBytes)); }
            catch (ArgumentException) { }
            catch (OutOfMemoryException) { }
        }
        titleBand.Objects.Add(MakeText($"DnTitle{idx}", 50, 2, 80, 9,
            "DELIVERY NOTE", fontSize: 18f, bold: true, align: HorzAlign.Center));
        titleBand.Objects.Add(MakeText($"DnNoLabel{idx}", 130, 1, 50, 4,
            "Delivery Note No.", fontSize: 7f, align: HorzAlign.Right));
        titleBand.Objects.Add(MakeText($"DnNoValue{idx}", 130, 5, 50, 6,
            order.DeliveryNoteNo, fontSize: 12f, bold: true, align: HorzAlign.Right));
        titleBand.Objects.Add(MakeText($"DnSubIdx{idx}", 130, 11, 50, 4,
            $"DO {idx + 1} of {data.Orders.Count}", fontSize: 7f, align: HorzAlign.Right));

        titleBand.Objects.Add(MakeHRule($"Rule1_{idx}", 0, 15, 180));

        // ----- (2) Address strip: warehouse (left) + Delivery To (right) -----
        var whCodeName = string.IsNullOrWhiteSpace(data.Pull.WarehouseName)
            ? data.Pull.WarehouseCode
            : $"{data.Pull.WarehouseCode} · {data.Pull.WarehouseName}";
        titleBand.Objects.Add(MakeText($"WhBlock{idx}", 0, 17, 90, 12,
            whCodeName + (string.IsNullOrWhiteSpace(data.Pull.WarehouseAddress)
                ? ""
                : "\n" + data.Pull.WarehouseAddress),
            fontSize: 9f));
        titleBand.Objects.Add(MakeText($"DeliverToLabel{idx}", 95, 17, 85, 4,
            "DELIVERY TO", fontSize: 7f, bold: true));
        titleBand.Objects.Add(MakeText($"DeliverToValue{idx}", 95, 21, 85, 8,
            string.IsNullOrWhiteSpace(data.Pull.WarehouseAddress) ? whCodeName : data.Pull.WarehouseAddress,
            fontSize: 9f));

        titleBand.Objects.Add(MakeHRule($"Rule2_{idx}", 0, 30, 180));

        // ----- (3) Info grid: 5 rows × 2 cols × 6mm; label left, value right within each col -----
        var dateOfDelivery = data.Pull.ClosedAt.HasValue
            ? data.Pull.ClosedAt.Value.ToString("dd MMM yyyy")
            : "—";
        var infoRows = new[]
        {
            ("P/O NO",            order.HeaderPoNumber ?? "—",
             "VENDOR ID",         order.VendorCode ?? "—"),
            ("PRS NO",            data.Pull.PullNumber,
             "VENDOR",            VendorDisplay(order)),
            ("ORDER TYPE",        "—",
             "FROM",              order.SubInventory ?? "—"),
            ("DROP ID",           "—",
             "TO",                order.ToLocation ?? "—"),
            ("DATE OF DELIVERY",  dateOfDelivery,
             "VENDOR INVOICE",    order.InvoiceNo ?? "—"),
        };
        const float gridY0 = 32f;
        const float rowH   = 6f;
        for (int r = 0; r < infoRows.Length; r++)
        {
            var (lLabel, lValue, rLabel, rValue) = infoRows[r];
            var y = gridY0 + r * rowH;
            // Left column (90mm, label 32mm + value 58mm)
            titleBand.Objects.Add(MakeText($"GridLL{idx}_{r}",  0, y, 32, 5, lLabel, fontSize: 8f, bold: true));
            titleBand.Objects.Add(MakeText($"GridLV{idx}_{r}", 32, y, 58, 5, lValue, fontSize: 10f));
            // Right column (90mm, label 32mm + value 58mm)
            titleBand.Objects.Add(MakeText($"GridRL{idx}_{r}", 95, y, 32, 5, rLabel, fontSize: 8f, bold: true));
            titleBand.Objects.Add(MakeText($"GridRV{idx}_{r}",127, y, 53, 5, rValue, fontSize: 10f));
        }

        titleBand.Objects.Add(MakeHRule($"Rule3_{idx}", 0, 63, 180));

        // ----- (4) Barcodes: PO, PRS, DN — Code128. Caption (4mm) + bars (22mm). -----
        if (!string.IsNullOrWhiteSpace(order.HeaderPoNumber))
        {
            titleBand.Objects.Add(MakeText($"BcPoCap{idx}", 0, 65, 55, 4, "P/O NO", fontSize: 7f, bold: true, align: HorzAlign.Center));
            titleBand.Objects.Add(MakeBarcode($"BcPo{idx}", 0, 69, 55, 22, order.HeaderPoNumber!));
        }
        if (!string.IsNullOrWhiteSpace(data.Pull.PullNumber))
        {
            titleBand.Objects.Add(MakeText($"BcPrsCap{idx}", 62, 65, 55, 4, "PRS NO", fontSize: 7f, bold: true, align: HorzAlign.Center));
            titleBand.Objects.Add(MakeBarcode($"BcPrs{idx}", 62, 69, 55, 22, data.Pull.PullNumber));
        }
        if (!string.IsNullOrWhiteSpace(order.DeliveryNoteNo))
        {
            titleBand.Objects.Add(MakeText($"BcDnCap{idx}", 124, 65, 55, 4, "DELIVERY NOTE", fontSize: 7f, bold: true, align: HorzAlign.Center));
            titleBand.Objects.Add(MakeBarcode($"BcDn{idx}", 124, 69, 55, 22, order.DeliveryNoteNo));
        }

        titleBand.Objects.Add(MakeHRule($"Rule4_{idx}", 0, 93, 180));

        // ----- (5) Column header row -----
        // Widths: PART 28 · DESC 60 · PALLET 24 · KANBAN 18 · ASN 18 · ROUND 14 · QTY 18 = 180
        titleBand.Objects.Add(MakeText($"HdrPart{idx}",  0,  95, 28, 6, "PART NUMBER", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"HdrDesc{idx}", 28,  95, 60, 6, "DESCRIPTION", fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"HdrPal{idx}",  88,  95, 24, 6, "PALLET",      fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"HdrKan{idx}", 112,  95, 18, 6, "KANBAN",      fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"HdrAsn{idx}", 130,  95, 18, 6, "ASN",         fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"HdrRnd{idx}", 148,  95, 14, 6, "ROUND",       fontSize: 8f, bold: true));
        titleBand.Objects.Add(MakeText($"HdrQty{idx}", 162,  95, 18, 6, "QTY",         fontSize: 8f, bold: true, align: HorzAlign.Right));
        titleBand.Objects.Add(MakeHRule($"Rule5_{idx}", 0, 101, 180));

        // ----- Data band (8mm per row, 7 columns matching the header) -----
        var dataBand = new DataBand
        {
            Name = $"DeliveryRows{idx}",
            Height = Units.Millimeters * 8f,
        };
        page.AddChild(dataBand);

        var dsName = $"Lines{idx}";
        var table = new DataTable(dsName);
        table.Columns.Add("ItemCode",     typeof(string));
        table.Columns.Add("Description",  typeof(string));
        table.Columns.Add("PalletId",     typeof(string));
        table.Columns.Add("KanbanNo",     typeof(string));
        table.Columns.Add("AsnNo",        typeof(string));
        table.Columns.Add("OrderRound",   typeof(string));
        table.Columns.Add("TotalQty",     typeof(int));
        foreach (var line in order.Lines)
        {
            table.Rows.Add(
                line.ItemCode, line.Description,
                line.PalletId   ?? "—",
                line.KanbanNo   ?? "—",
                line.AsnNo      ?? "—",
                line.OrderRound ?? "—",
                line.TotalQty);
        }
        report.RegisterData(table, dsName);
        var ds = report.GetDataSource(dsName)
            ?? throw new InvalidOperationException($"DataSource '{dsName}' did not register.");
        ds.Enabled = true;
        dataBand.DataSource = ds;

        dataBand.Objects.Add(MakeText($"ColPart{idx}",  0, 1, 28, 6, $"[{dsName}.ItemCode]",    fontSize: 9f));
        dataBand.Objects.Add(MakeText($"ColDesc{idx}", 28, 1, 60, 6, $"[{dsName}.Description]", fontSize: 9f));
        dataBand.Objects.Add(MakeText($"ColPal{idx}",  88, 1, 24, 6, $"[{dsName}.PalletId]",    fontSize: 8f));
        dataBand.Objects.Add(MakeText($"ColKan{idx}", 112, 1, 18, 6, $"[{dsName}.KanbanNo]",    fontSize: 8f));
        dataBand.Objects.Add(MakeText($"ColAsn{idx}", 130, 1, 18, 6, $"[{dsName}.AsnNo]",       fontSize: 8f));
        dataBand.Objects.Add(MakeText($"ColRnd{idx}", 148, 1, 14, 6, $"[{dsName}.OrderRound]",  fontSize: 8f));
        dataBand.Objects.Add(MakeText($"ColQty{idx}", 162, 1, 18, 6, $"[{dsName}.TotalQty]",    fontSize: 10f, bold: true, align: HorzAlign.Right));

        // ----- Summary band: TOTAL QTY -----
        var summaryBand = new ReportSummaryBand
        {
            Name = $"Summary{idx}",
            Height = Units.Millimeters * 12f,
        };
        page.ReportSummary = summaryBand;
        summaryBand.Objects.Add(MakeHRule($"RuleTotal{idx}", 0, 1, 180));
        summaryBand.Objects.Add(MakeText($"TotalLabel{idx}", 120, 3, 30, 6,
            "TOTAL QTY", fontSize: 9f, bold: true, align: HorzAlign.Right));
        summaryBand.Objects.Add(MakeText($"TotalValue{idx}", 152, 3, 28, 6,
            $"{order.TotalQty:N0}", fontSize: 12f, bold: true, align: HorzAlign.Right));

        // ----- Page footer: STORING NOTE strip + two signature boxes + page num -----
        var pageFooter = new PageFooterBand
        {
            Name = $"PageFooter{idx}",
            Height = Units.Millimeters * 60f,
        };
        page.PageFooter = pageFooter;

        pageFooter.Objects.Add(MakeHRule($"FootRule0_{idx}", 0, 0, 180));

        // STORING NOTE
        pageFooter.Objects.Add(MakeText($"StoreLabel{idx}", 0, 2, 180, 5,
            "STORING NOTE", fontSize: 8f, bold: true));
        var dateReceived = order.LastReceivedAt?.ToString("dd MMM yyyy HH:mm") ?? "—";
        pageFooter.Objects.Add(MakeText($"StoreDateLabel{idx}", 0, 9, 30, 5,
            "Date Received", fontSize: 8f, bold: true));
        pageFooter.Objects.Add(MakeText($"StoreDateValue{idx}", 30, 9, 60, 5,
            dateReceived, fontSize: 9f));
        var dnPlusInv = string.IsNullOrWhiteSpace(order.InvoiceNo)
            ? order.DeliveryNoteNo
            : $"{order.DeliveryNoteNo}+{order.InvoiceNo}";
        pageFooter.Objects.Add(MakeText($"StoreDnLabel{idx}", 95, 9, 40, 5,
            "Delivery Note No + Inv", fontSize: 8f, bold: true));
        pageFooter.Objects.Add(MakeText($"StoreDnValue{idx}", 135, 9, 45, 5,
            dnPlusInv, fontSize: 9f));

        pageFooter.Objects.Add(MakeHRule($"FootRule1_{idx}", 0, 18, 180));

        // Two signature blocks: left = empty for manual delivery signing
        // (Q7a), right = APPROVED FOR DELIVERY BY which carries the closer's
        // electronic signature captured at pull-close time. The box outline
        // frames the PNG; closer name + role + timestamp sit beneath it
        // instead of the generic caption.
        pageFooter.Objects.Add(MakeText($"SigDelLabel{idx}",   0, 20, 85, 5,
            "DELIVERED BY", fontSize: 8f, bold: true));
        pageFooter.Objects.Add(MakeText($"SigAppLabel{idx}",  95, 20, 85, 5,
            "APPROVED FOR DELIVERY BY", fontSize: 8f, bold: true));
        pageFooter.Objects.Add(MakeBox($"SigDelBox{idx}",  0, 26, 85, 22));
        pageFooter.Objects.Add(MakeBox($"SigAppBox{idx}", 95, 26, 85, 22));

        // PNG signature painted inside the APPROVED-BY box. Inline SVG and
        // other dataURL flavors skip silently — the box still frames the
        // closer-info caption beneath, so authorization is documented even
        // when the visual mark can't be rasterized.
        var sigPng = DecodeSignaturePng(data.Pull.SignatureSvg);
        if (sigPng is not null)
        {
            try { pageFooter.Objects.Add(MakeSignaturePicture($"AuthSig{idx}", 97, 27, 81, 20, sigPng)); }
            catch (ArgumentException) { /* malformed PNG — fall back to empty box */ }
            catch (OutOfMemoryException) { /* GDI+ throws this for invalid streams */ }
        }

        var closerCaption = string.IsNullOrWhiteSpace(data.Pull.ClosedByName)
            ? "Name / Signature / Date"
            : data.Pull.ClosedByName +
              (string.IsNullOrWhiteSpace(data.Pull.ClosedByRole)
                  ? ""
                  : " · " + data.Pull.ClosedByRole.ToUpperInvariant()) +
              (data.Pull.ClosedAt.HasValue
                  ? " · " + data.Pull.ClosedAt.Value.ToString("dd MMM yyyy HH:mm") + " UTC"
                  : "");

        pageFooter.Objects.Add(MakeText($"SigDelCap{idx}",  0, 49, 85, 4,
            "Name / Signature / Date", fontSize: 7f, align: HorzAlign.Center));
        pageFooter.Objects.Add(MakeText($"SigAppCap{idx}", 95, 49, 85, 4,
            closerCaption, fontSize: 7f, align: HorzAlign.Center));

        // Page X of Y — FastReport system vars expand at render time
        pageFooter.Objects.Add(MakeText($"PageNum{idx}", 130, 55, 50, 4,
            "Page [Page#] of [TotalPages#]", fontSize: 7f, align: HorzAlign.Right));
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
    /// Empty rectangle for manual-signature collection (Q7a). Implemented
    /// as a TextObject with all four borders so callers can stay in the
    /// MakeText / MakeHRule mental model rather than reaching for ShapeObject.
    /// </summary>
    private static TextObject MakeBox(string name, float xMm, float yMm, float wMm, float hMm)
    {
        return new TextObject
        {
            Name = name,
            Bounds = new RectangleF(
                Units.Millimeters * xMm,
                Units.Millimeters * yMm,
                Units.Millimeters * wMm,
                Units.Millimeters * hMm),
            Text = "",
            Border = { Lines = BorderLines.All, Width = 0.5f, Color = Color.Gray },
        };
    }

    /// <summary>
    /// Code128 BarcodeObject. SymbologyName drives the encoder lookup; Text
    /// is the encoded value. ShowText draws the value beneath the bars.
    /// Zoom 1.0 lets FastReport pick a default module width that fits the
    /// bounding rect. The caller pairs this with a separate caption
    /// TextObject (e.g. "P/O NO") above.
    /// </summary>
    private static BarcodeObject MakeBarcode(string name, float xMm, float yMm,
                                             float wMm, float hMm, string value)
    {
        return new BarcodeObject
        {
            Name = name,
            Bounds = new RectangleF(
                Units.Millimeters * xMm,
                Units.Millimeters * yMm,
                Units.Millimeters * wMm,
                Units.Millimeters * hMm),
            SymbologyName = "Code128",
            Text = value,
            ShowText = true,
            AutoSize = false,
            Zoom = 1.0f,
            HorzAlign = BarcodeObject.Alignment.Center,
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
        => BuildFlattenedPicture(name, xMm, yMm, wMm, hMm, pngBytes);

    /// <summary>
    /// PNG or JPEG data URL → raw bytes. SVG is skipped — System.Drawing
    /// can't parse it; the HTML preview still renders SVG warehouse logos
    /// fine, the PDF just falls back to a text-only header in that case.
    /// </summary>
    private static byte[]? DecodeLogoBytes(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        foreach (var prefix in new[] {
            "data:image/png;base64,",
            "data:image/jpeg;base64,",
            "data:image/jpg;base64,",
        })
        {
            if (raw.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                try { return Convert.FromBase64String(raw.Substring(prefix.Length)); }
                catch (FormatException) { return null; }
            }
        }
        return null;
    }

    /// <summary>
    /// Warehouse logo PictureObject — same flatten-onto-white trick as the
    /// signature builder so transparent PNG pixels don't collapse to black
    /// under PDFSimpleExport's JPEG page rasterization.
    /// </summary>
    private static PictureObject MakeLogoPicture(string name, float xMm, float yMm,
                                                 float wMm, float hMm, byte[] imageBytes)
        => BuildFlattenedPicture(name, xMm, yMm, wMm, hMm, imageBytes);

    private static PictureObject BuildFlattenedPicture(string name, float xMm, float yMm,
                                                       float wMm, float hMm, byte[] imageBytes)
    {
        Bitmap flat;
        using (var ms = new MemoryStream(imageBytes))
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
