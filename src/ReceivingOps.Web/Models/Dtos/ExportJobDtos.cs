namespace ReceivingOps.Web.Models.Dtos;

/// <summary>
/// Phase 8.5 — single row of the My Exports list. Mirrors
/// dbo.ExportJobsLog 1:1, plus controller-derived fields the UI needs.
/// </summary>
public class ExportJobLogRow
{
    public Guid Id { get; set; }
    public Guid RequesterUserId { get; set; }
    public string RequesterEmail { get; set; } = "";
    public string RequesterName  { get; set; } = "";
    public string JobType        { get; set; } = "";   // 'transactions' | 'pos' | 'audit-log'
    public string? FilterJson    { get; set; }
    public string Status         { get; set; } = "";   // 'queued' | 'running' | 'succeeded' | 'failed'
    public DateTime EnqueuedAt   { get; set; }
    public DateTime? StartedAt   { get; set; }
    public DateTime? CompletedAt { get; set; }
    public string? FileName      { get; set; }
    public int? RowsExported     { get; set; }
    public string? ErrorMessage  { get; set; }
}

/// <summary>
/// Phase 8.5 — payload for GET /api/exports/jobs. <see cref="DownloadUrl"/>
/// is computed by the controller (HMAC-signed, only populated for
/// succeeded jobs whose files are still on disk). <see cref="EffectiveStatus"/>
/// is "expired" when the row's <see cref="ExportJobLogRow.Status"/> = "succeeded"
/// but the file has been swept off disk past <c>ExportOptions.FileLifetime</c>.
/// </summary>
public class ExportJobView
{
    public Guid Id { get; set; }
    public string JobType        { get; set; } = "";
    public string Status         { get; set; } = "";   // 'queued' | 'running' | 'succeeded' | 'failed'
    public string EffectiveStatus { get; set; } = ""; // adds 'expired' over Status
    public DateTime EnqueuedAt   { get; set; }
    public DateTime? StartedAt   { get; set; }
    public DateTime? CompletedAt { get; set; }
    public string? FileName      { get; set; }
    public int? RowsExported     { get; set; }
    public string? ErrorMessage  { get; set; }
    public string? DownloadUrl   { get; set; }   // null unless EffectiveStatus == "succeeded"
    // Admin-only "see all" view fills the requester fields; per-user view leaves them null.
    public string? RequesterEmail { get; set; }
    public string? RequesterName  { get; set; }
}
