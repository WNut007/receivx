using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 — serializable snapshot of the filter chosen on the
/// Transactions page when the operator clicked Export. Hangfire stores
/// this verbatim in the job state; the worker rehydrates it and re-runs
/// the same query the page UI would have run (minus take/skip — exports
/// always grab the whole filtered result, capped at <see cref="MaxRows"/>
/// to keep memory bounded).
/// </summary>
public class TransactionsExportRequest
{
    public Guid? WarehouseId { get; set; }
    public string? WarehouseCode { get; set; }
    public DateTime? DateFrom { get; set; }
    public DateTime? DateTo { get; set; }
    public string? Kind { get; set; }
    public string? ReceivedByName { get; set; }
    public string? PullNumber { get; set; }
    public string? PoNumber { get; set; }
    public string? ItemCode { get; set; }
    public int? Hour { get; set; }
    public string? Q { get; set; }

    /// <summary>
    /// Upper bound on rows pulled per export. 100,000 covers ~20 days
    /// at the projected 5K/day rate; beyond that the operator probably
    /// wants a date-narrowed export. Bounded to keep the worker's memory
    /// footprint predictable.
    /// </summary>
    public int MaxRows { get; set; } = 100_000;

    /// <summary>Hydrates into the same <see cref="TransactionsQuery"/> the page uses, with paging disabled.</summary>
    public TransactionsQuery ToQuery() => new(
        WarehouseId:    WarehouseId,
        WarehouseCode:  WarehouseCode,
        DateFrom:       DateFrom,
        DateTo:         DateTo,
        Kind:           Kind,
        OperatorId:     null,
        ReceivedByName: ReceivedByName,
        PullNumber:     PullNumber,
        PoNumber:       PoNumber,
        ItemCode:       ItemCode,
        Hour:           Hour,
        Q:              Q,
        Take:           Math.Max(1, MaxRows),
        Skip:           0);
}
