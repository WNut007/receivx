using System.Security.Claims;
using FastReport.Export.PdfSimple;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers;

// v2.x Phase 7.3 — Reports view (Delivery Order render).
// v2.x Phase 7.4 — Two-pane layout: list + inline HTML preview replaces the
// standalone /Reports/Do/{id} page. The PDF endpoint moves under /api/reports
// in commit 4 — for the duration of commit 1 it stays at /Reports/Do/{id}/pdf
// so the existing smoke + any external links keep working until that commit.
//
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
    // candidates) rendered server-side into the two-pane layout. Non-admin
    // sessions get their session warehouse only.
    [HttpGet("/Reports")]
    public async Task<IActionResult> Index(CancellationToken ct)
    {
        var wh = User.IsInRole("admin") ? (Guid?)null : ParseGuid(User.FindFirstValue("warehouseId"));
        var rows = await _pulls.GetClosedWithReceiptsAsync(wh, ct);
        ViewData["PageId"] = "reports";
        return View(rows);
    }

    // GET /Reports/Do/{id}/pdf — direct PDF stream. Inline disposition so the
    // commit-2 Export PDF button can open it in a new tab; ?dl=1 forces an
    // attachment download. Rewired to /api/reports/do/{id}/export.pdf in
    // commit 4 when the preview endpoint lands and the URL space gets
    // canonicalized.
    [HttpGet("/Reports/Do/{id:guid}/pdf")]
    public async Task<IActionResult> DoPdf(Guid id, [FromQuery(Name = "dl")] int dl, CancellationToken ct)
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

            var detail = await _pulls.GetByIdAsync(id, ct);
            var filename = $"{(detail?.PullNumber ?? id.ToString())}-DO.pdf";
            var disposition = dl == 1 ? "attachment" : "inline";
            Response.Headers["Content-Disposition"] = $"{disposition}; filename=\"{filename}\"";
            return File(ms.ToArray(), "application/pdf");
        }
        catch (NotFoundException) { return NotFound(); }
        catch (BusinessException ex) { return BadRequest(ex.Message); }
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;
}
