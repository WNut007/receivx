namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 extension — serializable Pos list filter snapshot. Mirrors
/// the params on <c>PurchaseOrdersApiController.List</c>; Hangfire
/// persists this verbatim in the job state and the worker rehydrates
/// it to re-run the same query the page UI would have run, with paging
/// disabled and the result capped at <see cref="MaxRows"/>.
/// </summary>
public class PosExportRequest
{
    public Guid? WarehouseId { get; set; }
    public string? Status { get; set; }
    public string? Q { get; set; }
    public DateOnly? OrderDateFrom { get; set; }
    public DateOnly? OrderDateTo { get; set; }

    /// <summary>Upper bound on rows pulled per export. 100K covers any realistic Pos catalog.</summary>
    public int MaxRows { get; set; } = 100_000;
}
