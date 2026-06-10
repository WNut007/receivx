using System.Data;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// Path B Stage 2 — builds the master-detail DataSet that the
/// designer-driven delivery-order.frx will bind to.
///
/// Shape:
///   Orders (master)  — one row per DoOrder, PK = DeliveryNoteNo
///   Lines  (detail)  — one row per DoLine, FK = DeliveryNoteNo → Orders
///   OrdersLines      — DataRelation linking Orders.DeliveryNoteNo → Lines.DeliveryNoteNo
///
/// Pull-level fields (WarehouseCode/Name/Address/Logo, PullNumber, ClosedAt,
/// ClosedBy*, SignatureSvg, etc.) are denormalized onto every Orders row so
/// the .frx can reference them at page grain via [Orders.WarehouseCode]
/// without needing a third "Pull" table + a second relation. Two-tables /
/// one-relation keeps Stage 3 authoring + Stage 8 designer round-trip simple.
///
/// Stage 2 only builds the shape — this class is NOT yet wired into the
/// runtime pipeline. The existing programmatic Build() in DeliveryOrderService
/// stays authoritative until the Stage 4 cutover that swaps the per-page
/// inline DataTable creation for Report.Load() + report.RegisterData(dataset).
/// </summary>
public static class DoReportDataSetBuilder
{
    /// <summary>DataSet name passed to FastReport's RegisterData(ds, name).</summary>
    public const string DataSetName = "DoReport";

    /// <summary>Master table name. References in .frx use [Orders.Column].</summary>
    public const string OrdersTableName = "Orders";

    /// <summary>Detail table name. References in .frx use [Lines.Column].</summary>
    public const string LinesTableName = "Lines";

    /// <summary>Master→detail relation name (Orders.DeliveryNoteNo → Lines.DeliveryNoteNo).</summary>
    public const string OrdersLinesRelationName = "OrdersLines";

    public static DataSet Build(DoReportData data)
    {
        var ds = new DataSet(DataSetName);
        var orders = BuildOrdersTable();
        var lines = BuildLinesTable();
        ds.Tables.Add(orders);
        ds.Tables.Add(lines);

        for (int i = 0; i < data.Orders.Count; i++)
        {
            var order = data.Orders[i];
            AddOrderRow(orders, data.Pull, order, i);
            for (int j = 0; j < order.Lines.Count; j++)
            {
                AddLineRow(lines, order.DeliveryNoteNo, order.Lines[j], j);
            }
        }

        ds.Relations.Add(new DataRelation(
            OrdersLinesRelationName,
            orders.Columns[nameof(DoOrder.DeliveryNoteNo)]!,
            lines.Columns[nameof(DoOrder.DeliveryNoteNo)]!));

        return ds;
    }

    private static DataTable BuildOrdersTable()
    {
        var t = new DataTable(OrdersTableName);

        // PK + per-DO identity
        t.Columns.Add("DeliveryNoteNo", typeof(string));
        t.Columns.Add("DoIndex",        typeof(int));

        // 4-tuple DO identity (D1) + VendorName as attribute
        t.Columns.Add("VendorCode",     typeof(string));
        t.Columns.Add("VendorName",     typeof(string));
        t.Columns.Add("SubInventory",   typeof(string));
        t.Columns.Add("ToLocation",     typeof(string));
        t.Columns.Add("InvoiceNo",      typeof(string));

        // Per-DO display
        t.Columns.Add("HeaderPoNumber", typeof(string));
        t.Columns.Add("LastReceivedAt", typeof(DateTime));
        t.Columns.Add("TotalQty",       typeof(int));

        // Pull-level (denormalized — same value across every Orders row in
        // one render, but the .frx is per-page so it needs them here)
        t.Columns.Add("PullId",               typeof(Guid));
        t.Columns.Add("PullNumber",           typeof(string));
        t.Columns.Add("PullDate",             typeof(DateTime));
        t.Columns.Add("ReferenceNumber",      typeof(string));
        t.Columns.Add("WarehouseCode",        typeof(string));
        t.Columns.Add("WarehouseName",        typeof(string));
        t.Columns.Add("WarehouseAddress",     typeof(string));
        t.Columns.Add("WarehouseLogoDataUrl", typeof(string));
        t.Columns.Add("ClosedAt",             typeof(DateTime));
        t.Columns.Add("ClosedByName",         typeof(string));
        t.Columns.Add("ClosedByRole",         typeof(string));
        t.Columns.Add("SignatureSvg",         typeof(string));

        // Stage 6 — pre-decoded image bytes for PictureObject.DataColumn
        // binding. The string data-URL columns (WarehouseLogoDataUrl,
        // SignatureSvg) stay alongside so the HTML preview path can keep
        // rendering data URLs directly; the byte[] columns serve the PDF
        // pipeline which can't decode the URL form natively.
        t.Columns.Add("WarehouseLogoBytes",   typeof(byte[]));
        t.Columns.Add("SignatureBytes",       typeof(byte[]));

        foreach (DataColumn c in t.Columns)
            c.AllowDBNull = true;

        // PK is the only column DataRelation requires to be unique; the
        // DataTable handles uniqueness enforcement via the implicit
        // UniqueConstraint that PrimaryKey assignment installs.
        t.PrimaryKey = new[] { t.Columns["DeliveryNoteNo"]! };
        return t;
    }

