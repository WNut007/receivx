using Dapper;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public class AuditRepository : IAuditRepository
{
    private readonly IDbConnectionFactory _factory;

    public AuditRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IReadOnlyList<AuditRow>> QueryAsync(AuditQuery query, CancellationToken ct = default)
    {
        var take = Math.Clamp(query.Take, 1, 500);
        var where = new List<string>();
        var p = new DynamicParameters();
        p.Add("Take", take);

        if (!string.IsNullOrWhiteSpace(query.Action))
        {
            where.Add("ActionType = @Action");
            p.Add("Action", query.Action.Trim());
        }

        if (!string.IsNullOrWhiteSpace(query.Q))
        {
            var tokens = query.Q.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            for (var i = 0; i < tokens.Length; i++)
            {
                var name = $"Q{i}";
                p.Add(name, $"%{tokens[i]}%");
                where.Add($"(Message LIKE @{name} OR ISNULL(EntityType,'') LIKE @{name} OR ISNULL(ActorName,'') LIKE @{name} OR ActionType LIKE @{name})");
            }
        }

        var whereSql = where.Count == 0 ? "" : "WHERE " + string.Join(" AND ", where);
        var sql = $@"
            SELECT TOP (@Take)
                   Id, ActionType, EntityType, EntityId, Message,
                   ActorUserId, ActorName, IpAddress, OccurredAt
            FROM   dbo.AuditLog
            {whereSql}
            ORDER BY OccurredAt DESC, Id DESC;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<AuditRow>(new CommandDefinition(sql, p, cancellationToken: ct));
        return rows.AsList();
    }
}
