using ClosedXML.Excel;

namespace ReceivingOps.Web.Services.PoImport;

/// <summary>
/// Builds the downloadable PO-import template workbook served by
/// GET /api/imports/po/template.
///
/// <para><b>Why this is generated and not a committed .xlsx.</b> Operators do
/// not fill this template in by hand — they export the JasperReports sheet
/// <c>xxwdt0061_stock_shipped</c> from the ERP (a real one is ~4,400 rows ×
/// 34 columns) and upload it unmodified. The template's job is therefore
/// <i>comparison</i>: an operator unsure whether they exported the right
/// sheet opens this file and checks their header row against it. A static
/// file would go stale the first time <see cref="PoImportReader.RequiredHeaders"/>
/// changed, and it would go stale silently — the operator would be comparing
/// against a template that is confidently wrong. Generating in-request from
/// the reader's own constant means the template cannot disagree with the
/// validator.
/// </para>
///
/// <para>ClosedXML (already a dependency for the export jobs) writes the
/// workbook; NPOI stays on reading duty.</para>
/// </summary>
public static class PoImportTemplateBuilder
{
    public const string FileName = "ReceivingOps-PO-Import-Template.xlsx";
    public const string ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    /// <summary>
    /// Sheet name the parser looks for first
    /// (<c>workbook.GetSheet("data") ?? workbook.GetSheetAt(0)</c>). Naming
    /// the template's sheet "data" means a filled-in template parses no
    /// matter which sheet ends up first in the workbook.
    /// </summary>
    public const string DataSheetName = "data";

    public const string ReadmeSheetName = "README";

    /// <summary>
    /// Every column <see cref="PoImportReader"/> maps, in the order the brief
    /// lists them. Headers are matched by NAME, not position, so this order is
    /// presentational only — but the set is not: a template showing only the
    /// four required columns would teach operators to trim their export down
    /// to four and discard twenty-four fields the system stores.
    ///
    /// <para><b>"EXPORT DECELERATION NO" is misspelled deliberately.</b> The
    /// ERP header reads "Deceleration" and <see cref="PoImportReader"/>
    /// matches that spelling (sic). Correcting it here would silently break
    /// that column for anyone comparing their export against the template.</para>
    /// </summary>
    internal static readonly string[] Columns = new[]
    {
        "PULL SHEET ID / PRS NO",
        "SKU",
        "OPEN QTY",
        "DELIVERY DATE",
        "STORER CODE",
        "STORER NAME",
        "SKU DESCRIPTION",
        "ORDER ID",
        "PO",
        "ASN NO",
        "INVOICE",
        "KANBAN NO",
        "PCC NO",
        "BATCH / LOT NO",
        "MANUFACTURING CTRL NO",
        "MANUFACTURING REF",
        "CUSTOMER REFERENCE",
        "EXPORT DECELERATION NO",
        "VENDOR SKU",
        "PALLET ID",
        "VMI PALLET ID",
        "LOCATION",
        "BUILDING",
        "SUB INVENTORY",
        "TO LOCATION",
        "PRODUCTION LINE",
        "ROUND",
        "NOTES",
    };

    /// <summary>
    /// Columns forced to Excel's Text format ("@"), chosen from the values in
    /// a real 4,401-row export rather than by guesswork:
    /// <list type="bullet">
    ///   <item>PULL SHEET ID / PRS NO — 2,909 of 4,401 rows are zero-padded
    ///         (<c>0000028048</c>). A numeric cell stores 28048 and the
    ///         leading zeros are gone.</item>
    ///   <item>KANBAN NO — same zero-padded shape, 2,909 rows.</item>
    ///   <item>SKU — 13 rows begin with a zero.</item>
    ///   <item>ASN NO / PALLET ID / VMI PALLET ID — usually prefixed
    ///         (<c>ASN-0000108150</c>, <c>B0000108150001</c>) but a handful of
    ///         rows carry the bare zero-padded number.</item>
    ///   <item>ROUND — values are clock-like (<c>03:00</c>, <c>03:00|04:00</c>);
    ///         a General cell lets Excel reinterpret 03:00 as a time.</item>
    ///   <item>DELIVERY DATE — the ERP emits it as text in dd/MM/yyyy and
    ///         <see cref="PoImportReader"/> parses that with TryParseExact.
    ///         Text keeps a US-locale Excel from re-rendering 25/12/2026.</item>
    /// </list>
    /// ORDER ID was checked and deliberately left General — its values are
    /// alphanumeric (<c>1666141B1</c>) with no leading-zero cases in the
    /// sample export.
    /// </summary>
    private static readonly HashSet<string> TextFormattedColumns = new(StringComparer.Ordinal)
    {
        "PULL SHEET ID / PRS NO",
        "SKU",
        "DELIVERY DATE",
        "ASN NO",
        "KANBAN NO",
        "PALLET ID",
        "VMI PALLET ID",
        "ROUND",
    };

