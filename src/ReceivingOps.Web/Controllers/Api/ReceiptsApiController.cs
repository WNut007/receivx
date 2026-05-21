using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers.Api;

[ApiController]
[Route("api/receipts")]
[Authorize(Policy = "CanReceive")]
public class ReceiptsApiController : ControllerBase
{
    private readonly IReceiptService _receipts;
    private readonly IReceiptRepository _journal;
    private readonly ILogger<ReceiptsApiController> _logger;

    public ReceiptsApiController(
        IReceiptService receipts,
        IReceiptRepository journal,
        ILogger<ReceiptsApiController> logger)
    {
        _receipts = receipts;
        _journal = journal;
        _logger = logger;
    }

    // §7.2 POST /api/receipts — FIFO allocator may emit multiple receipt rows
    [HttpPost]
    public async Task<ActionResult<ReceiveResult>> Receive([FromBody] ReceiveRequest req, CancellationToken ct)
    {
        try
        {
            var result = await _receipts.ReceiveAsync(req, ct);
            return Ok(result);
        }
        catch (NotFoundException ex)    { return Problem(title: ex.Message, statusCode: 404); }
        catch (ForbiddenException ex)   { return Problem(title: ex.Message, statusCode: 403); }
        catch (BusinessException ex)    { return Problem(title: ex.Message, statusCode: 409); }
    }

    // §7.2 / §3.5 GET /api/receipts/preview?pullItemId=&qty= — read-only FIFO preview (lock-aware)
    [HttpGet("preview")]
    public async Task<ActionResult<ReceivePreviewResult>> Preview(
        [FromQuery] Guid pullItemId, [FromQuery] int qty, CancellationToken ct)
    {
        try
        {
            var result = await _receipts.PreviewAsync(pullItemId, qty, ct);
            return Ok(result);
        }
        catch (ValidationException ex)  { return Problem(title: ex.Message, statusCode: 400); }
        catch (NotFoundException ex)    { return Problem(title: ex.Message, statusCode: 404); }
        catch (ForbiddenException ex)   { return Problem(title: ex.Message, statusCode: 403); }
        catch (BusinessException ex)    { return Problem(title: ex.Message, statusCode: 409); }
    }

    // §7.3 POST /api/receipts/{id}/cancel
    [HttpPost("{id:guid}/cancel")]
    public async Task<ActionResult<CancelResult>> Cancel(Guid id, [FromBody] CancelRequest req, CancellationToken ct)
    {
        try
        {
            var result = await _receipts.CancelAsync(id, req, ct);
            return Ok(result);
        }
        catch (NotFoundException ex)    { return Problem(title: ex.Message, statusCode: 404); }
        catch (ForbiddenException ex)   { return Problem(title: ex.Message, statusCode: 403); }
        catch (BusinessException ex)    { return Problem(title: ex.Message, statusCode: 409); }
    }

    // GET /api/receipts/pull/{pullId} — journal for the drawer + modal embedded list
    [HttpGet("pull/{pullId:guid}")]
    public async Task<ActionResult<IReadOnlyList<ReceiptJournalRow>>> JournalForPull(Guid pullId, CancellationToken ct)
    {
        // Warehouse scoping piggybacks on the journal view's WarehouseId; non-admins only see their own.
        var rows = await _journal.GetJournalForPullAsync(pullId, ct);
        if (!User.IsInRole("admin"))
        {
            var sessionWh = User.FindFirst("warehouseId")?.Value;
            if (Guid.TryParse(sessionWh, out var whId))
                rows = rows.Where(r => r.WarehouseId == whId).ToList();
            else
                return Forbid();
        }
        return Ok(rows);
    }
}
