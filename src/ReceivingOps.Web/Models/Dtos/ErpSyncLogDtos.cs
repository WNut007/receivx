namespace ReceivingOps.Web.Models.Dtos;

/// <summary>
/// Phase 10.6 — read shape for dbo.ErpSyncLog. Dapper materializes
/// columns by name so the property list mirrors the table exactly.
/// </summary>
public class ErpSyncLogRow
{
    public Guid RunId { get; set; }
    public string TriggeredBy { get; set; } = "";      // 'recurring' | 'manual'
    public string ActorName { get; set; } = "";        // '[system]' or operator displayName
    public Guid WarehouseId { get; set; }
    public int BackfillDays { get; set; }
    public string Status { get; set; } = "running";    // 'running' | 'succeeded' | 'failed'
    public DateTime StartedAt { get; set; }
    public DateTime? CompletedAt { get; set; }
    public int? ElapsedMs { get; set; }
    public int? SourceRowCount { get; set; }
    public int? DraftPullCount { get; set; }
    public int? Created { get; set; }
    public int? Updated { get; set; }
    public int? SkippedClosed { get; set; }
    public int? Errors { get; set; }
    public int? ItemsAdded { get; set; }
    public int? ItemsCanceled { get; set; }
    public string? ErrorMessage { get; set; }
}

/// <summary>
/// Phase 10.6 — totals shape passed from ErpSyncJob into
/// IErpSyncLogRepository.MarkSucceededAsync. Mirrors the relevant
/// counters from <see cref="Services.ErpSync.ErpUpsertResult"/> +
/// the source counts from <see cref="Services.ErpSync.ErpSyncDraft"/>.
/// Kept as its own type so the repo doesn't take a dependency on the
/// ErpSync namespace.
/// </summary>
public class ErpSyncLogTotals
{
    public int SourceRowCount { get; set; }
    public int DraftPullCount { get; set; }
    public int Created { get; set; }
    public int Updated { get; set; }
    public int SkippedClosed { get; set; }
    public int Errors { get; set; }
    public int ItemsAdded { get; set; }
    public int ItemsCanceled { get; set; }
}
