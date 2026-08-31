using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;
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
    private readonly IWarehouseRepository _warehouses;
    private readonly IPurchaseOrderRepository _pos;
    private readonly IMemoryCache _cache;

    // Cached warehouse code→id map for the dashboard admin filter (warehouses
    // rarely change → resolve once, not per request).
    private const string WhMapCacheKey = "dashboard.warehouseCodeToId";

    // Cached vendor code→name map for the Receiving Console's Vendor column.
    // Same shape as the warehouse map: tiny, near-static, whole-dictionary.
    private const string VendorNameMapCacheKey = "console.vendorNameByBareCode";

    public PullsApiController(IPullRepository pulls, ICloseService close,
        IPullAdminService admin, IPullItemAdminService itemsAdmin,
        IWarehouseRepository warehouses, IPurchaseOrderRepository pos, IMemoryCache cache)
    {
        _pulls = pulls;
        _close = close;
        _admin = admin;
        _itemsAdmin = itemsAdmin;
        _warehouses = warehouses;
        _pos = pos;
        _cache = cache;
    }

    // Resolve an admin's selected warehouse CODE to its Guid via a cached map.
    // "all"/empty ⇒ null ⇒ NO warehouse predicate (never Guid.Empty, so "all"
    // can't degrade into a zero-row filter). An unknown code also ⇒ null ⇒ all
    // (only reachable by URL-tampering an admin, who can already see everything).
    private async Task<Guid?> ResolveWarehouseIdAsync(string? code, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(code) || code == "all") return null;

        var map = await _cache.GetOrCreateAsync(WhMapCacheKey, async entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(10);
            var all = await _warehouses.GetAllActiveAsync(ct);
            return all.ToDictionary(w => w.Code, w => w.Id, StringComparer.OrdinalIgnoreCase);
        });

        return map is not null && map.TryGetValue(code.Trim(), out var id) ? id : null;
    }

    // §6 GET /api/pulls?warehouse=<code>&dateFrom=&dateTo=&status=&q=&lock=&page=&pageSize=
    // Returns one page of cards (default sort PullDate DESC, PullNumber DESC) plus
    // tile/badge aggregates over the FULL filtered set.
    [HttpGet]
    public async Task<PullDashboardResponse> List(
        [FromQuery] string? warehouse,                 // admin: warehouse CODE ("WH-01") or "all"/empty
        [FromQuery] DateOnly? dateFrom,
        [FromQuery] DateOnly? dateTo,
        [FromQuery] string? status,
        [FromQuery] string? q,
        [FromQuery(Name = "lock")] string? lockMode,   // "locked" | "unlocked" | null
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 20,
        CancellationToken ct = default)
    {
        var isAdmin = User.IsInRole("admin");

        // Admin: resolve the selected CODE → Guid ("all"/empty → null → no predicate).
        // Non-admin: ignore the query and hard-force the session warehouse by id —
        // unchanged security behavior. Exactly one of the two is ever non-null.
        Guid? adminWhId   = isAdmin ? await ResolveWarehouseIdAsync(warehouse, ct) : null;
        Guid? sessionWhId = isAdmin ? null : ParseGuid(User.FindFirstValue("warehouseId"));

        bool? lockFilter = lockMode switch { "locked" => true, "unlocked" => false, _ => null };

        var filter = new PullQuery(
            WarehouseId: adminWhId,
            SessionWarehouseId: sessionWhId,
            DateFrom: dateFrom,
            DateTo: dateTo,
            Status: status,
            Q: q,
            LockPoByPull: lockFilter,
            Page: Math.Max(1, page),
            PageSize: Math.Clamp(pageSize, 1, 500));

        var (items, agg) = await _pulls.QueryDashboardAsync(filter, ct);
        return new PullDashboardResponse
        {
            Items = items,
            Page = filter.Page,
            PageSize = filter.PageSize,
            Total = agg.TotalPulls,   // == COUNT(*) over the same WHERE
            Aggregates = agg,
        };
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
        => await ResolveAsync(await _pulls.GetByIdAsync(id, ct), ct);

    // Dashboard links into Receiving with the human-readable PullNumber, not a GUID.
    [HttpGet("by-number/{pullNumber}")]
    public async Task<ActionResult<PullDetail>> GetByNumber(string pullNumber, CancellationToken ct)
        => await ResolveAsync(await _pulls.GetByPullNumberAsync(pullNumber, ct), ct);

    private async Task<ActionResult<PullDetail>> ResolveAsync(PullDetail? pull, CancellationToken ct)
    {
        if (pull is null) return NotFound();

        if (!User.IsInRole("admin"))
        {
            var sessionWh = ParseGuid(User.FindFirstValue("warehouseId"));
            if (sessionWh != pull.WarehouseId)
            {
                // Forbid() routes through the cookie scheme and would redirect to
                // /Account/AccessDenied (302). For API callers we want a real 403.
                return Problem(title: "You do not have access to this pull", statusCode: 403);
            }
        }

        await FillVendorNamesAsync(pull, ct);
        return Ok(pull);
    }

    // The ERP sync stamps PullItems.VendorCode from BPI_PRS.VENDOR but never a
    // name — BPI_PRS has no name column — so the Console's Vendor column had a
    // code and a blank second line on virtually every ERP-sourced row. The only
    // vendor NAME in the system lives on dbo.PurchaseOrderLines (db/036), keyed
    // by the same code under a source-system prefix.
    //
    // Resolved from a cached whole-map, never per row: one query per 10 minutes
    // for the whole app, then a dictionary hit per item.
    //
    // Display-only — deliberately does NOT write PullItems.VendorName. Anything
    // the map can't resolve keeps its existing value (usually null → blank line),
    // which is the honest rendering rather than a guess.
    private async Task FillVendorNamesAsync(PullDetail pull, CancellationToken ct)
    {
        if (pull.Items.Count == 0) return;

        // Nothing to do when every row already carries a name (e.g. hand-seeded pulls).
        var needing = pull.Items
            .Where(i => string.IsNullOrWhiteSpace(i.VendorName) && !string.IsNullOrWhiteSpace(i.VendorCode))
            .ToList();
        if (needing.Count == 0) return;

        var map = await _cache.GetOrCreateAsync(VendorNameMapCacheKey, async entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(10);
            return await _pos.GetVendorNameByBareCodeAsync(ct);
        });
        if (map is null || map.Count == 0) return;

        foreach (var item in needing)
        {
            if (map.TryGetValue(item.VendorCode!.Trim(), out var name))
                item.VendorName = name;
        }
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

    // §7.4 POST /api/pulls/{id}/close — Phase 7a: gated by CanCloseWithSign so
    // the closer is also the Warehouse signer (admin bypasses the bit, D1a).
    [HttpPost("{id:guid}/close")]
    [Authorize(Policy = "CanCloseWithSign")]
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

    // POST /api/pulls/{id}/items/{itemId}/cancel — permanent operator cancel.
    //
    // POST, not DELETE, and the verb is the point: nothing is removed. The row
    // stays, flips to Status='canceled', and takes an OperatorFieldEdits mark on
    // Status so no later ERP sync updates, re-imports or un-cancels it. Same
    // shape as POST /api/pos/{id}/close, which retires a PO without deleting it.
    //
    // The DELETE that used to live here is GONE, not aliased. It hard-deleted
    // the row, so the next sync re-INSERTed the draft line as net-new and the
    // operator had to delete it again — 15 (pull, item) pairs on production had
    // been deleted more than once, five of them three times. An alias would have
    // kept that URL working while silently changing what it means.
    //
    // Refused 409 when the pull is closed (consistent with every other item
    // mutation) or when any window already has receipts.
    //
    // There is deliberately no un-cancel endpoint.
    [HttpPost("{id:guid}/items/{itemId:guid}/cancel")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<IActionResult> CancelItem(Guid id, Guid itemId, CancellationToken ct)
    {
        try
        {
            await _itemsAdmin.CancelAsync(id, itemId, ct);
            return NoContent();
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    // Phase 9.1 — PUT /api/pulls/{id}/items/{itemId}/extended-fields
    // Bulk overwrite of the 7 ERP-sourced fields. Same CanManagePulls gate as
    // the other item writes (admin or supervisor); the pull's warehouse scope
    // is implicit via the service's pull lookup. Returns the refreshed item
    // so the client can re-render without an extra GET round trip.
    [HttpPut("{id:guid}/items/{itemId:guid}/extended-fields")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<PullItemDto>> UpdateItemExtendedFields(
        Guid id, Guid itemId, [FromBody] PullItemExtendedFieldsUpdateRequest req, CancellationToken ct)
    {
        try
        {
            await _itemsAdmin.UpdateExtendedFieldsAsync(id, itemId, req, ct);
            var item = await _pulls.GetItemByIdAsync(id, itemId, ct);
            return Ok(item);
        }
        catch (ValidationException ex) { return Problem(title: ex.Message, statusCode: 400); }
        catch (NotFoundException ex)   { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex)   { return Problem(title: ex.Message, statusCode: 409); }
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
