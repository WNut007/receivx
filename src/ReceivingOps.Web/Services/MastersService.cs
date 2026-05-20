using System.Data;
using System.Security.Claims;
using Dapper;
using Microsoft.AspNetCore.Identity;
using Microsoft.Data.SqlClient;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Services;

public class MastersService : IMastersService
{
    private static readonly HashSet<string> ValidRoles =
        new(StringComparer.OrdinalIgnoreCase) { "admin", "supervisor", "operator", "viewer" };

    private readonly IDbConnectionFactory _factory;
    private readonly IAuditService _audit;
    private readonly IPasswordHasher<User> _hasher;
    private readonly IHttpContextAccessor _httpContext;

    public MastersService(
        IDbConnectionFactory factory,
        IAuditService audit,
        IPasswordHasher<User> hasher,
        IHttpContextAccessor httpContext)
    {
        _factory = factory;
        _audit = audit;
        _hasher = hasher;
        _httpContext = httpContext;
    }

    // ==================== Users ====================

    public async Task<Guid> CreateUserAsync(UserCreateRequest req, CancellationToken ct = default)
    {
        ValidateUserCommon(req.Name, req.Role);
        var username = (req.Username ?? "").Trim();
        if (string.IsNullOrEmpty(username) || username.Length > 64)
            throw new BusinessException("Username is required and must be ≤ 64 chars");
        if (string.IsNullOrEmpty(req.Password) || req.Password.Length < 4)
            throw new BusinessException("Password must be at least 4 characters");

        if (req.Assignments is { Count: > 0 })
            ValidateAssignments(req.Assignments);

        // Pre-hash outside the tx; PBKDF2 is CPU-bound and shouldn't hold a DB lock.
        var hash = _hasher.HashPassword(new User(), req.Password);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // Username uniqueness inside the tx (the DB UNIQUE constraint is the last line).
            var exists = await conn.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM dbo.Users WHERE LOWER(Username) = LOWER(@Username);",
                new { Username = username }, transaction: tx, cancellationToken: ct));
            if (exists.HasValue)
                throw new BusinessException($"Username '{username}' is already taken");

            var newId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.Users (Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive, CreatedAt)
                OUTPUT INSERTED.Id
                VALUES (NEWID(), @Username, @Name, @Email, @Phone, @Role, @PasswordHash, @IsActive, SYSUTCDATETIME());",
                new
                {
                    Username = username,
                    req.Name,
                    req.Email,
                    req.Phone,
                    req.Role,
                    PasswordHash = hash,
                    req.IsActive
                }, transaction: tx, cancellationToken: ct));

            if (req.Assignments is { Count: > 0 })
            {
                foreach (var a in req.Assignments)
                {
                    await conn.ExecuteAsync(new CommandDefinition(@"
                        INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role, AssignedAt)
                        VALUES (@UserId, @WarehouseId, @Role, SYSUTCDATETIME());",
                        new { UserId = newId, a.WarehouseId, a.Role },
                        transaction: tx, cancellationToken: ct));
                }
            }

            var assignCount = req.Assignments?.Count ?? 0;
            await _audit.WriteAsync(conn, tx, "create", "User", newId.ToString(),
                $"Created user {username} ({req.Role}, {assignCount} assignment(s))", ct);

            tx.Commit();
            return newId;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            tx.Rollback();
            throw new BusinessException($"Username '{username}' is already taken");
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    public async Task DeleteUserAsync(Guid id, CancellationToken ct = default)
    {
        var actorId = CurrentUserId();
        if (actorId == id)
            throw new BusinessException("You cannot delete your own account.");

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // Lock the user row to prevent racing edits/deletes.
            var user = await conn.QuerySingleOrDefaultAsync<UserLockRow>(new CommandDefinition(@"
                SELECT Id, Username, Name
                FROM   dbo.Users WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("User not found");

            // Snapshot assignments before the FK cascade wipes them — needed for audit.
            var assignments = await conn.QueryAsync<AssignmentSnapshotRow>(new CommandDefinition(@"
                SELECT a.WarehouseId, w.Code AS WarehouseCode, a.Role
                FROM   dbo.UserWarehouseAssignments a
                INNER JOIN dbo.Warehouses w ON w.Id = a.WarehouseId
                WHERE  a.UserId = @UserId;",
                new { UserId = id }, transaction: tx, cancellationToken: ct));
            var snap = assignments.AsList();

            // FK CASCADE handles UserWarehouseAssignments + UserPreferences.
            await conn.ExecuteAsync(new CommandDefinition(
                "DELETE FROM dbo.Users WHERE Id = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct));

            // Per §7.7: one audit row per affected assignment, then one for the entity.
            foreach (var a in snap)
            {
                await _audit.WriteAsync(conn, tx, "delete", "Assignment",
                    $"{id}|{a.WarehouseId}",
                    $"Removed {user.Username} from {a.WarehouseCode} ({a.Role}) via user delete", ct);
            }
            await _audit.WriteAsync(conn, tx, "delete", "User", id.ToString(),
                $"Deleted user {user.Username} ({snap.Count} assignment(s) cascaded)", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    public async Task ReplaceAssignmentsAsync(
        Guid userId, IReadOnlyList<AssignmentInput> assignments, CancellationToken ct = default)
    {
        ValidateAssignments(assignments);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var user = await conn.QuerySingleOrDefaultAsync<UserLockRow>(new CommandDefinition(@"
                SELECT Id, Username, Name
                FROM   dbo.Users WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = userId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("User not found");

            await conn.ExecuteAsync(new CommandDefinition(
                "DELETE FROM dbo.UserWarehouseAssignments WHERE UserId = @UserId;",
                new { UserId = userId }, transaction: tx, cancellationToken: ct));

            foreach (var a in assignments)
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role, AssignedAt)
                    VALUES (@UserId, @WarehouseId, @Role, SYSUTCDATETIME());",
                    new { UserId = userId, a.WarehouseId, a.Role },
                    transaction: tx, cancellationToken: ct));
            }

            await _audit.WriteAsync(conn, tx, "assign", "User", userId.ToString(),
                $"Replaced assignments for {user.Username} ({assignments.Count} row(s))", ct);

            tx.Commit();
        }
        catch (SqlException ex) when (ex.Number == 547) // FK constraint violation (bad warehouseId)
        {
            tx.Rollback();
            throw new BusinessException("One or more warehouse IDs are invalid");
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    public async Task ResetPasswordAsync(Guid userId, string newPassword, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(newPassword) || newPassword.Length < 4)
            throw new BusinessException("New password must be at least 4 characters");

        var hash = _hasher.HashPassword(new User(), newPassword);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var user = await conn.QuerySingleOrDefaultAsync<UserLockRow>(new CommandDefinition(@"
                SELECT Id, Username, Name
                FROM   dbo.Users WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = userId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("User not found");

            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Users
                   SET PasswordHash = @Hash,
                       UpdatedAt    = SYSUTCDATETIME()
                 WHERE Id = @Id;",
                new { Id = userId, Hash = hash },
                transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "update", "User", userId.ToString(),
                $"Reset password for {user.Username}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ==================== Warehouses ====================

    public async Task<Guid> CreateWarehouseAsync(WarehouseCreateRequest req, CancellationToken ct = default)
    {
        ValidateWarehouse(req.Code, req.Name, req.Capacity, req.Timezone);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var existing = await conn.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM dbo.Warehouses WHERE UPPER(Code) = UPPER(@Code);",
                new { req.Code }, transaction: tx, cancellationToken: ct));
            if (existing.HasValue)
                throw new BusinessException($"Warehouse code '{req.Code}' is already taken");

            var newId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.Warehouses (Id, Code, Name, City, Country, Address, Capacity, Timezone, ManagerId, Phone, IsActive, CreatedAt)
                OUTPUT INSERTED.Id
                VALUES (NEWID(), @Code, @Name, @City, @Country, @Address, @Capacity, @Timezone, @ManagerId, @Phone, @IsActive, SYSUTCDATETIME());",
                new
                {
                    req.Code,
                    req.Name,
                    req.City,
                    req.Country,
                    req.Address,
                    req.Capacity,
                    req.Timezone,
                    req.ManagerId,
                    req.Phone,
                    req.IsActive
                }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "create", "Warehouse", newId.ToString(),
                $"Created warehouse {req.Code} ({req.Name})", ct);

            tx.Commit();
            return newId;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            tx.Rollback();
            throw new BusinessException($"Warehouse code '{req.Code}' is already taken");
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    public async Task UpdateWarehouseAsync(Guid id, WarehouseUpdateRequest req, CancellationToken ct = default)
    {
        // Code is immutable on update (matches the mockup UI which displays Code as read-only post-create).
        if (string.IsNullOrWhiteSpace(req.Name) || req.Name.Length > 120)
            throw new BusinessException("Warehouse name is required (≤ 120 chars)");

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var wh = await conn.QuerySingleOrDefaultAsync<WarehouseLockRow>(new CommandDefinition(@"
                SELECT Id, Code FROM dbo.Warehouses WITH (UPDLOCK, ROWLOCK) WHERE Id = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Warehouse not found");

            var affected = await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Warehouses
                   SET Name      = @Name,
                       City      = @City,
                       Country   = @Country,
                       Address   = @Address,
                       Capacity  = @Capacity,
                       Timezone  = @Timezone,
                       ManagerId = @ManagerId,
                       Phone     = @Phone,
                       IsActive  = @IsActive,
                       UpdatedAt = SYSUTCDATETIME()
                 WHERE Id = @Id;",
                new
                {
                    Id = id,
                    req.Name,
                    req.City,
                    req.Country,
                    req.Address,
                    req.Capacity,
                    req.Timezone,
                    req.ManagerId,
                    req.Phone,
                    req.IsActive
                }, transaction: tx, cancellationToken: ct));

            if (affected == 0)
                throw new NotFoundException("Warehouse not found");

            await _audit.WriteAsync(conn, tx, "update", "Warehouse", id.ToString(),
                $"Updated warehouse {wh.Code}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    public async Task DeleteWarehouseAsync(Guid id, CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var wh = await conn.QuerySingleOrDefaultAsync<WarehouseLockRow>(new CommandDefinition(@"
                SELECT Id, Code FROM dbo.Warehouses WITH (UPDLOCK, ROWLOCK) WHERE Id = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Warehouse not found");

            // Pulls FK has no CASCADE — refuse if any pulls exist for this warehouse.
            var pullCount = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM dbo.Pulls WHERE WarehouseId = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct));
            if (pullCount > 0)
                throw new BusinessException(
                    $"Cannot delete warehouse {wh.Code}: it has {pullCount} pull(s). Reassign or delete those first.");

            // Snapshot assignments for the per-row audit.
            var assignments = await conn.QueryAsync<WarehouseAssignmentSnap>(new CommandDefinition(@"
                SELECT a.UserId, u.Username, a.Role
                FROM   dbo.UserWarehouseAssignments a
                INNER JOIN dbo.Users u ON u.Id = a.UserId
                WHERE  a.WarehouseId = @WarehouseId;",
                new { WarehouseId = id }, transaction: tx, cancellationToken: ct));
            var snap = assignments.AsList();

            // FK CASCADE handles assignments. Pulls have no cascade (refused above).
            await conn.ExecuteAsync(new CommandDefinition(
                "DELETE FROM dbo.Warehouses WHERE Id = @Id;",
                new { Id = id }, transaction: tx, cancellationToken: ct));

            foreach (var a in snap)
            {
                await _audit.WriteAsync(conn, tx, "delete", "Assignment",
                    $"{a.UserId}|{id}",
                    $"Removed {a.Username} from {wh.Code} ({a.Role}) via warehouse delete", ct);
            }
            await _audit.WriteAsync(conn, tx, "delete", "Warehouse", id.ToString(),
                $"Deleted warehouse {wh.Code} ({snap.Count} assignment(s) cascaded)", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ==================== helpers ====================

    private static void ValidateUserCommon(string name, string role)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length > 120)
            throw new BusinessException("Name is required (≤ 120 chars)");
        if (!ValidRoles.Contains(role))
            throw new BusinessException($"Role must be one of: admin, supervisor, operator, viewer");
    }

    private static void ValidateAssignments(IEnumerable<AssignmentInput> assignments)
    {
        foreach (var a in assignments)
        {
            if (a.WarehouseId == Guid.Empty)
                throw new BusinessException("Assignment warehouseId is required");
            if (!ValidRoles.Contains(a.Role))
                throw new BusinessException($"Invalid assignment role '{a.Role}'");
        }
        // Reject duplicate warehouses in the same payload (composite PK would block it anyway).
        var dupe = assignments
            .GroupBy(a => a.WarehouseId)
            .FirstOrDefault(g => g.Count() > 1);
        if (dupe is not null)
            throw new BusinessException($"Duplicate assignment for warehouseId {dupe.Key}");
    }

    private static void ValidateWarehouse(string code, string name, int capacity, string timezone)
    {
        if (string.IsNullOrWhiteSpace(code) || code.Length > 16)
            throw new BusinessException("Code is required (≤ 16 chars)");
        if (string.IsNullOrWhiteSpace(name) || name.Length > 120)
            throw new BusinessException("Name is required (≤ 120 chars)");
        if (capacity < 0)
            throw new BusinessException("Capacity cannot be negative");
        if (string.IsNullOrWhiteSpace(timezone) || timezone.Length > 64)
            throw new BusinessException("Timezone is required");
    }

    private Guid CurrentUserId()
    {
        var ctx = _httpContext.HttpContext
            ?? throw new InvalidOperationException("HttpContext unavailable");
        var idClaim = ctx.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!Guid.TryParse(idClaim, out var id))
            throw new InvalidOperationException("Authenticated user has no NameIdentifier claim");
        return id;
    }

    private sealed class UserLockRow
    {
        public Guid Id { get; set; }
        public string Username { get; set; } = "";
        public string Name { get; set; } = "";
    }

    private sealed class WarehouseLockRow
    {
        public Guid Id { get; set; }
        public string Code { get; set; } = "";
    }

    private sealed class AssignmentSnapshotRow
    {
        public Guid WarehouseId { get; set; }
        public string WarehouseCode { get; set; } = "";
        public string Role { get; set; } = "";
    }

    private sealed class WarehouseAssignmentSnap
    {
        public Guid UserId { get; set; }
        public string Username { get; set; } = "";
        public string Role { get; set; } = "";
    }
}
