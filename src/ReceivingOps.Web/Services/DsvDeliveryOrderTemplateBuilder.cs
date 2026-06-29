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
        // Column header repeats on every page of a multi-page DO.
        detail.Header = BuildDetailHeader();
        master.Bands.Add(detail);

        master.Footer = BuildOrderFooter();
        page.PageFooter = BuildPageFooter();

        return report;
    }

    // ------------------------------------------------------------------
    // Master band — zero-height driver. It only iterates Orders (one row =
    // one DO) and carries StartNewPage so each DO opens on a fresh page.
    // The visible doc header lives in its DataHeaderBand (BuildMasterHeader)
    // so it repeats on every page of a multi-page DO; the column header is
    // the detail band's DataHeader (BuildDetailHeader). Both repeat → page
    // 2+ of a DO shows the complete header (logo · DO# · meta · columns).
    // ------------------------------------------------------------------
    private static DataBand BuildMasterBand(FastReport.Data.DataSourceBase ordersDs)
    {
        var master = new DataBand
        {
            Name = MasterBandName,
            DataSource = ordersDs,
            StartNewPage = true,
            Height = 0f,
        };
        master.Header = BuildMasterHeader();
        return master;
    }

    // ------------------------------------------------------------------
    // Master DataHeader — the document header (logo · DELIVERY ORDER title ·
    // DELIVERY ORDER# · meta grid ORDER TIME/PRODUCTION LINE/ROUND ||
    // FROM SUB/TO SUB). RepeatOnEveryPage=true + the band sits in the master
    // (Orders) context, so its [Orders.*] bindings resolve to the current DO
    // on every page — including page 1 (a DataHeader prints after the row is
    // read, unlike a PageHeader). ~37mm.
    // ------------------------------------------------------------------
    private static DataHeaderBand BuildMasterHeader()
    {
        var header = new DataHeaderBand
        {
            Name = "MasterHeaderDsv",
            Height = Units.Millimeters * 37f,
            RepeatOnEveryPage = true,
        };

        // ----- (1) Top strip: logo · DELIVERY ORDER · DELIVERY ORDER# -----
        header.Objects.Add(MakeDataPicture("WhLogo", 0, 0, 35, 14,
            DoReportDataSetBuilder.OrdersTableName + ".WarehouseLogoBytes"));
        header.Objects.Add(MakeText("DoTitle", 50, 2, 80, 9,
            "DELIVERY ORDER", fontSize: 18f, bold: true, align: HorzAlign.Center));
        header.Objects.Add(MakeText("DoNoLabel", 130, 1, 50, 4,
            "DELIVERY ORDER#", fontSize: 7f, align: HorzAlign.Right));
        header.Objects.Add(MakeText("DoNoValue", 130, 5, 50, 6,
            "[Orders.PullNumber]", fontSize: 12f, bold: true, align: HorzAlign.Right));

        header.Objects.Add(MakeHRule("Rule1", 0, 15, 180));

        // ----- (2) Meta grid: 3 left rows / 2 right rows -----
        // Left:  ORDER TIME · PRODUCTION LINE · ROUND
        // Right: FROM SUB · TO SUB
        const float y0 = 18f, rowH = 6f;
        header.Objects.Add(MakeText("MetaLL0", 0, y0,            35, 5, "ORDER TIME",      8f, bold: true));
        header.Objects.Add(MakeText("MetaLV0", 35, y0,          60, 5, "[Orders.OrderTimeText]", 10f));
        header.Objects.Add(MakeText("MetaLL1", 0, y0 + rowH,    35, 5, "PRODUCTION LINE", 8f, bold: true));
        header.Objects.Add(MakeText("MetaLV1", 35, y0 + rowH,   60, 5, "[Orders.ProductionLine]", 10f));
        header.Objects.Add(MakeText("MetaLL2", 0, y0 + rowH * 2, 35, 5, "ROUND",          8f, bold: true));
        header.Objects.Add(MakeText("MetaLV2", 35, y0 + rowH * 2, 145, 5, "[Orders.RoundDisplay]", 10f));

        header.Objects.Add(MakeText("MetaRL0", 100, y0,         25, 5, "FROM SUB",        8f, bold: true));
        header.Objects.Add(MakeText("MetaRV0", 125, y0,         55, 5, "[Orders.SubInventory]", 11f, bold: true));
        header.Objects.Add(MakeText("MetaRL1", 100, y0 + rowH,  25, 5, "TO SUB",          8f, bold: true));
        header.Objects.Add(MakeText("MetaRV1", 125, y0 + rowH,  55, 5, "[Orders.ToLocation]", 11f, bold: true));

        return header;
    }

    // ------------------------------------------------------------------
    // Detail DataHeader — the column header (PART | QTY ISSUE | LOCATOR |
    // VENDOR | DN/INV). RepeatOnEveryPage=true so a DO whose lines overflow
    // onto page 2+ keeps the table header on every page. Lives on the
    // detail band (not the master) so it prints below the doc header on the
    // first page and at the top of each continuation page. ~8mm.
    // Widths (180mm): PART 42 · QTY 20 · LOCATOR 50 · VENDOR 35 · DN/INV 33
    // ------------------------------------------------------------------
    private static DataHeaderBand BuildDetailHeader()
    {
        var header = new DataHeaderBand
        {
            Name = "DetailHeaderDsv",
            Height = Units.Millimeters * 8f,
            RepeatOnEveryPage = true,
        };

        header.Objects.Add(MakeHRule("Rule2", 0, 0, 180));
        header.Objects.Add(MakeText("HdrPart",   0,  2, 42, 6, "PART NUMBER",   8f, bold: true));
        header.Objects.Add(MakeText("HdrQty",   42,  2, 20, 6, "QTY ISSUE",     8f, bold: true, align: HorzAlign.Right));
        header.Objects.Add(MakeText("HdrLoc",   62,  2, 50, 6, "LOCATOR",       8f, bold: true));
        header.Objects.Add(MakeText("HdrVendor",112, 2, 35, 6, "VENDOR",        8f, bold: true));
        header.Objects.Add(MakeText("HdrDnInv", 147, 2, 33, 6, "DN/INV NUMBER", 8f, bold: true));
        header.Objects.Add(MakeHRule("Rule3", 0, 8, 180));

        return header;
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
    // Per-master DataFooter — TOTAL QTY + the two signature boxes (Issued/
    // Picked By + Approved For Delivery By with the closer's PNG mark).
    // Because this is the master's DataFooter it prints once per DO, after
    // the last line — i.e. on the DO's LAST page only. The signatures used
    // to live in the PageFooter (every page); moved here so they sign off
    // the document once. [Orders.*] resolves to the current DO (master
    // context). ~50mm.
    // ------------------------------------------------------------------
    private static DataFooterBand BuildOrderFooter()
    {
        var footer = new DataFooterBand
        {
            Name = OrderFooterName,
            Height = Units.Millimeters * 50f,
        };
        footer.Objects.Add(MakeHRule("RuleTotal", 0, 1, 180));
        footer.Objects.Add(MakeText("TotalLabel", 0, 3, 40, 6,
            "TOTAL QTY", fontSize: 9f, bold: true, align: HorzAlign.Right));
        footer.Objects.Add(MakeText("TotalValue", 42, 3, 20, 6,
            "[Orders.TotalQty]", fontSize: 12f, bold: true, align: HorzAlign.Right));

        footer.Objects.Add(MakeHRule("FootRule0", 0, 13, 180));

        // 3-party digital signature boxes (Customer / Warehouse / Production),
        // per-pull, denormalized onto every Orders row. Replaces the old 2-box
        // footer + pull-close PNG (decision #6). Each box binds its caption
        // column (CustomerSig/WarehouseSig/ProductionSig) — empty ⇒ blank box.
        AddSignatureBoxes(footer);

        return footer;
    }

    // ------------------------------------------------------------------
    // PageFooter — page number only, repeats per page. The signatures moved
    // to the per-DO DataFooter (last page only); page numbering stays here.
    // ------------------------------------------------------------------
    private static PageFooterBand BuildPageFooter()
    {
        var footer = new PageFooterBand
        {
            Name = PageFooterName,
            Height = Units.Millimeters * 8f,
        };

        footer.Objects.Add(MakeText("PageNum", 130, 2, 50, 4,
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

    // 3-party signature boxes at y=15..48mm across 180mm content width.
    // Each: bold label, bordered box, bound caption (CustomerSig/WarehouseSig/
    // ProductionSig — empty ⇒ blank), and a "Name / Date" sub-caption.
    private static void AddSignatureBoxes(BandBase band)
    {
        var parties = new[]
        {
            (x: 0f,     label: "CUSTOMER",   col: "CustomerSig"),
            (x: 61.5f,  label: "WAREHOUSE",  col: "WarehouseSig"),
            (x: 123f,   label: "PRODUCTION", col: "ProductionSig"),
        };
        foreach (var p in parties)
        {
            var key = p.label[0] + p.label.Substring(1).ToLowerInvariant();
            band.Objects.Add(MakeText($"Sig{key}Label", p.x, 15, 57, 5, p.label, fontSize: 8f, bold: true));
            band.Objects.Add(MakeBox($"Sig{key}Box", p.x, 21, 57, 22));
            band.Objects.Add(MakeText($"Sig{key}Val", p.x, 27, 57, 10,
                $"[Orders.{p.col}]", fontSize: 9f, align: HorzAlign.Center));
            band.Objects.Add(MakeText($"Sig{key}Cap", p.x, 44, 57, 4,
                "Name / Date", fontSize: 7f, align: HorzAlign.Center));
        }
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
