using System.Data;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Data.Repositories;

public interface IPullSignatureRepository
{
    /// <summary>All signatures for a pull, ordered by Party. Read path (Phase 4 report display).</summary>
    Task<IReadOnlyList<PullSignature>> GetByPullAsync(Guid pullId, CancellationToken ct = default);

    /// <summary>True if (PullId, Party) is already signed. Takes UPDLOCK inside the caller's tx
    /// so a concurrent double-sign serializes against the same row range.</summary>
    Task<bool> ExistsAsync(IDbConnection conn, IDbTransaction tx,
        Guid pullId, string party, CancellationToken ct = default);

    /// <summary>Inserts a signature inside the caller's tx. UQ_PullSig_Party is the hard
    /// immutability guard. Returns the row with server-assigned Id + SignedAt populated.</summary>
    Task<PullSignature> InsertAsync(IDbConnection conn, IDbTransaction tx,
        PullSignature sig, CancellationToken ct = default);

    /// <summary>
    /// Phase 7b — upserts the Warehouse-party signature inside the caller's tx with an
    /// explicit SignedAt (the close timestamp). Updates the existing (PullId,'Warehouse')
    /// row if present, else inserts. The upsert is what makes reopen→reclose re-stamp the
    /// Warehouse box with the new closer (D2) instead of violating UQ_PullSig_Party.
    /// Returns true if a new row was inserted, false if an existing row was updated.
    /// </summary>
    Task<bool> UpsertWarehouseAsync(IDbConnection conn, IDbTransaction tx,
        Guid pullId, Guid warehouseId, Guid signerUserId, string signerName,
        DateTime signedAt, CancellationToken ct = default);
}
