namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 13.2 — strategy abstraction over a single ERP source table.
///
/// <para>v3.2 had one reader (BPI_PRS) hardwired inside <c>ErpSyncService</c>.
/// Phase 13 introduces a second source (PRB_PRS) on the same host; the job
/// iterates every <see cref="IErpSource"/> instance whose <see cref="Enabled"/>
/// returns true and concatenates results.</para>
///
/// <para>Implementations are pure read+transform — they MUST NOT persist
/// anything. <see cref="ErpUpsertService"/> consumes the produced draft.</para>
/// </summary>
public interface IErpSource
{
    /// <summary>Short stable identifier — used in audit messages + ErpSyncLog.SourceTotals JSON keys (e.g. <c>"BPI_PRS"</c>).</summary>
    string SourceName { get; }

    /// <summary>True when the source's per-source toggle (e.g. <c>ErpSync:Sources:Bpi:Enabled</c>) is on. False sources are silently skipped by the fan-out loop.</summary>
    bool Enabled { get; }

    /// <summary>Read + transform one batch. <paramref name="warehouseId"/> is the target WH for projected pulls (the source table has no WH column).</summary>
    Task<ErpSyncDraft> ReadAndTransformAsync(
        Guid warehouseId, int backfillDays, CancellationToken ct = default);
}
