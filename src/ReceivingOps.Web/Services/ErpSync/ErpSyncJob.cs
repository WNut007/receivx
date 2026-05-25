using Hangfire;
using Microsoft.Extensions.Options;

namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10 — Hangfire-scheduled ETL pull from the ERP source DB.
///
/// <para>Read → transform (10.2) → upsert (10.3). End-to-end flow in
/// one method so the [DisableConcurrentExecution] mutex covers everything
/// from the ERP SELECT through the last Pulls table commit.</para>
///
/// <para>WarehouseId resolution: BPI_PRS has no warehouse column. The
/// recurring path uses <see cref="ErpSyncOptions.DefaultWarehouseId"/>;
/// when unset the job logs a clear "no default" message and exits without
/// touching the ERP DB. Manual triggers (10.4) will enqueue a different
/// fire-and-forget job with the operator's picked warehouse.</para>
///
/// <para>Concurrency: <c>[DisableConcurrentExecution]</c> on
/// <see cref="RunAsync"/> means two scheduled fires can't overlap. Timeout
/// is a compile-time attribute literal — keep in sync with
/// <see cref="ErpSyncOptions.TimeoutSeconds"/> manually.</para>
///
/// <para>Queue: dedicated <c>erp-sync</c> queue so this work doesn't
/// contend with the <c>exports</c> queue's XLSX writers.</para>
/// </summary>
public class ErpSyncJob
{
    private readonly IErpSyncService _read;
    private readonly IErpUpsertService _upsert;
    private readonly ErpSyncOptions _opts;
    private readonly ILogger<ErpSyncJob> _log;

    public ErpSyncJob(
        IErpSyncService read,
        IErpUpsertService upsert,
        IOptions<ErpSyncOptions> opts,
        ILogger<ErpSyncJob> log)
    {
        _read = read;
        _upsert = upsert;
        _opts = opts.Value;
        _log = log;
    }

    [DisableConcurrentExecution(timeoutInSeconds: 600)]
    [Queue("erp-sync")]
    public async Task RunAsync()
    {
        if (_opts.DefaultWarehouseId == Guid.Empty)
        {
            _log.LogInformation(
                "ErpSync recurring fired but ErpSync:DefaultWarehouseId is unset — skipping. " +
                "Set it in user-secrets or use the manual-trigger UI (10.4) to pick a warehouse.");
            return;
        }

        _log.LogInformation(
            "ErpSync recurring starting — warehouse={Wh}, backfillDays={Days}",
            _opts.DefaultWarehouseId, _opts.BackfillDays);

        var draft = await _read.ReadAndTransformAsync(
            _opts.DefaultWarehouseId, _opts.BackfillDays);

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

        // 10.5 will persist `outcome.PullOutcomes` as per-pull audit rows.
    }
}
