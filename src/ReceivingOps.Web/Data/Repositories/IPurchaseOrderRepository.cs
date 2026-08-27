using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

/// <summary>
/// Read access for PurchaseOrders + PurchaseOrderLines. Locking + writes happen
/// inside the receive/cancel/PO-admin services, not here.
/// </summary>
public interface IPurchaseOrderRepository
{
    /// <summary>
    /// GET /api/pos — paged list with per-PO line summary
    /// (count + ordered + received). Returns the rows for the requested
    /// slice + the unfiltered-by-paging total so the API layer can wrap
    /// it in <c>PaginatedResponse&lt;PoListRow&gt;</c>.
    /// </summary>
    Task<(IReadOnlyList<PoListRow> Items, int Total)> QueryAsync(
        Guid? warehouseId, string? status, string? itemCode, string? q,
        DateOnly? orderDateFrom, DateOnly? orderDateTo,
        int skip, int take,
        CancellationToken ct = default);

    /// <summary>GET /api/pos/{id} — header + lines (no receipts inline; the
    /// caller fetches per-line receipts through the existing transactions journal).</summary>
    Task<PoDetail?> GetDetailAsync(Guid id, CancellationToken ct = default);

    /// <summary>
    /// Vendor code → vendor name, as known to <c>dbo.PurchaseOrderLines</c> (the
    /// only place a vendor NAME is stored since Phase 14 / db/036).
    ///
    /// Keyed by the code with any source-system prefix stripped (<c>COI-84491</c>
    /// → <c>84491</c>), because <c>dbo.PullItems.VendorCode</c> — which the ERP
    /// sync copies verbatim out of BPI_PRS.VENDOR — carries the bare form. The
    /// map is small (tens of entries) and near-static, so callers are expected to
    /// cache it rather than call this per request.
    ///
    /// Codes whose bare form is ambiguous (two prefixed codes, different names)
    /// are omitted rather than resolved arbitrarily.
    /// </summary>
    Task<IReadOnlyDictionary<string, string>> GetVendorNameByBareCodeAsync(CancellationToken ct = default);

    /// <summary>
    /// FIFO-ordered open PO lines for a (warehouse, itemCode). Drives the
    /// receive preview (§7.2). NOT locked — preview is advisory only; the
    /// transactional path re-reads under UPDLOCK + HOLDLOCK.
    /// </summary>
    Task<IReadOnlyList<PoAvailabilityRow>> GetAvailabilityAsync(
        Guid warehouseId, string itemCode, CancellationToken ct = default);

    /// <summary>
    /// Phase 9 — line-level rows for a set of POs, used by PosExportJob's
    /// "Lines" sheet. Returns one row per PurchaseOrderLine with PO header
    /// context (PoNumber, OrderDate, Vendor*, WarehouseCode, Status)
    /// inlined plus all 20 ERP-sourced columns from db/021. Ordered by
    /// (PoNumber, LineNumber) so the export is human-scannable.
    ///
    /// Empty input → empty result (no SQL issued).
    /// </summary>
    Task<IReadOnlyList<PoLineExportRow>> GetLinesForPosAsync(
        IReadOnlyList<Guid> poIds, CancellationToken ct = default);
}
