using System.Data;
using Dapper;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Data.Repositories;

public class UserRepository : IUserRepository
{
    private readonly IDbConnectionFactory _factory;

    public UserRepository(IDbConnectionFactory factory) => _factory = factory;

    // -------- existing auth methods --------

    public async Task<User?> GetByUsernameAsync(string username, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive,
                   LastSignInAt, CreatedAt, UpdatedAt
            FROM   dbo.Users
            WHERE  LOWER(Username) = LOWER(@Username);";

        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<User>(
            new CommandDefinition(sql, new { Username = username }, cancellationToken: ct));
    }

    public async Task<User?> GetByIdAsync(Guid id, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive,
                   LastSignInAt, CreatedAt, UpdatedAt
            FROM   dbo.Users
            WHERE  Id = @Id;";

        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<User>(
            new CommandDefinition(sql, new { Id = id }, cancellationToken: ct));
    }

    public async Task UpdateLastSignInAsync(Guid userId, CancellationToken ct = default)
    {
        const string sql = "UPDATE dbo.Users SET LastSignInAt = SYSUTCDATETIME() WHERE Id = @Id;";

        using var conn = _factory.Create();
        await conn.ExecuteAsync(
            new CommandDefinition(sql, new { Id = userId }, cancellationToken: ct));
    }

    // -------- masters CRUD --------

    public async Task<IReadOnlyList<UserListRow>> QueryAsync(
        string? role, string? status, string? q, CancellationToken ct = default)
    {
        var where = new List<string>();
        var p = new DynamicParameters();

        if (!string.IsNullOrWhiteSpace(role))
        {
            where.Add("u.Role = @Role");
            p.Add("Role", role.Trim());
        }
        if (!string.IsNullOrWhiteSpace(status))
        {
            var s = status.Trim().ToLowerInvariant();
            if (s == "active")    where.Add("u.IsActive = 1");
            else if (s == "inactive") where.Add("u.IsActive = 0");
        }
        if (!string.IsNullOrWhiteSpace(q))
        {
            // Multi-token AND across username/name/email/phone — same shape as Transactions.
            var tokens = q.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            for (var i = 0; i < tokens.Length; i++)
            {
                var name = $"Q{i}";
                p.Add(name, $"%{tokens[i]}%");
                where.Add($"(u.Username LIKE @{name} OR u.Name LIKE @{name} OR ISNULL(u.Email,'') LIKE @{name} OR ISNULL(u.Phone,'') LIKE @{name})");
            }
        }

        var whereSql = where.Count == 0 ? "" : "WHERE " + string.Join(" AND ", where);
        var listSql = $@"
            SELECT u.Id, u.Username, u.Name, u.Email, u.Phone, u.Role, u.IsActive,
                   u.LastSignInAt, u.CreatedAt,
                   (SELECT COUNT(*) FROM dbo.UserWarehouseAssignments a WHERE a.UserId = u.Id) AS AssignmentCount
            FROM   dbo.Users u
            {whereSql}
            ORDER BY u.Username;";

        // Second query fans out assignments for the filtered user set. Inline so
        // masters.js doesn't N+1 the detail endpoint per row.
        var assignSql = $@"
            SELECT a.UserId, a.WarehouseId, w.Code AS WarehouseCode, w.Name AS WarehouseName,
                   a.Role, a.AssignedAt
            FROM   dbo.UserWarehouseAssignments a
            INNER JOIN dbo.Warehouses w ON w.Id = a.WarehouseId
            WHERE  a.UserId IN (SELECT u.Id FROM dbo.Users u {whereSql})
            ORDER BY w.Code;";

        using var conn = _factory.Create();
        var rows = (await conn.QueryAsync<UserListRow>(
            new CommandDefinition(listSql, p, cancellationToken: ct))).AsList();

        // Reuse the same parameter bag — the WHERE inside the subquery is the same shape.
        var assigns = (await conn.QueryAsync<UserAssignmentJoin>(
            new CommandDefinition(assignSql, p, cancellationToken: ct))).AsList();

        var byUser = assigns
            .GroupBy(a => a.UserId)
            .ToDictionary(g => g.Key, g => g.Select(a => new AssignmentRow
            {
                WarehouseId = a.WarehouseId,
                WarehouseCode = a.WarehouseCode,
                WarehouseName = a.WarehouseName,
                Role = a.Role,
                AssignedAt = a.AssignedAt
            }).ToList());

        foreach (var row in rows)
        {
            if (byUser.TryGetValue(row.Id, out var list))
                row.Assignments = list;
        }
        return rows;
    }

