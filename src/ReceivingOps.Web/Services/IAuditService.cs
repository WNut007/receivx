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
}
