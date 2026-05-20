using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace ReceivingOps.Web.Controllers;

[Authorize(Policy = "AdminOnly")]
public class MastersController : Controller
{
    [HttpGet("/Masters")]
    public IActionResult Index() => View();
}
