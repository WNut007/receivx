using System.Diagnostics;
using System.Text.Json;
using Hangfire;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 13.5 — Hangfire-scheduled ETL pull from the ERP source DB(s).
///
/// <para>Fan-out: one fire iterates every <see cref="IErpSource"/> whose
/// <see cref="IErpSource.Enabled"/> returns true, serially under one
/// mutex acquisition + one <c>RunId</c>. Per-source counters land in
/// <c>dbo.ErpSyncLog.SourceTotals</c> as JSON; the aggregate scalar
/// columns (Created/Updated/SkippedClosed/...) hold the cross-source
/// sum so the v3.2 status page query stays unchanged.</para>
///
/// <para>Two entry points: <see cref="RunAsync"/> (recurring; per-source
/// defaults for WH + backfill) and <see cref="RunForWarehouseAsync"/>
/// (manual; operator-picked WH + backfill applied to every enabled
/// source — see operator UX recommendation in the Phase 13 design plan).</para>
/// </summary>
public class ErpSyncJob
{
    /// <summary>Actor name recorded for ETL runs triggered by the recurring cron.</summary>
    public const string SystemActor = "[system]";

    private readonly IEnumerable<IErpSource> _sources;
    private readonly IErpUpsertService _upsert;
    private readonly IAuditService _audit;
    private readonly IErpSyncLogRepository _logRepo;
    private readonly ErpSyncOptions _opts;
    private readonly ErpSyncMutex _mutex;
    private readonly ILogger<ErpSyncJob> _log;

    public ErpSyncJob(
        IEnumerable<IErpSource> sources,
        IErpUpsertService upsert,
        IAuditService audit,
        IErpSyncLogRepository logRepo,
        IOptions<ErpSyncOptions> opts,
        ErpSyncMutex mutex,
        ILogger<ErpSyncJob> log)
    {
        _sources = sources;
        _upsert = upsert;
        _audit = audit;
        _logRepo = logRepo;
        _opts = opts.Value;
        _mutex = mutex;
        _log = log;
    }

    /// <summary>
    /// Recurring entry point — Hangfire calls this on the configured
    /// cron. Each enabled source uses its OWN
    /// <c>ErpSync:Sources:X:DefaultWarehouseId</c> +
    /// <c>:BackfillDays</c>. Empty WH on every enabled source aborts
    /// the run.
    /// </summary>
    [DisableConcurrentExecution(timeoutInSeconds: 600)]
    [Queue("erp-sync")]
    public async Task RunAsync()
    {
        await ExecuteAsync(
            overrideWarehouse: null, overrideBackfillDays: null,
            trigger: "recurring", actorName: SystemActor);
    }

    /// <summary>
    /// Legacy manual-trigger entry point (Phase 10.4 / 13.8.1). Operator
    /// picks an explicit warehouse + backfill window that applies to every
    /// enabled source. Superseded by <see cref="RunNowAsync"/> in Phase
    /// 13.9.1 — the controller now enqueues that path instead.
    ///
    /// <para>Kept callable so any in-flight Hangfire job from a prior
    /// deploy can still resolve. New callers should use <see cref="RunNowAsync"/>.</para>
    /// </summary>
    [DisableConcurrentExecution(timeoutInSeconds: 600)]
    [Queue("erp-sync")]
    public async Task RunForWarehouseAsync(
        Guid warehouseId, int backfillDays, string actorName, string? sourceName = null)
    {
        if (warehouseId == Guid.Empty)
        {
            _log.LogWarning("ErpSync manual trigger called with empty warehouseId — aborting.");
            return;
        }
        var safeActor = string.IsNullOrWhiteSpace(actorName) ? "(unknown)" : actorName;
        await ExecuteAsync(
            overrideWarehouse: warehouseId, overrideBackfillDays: backfillDays,
            trigger: "manual", actorName: safeActor, sourceFilter: sourceName);
    }

