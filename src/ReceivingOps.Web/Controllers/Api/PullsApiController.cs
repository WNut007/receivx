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
    private readonly IPullAdminService _admin;
    private readonly IPullItemAdminService _itemsAdmin;

    public PullsApiController(IPullRepository pulls, ICloseService close,
        IPullAdminService admin, IPullItemAdminService itemsAdmin)
    {
        _pulls = pulls;
        _close = close;
        _admin = admin;
        _itemsAdmin = itemsAdmin;
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

    // §3.5 GET /api/pulls/search?warehouseId=&q=&take=
    // Typeahead for the New-PO linked-pull picker on /Pos. CanManagePulls only
    // (matches POST /api/pos which is the only write that consumes this).
    // Validates warehouseId required + q.Length >= 2 (no single-char full-table
    // scans). Take is clamped 1..25, default 10. Non-admins are forced to their
    // session warehouse — passing a different one yields rows from their own.
    [HttpGet("search")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<IReadOnlyList<PullSearchResult>>> Search(
        [FromQuery] Guid? warehouseId,
        [FromQuery] string? q,
        [FromQuery] int? take,
        CancellationToken ct)
    {
        var isAdmin = User.IsInRole("admin");
        var effectiveWh = isAdmin
            ? warehouseId
            : ParseGuid(User.FindFirstValue("warehouseId"));

        if (effectiveWh is null || effectiveWh == Guid.Empty)
            return Problem(title: "warehouseId is required.", statusCode: 400);

        var trimmed = (q ?? string.Empty).Trim();
        if (trimmed.Length < 2)
            return Problem(title: "q must be at least 2 characters.", statusCode: 400);

        var effectiveTake = Math.Clamp(take ?? 10, 1, 25);
        var rows = await _pulls.SearchAsync(effectiveWh.Value, trimmed, effectiveTake, ct);
        return Ok(rows);
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

    // §3.5 POST /api/pulls — create a new pull with optional LockPoByPull
    [HttpPost]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<PullDetail>> Create([FromBody] PullCreateRequest req, CancellationToken ct)
    {
        try
        {
            var newId = await _admin.CreateAsync(req, ct);
            var detail = await _pulls.GetByIdAsync(newId, ct);
            return CreatedAtAction(nameof(GetById), new { id = newId }, detail);
        }
        catch (ValidationException ex) { return Problem(title: ex.Message, statusCode: 400); }
        catch (BusinessException ex)   { return Problem(title: ex.Message, statusCode: 409); }
    }

    // §3.5 PUT /api/pulls/{id} — edit PullDate / Eta / Notes
    // LockPoByPull must echo the current value or 409 (strict immutability, both directions).
    [HttpPut("{id:guid}")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<PullDetail>> Update(Guid id, [FromBody] PullUpdateRequest req, CancellationToken ct)
    {
        try
        {
            await _admin.UpdateAsync(id, req, ct);
            var detail = await _pulls.GetByIdAsync(id, ct);
            return Ok(detail);
        }
        catch (ValidationException ex) { return Problem(title: ex.Message, statusCode: 400); }
        catch (NotFoundException ex)   { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex)   { return Problem(title: ex.Message, statusCode: 409); }
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

    // ========================================================================
    // v2.1 — PullItem admin (retires tools/add-pull-item.ps1)
    // ========================================================================

    // GET /api/pulls/{id}/items — list items + windows. Same warehouse-scope
    // rule as GetById: non-admin callers only see items on pulls in their
    // session warehouse.
    [HttpGet("{id:guid}/items")]
    public async Task<ActionResult<IReadOnlyList<PullItemDto>>> ListItems(Guid id, CancellationToken ct)
    {
        var pull = await _pulls.GetByIdAsync(id, ct);
        if (pull is null) return NotFound();
        if (!UserCanReadPull(pull))
            return Problem(title: "You do not have access to this pull", statusCode: 403);

        var items = await _pulls.GetItemsAsync(id, ct);
        return Ok(items);
    }

    // POST /api/pulls/{id}/items — create a new item with windows.
    [HttpPost("{id:guid}/items")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<PullItemDto>> CreateItem(Guid id, [FromBody] PullItemCreateRequest req, CancellationToken ct)
    {
        try
        {
            var newId = await _itemsAdmin.CreateAsync(id, req, ct);
            var item = await _pulls.GetItemByIdAsync(id, newId, ct);
            return CreatedAtAction(nameof(ListItems), new { id }, item);
        }
        catch (ValidationException ex) { return Problem(title: ex.Message, statusCode: 400); }
        catch (NotFoundException ex)   { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex)   { return Problem(title: ex.Message, statusCode: 409); }
    }

    // PUT /api/pulls/{id}/items/{itemId} — edit Description/Vendor/Tag/Status/Remark.
    // ItemCode is immutable (natural key) and intentionally absent from the request body.
    [HttpPut("{id:guid}/items/{itemId:guid}")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<PullItemDto>> UpdateItem(Guid id, Guid itemId, [FromBody] PullItemUpdateRequest req, CancellationToken ct)
    {
        try
        {
            await _itemsAdmin.UpdateAsync(id, itemId, req, ct);
            var item = await _pulls.GetItemByIdAsync(id, itemId, ct);
            return Ok(item);
        }
        catch (ValidationException ex) { return Problem(title: ex.Message, statusCode: 400); }
        catch (NotFoundException ex)   { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex)   { return Problem(title: ex.Message, statusCode: 409); }
    }

    // DELETE /api/pulls/{id}/items/{itemId} — cascade-delete windows.
    // Refused (409) if any window has ReceivedQty > 0.
    [HttpDelete("{id:guid}/items/{itemId:guid}")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<IActionResult> DeleteItem(Guid id, Guid itemId, CancellationToken ct)
    {
        try
        {
            await _itemsAdmin.DeleteAsync(id, itemId, ct);
            return NoContent();
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    // ========================================================================
    // v2.1 Phase 6.2 — PullItem windows sub-resource
    // ========================================================================

    // GET /api/pulls/{id}/items/{itemId}/windows — list windows for one item.
    // Same warehouse scope as ListItems; falls through GetItemByIdAsync.
    [HttpGet("{id:guid}/items/{itemId:guid}/windows")]
    public async Task<ActionResult<IReadOnlyList<PullItemWindowDto>>> ListWindows(Guid id, Guid itemId, CancellationToken ct)
    {
        var pull = await _pulls.GetByIdAsync(id, ct);
        if (pull is null) return NotFound();
        if (!UserCanReadPull(pull))
            return Problem(title: "You do not have access to this pull", statusCode: 403);

        var item = await _pulls.GetItemByIdAsync(id, itemId, ct);
        if (item is null) return NotFound();
        return Ok(item.Windows);
    }

    // POST /api/pulls/{id}/items/{itemId}/windows — add one hour window.
    [HttpPost("{id:guid}/items/{itemId:guid}/windows")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<PullItemWindowDto>> AddWindow(Guid id, Guid itemId, [FromBody] PullItemWindowCreateRequest req, CancellationToken ct)
    {
        try
        {
            var hour = await _itemsAdmin.AddWindowAsync(id, itemId, req, ct);
            var item = await _pulls.GetItemByIdAsync(id, itemId, ct);
            var added = item?.Windows.FirstOrDefault(w => w.HourOfDay == hour);
            return CreatedAtAction(nameof(ListWindows), new { id, itemId }, added);
        }
        catch (ValidationException ex) { return Problem(title: ex.Message, statusCode: 400); }
        catch (NotFoundException ex)   { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex)   { return Problem(title: ex.Message, statusCode: 409); }
    }

    // PUT /api/pulls/{id}/items/{itemId}/windows/{hour} — edit ExpectedQty.
    // HourOfDay is the natural key on the item and is implicit in the URL —
    // to "move" a window across hours, DELETE the old + POST the new.
    [HttpPut("{id:guid}/items/{itemId:guid}/windows/{hour:int}")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<PullItemWindowDto>> UpdateWindow(Guid id, Guid itemId, int hour, [FromBody] PullItemWindowUpdateRequest req, CancellationToken ct)
    {
        if (hour < 0 || hour > 23)
            return Problem(title: $"HourOfDay {hour} out of range (0..23)", statusCode: 400);
        try
        {
            await _itemsAdmin.UpdateWindowAsync(id, itemId, (byte)hour, req, ct);
            var item = await _pulls.GetItemByIdAsync(id, itemId, ct);
            var updated = item?.Windows.FirstOrDefault(w => w.HourOfDay == hour);
            return Ok(updated);
        }
        catch (ValidationException ex) { return Problem(title: ex.Message, statusCode: 400); }
        catch (NotFoundException ex)   { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex)   { return Problem(title: ex.Message, statusCode: 409); }
    }

    // DELETE /api/pulls/{id}/items/{itemId}/windows/{hour} — refuses 409 if ReceivedQty>0.
    [HttpDelete("{id:guid}/items/{itemId:guid}/windows/{hour:int}")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<IActionResult> DeleteWindow(Guid id, Guid itemId, int hour, CancellationToken ct)
    {
        if (hour < 0 || hour > 23)
            return Problem(title: $"HourOfDay {hour} out of range (0..23)", statusCode: 400);
        try
        {
            await _itemsAdmin.DeleteWindowAsync(id, itemId, (byte)hour, ct);
            return NoContent();
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    private bool UserCanReadPull(PullDetail pull)
    {
        if (User.IsInRole("admin")) return true;
        var sessionWh = ParseGuid(User.FindFirstValue("warehouseId"));
        return sessionWh == pull.WarehouseId;
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;
}
