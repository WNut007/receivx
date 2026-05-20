using System.Data;
using System.Security.Claims;
using Dapper;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public class CloseService : ICloseService
{
    // §7.4: signature payload sanity bound. NVARCHAR(MAX) so the column itself is fine;
    // the limit is to refuse pathological client uploads. Roughly the size of a 1024-wide
    // PNG data URL — generous for a signature pad.
    private const int MaxSignatureLength = 200 * 1024;

    private readonly IDbConnectionFactory _factory;
    private readonly IAuditService _audit;
    private readonly IHttpContextAccessor _httpContext;

    public CloseService(IDbConnectionFactory factory, IAuditService audit, IHttpContextAccessor httpContext)
    {
        _factory = factory;
        _audit = audit;
        _httpContext = httpContext;
    }

    public async Task<CloseResult> CloseAsync(Guid pullId, CloseRequest req, CancellationToken ct = default)
    {
        var sig = req.SignatureSvg ?? "";
        if (string.IsNullOrWhiteSpace(sig))
            throw new BusinessException("Signature is required");
        if (sig.Length > MaxSignatureLength)
            // The controller layer maps PayloadTooLargeException → 413; using a dedicated
            // type here lets the caller branch without parsing the message.
            throw new PayloadTooLargeException(
                $"Signature is too large ({sig.Length} bytes; max {MaxSignatureLength})");

        var actorId = CurrentUserId();
        var (sessionWh, isAdmin) = SessionWarehouseContext();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // Lock + read pull. Single query — we need PullNumber for the audit message
            // and WarehouseId for scoping.
            var pull = await conn.QuerySingleOrDefaultAsync<PullLockRow>(new CommandDefinition(@"
                SELECT Id, PullNumber, Status, WarehouseId
                FROM dbo.Pulls WITH (UPDLOCK, ROWLOCK)
                WHERE Id = @Id;",
                new { Id = pullId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Pull not found");

            if (!isAdmin && sessionWh != pull.WarehouseId)
                throw new ForbiddenException("You do not have access to this pull");

            if (string.Equals(pull.Status, "closed", StringComparison.Ordinal))
                throw new BusinessException("Pull is already closed");

            // §7.4 gate: one query against PullItems + PullItemWindows. Non-canceled
            // items only. Outstanding = any window where ExpectedQty > ReceivedQty.
            var outstanding = await conn.QuerySingleAsync<int>(new CommandDefinition(@"
                SELECT COUNT(*)
                FROM dbo.PullItems pi
                INNER JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
                WHERE pi.PullId = @PullId
                  AND pi.Status <> 'canceled'
                  AND piw.ExpectedQty > piw.ReceivedQty;",
                new { PullId = pullId }, transaction: tx, cancellationToken: ct));
            if (outstanding > 0)
                throw new BusinessException(
                    $"Pull has {outstanding} outstanding window(s); cannot close.");

            // §7.11: total received via the view (handles reversals correctly).
            // Used only for the audit message.
            var totalReceived = await conn.QuerySingleAsync<int>(new CommandDefinition(@"
                SELECT ISNULL(SUM(v.NetReceived), 0)
                FROM dbo.PullItems pi
                INNER JOIN dbo.vw_PullItemReceived v ON v.PullItemId = pi.Id
                WHERE pi.PullId = @PullId
                  AND pi.Status <> 'canceled';",
                new { PullId = pullId }, transaction: tx, cancellationToken: ct));

            var closedAt = await conn.QuerySingleAsync<DateTime>(new CommandDefinition(@"
                UPDATE dbo.Pulls
                   SET Status       = 'closed',
                       ClosedAt     = SYSUTCDATETIME(),
                       ClosedBy     = @ActorId,
                       SignatureSvg = @Sig
                 OUTPUT INSERTED.ClosedAt
                 WHERE Id = @PullId;",
                new { PullId = pullId, ActorId = actorId, Sig = sig },
                transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "close", "Pull", pullId.ToString(),
                $"Closed pull {pull.PullNumber} ({totalReceived} pcs received)", ct);

            tx.Commit();

            return new CloseResult
            {
                PullId = pullId,
                ClosedAt = closedAt,
                TotalReceived = totalReceived,
            };
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    public async Task<ReopenResult> ReopenAsync(Guid pullId, ReopenRequest req, CancellationToken ct = default)
    {
        var reason = (req.Reason ?? "").Trim();
        if (string.IsNullOrEmpty(reason))
            throw new BusinessException("Reason is required");
        if (reason.Length > 500)
            throw new BusinessException("Reason exceeds 500 characters");

        var actorId = CurrentUserId();
        var (sessionWh, isAdmin) = SessionWarehouseContext();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await conn.QuerySingleOrDefaultAsync<PullCloseRow>(new CommandDefinition(@"
                SELECT p.Id, p.PullNumber, p.Status, p.WarehouseId,
                       p.ClosedAt, cb.Name AS ClosedByName
                FROM dbo.Pulls p WITH (UPDLOCK, ROWLOCK)
                LEFT JOIN dbo.Users cb ON cb.Id = p.ClosedBy
                WHERE p.Id = @Id;",
                new { Id = pullId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Pull not found");

            if (!isAdmin && sessionWh != pull.WarehouseId)
                throw new ForbiddenException("You do not have access to this pull");

            if (!string.Equals(pull.Status, "closed", StringComparison.Ordinal))
                throw new BusinessException("Pull is not closed");

            // §7.5: PRESERVE ClosedAt/ClosedBy/SignatureSvg. Only set the reopen trio
            // and demote status to in_progress (NOT pending — work has happened).
            var reopenedAt = await conn.QuerySingleAsync<DateTime>(new CommandDefinition(@"
                UPDATE dbo.Pulls
                   SET Status       = 'in_progress',
                       ReopenedAt   = SYSUTCDATETIME(),
                       ReopenedBy   = @ActorId,
                       ReopenReason = @Reason
                 OUTPUT INSERTED.ReopenedAt
                 WHERE Id = @PullId;",
                new { PullId = pullId, ActorId = actorId, Reason = reason },
                transaction: tx, cancellationToken: ct));

            var closedAtStr = pull.ClosedAt?.ToString("u") ?? "(unknown)";
            var closedByName = pull.ClosedByName ?? "(unknown)";
            await _audit.WriteAsync(conn, tx, "reopen", "Pull", pullId.ToString(),
                $"Reopened pull {pull.PullNumber}. Reason: {reason}. Previously closed at {closedAtStr} by {closedByName}.", ct);

            tx.Commit();

            return new ReopenResult { PullId = pullId, ReopenedAt = reopenedAt };
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ----- helpers -----

    private Guid CurrentUserId()
    {
        var ctx = _httpContext.HttpContext
            ?? throw new InvalidOperationException("HttpContext unavailable");
        var idClaim = ctx.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!Guid.TryParse(idClaim, out var id))
            throw new InvalidOperationException("Authenticated user has no NameIdentifier claim");
        return id;
    }

    private (Guid? warehouseId, bool isAdmin) SessionWarehouseContext()
    {
        var ctx = _httpContext.HttpContext;
        if (ctx is null) return (null, false);

        var isAdmin = ctx.User.IsInRole("admin");
        Guid? wh = null;
        if (Guid.TryParse(ctx.User.FindFirstValue("warehouseId"), out var g)) wh = g;
        return (wh, isAdmin);
    }

    private sealed class PullLockRow
    {
        public Guid Id { get; set; }
        public string PullNumber { get; set; } = "";
        public string Status { get; set; } = "";
        public Guid WarehouseId { get; set; }
    }

    private sealed class PullCloseRow
    {
        public Guid Id { get; set; }
        public string PullNumber { get; set; } = "";
        public string Status { get; set; } = "";
        public Guid WarehouseId { get; set; }
        public DateTime? ClosedAt { get; set; }
        public string? ClosedByName { get; set; }
    }
}
