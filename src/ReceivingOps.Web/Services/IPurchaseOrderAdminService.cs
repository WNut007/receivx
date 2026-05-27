using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// Write paths for PurchaseOrders + PurchaseOrderLines. Enforces §7.13 PO
/// immutability when receipts reference the PO/line, and the manual-close path.
/// </summary>
public interface IPurchaseOrderAdminService
{
    Task<Guid> CreateAsync(PoCreateRequest req, CancellationToken ct = default);

    /// <summary>Refuses with BusinessException if any receipt already references this PO (§7.13).</summary>
    Task UpdateAsync(Guid id, PoUpdateRequest req, CancellationToken ct = default);

    /// <summary>Manual procurement close — allowed even with outstanding qty. Reason required (audit).</summary>
    Task CloseAsync(Guid id, PoCloseRequest req, CancellationToken ct = default);

    Task<Guid> AddLineAsync(Guid poId, PoLineCreateRequest req, CancellationToken ct = default);

    /// <summary>Refuses with BusinessException if any receipt references the line (§7.13).</summary>
    Task DeleteLineAsync(Guid poId, Guid lineId, CancellationToken ct = default);

    /// <summary>
    /// Phase 9.2 — bulk overwrite of the 20 ERP-sourced metadata fields on a
    /// single PO line. Mirror of <see cref="IPullItemAdminService.UpdateExtendedFieldsAsync"/>.
    /// Refuses with BusinessException if the parent PO is not 'open' (closed
    /// or canceled). Receipt-reference (§7.13) does NOT block — metadata
    /// updates are non-quantitative and don't invalidate prior receipts.
    /// </summary>
    Task UpdateLineExtendedFieldsAsync(
        Guid poId, Guid lineId, PoLineExtendedFieldsUpdateRequest req, CancellationToken ct = default);
}
