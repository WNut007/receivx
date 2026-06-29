using System.Security.Claims;
using Dapper;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Services;

public class PullSignatureService : IPullSignatureService
{
    // Canonical party labels — stored Title-case (CK_PullSig_Party enforces these).
    // The authorizing per-warehouse whRole is the lowercase peer (customer/warehouse/
    // production) — see RequiredWhRole below.
    private static readonly string[] Parties = { "Customer", "Warehouse", "Production" };

    private readonly IDbConnectionFactory _factory;
    private readonly IPullSignatureRepository _repo;
    private readonly IAuditService _audit;
    private readonly IHttpContextAccessor _httpContext;

    public PullSignatureService(
        IDbConnectionFactory factory,
        IPullSignatureRepository repo,
        IAuditService audit,
        IHttpContextAccessor httpContext)
    {
        _factory = factory;
        _repo = repo;
        _audit = audit;
        _httpContext = httpContext;
    }

    public async Task<SignatureResult> SignAsync(Guid pullId, string party, CancellationToken ct = default)
    {
        // Normalize + validate against the canonical party set.
        var canonical = Parties.FirstOrDefault(
            p => string.Equals(p, party?.Trim(), StringComparison.OrdinalIgnoreCase))
            ?? throw new BusinessException(
                $"Invalid party '{party}'. Expected Customer, Warehouse, or Production.");

        var ctx = _httpContext.HttpContext
            ?? throw new InvalidOperationException("HttpContext unavailable");

        var userId = ParseUserId(ctx);
        var signerName = ctx.User.FindFirstValue("displayName")
            ?? ctx.User.Identity?.Name ?? "(unknown)";
        var whRole = ctx.User.FindFirstValue("whRole") ?? "";
        var sessionWh = Guid.TryParse(ctx.User.FindFirstValue("warehouseId"), out var g) ? g : Guid.Empty;

        // Role gate (defense-in-depth alongside the controller's CanSign{Party} policy):
        // whRole must equal the lowercase peer of the party. No admin override — admins
        // manage/view, they don't sign.
        if (!string.Equals(whRole, canonical.ToLowerInvariant(), StringComparison.Ordinal))
            throw new ForbiddenException($"Your role does not permit signing the {canonical} box.");

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await conn.QuerySingleOrDefaultAsync<PullScopeRow>(new CommandDefinition(@"
                SELECT Id, PullNumber, WarehouseId
                FROM dbo.Pulls WITH (UPDLOCK, ROWLOCK)
                WHERE Id = @Id;",
                new { Id = pullId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Pull not found");

            // Warehouse scope: signer's session warehouse must match the pull's.
            if (sessionWh != pull.WarehouseId)
                throw new ForbiddenException("You do not have access to this pull's warehouse.");

            // Immutability: one signature per (pull, party). Pre-check under UPDLOCK for a
            // friendly error; UQ_PullSig_Party is the hard guard against a race.
            if (await _repo.ExistsAsync(conn, tx, pullId, canonical, ct))
                throw new BusinessException($"The {canonical} box is already signed for this pull.");

            var sig = await _repo.InsertAsync(conn, tx, new PullSignature
            {
                PullId = pullId,
                Party = canonical,
                WarehouseId = pull.WarehouseId,
                SignerUserId = userId,
                SignerName = signerName,
            }, ct);

            await _audit.WriteAsync(conn, tx, "do-sign", "Pull", pullId.ToString(),
                $"Signed {canonical} on pull {pull.PullNumber} as {signerName}", ct);

            tx.Commit();

            return new SignatureResult
            {
                PullId = pullId,
                Party = canonical,
                SignerName = signerName,
                SignedAt = sig.SignedAt,
            };
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    private static Guid ParseUserId(HttpContext ctx)
    {
        var idClaim = ctx.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!Guid.TryParse(idClaim, out var id))
            throw new InvalidOperationException("Authenticated user has no NameIdentifier claim");
        return id;
    }

    private sealed class PullScopeRow
    {
        public Guid Id { get; set; }
        public string PullNumber { get; set; } = "";
        public Guid WarehouseId { get; set; }
    }
}
