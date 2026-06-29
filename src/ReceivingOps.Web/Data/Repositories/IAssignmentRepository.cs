using System.Data;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public interface IAssignmentRepository
{
    /// <summary>Active warehouses the user has access to, joined with role.</summary>
    Task<IReadOnlyList<AssignedWarehouse>> GetWarehousesForUserAsync(Guid userId, CancellationToken ct = default);

    /// <summary>
    /// Returns the per-warehouse operational role plus the 3 signing-capability
    /// flags at the warehouse, or null if the user has no assignment there.
    /// Used at login to mint the whRole + canSign claims in one round trip.
    /// </summary>
    Task<AssignmentAccess?> GetAccessAsync(Guid userId, Guid warehouseId, CancellationToken ct = default);

    /// <summary>All assignments for a user, enriched with warehouse code+name (for audit messages on user delete).</summary>
    Task<IReadOnlyList<AssignmentRow>> GetForUserAsync(Guid userId, CancellationToken ct = default);

    /// <summary>All assignments for a warehouse, enriched with username+name (for audit on warehouse delete).</summary>
    Task<IReadOnlyList<WarehouseAssignmentRow>> GetForWarehouseAsync(Guid warehouseId, CancellationToken ct = default);

    /// <summary>
    /// Atomically replace the user's assignments with the given set. DELETE-then-INSERT inside the caller's tx.
    /// Returns the (deletedCount, insertedCount) tuple so audit messages can be precise.
    /// </summary>
    Task<(int deleted, int inserted)> ReplaceForUserAsync(
        IDbConnection conn, IDbTransaction tx,
        Guid userId, IEnumerable<AssignmentInput> assignments, CancellationToken ct = default);
}

/// <summary>An active warehouse the user can sign into, with their per-warehouse role.</summary>
public record AssignedWarehouse(Guid Id, string Code, string Name, string Role);

/// <summary>
/// Per-warehouse access for one user: the operational role plus the 3 additive
/// signing-capability flags (db/043). Drives claim minting at login.
/// </summary>
public record AssignmentAccess(
    string Role,
    bool CanSignCustomer,
    bool CanSignWarehouse,
    bool CanSignProduction);

/// <summary>Warehouse-side assignment row enriched with the user's username + name.</summary>
public class WarehouseAssignmentRow
{
    public Guid UserId { get; set; }
    public string Username { get; set; } = "";
    public string UserName { get; set; } = "";
    public string Role { get; set; } = "";
    public bool CanSignCustomer { get; set; }
    public bool CanSignWarehouse { get; set; }
    public bool CanSignProduction { get; set; }
    public DateTime AssignedAt { get; set; }
}