    private sealed class UserAssignmentJoin
    {
        public Guid UserId { get; set; }
        public Guid WarehouseId { get; set; }
        public string WarehouseCode { get; set; } = "";
        public string WarehouseName { get; set; } = "";
        public string Role { get; set; } = "";
        public DateTime AssignedAt { get; set; }
    }

    public async Task<UserDetail?> GetDetailAsync(Guid id, CancellationToken ct = default)
    {
        const string userSql = @"
            SELECT Id, Username, Name, Email, Phone, Role, IsActive,
                   LastSignInAt, CreatedAt, UpdatedAt
            FROM   dbo.Users
            WHERE  Id = @Id;";

        const string assignSql = @"
            SELECT a.WarehouseId, w.Code AS WarehouseCode, w.Name AS WarehouseName,
                   a.Role, a.AssignedAt
            FROM   dbo.UserWarehouseAssignments a
            INNER JOIN dbo.Warehouses w ON w.Id = a.WarehouseId
            WHERE  a.UserId = @Id
            ORDER BY w.Code;";

        using var conn = _factory.Create();
        var detail = await conn.QuerySingleOrDefaultAsync<UserDetail>(
            new CommandDefinition(userSql, new { Id = id }, cancellationToken: ct));
        if (detail is null) return null;

        var assigns = await conn.QueryAsync<AssignmentRow>(
            new CommandDefinition(assignSql, new { Id = id }, cancellationToken: ct));
        detail.Assignments = assigns.AsList();
        return detail;
    }

    public async Task<bool> ExistsByUsernameAsync(string username, CancellationToken ct = default)
    {
        const string sql = "SELECT 1 FROM dbo.Users WHERE LOWER(Username) = LOWER(@Username);";
        using var conn = _factory.Create();
        var hit = await conn.QuerySingleOrDefaultAsync<int?>(
            new CommandDefinition(sql, new { Username = username }, cancellationToken: ct));
        return hit.HasValue;
    }

    public async Task<Guid> CreateAsync(UserCreateRequest req, string passwordHash, CancellationToken ct = default)
    {
        const string sql = @"
            INSERT INTO dbo.Users (Id, Username, Name, Email, Phone, Role, PasswordHash, IsActive, CreatedAt)
            OUTPUT INSERTED.Id
            VALUES (NEWID(), @Username, @Name, @Email, @Phone, @Role, @PasswordHash, @IsActive, SYSUTCDATETIME());";

        using var conn = _factory.Create();
        return await conn.QuerySingleAsync<Guid>(new CommandDefinition(sql, new
        {
            req.Username,
            req.Name,
            req.Email,
            req.Phone,
            req.Role,
            PasswordHash = passwordHash,
            req.IsActive
        }, cancellationToken: ct));
    }

    public async Task<int> UpdateAsync(Guid id, UserUpdateRequest req, CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.Users
               SET Name      = @Name,
                   Email     = @Email,
                   Phone     = @Phone,
                   Role      = @Role,
                   IsActive  = @IsActive,
                   UpdatedAt = SYSUTCDATETIME()
             WHERE Id = @Id;";

        using var conn = _factory.Create();
        return await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            Id = id,
            req.Name,
            req.Email,
            req.Phone,
            req.Role,
            req.IsActive
        }, cancellationToken: ct));
    }

    public async Task<int> DeleteAsync(Guid id, CancellationToken ct = default)
    {
        const string sql = "DELETE FROM dbo.Users WHERE Id = @Id;";
        using var conn = _factory.Create();
        return await conn.ExecuteAsync(new CommandDefinition(sql, new { Id = id }, cancellationToken: ct));
    }

    public async Task UpdatePasswordHashAsync(Guid id, string passwordHash, CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.Users
               SET PasswordHash = @PasswordHash,
                   UpdatedAt    = SYSUTCDATETIME()
             WHERE Id = @Id;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new { Id = id, PasswordHash = passwordHash }, cancellationToken: ct));
    }
}
