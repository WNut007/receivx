namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 — public surface for kicking off an export. Wraps the
/// Hangfire enqueue so callers (controllers) don't need to take a direct
/// dependency on the job framework.
/// </summary>
public interface IExportService
{
    /// <summary>Queues a transactions export. Returns the assigned jobId.</summary>
    Guid EnqueueTransactionsExport(TransactionsExportRequest request, string requesterEmail, string requesterName);

    /// <summary>Queues a /Pos (Purchase Orders) export. Returns the assigned jobId.</summary>
    Guid EnqueuePosExport(PosExportRequest request, string requesterEmail, string requesterName);
}
