using ClosedXML.Excel;
using Hangfire;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services.Email;

namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 — the actual export worker. Hangfire invokes
/// <see cref="RunAsync"/> on a background worker thread; this method:
///   1. Queries the full filtered result set (capped at MaxRows)
///   2. Streams it into a ClosedXML workbook
///   3. Writes the workbook to <c>{StorageRoot}/{jobId}.xlsx</c>
///   4. Builds a signed download URL with 24h expiry
///   5. Emails the requester
///
/// All five steps must succeed for the job to be marked Succeeded;
/// Hangfire retries on exception per the [AutomaticRetry] attribute.
/// File path is deterministic from jobId, so retries overwrite cleanly.
/// </summary>
public class TransactionsExportJob
{
    private readonly IReceiptRepository _receipts;
    private readonly IEmailService _email;
    private readonly ExportTokenService _tokens;
    private readonly IExportJobLogRepository _logRepo;
    private readonly ExportOptions _opts;
    private readonly ILogger<TransactionsExportJob> _log;

    public TransactionsExportJob(
        IReceiptRepository receipts,
        IEmailService email,
        ExportTokenService tokens,
        IExportJobLogRepository logRepo,
        IOptions<ExportOptions> opts,
        ILogger<TransactionsExportJob> log)
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
        _log.LogInformation("Export job {JobId} starting for {Email}", jobId, requesterEmail);
        await _logRepo.UpdateRunningAsync(jobId);
        try
        {
            var paged = await _receipts.QueryAsync(request.ToQuery());
            _log.LogInformation("Export job {JobId} fetched {Count} of {Total} rows", jobId, paged.Rows.Count, paged.Total);

            var (filePath, fileName) = ResolveFilePath(jobId);
            WriteWorkbook(filePath, paged.Rows, paged.Total, request);

            var expiresAt = DateTime.UtcNow.Add(_opts.FileLifetime);
            var token = _tokens.Issue(jobId, expiresAt);
            var baseUrl = _opts.BaseUrl.TrimEnd('/');
            var url = $"{baseUrl}/api/exports/{jobId:D}/download?token={token}";

            var subject = $"Your transactions export is ready ({paged.Total:N0} rows)";
            var html = BuildEmailBody(requesterName, paged.Total, paged.Rows.Count, expiresAt, url);
            await _email.SendAsync(requesterEmail, subject, html);

            await _logRepo.UpdateSucceededAsync(jobId, fileName, paged.Rows.Count);
            _log.LogInformation("Export job {JobId} complete: {File} ({Bytes} bytes), email queued to {Email}",
                jobId, filePath, new FileInfo(filePath).Length, requesterEmail);
        }
        catch (Exception ex)
        {
            // Mark the log row failed BEFORE rethrowing — Hangfire's
            // [AutomaticRetry] will rerun us; UpdateRunningAsync at the
            // top of the next attempt overwrites Status back to 'running'.
            await _logRepo.UpdateFailedAsync(jobId, ex.ToString());
            throw;
        }
    }

    /// <summary>Resolves <c>{StorageRoot}/{jobId}.xlsx</c>, creating the dir if needed.</summary>
    public (string Path, string FileName) ResolveFilePath(Guid jobId)
    {
        var dir = Path.IsPathRooted(_opts.StorageRoot)
            ? _opts.StorageRoot
            : Path.Combine(AppContext.BaseDirectory, "..", "..", "..", _opts.StorageRoot);
        Directory.CreateDirectory(dir);
        var fileName = $"transactions-{jobId:N}.xlsx";
        return (Path.GetFullPath(Path.Combine(dir, fileName)), fileName);
    }

    // ------------------------------------------------------------------
    // ClosedXML workbook builder — single "Transactions" sheet with the
    // full journal row shape. Header sheet captures the filter snapshot
    // so the operator can see what they were filtering by when they re-
    // open the file weeks later.
    // ------------------------------------------------------------------
    private static void WriteWorkbook(string path, IReadOnlyList<Models.Dtos.ReceiptJournalRow> rows, int total, TransactionsExportRequest req)
    {
        using var wb = new XLWorkbook();

        // ---- Header sheet (filter snapshot) ----
        var hs = wb.Worksheets.Add("Header");
        hs.Cell(1, 1).Value = "Field";
        hs.Cell(1, 2).Value = "Value";
        hs.Range(1, 1, 1, 2).Style.Font.Bold = true;
        var meta = new (string, object)[]
        {
            ("Generated at (UTC)", DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss")),
            ("Total matching rows", total),
            ("Rows in this export", rows.Count),
            ("Warehouse ID", req.WarehouseId?.ToString() ?? ""),
            ("Warehouse code",   req.WarehouseCode ?? ""),
            ("Date from",        req.DateFrom?.ToString("yyyy-MM-dd HH:mm:ss") ?? ""),
            ("Date to",          req.DateTo?.ToString("yyyy-MM-dd HH:mm:ss") ?? ""),
            ("Action",           req.Kind ?? ""),
            ("Operator name",    req.ReceivedByName ?? ""),
            ("Pull number",      req.PullNumber ?? ""),
            ("PO number",        req.PoNumber ?? ""),
            ("Item code",        req.ItemCode ?? ""),
            ("Hour",             req.Hour?.ToString() ?? ""),
            ("Search",           req.Q ?? ""),
        };
        for (int i = 0; i < meta.Length; i++)
        {
            hs.Cell(i + 2, 1).Value = meta[i].Item1;
            hs.Cell(i + 2, 2).SetValue(XLCellValue.FromObject(meta[i].Item2));
        }
        hs.Columns().AdjustToContents();

        // ---- Transactions sheet ----
        var ws = wb.Worksheets.Add("Transactions");
        var headers = new[]
        {
            "Id", "Kind", "ReceivedAt (UTC)", "QtyReceived", "HourOfDay",
            "PullNumber", "WarehouseCode", "WarehouseName",
            "ItemCode", "ItemDescription",
            "PoNumber", "VendorCode", "VendorName", "PoLineNumber",
            "LotBatch", "PalletId", "BinLocation", "QcStatus", "Note",
            "ReceivedByName", "ReversesReceiptId", "ReversedById", "CancelReason",
            // Phase 9.1 — ERP-sourced PullItem fields (db/024 + view ALTER 025)
            "ProductFamily", "FromSubInventory", "ToSubInventory",
            "TrialId", "PullLocation", "PullPhase", "SpecialControl",
        };
        for (int c = 0; c < headers.Length; c++)
        {
            ws.Cell(1, c + 1).Value = headers[c];
        }
        ws.Range(1, 1, 1, headers.Length).Style.Font.Bold = true;
        ws.SheetView.FreezeRows(1);

        for (int r = 0; r < rows.Count; r++)
        {
            var row = rows[r];
            var x = r + 2;
            ws.Cell(x, 1).Value  = row.Id.ToString();
            ws.Cell(x, 2).Value  = row.Kind;
            ws.Cell(x, 3).Value  = row.ReceivedAt;
            ws.Cell(x, 4).Value  = row.QtyReceived;
            ws.Cell(x, 5).Value  = row.HourOfDay;
            ws.Cell(x, 6).Value  = row.PullNumber;
            ws.Cell(x, 7).Value  = row.WarehouseCode;
            ws.Cell(x, 8).Value  = row.WarehouseName;
            ws.Cell(x, 9).Value  = row.ItemCode;
            ws.Cell(x, 10).Value = row.ItemDescription;
            ws.Cell(x, 11).Value = row.PoNumber;
            ws.Cell(x, 12).Value = row.VendorCode ?? "";
            ws.Cell(x, 13).Value = row.VendorName ?? "";
            ws.Cell(x, 14).Value = row.PoLineNumber;
            ws.Cell(x, 15).Value = row.LotBatch ?? "";
            ws.Cell(x, 16).Value = row.PalletId ?? "";
            ws.Cell(x, 17).Value = row.BinLocation ?? "";
            ws.Cell(x, 18).Value = row.QcStatus;
            ws.Cell(x, 19).Value = row.Note ?? "";
            ws.Cell(x, 20).Value = row.ReceivedByName;
            ws.Cell(x, 21).Value = row.ReversesReceiptId?.ToString() ?? "";
            ws.Cell(x, 22).Value = row.ReversedById?.ToString() ?? "";
            ws.Cell(x, 23).Value = row.CancelReason ?? "";
            // Phase 9.1 — ERP-sourced PullItem fields. Same SpecialControl-last
            // ordering as the on-screen drawer band.
            ws.Cell(x, 24).Value = row.ProductFamily ?? "";
            ws.Cell(x, 25).Value = row.FromSubInventory ?? "";
            ws.Cell(x, 26).Value = row.ToSubInventory ?? "";
            ws.Cell(x, 27).Value = row.TrialId ?? "";
            ws.Cell(x, 28).Value = row.PullLocation ?? "";
            ws.Cell(x, 29).Value = row.PullPhase ?? "";
            ws.Cell(x, 30).Value = row.SpecialControl ?? "";
        }
        // AdjustToContents on a wide sheet with many rows is slow — skip in
        // favor of cheap fixed widths. Operators downloading the file open
        // it in Excel which auto-fits on demand.

        wb.SaveAs(path);
    }

    private static string BuildEmailBody(string requesterName, int total, int exported, DateTime expiresAt, string downloadUrl)
    {
        var truncated = exported < total
            ? $"<p>Note: this export contains the first <b>{exported:N0}</b> of <b>{total:N0}</b> matching rows. Narrow the date range to capture the rest.</p>"
            : "";
        return $@"<!DOCTYPE html>
<html><body style='font-family: Arial, sans-serif; color: #1a1d20; max-width: 600px;'>
    <p>Hi {System.Net.WebUtility.HtmlEncode(requesterName)},</p>
    <p>Your transactions export is ready: <b>{exported:N0} rows</b>.</p>
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
