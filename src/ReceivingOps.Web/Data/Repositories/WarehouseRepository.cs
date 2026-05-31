using Dapper;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Data.Repositories;

public class WarehouseRepository : IWarehouseRepository
{
    private const string SelectAll = @"
        SELECT Id, Code, Name, City, Country, Address, Capacity, Timezone,
               ManagerId, Phone, IsActive, CreatedAt, UpdatedAt, LogoDataUrl
        FROM   dbo.Warehouses ";

    private const string ListSelect = @"
        SELECT w.Id, w.Code, w.Name, w.City, w.Country, w.Address, w.Capacity,
               w.Timezone, w.ManagerId, mu.Name AS ManagerName,
               w.Phone, w.IsActive, w.CreatedAt, w.LogoDataUrl,
               (SELECT COUNT(*) FROM dbo.UserWarehouseAssignments a WHERE a.WarehouseId = w.Id) AS UserCount
        FROM   dbo.Warehouses w
        LEFT JOIN dbo.Users mu ON mu.Id = w.ManagerId ";

    private readonly IDbConnectionFactory _factory;

    public WarehouseRepository(IDbConnectionFactory factory) => _factory = factory;

    // -------- existing --------

    public async Task<Warehouse?> GetByIdAsync(Guid id, CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<Warehouse>(
            new CommandDefinition(SelectAll + "WHERE Id = @Id;", new { Id = id }, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<Warehouse>> GetAllActiveAsync(CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<Warehouse>(
            new CommandDefinition(SelectAll + "WHERE IsActive = 1 ORDER BY Code;", cancellationToken: ct));
        return rows.AsList();
    }

    // -------- masters CRUD --------

    public async Task<IReadOnlyList<WarehouseListRow>> QueryAsync(
        string? status, string? q, CancellationToken ct = default)
    {
        var where = new List<string>();
        var p = new DynamicParameters();

        if (!string.IsNullOrWhiteSpace(status))
        {
            var s = status.Trim().ToLowerInvariant();
            if (s == "active") where.Add("w.IsActive = 1");
            else if (s == "inactive") where.Add("w.IsActive = 0");
        }
        if (!string.IsNullOrWhiteSpace(q))
        {
            var tokens = q.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            for (var i = 0; i < tokens.Length; i++)
            {
                var name = $"Q{i}";
                p.Add(name, $"%{tokens[i]}%");
                where.Add($"(w.Code LIKE @{name} OR w.Name LIKE @{name} OR ISNULL(w.City,'') LIKE @{name} OR ISNULL(w.Country,'') LIKE @{name})");
            }
        }

        var whereSql = where.Count == 0 ? "" : "WHERE " + string.Join(" AND ", where);
        var sql = ListSelect + whereSql + " ORDER BY w.Code;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<WarehouseListRow>(new CommandDefinition(sql, p, cancellationToken: ct));
        return rows.AsList();
    }

    public async Task<WarehouseListRow?> GetListRowAsync(Guid id, CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<WarehouseListRow>(
            new CommandDefinition(ListSelect + "WHERE w.Id = @Id;",
                new { Id = id }, cancellationToken: ct));
    }

    public async Task<bool> ExistsByCodeAsync(string code, CancellationToken ct = default)
    {
        const string sql = "SELECT 1 FROM dbo.Warehouses WHERE UPPER(Code) = UPPER(@Code);";
        using var conn = _factory.Create();
        var hit = await conn.QuerySingleOrDefaultAsync<int?>(
            new CommandDefinition(sql, new { Code = code }, cancellationToken: ct));
        return hit.HasValue;
    }

    public async Task<Guid> CreateAsync(WarehouseCreateRequest req, CancellationToken ct = default)
    {
        const string sql = @"
            INSERT INTO dbo.Warehouses (Id, Code, Name, City, Country, Address, Capacity, Timezone, ManagerId, Phone, IsActive, CreatedAt, LogoDataUrl)
            OUTPUT INSERTED.Id
            VALUES (NEWID(), @Code, @Name, @City, @Country, @Address, @Capacity, @Timezone, @ManagerId, @Phone, @IsActive, SYSUTCDATETIME(), @LogoDataUrl);";

        using var conn = _factory.Create();
        return await conn.QuerySingleAsync<Guid>(new CommandDefinition(sql, new
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
            req.IsActive,
            req.LogoDataUrl
        }, cancellationToken: ct));
    }

    public async Task<int> UpdateAsync(Guid id, WarehouseUpdateRequest req, CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.Warehouses
               SET Name        = @Name,
                   City        = @City,
                   Country     = @Country,
                   Address     = @Address,
                   Capacity    = @Capacity,
                   Timezone    = @Timezone,
                   ManagerId   = @ManagerId,
                   Phone       = @Phone,
                   IsActive    = @IsActive,
                   LogoDataUrl = @LogoDataUrl,
                   UpdatedAt   = SYSUTCDATETIME()
             WHERE Id = @Id;";

        using var conn = _factory.Create();
        return await conn.ExecuteAsync(new CommandDefinition(sql, new
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
            req.IsActive,
            req.LogoDataUrl
        }, cancellationToken: ct));
    }

    public async Task<int> DeleteAsync(Guid id, CancellationToken ct = default)
    {
        const string sql = "DELETE FROM dbo.Warehouses WHERE Id = @Id;";
        using var conn = _factory.Create();
        return await conn.ExecuteAsync(new CommandDefinition(sql, new { Id = id }, cancellationToken: ct));
    }
}
