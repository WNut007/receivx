using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace ReceivingOps.Web.Controllers;

[Authorize]
public class ReceivingController : Controller
{
    // GET /Receiving/{id?}
    //
    // Stage A: serve the verbatim mockup port. The JS still ships with hardcoded
    // seed data (PL-2847 etc.) — wiring the page to /api/pulls/{id} +
    // /api/receipts/* is Stage B. The optional {id} segment is parsed only so
    // the URL is clean; the view layer doesn't act on it yet.
    [HttpGet("/Receiving/{id?}")]
    public IActionResult Index(string? id)
    {
        ViewData["Title"] = "Receiving Console";
        ViewData["PageId"] = "receiving";
        ViewData["PullId"] = id;
        return View();
    }
}
