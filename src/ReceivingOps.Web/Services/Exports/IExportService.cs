namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 — public surface for kicking off an export. Wraps the
/// Hangfire enqueue so callers (controllers) don't need to take a direct
/// dependency on the job framework.
/// </summary>
public interface IExportService
{
    /// <summary>Queues a transactions export. Returns the assigned jobId.</summary>
    Task<Guid> EnqueueTransactionsExportAsync(TransactionsExportRequest request, Guid requesterUserId, string requesterEmail, string requesterName, CancellationToken ct = default);

    /// <summary>Queues a /Pos (Purchase Orders) export. Returns the assigned jobId.</summary>
    Task<Guid> EnqueuePosExportAsync(PosExportRequest request, Guid requesterUserId, string requesterEmail, string requesterName, CancellationToken ct = default);

    /// <summary>Queues an Audit Log export (admin-only at controller layer). Returns the assigned jobId.</summary>
    Task<Guid> EnqueueAuditLogExportAsync(AuditLogExportRequest request, Guid requesterUserId, string requesterEmail, string requesterName, CancellationToken ct = default);
}
