using System.Drawing;
using FastReport;
using FastReport.Barcode;
using FastReport.Utils;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// Path B Stage 3 — programmatic builder for the designer-driven
/// delivery-order.frx template.
///
/// Produces a single-page A4 master-detail Report where:
///   - Master DataBand "MasterOrders" iterates the Orders table; each row
///     triggers a new page (StartNewPage=true).
///   - Master content (logo strip, DELIVERY NOTE title + DN#, address
///     strip, 5-row info grid, 3 Code128 barcodes, column header row)
///     lives INSIDE the master band — it reprints per page because each
///     master row is one page.
///   - Nested detail DataBand "DetailLines" is added as a sub-band of
///     master via master.Bands.Add(detail) and bound to the OrdersLines
///     relation so it iterates only the lines belonging to the current DO.
///   - Per-master DataFooterBand "OrderFooter" carries TOTAL QTY; it
///     prints after the detail band finishes for the current master row.
///   - PageFooterBand "PageFoot" carries the STORING NOTE strip, two
///     signature boxes, and the "Page X of Y" caption. It auto-repeats
///     per physical page so multi-page DOs (>~13 lines) still get the
///     STORING NOTE + sigs at the bottom.
///
/// Bindings are FastReport expression text such as "[Orders.WarehouseCode]"
/// — resolved at render time against the populated DataSet that Stage 4
/// will register via Report.RegisterData(populatedDataSet).
///
/// The schema-only DataSet from DoReportDataSetBuilder.Build(new DoReportData())
/// is registered here so the bands have typed DataSource refs to bind to
/// when the .frx is serialized in Stage 4. At runtime, the same shape
/// gets re-registered with real rows.
///
/// Logo + signature PictureObjects are intentionally NOT added in Stage 3
/// (the handoff plan reserves byte[] picture binding for Stage 6). The
/// generated PDF will lack the logo + signature mark until Stage 6 wires
/// them — the rest of the DSV layout is complete.
/// </summary>
public static class DeliveryOrderTemplateBuilder
{
    /// <summary>Master band name. .frx and runtime refer to it by this name.</summary>
    public const string MasterBandName = "MasterOrders";

    /// <summary>Detail (Lines) band name.</summary>
    public const string DetailBandName = "DetailLines";

    /// <summary>Per-master DataFooter band name.</summary>
    public const string OrderFooterName = "OrderFooter";

    /// <summary>Page-level footer name (STORING NOTE + sigs + page#).</summary>
    public const string PageFooterName = "PageFoot";

    public static Report BuildTemplate()
    {
        var report = new Report();

        // Register schema-only DataSet so DataBand.DataSource refs and the
        // OrdersLines relation exist in the dictionary when bands are added
        // and when the .frx is later serialized.
        var schemaDs = DoReportDataSetBuilder.Build(new DoReportData());
        report.RegisterData(schemaDs, DoReportDataSetBuilder.DataSetName);

        var ordersDs = report.GetDataSource(DoReportDataSetBuilder.OrdersTableName)
            ?? throw new InvalidOperationException("Orders data source did not register.");
        var linesDs = report.GetDataSource(DoReportDataSetBuilder.LinesTableName)
            ?? throw new InvalidOperationException("Lines data source did not register.");
        ordersDs.Enabled = true;
        linesDs.Enabled  = true;

        var page = new ReportPage
        {
            Name = "DeliveryOrderPage",
            PaperWidth  = 210,
            PaperHeight = 297,
            LeftMargin = 15, RightMargin = 15, TopMargin = 15, BottomMargin = 15,
        };
        report.Pages.Add(page);

        var master = BuildMasterBand(ordersDs);
        page.AddChild(master);

        var detail = BuildDetailBand(linesDs);
        detail.Relation = report.Dictionary.Relations.FindByName(
            DoReportDataSetBuilder.OrdersLinesRelationName);
        master.Bands.Add(detail);

        master.Footer = BuildOrderFooter();

        page.PageFooter = BuildPageFooter();

        return report;
    }

