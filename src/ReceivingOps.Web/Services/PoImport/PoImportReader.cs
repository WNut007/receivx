using System.Globalization;
using NPOI.HSSF.UserModel;
using NPOI.SS.UserModel;
using NPOI.XSSF.UserModel;

namespace ReceivingOps.Web.Services.PoImport;

/// <summary>
/// Phase 12.2 — NPOI-backed reader for the PO Excel import pipeline.
/// HSSF for .xls (OLE2) + XSSF for .xlsx (OOXML), one implementation,
/// extension-discriminated at the entry point.
///
/// <para>Mapping resolves four header conflicts captured in the v3.2
/// session decisions doc:</para>
/// <list type="bullet">
///   <item>C1=A — "PULL SHEET ID / PRS NO" wins for PoNumber; "PO" column is ignored.</item>
///   <item>C2=C — "ORDER ID" and "ASN NO" both land (db/031 added OrderId).</item>
///   <item>C3=A — "PALLET ID" (uppercase, later in sheet) wins; "Pallet ID" ignored.
///                Encoded by the later-wins normalization in the header map.</item>
///   <item>C4=A — "DELIVERY DATE" wins for DeliveryDate; "ORDER DATE" is ignored.</item>
/// </list>
/// </summary>
public class PoImportReader : IPoImportReader
{
    private const string DataSheetName = "data";

    /// <summary>
    /// Headers that MUST be present in the sheet. Anything else is optional —
    /// missing optional headers just leave the corresponding row fields null.
    /// </summary>
    private static readonly string[] RequiredHeaders = new[]
    {
        "PULL SHEET ID / PRS NO",
        "SKU",
        "OPEN QTY",
        "DELIVERY DATE",
    };

    private readonly ILogger<PoImportReader> _log;

    public PoImportReader(ILogger<PoImportReader> log)
    {
        _log = log;
    }

    public Task<PoImportParseResult> ParseAsync(string filePath, CancellationToken ct = default)
    {
        // NPOI is synchronous by design. The async signature is for caller
        // ergonomics (controllers expect Task<T>); we deliberately do not
        // wrap in Task.Run — at our file sizes the thread-pool hop costs
        // more than the parse itself, and the upload endpoint is already
        // running on a request-handling thread that's fine to block briefly.
        var result = new PoImportParseResult();

        var ext = Path.GetExtension(filePath).ToLowerInvariant();
        if (ext != ".xls" && ext != ".xlsx")
        {
            result.ValidationErrors.Add(new PoImportValidationError
            {
                Message = $"Unsupported file extension: {ext}. Only .xls and .xlsx are accepted."
            });
            return Task.FromResult(result);
        }

        IWorkbook workbook;
        try
        {
            using var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            workbook = ext == ".xls"
                ? (IWorkbook)new HSSFWorkbook(stream)
                : new XSSFWorkbook(stream);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Failed to open Excel file {Path}", filePath);
            result.ValidationErrors.Add(new PoImportValidationError
            {
                Message = $"Could not open file: {ex.Message}"
            });
            return Task.FromResult(result);
        }

        var sheet = workbook.GetSheet(DataSheetName) ?? workbook.GetSheetAt(0);
        if (sheet == null)
        {
            result.ValidationErrors.Add(new PoImportValidationError
            {
                Message = "No data sheet found in workbook."
            });
            return Task.FromResult(result);
        }

        var headerRow = sheet.GetRow(0);
        if (headerRow == null)
        {
            result.ValidationErrors.Add(new PoImportValidationError
            {
                Message = "Header row is missing."
            });
            return Task.FromResult(result);
        }

        // Header → column-index map. Trim+upper normalization plus later-wins
        // semantics: when two source columns normalize to the same key
        // (the C3=A "Pallet ID" / "PALLET ID" pair), the rightmost column
        // overwrites the earlier index. The uppercase variant appears later
        // in the spec sheet so this resolves the conflict the way C3=A wants.
        var columnMap = new Dictionary<string, int>();
        for (int c = headerRow.FirstCellNum; c < headerRow.LastCellNum; c++)
        {
            var cell = headerRow.GetCell(c);
            if (cell == null) continue;
            var norm = (cell.ToString() ?? "").Trim().ToUpperInvariant();
            if (norm.Length > 0) columnMap[norm] = c;
        }

        var missing = RequiredHeaders.Where(h => !columnMap.ContainsKey(h)).ToList();
        if (missing.Count > 0)
        {
            foreach (var h in missing)
            {
                result.ValidationErrors.Add(new PoImportValidationError
                {
                    Column = h,
                    Message = $"Required column missing: {h}"
                });
            }
            return Task.FromResult(result);
        }

        for (int r = 1; r <= sheet.LastRowNum; r++)
        {
            ct.ThrowIfCancellationRequested();

            var row = sheet.GetRow(r);
            if (row == null) continue;

            // Trailing empty rows are common in Excel exports — skip them
            // silently rather than reporting "required field blank" for each.
            if (IsRowEmpty(row, columnMap)) continue;

            var excelRowNumber = r + 1;
            var poRow = MapRow(row, columnMap, excelRowNumber);
            var rowErrors = ValidateRow(poRow);

            if (rowErrors.Count > 0)
            {
                result.ValidationErrors.AddRange(rowErrors);
            }
            else
            {
                result.Rows.Add(poRow);
            }
        }

        // TotalRows = rows the parser actually attempted (valid + at-least-one-error).
        // Excludes wholly-empty trailing rows. Lets the UI show "X of Y rows valid".
        var failingRowCount = result.ValidationErrors
            .Where(e => e.RowNumber > 0)
            .Select(e => e.RowNumber)
            .Distinct()
            .Count();
        result.TotalRows = result.Rows.Count + failingRowCount;

        return Task.FromResult(result);
    }

