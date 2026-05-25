namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10.2 — read BPI_PRS from the ERP DB and transform into Receivx's
/// draft graph. Pure read + transform; no persistence. 10.3 adds upsert.
/// </summary>
public interface IErpSyncService
{
    /// <summary>
    /// Run a read+transform pass against the ERP DB.
    /// </summary>
    /// <param name="warehouseId">The Receivx warehouse all transformed
    /// pulls will be assigned to. Required — BPI_PRS has no warehouse
    /// column, so the caller picks (manual trigger: operator selects;
    /// recurring: configured default).</param>
    /// <param name="backfillDays">Window size for the BPI_PRS read,
    /// applied against DeliveryDate. Caller-controlled so manual triggers
    /// can override the recurring default (e.g. operator does a 90-day
    /// catch-up after a downtime).</param>
    Task<ErpSyncDraft> ReadAndTransformAsync(
        Guid warehouseId, int backfillDays, CancellationToken ct = default);
}
