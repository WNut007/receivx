using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

/// <summary>
/// Phase 8.5 — read/write surface for dbo.ExportJobsLog. The Hangfire
/// jobs use the Update* methods to advance state; the controller uses
/// QueryPagedAsync for the My Exports page.
///
/// All Update* methods are idempotent — Hangfire retries call the same
/// jobId, so an Update is essentially an upsert from the second attempt
/// on. The repo just runs UPDATE ... WHERE Id = @Id; no concurrency token
/// because Hangfire serializes attempts of the same job.
/// </summary>
public interface IExportJobLogRepository
{
    /// <summary>Insert the initial Status='queued' row when ExportService hands the job to Hangfire.</summary>
    Task InsertQueuedAsync(ExportJobLogRow row, CancellationToken ct = default);

    /// <summary>Worker entry — flip Status='running' + stamp StartedAt.</summary>
    Task UpdateRunningAsync(Guid id, CancellationToken ct = default);

    /// <summary>Worker success — Status='succeeded' + CompletedAt + file metadata.</summary>
    Task UpdateSucceededAsync(Guid id, string fileName, int rowsExported, CancellationToken ct = default);

    /// <summary>Worker failure — Status='failed' + CompletedAt + truncated error text.</summary>
    Task UpdateFailedAsync(Guid id, string errorMessage, CancellationToken ct = default);

    /// <summary>
    /// Paged list. When <paramref name="requesterUserId"/> is non-null, scoped to
    /// that user's own exports; when null, returns everyone (caller is admin).
    /// </summary>
    Task<(IReadOnlyList<ExportJobLogRow> Items, int Total)> QueryPagedAsync(
        Guid? requesterUserId, int skip, int take, CancellationToken ct = default);

    /// <summary>Single-row lookup — used by the download endpoint if it ever wants to verify the log row exists.</summary>
    Task<ExportJobLogRow?> GetByIdAsync(Guid id, CancellationToken ct = default);
}
