using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Controllers;

// v2.x Phase 7.4 — Page controller for /Reports (two-pane Reports page).
// The DO preview HTML fragment + the PDF export live on the API surface
// at /api/reports/do/{id}/preview and /api/reports/do/{id}/export.pdf
// (ReportsApiController).
//
// CanManagePulls = admin + supervisor (matches Phase 5c /Pos convention —
// the operator who closed the pull also wants to print the paperwork; non-
// admins on other warehouses are scoped out at the repo query.)
[Authorize(Policy = "CanManagePulls")]
public class ReportsController : Controller
{
    private readonly IPullRepository _pulls;

    public ReportsController(IPullRepository pulls)
    {
        _pulls = pulls;
    }

    // GET /Reports — server-renders the closed-pull list into the two-pane
    // layout. Non-admin sessions get their session warehouse only.
    //
    // Phase 8.1: paginated. ?page=N&pageSize=M query params drive the
    // slice; HTML default = page 1, pageSize 50. UI page nav (prev/next)
    // ships in Phase 8.3; for now the URL params are the only way to
    // reach pages > 1 — but the result-count surfaces the total so
    // operators know more data exists.
    [HttpGet("/Reports")]
    public async Task<IActionResult> Index(
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 50,
        CancellationToken ct = default)
    {
        var wh = User.IsInRole("admin") ? (Guid?)null : ParseGuid(User.FindFirstValue("warehouseId"));
        var req = new PaginatedRequest { Page = page, PageSize = pageSize };
        var (items, total) = await _pulls.GetClosedWithReceiptsAsync(wh, req.Skip, req.Take, ct);
        ViewData["PageId"] = "reports";
        return View(new PaginatedResponse<PullSummary>
        {
            Items = items,
            Page = Math.Max(1, page),
            PageSize = req.Take,
            Total = total,
        });
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;
}
