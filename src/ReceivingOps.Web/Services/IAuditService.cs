using System.Data;

namespace ReceivingOps.Web.Services;

public interface IAuditService
{
    /// <summary>Writes an audit row inside the caller's transaction. Never throws.</summary>
    Task WriteAsync(IDbConnection conn, IDbTransaction? tx,
        string actionType, string? entityType, string? entityId,
        string message, CancellationToken ct = default);

    /// <summary>Standalone write using a fresh connection — for login/logout outside a tx.</summary>
    Task WriteAsync(string actionType, string? entityType, string? entityId,
        string message, CancellationToken ct = default);

    /// <summary>
    /// Phase 10.5 — write an audit row with an explicitly-supplied actor name
    /// (no HttpContext required). Used by ETL paths that run on Hangfire worker
    /// threads where no request context exists. Pass <c>"[system]"</c> for the
    /// recurring path or the operator's display name for the manual path.
    /// </summary>
    Task WriteSystemAsync(IDbConnection conn, IDbTransaction? tx,
        string actorName, string actionType, string? entityType, string? entityId,
        string message, CancellationToken ct = default);

    /// <summary>Standalone <see cref="WriteSystemAsync"/> for writes outside any caller tx.</summary>
    Task WriteSystemAsync(string actorName, string actionType,
        string? entityType, string? entityId, string message,
        CancellationToken ct = default);
}
