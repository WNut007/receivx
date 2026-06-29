using System.Security.Claims;
using FastReport.Export.PdfSimple;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers.Api;

// v2.x Phase 7.4 — JSON/HTML API surface for the Reports page.
//   GET /api/reports/do/{id}/preview     → HTML fragment from _DoPreview.cshtml
//   GET /api/reports/do/{id}/export.pdf  → PDF stream (FastReport, multi-page)
[ApiController]
[Authorize(Policy = "CanViewReports")]
[Route("api/reports")]
public class ReportsApiController : Controller
{
    private readonly IDeliveryOrderService _doService;
    private readonly IPullRepository _pulls;

    public ReportsApiController(IDeliveryOrderService doService, IPullRepository pulls)
    {
        _doService = doService;
        _pulls = pulls;
    }

    // GET /api/reports/do/{id}/preview → HTML fragment for the preview pane.
    // Non-admin sessions are restricted to their session warehouse — the
    // scope check happens before BuildData so a forbidden caller doesn't
    // even see the existence-or-not signal in the response timing.
    [HttpGet("do/{id:guid}/preview")]
    public async Task<IActionResult> Preview(Guid id, [FromQuery] string? type, CancellationToken ct)
    {
        try
        {
            if (!await EnsureWarehouseScopeAsync(id, ct)) return Forbid();
            var reportType = ParseReportType(type);
            var data = await _doService.GetReportDataAsync(id, reportType, ct);
            // Full path — the api controller's view discovery would look under
            // Views/ReportsApi/ otherwise (controller name → folder mapping).
            var partial = reportType == ReportType.DeliveryOrder
                ? "~/Views/Reports/_DsvOrderPreview.cshtml"
                : "~/Views/Reports/_DoPreview.cshtml";
            return PartialView(partial, data);
        }
        catch (NotFoundException) { return NotFound(); }
        catch (BusinessException ex) { return BadRequest(new { error = ex.Message }); }
    }

    // GET /api/reports/do/{id}/export.pdf → PDF download. Always attachment
    // (the iframe-preview disposition trick from Phase 7.3 is moot now that
    // the preview is an HTML render, not an embedded PDF). Filename uses
    // the pull number so the operator's downloads folder shows
    // PL-XXXX-DO.pdf rather than a bare GUID.
    [HttpGet("do/{id:guid}/export.pdf")]
    public async Task<IActionResult> ExportPdf(Guid id, [FromQuery] string? type, CancellationToken ct)
    {
        try
        {
            if (!await EnsureWarehouseScopeAsync(id, ct)) return Forbid();
            using var report = await _doService.BuildAsync(id, ParseReportType(type), ct);
            using var ms = new MemoryStream();
            using var pdf = new PDFSimpleExport();
            report.Export(pdf, ms);

            var detail = await _pulls.GetByIdAsync(id, ct);
            var filename = $"{(detail?.PullNumber ?? id.ToString())}-DO.pdf";
            Response.Headers["Content-Disposition"] = $"attachment; filename=\"{filename}\"";
            return File(ms.ToArray(), "application/pdf");
        }
        catch (NotFoundException) { return NotFound(); }
        catch (BusinessException ex) { return BadRequest(new { error = ex.Message }); }
    }

    /// <summary>Returns false when the non-admin caller's warehouse claim doesn't match the pull's warehouse.</summary>
    private async Task<bool> EnsureWarehouseScopeAsync(Guid pullId, CancellationToken ct)
    {
        if (User.IsInRole("admin")) return true;
        var sessionWh = ParseGuid(User.FindFirstValue("warehouseId"));
        var pull = await _pulls.GetByIdAsync(pullId, ct);
        return pull is not null && pull.WarehouseId == sessionWh;
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;

    /// <summary>Maps the ?type= query (order|order-dsv → DeliveryOrder; anything else → DeliveryNote).</summary>
    private static ReportType ParseReportType(string? type) =>
        string.Equals(type, "order", StringComparison.OrdinalIgnoreCase)
            ? ReportType.DeliveryOrder
            : ReportType.DeliveryNote;
}
