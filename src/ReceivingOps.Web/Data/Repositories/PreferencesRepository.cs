using Dapper;
using ReceivingOps.Web.Models.Entities;

namespace ReceivingOps.Web.Data.Repositories;

public class PreferencesRepository : IPreferencesRepository
{
    private readonly IDbConnectionFactory _factory;

    public PreferencesRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<UserPreferences?> GetAsync(Guid userId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT UserId, Theme, NavPosition, NavBehavior, NavCollapsed, UpdatedAt
            FROM   dbo.UserPreferences
            WHERE  UserId = @UserId;";

        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<UserPreferences>(
            new CommandDefinition(sql, new { UserId = userId }, cancellationToken: ct));
    }

    public async Task UpsertAsync(UserPreferences prefs, CancellationToken ct = default)
    {
        // MERGE is idiomatic on SQL Server for upserts; the unique key here is UserId.
        const string sql = @"
            MERGE dbo.UserPreferences AS tgt
            USING (SELECT @UserId AS UserId) AS src
               ON tgt.UserId = src.UserId
            WHEN MATCHED THEN
                UPDATE SET Theme        = @Theme,
                           NavPosition  = @NavPosition,
                           NavBehavior  = @NavBehavior,
                           NavCollapsed = @NavCollapsed,
                           UpdatedAt    = SYSUTCDATETIME()
            WHEN NOT MATCHED THEN
                INSERT (UserId, Theme, NavPosition, NavBehavior, NavCollapsed, UpdatedAt)
                VALUES (@UserId, @Theme, @NavPosition, @NavBehavior, @NavCollapsed, SYSUTCDATETIME());";

        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            prefs.UserId,
            prefs.Theme,
            prefs.NavPosition,
            prefs.NavBehavior,
            prefs.NavCollapsed
        }, cancellationToken: ct));
    }
}
