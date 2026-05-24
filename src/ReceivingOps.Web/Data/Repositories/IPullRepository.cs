using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public interface IPullRepository
{
    Task<IReadOnlyList<PullSummary>> QueryAsync(PullQuery filter, CancellationToken ct = default);
    Task<PullDetail?> GetByIdAsync(Guid id, CancellationToken ct = default);
    Task<PullDetail?> GetByPullNumberAsync(string pullNumber, CancellationToken ct = default);
    Task<IReadOnlyList<PullSearchResult>> SearchAsync(Guid warehouseId, string q, int take, CancellationToken ct = default);

    // v2.1 — item-grained reads for the PullItem admin surface.
    // GetByIdAsync already returns Items inside PullDetail, but the admin
    // endpoints want shapes that don't carry the full pull summary.
    Task<IReadOnlyList<PullItemDto>> GetItemsAsync(Guid pullId, CancellationToken ct = default);
    Task<PullItemDto?> GetItemByIdAsync(Guid pullId, Guid itemId, CancellationToken ct = default);

    // v2.x Phase 7.3 / 8.1 — DO-eligible pulls. Closed status AND
    // net-positive received qty (excludes fully-cancelled cycles).
    // warehouseId is optional — null returns all warehouses the caller
    // has access to; the controller does the role-based scoping.
    // Paged: returns the page slice + the unfiltered-by-paging total
    // so the Reports view can render "X of N" + (eventually) page nav.
    Task<(IReadOnlyList<PullSummary> Items, int Total)> GetClosedWithReceiptsAsync(
        Guid? warehouseId, int skip, int take, CancellationToken ct = default);

    // v2.x Phase 7.4 — flat aggregated rows for the DO report. One row per
    // (PO × PoLineNumber × ItemCode) with SUM(QtyReceived) over all receipts
    // (originals + reversals net out — voided originals excluded, reversal
    // negatives included so a fully-reversed line nets to zero and is
    // dropped by HAVING). Ordered by (PoNumber, PoLineNumber, ItemCode) so
    // the service can group sequentially.
    Task<IReadOnlyList<DoReportRow>> GetDoReportRowsAsync(Guid pullId, CancellationToken ct = default);
}
