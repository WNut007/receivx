using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public interface IReceiptService
{
    /// <summary>
    /// §7.2 atomic receive: lock the window row, enforce cap-at-expected, insert Receipt,
    /// update PullItemWindows.ReceivedQty, stamp Pulls.LastActivityAt/FirstReceiptAt,
    /// auto-promote pending → in_progress, write audit. Everything in one transaction.
    /// </summary>
    /// <exception cref="NotFoundException">PullItem or its window doesn't exist.</exception>
    /// <exception cref="ForbiddenException">Caller's session warehouse doesn't match the pull's warehouse (non-admin).</exception>
    /// <exception cref="BusinessException">Pull is closed, qty exceeds remaining, invalid QcStatus, etc.</exception>
    Task<ReceiveResult> ReceiveAsync(ReceiveRequest req, CancellationToken ct = default);

    /// <summary>
    /// §7.3 reverse-entry cancel: insert a negative-qty Receipt linked to the original,
    /// flip Receipts.ReversedById on the original, subtract from PullItemWindows.ReceivedQty,
    /// demote fully_received → in_progress, audit. One transaction.
    /// </summary>
    Task<CancelResult> CancelAsync(Guid receiptId, CancelRequest req, CancellationToken ct = default);
}