    private const string TextNumberFormat = "@";

    // Sample values are deliberately, visibly fictitious. If someone uploads
    // the template unchanged the rows must read as junk rather than plausible
    // stock. Both rows pass ValidateRow as written (non-blank PoNumber,
    // non-blank SKU, OPEN QTY > 0, a DELIVERY DATE GetDate accepts) — the
    // smoke proves it by feeding this workbook back through ParseAsync.
    //
    // Row 2 leaves PO blank on purpose: PO is optional and blank on 59% of
    // rows in a real export (223 of 504 pull sheets have it blank on every
    // row). PoNumber comes from PULL SHEET ID / PRS NO per C1=A; PO lands on
    // SourcePoNo.
    private static readonly (string Header, string? Row1, string? Row2)[] SampleValues = new[]
    {
        ("PULL SHEET ID / PRS NO",   (string?)"0000000001",          (string?)"0000000002"),
        ("SKU",                      "SKU-EXAMPLE-001",              "SKU-EXAMPLE-002"),
        // OPEN QTY is written as a number, not a string — see WriteDataSheet.
        ("DELIVERY DATE",            "25/12/2026",                   "26/12/2026"),
        ("STORER CODE",              "VENDOR-EXAMPLE",               "VENDOR-EXAMPLE"),
        ("STORER NAME",              "VENDOR EXAMPLE CO., LTD.",     "VENDOR EXAMPLE CO., LTD."),
        ("SKU DESCRIPTION",          "EXAMPLE ITEM (SAMPLE ROW)",    "EXAMPLE ITEM (SAMPLE ROW)"),
        ("ORDER ID",                 "ORDER-EXAMPLE-1",              "ORDER-EXAMPLE-2"),
        ("PO",                       "PO-EXAMPLE-1",                 null),
        ("ASN NO",                   "ASN-EXAMPLE-1",                "ASN-EXAMPLE-2"),
        ("INVOICE",                  "INV-EXAMPLE-1",                "INV-EXAMPLE-2"),
        ("KANBAN NO",                "0000012345",                   "0000012346"),
        ("PCC NO",                   "PCC-EXAMPLE",                  null),
        ("BATCH / LOT NO",           "LOT-EXAMPLE-1",                "LOT-EXAMPLE-2"),
        ("MANUFACTURING CTRL NO",    "MCTRL-EXAMPLE",                null),
        ("MANUFACTURING REF",        "MREF-EXAMPLE",                 null),
        ("CUSTOMER REFERENCE",       "CUSTREF-EXAMPLE",              null),
        // Blank on all 4,401 rows of the sample export — mirrored here.
        ("EXPORT DECELERATION NO",   null,                           null),
        ("VENDOR SKU",               "VENDORSKU-EXAMPLE",            null),
        ("PALLET ID",                "PALLET-EXAMPLE-1",             "PALLET-EXAMPLE-2"),
        ("VMI PALLET ID",            "VMIPALLET-EXAMPLE-1",          "VMIPALLET-EXAMPLE-2"),
        ("LOCATION",                 "LOC-EXAMPLE",                  "LOC-EXAMPLE"),
        ("BUILDING",                 "B1",                           "B1"),
        ("SUB INVENTORY",            "SUB-EXAMPLE",                  "SUB-EXAMPLE"),
        ("TO LOCATION",              "TOLOC-EXAMPLE",                "TOLOC-EXAMPLE"),
        ("PRODUCTION LINE",          "LINE-EXAMPLE",                 "LINE-EXAMPLE"),
        ("ROUND",                    "03:00",                        "04:00"),
        ("NOTES",                    "SAMPLE ROW - FICTITIOUS DATA", "SAMPLE ROW - FICTITIOUS DATA"),
    };

