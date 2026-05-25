using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace ReceivingOps.Web.Controllers;

// Phase 10.6 — admin-only page chrome. Data + actions come from the
// /api/admin/* controllers; this just hands out the Razor view.
[Authorize(Roles = "admin")]
public class AdminController : Controller
{
    [HttpGet("/Admin/ErpSync")]
    public IActionResult ErpSync()
    {
        ViewData["PageId"] = "admin-erp-sync";
        return View();
    }
}
