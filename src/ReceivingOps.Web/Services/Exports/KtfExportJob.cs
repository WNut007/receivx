using System.Globalization;
using ClosedXML.Excel;
using Hangfire;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services.Email;

namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// KTF form export — same pipeline as <see cref="TransactionsExportJob"/>
/// (Hangfire "exports" queue → ClosedXML → signed link → email), different
/// output shape. Where the transactions export is a flat 30-column journal
/// dump, this renders the 15-column KTF paper form.
///
/// Two deliberate differences from the transactions export:
///   1. RECEIVE rows only. Kind is forced to 'receive' regardless of the
///      operator's Action filter — a KTF form records goods received, so
///      reversals (negative qty) and voided originals have no place on it.
///   2. Warehouse-local dates. ReceivedAt is UTC in the DB; the Date column is
///      rendered in the row's warehouse timezone (db/041) because the form is
///      printed and read on site. SHIFT/Time instead come from the booked
///      window slot (HourOfDay), which is already local.
///   3. The email is best-effort. The job is marked succeeded as soon as the
///      file exists; a failed notification is logged, not fatal.
///
/// Read-only: queries the journal view, writes a file. Touches no write path.
/// </summary>
public class KtfExportJob
{
    // ---- Shift model -------------------------------------------------------
    // No shift logic existed in the codebase when this was written (no column,
    // no config, no constant), so the boundary below is the only definition of
    // it — a real business rule replaces it here.
    //
    // SHIFT and Time both derive from Receipts.HourOfDay, NOT from ReceivedAt.
    // HourOfDay is the receiving *window slot* the operator books against
    // (§7.1 dual-cap model); ReceivedAt is just when the row got written. The
    // reference form's Time column is always on the hour (7:00 AM, 9:00 AM,
    // 3:00 PM …), which is the slot, not a wall clock. Using the slot also
    // sidesteps timezone entirely — HourOfDay is already warehouse-local.
    private const int DayShiftStartHour = 7;    // inclusive
    private const int NightShiftStartHour = 19; // exclusive upper bound of DAY

    /// <summary>Fallback when a warehouse's Timezone id isn't resolvable on this host.</summary>
    private const string FallbackTimezone = "Asia/Bangkok";

    // Palette + formats read off the reference workbook
    // (mockups/KTF  MTF to MFG (Issue transaction record).xlsx, sheet "09-Jul-2026").
    private static readonly XLColor HeaderFill = XLColor.FromHtml("#CCFFCC"); // green
    private static readonly XLColor DataFill = XLColor.FromHtml("#FFCCFF");   // pink
    private const string FontName = "Arial";
    private const double HeaderFontSize = 11;
    private const double BodyFontSize = 10;
    /// <summary>Excel built-in format 15 = "d-mmm-yy" — what the reference form uses.</summary>
    private const int DateFormatId = 15;
    private const string TimeFormat = @"[$-409]h:mm\ AM/PM;@";
    private const string QtyFormat = @"_(* #,##0_);_(* \(#,##0\);_(* ""-""??_);_(@_)";

    /// <summary>Only Product, Date and Description carry the pink fill; the rest are unfilled.</summary>
    private static readonly int[] FilledColumns = { 1, 2, 8 };
    private const int DescriptionColumn = 8;
    private const int DateColumn = 2;
    private const int TimeColumn = 4;
    private const int QtyColumn = 7;

    private static readonly string[] Headers =
    {
        "Product", "Date", "SHIFT", "Time", "KTF no.", "Part Number", "Q'TY",
        "Description", "From Sup", "To Sup", "INV.", "Po & RT", "Supplier",
        "Trial/EEN", "Remark",
    };

    private readonly IReceiptRepository _receipts;
    private readonly IEmailService _email;
    private readonly ExportTokenService _tokens;
    private readonly IExportJobLogRepository _logRepo;
    private readonly ExportOptions _opts;
    private readonly ILogger<KtfExportJob> _log;

