using Hangfire;
using Hangfire.States;
using Hangfire.Storage;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Services.ErpSync;

namespace ReceivingOps.Web.Controllers.Api;

// Phase 10.4 — admin-gated ERP sync trigger + status.
//
//   POST /api/admin/erp-sync/trigger      enqueue a one-shot sync for a
//                                         specific warehouse
//   GET  /api/admin/erp-sync/jobs/{jobId} poll Hangfire job state for the
//                                         enqueued sync (so the UI can
//                                         flip a "syncing..." badge to a
//                                         success/failure toast)
//
// Admin-only by design: an ETL run can touch many pulls across many
// warehouses. Supervisor scope is per-warehouse and doesn't compose
// cleanly with a global ETL. If procurement leads need read-only sync
// visibility, the 10.6 status page can extend the policy.
[ApiController]
[Route("api/admin/erp-sync")]
[Authorize(Roles = "admin")]
public class ErpSyncAdminController : ControllerBase
{
    private readonly IBackgroundJobClient _bgClient;
    private readonly ErpSyncMutex _mutex;
    private readonly ILogger<ErpSyncAdminController> _log;

    public ErpSyncAdminController(
        IBackgroundJobClient bgClient,
        ErpSyncMutex mutex,
        ILogger<ErpSyncAdminController> log)
    {
        _bgClient = bgClient;
        _mutex = mutex;
        _log = log;
    }

    public class TriggerRequest
    {
        public Guid WarehouseId { get; set; }
        // Optional; defaults to 30 when null/<=0 — matches ErpSyncOptions.BackfillDays default.
        public int? BackfillDays { get; set; }
    }

    public class TriggerResponse
    {
        public string JobId { get; set; } = "";
        public Guid WarehouseId { get; set; }
        public int BackfillDays { get; set; }
        public string Message { get; set; } = "";
    }

    public class JobStatusResponse
    {
        public string JobId { get; set; } = "";
        /// <summary>One of: Enqueued, Processing, Succeeded, Failed, Deleted, Awaiting, Scheduled, (unknown).</summary>
        public string State { get; set; } = "";
        public string? Reason { get; set; }
        public DateTime? CreatedAt { get; set; }
    }

    // POST /api/admin/erp-sync/trigger
    [HttpPost("trigger")]
    public IActionResult Trigger([FromBody] TriggerRequest req)
    {
        if (req is null || req.WarehouseId == Guid.Empty)
            return Problem(title: "warehouseId is required.", statusCode: 400);

        // Pre-flight 409: gives instant feedback rather than enqueueing a
        // job that will immediately no-op on the mutex check inside the
        // worker thread. The job's own TryAcquire is still the correctness
        // gate — this check can race but the worst case is a phantom job
        // that logs "skipped" without doing harm.
        if (_mutex.IsRunning)
            return Problem(
                title: "ERP sync is already in progress. Try again in a moment.",
                statusCode: 409);

        var backfillDays = (req.BackfillDays is int b && b > 0) ? b : 30;

        // Capture operator name HERE — Hangfire serializes the lambda's args
        // into the job payload, so by the time the worker thread runs there's
        // no HttpContext to read User from. Falls back to "(unknown)" only if
        // the [Authorize] gate somehow lets through an unidentified caller
        // (shouldn't happen but the audit row stays writable).
        var operatorName = User.FindFirst("displayName")?.Value
                           ?? User.Identity?.Name
                           ?? "(unknown)";

        var jobId = _bgClient.Enqueue<ErpSyncJob>(
            j => j.RunForWarehouseAsync(req.WarehouseId, backfillDays, operatorName));

        _log.LogInformation(
            "ErpSync manual trigger by {User} — jobId={JobId}, warehouse={Wh}, backfillDays={Days}",
            operatorName, jobId, req.WarehouseId, backfillDays);

        return Accepted(new TriggerResponse
        {
            JobId = jobId,
            WarehouseId = req.WarehouseId,
            BackfillDays = backfillDays,
            Message = "Sync enqueued — poll /jobs/{jobId} for state.",
        });
    }

    // GET /api/admin/erp-sync/jobs/{jobId}
    [HttpGet("jobs/{jobId}")]
    public IActionResult GetJobStatus(string jobId)
    {
        if (string.IsNullOrWhiteSpace(jobId))
            return Problem(title: "jobId is required.", statusCode: 400);

        // Hangfire's monitoring API is a static service-locator — fine here
        // since the IBackgroundJobClient that enqueued the job and this query
        // both target the same JobStorage.Current that Program.cs wired.
        IMonitoringApi monitor;
        try
        {
            monitor = JobStorage.Current.GetMonitoringApi();
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to acquire Hangfire monitoring API");
            return Problem(title: "Hangfire monitoring unavailable.", statusCode: 500);
        }

        var details = monitor.JobDetails(jobId);
        if (details is null)
            return NotFound(new { jobId, error = "Job not found in Hangfire storage." });

        // History is ordered newest-first by Hangfire convention. The latest
        // entry's StateName is the current state. CreatedAt comes from the
        // job's enqueue timestamp.
        var latest = details.History?.FirstOrDefault();
        var state = latest?.StateName ?? "(unknown)";

        return Ok(new JobStatusResponse
        {
            JobId = jobId,
            State = state,
            Reason = latest?.Reason,
            CreatedAt = details.CreatedAt,
        });
    }

    // Convenience constants for clients that want to compare against the
    // "terminal" states without hardcoding the Hangfire string literals.
    public static readonly HashSet<string> TerminalStates =
        new(StringComparer.OrdinalIgnoreCase) { SucceededState.StateName, FailedState.StateName, DeletedState.StateName };
}
