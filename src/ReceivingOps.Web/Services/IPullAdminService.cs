using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// Write paths for Pulls (header only — items are managed via separate endpoints).
/// LockPoByPull is set at create-time and cannot be changed (§3.5).
/// PullNumber + WarehouseId are also immutable post-create (business key + scope).
/// State transitions (close/reopen) live in ICloseService.
/// </summary>
public interface IPullAdminService
{
    /// <summary>Creates a new pull. PullNumber must be unique; LockPoByPull defaults to false.</summary>
    Task<Guid> CreateAsync(PullCreateRequest req, CancellationToken ct = default);

    /// <summary>
    /// Edits PullDate / Eta / Notes. Refuses with BusinessException when:
    ///   • req.LockPoByPull does not match the existing flag (§3.5 immutability), or
    ///   • the pull is closed (closed pulls are read-only — reopen via §7.5 first).
    /// </summary>
    Task UpdateAsync(Guid id, PullUpdateRequest req, CancellationToken ct = default);
}
