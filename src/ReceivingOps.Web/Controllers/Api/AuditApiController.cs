using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Controllers.Api;

[ApiController]
[Route("api/audit")]
[Authorize(Policy = "AdminOnly")]
public class AuditApiController : ControllerBase
{
    private readonly IAuditRepository _audit;

    public AuditApiController(IAuditRepository audit) => _audit = audit;

    // GET /api/audit?action=&q=&take=200
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<AuditRow>>> List(
        [FromQuery] string? action,
        [FromQuery] string? q,
        [FromQuery] int? take,
        CancellationToken ct)
    {
        var rows = await _audit.QueryAsync(new AuditQuery(action, q, take ?? 200), ct);
        return Ok(rows);
    }
}
