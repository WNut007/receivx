using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers.Api;

[ApiController]
[Route("api/auth")]
public class AuthApiController : ControllerBase
{
    private readonly IAuthService _auth;
    private readonly ILogger<AuthApiController> _logger;

    public AuthApiController(IAuthService auth, ILogger<AuthApiController> logger)
    {
        _auth = auth;
        _logger = logger;
    }

    // §5.2
    [HttpGet("warehouses-for/{username}")]
    [AllowAnonymous]
    public async Task<IReadOnlyList<WarehouseOption>> GetWarehousesFor(string username, CancellationToken ct)
        => await _auth.GetWarehousesForUsernameAsync(username, ct);

    // §5.1
    [HttpPost("login")]
    [AllowAnonymous]
    public async Task<IActionResult> Login([FromBody] LoginRequest req, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(req.Username) || string.IsNullOrWhiteSpace(req.Password))
            return Problem(title: "Username and password are required", statusCode: 400);

        var result = await _auth.LoginAsync(req, ct);
        return result switch
        {
            AuthResult.Success ok        => Ok(ok.Info),
            AuthResult.Failure fail      => Problem(title: fail.Title, statusCode: fail.Status),
            _                            => Problem(title: "Unknown auth error", statusCode: 500),
        };
    }

    // §5.4
    [HttpPost("logout")]
    [Authorize]
    public async Task<IActionResult> Logout(CancellationToken ct)
    {
        await _auth.LogoutAsync(ct);
        return NoContent();
    }

    // §5.3
    [HttpGet("me")]
    [Authorize]
    public ActionResult<MeResponse> Me()
    {
        var me = _auth.GetCurrentSession();
        return me is null ? Unauthorized() : Ok(me);
    }
}