    // -----------------------------------------------------------------------
    // Mapping + validation
    // -----------------------------------------------------------------------

    private static PoImportRow MapRow(IRow row, Dictionary<string, int> map, int excelRowNumber)
    {
        return new PoImportRow
        {
            RowNumber = excelRowNumber,

            PoNumber = GetString(row, map, "PULL SHEET ID / PRS NO") ?? "",
            VendorCode = GetString(row, map, "STORER CODE"),
            VendorName = GetString(row, map, "STORER NAME"),

            ItemCode = GetString(row, map, "SKU") ?? "",
            Description = GetString(row, map, "SKU DESCRIPTION"),
            OrderedQty = GetInt(row, map, "OPEN QTY") ?? 0,
            DeliveryDate = GetDate(row, map, "DELIVERY DATE"),

            OrderId = GetString(row, map, "ORDER ID"),
            AsnNo = GetString(row, map, "ASN NO"),
            InvoiceNo = GetString(row, map, "INVOICE"),
            KanbanNo = GetString(row, map, "KANBAN NO"),
            PCCNo = GetString(row, map, "PCC NO"),
            BatchNo = GetString(row, map, "BATCH / LOT NO"),
            ManufacturingControlNo = GetString(row, map, "MANUFACTURING CTRL NO"),
            ManufacturingReferenceNo = GetString(row, map, "MANUFACTURING REF"),
            CustomerReferenceNo = GetString(row, map, "CUSTOMER REFERENCE"),
            // Source header spelling is "Deceleration" (sic). Mapping matches the file.
            ExportDeclarationNo = GetString(row, map, "EXPORT DECELERATION NO"),
            VendorItem = GetString(row, map, "VENDOR SKU"),

            PalletId = GetString(row, map, "PALLET ID"),
            VmiPalletId = GetString(row, map, "VMI PALLET ID"),
            Location = GetString(row, map, "LOCATION"),
            Building = GetString(row, map, "BUILDING"),
            SubInventory = GetString(row, map, "SUB INVENTORY"),
            ToLocation = GetString(row, map, "TO LOCATION"),

            ProductionLine = GetString(row, map, "PRODUCTION LINE"),
            OrderRound = GetString(row, map, "ROUND"),
            Note = GetString(row, map, "NOTES"),
        };
    }

