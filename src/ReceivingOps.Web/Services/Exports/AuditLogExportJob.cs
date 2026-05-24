using ClosedXML.Excel;
using Hangfire;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services.Email;

namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 ext — audit log export worker. Mirrors
/// <see cref="TransactionsExportJob"/>/<see cref="PosExportJob"/>:
/// query → ClosedXML → file → signed URL → email. Admin-gated at
/// the controller; the job itself doesn't re-check roles (Hangfire
/// runs without an HttpContext anyway).
/// </summary>
public class AuditLogExportJob
{
    private readonly IAuditRepository _audit;
    private readonly IEmailService _email;
    private readonly ExportTokenService _tokens;
    private readonly IExportJobLogRepository _logRepo;
    private readonly ExportOptions _opts;
    private readonly ILogger<AuditLogExportJob> _log;

    public AuditLogExportJob(
        IAuditRepository audit,
        IEmailService email,
        ExportTokenService tokens,
        IExportJobLogRepository logRepo,
        IOptions<ExportOptions> opts,
        ILogger<AuditLogExportJob> log)
    {
        _audit = audit;
        _email = email;
        _tokens = tokens;
        _logRepo = logRepo;
        _opts = opts.Value;
        _log = log;
    }

    [AutomaticRetry(Attempts = 3, DelaysInSeconds = new[] { 30, 120, 600 })]
    [Queue("exports")]
    public async Task RunAsync(Guid jobId, AuditLogExportRequest request, string requesterEmail, string requesterName)
    {
        _log.LogInformation("Audit export job {JobId} starting for {Email}", jobId, requesterEmail);
        await _logRepo.UpdateRunningAsync(jobId);
        try
        {
            var rows = await _audit.QueryForExportAsync(request.ToQuery());
            _log.LogInformation("Audit export job {JobId} fetched {Count} rows", jobId, rows.Count);

            var (filePath, fileName) = ResolveFilePath(jobId);
            WriteWorkbook(filePath, rows, request);

            var expiresAt = DateTime.UtcNow.Add(_opts.FileLifetime);
            var token = _tokens.Issue(jobId, expiresAt);
            var baseUrl = _opts.BaseUrl.TrimEnd('/');
            var url = $"{baseUrl}/api/exports/{jobId:D}/download?token={token}";

            var subject = $"Your audit log export is ready ({rows.Count:N0} rows)";
            var html = BuildEmailBody(requesterName, rows.Count, expiresAt, url);
            await _email.SendAsync(requesterEmail, subject, html);

            await _logRepo.UpdateSucceededAsync(jobId, fileName, rows.Count);
            _log.LogInformation("Audit export job {JobId} complete: {File} ({Bytes} bytes), email queued to {Email}",
                jobId, filePath, new FileInfo(filePath).Length, requesterEmail);
        }
        catch (Exception ex)
        {
            await _logRepo.UpdateFailedAsync(jobId, ex.ToString());
            throw;
        }
    }

    /// <summary>Resolves <c>{StorageRoot}/audit-log-{jobId}.xlsx</c>.</summary>
    public (string Path, string FileName) ResolveFilePath(Guid jobId)
    {
        var dir = Path.IsPathRooted(_opts.StorageRoot)
            ? _opts.StorageRoot
            : Path.Combine(AppContext.BaseDirectory, "..", "..", "..", _opts.StorageRoot);
        Directory.CreateDirectory(dir);
        var fileName = $"audit-log-{jobId:N}.xlsx";
        return (Path.GetFullPath(Path.Combine(dir, fileName)), fileName);
    }

    private static void WriteWorkbook(string path, IReadOnlyList<AuditRow> rows, AuditLogExportRequest req)
    {
        using var wb = new XLWorkbook();

        var hs = wb.Worksheets.Add("Header");
        hs.Cell(1, 1).Value = "Field";
        hs.Cell(1, 2).Value = "Value";
        hs.Range(1, 1, 1, 2).Style.Font.Bold = true;
        var meta = new (string, object)[]
        {
            ("Generated at (UTC)", DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss")),
            ("Rows in this export", rows.Count),
            ("Action filter",  req.Action ?? ""),
            ("Search",         req.Q ?? ""),
            ("Occurred from",  req.OccurredFrom?.ToString("yyyy-MM-dd HH:mm:ss") ?? ""),
            ("Occurred to",    req.OccurredTo?.ToString("yyyy-MM-dd HH:mm:ss") ?? ""),
        };
        for (int i = 0; i < meta.Length; i++)
        {
            hs.Cell(i + 2, 1).Value = meta[i].Item1;
            hs.Cell(i + 2, 2).SetValue(XLCellValue.FromObject(meta[i].Item2));
        }
        hs.Columns().AdjustToContents();

        var ws = wb.Worksheets.Add("Audit Log");
        var headers = new[]
        {
            "OccurredAt (UTC)", "ActionType", "EntityType", "EntityId",
            "ActorName", "ActorUserId", "IpAddress", "Message",
        };
        for (int c = 0; c < headers.Length; c++) ws.Cell(1, c + 1).Value = headers[c];
        ws.Range(1, 1, 1, headers.Length).Style.Font.Bold = true;
        ws.SheetView.FreezeRows(1);

        for (int r = 0; r < rows.Count; r++)
        {
            var row = rows[r];
            var x = r + 2;
            ws.Cell(x, 1).Value = row.OccurredAt;
            ws.Cell(x, 2).Value = row.ActionType;
            ws.Cell(x, 3).Value = row.EntityType ?? "";
            ws.Cell(x, 4).Value = row.EntityId ?? "";
            ws.Cell(x, 5).Value = row.ActorName ?? "";
            ws.Cell(x, 6).Value = row.ActorUserId?.ToString() ?? "";
            ws.Cell(x, 7).Value = row.IpAddress ?? "";
            ws.Cell(x, 8).Value = row.Message;
        }

        wb.SaveAs(path);
    }

    private static string BuildEmailBody(string requesterName, int count, DateTime expiresAt, string downloadUrl)
    {
        return $@"<!DOCTYPE html>
<html><body style='font-family: Arial, sans-serif; color: #1a1d20; max-width: 600px;'>
    <p>Hi {System.Net.WebUtility.HtmlEncode(requesterName)},</p>
    <p>Your audit log export is ready: <b>{count:N0} rows</b>.</p>
    <p>
        <a href='{downloadUrl}' style='display: inline-block; padding: 10px 20px;
            background: #1f4d2b; color: #fff; text-decoration: none; border-radius: 6px;'>
            Download .xlsx
        </a>
    </p>
    <p style='color: #5a626c; font-size: 12px;'>
        Link expires {expiresAt:yyyy-MM-dd HH:mm} UTC. Audit data is sensitive — do not forward.
    </p>
    <hr style='border: 0; border-top: 1px solid #e6e3dc;'>
    <p style='color: #8a8f97; font-size: 11px;'>ReceivingOps — automated notification</p>
</body></html>";
    }
}
