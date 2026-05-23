using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;

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
    [HttpGet("/Reports")]
    public async Task<IActionResult> Index(CancellationToken ct)
    {
        var wh = User.IsInRole("admin") ? (Guid?)null : ParseGuid(User.FindFirstValue("warehouseId"));
        var rows = await _pulls.GetClosedWithReceiptsAsync(wh, ct);
        ViewData["PageId"] = "reports";
        return View(rows);
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;
}
