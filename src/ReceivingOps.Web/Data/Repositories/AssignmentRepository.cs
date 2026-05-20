using System.Data;
using Dapper;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public class AssignmentRepository : IAssignmentRepository
{
    private readonly IDbConnectionFactory _factory;

    public AssignmentRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IReadOnlyList<AssignedWarehouse>> GetWarehousesForUserAsync(
        Guid userId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT  w.Id, w.Code, w.Name, a.Role
            FROM    dbo.UserWarehouseAssignments a
            INNER JOIN dbo.Warehouses w ON w.Id = a.WarehouseId
            WHERE   a.UserId = @UserId
              AND   w.IsActive = 1
            ORDER BY w.Code;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<AssignedWarehouse>(
            new CommandDefinition(sql, new { UserId = userId }, cancellationToken: ct));
        return rows.AsList();
    }

    public async Task<string?> GetRoleAsync(Guid userId, Guid warehouseId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT Role
            FROM   dbo.UserWarehouseAssignments
            WHERE  UserId = @UserId AND WarehouseId = @WarehouseId;";

        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<string?>(
            new CommandDefinition(sql, new { UserId = userId, WarehouseId = warehouseId }, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<AssignmentRow>> GetForUserAsync(Guid userId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT a.WarehouseId, w.Code AS WarehouseCode, w.Name AS WarehouseName,
                   a.Role, a.AssignedAt
            FROM   dbo.UserWarehouseAssignments a
            INNER JOIN dbo.Warehouses w ON w.Id = a.WarehouseId
            WHERE  a.UserId = @UserId
            ORDER BY w.Code;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<AssignmentRow>(
            new CommandDefinition(sql, new { UserId = userId }, cancellationToken: ct));
        return rows.AsList();
    }

    public async Task<IReadOnlyList<WarehouseAssignmentRow>> GetForWarehouseAsync(
        Guid warehouseId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT a.UserId, u.Username, u.Name AS UserName, a.Role, a.AssignedAt
            FROM   dbo.UserWarehouseAssignments a
            INNER JOIN dbo.Users u ON u.Id = a.UserId
            WHERE  a.WarehouseId = @WarehouseId
            ORDER BY u.Username;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<WarehouseAssignmentRow>(
            new CommandDefinition(sql, new { WarehouseId = warehouseId }, cancellationToken: ct));
        return rows.AsList();
    }

    public async Task<(int deleted, int inserted)> ReplaceForUserAsync(
        IDbConnection conn, IDbTransaction tx,
        Guid userId, IEnumerable<AssignmentInput> assignments, CancellationToken ct = default)
    {
        // Atomic replace: wipe + reinsert. The caller's transaction is the one
        // responsible for crash-safety.
        var deleted = await conn.ExecuteAsync(new CommandDefinition(
            "DELETE FROM dbo.UserWarehouseAssignments WHERE UserId = @UserId;",
            new { UserId = userId }, transaction: tx, cancellationToken: ct));

        var inserted = 0;
        const string insertSql = @"
            INSERT INTO dbo.UserWarehouseAssignments (UserId, WarehouseId, Role, AssignedAt)
            VALUES (@UserId, @WarehouseId, @Role, SYSUTCDATETIME());";

        foreach (var a in assignments)
        {
            inserted += await conn.ExecuteAsync(new CommandDefinition(insertSql,
                new { UserId = userId, a.WarehouseId, a.Role },
                transaction: tx, cancellationToken: ct));
        }

        return (deleted, inserted);
    }
}
