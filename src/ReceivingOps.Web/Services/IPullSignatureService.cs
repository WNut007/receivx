using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public interface IPullSignatureService
{
    /// <summary>
    /// Signs one party box (Customer/Warehouse/Production) of a pull on behalf of the
    /// current user. Enforces: role gate (whRole must match the party), warehouse scope
    /// (signer's session warehouse must equal the pull's), and immutability (one sign per
    /// (pull, party)). Writes an audit row. Throws ForbiddenException (role/warehouse),
    /// NotFoundException (pull), or BusinessException (already signed / invalid party).
    /// </summary>
    Task<SignatureResult> SignAsync(Guid pullId, string party, string? signatureSvg = null, CancellationToken ct = default);

    /// <summary>
    /// Phase 7d — signs one party (Customer or Production only) across many pulls in a
    /// single call. Per-pull, independent transactions: the same role + warehouse-scope +
    /// immutability guards as SignAsync apply, but a pull that is already signed
    /// ('skipped') or unsignable ('error': not found / different warehouse) does NOT fail
    /// the rest of the batch. Rejects the Warehouse party (BusinessException → 400): it is
    /// auto-signed at close. Throws ForbiddenException when the caller lacks the canSign
    /// claim, BusinessException for an invalid/Warehouse party or an empty/oversized batch.
    /// </summary>
    Task<SignBatchResult> SignBatchAsync(IReadOnlyList<Guid> pullIds, string party, string? signatureSvg = null, CancellationToken ct = default);
}