    private static DataTable BuildLinesTable()
    {
        var t = new DataTable(LinesTableName);

        // FK back to Orders + intra-DO ordering preserved for display
        t.Columns.Add("DeliveryNoteNo", typeof(string));
        t.Columns.Add("LineIndex",      typeof(int));

        // Core line columns
        t.Columns.Add("ItemCode",       typeof(string));
        t.Columns.Add("Description",    typeof(string));
        t.Columns.Add("PoLineNumber",   typeof(int));
        t.Columns.Add("PoLineRef",      typeof(string));
        t.Columns.Add("TotalQty",       typeof(int));
        t.Columns.Add("LastReceivedAt", typeof(DateTime));

        // ERP-sourced PoLine attributes surfaced on the DO at line grain
        t.Columns.Add("PalletId",       typeof(string));
        t.Columns.Add("OrderId",        typeof(string));
        t.Columns.Add("InvoiceNo",      typeof(string));
        t.Columns.Add("KanbanNo",       typeof(string));
        t.Columns.Add("SubInventory",   typeof(string));
        t.Columns.Add("ToLocation",     typeof(string));
        t.Columns.Add("AsnNo",          typeof(string));
        t.Columns.Add("OrderRound",     typeof(string));
        t.Columns.Add("SourcePoNo",     typeof(string));

        foreach (DataColumn c in t.Columns)
            c.AllowDBNull = true;

        return t;
    }

    private static void AddOrderRow(DataTable orders, DoPullHeader pull, DoOrder o, int idx)
    {
        var row = orders.NewRow();
        row["DeliveryNoteNo"]       = o.DeliveryNoteNo;
        row["DoIndex"]              = idx;
        row["VendorCode"]           = NullIfEmpty(o.VendorCode);
        row["VendorName"]           = NullIfEmpty(o.VendorName);
        row["SubInventory"]         = NullIfEmpty(o.SubInventory);
        row["ToLocation"]           = NullIfEmpty(o.ToLocation);
        row["InvoiceNo"]            = NullIfEmpty(o.InvoiceNo);
        row["HeaderPoNumber"]       = NullIfEmpty(o.HeaderPoNumber);
        row["LastReceivedAt"]       = NullableDate(o.LastReceivedAt);
        row["TotalQty"]             = o.TotalQty;

        row["PullId"]               = pull.Id;
        row["PullNumber"]           = pull.PullNumber;
        row["PullDate"]             = pull.PullDate;
        row["ReferenceNumber"]      = NullIfEmpty(pull.ReferenceNumber);
        row["WarehouseCode"]        = pull.WarehouseCode;
        row["WarehouseName"]        = pull.WarehouseName;
        row["WarehouseAddress"]     = NullIfEmpty(pull.WarehouseAddress);
        row["WarehouseLogoDataUrl"] = NullIfEmpty(pull.WarehouseLogoDataUrl);
        row["ClosedAt"]             = NullableDate(pull.ClosedAt);
        row["ClosedByName"]         = NullIfEmpty(pull.ClosedByName);
        row["ClosedByRole"]         = NullIfEmpty(pull.ClosedByRole);
        row["SignatureSvg"]         = NullIfEmpty(pull.SignatureSvg);
        row["WarehouseLogoBytes"]   = (object?)DecodeAndFlattenImage(pull.WarehouseLogoDataUrl) ?? DBNull.Value;
        row["SignatureBytes"]       = (object?)DecodeAndFlattenImage(pull.SignatureSvg)         ?? DBNull.Value;

        orders.Rows.Add(row);
    }

