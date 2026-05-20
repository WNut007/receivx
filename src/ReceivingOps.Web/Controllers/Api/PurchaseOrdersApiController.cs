using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers.Api;

[ApiController]
[Route("api/pos")]
[Authorize]
public class PurchaseOrdersApiController : ControllerBase
{
    private readonly IPurchaseOrderRepository _repo;
    private readonly IPurchaseOrderAdminService _admin;

    public PurchaseOrdersApiController(IPurchaseOrderRepository repo, IPurchaseOrderAdminService admin)
    {
        _repo = repo;
        _admin = admin;
    }

    // ---- Reads (authenticated) ----

    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<PoListRow>>> List(
        [FromQuery] Guid? warehouseId,
        [FromQuery] string? status,
        [FromQuery] string? itemCode,
        [FromQuery] string? q,
        CancellationToken ct)
    {
        var rows = await _repo.QueryAsync(warehouseId, status, itemCode, q, ct);
        return Ok(rows);
    }

    [HttpGet("{id:guid}")]
    public async Task<ActionResult<PoDetail>> Get(Guid id, CancellationToken ct)
    {
        var detail = await _repo.GetDetailAsync(id, ct);
        if (detail is null) return Problem(title: "PO not found", statusCode: 404);
        return Ok(detail);
    }

    [HttpGet("availability")]
    public async Task<ActionResult<IReadOnlyList<PoAvailabilityRow>>> Availability(
        [FromQuery] Guid warehouseId, [FromQuery] string itemCode, CancellationToken ct)
    {
        if (warehouseId == Guid.Empty) return Problem(title: "warehouseId is required", statusCode: 400);
        if (string.IsNullOrWhiteSpace(itemCode)) return Problem(title: "itemCode is required", statusCode: 400);
        var rows = await _repo.GetAvailabilityAsync(warehouseId, itemCode.Trim(), ct);
        return Ok(rows);
    }

    // ---- Writes (CanManagePulls — supervisor+admin) ----

    [HttpPost]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<PoDetail>> Create([FromBody] PoCreateRequest req, CancellationToken ct)
    {
        try
        {
            var newId = await _admin.CreateAsync(req, ct);
            var detail = await _repo.GetDetailAsync(newId, ct);
            return CreatedAtAction(nameof(Get), new { id = newId }, detail);
        }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    [HttpPut("{id:guid}")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<ActionResult<PoDetail>> Update(Guid id, [FromBody] PoUpdateRequest req, CancellationToken ct)
    {
        try
        {
            await _admin.UpdateAsync(id, req, ct);
            var detail = await _repo.GetDetailAsync(id, ct);
            return Ok(detail);
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    [HttpPost("{id:guid}/close")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<IActionResult> CloseManually(Guid id, [FromBody] PoCloseRequest req, CancellationToken ct)
    {
        try
        {
            await _admin.CloseAsync(id, req, ct);
            return NoContent();
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    [HttpPost("{id:guid}/lines")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<IActionResult> AddLine(Guid id, [FromBody] PoLineCreateRequest req, CancellationToken ct)
    {
        try
        {
            var newId = await _admin.AddLineAsync(id, req, ct);
            return Ok(new { id = newId });
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    [HttpDelete("{id:guid}/lines/{lineId:guid}")]
    [Authorize(Policy = "CanManagePulls")]
    public async Task<IActionResult> DeleteLine(Guid id, Guid lineId, CancellationToken ct)
    {
        try
        {
            await _admin.DeleteLineAsync(id, lineId, ct);
            return NoContent();
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }
}
