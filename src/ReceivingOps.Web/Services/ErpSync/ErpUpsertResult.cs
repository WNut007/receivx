namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10.3 — outcome of applying an <see cref="ErpSyncDraft"/> to the
/// Receivx DB. Per-pull counts let the job log a single-line summary
/// and 10.5 will turn <see cref="PullOutcomes"/> into per-pull audit rows.
/// </summary>
public class ErpUpsertResult
{
    /// <summary>New Pulls inserted (with items + windows).</summary>
    public int Created { get; set; }

    /// <summary>Existing pulls updated in place (planning fields only).</summary>
    public int Updated { get; set; }

    /// <summary>Pulls skipped because they are already <c>closed</c>.</summary>
    public int SkippedClosed { get; set; }

    /// <summary>
    /// Pulls skipped because of an unrecoverable error (PullNumber too long,
    /// FK lookup failed, constraint violation, etc.). One entry per pull.
    /// </summary>
    public int Errors { get; set; }

    /// <summary>Items that ETL marked <c>canceled</c> because the ERP no longer references them.</summary>
    public int ItemsCanceled { get; set; }

    /// <summary>Items inserted on update-path pulls (newly-added by ERP since last run).</summary>
    public int ItemsAdded { get; set; }

    /// <summary>
    /// Per-pull detail. Kept small (PullNumber + outcome + optional error)
    /// so it's safe to log + later audit. Populated for every pull in the draft.
    /// </summary>
    public List<PullOutcome> PullOutcomes { get; set; } = new();

    public int TotalProcessed => Created + Updated + SkippedClosed + Errors;
}

/// <summary>One row in <see cref="ErpUpsertResult.PullOutcomes"/>.</summary>
public class PullOutcome
{
    public string PullNumber { get; set; } = "";
    public string Outcome { get; set; } = "";   // created|updated|skipped-closed|error
    public string? Detail { get; set; }         // error message, or short summary
}
