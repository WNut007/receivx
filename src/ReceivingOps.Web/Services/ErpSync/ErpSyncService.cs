namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 13.2 — thin facade kept for v3.2-era callers (notably
/// <see cref="ErpSyncJob"/> before the 13.5 fan-out refactor lands).
/// Delegates to <see cref="BpiPrsSource"/>; will be retired in Phase 13.5
/// when the job depends on <c>IEnumerable&lt;IErpSource&gt;</c> directly.
///
/// <para>The body that used to live here (SQL + Transform + BpiPrsRow)
/// moved to <see cref="BpiPrsSource"/> verbatim — pure refactor.</para>
/// </summary>
public class ErpSyncService : IErpSyncService
{
    private readonly BpiPrsSource _bpi;

    public ErpSyncService(BpiPrsSource bpi) => _bpi = bpi;

    public Task<ErpSyncDraft> ReadAndTransformAsync(
        Guid warehouseId, int backfillDays, CancellationToken ct = default)
        => _bpi.ReadAndTransformAsync(warehouseId, backfillDays, ct);
}
