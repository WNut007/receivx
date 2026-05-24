using Hangfire;

namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 — Hangfire-backed export queueing. The actual work happens
/// in <see cref="TransactionsExportJob.RunAsync"/>; this class just hands
/// the request to Hangfire (which serializes it + invokes the job on a
/// worker thread).
///
/// The jobId we generate up front + pass into the job lets the file path
/// + download URL be known *before* the job runs — handy for retry
/// idempotency (deterministic file location) and for surfacing the jobId
/// back to the caller's API response.
/// </summary>
public class ExportService : IExportService
{
    private readonly IBackgroundJobClient _jobs;

    public ExportService(IBackgroundJobClient jobs)
    {
        _jobs = jobs;
    }

    public Guid EnqueueTransactionsExport(TransactionsExportRequest request, string requesterEmail, string requesterName)
    {
        var jobId = Guid.NewGuid();
        _jobs.Enqueue<TransactionsExportJob>(job => job.RunAsync(jobId, request, requesterEmail, requesterName));
        return jobId;
    }

    public Guid EnqueuePosExport(PosExportRequest request, string requesterEmail, string requesterName)
    {
        var jobId = Guid.NewGuid();
        _jobs.Enqueue<PosExportJob>(job => job.RunAsync(jobId, request, requesterEmail, requesterName));
        return jobId;
    }

    public Guid EnqueueAuditLogExport(AuditLogExportRequest request, string requesterEmail, string requesterName)
    {
        var jobId = Guid.NewGuid();
        _jobs.Enqueue<AuditLogExportJob>(job => job.RunAsync(jobId, request, requesterEmail, requesterName));
        return jobId;
    }
}