    /// <summary>
    /// Phase 13.9.1 — current manual-trigger entry point. "Run scheduled
    /// logic now": each enabled source uses its OWN configured
    /// <c>DefaultWarehouseId</c> + <c>BackfillDays</c> (same as the
    /// recurring path), just attributed to the operator + tagged
    /// <c>trigger=manual</c> in audit/log rows. Optional
    /// <paramref name="sourceName"/> filter restricts the run to one
    /// source (Phase 13.8.1 contract preserved).
    ///
    /// <para>Sources whose <c>DefaultWarehouseId</c> is unset are skipped
    /// per-source with a warning log (not a hard failure) — so a missing
    /// PRB config doesn't block a BPI-only fire on the same run.</para>
    /// </summary>
    [DisableConcurrentExecution(timeoutInSeconds: 600)]
    [Queue("erp-sync")]
    public async Task RunNowAsync(string actorName, string? sourceName = null)
    {
        var safeActor = string.IsNullOrWhiteSpace(actorName) ? "(unknown)" : actorName;
        await ExecuteAsync(
            overrideWarehouse: null, overrideBackfillDays: null,
            trigger: "manual", actorName: safeActor, sourceFilter: sourceName);
    }

    // ------------------------------------------------------------------
    // Shared body — mutex-guarded, audit-bracketed, per-source loop.
    //
    //   - One 'etl-start' audit row at the run level.
    //   - For each enabled source: ReadAndTransform + UpsertAsync
    //     (which writes per-pull etl-create/update/skip rows tagged
    //     [source X]).
    //   - SourceTotals JSON is written to dbo.ErpSyncLog so the status
    //     page drill-down can render the per-source split.
    //   - One 'etl-end' audit row at the run level.
    //   - One 'etl-error' audit row + rethrow if anything goes wrong.
    //
    // When overrides are non-null, every enabled source uses the
    // override values (manual path). When null, each source uses its
    // own per-source defaults (recurring path).
    //
    // dbo.ErpSyncLog has a single WarehouseId column. We store the
    // FIRST enabled source's effective warehouse — keeps the v3.2
    // schema invariants while the per-source breakdown lives in
    // SourceTotals JSON.
    // ------------------------------------------------------------------
    private async Task ExecuteAsync(
        Guid? overrideWarehouse, int? overrideBackfillDays,
        string trigger, string actorName, string? sourceFilter = null)
    {
        if (!_mutex.TryAcquire())
        {
            _log.LogInformation(
                "ErpSync {Trigger} fire skipped — another sync is already in progress.",
                trigger);
            return;
        }

        // Phase 13.8.1 — when a sourceFilter is provided, narrow to that
        // source BEFORE the empty-set check so the failure mode is loud
        // (throw inside the try-block, marks Hangfire job Failed) rather
        // than silent ("no enabled sources" log + return). Controller
        // pre-flight already validated the source name; this is the
        // worker-side backstop for a race where the source got disabled
        // between trigger and pickup.
        IEnumerable<IErpSource> sourceQuery = _sources.Where(s => s.Enabled);
        if (!string.IsNullOrWhiteSpace(sourceFilter))
        {
            sourceQuery = sourceQuery.Where(s =>
                s.SourceName.Equals(sourceFilter, StringComparison.OrdinalIgnoreCase));
        }
        var enabledSources = sourceQuery.ToList();
        if (enabledSources.Count == 0)
        {
            if (!string.IsNullOrWhiteSpace(sourceFilter))
            {
                // Explicit-source request that produced zero runnables.
                // Throw so Hangfire records Failed + the audit-error path runs.
                _mutex.Release();
                throw new InvalidOperationException(
                    $"Source '{sourceFilter}' is not enabled (or was disabled between " +
                    "trigger and worker pickup). Re-check ErpSync:Sources:* in /Config.");
            }
            _log.LogInformation(
                "ErpSync {Trigger} fired but no sources are enabled — skipping.", trigger);
            _mutex.Release();
            return;
        }

        // Build the per-source plan (warehouse + backfill) up front so the
        // log row can be written with a representative WH before any source
        // runs. Also lets us bail early if every enabled source has an
        // unset DefaultWarehouseId on the recurring path.
        var plans = enabledSources.Select(s =>
        {
            var wh = overrideWarehouse ?? PerSourceWarehouse(s);
            var bd = overrideBackfillDays ?? PerSourceBackfillDays(s);
            return new SourcePlan(s, wh, bd);
        }).ToList();

        // Phase 13.9.1 — surface per-source skip-due-to-empty-WH as a
        // warning before partitioning to `runnable`. Previously silent;
        // operators reasonably want to know "PRB was disabled-by-config
        // because its warehouse was Guid.Empty" without grepping logs.
        foreach (var skipped in plans.Where(p => p.WarehouseId == Guid.Empty))
        {
            _log.LogWarning(
                "ErpSync {Trigger} — source {Src} has no DefaultWarehouseId configured; skipping. " +
                "Set ErpSync:Sources:{SrcKey}:DefaultWarehouseId via /Config and restart.",
                trigger, skipped.Source.SourceName, ConfigKeyForSource(skipped.Source.SourceName));
        }

        var runnable = plans.Where(p => p.WarehouseId != Guid.Empty).ToList();
        if (runnable.Count == 0)
        {
            _mutex.Release();
            // Phase 13.9.1 — explicit-source request that ended up empty
            // (the requested source had no WH) is a LOUD failure: the
            // operator deliberately asked for that source, so silence
            // would be confusing. Recurring/all-enabled path stays a
            // quiet skip — that's the documented background-run behavior.
            if (!string.IsNullOrWhiteSpace(sourceFilter))
            {
                throw new InvalidOperationException(
                    $"Source '{sourceFilter}' has no DefaultWarehouseId configured. " +
                    "Set it via /Config (Sync Schedule tab) and restart, then retry.");
            }
            _log.LogInformation(
                "ErpSync {Trigger} fire skipped — every enabled source has an unset DefaultWarehouseId. " +
                "Configure ErpSync:Sources:<X>:DefaultWarehouseId via /Config or use the manual trigger.",
                trigger);
            return;
        }

        var runId = Guid.NewGuid();
        var sw = Stopwatch.StartNew();
        // Representative WH for the log header: first runnable source's WH.
        var headerWh = runnable[0].WarehouseId;
        var headerBd = runnable[0].BackfillDays;

        await _logRepo.InsertStartAsync(runId, trigger, actorName, headerWh, headerBd);

        await _audit.WriteSystemAsync(actorName, "etl-start", "ErpSync",
            runId.ToString(),
            $"[run {runId}] Triggered by {trigger} — sources=[{string.Join(",", runnable.Select(p => p.Source.SourceName))}]");

        try
        {
            var totals = new ErpSyncLogTotals();
            var sourceTotals = new Dictionary<string, PerSourceTotals>(StringComparer.Ordinal);

            foreach (var plan in runnable)
            {
                _log.LogInformation(
                    "ErpSync {Trigger} — source={Src}, warehouse={Wh}, backfillDays={Days}, runId={RunId}",
                    trigger, plan.Source.SourceName, plan.WarehouseId, plan.BackfillDays, runId);

                var draft = await plan.Source.ReadAndTransformAsync(plan.WarehouseId, plan.BackfillDays);

                totals.SourceRowCount += draft.SourceRowCount;
                totals.DraftPullCount += draft.Pulls.Count;

                ErpUpsertResult outcome;
                if (draft.Pulls.Count == 0)
                {
                    _log.LogInformation(
                        "ErpSync transform produced no pulls for {Src} — skipping upsert.",
                        plan.Source.SourceName);
                    outcome = new ErpUpsertResult();
                }
                else
                {
                    outcome = await _upsert.UpsertAsync(draft, runId, actorName, plan.Source.SourceName);
                }

                totals.Created       += outcome.Created;
                totals.Updated       += outcome.Updated;
                totals.SkippedClosed += outcome.SkippedClosed;
                totals.Errors        += outcome.Errors;
                totals.ItemsAdded    += outcome.ItemsAdded;
                totals.ItemsCanceled += outcome.ItemsCanceled;

                sourceTotals[plan.Source.SourceName] = new PerSourceTotals
                {
                    SourceRowCount = draft.SourceRowCount,
                    DraftPullCount = draft.Pulls.Count,
                    Created        = outcome.Created,
                    Updated        = outcome.Updated,
                    SkippedClosed  = outcome.SkippedClosed,
                    Errors         = outcome.Errors,
                    ItemsAdded     = outcome.ItemsAdded,
                    ItemsCanceled  = outcome.ItemsCanceled,
                };
            }

            sw.Stop();
            await _logRepo.MarkSucceededAsync(runId, totals, (int)sw.ElapsedMilliseconds);
            // SourceTotals written separately — keeps MarkSucceededAsync's
            // SQL shape unchanged for v3.2 callers (smokes that read the
            // log row by other means).
            await _logRepo.UpdateSourceTotalsAsync(runId,
                JsonSerializer.Serialize(sourceTotals));

            var perSourceSummary = string.Join(", ",
                sourceTotals.Select(kv =>
                    $"{kv.Key}=(c={kv.Value.Created},u={kv.Value.Updated},s={kv.Value.SkippedClosed},e={kv.Value.Errors})"));
            await _audit.WriteSystemAsync(actorName, "etl-end", "ErpSync",
                runId.ToString(),
                $"[run {runId}] Completed in {sw.ElapsedMilliseconds}ms — " +
                $"sources=[{string.Join(",", sourceTotals.Keys)}] — {perSourceSummary}");
        }
        catch (Exception ex)
        {
            sw.Stop();
            // Mark the summary row failed first so the status page reflects
            // the catastrophic outcome even if the audit write below also
            // fails for some reason (rare, but the swallow-on-failure audit
            // semantic means we shouldn't depend on it landing).
            await _logRepo.MarkFailedAsync(runId,
                $"{ex.GetType().Name}: {ex.Message}",
                (int)sw.ElapsedMilliseconds);
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

    // Per-source defaults — recurring path. Adding a new source means
    // adding a switch arm here AND a Sources sub-property on ErpSyncOptions.
    private Guid PerSourceWarehouse(IErpSource s) => s.SourceName switch
    {
        "BPI_PRS" => _opts.Sources.Bpi.DefaultWarehouseId,
        "PRB_PRS" => _opts.Sources.Prb.DefaultWarehouseId,
        _ => Guid.Empty,
    };

    private int PerSourceBackfillDays(IErpSource s) => s.SourceName switch
    {
        "BPI_PRS" => _opts.Sources.Bpi.BackfillDays,
        "PRB_PRS" => _opts.Sources.Prb.BackfillDays,
        _ => 30,
    };

    // Phase 13.9.1 — sub-key for the per-source warning log so operators can
    // copy the exact key to /Config without consulting docs.
    private static string ConfigKeyForSource(string sourceName) => sourceName switch
    {
        "BPI_PRS" => "Bpi",
        "PRB_PRS" => "Prb",
        _ => sourceName,
    };

    private sealed record SourcePlan(IErpSource Source, Guid WarehouseId, int BackfillDays);

    // JSON shape stored in dbo.ErpSyncLog.SourceTotals. Property names are
    // camelCased by JsonSerializer defaults below — match the casing
    // contract the /api/admin/erp-sync responses use elsewhere.
    private sealed class PerSourceTotals
    {
        public int SourceRowCount { get; set; }
        public int DraftPullCount { get; set; }
        public int Created { get; set; }
        public int Updated { get; set; }
        public int SkippedClosed { get; set; }
        public int Errors { get; set; }
        public int ItemsAdded { get; set; }
        public int ItemsCanceled { get; set; }
    }
}
