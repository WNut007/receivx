using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers.Api;

[ApiController]
[Route("api/users")]
[Authorize(Policy = "AdminOnly")]
public class UsersApiController : ControllerBase
{
    private static readonly string[] ValidRoles = { "admin", "supervisor", "operator", "viewer" };

    private readonly IUserRepository _users;
    private readonly IMastersService _masters;
    private readonly IAuditService _audit;

    public UsersApiController(IUserRepository users, IMastersService masters, IAuditService audit)
    {
        _users = users;
        _masters = masters;
        _audit = audit;
    }

    // GET /api/users?role=&status=&q=
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<UserListRow>>> List(
        [FromQuery] string? role,
        [FromQuery] string? status,
        [FromQuery] string? q,
        CancellationToken ct)
    {
        var rows = await _users.QueryAsync(role, status, q, ct);
        return Ok(rows);
    }

    // GET /api/users/{id}
    [HttpGet("{id:guid}")]
    public async Task<ActionResult<UserDetail>> Get(Guid id, CancellationToken ct)
    {
        var detail = await _users.GetDetailAsync(id, ct);
        if (detail is null) return Problem(title: "User not found", statusCode: 404);
        return Ok(detail);
    }

    // POST /api/users
    [HttpPost]
    public async Task<ActionResult<UserDetail>> Create([FromBody] UserCreateRequest req, CancellationToken ct)
    {
        try
        {
            var newId = await _masters.CreateUserAsync(req, ct);
            var detail = await _users.GetDetailAsync(newId, ct);
            return CreatedAtAction(nameof(Get), new { id = newId }, detail);
        }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
    }

    // PUT /api/users/{id}
    [HttpPut("{id:guid}")]
    public async Task<ActionResult<UserDetail>> Update(Guid id, [FromBody] UserUpdateRequest req, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(req.Name) || req.Name.Length > 120)
            return Problem(title: "Name is required (≤ 120 chars)", statusCode: 409);
        if (!ValidRoles.Contains(req.Role, StringComparer.OrdinalIgnoreCase))
            return Problem(title: "Invalid role", statusCode: 409);

        var affected = await _users.UpdateAsync(id, req, ct);
        if (affected == 0) return Problem(title: "User not found", statusCode: 404);

        await _audit.WriteAsync("update", "User", id.ToString(),
            $"Updated user {req.Name} (role={req.Role}, active={req.IsActive})", ct);

        var detail = await _users.GetDetailAsync(id, ct);
        return Ok(detail);
    }

    // DELETE /api/users/{id} — refuses self (§7.8)
    [HttpDelete("{id:guid}")]
    public async Task<IActionResult> Delete(Guid id, CancellationToken ct)
    {
        try
        {
            await _masters.DeleteUserAsync(id, ct);
            return NoContent();
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    // PUT /api/users/{id}/assignments
    [HttpPut("{id:guid}/assignments")]
    public async Task<IActionResult> ReplaceAssignments(
        Guid id, [FromBody] List<AssignmentInput> assignments, CancellationToken ct)
    {
        try
        {
            await _masters.ReplaceAssignmentsAsync(id, assignments ?? new(), ct);
            var detail = await _users.GetDetailAsync(id, ct);
            return Ok(detail);
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    // POST /api/users/{id}/reset-password
    [HttpPost("{id:guid}/reset-password")]
    public async Task<IActionResult> ResetPassword(
        Guid id, [FromBody] ResetPasswordRequest req, CancellationToken ct)
    {
        try
        {
            await _masters.ResetPasswordAsync(id, req?.NewPassword ?? "", ct);
            return NoContent();
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }
}
