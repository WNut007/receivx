using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Controllers.Api;

[ApiController]
[Route("api/me")]
[Authorize]
public class PreferencesApiController : ControllerBase
{
    private static readonly HashSet<string> ValidThemes = new(StringComparer.Ordinal) { "light", "midnight", "slate" };
    private static readonly HashSet<string> ValidPositions = new(StringComparer.Ordinal) { "horizontal", "vertical" };
    private static readonly HashSet<string> ValidBehaviors = new(StringComparer.Ordinal) { "sticky", "auto-hide", "static" };

    private readonly IPreferencesRepository _prefs;

    public PreferencesApiController(IPreferencesRepository prefs) => _prefs = prefs;

    // GET /api/me/preferences
    [HttpGet("preferences")]
    public async Task<ActionResult<PreferencesDto>> Get(CancellationToken ct)
    {
        var userId = CurrentUserId();
        var row = await _prefs.GetAsync(userId, ct);
        if (row is null) return Ok(new PreferencesDto());  // schema defaults

        return Ok(new PreferencesDto
        {
            Theme = row.Theme,
            NavPosition = row.NavPosition,
            NavBehavior = row.NavBehavior,
            NavCollapsed = row.NavCollapsed,
            UpdatedAt = row.UpdatedAt
        });
    }

    // PUT /api/me/preferences
    [HttpPut("preferences")]
    public async Task<ActionResult<PreferencesDto>> Put([FromBody] PreferencesDto req, CancellationToken ct)
    {
        if (req is null) return Problem(title: "Body required", statusCode: 400);
        if (!ValidThemes.Contains(req.Theme))
            return Problem(title: $"Theme must be one of: {string.Join(", ", ValidThemes)}", statusCode: 400);
        if (!ValidPositions.Contains(req.NavPosition))
            return Problem(title: $"NavPosition must be one of: {string.Join(", ", ValidPositions)}", statusCode: 400);
        if (!ValidBehaviors.Contains(req.NavBehavior))
            return Problem(title: $"NavBehavior must be one of: {string.Join(", ", ValidBehaviors)}", statusCode: 400);

        var userId = CurrentUserId();
        await _prefs.UpsertAsync(new UserPreferences
        {
            UserId = userId,
            Theme = req.Theme,
            NavPosition = req.NavPosition,
            NavBehavior = req.NavBehavior,
            NavCollapsed = req.NavCollapsed
        }, ct);

        return await Get(ct);
    }

    private Guid CurrentUserId()
    {
        var idClaim = User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!Guid.TryParse(idClaim, out var id))
            throw new InvalidOperationException("Authenticated user has no NameIdentifier claim");
        return id;
    }
}
