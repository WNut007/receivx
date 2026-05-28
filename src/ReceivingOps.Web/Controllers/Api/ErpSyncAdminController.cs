using Hangfire;
using Hangfire.States;
using Hangfire.Storage;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services.ErpSync;
// Phase 13.8.1 — controller takes IEnumerable<IErpSource> to validate
// req.SourceName at pre-flight time (same source-of-truth as the job).

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
    private readonly IErpSyncLogRepository _logRepo;
    private readonly IEnumerable<IErpSource> _sources;
    private readonly ILogger<ErpSyncAdminController> _log;

    public ErpSyncAdminController(
        IBackgroundJobClient bgClient,
        ErpSyncMutex mutex,
        IErpSyncLogRepository logRepo,
        IEnumerable<IErpSource> sources,
        ILogger<ErpSyncAdminController> log)
    {
        _bgClient = bgClient;
        _mutex = mutex;
        _logRepo = logRepo;
        _sources = sources;
        _log = log;
    }

    public class TriggerRequest
    {
        // Phase 13.8.1 — when null or empty, the job runs every enabled source
        // (legacy single-payload behavior preserved). When set, the controller
        // verifies the source exists + is enabled and threads it through to
        // the fan-out loop, which restricts the run to that source alone.
        public string? SourceName { get; set; }

        // Phase 13.9.1 — WarehouseId + BackfillDays REMOVED. Manual trigger
        // now reuses per-source config (ErpSync:Sources:<X>:DefaultWarehouseId
        // and :BackfillDays), the same values the recurring path uses.
        // Operators changing those values use /Config + restart.
        //
        // Stale clients that still send the old fields are tolerated
        // (System.Text.Json ignores unknown body fields by default).
    }

    public class TriggerResponse
    {
        public string JobId { get; set; } = "";
        // Phase 13.8.1 — echoes the resolved source name for the run.
        // Empty string when no source filter was requested ("all enabled").
        public string SourceName { get; set; } = "";
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
    public IActionResult Trigger([FromBody] TriggerRequest? req)
    {
        // Phase 13.9.1 — req is optional; a fully empty body means "run all
        // enabled sources with their configured warehouse + backfill".
        var sourceName = req?.SourceName;

        // Phase 13.8.1 — source-name validation. Empty/null = all enabled
        // (legacy behavior). Otherwise the source must exist + be enabled
        // RIGHT NOW. IOptions<ErpSyncOptions> backs IErpSource.Enabled, so
        // this view of "enabled" matches what the worker will see when it
        // dequeues. (Restart-required: a /Config edit between trigger and
        // worker pickup that the IOptions cache hasn't refreshed is the
        // documented Phase 11.1 invariant.)
        string? resolvedSource = null;
        if (!string.IsNullOrWhiteSpace(sourceName))
        {
            var match = _sources.FirstOrDefault(s =>
                s.SourceName.Equals(sourceName, StringComparison.OrdinalIgnoreCase));
            if (match is null)
            {
                var known = string.Join(", ", _sources.Select(s => s.SourceName));
                return Problem(
                    title: $"Unknown source '{sourceName}'. Known: {known}",
                    statusCode: 400);
            }
            if (!match.Enabled)
            {
                return Problem(
                    title: $"Source '{match.SourceName}' is not enabled. " +
                           "Enable it via /Config (Sync Schedule tab) and restart, then retry.",
                    statusCode: 400);
            }
            resolvedSource = match.SourceName;  // canonical casing
        }

        // Pre-flight 409: gives instant feedback rather than enqueueing a
        // job that will immediately no-op on the mutex check inside the
        // worker thread. The job's own TryAcquire is still the correctness
        // gate — this check can race but the worst case is a phantom job
        // that logs "skipped" without doing harm.
        if (_mutex.IsRunning)
            return Problem(
                title: "ERP sync is already in progress. Try again in a moment.",
                statusCode: 409);

        // Capture operator name HERE — Hangfire serializes the lambda's args
        // into the job payload, so by the time the worker thread runs there's
        // no HttpContext to read User from. Falls back to "(unknown)" only if
        // the [Authorize] gate somehow lets through an unidentified caller
        // (shouldn't happen but the audit row stays writable).
        var operatorName = User.FindFirst("displayName")?.Value
                           ?? User.Identity?.Name
                           ?? "(unknown)";

        // Phase 13.9.1 — switched from RunForWarehouseAsync (operator-picked
        // WH + backfill) to RunNowAsync (per-source config). The latter is
        // the "run the scheduled logic now" semantic the user wants.
        var jobId = _bgClient.Enqueue<ErpSyncJob>(
            j => j.RunNowAsync(operatorName, resolvedSource));

        _log.LogInformation(
            "ErpSync manual trigger by {User} — jobId={JobId}, source={Src} (per-source config)",
            operatorName, jobId, resolvedSource ?? "(all enabled)");

        return Accepted(new TriggerResponse
        {
            JobId = jobId,
            SourceName = resolvedSource ?? "",
            Message = "Sync enqueued — each enabled source uses its configured " +
                      "DefaultWarehouseId + BackfillDays. Poll /jobs/{jobId} for state.",
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

    // ------------------------------------------------------------------
    // Phase 10.6 — sync history (denormalized run-level summaries).
    // The audit-log-level per-pull detail is a future drill-down endpoint;
    // for now the status page lists runs only.
    // ------------------------------------------------------------------

    /// <summary>GET /api/admin/erp-sync/log?page=1&amp;pageSize=50 — paginated history.</summary>
    [HttpGet("log")]
    public async Task<ActionResult<PaginatedResponse<ErpSyncLogRow>>> ListLog(
        [FromQuery] PaginatedRequest req, CancellationToken ct)
    {
        var (items, total) = await _logRepo.QueryPagedAsync(req.Skip, req.Take, ct);
        return Ok(new PaginatedResponse<ErpSyncLogRow>
        {
            Items = items,
            Page = req.Page,
            PageSize = req.Take,
            Total = total,
        });
    }

    /// <summary>GET /api/admin/erp-sync/log/{runId} — single-row drill-down.</summary>
    [HttpGet("log/{runId:guid}")]
    public async Task<ActionResult<ErpSyncLogRow>> GetLogRow(Guid runId, CancellationToken ct)
    {
        var row = await _logRepo.GetByRunIdAsync(runId, ct);
        return row is null ? NotFound() : Ok(row);
    }

    /// <summary>
    /// GET /api/admin/erp-sync/state — lightweight UI helper: is a sync
    /// currently running? Used by the status page's "Sync now" button
    /// to disable itself while in-flight (separate from the per-job
    /// poll which only sees a single run).
    /// </summary>
    [HttpGet("state")]
    public IActionResult GetState()
        => Ok(new { isRunning = _mutex.IsRunning });
}