    private static void AddLineRow(DataTable lines, string deliveryNoteNo, DoLine l, int idx)
    {
        var row = lines.NewRow();
        row["DeliveryNoteNo"] = deliveryNoteNo;
        row["LineIndex"]      = idx;
        row["ItemCode"]       = l.ItemCode;
        row["Description"]    = l.Description;
        row["PoLineNumber"]   = l.PoLineNumber;
        row["PoLineRef"]      = l.PoLineRef;
        row["TotalQty"]       = l.TotalQty;
        row["LastReceivedAt"] = NullableDate(l.LastReceivedAt);
        row["PalletId"]       = NullIfEmpty(l.PalletId);
        row["OrderId"]        = NullIfEmpty(l.OrderId);
        row["InvoiceNo"]      = NullIfEmpty(l.InvoiceNo);
        row["KanbanNo"]       = NullIfEmpty(l.KanbanNo);
        row["SubInventory"]   = NullIfEmpty(l.SubInventory);
        row["ToLocation"]     = NullIfEmpty(l.ToLocation);
        row["AsnNo"]          = NullIfEmpty(l.AsnNo);
        row["OrderRound"]     = NullIfEmpty(l.OrderRound);
        row["SourcePoNo"]     = NullIfEmpty(l.SourcePoNo);
        lines.Rows.Add(row);
    }

    private static object NullIfEmpty(string? s) =>
        string.IsNullOrEmpty(s) ? DBNull.Value : s;

    private static object NullableDate(DateTime? d) =>
        d.HasValue ? d.Value : DBNull.Value;

    /// <summary>
    /// Decodes a "data:image/png;base64,..." or "data:image/jpeg;base64,..."
    /// URL into raw image bytes, then flattens onto a 24bpp white canvas
    /// and re-encodes as PNG. Two reasons:
    /// (1) PDFSimpleExport rasterizes each page as a JPEG, which has no
    ///     alpha channel — transparent PNG pixels collapse to BLACK in the
    ///     export pipeline. Server-side flatten onto white avoids that.
    /// (2) Storing the canvas bytes in the DataSet lets PictureObject.
    ///     DataColumn pull image bytes directly at render time, no per-
    ///     request decode in the template builder.
    /// Returns null for null/empty input, inline SVG (System.Drawing can't
    /// parse SVG), other URL flavors, or any decode/GDI+ failure — the
    /// caller writes DBNull and the bound PictureObject silently renders
    /// nothing.
    /// </summary>
    private static byte[]? DecodeAndFlattenImage(string? dataUrl)
    {
        if (string.IsNullOrWhiteSpace(dataUrl)) return null;

        string[] prefixes =
        {
            "data:image/png;base64,",
            "data:image/jpeg;base64,",
            "data:image/jpg;base64,",
        };
        string? base64 = null;
        foreach (var prefix in prefixes)
        {
            if (dataUrl.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                base64 = dataUrl.Substring(prefix.Length);
                break;
            }
        }
        if (base64 is null) return null;

        byte[] raw;
        try { raw = Convert.FromBase64String(base64); }
        catch (FormatException) { return null; }

        try
        {
            using var ms = new MemoryStream(raw);
            using var loaded = Image.FromStream(ms);
            using var flat = new Bitmap(loaded.Width, loaded.Height, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(flat))
            {
                g.Clear(Color.White);
                g.DrawImage(loaded, 0, 0, loaded.Width, loaded.Height);
            }
            using var outMs = new MemoryStream();
            flat.Save(outMs, ImageFormat.Png);
            return outMs.ToArray();
        }
        catch (ArgumentException) { return null; }
        catch (OutOfMemoryException) { return null; }
    }
}
