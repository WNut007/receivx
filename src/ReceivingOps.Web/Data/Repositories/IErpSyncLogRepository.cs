using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

/// <summary>
/// Phase 10.6 — read/write surface for dbo.ErpSyncLog. ErpSyncJob calls
/// InsertStartAsync → MarkSucceededAsync (or MarkFailedAsync). The status
/// page controller calls QueryPagedAsync / GetByRunIdAsync.
/// </summary>
public interface IErpSyncLogRepository
{
    /// <summary>Insert the initial Status='running' row when the job's mutex is acquired.</summary>
    Task InsertStartAsync(
        Guid runId, string triggeredBy, string actorName,
        Guid warehouseId, int backfillDays, CancellationToken ct = default);

    /// <summary>Worker success — Status='succeeded' + CompletedAt + totals + elapsed.</summary>
    Task MarkSucceededAsync(
        Guid runId, ErpSyncLogTotals totals, int elapsedMs, CancellationToken ct = default);

    /// <summary>Catastrophic worker failure — Status='failed' + CompletedAt + truncated error.</summary>
    Task MarkFailedAsync(
        Guid runId, string errorMessage, int elapsedMs, CancellationToken ct = default);

    /// <summary>Paged list, newest first. Total = full row count for pagination math.</summary>
    Task<(IReadOnlyList<ErpSyncLogRow> Items, int Total)> QueryPagedAsync(
        int skip, int take, CancellationToken ct = default);

    /// <summary>Single-row lookup for the drill-down view; returns null if not found.</summary>
    Task<ErpSyncLogRow?> GetByRunIdAsync(Guid runId, CancellationToken ct = default);

    /// <summary>
    /// Phase 13.1 — write the per-source counter JSON for a run. The aggregate
    /// scalar counters still flow through <see cref="MarkSucceededAsync"/>;
    /// this is the per-source breakdown the status drill-down renders.
    /// </summary>
    Task UpdateSourceTotalsAsync(Guid runId, string sourceTotalsJson, CancellationToken ct = default);
}
