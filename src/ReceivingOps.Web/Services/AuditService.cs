using System.Data;
using System.Security.Claims;
using Dapper;
using ReceivingOps.Web.Data;

namespace ReceivingOps.Web.Services;

public class AuditService : IAuditService
{
    private const string InsertSql = @"
        INSERT INTO dbo.AuditLog (ActionType, EntityType, EntityId, Message, ActorUserId, ActorName, IpAddress)
        VALUES (@ActionType, @EntityType, @EntityId, @Message, @ActorUserId, @ActorName, @IpAddress);";

    private readonly IDbConnectionFactory _factory;
    private readonly IHttpContextAccessor _httpContext;
    private readonly ILogger<AuditService> _logger;

    public AuditService(IDbConnectionFactory factory, IHttpContextAccessor httpContext, ILogger<AuditService> logger)
    {
        _factory = factory;
        _httpContext = httpContext;
        _logger = logger;
    }

    public async Task WriteAsync(IDbConnection conn, IDbTransaction? tx,
        string actionType, string? entityType, string? entityId,
        string message, CancellationToken ct = default)
    {
        try
        {
            var (actorId, actorName, ip) = ResolveActor();
            await conn.ExecuteAsync(new CommandDefinition(InsertSql,
                new
                {
                    ActionType = actionType,
                    EntityType = entityType,
                    EntityId = entityId,
                    Message = message,
                    ActorUserId = actorId,
                    ActorName = actorName,
                    IpAddress = ip
                },
                transaction: tx,
                cancellationToken: ct));
        }
        catch (Exception ex)
        {
            // §8: never let an audit write throw and roll back the user's business action.
            _logger.LogError(ex, "Audit write failed: {ActionType} {EntityType}/{EntityId}",
                actionType, entityType, entityId);
        }
    }

    public async Task WriteAsync(string actionType, string? entityType, string? entityId,
        string message, CancellationToken ct = default)
    {
        try
        {
            using var conn = _factory.Create();
            await WriteAsync(conn, null, actionType, entityType, entityId, message, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Standalone audit write failed: {ActionType}", actionType);
        }
    }

    private (Guid? actorId, string? actorName, string? ip) ResolveActor()
    {
        var ctx = _httpContext.HttpContext;
        if (ctx is null) return (null, null, null);

        Guid? id = null;
        var idClaim = ctx.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (Guid.TryParse(idClaim, out var g)) id = g;

        var name = ctx.User.FindFirstValue("displayName") ?? ctx.User.Identity?.Name;
        var ip = ctx.Connection.RemoteIpAddress?.ToString();

        return (id, name, ip);
    }
}
