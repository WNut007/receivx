using System.Security.Claims;
using Dapper;
using Microsoft.Data.SqlClient;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public class PullAdminService : IPullAdminService
{
    private readonly IDbConnectionFactory _factory;
    private readonly IAuditService _audit;
    private readonly IHttpContextAccessor _httpContext;

    public PullAdminService(IDbConnectionFactory factory, IAuditService audit, IHttpContextAccessor httpContext)
    {
        _factory = factory;
        _audit = audit;
        _httpContext = httpContext;
    }

    // ========================================================================
    // CREATE
    // ========================================================================
    public async Task<Guid> CreateAsync(PullCreateRequest req, CancellationToken ct = default)
    {
        ValidateCreate(req);

        var actorId = CurrentUserId();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // PullNumber uniqueness — DB UNIQUE is the last line of defense; pre-check gives a friendlier error.
            var dup = await conn.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM dbo.Pulls WHERE PullNumber = @PullNumber;",
                new { req.PullNumber }, transaction: tx, cancellationToken: ct));
            if (dup.HasValue)
                throw new BusinessException($"Pull number '{req.PullNumber}' is already taken");

            var newId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status,
                                       Eta, Notes, CreatedBy, CreatedAt, LockPoByPull)
                OUTPUT INSERTED.Id
                VALUES (NEWID(), @PullNumber, @WarehouseId, @PullDate, 'pending',
                        @Eta, @Notes, @CreatedBy, SYSUTCDATETIME(), @LockPoByPull);",
                new
                {
                    req.PullNumber, req.WarehouseId, req.PullDate,
                    req.Eta, req.Notes, req.LockPoByPull,
                    CreatedBy = actorId,
                }, transaction: tx, cancellationToken: ct));

            var lockSuffix = req.LockPoByPull ? " (LockPoByPull=true)" : "";
            await _audit.WriteAsync(conn, tx, "create", "Pull", newId.ToString(),
                $"Created pull {req.PullNumber} for warehouse {req.WarehouseId}{lockSuffix}", ct);

            tx.Commit();
            return newId;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            tx.Rollback();
            throw new BusinessException($"Pull number '{req.PullNumber}' is already taken");
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ========================================================================
    // UPDATE (§3.5 LockPoByPull immutability)
    // ========================================================================
    public async Task UpdateAsync(Guid id, PullUpdateRequest req, CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await conn.QuerySingleOrDefaultAsync<PullLockRow>(new CommandDefinition(@"
                SELECT Id, PullNumber, Status, LockPoByPull
                FROM   dbo.Pulls WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Pull not found");

            // §3.5 — LockPoByPull is immutable after create. Strict echo, in both directions.
            if (req.LockPoByPull != pull.LockPoByPull)
                throw new BusinessException(
                    "LockPoByPull is immutable after pull creation.");

            // §7.12 — closed pulls are read-only at this surface (reopen via §7.5 first).
            if (string.Equals(pull.Status, "closed", StringComparison.Ordinal))
                throw new BusinessException(
                    "Cannot edit a closed pull. Reopen it first if you need to change details.");

            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Pulls
                   SET PullDate = @PullDate,
                       Eta      = @Eta,
                       Notes    = @Notes
                 WHERE Id = @Id;",
                new
                {
                    Id = id, req.PullDate, req.Eta, req.Notes,
                }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "update", "Pull", id.ToString(),
                $"Updated pull {pull.PullNumber}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ========================================================================
    // helpers
    // ========================================================================
    private static void ValidateCreate(PullCreateRequest req)
    {
        if (string.IsNullOrWhiteSpace(req.PullNumber) || req.PullNumber.Length > 32)
            throw new ValidationException("PullNumber is required (≤ 32 chars)");
        if (req.WarehouseId == Guid.Empty)
            throw new ValidationException("WarehouseId is required");
        if (req.PullDate == default)
            throw new ValidationException("PullDate is required");
        if (req.Eta is not null && req.Eta.Length > 64)
            throw new ValidationException("Eta is too long (≤ 64 chars)");
        if (req.Notes is not null && req.Notes.Length > 500)
            throw new ValidationException("Notes is too long (≤ 500 chars)");
    }

    private Guid CurrentUserId()
    {
        var ctx = _httpContext.HttpContext
            ?? throw new InvalidOperationException("HttpContext unavailable");
        var idClaim = ctx.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!Guid.TryParse(idClaim, out var id))
            throw new InvalidOperationException("Authenticated user has no NameIdentifier claim");
        return id;
    }

    private sealed class PullLockRow
    {
        public Guid Id { get; set; }
        public string PullNumber { get; set; } = "";
        public string Status { get; set; } = "";
        public bool LockPoByPull { get; set; }
    }
}
