using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace ReceivingOps.Web.Controllers;

// Phase 12.6 — page chrome for the PO Excel importer. Open to every
// authenticated user per Q4=A: discoverable in the sidebar even for
// operators. The actual upload + confirm endpoints under /api/imports/po
// are admin,supervisor-gated at the API controller; operators landing
// here see the page but are blocked at the API call.
[Authorize]
public class ImportsController : Controller
{
    [HttpGet("/Imports")]
    public IActionResult Index()
    {
        ViewData["PageId"] = "imports";
        return View();
    }
}
