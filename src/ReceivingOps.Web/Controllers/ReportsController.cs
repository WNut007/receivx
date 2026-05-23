using System.Security.Claims;
using FastReport.Export.PdfSimple;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers;

// v2.x Phase 7.3 — Reports view (Delivery Order render).
// CanManagePulls = admin + supervisor (matches Phase 5c /Pos convention —
// the operator who closed the pull also wants to print the paperwork; non-
// admins on other warehouses are scoped out at the repo query.)
[Authorize(Policy = "CanManagePulls")]
public class ReportsController : Controller
{
    private readonly IPullRepository _pulls;
    private readonly IDeliveryOrderService _doService;

    public ReportsController(IPullRepository pulls, IDeliveryOrderService doService)
    {
        _pulls = pulls;
        _doService = doService;
    }

    // GET /Reports — list of closed pulls with delivery activity (the DO
    // candidates). Non-admin sessions get their session warehouse only.
    [HttpGet("/Reports")]
    public async Task<IActionResult> Index(CancellationToken ct)
    {
        var wh = User.IsInRole("admin") ? (Guid?)null : ParseGuid(User.FindFirstValue("warehouseId"));
        var rows = await _pulls.GetClosedWithReceiptsAsync(wh, ct);
        ViewData["PageId"] = "reports";
        return View(rows);
    }

    // GET /Reports/Do/{id} — page chrome that embeds the PDF in an iframe.
    // FastReport.OpenSource.Web does not ship the interactive JS viewer
    // assets, so we lean on the browser's built-in PDF viewer. BuildAsync
    // still runs as the eligibility gate (open pull or no-receipt pull →
    // 400 before the iframe even loads).
    [HttpGet("/Reports/Do/{id:guid}")]
    public async Task<IActionResult> Do(Guid id, CancellationToken ct)
    {
        try
        {
            using var report = await _doService.BuildAsync(id, ct);
            // Scope-check: same pattern as PullsApiController.ResolveAsync.
            // Non-admin → 403 if the pull is not on their session warehouse.
            if (!User.IsInRole("admin"))
            {
                var sessionWh = ParseGuid(User.FindFirstValue("warehouseId"));
                var pull = await _pulls.GetByIdAsync(id, ct);
                if (pull is null || pull.WarehouseId != sessionWh)
                    return Forbid();
            }
            ViewData["PageId"] = "reports";
            ViewData["PullId"] = id;
            return View();
        }
        catch (NotFoundException) { return NotFound(); }
        catch (BusinessException ex) { return BadRequest(ex.Message); }
    }

    // GET /Reports/Do/{id}/pdf — direct PDF stream download. Bypasses the
    // WebReport viewer; useful for one-click "save to disk" + email-the-
    // delivery-receipt-to-the-vendor flows.
    [HttpGet("/Reports/Do/{id:guid}/pdf")]
    public async Task<IActionResult> DoPdf(Guid id, CancellationToken ct)
    {
        try
        {
            using var report = await _doService.BuildAsync(id, ct);
            if (!User.IsInRole("admin"))
            {
                var sessionWh = ParseGuid(User.FindFirstValue("warehouseId"));
                var pull = await _pulls.GetByIdAsync(id, ct);
                if (pull is null || pull.WarehouseId != sessionWh)
                    return Forbid();
            }
            using var ms = new MemoryStream();
            using var pdf = new PDFSimpleExport();
            report.Export(pdf, ms);

            // Resolve pull number for the filename — separate fetch is fine
            // (one extra query per download; cached at the SQL Server level).
            var detail = await _pulls.GetByIdAsync(id, ct);
            var filename = $"{(detail?.PullNumber ?? id.ToString())}-DO.pdf";
            return File(ms.ToArray(), "application/pdf", filename);
        }
        catch (NotFoundException) { return NotFound(); }
        catch (BusinessException ex) { return BadRequest(ex.Message); }
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;
}
