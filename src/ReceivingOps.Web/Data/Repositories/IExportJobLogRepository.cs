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
    /// <paramref name="tab"/> filters to "pending" (queued | running | failed |
    /// succeeded-undownloaded) or "downloaded" (succeeded + DownloadedAt set);
    /// any other value (incl. null/empty) returns all rows in the scope.
    /// </summary>
    Task<(IReadOnlyList<ExportJobLogRow> Items, int Total)> QueryPagedAsync(
        Guid? requesterUserId, string? tab, int skip, int take, CancellationToken ct = default);

    /// <summary>
    /// Phase 8.4 ext — tab badges. Pending = queued|running|failed PLUS
    /// the subset of succeeded-undownloaded rows whose files are still on
    /// disk (controller passes the present-id set so expired rows don't
    /// inflate the badge). Downloaded = pure SQL count of succeeded +
    /// DownloadedAt set.
    /// </summary>
    Task<ExportTabCounts> GetTabCountsAsync(
        Guid? requesterUserId, ISet<string> presentIdHexes, CancellationToken ct = default);

    /// <summary>
    /// Phase 8.4 ext — stamps DownloadedAt on the user's succeeded row.
    /// Privacy guard: WHERE RequesterUserId = @UserId — operator can't
    /// mark someone else's row. Idempotent: a second call after the
    /// row is already marked is a no-op (returns 0). Returns the
    /// affected row count (0 or 1).
    /// </summary>
    Task<int> MarkDownloadedAsync(Guid id, Guid requesterUserId, CancellationToken ct = default);

    /// <summary>Single-row lookup — used by the download endpoint if it ever wants to verify the log row exists.</summary>
    Task<ExportJobLogRow?> GetByIdAsync(Guid id, CancellationToken ct = default);

    /// <summary>
    /// Phase 8.5+ badge — count this user's succeeded export jobs that
    /// haven't been read yet AND whose file is still on disk. Files that
    /// have expired don't count (operator can't do anything with them).
    /// File existence is checked at the caller (controller does the disk
    /// scan once and passes the present-id set in).
    /// </summary>
    Task<int> CountUnreadSucceededAsync(Guid userId, ISet<string> presentIdHexes, CancellationToken ct = default);

    /// <summary>
    /// Marks all of the user's currently-unread succeeded jobs as read.
    /// Returns the affected row count. Idempotent (re-runs no-op once
    /// nothing's unread).
    /// </summary>
    Task<int> MarkAllUnreadAsReadAsync(Guid userId, CancellationToken ct = default);
}
