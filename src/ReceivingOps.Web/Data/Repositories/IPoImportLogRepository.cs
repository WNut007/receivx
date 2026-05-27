using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

/// <summary>
/// Phase 12.3 — read/write surface for dbo.PoImportLog.
///
/// <para>Write pattern follows the state machine in
/// <see cref="PoImportLogRow"/>: <c>InsertSubmittedAsync</c> at upload,
/// then <c>MarkValidated</c> | <c>MarkValidationFailed</c> after Stage 1
/// parse, then <c>MarkQueued</c> on operator confirm, then
/// <c>MarkRunning</c> → <c>MarkSucceeded</c> | <c>MarkFailed</c> from
/// the Hangfire worker.</para>
///
/// <para>Reads support the two surfaces: the paged
/// <c>/Admin/PoImport</c> list view (12.7) and the drill-down detail
/// page. Warehouse-scope filter lets supervisors see only their own
/// warehouse; admin passes <c>warehouseId = null</c> for see-all.</para>
/// </summary>
public interface IPoImportLogRepository
{
    /// <summary>Initial row at upload — Status='validating', SubmittedAt=now.</summary>
    Task InsertSubmittedAsync(
        Guid runId, string uploadedBy, Guid uploadedByUserId, string uploadedByRole,
        Guid warehouseId, string fileName, long fileSizeBytes, string storagePath,
        CancellationToken ct = default);

    /// <summary>
    /// Stage 1 rejected the file. <paramref name="validationErrorsJson"/>
    /// is the serialized list of <see cref="Services.PoImport.PoImportValidationError"/>
    /// — the operator's pre-flight modal renders the first 50.
    /// </summary>
    Task MarkValidationFailedAsync(
        Guid runId, int totalRowsRead, int validationErrorCount,
        string validationErrorsJson, CancellationToken ct = default);

    /// <summary>Stage 1 passed; awaiting operator confirm. CompletedAt stays null until terminal.</summary>
    Task MarkValidatedAsync(
        Guid runId, int totalRowsRead, CancellationToken ct = default);

    /// <summary>Operator confirmed; Hangfire enqueued. Records HangfireJobId for dashboard drill-down.</summary>
    Task MarkQueuedAsync(
        Guid runId, string hangfireJobId, CancellationToken ct = default);

    /// <summary>Hangfire worker started — StartedAt=now.</summary>
    Task MarkRunningAsync(Guid runId, CancellationToken ct = default);

    /// <summary>Atomic insert tx committed — Status='succeeded' + CompletedAt + counts + elapsed.</summary>
    Task MarkSucceededAsync(
        Guid runId, int posInserted, int linesInserted, int elapsedMs,
        CancellationToken ct = default);

    /// <summary>Catastrophic worker failure — Status='failed' + CompletedAt + truncated error.</summary>
    Task MarkFailedAsync(
        Guid runId, string errorMessage, int elapsedMs, CancellationToken ct = default);

    /// <summary>
    /// Paged list, newest first. <paramref name="warehouseId"/> null = see-all
    /// (admin only — controller enforces). Total = full row count after the
    /// optional warehouse filter, for pagination math.
    /// </summary>
    Task<(IReadOnlyList<PoImportLogRow> Items, int Total)> QueryPagedAsync(
        int skip, int take, Guid? warehouseId, CancellationToken ct = default);

    /// <summary>Single-row lookup for the drill-down view; returns null if not found.</summary>
    Task<PoImportLogRow?> GetByRunIdAsync(Guid runId, CancellationToken ct = default);
}
