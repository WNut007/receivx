using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Data.Repositories;

public interface IUserRepository
{
    // ----- existing (auth) -----
    Task<User?> GetByUsernameAsync(string username, CancellationToken ct = default);
    Task<User?> GetByIdAsync(Guid id, CancellationToken ct = default);
    Task UpdateLastSignInAsync(Guid userId, CancellationToken ct = default);

    // ----- masters CRUD -----
    /// <summary>List users with optional role / status (active|inactive) / multi-token q filter.</summary>
    Task<IReadOnlyList<UserListRow>> QueryAsync(string? role, string? status, string? q, CancellationToken ct = default);

    /// <summary>User row + per-warehouse assignments (joined with Warehouses for code+name).</summary>
    Task<UserDetail?> GetDetailAsync(Guid id, CancellationToken ct = default);

    Task<bool> ExistsByUsernameAsync(string username, CancellationToken ct = default);

    /// <summary>Insert a new user with the given pre-hashed password. Returns the new Id.</summary>
    Task<Guid> CreateAsync(UserCreateRequest req, string passwordHash, CancellationToken ct = default);

    /// <summary>Update mutable fields (NOT username, NOT password). Returns rows affected.</summary>
    Task<int> UpdateAsync(Guid id, UserUpdateRequest req, CancellationToken ct = default);

    /// <summary>Hard delete the user. Cascades to UserWarehouseAssignments + UserPreferences via FK CASCADE.</summary>
    Task<int> DeleteAsync(Guid id, CancellationToken ct = default);

    Task UpdatePasswordHashAsync(Guid id, string passwordHash, CancellationToken ct = default);
}