    private static List<PoImportValidationError> ValidateRow(PoImportRow row)
    {
        var errors = new List<PoImportValidationError>();

        if (string.IsNullOrWhiteSpace(row.PoNumber))
            errors.Add(new() { RowNumber = row.RowNumber, Column = "PULL SHEET ID / PRS NO", Message = "Required" });

        if (string.IsNullOrWhiteSpace(row.ItemCode))
            errors.Add(new() { RowNumber = row.RowNumber, Column = "SKU", Message = "Required" });

        if (row.OrderedQty <= 0)
            errors.Add(new() { RowNumber = row.RowNumber, Column = "OPEN QTY", Message = "Must be > 0" });

        if (!row.DeliveryDate.HasValue)
            errors.Add(new() { RowNumber = row.RowNumber, Column = "DELIVERY DATE", Message = "Invalid or missing date" });

        return errors;
    }

    private static bool IsRowEmpty(IRow row, Dictionary<string, int> map)
    {
        // Treat the row as empty only when every REQUIRED cell is blank.
        // Excel often leaves trailing rows with phantom formatting on
        // non-required columns; declaring them "missing required field"
        // would spam the validation report with hundreds of false errors.
        foreach (var h in RequiredHeaders)
        {
            if (!map.TryGetValue(h, out var c)) continue;
            var cell = row.GetCell(c);
            if (cell == null) continue;
            if (cell.CellType == CellType.Blank) continue;
            var s = cell.ToString();
            if (!string.IsNullOrWhiteSpace(s)) return false;
        }
        return true;
    }

    // -----------------------------------------------------------------------
    // Cell readers — typed to the destination column rather than to NPOI's
    // generic ICell so the call sites in MapRow stay readable.
    // -----------------------------------------------------------------------

    private static string? GetString(IRow row, Dictionary<string, int> map, string header)
    {
        if (!map.TryGetValue(header, out var c)) return null;
        var cell = row.GetCell(c);
        if (cell == null) return null;

        return cell.CellType switch
        {
            CellType.String => NullIfBlank(cell.StringCellValue),
            // Numeric cells stringify via InvariantCulture so a German Excel
            // doesn't smuggle "1.234,5" into an item code column.
            CellType.Numeric => NullIfBlank(cell.NumericCellValue.ToString(CultureInfo.InvariantCulture)),
            CellType.Boolean => cell.BooleanCellValue.ToString(),
            CellType.Formula => NullIfBlank(FormulaResultAsString(cell)),
            _ => null
        };
    }

    private static int? GetInt(IRow row, Dictionary<string, int> map, string header)
    {
        if (!map.TryGetValue(header, out var c)) return null;
        var cell = row.GetCell(c);
        if (cell == null) return null;

        switch (cell.CellType)
        {
            case CellType.Numeric:
                // CLAUDE.md invariant: all qty arithmetic is whole units.
                // Truncate any fractional component the spreadsheet smuggled in.
                return (int)cell.NumericCellValue;
            case CellType.String:
                var s = cell.StringCellValue?.Trim();
                if (string.IsNullOrEmpty(s)) return null;
                return int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : null;
            case CellType.Formula:
                if (cell.CachedFormulaResultType == CellType.Numeric)
                    return (int)cell.NumericCellValue;
                return null;
            default:
                return null;
        }
    }

    private static DateTime? GetDate(IRow row, Dictionary<string, int> map, string header)
    {
        if (!map.TryGetValue(header, out var c)) return null;
        var cell = row.GetCell(c);
        if (cell == null) return null;

        try
        {
            switch (cell.CellType)
            {
                case CellType.Numeric:
                    // NPOI converts the Excel serial to DateTime here even
                    // when the cell isn't explicitly date-formatted. The
                    // sample file uses real numeric date cells so this is
                    // the common path.
                    return cell.DateCellValue;
                case CellType.String:
                    var s = cell.StringCellValue?.Trim();
                    if (string.IsNullOrEmpty(s)) return null;
                    return DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt)
                        ? dt
                        : null;
                case CellType.Formula when cell.CachedFormulaResultType == CellType.Numeric:
                    return cell.DateCellValue;
                default:
                    return null;
            }
        }
        catch
        {
            // NPOI throws on malformed serials; treat as missing.
            return null;
        }
    }

    private static string? NullIfBlank(string? s)
        => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    private static string FormulaResultAsString(ICell cell) => cell.CachedFormulaResultType switch
    {
        CellType.String => cell.StringCellValue ?? "",
        CellType.Numeric => cell.NumericCellValue.ToString(CultureInfo.InvariantCulture),
        CellType.Boolean => cell.BooleanCellValue.ToString(),
        _ => ""
    };
}