    public KtfExportJob(
        IReceiptRepository receipts,
        IEmailService email,
        ExportTokenService tokens,
        IExportJobLogRepository logRepo,
        IOptions<ExportOptions> opts,
        ILogger<KtfExportJob> log)
    {
        _receipts = receipts;
        _email = email;
        _tokens = tokens;
        _logRepo = logRepo;
        _opts = opts.Value;
        _log = log;
    }

    [AutomaticRetry(Attempts = 3, DelaysInSeconds = new[] { 30, 120, 600 })]
    [Queue("exports")]
    public async Task RunAsync(Guid jobId, TransactionsExportRequest request, string requesterEmail, string requesterName)
    {
        _log.LogInformation("KTF export job {JobId} starting for {Email}", jobId, requesterEmail);
        await _logRepo.UpdateRunningAsync(jobId);
        try
        {
            // Reuse the page's filter verbatim, but pin Kind — a KTF form is
            // receives only. maxTake lifts the repo's 500-row page ceiling so
            // the form isn't silently truncated mid-month.
            var query = request.ToQuery() with { Kind = "receive" };
            var paged = await _receipts.QueryAsync(query, CancellationToken.None, maxTake: request.MaxRows);
            _log.LogInformation("KTF export job {JobId} fetched {Count} of {Total} receive rows", jobId, paged.Rows.Count, paged.Total);

            var (filePath, fileName) = ResolveFilePath(jobId);
            WriteWorkbook(filePath, paged.Rows);

            var expiresAt = DateTime.UtcNow.Add(_opts.FileLifetime);
            var token = _tokens.Issue(jobId, expiresAt);
            var baseUrl = _opts.BaseUrl.TrimEnd('/');
            var url = $"{baseUrl}/api/exports/{jobId:D}/download?token={token}";

            // Mark succeeded BEFORE emailing. The file on disk is the deliverable;
            // the email is only one way to learn about it — /Exports lists the job
            // and builds its own signed download link. Marking first means a broken
            // mail server can't turn a perfectly good export into a failed job (and
            // can't trigger a Hangfire retry that regenerates the same file).
            await _logRepo.UpdateSucceededAsync(jobId, fileName, paged.Rows.Count);
            _log.LogInformation("KTF export job {JobId} complete: {File} ({Bytes} bytes)",
                jobId, filePath, new FileInfo(filePath).Length);

            // Best-effort notification. MailKitEmailService already no-ops when SMTP
            // is unconfigured or the key ring can't decrypt the password; this catch
            // covers the rest (server down, auth rejected, timeout).
            try
            {
                var subject = $"Your KTF export is ready ({paged.Rows.Count:N0} rows)";
                var html = BuildEmailBody(requesterName, paged.Total, paged.Rows.Count, expiresAt, url);
                await _email.SendAsync(requesterEmail, subject, html);
            }
            catch (Exception ex)
            {
                _log.LogError(ex,
                    "KTF export job {JobId} produced {File} but the notification to {Email} failed. " +
                    "The export is downloadable from /Exports.",
                    jobId, fileName, requesterEmail);
            }
        }
        catch (Exception ex)
        {
            await _logRepo.UpdateFailedAsync(jobId, ex.ToString());
            throw;
        }
    }

    /// <summary>
    /// Resolves <c>{StorageRoot}/KTF_{yyyyMMdd_HHmm}_{jobId:N}.xlsx</c>.
    /// The jobId hex is mandatory in the name — ExportsApiController.Download
    /// globs the directory by it and derives Content-Disposition from the disk
    /// filename, so it rides along into the operator's Downloads folder.
    /// Timestamp is stamped in the app's default zone, not UTC, so the name
    /// agrees with the dates printed inside the sheet.
    /// </summary>
    public (string Path, string FileName) ResolveFilePath(Guid jobId)
    {
        var dir = Path.IsPathRooted(_opts.StorageRoot)
            ? _opts.StorageRoot
            : Path.Combine(AppContext.BaseDirectory, "..", "..", "..", _opts.StorageRoot);
        Directory.CreateDirectory(dir);
        var stamp = ToZone(DateTime.UtcNow, ResolveZone(null)).ToString("yyyyMMdd_HHmm", CultureInfo.InvariantCulture);
        var fileName = $"KTF_{stamp}_{jobId:N}.xlsx";
        return (Path.GetFullPath(Path.Combine(dir, fileName)), fileName);
    }

