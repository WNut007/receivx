using System.Drawing;
using FastReport;
using FastReport.Barcode;
using FastReport.Utils;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// Programmatic builder for the DSV Delivery Order (2nd report) template
/// — delivery-order-dsv.frx. Sibling of <see cref="DeliveryOrderTemplateBuilder"/>
/// (the Delivery Note); kept separate so the two layouts evolve
/// independently and the Note .frx is never touched by Order changes.
///
/// Layout (A4 portrait, one DO per page):
///   - Master DataBand "MasterDsv" iterates Orders (each Orders row is one
///     (SubInventory × ToLocation) DO). StartNewPage=true → one page per DO.
///   - Master content: logo · DELIVERY ORDER title · DELIVERY ORDER# (=
///     PullNumber) · meta grid (Order Time / Production Line / Round ||
///     From Sub / To Sub) · column header (PART | QTY ISSUE | LOCATOR |
///     VENDOR | DN/INV).
///   - Nested detail DataBand "DetailDsv" bound to the OrdersLines relation:
///     one ~14mm row per line — Part Number text + Code128 barcode beneath,
///     plus Qty / Locator / Vendor / DN-INV. Same physical-line grain as
///     the HTML preview (a Part Number can repeat with its own Locator/DN).
///   - DataFooterBand "OrderFooterDsv": TOTAL QTY under the QTY column.
///   - PageFooterBand "PageFootDsv": two signature boxes (Issued/Picked By +
///     Approved For Delivery By with the closer's PNG mark) + page number.
///
/// Bindings are FastReport expressions ("[Orders.PullNumber]",
/// "[Lines.Locator]", …) resolved at render time against the populated
/// DataSet (DoReportDataSetBuilder). Only the documented FastReport system
/// variables [Page#] / [TotalPages#] are used — [TotalRows#] does NOT exist
/// and crashes report compilation (the Stage-7 bug on the Note template).
///
/// Like the Note builder, this is the bootstrap source for a fresh
/// environment: DeliveryOrderService serializes it to disk on first miss,
/// after which the .frx is the authoritative, Designer-editable artifact.
/// </summary>
public static class DsvDeliveryOrderTemplateBuilder
{
    public const string MasterBandName  = "MasterDsv";
    public const string DetailBandName  = "DetailDsv";
    public const string OrderFooterName = "OrderFooterDsv";
    public const string PageFooterName  = "PageFootDsv";

