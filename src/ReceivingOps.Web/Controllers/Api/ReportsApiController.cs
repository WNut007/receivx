using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers.Api;

// v2.x Phase 7.4 — JSON/HTML API surface for the Reports page.
//   GET /api/reports/do/{id}/preview  → HTML fragment from _DoPreview.cshtml
// The PDF endpoint stays on the page-level ReportsController during commit 2
// and gets canonicalized to /api/reports/do/{id}/export.pdf in commit 4.
[ApiController]
[Authorize(Policy = "CanManagePulls")]
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
    public async Task<IActionResult> Preview(Guid id, CancellationToken ct)
    {
        try
        {
            if (!User.IsInRole("admin"))
            {
                var sessionWh = ParseGuid(User.FindFirstValue("warehouseId"));
                var pull = await _pulls.GetByIdAsync(id, ct);
                if (pull is null || pull.WarehouseId != sessionWh)
                    return Forbid();
            }
            var data = await _doService.GetReportDataAsync(id, ct);
            // Full path — the api controller's view discovery would look under
            // Views/ReportsApi/ otherwise (controller name → folder mapping).
            return PartialView("~/Views/Reports/_DoPreview.cshtml", data);
        }
        catch (NotFoundException) { return NotFound(); }
        catch (BusinessException ex) { return BadRequest(new { error = ex.Message }); }
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;
}