    // ------------------------------------------------------------------
    // Master band — DSV title strip + info grid + barcodes + column header.
    // Total height ~102mm. Sits inside the master DataBand so it reprints
    // per Orders row (each row = new page).
    // ------------------------------------------------------------------
    private static DataBand BuildMasterBand(FastReport.Data.DataSourceBase ordersDs)
    {
        var master = new DataBand
        {
            Name = MasterBandName,
            DataSource = ordersDs,
            StartNewPage = true,
            Height = Units.Millimeters * 102f,
        };

        // ----- (1) Top strip: [logo area] · DELIVERY NOTE title · DN# -----
        // Logo PictureObject deferred to Stage 6 — 0..35mm × 14mm left of
        // the title is left empty so Stage 6 can drop a PictureObject in.
        master.Objects.Add(MakeText("DnTitle", 50, 2, 80, 9,
            "DELIVERY NOTE", fontSize: 18f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeText("DnNoLabel", 130, 1, 50, 4,
            "Delivery Note No.", fontSize: 7f, align: HorzAlign.Right));
        master.Objects.Add(MakeText("DnNoValue", 130, 5, 50, 6,
            "[Orders.DeliveryNoteNo]", fontSize: 12f, bold: true, align: HorzAlign.Right));
        // [Row#] is FastReport's 1-based row counter on the current data band.
        master.Objects.Add(MakeText("DnSubIdx", 130, 11, 50, 4,
            "DO [Row#] of [TotalRows#]", fontSize: 7f, align: HorzAlign.Right));

        master.Objects.Add(MakeHRule("Rule1", 0, 15, 180));

        // ----- (2) Address strip: warehouse (left) + Delivery To (right) -----
        master.Objects.Add(MakeText("WhBlock", 0, 17, 90, 12,
            "[Orders.WarehouseCode] · [Orders.WarehouseName]\n[Orders.WarehouseAddress]",
            fontSize: 9f));
        master.Objects.Add(MakeText("DeliverToLabel", 95, 17, 85, 4,
            "DELIVERY TO", fontSize: 7f, bold: true));
        master.Objects.Add(MakeText("DeliverToValue", 95, 21, 85, 8,
            "[Orders.WarehouseAddress]", fontSize: 9f));

        master.Objects.Add(MakeHRule("Rule2", 0, 30, 180));

        // ----- (3) Info grid: 5 rows × 2 cols × 6mm -----
        // Left col: P/O NO · PRS NO · ORDER TYPE · DROP ID · DATE OF DELIVERY
        // Right col: VENDOR ID · VENDOR · FROM · TO · VENDOR INVOICE
        // ORDER TYPE + DROP ID are not in the current DTO — emit em-dash
        // placeholders so the designer can wire them in Stage 8 if needed.
        var infoRows = new (string LL, string LV, string RL, string RV)[]
        {
            ("P/O NO",           "[Orders.HeaderPoNumber]",
             "VENDOR ID",        "[Orders.VendorCode]"),
            ("PRS NO",           "[Orders.PullNumber]",
             "VENDOR",           "[Orders.VendorName]"),
            ("ORDER TYPE",       "—",
             "FROM",             "[Orders.SubInventory]"),
            ("DROP ID",          "—",
             "TO",               "[Orders.ToLocation]"),
            ("DATE OF DELIVERY", "[Orders.ClosedAt]",
             "VENDOR INVOICE",   "[Orders.InvoiceNo]"),
        };
        const float gridY0 = 32f;
        const float rowH   = 6f;
        for (int r = 0; r < infoRows.Length; r++)
        {
            var row = infoRows[r];
            var y = gridY0 + r * rowH;
            master.Objects.Add(MakeText($"GridLL{r}",  0, y, 32, 5, row.LL, fontSize: 8f, bold: true));
            master.Objects.Add(MakeText($"GridLV{r}", 32, y, 58, 5, row.LV, fontSize: 10f));
            master.Objects.Add(MakeText($"GridRL{r}", 95, y, 32, 5, row.RL, fontSize: 8f, bold: true));
            master.Objects.Add(MakeText($"GridRV{r}",127, y, 53, 5, row.RV, fontSize: 10f));
        }

        master.Objects.Add(MakeHRule("Rule3", 0, 63, 180));

        // ----- (4) Code128 barcodes: PO · PRS · DN -----
        // BarcodeObject.Text holds an expression; FastReport resolves it
        // against the current row at render time before encoding the bars.
        master.Objects.Add(MakeText("BcPoCap", 0, 65, 55, 4,
            "P/O NO", fontSize: 7f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeBarcode("BcPo", 0, 69, 55, 22, "[Orders.HeaderPoNumber]"));

        master.Objects.Add(MakeText("BcPrsCap", 62, 65, 55, 4,
            "PRS NO", fontSize: 7f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeBarcode("BcPrs", 62, 69, 55, 22, "[Orders.PullNumber]"));

        master.Objects.Add(MakeText("BcDnCap", 124, 65, 55, 4,
            "DELIVERY NOTE", fontSize: 7f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeBarcode("BcDn", 124, 69, 55, 22, "[Orders.DeliveryNoteNo]"));

        master.Objects.Add(MakeHRule("Rule4", 0, 93, 180));

        // ----- (5) Column header row -----
        // Widths: PART 28 · DESC 60 · PALLET 24 · KANBAN 18 · ASN 18 · ROUND 14 · QTY 18 = 180
        master.Objects.Add(MakeText("HdrPart",  0,  95, 28, 6, "PART NUMBER", fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrDesc", 28,  95, 60, 6, "DESCRIPTION", fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrPal",  88,  95, 24, 6, "PALLET",      fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrKan", 112,  95, 18, 6, "KANBAN",      fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrAsn", 130,  95, 18, 6, "ASN",         fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrRnd", 148,  95, 14, 6, "ROUND",       fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrQty", 162,  95, 18, 6, "QTY",         fontSize: 8f, bold: true, align: HorzAlign.Right));
        master.Objects.Add(MakeHRule("Rule5", 0, 101, 180));

        return master;
    }

    // ------------------------------------------------------------------
    // Detail band — one 8mm row per Lines entry. Master-detail relation
    // is assigned by the caller via detail.Relation after the dictionary
    // has registered the OrdersLines DataRelation.
    // ------------------------------------------------------------------
    private static DataBand BuildDetailBand(FastReport.Data.DataSourceBase linesDs)
    {
        var detail = new DataBand
        {
            Name = DetailBandName,
            DataSource = linesDs,
            Height = Units.Millimeters * 8f,
        };

        detail.Objects.Add(MakeText("ColPart",  0, 1, 28, 6, "[Lines.ItemCode]",    fontSize: 9f));
        detail.Objects.Add(MakeText("ColDesc", 28, 1, 60, 6, "[Lines.Description]", fontSize: 9f));
        detail.Objects.Add(MakeText("ColPal",  88, 1, 24, 6, "[Lines.PalletId]",    fontSize: 8f));
        detail.Objects.Add(MakeText("ColKan", 112, 1, 18, 6, "[Lines.KanbanNo]",    fontSize: 8f));
        detail.Objects.Add(MakeText("ColAsn", 130, 1, 18, 6, "[Lines.AsnNo]",       fontSize: 8f));
        detail.Objects.Add(MakeText("ColRnd", 148, 1, 14, 6, "[Lines.OrderRound]",  fontSize: 8f));
        detail.Objects.Add(MakeText("ColQty", 162, 1, 18, 6, "[Lines.TotalQty]",    fontSize: 10f, bold: true, align: HorzAlign.Right));

        return detail;
    }

    // ------------------------------------------------------------------
    // Per-master DataFooter — TOTAL QTY for the current Orders row. Prints
    // once after the detail band finishes iterating, before the next
    // master row triggers its StartNewPage.
    // ------------------------------------------------------------------
    private static DataFooterBand BuildOrderFooter()
    {
        var footer = new DataFooterBand
        {
            Name = OrderFooterName,
            Height = Units.Millimeters * 12f,
        };
        footer.Objects.Add(MakeHRule("RuleTotal", 0, 1, 180));
        footer.Objects.Add(MakeText("TotalLabel", 120, 3, 30, 6,
            "TOTAL QTY", fontSize: 9f, bold: true, align: HorzAlign.Right));
        footer.Objects.Add(MakeText("TotalValue", 152, 3, 28, 6,
            "[Orders.TotalQty]", fontSize: 12f, bold: true, align: HorzAlign.Right));
        return footer;
    }

    // ------------------------------------------------------------------
    // PageFooter — repeats at the bottom of every physical page, so a DO
    // that overflows past one page still gets STORING NOTE + sigs at the
    // bottom of each. Signature picture rendering deferred to Stage 6;
    // for Stage 3 the boxes are framed and the captions bind text only.
    // ------------------------------------------------------------------
    private static PageFooterBand BuildPageFooter()
    {
        var footer = new PageFooterBand
        {
            Name = PageFooterName,
            Height = Units.Millimeters * 60f,
        };

        footer.Objects.Add(MakeHRule("FootRule0", 0, 0, 180));

        // STORING NOTE strip
        footer.Objects.Add(MakeText("StoreLabel", 0, 2, 180, 5,
            "STORING NOTE", fontSize: 8f, bold: true));
        footer.Objects.Add(MakeText("StoreDateLabel", 0, 9, 30, 5,
            "Date Received", fontSize: 8f, bold: true));
        footer.Objects.Add(MakeText("StoreDateValue", 30, 9, 60, 5,
            "[Orders.LastReceivedAt]", fontSize: 9f));
        footer.Objects.Add(MakeText("StoreDnLabel", 95, 9, 40, 5,
            "Delivery Note No + Inv", fontSize: 8f, bold: true));
        footer.Objects.Add(MakeText("StoreDnValue", 135, 9, 45, 5,
            "[Orders.DeliveryNoteNo]+[Orders.InvoiceNo]", fontSize: 9f));

        footer.Objects.Add(MakeHRule("FootRule1", 0, 18, 180));

        // Two signature boxes — left is manual fill on paper, right is
        // APPROVED FOR DELIVERY BY and will receive the PNG signature
        // PictureObject in Stage 6. Caption beneath is text-only here.
        footer.Objects.Add(MakeText("SigDelLabel",  0, 20, 85, 5,
            "DELIVERED BY", fontSize: 8f, bold: true));
        footer.Objects.Add(MakeText("SigAppLabel", 95, 20, 85, 5,
            "APPROVED FOR DELIVERY BY", fontSize: 8f, bold: true));
        footer.Objects.Add(MakeBox("SigDelBox",  0, 26, 85, 22));
        footer.Objects.Add(MakeBox("SigAppBox", 95, 26, 85, 22));
        footer.Objects.Add(MakeText("SigDelCap",  0, 49, 85, 4,
            "Name / Signature / Date", fontSize: 7f, align: HorzAlign.Center));
        footer.Objects.Add(MakeText("SigAppCap", 95, 49, 85, 4,
            "[Orders.ClosedByName] · [Orders.ClosedByRole] · [Orders.ClosedAt]",
            fontSize: 7f, align: HorzAlign.Center));

        // FastReport system variables expand to the current page index and
        // the prepared report's page count at render time.
        footer.Objects.Add(MakeText("PageNum", 130, 55, 50, 4,
            "Page [Page#] of [TotalPages#]", fontSize: 7f, align: HorzAlign.Right));

        return footer;
    }

    // ------------------------------------------------------------------
    // Tiny builders. Duplicated from DeliveryOrderService rather than
    // shared so the template builder stays self-contained; Stage 4 may
    // consolidate them into a shared helper if the cutover keeps both
    // code paths around for a while.
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

    private static BarcodeObject MakeBarcode(string name, float xMm, float yMm,
                                             float wMm, float hMm, string textExpr)
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
            Text = textExpr,
            ShowText = true,
            AutoSize = false,
            Zoom = 1.0f,
            HorzAlign = BarcodeObject.Alignment.Center,
        };
    }
}
