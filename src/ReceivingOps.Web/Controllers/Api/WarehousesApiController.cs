using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers.Api;

[ApiController]
[Route("api/warehouses")]
[Authorize]
public class WarehousesApiController : ControllerBase
{
    private readonly IWarehouseRepository _warehouses;
    private readonly IMastersService _masters;

    public WarehousesApiController(IWarehouseRepository warehouses, IMastersService masters)
    {
        _warehouses = warehouses;
        _masters = masters;
    }

    // GET /api/warehouses?status=&q=  (authenticated)
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<WarehouseListRow>>> List(
        [FromQuery] string? status,
        [FromQuery] string? q,
        CancellationToken ct)
    {
        var rows = await _warehouses.QueryAsync(status, q, ct);
        return Ok(rows);
    }

    // GET /api/warehouses/{id}  (authenticated)
    [HttpGet("{id:guid}")]
    public async Task<ActionResult<WarehouseListRow>> Get(Guid id, CancellationToken ct)
    {
        var row = await _warehouses.GetListRowAsync(id, ct);
        if (row is null) return Problem(title: "Warehouse not found", statusCode: 404);
        return Ok(row);
    }

    // POST /api/warehouses  (AdminOnly)
    [HttpPost]
    [Authorize(Policy = "AdminOnly")]
    public async Task<ActionResult<WarehouseListRow>> Create(
        [FromBody] WarehouseCreateRequest req, CancellationToken ct)
    {
        try
        {
            var newId = await _masters.CreateWarehouseAsync(req, ct);
            var row = await _warehouses.GetListRowAsync(newId, ct);
            return CreatedAtAction(nameof(Get), new { id = newId }, row);
        }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    // PUT /api/warehouses/{id}  (AdminOnly)
    [HttpPut("{id:guid}")]
    [Authorize(Policy = "AdminOnly")]
    public async Task<ActionResult<WarehouseListRow>> Update(
        Guid id, [FromBody] WarehouseUpdateRequest req, CancellationToken ct)
    {
        try
        {
            await _masters.UpdateWarehouseAsync(id, req, ct);
            var row = await _warehouses.GetListRowAsync(id, ct);
            return Ok(row);
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }

    // DELETE /api/warehouses/{id}  (AdminOnly)
    [HttpDelete("{id:guid}")]
    [Authorize(Policy = "AdminOnly")]
    public async Task<IActionResult> Delete(Guid id, CancellationToken ct)
    {
        try
        {
            await _masters.DeleteWarehouseAsync(id, ct);
            return NoContent();
        }
        catch (NotFoundException ex) { return Problem(title: ex.Message, statusCode: 404); }
        catch (BusinessException ex) { return Problem(title: ex.Message, statusCode: 409); }
    }
}
