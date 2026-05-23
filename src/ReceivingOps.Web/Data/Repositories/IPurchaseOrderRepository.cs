using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

/// <summary>
/// Read access for PurchaseOrders + PurchaseOrderLines. Locking + writes happen
/// inside the receive/cancel/PO-admin services, not here.
/// </summary>
public interface IPurchaseOrderRepository
{
    /// <summary>GET /api/pos — list with per-PO line summary (count + ordered + received).</summary>
    Task<IReadOnlyList<PoListRow>> QueryAsync(
        Guid? warehouseId, string? status, string? itemCode, string? q,
        DateOnly? orderDateFrom, DateOnly? orderDateTo,
        CancellationToken ct = default);

    /// <summary>GET /api/pos/{id} — header + lines (no receipts inline; the
    /// caller fetches per-line receipts through the existing transactions journal).</summary>
    Task<PoDetail?> GetDetailAsync(Guid id, CancellationToken ct = default);

    /// <summary>
    /// FIFO-ordered open PO lines for a (warehouse, itemCode). Drives the
    /// receive preview (§7.2). NOT locked — preview is advisory only; the
    /// transactional path re-reads under UPDLOCK + HOLDLOCK.
    /// </summary>
    Task<IReadOnlyList<PoAvailabilityRow>> GetAvailabilityAsync(
        Guid warehouseId, string itemCode, CancellationToken ct = default);
}
