using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public interface IAuditRepository
{
    /// <summary>
    /// Recent audit entries, optionally filtered by action type and a multi-token AND
    /// search across Message + EntityType + ActorName. `take` is clamped 1..500.
    /// </summary>
    Task<IReadOnlyList<AuditRow>> QueryAsync(AuditQuery query, CancellationToken ct = default);
}
