using Hangfire;
using Microsoft.Extensions.Options;

namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10 — Hangfire-scheduled ETL pull from the ERP source DB.
///
/// <para>10.1 stubbed this as <c>SELECT @@VERSION</c>; 10.2 replaces the
/// body with a real read+transform via <see cref="IErpSyncService"/>.
/// Persistence (the upsert into Pulls / PullItems / PullItemWindows)
/// lands in 10.3.</para>
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
    private readonly IErpSyncService _service;
    private readonly ErpSyncOptions _opts;
    private readonly ILogger<ErpSyncJob> _log;

    public ErpSyncJob(
        IErpSyncService service,
        IOptions<ErpSyncOptions> opts,
        ILogger<ErpSyncJob> log)
    {
        _service = service;
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

        var draft = await _service.ReadAndTransformAsync(
            _opts.DefaultWarehouseId, _opts.BackfillDays);

        _log.LogInformation(
            "ErpSync recurring transform complete — source={Src}, skipped={Skip}, " +
            "pulls={Pulls}, items={Items}, totalExpected={Exp}",
            draft.SourceRowCount, draft.SkippedRowCount,
            draft.Pulls.Count, draft.ItemCount, draft.TotalExpected);

        // 10.3 will pass this draft to an IErpUpsertService here.
    }
}
