using System.Diagnostics;
using Hangfire;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10 — Hangfire-scheduled ETL pull from the ERP source DB.
///
/// <para>Two entry points:</para>
/// <list type="bullet">
///   <item><see cref="RunAsync"/>           — recurring; reads warehouse +
///         backfill from <see cref="ErpSyncOptions"/>; audited as actor <c>[system]</c>.</item>
///   <item><see cref="RunForWarehouseAsync"/> — manual; caller-provided
///         warehouse + backfill + operator name; audited as the operator.</item>
/// </list>
///
/// <para>Both paths share <see cref="ExecuteAsync"/> internally and both
/// guard with the singleton <see cref="ErpSyncMutex"/>: the second caller
/// returns early with a log line. Phase 10.5 wires audit-log writes for
/// every run: start row, per-pull rows (in the upsert tx), end row.</para>
/// </summary>
public class ErpSyncJob
{
    /// <summary>Actor name recorded for ETL runs triggered by the recurring cron.</summary>
    public const string SystemActor = "[system]";

    private readonly IErpSyncService _read;
    private readonly IErpUpsertService _upsert;
    private readonly IAuditService _audit;
    private readonly ErpSyncOptions _opts;
    private readonly ErpSyncMutex _mutex;
    private readonly ILogger<ErpSyncJob> _log;

    public ErpSyncJob(
        IErpSyncService read,
        IErpUpsertService upsert,
        IAuditService audit,
        IOptions<ErpSyncOptions> opts,
        ErpSyncMutex mutex,
        ILogger<ErpSyncJob> log)
    {
        _read = read;
        _upsert = upsert;
        _audit = audit;
        _opts = opts.Value;
        _mutex = mutex;
        _log = log;
    }

    /// <summary>
    /// Recurring entry point — Hangfire calls this on the configured
    /// cron. Reads warehouse + backfill from <see cref="ErpSyncOptions"/>;
    /// skips silently if DefaultWarehouseId is unset.
    /// </summary>
    [DisableConcurrentExecution(timeoutInSeconds: 600)]
    [Queue("erp-sync")]
    public async Task RunAsync()
    {
        if (_opts.DefaultWarehouseId == Guid.Empty)
        {
            _log.LogInformation(
                "ErpSync recurring fired but ErpSync:DefaultWarehouseId is unset — skipping. " +
                "Set it in user-secrets or use the manual-trigger UI to pick a warehouse.");
            return;
        }
        await ExecuteAsync(_opts.DefaultWarehouseId, _opts.BackfillDays,
            trigger: "recurring", actorName: SystemActor);
    }

    /// <summary>
    /// Manual-trigger entry point — admin picks the warehouse + backfill
    /// via the UI / API. Hangfire serializes the parameters into the job
    /// payload so the worker thread sees the operator's values, not the
    /// recurring options.
    /// </summary>
    [DisableConcurrentExecution(timeoutInSeconds: 600)]
    [Queue("erp-sync")]
    public async Task RunForWarehouseAsync(Guid warehouseId, int backfillDays, string actorName)
    {
        if (warehouseId == Guid.Empty)
        {
            _log.LogWarning("ErpSync manual trigger called with empty warehouseId — aborting.");
            return;
        }
        var safeActor = string.IsNullOrWhiteSpace(actorName) ? "(unknown)" : actorName;
        await ExecuteAsync(warehouseId, backfillDays, trigger: "manual", actorName: safeActor);
    }

    // ------------------------------------------------------------------
    // Shared body — mutex-guarded, audit-bracketed.
    //
    //   - One 'etl-start' audit row before read+transform begins.
    //   - Per-pull rows are written by ErpUpsertService.UpsertAsync.
    //   - One 'etl-complete' audit row when the run finishes successfully.
    //   - One 'etl-error' audit row + rethrow when the run fails — Hangfire
    //     marks the job Failed so the status endpoint surfaces it.
    //
    // runId is generated at the start of each invocation and stamped into
    // every audit row's Message so the 10.6 status page can group all rows
    // for one run.
    // ------------------------------------------------------------------
    private async Task ExecuteAsync(Guid warehouseId, int backfillDays, string trigger, string actorName)
    {
        if (!_mutex.TryAcquire())
        {
            _log.LogInformation(
                "ErpSync {Trigger} fire skipped — another sync is already in progress.",
                trigger);
            return;
        }

        var runId = Guid.NewGuid();
        var sw = Stopwatch.StartNew();
        await _audit.WriteSystemAsync(actorName, "etl-start", "ErpSync",
            runId.ToString(),
            $"[run {runId}] Triggered by {trigger} — warehouse={warehouseId}, backfillDays={backfillDays}");

        try
        {
            _log.LogInformation(
                "ErpSync {Trigger} starting — runId={RunId}, warehouse={Wh}, backfillDays={Days}",
                trigger, runId, warehouseId, backfillDays);

            var draft = await _read.ReadAndTransformAsync(warehouseId, backfillDays);

            _log.LogInformation(
                "ErpSync transform — runId={RunId}, source={Src}, skipped={Skip}, " +
                "pulls={Pulls}, items={Items}, totalExpected={Exp}",
                runId, draft.SourceRowCount, draft.SkippedRowCount,
                draft.Pulls.Count, draft.ItemCount, draft.TotalExpected);

            ErpUpsertResult outcome;
            if (draft.Pulls.Count == 0)
            {
                _log.LogInformation("ErpSync transform produced no pulls — skipping upsert.");
                outcome = new ErpUpsertResult();
            }
            else
            {
                outcome = await _upsert.UpsertAsync(draft, runId, actorName);
                _log.LogInformation(
                    "ErpSync upsert — runId={RunId}, created={Created}, updated={Updated}, " +
                    "skippedClosed={Skipped}, errors={Errors}, " +
                    "itemsAdded={Added}, itemsCanceled={Canceled}",
                    runId, outcome.Created, outcome.Updated, outcome.SkippedClosed,
                    outcome.Errors, outcome.ItemsAdded, outcome.ItemsCanceled);
            }

            sw.Stop();
            await _audit.WriteSystemAsync(actorName, "etl-end", "ErpSync",
                runId.ToString(),
                $"[run {runId}] Completed in {sw.ElapsedMilliseconds}ms — " +
                $"sourceRows={draft.SourceRowCount}, transformed={draft.Pulls.Count}, " +
                $"created={outcome.Created}, updated={outcome.Updated}, " +
                $"skippedClosed={outcome.SkippedClosed}, errors={outcome.Errors}, " +
                $"itemsAdded={outcome.ItemsAdded}, itemsCanceled={outcome.ItemsCanceled}");
        }
        catch (Exception ex)
        {
            sw.Stop();
            // Audit the run-level failure standalone — the per-pull catchall
            // inside UpsertAsync handles per-row failures, but this catches
            // catastrophic errors (read failure, DB unreachable, etc.).
            await _audit.WriteSystemAsync(actorName, "etl-error", "ErpSync",
                runId.ToString(),
                $"[run {runId}] Run failed after {sw.ElapsedMilliseconds}ms — " +
                $"{ex.GetType().Name}: {ex.Message}");
            _log.LogError(ex, "ErpSync run {RunId} failed", runId);
            throw;  // Hangfire marks Failed; status endpoint surfaces it.
        }
        finally
        {
            _mutex.Release();
        }
    }
}
