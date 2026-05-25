using Hangfire;
using Microsoft.Extensions.Options;

namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10 — Hangfire-scheduled ETL pull from the ERP source DB.
///
/// <para>Two entry points:</para>
/// <list type="bullet">
///   <item><see cref="RunAsync"/>           — recurring fire from the
///         hourly cron. Reads warehouse + backfill from <see cref="ErpSyncOptions"/>.</item>
///   <item><see cref="RunForWarehouseAsync"/> — manual trigger from
///         <see cref="Controllers.Api.ErpSyncAdminController"/>. Caller-
///         provided warehouse + backfill.</item>
/// </list>
///
/// <para>Both paths share <see cref="ExecuteAsync"/> internally and both
/// guard with the singleton <see cref="ErpSyncMutex"/>: the second caller
/// returns early with a log line. Hangfire's [DisableConcurrentExecution]
/// scopes locks per method signature, so it CAN'T prevent recurring vs
/// manual overlap — the singleton mutex is the cross-method lock.</para>
///
/// <para>Queue: dedicated <c>erp-sync</c> queue so this work doesn't
/// contend with the <c>exports</c> queue's XLSX writers.</para>
/// </summary>
public class ErpSyncJob
{
    private readonly IErpSyncService _read;
    private readonly IErpUpsertService _upsert;
    private readonly ErpSyncOptions _opts;
    private readonly ErpSyncMutex _mutex;
    private readonly ILogger<ErpSyncJob> _log;

    public ErpSyncJob(
        IErpSyncService read,
        IErpUpsertService upsert,
        IOptions<ErpSyncOptions> opts,
        ErpSyncMutex mutex,
        ILogger<ErpSyncJob> log)
    {
        _read = read;
        _upsert = upsert;
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
        await ExecuteAsync(_opts.DefaultWarehouseId, _opts.BackfillDays, trigger: "recurring");
    }

    /// <summary>
    /// Manual-trigger entry point — admin or supervisor picks the
    /// warehouse + backfill via the UI / API. Hangfire serializes the
    /// parameters into the job payload so the worker thread sees the
    /// operator's values, not the recurring options.
    /// </summary>
    [DisableConcurrentExecution(timeoutInSeconds: 600)]
    [Queue("erp-sync")]
    public async Task RunForWarehouseAsync(Guid warehouseId, int backfillDays)
    {
        if (warehouseId == Guid.Empty)
        {
            _log.LogWarning("ErpSync manual trigger called with empty warehouseId — aborting.");
            return;
        }
        await ExecuteAsync(warehouseId, backfillDays, trigger: "manual");
    }

    // ------------------------------------------------------------------
    // Shared body. Singleton mutex around read+upsert so the recurring
    // and manual paths can't overlap; release in finally so an exception
    // never leaves the mutex stuck.
    // ------------------------------------------------------------------
    private async Task ExecuteAsync(Guid warehouseId, int backfillDays, string trigger)
    {
        if (!_mutex.TryAcquire())
        {
            _log.LogInformation(
                "ErpSync {Trigger} fire skipped — another sync is already in progress.",
                trigger);
            return;
        }
        try
        {
            _log.LogInformation(
                "ErpSync {Trigger} starting — warehouse={Wh}, backfillDays={Days}",
                trigger, warehouseId, backfillDays);

            var draft = await _read.ReadAndTransformAsync(warehouseId, backfillDays);

            _log.LogInformation(
                "ErpSync transform — source={Src}, skipped={Skip}, " +
                "pulls={Pulls}, items={Items}, totalExpected={Exp}",
                draft.SourceRowCount, draft.SkippedRowCount,
                draft.Pulls.Count, draft.ItemCount, draft.TotalExpected);

            if (draft.Pulls.Count == 0)
            {
                _log.LogInformation("ErpSync transform produced no pulls — skipping upsert.");
                return;
            }

            var outcome = await _upsert.UpsertAsync(draft);
            _log.LogInformation(
                "ErpSync upsert — created={Created}, updated={Updated}, " +
                "skippedClosed={Skipped}, errors={Errors}, " +
                "itemsAdded={Added}, itemsCanceled={Canceled}",
                outcome.Created, outcome.Updated, outcome.SkippedClosed,
                outcome.Errors, outcome.ItemsAdded, outcome.ItemsCanceled);

            // 10.5 will persist outcome.PullOutcomes as per-pull audit rows.
        }
        finally
        {
            _mutex.Release();
        }
    }
}
