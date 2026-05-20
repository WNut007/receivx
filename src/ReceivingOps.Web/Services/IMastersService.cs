using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// Multi-step admin operations on Users/Warehouses/Assignments that need a transaction
/// across more than one table (create-with-assignments, replace-assignments, cascade-on-delete).
/// Simple single-row CRUD goes through the repositories directly.
/// </summary>
public interface IMastersService
{
    // -------- Users --------
    Task<Guid> CreateUserAsync(UserCreateRequest req, CancellationToken ct = default);

    /// <summary>Removes a user and writes a delete audit for the user + each affected assignment (§7.7).</summary>
    Task DeleteUserAsync(Guid id, CancellationToken ct = default);

    /// <summary>Replaces all assignments for a user atomically (§6 PUT /api/users/{id}/assignments).</summary>
    Task ReplaceAssignmentsAsync(Guid userId, IReadOnlyList<AssignmentInput> assignments, CancellationToken ct = default);

    /// <summary>Re-hashes the password and writes an audit row (§6 POST /api/users/{id}/reset-password).</summary>
    Task ResetPasswordAsync(Guid userId, string newPassword, CancellationToken ct = default);

    // -------- Warehouses --------
    Task<Guid> CreateWarehouseAsync(WarehouseCreateRequest req, CancellationToken ct = default);
    Task UpdateWarehouseAsync(Guid id, WarehouseUpdateRequest req, CancellationToken ct = default);

    /// <summary>Removes a warehouse and writes a delete audit for the warehouse + each affected assignment (§7.7).</summary>
    Task DeleteWarehouseAsync(Guid id, CancellationToken ct = default);
}