    private const int Row1Qty = 120;
    private const int Row2Qty = 45;

    private static readonly XLColor RequiredHeaderFill = XLColor.FromHtml("#FFF3CD");
    private static readonly XLColor OptionalHeaderFill = XLColor.FromHtml("#EDF1F5");

    public static byte[] Build()
    {
        using var wb = new XLWorkbook();
        WriteDataSheet(wb);
        WriteReadmeSheet(wb);

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    private static void WriteDataSheet(XLWorkbook wb)
    {
        var ws = wb.Worksheets.Add(DataSheetName);

        // Column-level Text format goes on BEFORE any value is written so the
        // sample cells inherit it and Excel never gets the chance to coerce
        // "0000000001" into 1.
        for (int i = 0; i < Columns.Length; i++)
        {
            if (TextFormattedColumns.Contains(Columns[i]))
                ws.Column(i + 1).Style.NumberFormat.Format = TextNumberFormat;
        }

        var sampleByHeader = SampleValues.ToDictionary(s => s.Header, StringComparer.Ordinal);

        for (int i = 0; i < Columns.Length; i++)
        {
            var header = Columns[i];
            var col = i + 1;

            // Required-ness is read off the reader's own constant, so a change
            // to RequiredHeaders re-marks the template automatically. Whether a
            // NEW required header appears in Columns at all is guarded by
            // tools/smoke-import-template.ps1 §5, which drives its assertion
            // from the same constant.
            var isRequired = PoImportReader.RequiredHeaders.Contains(header, StringComparer.Ordinal);

            var headerCell = ws.Cell(1, col);
            headerCell.SetValue(header);
            headerCell.Style.Font.Bold = true;
            headerCell.Style.Fill.BackgroundColor = isRequired ? RequiredHeaderFill : OptionalHeaderFill;
            headerCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            headerCell.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

            if (isRequired)
            {
                // Marked with a fill + a comment, never by editing the header
                // TEXT — the text is the matching key. The author is set
                // explicitly; ClosedXML otherwise stamps the server process's
                // OS account onto every downloaded copy.
                var comment = headerCell.CreateComment();
                comment.SetAuthor("ReceivingOps");
                comment.AddText("(required) — the import is rejected before any row is read if this column is missing.");
            }

            if (!sampleByHeader.TryGetValue(header, out var sample)) continue;
            if (sample.Row1 is not null) ws.Cell(2, col).SetValue(sample.Row1);
            if (sample.Row2 is not null) ws.Cell(3, col).SetValue(sample.Row2);
        }

        // OPEN QTY is numeric in the real export and GetInt's Numeric branch is
        // the common path — write real numbers rather than strings.
        var qtyCol = Array.IndexOf(Columns, "OPEN QTY") + 1;
        ws.Cell(2, qtyCol).SetValue(Row1Qty);
        ws.Cell(3, qtyCol).SetValue(Row2Qty);

        ws.SheetView.FreezeRows(1);

        // AdjustToContents then clamp: an operator comparing 28 headers should
        // not have to widen a column first, and no single column should be wide
        // enough to push the rest off screen.
        ws.Columns().AdjustToContents();
        foreach (var col in ws.ColumnsUsed())
        {
            if (col.Width < 14) col.Width = 14;
            if (col.Width > 34) col.Width = 34;
        }
    }

    private static void WriteReadmeSheet(XLWorkbook wb)
    {
        // Thai — the operators reading this are Thai-speaking. Column header
        // names stay in English because they are the matching keys.
        var ws = wb.Worksheets.Add(ReadmeSheetName);

        var row = 1;

        void Title(string text)
        {
            var c = ws.Cell(row++, 1);
            c.SetValue(text);
            c.Style.Font.Bold = true;
            c.Style.Font.FontSize = 14;
        }

        void Heading(string text)
        {
            row++;
            var c = ws.Cell(row++, 1);
            c.SetValue(text);
            c.Style.Font.Bold = true;
        }

        void Line(string text) => ws.Cell(row++, 1).SetValue(text);

        Title("เทมเพลตสำหรับนำเข้า PO (PO Import Template) — ReceivingOps");
        Line("ไฟล์นี้มีไว้ให้ \"เทียบหัวคอลัมน์\" ไม่ได้มีไว้ให้กรอกข้อมูลเอง");

        Heading("1. ไฟล์ที่ต้องอัปโหลดมาจากไหน");
        Line("ให้ export รายงาน xxwdt0061_stock_shipped จากระบบ ERP แล้วอัปโหลดไฟล์นั้น \"โดยไม่ต้องแก้ไข\"");
        Line("ไม่ต้องลบคอลัมน์ ไม่ต้องจัดเรียงใหม่ ไม่ต้องพิมพ์ข้อมูลเพิ่ม — อัปโหลดไฟล์ที่ export มาได้เลย");

        Heading("2. คอลัมน์ที่จำเป็น (ถ้าขาดคอลัมน์ใดคอลัมน์หนึ่ง ระบบจะปฏิเสธทั้งไฟล์)");
        // Listed from PoImportReader.RequiredHeaders — the same array the
        // validator uses, so this list cannot drift from the rule it describes.
        foreach (var h in PoImportReader.RequiredHeaders)
            Line($"    • {h}   (required)");
        Line("ชื่อคอลัมน์เป็นภาษาอังกฤษ เพราะระบบใช้ \"ชื่อหัวคอลัมน์\" ในการจับคู่ข้อมูล — ห้ามแปลหรือแก้ตัวสะกด");
        Line("ในชีท data คอลัมน์ที่จำเป็นถูกไฮไลต์ด้วยสีเหลือง");

        Heading("3. คอลัมน์อื่น ๆ และลำดับคอลัมน์");
        Line("ระบบจับคู่ด้วยชื่อหัวคอลัมน์ ไม่ใช่ตำแหน่ง ดังนั้นลำดับคอลัมน์ไม่มีผล");
        Line("คอลัมน์ที่ระบบไม่ได้ใช้จะถูกข้ามไป ไม่ทำให้ไฟล์ผิดพลาด (ไฟล์จริงจาก ERP มีคอลัมน์มากกว่าที่ระบบอ่าน)");

        Heading("4. การนำเข้าเป็นแบบ \"ทั้งหมดหรือไม่เอาเลย\"");
        Line("ถ้ามีแถวใดไม่ผ่านการตรวจสอบแม้เพียงแถวเดียว ไฟล์ทั้งไฟล์จะถูกปฏิเสธ ไม่มีการนำเข้าบางส่วน");
        Line("ระบบจะตรวจไฟล์ให้ก่อน และแสดงรายการข้อผิดพลาดให้ตรวจสอบก่อนกดยืนยัน");

        Heading("5. คอลัมน์ PO เว้นว่างได้");
        Line("คอลัมน์ PO ว่างได้และเป็นเรื่องปกติ (ในไฟล์จริงว่างประมาณ 59% ของแถว) ไม่ถือเป็นข้อผิดพลาด");
        Line("เลขที่ระบบใช้เป็น PO มาจากคอลัมน์ PULL SHEET ID / PRS NO ส่วนคอลัมน์ PO เก็บไว้เป็นเลขอ้างอิงต้นทาง");

        Heading("6. ชนิดไฟล์และขนาด");
        Line("รองรับทั้ง .xls และ .xlsx — ขนาดไฟล์ไม่เกิน 50 MB");

        Heading("7. ข้อมูลตัวอย่างในชีท data");
        Line("แถวที่ 2 และ 3 ของชีท data เป็นข้อมูลสมมติ (SKU-EXAMPLE-001 / VENDOR-EXAMPLE) มีไว้ดูรูปแบบเท่านั้น");
        Line("คอลัมน์ PULL SHEET ID / PRS NO ตั้งเป็นรูปแบบ Text เพื่อรักษาเลขศูนย์นำหน้า เช่น 0000028048");
        Line("คอลัมน์ DELIVERY DATE ใช้รูปแบบ วว/ดด/ปปปป (ค.ศ.) เช่น 25/12/2026");

        ws.Column(1).Width = 110;
        ws.SheetView.FreezeRows(1);
    }
}
