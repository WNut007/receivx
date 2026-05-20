using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace ReceivingOps.Web.Controllers;

[Authorize]
public class ConfigController : Controller
{
    [HttpGet("/Config")]
    public IActionResult Index() => View();
}
