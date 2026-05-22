using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public interface IReceiptService
{
    /// <summary>
    /// §7.2 read-only FIFO preview. Same algorithm as ReceiveAsync but no locks,
    /// no inserts. The result may be stale by the time Confirm fires — the
    /// transactional path re-runs allocation under lock and is the source of truth.
    /// </summary>
    Task<ReceivePreviewResult> PreviewAsync(Guid pullItemId, int qty, CancellationToken ct = default);

    /// <summary>
    /// §7.2a atomic multi-row receive. Locks the pull row + all candidate PO lines
    /// (UPDLOCK + HOLDLOCK + ROWLOCK), runs FIFO allocation by OrderDate ASC, inserts
    /// one Receipts row per allocation slice, updates PO line cache + auto-closes any
    /// PO that's now fully received, updates PullItemWindows cache, stamps Pulls
    /// timing, auto-promotes pending → in_progress, writes one summary audit row.
    /// Everything in one transaction.
    /// </summary>
    /// <exception cref="NotFoundException">PullItem doesn't exist.</exception>
    /// <exception cref="ForbiddenException">Caller's session warehouse doesn't match (non-admin).</exception>
    /// <exception cref="BusinessException">Pull closed, qty &lt;= 0, insufficient PO capacity, invalid QcStatus.</exception>
    Task<ReceiveResult> ReceiveAsync(ReceiveRequest req, CancellationToken ct = default);

    /// <summary>
    /// §7.3 reverse-entry cancel. Locks the original receipt + the same PO line it
    /// consumed, inserts a negative-qty Receipt with ReversesReceiptId set, restores
    /// qty to the original's PO line (no FIFO logic on the way back), auto-reopens
    /// the PO if it had been auto-closed, decrements PullItemWindows cache, demotes
    /// fully_received → in_progress (preserves FirstReceiptAt). One transaction.
    /// </summary>
    Task<CancelResult> CancelAsync(Guid receiptId, CancelRequest req, CancellationToken ct = default);
}
