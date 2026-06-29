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

        // FastReport's RegisterData(DataSet) populates table data sources but
        // does NOT carry System.Data.DataRelations into
        // report.Dictionary.Relations in a form that survives Save. The
        // overload RegisterData(DataRelation, name) silently fails to
        // serialize because the System.Data.DataRelation's parent/child
        // names ("Orders" / "Lines") don't match the dictionary's prefixed
        // table names ("DoReport.Orders" / "DoReport.Lines").
        //
        // Without a real <Relation> in the .frx Dictionary, the detail
        // band's Relation="OrdersLines" attribute is a dangling string
        // reference: on Load it resolves to null, and Prepare iterates
        // EVERY Lines row per master row — a cross-product where each
        // DO page shows every other DO's lines.
        //
        // Construct the FastReport.Data.Relation directly with the dict's
        // actual DataSourceBase objects so Add() produces a serializable
        // entry. The Relation now appears as <Relation> in the .frx and
        // resolves correctly on Load + Prepare.
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

        // ----- (1) Top strip: warehouse logo · DELIVERY NOTE title · DN# -----
        // Stage 6: PictureObject bound to Orders.WarehouseLogoBytes (PNG
        // pre-flattened onto a white 24bpp canvas server-side — see
        // DoReportDataSetBuilder.DecodeAndFlattenImage). Zoom SizeMode keeps
        // logos with mixed aspect ratios inside the 35×14mm slot without
        // distortion; null logos collapse to a blank space.
        master.Objects.Add(MakeDataPicture("WhLogo", 0, 0, 35, 14,
            DoReportDataSetBuilder.OrdersTableName + ".WarehouseLogoBytes"));
        master.Objects.Add(MakeText("DnTitle", 50, 2, 80, 9,
            "DELIVERY NOTE", fontSize: 18f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeText("DnNoLabel", 130, 1, 50, 4,
            "Delivery Note No.", fontSize: 7f, align: HorzAlign.Right));
        master.Objects.Add(MakeText("DnNoValue", 130, 5, 50, 6,
            "[Orders.DeliveryNoteNo]", fontSize: 12f, bold: true, align: HorzAlign.Right));
        // Stage 7 fix: the original "DO [Row#] of [TotalRows#]" subtitle
        // referenced a non-existent FastReport system variable (TotalRows#
        // — only Row#, Page#, TotalPages# are in the public surface).
        // Compilation of any expression in the template would fail the
        // whole report. Dropped entirely; the DN value above uniquely
        // identifies which DO this is for the reader.

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
            // Stage 8 — widened right-column VALUE cell (RV) 53 → 65mm by
            // shrinking right-column LABEL cell (RL) 32 → 20mm. The longer
            // VendorName values (e.g. "NHK SPRING (THAILAND) CO., LTD.",
            // 30 chars ~60mm at 10pt) used to wrap at the 53mm boundary,
            // triggering a CanGrow cascade in the master band that bled a
            // 1px overflow line into the detail band's first row text —
            // visible as a strikethrough across all 7 columns. 65mm fits
            // ~32 chars at 10pt, which covers typical long vendor names.
            master.Objects.Add(MakeText($"GridLL{r}",  0, y, 32, 5, row.LL, fontSize: 8f, bold: true));
            master.Objects.Add(MakeText($"GridLV{r}", 32, y, 58, 5, row.LV, fontSize: 10f));
            master.Objects.Add(MakeText($"GridRL{r}", 95, y, 20, 5, row.RL, fontSize: 8f, bold: true));
            master.Objects.Add(MakeText($"GridRV{r}",115, y, 65, 5, row.RV, fontSize: 10f));
        }

        master.Objects.Add(MakeHRule("Rule3", 0, 63, 180));

        // ----- (4) Code128 barcodes: PO · PRS · DN · INVOICE (Stage 5) -----
        // 4 strips, each 42mm wide + 3 × 4mm gaps = 180mm. Code128 with 6–10
        // char identifiers (typical for these fields) scans at this width.
        // BarcodeObject.Text holds an expression; FastReport resolves it
        // against the current row at render time before encoding the bars.
        master.Objects.Add(MakeText("BcPoCap",   0, 65, 42, 4,
            "P/O NO", fontSize: 7f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeBarcode("BcPo",   0, 69, 42, 22, "[Orders.HeaderPoNumber]"));

        master.Objects.Add(MakeText("BcPrsCap", 46, 65, 42, 4,
            "PRS NO", fontSize: 7f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeBarcode("BcPrs", 46, 69, 42, 22, "[Orders.PullNumber]"));

        master.Objects.Add(MakeText("BcDnCap",  92, 65, 42, 4,
            "DELIVERY NOTE", fontSize: 7f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeBarcode("BcDn",  92, 69, 42, 22, "[Orders.DeliveryNoteNo]"));

        master.Objects.Add(MakeText("BcInvCap",138, 65, 42, 4,
            "INVOICE", fontSize: 7f, bold: true, align: HorzAlign.Center));
        master.Objects.Add(MakeBarcode("BcInv",138, 69, 42, 22, "[Orders.InvoiceNo]"));

        master.Objects.Add(MakeHRule("Rule4", 0, 93, 180));

        // ----- (5) Column header row -----
        // Widths: PART 25 · DESC 55 · PALLET 25 · KANBAN 20 · ASN 25 · ROUND 13 · QTY 17 = 180
        //
        // Stage 8 — widened the ERP cluster (PALLET/KANBAN/ASN) by 10mm
        // total, redistributed from PART (-3) + DESC (-5) + ROUND (-1) +
        // QTY (-1). The original 18mm ASN column was too narrow for
        // ERP-typical values like "ASN-0000079740" (14 chars, ~22mm at
        // 8pt Arial digits) — they wrapped to 3 lines. ROUND stays at
        // 13mm so the bold "ROUND" caption doesn't truncate; QTY at 17mm
        // still fits 4-5 digit totals comfortably.
        master.Objects.Add(MakeText("HdrPart",   0, 95, 25, 6, "PART NUMBER", fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrDesc",  25, 95, 55, 6, "DESCRIPTION", fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrPal",   80, 95, 25, 6, "PALLET",      fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrKan", 105, 95, 20, 6, "KANBAN",       fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrAsn", 125, 95, 25, 6, "ASN",          fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrRnd", 150, 95, 13, 6, "ROUND",        fontSize: 8f, bold: true));
        master.Objects.Add(MakeText("HdrQty", 163, 95, 17, 6, "QTY",          fontSize: 8f, bold: true, align: HorzAlign.Right));
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

        // Widths mirror BuildMasterBand column header — see widening rationale there.
        detail.Objects.Add(MakeText("ColPart",   0, 1, 25, 6, "[Lines.ItemCode]",    fontSize: 9f));
        detail.Objects.Add(MakeText("ColDesc",  25, 1, 55, 6, "[Lines.Description]", fontSize: 9f));
        detail.Objects.Add(MakeText("ColPal",   80, 1, 25, 6, "[Lines.PalletId]",    fontSize: 8f));
        detail.Objects.Add(MakeText("ColKan", 105, 1, 20, 6, "[Lines.KanbanNo]",     fontSize: 8f));
        detail.Objects.Add(MakeText("ColAsn", 125, 1, 25, 6, "[Lines.AsnNo]",        fontSize: 8f));
        detail.Objects.Add(MakeText("ColRnd", 150, 1, 13, 6, "[Lines.OrderRound]",   fontSize: 8f));
        detail.Objects.Add(MakeText("ColQty", 163, 1, 17, 6, "[Lines.TotalQty]",     fontSize: 10f, bold: true, align: HorzAlign.Right));

        return detail;
    }

    // ------------------------------------------------------------------
    // Per-master DataFooter — TOTAL QTY for the current Orders row. Prints
    // once after the detail band finishes iterating, before the next
    // master row triggers its StartNewPage.
    // ------------------------------------------------------------------
    private static DataFooterBand BuildOrderFooter()
    {
        // Height bumped 12 → 22mm in Stage 5 to host the TOTAL QTY Code128
        // beneath the numeric value. Trade-off: shaves ~1 line off the
        // single-page detail capacity (13 → 12 rows) before the band overflows
        // to a continuation page. Multi-page DOs already paginate the detail
        // band, so the regression is bounded.
        var footer = new DataFooterBand
        {
            Name = OrderFooterName,
            Height = Units.Millimeters * 22f,
        };
        footer.Objects.Add(MakeHRule("RuleTotal", 0, 1, 180));
        footer.Objects.Add(MakeText("TotalLabel", 120, 3, 30, 6,
            "TOTAL QTY", fontSize: 9f, bold: true, align: HorzAlign.Right));
        footer.Objects.Add(MakeText("TotalValue", 152, 3, 28, 6,
            "[Orders.TotalQty]", fontSize: 12f, bold: true, align: HorzAlign.Right));
        // Stage 5: Code128 of the integer total, right-aligned under the
        // numeric value. 56mm × 10mm gives enough module width for the
        // ~1–4 digit totals that real DOs carry.
        footer.Objects.Add(MakeBarcode("BcTotal", 124, 11, 56, 10, "[Orders.TotalQty]"));
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

        // 3-party digital signature boxes (Customer / Warehouse / Production),
        // per-pull, denormalized onto every Orders row. Replaces the old 2-box
        // footer + pull-close PNG (decision #6). Each box binds its caption
        // column (CustomerSig/WarehouseSig/ProductionSig) — empty ⇒ blank box
        // for manual signing on paper.
        AddSignatureBoxes(footer, yLabel: 20, yBox: 26, yVal: 32, yCap: 49);

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

    // 3-party signature boxes across 180mm content width (Customer / Warehouse
    // / Production). Each: bold label, bordered box, bound caption column
    // (empty ⇒ blank), and a "Name / Date" sub-caption. y offsets are passed in
    // because the Note footer band lays out differently from the DSV one.
    private static void AddSignatureBoxes(BandBase band, float yLabel, float yBox, float yVal, float yCap)
    {
        var parties = new[]
        {
            (x: 0f,    label: "CUSTOMER",   col: "CustomerSig"),
            (x: 61.5f, label: "WAREHOUSE",  col: "WarehouseSig"),
            (x: 123f,  label: "PRODUCTION", col: "ProductionSig"),
        };
        foreach (var p in parties)
        {
            var key = p.label[0] + p.label.Substring(1).ToLowerInvariant();
            band.Objects.Add(MakeText($"Sig{key}Label", p.x, yLabel, 57, 5, p.label, fontSize: 8f, bold: true));
            band.Objects.Add(MakeBox($"Sig{key}Box", p.x, yBox, 57, 22));
            band.Objects.Add(MakeText($"Sig{key}Val", p.x, yVal, 57, 10,
                $"[Orders.{p.col}]", fontSize: 9f, align: HorzAlign.Center));
            band.Objects.Add(MakeText($"Sig{key}Cap", p.x, yCap, 57, 4,
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
            HorzAlign = BarcodeObject.Alignment.Center,
        };
    }

    /// <summary>
    /// Stage 6 — PictureObject bound to a DataSet column carrying raw image
    /// bytes (see DoReportDataSetBuilder.DecodeAndFlattenImage). DataColumn
    /// reference form is "Table.Column"; FastReport pulls bytes at render
    /// time per current data band row.
    ///
    /// SizeMode=Zoom scales the image to fit the bounds while preserving
    /// aspect ratio. PictureBoxSizeMode lives under System.Windows.Forms
    /// in FastReport.OpenSource via FastReport.Compat — qualifying the
    /// enum reference dodges a missing-namespace error if a future SDK
    /// change shuffles the shim.
    /// </summary>
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
