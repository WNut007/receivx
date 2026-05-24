using System.Text.Json;
using Hangfire;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4/8.5 — Hangfire-backed export queueing. The actual work
/// happens in the matching *ExportJob.RunAsync; this class hands the
/// request to Hangfire AND persists a Status='queued' row in
/// dbo.ExportJobsLog so the My Exports page can show it before the
/// worker picks it up.
///
/// The jobId is generated up front and reused as:
///   - the export file basename ({prefix}-{jobId}.xlsx)
///   - the signed download URL path segment
///   - the ExportJobsLog PK
///
/// Filter snapshot stored as JSON for the log row — operators looking at
/// "Pos export from 3 days ago" can see what they were filtering for.
/// </summary>
public class ExportService : IExportService
{
    private readonly IBackgroundJobClient _jobs;
    private readonly IExportJobLogRepository _log;

    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web);

    public ExportService(IBackgroundJobClient jobs, IExportJobLogRepository log)
    {
        _jobs = jobs;
        _log = log;
    }

    public async Task<Guid> EnqueueTransactionsExportAsync(
        TransactionsExportRequest request, Guid requesterUserId,
        string requesterEmail, string requesterName, CancellationToken ct = default)
    {
        var jobId = Guid.NewGuid();
        await InsertQueuedAsync(jobId, "transactions", request, requesterUserId, requesterEmail, requesterName, ct);
        _jobs.Enqueue<TransactionsExportJob>(job => job.RunAsync(jobId, request, requesterEmail, requesterName));
        return jobId;
    }

    public async Task<Guid> EnqueuePosExportAsync(
        PosExportRequest request, Guid requesterUserId,
        string requesterEmail, string requesterName, CancellationToken ct = default)
    {
        var jobId = Guid.NewGuid();
        await InsertQueuedAsync(jobId, "pos", request, requesterUserId, requesterEmail, requesterName, ct);
        _jobs.Enqueue<PosExportJob>(job => job.RunAsync(jobId, request, requesterEmail, requesterName));
        return jobId;
    }

    public async Task<Guid> EnqueueAuditLogExportAsync(
        AuditLogExportRequest request, Guid requesterUserId,
        string requesterEmail, string requesterName, CancellationToken ct = default)
    {
        var jobId = Guid.NewGuid();
        await InsertQueuedAsync(jobId, "audit-log", request, requesterUserId, requesterEmail, requesterName, ct);
        _jobs.Enqueue<AuditLogExportJob>(job => job.RunAsync(jobId, request, requesterEmail, requesterName));
        return jobId;
    }

    private Task InsertQueuedAsync<TRequest>(
        Guid jobId, string jobType, TRequest request,
        Guid requesterUserId, string requesterEmail, string requesterName,
        CancellationToken ct)
    {
        return _log.InsertQueuedAsync(new ExportJobLogRow
        {
            Id = jobId,
            RequesterUserId = requesterUserId,
            RequesterEmail = requesterEmail,
            RequesterName = requesterName,
            JobType = jobType,
            FilterJson = JsonSerializer.Serialize(request, JsonOpts),
            Status = "queued",
        }, ct);
    }
}