    // ------------------------------------------------------------------
    // Time helpers — UTC → warehouse-local, then shift derivation.
    // ------------------------------------------------------------------

    /// <summary>
    /// IANA id → TimeZoneInfo, falling back to Asia/Bangkok and then UTC.
    /// Warehouses.Timezone is operator-editable free text validated only for
    /// length (MastersService.ValidateWarehouse), so a bad id must degrade
    /// rather than fail a whole export.
    /// </summary>
    private static TimeZoneInfo ResolveZone(string? ianaId)
    {
        foreach (var id in new[] { ianaId, FallbackTimezone })
        {
            if (string.IsNullOrWhiteSpace(id)) continue;
            try { return TimeZoneInfo.FindSystemTimeZoneById(id); }
            catch (TimeZoneNotFoundException) { }
            catch (InvalidTimeZoneException) { }
        }
        return TimeZoneInfo.Utc;
    }

    /// <summary>
    /// Dapper hands back DateTimeKind.Unspecified from DATETIME2; ConvertTimeFromUtc
    /// throws on anything already marked Local, so pin the Kind first.
    /// </summary>
    private static DateTime ToZone(DateTime utc, TimeZoneInfo zone) =>
        TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), zone);

    /// <summary>
    /// PullItems.Description is the part description when someone supplied one,
    /// but the ERP sync leaves it echoing ItemCode for most rows (224 of 226 in
    /// the current data). Echoing that into Description would just duplicate the
    /// Part Number column, so emit it only when it says something new — a blank
    /// cell is the honest answer, and matches what the operator already fills by
    /// hand today. To populate these properly, Receivx needs the part→description
    /// catalogue that currently lives in the reference workbook's "Lookup" sheet.
    /// </summary>
    private static string DescriptionFor(ReceiptJournalRow row) =>
        string.IsNullOrWhiteSpace(row.ItemDescription) ||
        string.Equals(row.ItemDescription.Trim(), row.ItemCode?.Trim(), StringComparison.OrdinalIgnoreCase)
            ? ""
            : row.ItemDescription;

    /// <summary>Window slot → shift. HourOfDay is a byte in [0,23], already warehouse-local.</summary>
    private static string ClassifyShift(byte hourOfDay) =>
        hourOfDay >= DayShiftStartHour && hourOfDay < NightShiftStartHour ? "DAY" : "NIGHT";

    // ------------------------------------------------------------------
    // ClosedXML workbook builder — one "KTF" sheet, 15 columns, styled to
    // match the reference form. No Header/filter-snapshot sheet: this is a
    // form meant to be printed, not an audit artifact.
    // ------------------------------------------------------------------
    private static void WriteWorkbook(string path, IReadOnlyList<ReceiptJournalRow> rows)
    {
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add("KTF");
        ws.Style.Font.FontName = FontName;
        ws.Style.Font.FontSize = BodyFontSize;

        for (int c = 0; c < Headers.Length; c++)
            ws.Cell(1, c + 1).Value = Headers[c];

        var headerRange = ws.Range(1, 1, 1, Headers.Length);
        headerRange.Style.Fill.BackgroundColor = HeaderFill;
        headerRange.Style.Font.Italic = true;   // italic but NOT bold — matches the reference form
        headerRange.Style.Font.FontSize = HeaderFontSize;
        headerRange.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        headerRange.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.SheetView.FreezeRows(1);

        for (int r = 0; r < rows.Count; r++)
        {
            var row = rows[r];
            var x = r + 2;

            // Date comes from the receive timestamp (UTC → warehouse-local);
            // SHIFT/Time come from the booked window slot. See the shift-model
            // note above for why these two have different sources.
            var localDate = ToZone(row.ReceivedAt, ResolveZone(row.WarehouseTimezone)).Date;

            ws.Cell(x, 1).Value = row.ProductFamily ?? "";
            ws.Cell(x, 2).Value = localDate;
            ws.Cell(x, 3).Value = ClassifyShift(row.HourOfDay);
            ws.Cell(x, 4).Value = TimeSpan.FromHours(row.HourOfDay);
            ws.Cell(x, 5).SetValue(row.PullNumber);
            ws.Cell(x, 6).SetValue(row.ItemCode);
            ws.Cell(x, 7).Value = row.QtyReceived;
            ws.Cell(x, 8).Value = DescriptionFor(row);
            ws.Cell(x, 9).Value = row.FromSubInventory ?? "";
            ws.Cell(x, 10).Value = row.ToSubInventory ?? "";
            ws.Cell(x, 11).SetValue(row.InvoiceNo ?? "");
            ws.Cell(x, 12).SetValue(row.PoNumber);
            ws.Cell(x, 13).Value = row.VendorName ?? row.VendorCode ?? "";
            ws.Cell(x, 14).Value = "";                     // Trial/EEN — blank per the form
            ws.Cell(x, 15).Value = "";                     // Remark — blank per the form
        }

        // SetValue(string) on the identifier columns stops Excel re-interpreting
        // values that merely look numeric — a part number like "0F47229" or an
        // invoice like "202651011" must keep its leading zeros and stay text.

        var lastRow = Math.Max(1, rows.Count + 1);
        var all = ws.Range(1, 1, lastRow, Headers.Length);
        all.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        all.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        all.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        if (rows.Count > 0)
        {
            foreach (var c in FilledColumns)
                ws.Range(2, c, lastRow, c).Style.Fill.BackgroundColor = DataFill;

            var desc = ws.Range(2, DescriptionColumn, lastRow, DescriptionColumn);
            desc.Style.Alignment.WrapText = true;
            desc.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;

            ws.Range(2, DateColumn, lastRow, DateColumn).Style.NumberFormat.NumberFormatId = DateFormatId;
            ws.Range(2, TimeColumn, lastRow, TimeColumn).Style.NumberFormat.Format = TimeFormat;
            ws.Range(2, QtyColumn, lastRow, QtyColumn).Style.NumberFormat.Format = QtyFormat;
        }

        ws.Columns().AdjustToContents();
        // AdjustToContents collapses the always-blank columns to unusably narrow;
        // the form needs writable space in them, and Description needs room to wrap.
        ws.Column(DescriptionColumn).Width = 40;
        foreach (var c in new[] { 14, 15 })
            ws.Column(c).Width = Math.Max(ws.Column(c).Width, 16);

        wb.SaveAs(path);
    }

    private static string BuildEmailBody(string requesterName, int total, int exported, DateTime expiresAt, string downloadUrl)
    {
        // `total` counts receive rows only — the job pins Kind before querying,
        // so this compares like with like.
        var truncated = exported < total
            ? $"<p>Note: this export contains the first <b>{exported:N0}</b> of <b>{total:N0}</b> matching rows. Narrow the date range to capture the rest.</p>"
            : "";
        return $@"<!DOCTYPE html>
<html><body style='font-family: Arial, sans-serif; color: #1a1d20; max-width: 600px;'>
    <p>Hi {System.Net.WebUtility.HtmlEncode(requesterName)},</p>
    <p>Your KTF export is ready: <b>{exported:N0} rows</b>.</p>
    <p style='color: #5a626c; font-size: 12px;'>
        Receives only — reversals and cancelled entries are excluded by design.
        Dates are shown in each warehouse's local time; SHIFT and Time reflect
        the booked receiving window.
    </p>
    {truncated}
    <p>
        <a href='{downloadUrl}' style='display: inline-block; padding: 10px 20px;
            background: #1f4d2b; color: #fff; text-decoration: none; border-radius: 6px;'>
            Download .xlsx
        </a>
    </p>
    <p style='color: #5a626c; font-size: 12px;'>
        Link expires {expiresAt:yyyy-MM-dd HH:mm} UTC. After that the file is
        automatically deleted and the link returns 410 Gone.
    </p>
    <hr style='border: 0; border-top: 1px solid #e6e3dc;'>
    <p style='color: #8a8f97; font-size: 11px;'>ReceivingOps — automated notification</p>
</body></html>";
    }
}
