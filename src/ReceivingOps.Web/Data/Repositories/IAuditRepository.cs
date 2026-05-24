using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public interface IAuditRepository
{
    /// <summary>
    /// Recent audit entries, optionally filtered by action type and a multi-token AND
    /// search across Message + EntityType + ActorName. `take` is clamped 1..500.
    /// </summary>
    Task<IReadOnlyList<AuditRow>> QueryAsync(AuditQuery query, CancellationToken ct = default);

    /// <summary>
    /// Phase 8.4 ext — full-result query for export jobs. Same filters
    /// as <see cref="QueryAsync"/> plus a date window; capped at the
    /// caller-supplied MaxRows (bounded internally to 100K to keep the
    /// worker's memory footprint predictable).
    /// </summary>
    Task<IReadOnlyList<AuditRow>> QueryForExportAsync(AuditExportQuery query, CancellationToken ct = default);
}
