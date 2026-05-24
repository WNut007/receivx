using ClosedXML.Excel;
using Hangfire;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services.Email;

namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 extension — Pos export worker. Mirrors
/// <see cref="TransactionsExportJob"/>: query → ClosedXML → file →
/// signed URL → email. Permission gating happens at the controller —
/// admin OR supervisor (procurement leads need this too, not just admins).
///
/// File layout: Header sheet with the filter snapshot + Pos sheet with
/// the catalog rows.
/// </summary>
public class PosExportJob
{
    private readonly IPurchaseOrderRepository _pos;
    private readonly IEmailService _email;
    private readonly ExportTokenService _tokens;
    private readonly ExportOptions _opts;
    private readonly ILogger<PosExportJob> _log;

    public PosExportJob(
        IPurchaseOrderRepository pos,
        IEmailService email,
        ExportTokenService tokens,
        IOptions<ExportOptions> opts,
        ILogger<PosExportJob> log)
    {
        _pos = pos;
        _email = email;
        _tokens = tokens;
        _opts = opts.Value;
        _log = log;
    }

    [AutomaticRetry(Attempts = 3, DelaysInSeconds = new[] { 30, 120, 600 })]
    [Queue("exports")]
    public async Task RunAsync(Guid jobId, PosExportRequest request, string requesterEmail, string requesterName)
    {
        _log.LogInformation("Pos export job {JobId} starting for {Email}", jobId, requesterEmail);

        var (items, total) = await _pos.QueryAsync(
            request.WarehouseId, request.Status, null, request.Q,
            request.OrderDateFrom, request.OrderDateTo,
            skip: 0, take: Math.Max(1, request.MaxRows));
        _log.LogInformation("Pos export job {JobId} fetched {Count} of {Total} rows", jobId, items.Count, total);

        var (filePath, fileName) = ResolveFilePath(jobId);
        WriteWorkbook(filePath, items, total, request);

        var expiresAt = DateTime.UtcNow.Add(_opts.FileLifetime);
        var token = _tokens.Issue(jobId, expiresAt);
        var baseUrl = _opts.BaseUrl.TrimEnd('/');
        var url = $"{baseUrl}/api/exports/{jobId:D}/download?token={token}";

        var subject = $"Your purchase orders export is ready ({total:N0} rows)";
        var html = BuildEmailBody(requesterName, total, items.Count, expiresAt, url);
        await _email.SendAsync(requesterEmail, subject, html);

        _log.LogInformation("Pos export job {JobId} complete: {File} ({Bytes} bytes), email queued to {Email}",
            jobId, filePath, new FileInfo(filePath).Length, requesterEmail);
    }

    /// <summary>Resolves <c>{StorageRoot}/pos-{jobId}.xlsx</c>; same dir scheme as TransactionsExportJob.</summary>
    public (string Path, string FileName) ResolveFilePath(Guid jobId)
    {
        var dir = Path.IsPathRooted(_opts.StorageRoot)
            ? _opts.StorageRoot
            : Path.Combine(AppContext.BaseDirectory, "..", "..", "..", _opts.StorageRoot);
        Directory.CreateDirectory(dir);
        var fileName = $"pos-{jobId:N}.xlsx";
        return (Path.GetFullPath(Path.Combine(dir, fileName)), fileName);
    }

    private static void WriteWorkbook(string path, IReadOnlyList<PoListRow> rows, int total, PosExportRequest req)
    {
        using var wb = new XLWorkbook();

        // Header sheet
        var hs = wb.Worksheets.Add("Header");
        hs.Cell(1, 1).Value = "Field";
        hs.Cell(1, 2).Value = "Value";
        hs.Range(1, 1, 1, 2).Style.Font.Bold = true;
        var meta = new (string, object)[]
        {
            ("Generated at (UTC)", DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss")),
            ("Total matching rows", total),
            ("Rows in this export", rows.Count),
            ("Warehouse ID",        req.WarehouseId?.ToString() ?? ""),
            ("Status",              req.Status ?? ""),
            ("Order date from",     req.OrderDateFrom?.ToString("yyyy-MM-dd") ?? ""),
            ("Order date to",       req.OrderDateTo?.ToString("yyyy-MM-dd") ?? ""),
            ("Search",              req.Q ?? ""),
        };
        for (int i = 0; i < meta.Length; i++)
        {
            hs.Cell(i + 2, 1).Value = meta[i].Item1;
            hs.Cell(i + 2, 2).SetValue(XLCellValue.FromObject(meta[i].Item2));
        }
        hs.Columns().AdjustToContents();

        // Pos sheet — column order matches the spec
        var ws = wb.Worksheets.Add("Purchase Orders");
        var headers = new[]
        {
            "PoNumber", "OrderDate", "ExpectedDate", "VendorCode", "VendorName",
            "WarehouseCode", "Status",
            "LineCount", "TotalOrdered", "TotalReceived",
            "CreatedAt (UTC)", "ClosedAt (UTC)",
            "PullId", "PullNumber",
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
            ws.Cell(x, 1).Value  = row.PoNumber;
            ws.Cell(x, 2).Value  = row.OrderDate;
            ws.Cell(x, 3).Value  = row.ExpectedDate.HasValue ? (XLCellValue)row.ExpectedDate.Value : "";
            ws.Cell(x, 4).Value  = row.VendorCode ?? "";
            ws.Cell(x, 5).Value  = row.VendorName ?? "";
            ws.Cell(x, 6).Value  = row.WarehouseCode;
            ws.Cell(x, 7).Value  = row.Status;
            ws.Cell(x, 8).Value  = row.LineCount;
            ws.Cell(x, 9).Value  = row.TotalOrdered;
            ws.Cell(x, 10).Value = row.TotalReceived;
            ws.Cell(x, 11).Value = row.CreatedAt;
            ws.Cell(x, 12).Value = row.ClosedAt.HasValue ? (XLCellValue)row.ClosedAt.Value : "";
            ws.Cell(x, 13).Value = row.PullId?.ToString() ?? "";
            ws.Cell(x, 14).Value = row.PullNumber ?? "";
        }

        wb.SaveAs(path);
    }

    private static string BuildEmailBody(string requesterName, int total, int exported, DateTime expiresAt, string downloadUrl)
    {
        var truncated = exported < total
            ? $"<p>Note: this export contains the first <b>{exported:N0}</b> of <b>{total:N0}</b> matching POs.</p>"
            : "";
        return $@"<!DOCTYPE html>
<html><body style='font-family: Arial, sans-serif; color: #1a1d20; max-width: 600px;'>
    <p>Hi {System.Net.WebUtility.HtmlEncode(requesterName)},</p>
    <p>Your purchase orders export is ready: <b>{exported:N0} rows</b>.</p>
    {truncated}
    <p>
        <a href='{downloadUrl}' style='display: inline-block; padding: 10px 20px;
            background: #1f4d2b; color: #fff; text-decoration: none; border-radius: 6px;'>
            Download .xlsx
        </a>
    </p>
    <p style='color: #5a626c; font-size: 12px;'>
        Link expires {expiresAt:yyyy-MM-dd HH:mm} UTC. After that the file is deleted and the link returns 410 Gone.
    </p>
    <hr style='border: 0; border-top: 1px solid #e6e3dc;'>
    <p style='color: #8a8f97; font-size: 11px;'>ReceivingOps — automated notification</p>
</body></html>";
    }
}
