using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace ReceivingOps.Web.Controllers;

[Authorize]
public class TransactionsController : Controller
{
    // §15 #10 — standalone cross-pull journal. All filtering happens via
    // /api/transactions; this action just serves the verbatim mockup port.
    [HttpGet("/Transactions")]
    public IActionResult Index()
    {
        ViewData["Title"] = "Transactions";
        ViewData["PageId"] = "transactions";
        return View();
    }
}