    public static Report BuildTemplate()
    {
        var report = new Report();

        // Schema-only DataSet so DataBand.DataSource refs + the OrdersLines
        // relation exist in the dictionary when bands are added + serialized.
        var schemaDs = DoReportDataSetBuilder.Build(new DoReportData());
        report.RegisterData(schemaDs, DoReportDataSetBuilder.DataSetName);

        var ordersDs = report.GetDataSource(DoReportDataSetBuilder.OrdersTableName)
            ?? throw new InvalidOperationException("Orders data source did not register.");
        var linesDs = report.GetDataSource(DoReportDataSetBuilder.LinesTableName)
            ?? throw new InvalidOperationException("Lines data source did not register.");
        ordersDs.Enabled = true;
        linesDs.Enabled  = true;

        // Construct the master→detail Relation directly with the dictionary's
        // DataSourceBase objects so it serializes as a real <Relation> and
        // the detail band iterates only its DO's lines (see the cross-product
        // bug note in DeliveryOrderTemplateBuilder).
        var ordersLinesRel = new FastReport.Data.Relation
        {
            Name = DoReportDataSetBuilder.OrdersLinesRelationName,
            ParentDataSource = ordersDs,
            ChildDataSource  = linesDs,
            ParentColumns    = new[] { nameof(DoOrder.DeliveryNoteNo) },
            ChildColumns     = new[] { nameof(DoOrder.DeliveryNoteNo) },
        };
        report.Dictionary.Relations.Add(ordersLinesRel);

        var page = new ReportPage
        {
            Name = "DsvDeliveryOrderPage",
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
    // Master band — title strip + meta grid + column header. ~46mm.
    // Reprints per Orders row (each row = one page).
    // ------------------------------------------------------------------
    private static DataBand BuildMasterBand(FastReport.Data.DataSourceBase ordersDs)
    {
        var master = new DataBand
        {
            Name = MasterBandName,
            DataSource = ordersDs,
            StartNewPage = true,
            Height = Units.Millimeters * 46f,
        };

        // ----- (1) Top strip: logo · DELIVERY ORDER · DELIVERY ORDER# -----
        master.Objects.Add(MakeDataPicture("WhLogo", 0, 0, 35, 14,
            DoReportDataSetBuilder.OrdersTableName + ".WarehouseLogoBytes"));
        master.Objects.Add(MakeText("DoTitle", 50, 2, 80, 9,
            "DELIVERY ORDER", fontSize: 18f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeText("DoNoLabel", 130, 1, 50, 4,
            "DELIVERY ORDER#", fontSize: 7f, align: HorzAlign.Right));
        master.Objects.Add(MakeText("DoNoValue", 130, 5, 50, 6,
            "[Orders.PullNumber]", fontSize: 12f, bold: true, align: HorzAlign.Right));

        master.Objects.Add(MakeHRule("Rule1", 0, 15, 180));

        // ----- (2) Meta grid: 3 left rows / 2 right rows -----
        // Left:  ORDER TIME · PRODUCTION LINE · ROUND
        // Right: FROM SUB · TO SUB
        const float y0 = 18f, rowH = 6f;
        master.Objects.Add(MakeText("MetaLL0", 0, y0,            35, 5, "ORDER TIME",      8f, bold: true));
        master.Objects.Add(MakeText("MetaLV0", 35, y0,          60, 5, "[Orders.OrderTimeText]", 10f));
        master.Objects.Add(MakeText("MetaLL1", 0, y0 + rowH,    35, 5, "PRODUCTION LINE", 8f, bold: true));
        master.Objects.Add(MakeText("MetaLV1", 35, y0 + rowH,   60, 5, "[Orders.ProductionLine]", 10f));
        master.Objects.Add(MakeText("MetaLL2", 0, y0 + rowH * 2, 35, 5, "ROUND",          8f, bold: true));
        master.Objects.Add(MakeText("MetaLV2", 35, y0 + rowH * 2, 145, 5, "[Orders.RoundDisplay]", 10f));

        master.Objects.Add(MakeText("MetaRL0", 100, y0,         25, 5, "FROM SUB",        8f, bold: true));
        master.Objects.Add(MakeText("MetaRV0", 125, y0,         55, 5, "[Orders.SubInventory]", 11f, bold: true));
        master.Objects.Add(MakeText("MetaRL1", 100, y0 + rowH,  25, 5, "TO SUB",          8f, bold: true));
        master.Objects.Add(MakeText("MetaRV1", 125, y0 + rowH,  55, 5, "[Orders.ToLocation]", 11f, bold: true));

        master.Objects.Add(MakeHRule("Rule2", 0, 37, 180));

        // ----- (3) Column header: PART | QTY ISSUE | LOCATOR | VENDOR | DN/INV -----
        // Widths (180mm): PART 42 · QTY 20 · LOCATOR 50 · VENDOR 35 · DN/INV 33
        master.Objects.Add(MakeText("HdrPart",   0,  39, 42, 6, "PART NUMBER",   8f, bold: true));
        master.Objects.Add(MakeText("HdrQty",   42,  39, 20, 6, "QTY ISSUE",     8f, bold: true, align: HorzAlign.Right));
        master.Objects.Add(MakeText("HdrLoc",   62,  39, 50, 6, "LOCATOR",       8f, bold: true));
        master.Objects.Add(MakeText("HdrVendor",112, 39, 35, 6, "VENDOR",        8f, bold: true));
        master.Objects.Add(MakeText("HdrDnInv", 147, 39, 33, 6, "DN/INV NUMBER", 8f, bold: true));
        master.Objects.Add(MakeHRule("Rule3", 0, 45, 180));

        return master;
    }

    // ------------------------------------------------------------------
    // Detail band — ~14mm: Part Number text on top, Code128 beneath, with
    // Qty / Locator / Vendor / DN-INV top-aligned alongside.
    // ------------------------------------------------------------------
    private static DataBand BuildDetailBand(FastReport.Data.DataSourceBase linesDs)
    {
        var detail = new DataBand
        {
            Name = DetailBandName,
            DataSource = linesDs,
            Height = Units.Millimeters * 14f,
        };

        detail.Objects.Add(MakeText("ColPart", 0, 0.5f, 42, 4, "[Lines.ItemCode]", 9f, bold: true));
        // Code128 under the part number; ShowText prints the value beneath
        // the bars (the HTML preview's caption-below-bars equivalent).
        detail.Objects.Add(MakeBarcode("ColBc", 0, 5f, 38, 7.5f, "[Lines.ItemCode]"));

        detail.Objects.Add(MakeText("ColQty",    42,  0.5f, 20, 5,  "[Lines.TotalQty]", 10f, bold: true, align: HorzAlign.Right));
        detail.Objects.Add(MakeText("ColLoc",    62,  0.5f, 50, 12, "[Lines.Locator]",    8f));
        detail.Objects.Add(MakeText("ColVendor", 112, 0.5f, 35, 12, "[Lines.VendorName]", 8f));
        detail.Objects.Add(MakeText("ColDnInv",  147, 0.5f, 33, 12, "[Lines.DnInv]",      8f));

        detail.Objects.Add(MakeHRule("RowRule", 0, 13.5f, 180, thin: true));

        return detail;
    }

    // ------------------------------------------------------------------
    // Per-master DataFooter — TOTAL QTY under the QTY ISSUE column.
    // ------------------------------------------------------------------
    private static DataFooterBand BuildOrderFooter()
    {
        var footer = new DataFooterBand
        {
            Name = OrderFooterName,
            Height = Units.Millimeters * 12f,
        };
        footer.Objects.Add(MakeHRule("RuleTotal", 0, 1, 180));
        footer.Objects.Add(MakeText("TotalLabel", 0, 3, 40, 6,
            "TOTAL QTY", fontSize: 9f, bold: true, align: HorzAlign.Right));
        footer.Objects.Add(MakeText("TotalValue", 42, 3, 20, 6,
            "[Orders.TotalQty]", fontSize: 12f, bold: true, align: HorzAlign.Right));
        return footer;
    }

    // ------------------------------------------------------------------
    // PageFooter — two signature boxes + page number, repeats per page.
    // ------------------------------------------------------------------
    private static PageFooterBand BuildPageFooter()
    {
        var footer = new PageFooterBand
        {
            Name = PageFooterName,
            Height = Units.Millimeters * 42f,
        };

        footer.Objects.Add(MakeHRule("FootRule0", 0, 0, 180));

        footer.Objects.Add(MakeText("SigDelLabel", 0, 4, 85, 5,
            "ISSUED / PICKED BY", fontSize: 8f, bold: true));
        footer.Objects.Add(MakeText("SigAppLabel", 95, 4, 85, 5,
            "APPROVED FOR DELIVERY BY", fontSize: 8f, bold: true));

        footer.Objects.Add(MakeBox("SigDelBox", 0, 10, 85, 22));
        footer.Objects.Add(MakeBox("SigAppBox", 95, 10, 85, 22));
        // PNG signature mark bound to Orders.SignatureBytes (pre-flattened
        // onto white server-side). Inline-SVG / undecodable → DBNull → blank.
        footer.Objects.Add(MakeDataPicture("AuthSig", 97, 11, 81, 20,
            DoReportDataSetBuilder.OrdersTableName + ".SignatureBytes"));

        footer.Objects.Add(MakeText("SigDelCap", 0, 33, 85, 4,
            "Name / Signature / Date", fontSize: 7f, align: HorzAlign.Center));
        footer.Objects.Add(MakeText("SigAppCap", 95, 33, 85, 4,
            "[Orders.ClosedByName] · [Orders.ClosedByRole] · [Orders.ClosedAt]",
            fontSize: 7f, align: HorzAlign.Center));

        footer.Objects.Add(MakeText("PageNum", 130, 38, 50, 4,
            "Page [Page#] of [TotalPages#]", fontSize: 7f, align: HorzAlign.Right));

        return footer;
    }

    // ------------------------------------------------------------------
    // Object builders — self-contained copy (matches the Note builder's
    // convention of not sharing, so the two templates stay decoupled).
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

    private static LineObject MakeHRule(string name, float xMm, float yMm, float wMm, bool thin = false)
    {
        return new LineObject
        {
            Name = name,
            Bounds = new RectangleF(
                Units.Millimeters * xMm,
                Units.Millimeters * yMm,
                Units.Millimeters * wMm,
                0),
            Border = { Lines = BorderLines.Top, Width = thin ? 0.25f : 0.5f },
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
            HorzAlign = BarcodeObject.Alignment.Left,
        };
    }

    private static PictureObject MakeDataPicture(string name, float xMm, float yMm,
                                                 float wMm, float hMm, string dataColumn)
    {
        return new PictureObject
        {
            Name = name,
            Bounds = new RectangleF(
                Units.Millimeters * xMm,
                Units.Millimeters * yMm,
                Units.Millimeters * wMm,
                Units.Millimeters * hMm),
            SizeMode = System.Windows.Forms.PictureBoxSizeMode.Zoom,
            DataColumn = dataColumn,
        };
    }
}
