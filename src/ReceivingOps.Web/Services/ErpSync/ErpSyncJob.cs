using Dapper;
using Hangfire;
using ReceivingOps.Web.Data;

namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10.1 — Hangfire-scheduled ETL pull from the ERP source DB.
///
/// <para>This is the 10.1 STUB: <see cref="RunAsync"/> only opens a
/// connection via <see cref="IErpDbConnectionFactory"/> and runs
/// <c>SELECT @@VERSION</c> to prove reachability + credentials. The
/// actual BPI_PRS read + transform lands in 10.2; upsert in 10.3.</para>
///
/// <para>Concurrency: <c>[DisableConcurrentExecution]</c> on
/// <see cref="RunAsync"/> means two scheduled fires can't overlap (e.g.
/// if a manual trigger lands while the hourly is still running, the
/// second waits up to <c>TimeoutSeconds</c> then is dropped). The
/// timeout value comes from <see cref="ErpSyncOptions.TimeoutSeconds"/>
/// but Hangfire reads it as a compile-time attribute literal; we hard-
/// code 600s on the attribute to match the option default. If the
/// option diverges, the attribute wins (Hangfire constraint).</para>
///
/// <para>Queue: dedicated <c>erp-sync</c> queue so this work doesn't
/// contend with the <c>exports</c> queue's XLSX writers.</para>
/// </summary>
public class ErpSyncJob
{
    private readonly IErpDbConnectionFactory _factory;
    private readonly ILogger<ErpSyncJob> _log;

    public ErpSyncJob(IErpDbConnectionFactory factory, ILogger<ErpSyncJob> log)
    {
        _factory = factory;
        _log = log;
    }

    [DisableConcurrentExecution(timeoutInSeconds: 600)]
    [Queue("erp-sync")]
    public async Task RunAsync()
    {
        _log.LogInformation("ErpSync stub starting");

        using var conn = _factory.Create();
        var version = await conn.QuerySingleAsync<string>(
            new CommandDefinition("SELECT @@VERSION;"));

        // First non-empty line of @@VERSION is the human-readable banner.
        // Truncate long banners (some ERP boxes return multi-paragraph
        // descriptions) so the log entry stays grep-friendly.
        var banner = (version ?? string.Empty)
            .Split('\n', 2, StringSplitOptions.RemoveEmptyEntries)
            .FirstOrDefault()?.Trim()
            ?? "(empty version banner)";
        if (banner.Length > 160) banner = banner[..160] + "…";

        _log.LogInformation("ErpSync stub OK — ERP DB reachable: {Banner}", banner);
    }
}
