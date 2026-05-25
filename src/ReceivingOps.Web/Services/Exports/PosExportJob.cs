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
    private readonly IExportJobLogRepository _logRepo;
    private readonly ExportOptions _opts;
    private readonly ILogger<PosExportJob> _log;

    public PosExportJob(
        IPurchaseOrderRepository pos,
        IEmailService email,
        ExportTokenService tokens,
        IExportJobLogRepository logRepo,
        IOptions<ExportOptions> opts,
        ILogger<PosExportJob> log)
    {
        _pos = pos;
        _email = email;
        _tokens = tokens;
        _logRepo = logRepo;
        _opts = opts.Value;
        _log = log;
    }

    [AutomaticRetry(Attempts = 3, DelaysInSeconds = new[] { 30, 120, 600 })]
    [Queue("exports")]
    public async Task RunAsync(Guid jobId, PosExportRequest request, string requesterEmail, string requesterName)
    {
        _log.LogInformation("Pos export job {JobId} starting for {Email}", jobId, requesterEmail);
        await _logRepo.UpdateRunningAsync(jobId);
        try
        {
            var (items, total) = await _pos.QueryAsync(
                request.WarehouseId, request.Status, null, request.Q,
                request.OrderDateFrom, request.OrderDateTo,
                skip: 0, take: Math.Max(1, request.MaxRows));
            _log.LogInformation("Pos export job {JobId} fetched {Count} of {Total} rows", jobId, items.Count, total);

            // Phase 9 — line-level rows for the new "Lines" sheet (20 ERP fields
            // from db/021 + PO header context). Single round trip joining lines
            // → PO header → warehouse for the PO set we just paged.
            var lineRows = await _pos.GetLinesForPosAsync(items.Select(i => i.Id).ToList());
            _log.LogInformation("Pos export job {JobId} fetched {LineCount} line-level rows for ERP detail sheet",
                jobId, lineRows.Count);

            var (filePath, fileName) = ResolveFilePath(jobId);
            WriteWorkbook(filePath, items, total, request, lineRows);

            var expiresAt = DateTime.UtcNow.Add(_opts.FileLifetime);
            var token = _tokens.Issue(jobId, expiresAt);
            var baseUrl = _opts.BaseUrl.TrimEnd('/');
            var url = $"{baseUrl}/api/exports/{jobId:D}/download?token={token}";

            var subject = $"Your purchase orders export is ready ({total:N0} rows)";
            var html = BuildEmailBody(requesterName, total, items.Count, expiresAt, url);
            await _email.SendAsync(requesterEmail, subject, html);

            await _logRepo.UpdateSucceededAsync(jobId, fileName, items.Count);
            _log.LogInformation("Pos export job {JobId} complete: {File} ({Bytes} bytes), email queued to {Email}",
                jobId, filePath, new FileInfo(filePath).Length, requesterEmail);
        }
        catch (Exception ex)
        {
            await _logRepo.UpdateFailedAsync(jobId, ex.ToString());
            throw;
        }
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

    private static void WriteWorkbook(string path, IReadOnlyList<PoListRow> rows, int total,
        PosExportRequest req, IReadOnlyList<PoLineExportRow> lineRows)
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

        // Phase 9 — Lines sheet: one row per PO line × (PO context + line basic
        // + 20 ERP fields from db/021). Separate from the PO-summary sheet so
        // operators relying on header-level aggregates aren't affected; this
        // sheet is purely additive. Grouped columns logically (Tracking IDs /
        // Location / Operations / Dates / Note) to match the field-redistribution
        // discussion in db/021.
        WriteLinesSheet(wb, lineRows);

        wb.SaveAs(path);
    }

    private static void WriteLinesSheet(XLWorkbook wb, IReadOnlyList<PoLineExportRow> rows)
    {
        var ws = wb.Worksheets.Add("Lines");

        var headers = new[]
        {
            // PO context (8)
            "PoNumber", "OrderDate", "ExpectedDate", "VendorCode", "VendorName",
            "WarehouseCode", "PoStatus",
            "LineNumber",
            // Line basic (5)
            "ItemCode", "Description", "OrderedQty", "ReceivedQty", "RemainingQty",
            // ERP — Tracking IDs (10)
            "InvoiceNo", "KanbanNo", "AsnNo", "PCCNo", "BatchNo",
            "ManufacturingControlNo", "ManufacturingReferenceNo",
            "CustomerReferenceNo", "ExportDeclarationNo", "VendorItem",
            // ERP — Location (6)
            "PalletId", "VmiPalletId", "Location", "Building",
            "SubInventory", "ToLocation",
            // ERP — Operations (2)
            "ProductionLine", "OrderRound",
            // ERP — Dates (1)
            "DeliveryDate",
            // ERP — Note (1)
            "Note",
        };
        for (int c = 0; c < headers.Length; c++)
            ws.Cell(1, c + 1).Value = headers[c];
        ws.Range(1, 1, 1, headers.Length).Style.Font.Bold = true;
        ws.SheetView.FreezeRows(1);

        for (int r = 0; r < rows.Count; r++)
        {
            var row = rows[r];
            var x = r + 2;
            int c = 1;
            ws.Cell(x, c++).Value = row.PoNumber;
            ws.Cell(x, c++).Value = row.OrderDate;
            ws.Cell(x, c++).Value = row.ExpectedDate.HasValue ? (XLCellValue)row.ExpectedDate.Value : "";
            ws.Cell(x, c++).Value = row.VendorCode ?? "";
            ws.Cell(x, c++).Value = row.VendorName ?? "";
            ws.Cell(x, c++).Value = row.WarehouseCode;
            ws.Cell(x, c++).Value = row.PoStatus;
            ws.Cell(x, c++).Value = row.LineNumber;
            ws.Cell(x, c++).Value = row.ItemCode;
            ws.Cell(x, c++).Value = row.Description;
            ws.Cell(x, c++).Value = row.OrderedQty;
            ws.Cell(x, c++).Value = row.ReceivedQty;
            ws.Cell(x, c++).Value = row.RemainingQty;
            // ERP — Tracking IDs
            ws.Cell(x, c++).Value = row.InvoiceNo ?? "";
            ws.Cell(x, c++).Value = row.KanbanNo ?? "";
            ws.Cell(x, c++).Value = row.AsnNo ?? "";
            ws.Cell(x, c++).Value = row.PCCNo ?? "";
            ws.Cell(x, c++).Value = row.BatchNo ?? "";
            ws.Cell(x, c++).Value = row.ManufacturingControlNo ?? "";
            ws.Cell(x, c++).Value = row.ManufacturingReferenceNo ?? "";
            ws.Cell(x, c++).Value = row.CustomerReferenceNo ?? "";
            ws.Cell(x, c++).Value = row.ExportDeclarationNo ?? "";
            ws.Cell(x, c++).Value = row.VendorItem ?? "";
            // ERP — Location
            ws.Cell(x, c++).Value = row.PalletId ?? "";
            ws.Cell(x, c++).Value = row.VmiPalletId ?? "";
            ws.Cell(x, c++).Value = row.Location ?? "";
            ws.Cell(x, c++).Value = row.Building ?? "";
            ws.Cell(x, c++).Value = row.SubInventory ?? "";
            ws.Cell(x, c++).Value = row.ToLocation ?? "";
            // ERP — Operations
            ws.Cell(x, c++).Value = row.ProductionLine ?? "";
            ws.Cell(x, c++).Value = row.OrderRound ?? "";
            // ERP — Dates
            ws.Cell(x, c++).Value = row.DeliveryDate.HasValue ? (XLCellValue)row.DeliveryDate.Value : "";
            // ERP — Note
            ws.Cell(x, c++).Value = row.Note ?? "";
        }
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
