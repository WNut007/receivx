using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace ReceivingOps.Web.Controllers;

// v2.x Phase 7.4 — Page controller for /Reports (two-pane Reports page).
// The closed-pull list, the DO preview HTML fragment and the PDF export all
// live on the API surface: /api/reports/closed-pulls,
// /api/reports/do/{id}/preview and /api/reports/do/{id}/export.pdf
// (ReportsApiController).
//
// CanViewReports = admin + any recognized whRole (supervisor/operator/viewer/
// customer/warehouse/production). Loosened from CanManagePulls for the digital-
// signature feature so view-only viewers and the 3 signer roles can open the
// DO reports; non-admins on other warehouses are still scoped out at the repo
// query / EnsureWarehouseScopeAsync.
[Authorize(Policy = "CanViewReports")]
public class ReportsController : Controller
{
    // GET /Reports — renders the two-pane shell. The closed-pull list itself is
    // fetched by reports.js from GET /api/reports/closed-pulls, filtered and
    // paged server-side.
    //
    // The list was server-rendered here until the filter bar moved into SQL.
    // Rendering the rows in both Razor and JS would have meant two markup paths
    // for one list, and they drift; the endpoint is now the single source. The
    // ?page= query param went with it — page state lives in the JS pagination
    // control, because a page link that doesn't carry the active filters points
    // at the wrong rows.
    [HttpGet("/Reports")]
    public IActionResult Index()
    {
        ViewData["PageId"] = "reports";

        // Phase 7e — the current user's signing capabilities (lowercase party
        // peers from the canSign claims, 6b). Drives the per-row batch checkboxes,
        // the batch-party selector, and the 'unsigned for my role' filter. The
        // API scopes the list to warehouses this user can reach, so every row it
        // returns is a pull this user could sign (scope-wise); eligibility
        // narrows to unsigned boxes in the renderer. Warehouse is excluded from
        // batch (auto-signed at close).
        var signParties = User.FindAll("canSign").Select(c => c.Value).ToArray();
        ViewData["SignPartiesArr"]  = signParties;
        ViewData["SignPartiesJson"] = System.Text.Json.JsonSerializer.Serialize(signParties);

        // The warehouse filter only means something for admins — everyone else is
        // pinned to their session warehouse by the API regardless of what they
        // pick, so the renderer removes the control rather than leaving a dead one.
        ViewData["IsAdmin"] = User.IsInRole("admin");
        return View();
    }
}
