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
    Task<SignatureResult> SignAsync(Guid pullId, string party, CancellationToken ct = default);
}
