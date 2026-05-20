using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers.Api;

[ApiController]
[Route("api/pulls")]
[Authorize]
public class PullsApiController : ControllerBase
{
    private readonly IPullRepository _pulls;
    private readonly ICloseService _close;

    public PullsApiController(IPullRepository pulls, ICloseService close)
    {
        _pulls = pulls;
        _close = close;
    }

    // §6 GET /api/pulls?warehouseId=&dateFrom=&dateTo=&status=&q=
    [HttpGet]
    public async Task<IReadOnlyList<PullSummary>> List(
        [FromQuery] Guid? warehouseId,
        [FromQuery] DateOnly? dateFrom,
        [FromQuery] DateOnly? dateTo,
        [FromQuery] string? status,
        [FromQuery] string? q,
        CancellationToken ct)
    {
        // Non-admins are scoped to the warehouse on their session, no matter what
        // they pass in the query string. Admins can pass any warehouseId, or omit
        // to see everything.
        var isAdmin = User.IsInRole("admin");
        var effectiveWh = isAdmin
            ? warehouseId
            : ParseGuid(User.FindFirstValue("warehouseId"));

        var filter = new PullQuery(effectiveWh, dateFrom, dateTo, status, q);
        return await _pulls.QueryAsync(filter, ct);
    }

    // §6 GET /api/pulls/{id}
    [HttpGet("{id:guid}")]
    public async Task<ActionResult<PullDetail>> GetById(Guid id, CancellationToken ct)
        => await ResolveAsync(await _pulls.GetByIdAsync(id, ct));

    // Dashboard links into Receiving with the human-readable PullNumber, not a GUID.
    [HttpGet("by-number/{pullNumber}")]
    public async Task<ActionResult<PullDetail>> GetByNumber(string pullNumber, CancellationToken ct)
        => await ResolveAsync(await _pulls.GetByPullNumberAsync(pullNumber, ct));

    private Task<ActionResult<PullDetail>> ResolveAsync(PullDetail? pull)
    {
        if (pull is null) return Task.FromResult<ActionResult<PullDetail>>(NotFound());

        if (!User.IsInRole("admin"))
        {
            var sessionWh = ParseGuid(User.FindFirstValue("warehouseId"));
            if (sessionWh != pull.WarehouseId)
            {
                // Forbid() routes through the cookie scheme and would redirect to
                // /Account/AccessDenied (302). For API callers we want a real 403.
                return Task.FromResult<ActionResult<PullDetail>>(
                    Problem(title: "You do not have access to this pull", statusCode: 403));
            }
        }
        return Task.FromResult<ActionResult<PullDetail>>(Ok(pull));
    }

    // §7.4 POST /api/pulls/{id}/close
    [HttpPost("{id:guid}/close")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<CloseResult>> Close(Guid id, [FromBody] CloseRequest req, CancellationToken ct)
    {
        try
        {
            return Ok(await _close.CloseAsync(id, req, ct));
        }
        catch (NotFoundException ex)         { return Problem(title: ex.Message, statusCode: 404); }
        catch (ForbiddenException ex)        { return Problem(title: ex.Message, statusCode: 403); }
        catch (PayloadTooLargeException ex)  { return Problem(title: ex.Message, statusCode: 413); }
        catch (BusinessException ex)         { return Problem(title: ex.Message, statusCode: 409); }
    }

    // §7.5 POST /api/pulls/{id}/reopen
    [HttpPost("{id:guid}/reopen")]
    [Authorize(Policy = "CanReopenPull")]
    public async Task<ActionResult<ReopenResult>> Reopen(Guid id, [FromBody] ReopenRequest req, CancellationToken ct)
    {
        try
        {
            return Ok(await _close.ReopenAsync(id, req, ct));
        }
        catch (NotFoundException ex)   { return Problem(title: ex.Message, statusCode: 404); }
        catch (ForbiddenException ex)  { return Problem(title: ex.Message, statusCode: 403); }
        catch (BusinessException ex)   { return Problem(title: ex.Message, statusCode: 409); }
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;
}
