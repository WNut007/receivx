using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public interface ICloseService
{
    /// <summary>
    /// §7.4: close a fully-received pull. Atomic: validate not-already-closed,
    /// validate signature size, gate on outstanding windows (non-canceled items
    /// only), UPDATE Pulls (Status/ClosedAt/ClosedBy/SignatureSvg), audit.
    /// </summary>
    /// <exception cref="NotFoundException">Pull doesn't exist.</exception>
    /// <exception cref="ForbiddenException">Non-admin caller's session warehouse differs from pull.</exception>
    /// <exception cref="BusinessException">Already closed, signature missing/oversized, or outstanding windows.</exception>
    Task<CloseResult> CloseAsync(Guid pullId, CloseRequest req, CancellationToken ct = default);

    /// <summary>
    /// §7.5: reopen a closed pull. Preserves ClosedAt/ClosedBy/SignatureSvg
    /// (close evidence), sets ReopenedAt/By/Reason, demotes to in_progress, audit.
    /// </summary>
    Task<ReopenResult> ReopenAsync(Guid pullId, ReopenRequest req, CancellationToken ct = default);
}
