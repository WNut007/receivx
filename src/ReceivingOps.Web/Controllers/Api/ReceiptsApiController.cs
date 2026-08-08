using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models;
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

    // db/047 — carry the machine-readable error code in ProblemDetails.Extensions["code"].
    // Purely additive: status codes, titles and the RFC `type`/`traceId` fields are
    // untouched, so existing callers that only read `title` keep working. Built on top of
    // ControllerBase.Problem(...) rather than a hand-rolled ProblemDetails so the response
    // shape stays identical to every other endpoint in the app.
    private ObjectResult ProblemWithCode(string title, int statusCode, string? code)
    {
        var result = Problem(title: title, statusCode: statusCode);
        if (code is not null && result.Value is ProblemDetails pd)
            pd.Extensions["code"] = code;
        return result;
    }

    // db/049 — GET /api/receipts/variance-reasons
    //
    // The dropdown's source of truth. The client renders whatever this returns and holds
    // NO copy of the labels, so changing a label — or the eventual decision about what
    // language the list is in — is an edit to VarianceReasonCodes.cs alone.
    //
    // Direction filtering is done client-side from the ValidOver/ValidShort flags rather
    // than by asking the server per keystroke: the operator changes the quantity
    // continuously while typing, and the set is six fixed rows. The server re-validates the
    // submitted code against the direction on POST regardless — this endpoint decides what
    // is OFFERED, never what is ACCEPTED.
    [HttpGet("variance-reasons")]
    public ActionResult<IReadOnlyList<VarianceReasonCodes.Reason>> VarianceReasons()
        => Ok(VarianceReasonCodes.All);

    // §7.2 / §3.5 POST /api/receipts — lock-aware FIFO allocator; may emit multiple receipt rows
    [HttpPost]
    public async Task<ActionResult<ReceiveResult>> Receive([FromBody] ReceiveRequest req, CancellationToken ct)
    {
        try
        {
            var result = await _receipts.ReceiveAsync(req, ct);
            return Ok(result);
        }
        catch (ValidationException ex)  { return ProblemWithCode(ex.Message, 400, ex.Code); }
        catch (NotFoundException ex)    { return Problem(title: ex.Message, statusCode: 404); }
        catch (ForbiddenException ex)   { return Problem(title: ex.Message, statusCode: 403); }
        catch (BusinessException ex)    { return ProblemWithCode(ex.Message, 409, ex.Code); }
    }

    // §7.2 / §3.5 GET /api/receipts/preview?pullItemId=&qty=&hour=
    // hour is optional. When the pull has LockHourCap=true and the caller passes hour,
    // the preview also surfaces "Insufficient hour capacity" 409 before allocating PO
    // lines, so the modal's alloc panel can render the localized error early.
    [HttpGet("preview")]
    public async Task<ActionResult<ReceivePreviewResult>> Preview(
        [FromQuery] Guid pullItemId, [FromQuery] int qty, [FromQuery] byte? hour,
        [FromQuery] bool varianceAccepted, CancellationToken ct)
    {
        try
        {
            var result = await _receipts.PreviewAsync(pullItemId, qty, hour, varianceAccepted, ct);
            return Ok(result);
        }
        catch (ValidationException ex)  { return ProblemWithCode(ex.Message, 400, ex.Code); }
        catch (NotFoundException ex)    { return Problem(title: ex.Message, statusCode: 404); }
        catch (ForbiddenException ex)   { return Problem(title: ex.Message, statusCode: 403); }
        catch (BusinessException ex)    { return ProblemWithCode(ex.Message, 409, ex.Code); }
    }

    // db/047 §2d POST /api/receipts/reopen — clear the close flags on one window.
    //
    // Same [Authorize(Policy = "CanReceive")] as the rest of this controller: reopening is
    // part of doing the receiving, not an administrative override. Warehouse scoping and
    // the closed-pull rule are enforced in the service, as they are for cancel.
    [HttpPost("reopen")]
    public async Task<ActionResult<ReopenWindowResult>> ReopenWindow([FromBody] ReopenWindowRequest req, CancellationToken ct)
    {
        try
        {
            var result = await _receipts.ReopenWindowAsync(req, ct);
            return Ok(result);
        }
        catch (ValidationException ex)  { return ProblemWithCode(ex.Message, 400, ex.Code); }
        catch (NotFoundException ex)    { return Problem(title: ex.Message, statusCode: 404); }
        catch (ForbiddenException ex)   { return Problem(title: ex.Message, statusCode: 403); }
        catch (BusinessException ex)    { return ProblemWithCode(ex.Message, 409, ex.Code); }
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
