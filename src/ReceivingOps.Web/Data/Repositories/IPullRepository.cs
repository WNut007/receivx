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

    // v2.x Phase 7.3 — DO-eligible pulls. Closed status AND net-positive
    // received qty (excludes fully-cancelled cycles). warehouseId is
    // optional — null returns all warehouses the caller has access to;
    // the controller does the role-based scoping.
    Task<IReadOnlyList<PullSummary>> GetClosedWithReceiptsAsync(Guid? warehouseId, CancellationToken ct = default);
}
