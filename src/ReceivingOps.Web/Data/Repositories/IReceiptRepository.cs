using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

/// <summary>
/// Read-only access to Receipts (§7.10 — append-only, no Update/Delete here).
/// The transactional write paths live in <see cref="Services.IReceiptService"/>.
/// </summary>
public interface IReceiptRepository
{
    /// <summary>All receipt journal rows for a pull (positive + voided + reversal), most recent first.</summary>
    Task<IReadOnlyList<ReceiptJournalRow>> GetJournalForPullAsync(Guid pullId, CancellationToken ct = default);

    /// <summary>Single journal row by receipt id — used by the drawer's detail view.</summary>
    Task<ReceiptJournalRow?> GetJournalRowAsync(Guid receiptId, CancellationToken ct = default);

    /// <summary>
    /// Cross-pull journal query for the Transactions page (§6, §9.4). Multi-token
    /// AND match on `q` against PullNumber + WarehouseCode + ItemCode + ItemDescription
    /// + LotBatch + PalletId + BinLocation + ReceivedByName + Note. Paged.
    /// </summary>
    Task<PagedTransactions> QueryAsync(TransactionsQuery filter, CancellationToken ct = default);
}
