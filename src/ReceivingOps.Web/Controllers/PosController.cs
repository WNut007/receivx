using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace ReceivingOps.Web.Controllers;

// §3.5 / §5c — Purchase Order admin page.
// CanManagePulls = supervisor + admin (matches the underlying /api/pos write policy).
// The "Close PO" button is hidden in the UI for non-admin sessions — see pos.js.
[Authorize(Policy = "CanManagePulls")]
public class PosController : Controller
{
    [HttpGet("/Pos")]
    public IActionResult Index() => View();
}
