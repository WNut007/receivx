using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Controllers.Api;

[ApiController]
[Route("api/transactions")]
[Authorize]
public class TransactionsApiController : ControllerBase
{
    private const int DefaultTake = 50;
    private const int MaxTake = 500;

    private readonly IReceiptRepository _repo;

    public TransactionsApiController(IReceiptRepository repo) => _repo = repo;

    // §6 GET /api/transactions
    [HttpGet]
    public async Task<PagedTransactions> List(
        [FromQuery] Guid? warehouseId,
        [FromQuery] string? warehouseCode,
        [FromQuery] DateTime? dateFrom,
        [FromQuery] DateTime? dateTo,
        [FromQuery] string? kind,
        [FromQuery] Guid? operatorId,
        [FromQuery] string? receivedByName,
        [FromQuery] string? pullNumber,
        [FromQuery] string? poNumber,
        [FromQuery] string? itemCode,
        [FromQuery] int? hour,
        [FromQuery] string? q,
        [FromQuery] int? take,
        [FromQuery] int? skip,
        CancellationToken ct)
    {
        // Non-admins are scoped to their session warehouse, regardless of query string.
        // Admins can pass any warehouseId/Code or omit for cross-warehouse view.
        var isAdmin = User.IsInRole("admin");
        var effectiveWhId = isAdmin
            ? warehouseId
            : ParseGuid(User.FindFirstValue("warehouseId"));
        var effectiveWhCode = isAdmin ? warehouseCode : null;

        var filter = new TransactionsQuery(
            WarehouseId:    effectiveWhId,
            WarehouseCode:  effectiveWhCode,
            DateFrom:       dateFrom,
            DateTo:         dateTo,
            Kind:           NormaliseKind(kind),
            OperatorId:     operatorId,
            ReceivedByName: receivedByName,
            PullNumber:     pullNumber,
            PoNumber:       poNumber,
            ItemCode:       itemCode,
            Hour:           hour,
            Q:              q,
            Take:           Math.Clamp(take ?? DefaultTake, 1, MaxTake),
            Skip:           Math.Max(0, skip ?? 0));

        return await _repo.QueryAsync(filter, ct);
    }

    private static string? NormaliseKind(string? k)
    {
        if (string.IsNullOrWhiteSpace(k)) return null;
        var v = k.Trim().ToLowerInvariant();
        return v is "receive" or "voided" or "reversal" ? v : null;
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;
}
