using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace ReceivingOps.Web.Controllers;

// Phase 8.5 — page controller for the My Exports list. Data + signed
// download URLs come from /api/exports/jobs (ExportsApiController);
// this page is just chrome + JS wiring.
[Authorize]
public class ExportsController : Controller
{
    [HttpGet("/Exports")]
    public IActionResult Index()
    {
        ViewData["PageId"] = "exports";
        return View();
    }
}
