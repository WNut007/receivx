using Dapper;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public class ExportJobLogRepository : IExportJobLogRepository
{
    private readonly IDbConnectionFactory _factory;

    public ExportJobLogRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task InsertQueuedAsync(ExportJobLogRow row, CancellationToken ct = default)
    {
        const string sql = @"
            INSERT INTO dbo.ExportJobsLog
                (Id, RequesterUserId, RequesterEmail, RequesterName, JobType, FilterJson,
                 Status, EnqueuedAt)
            VALUES
                (@Id, @RequesterUserId, @RequesterEmail, @RequesterName, @JobType, @FilterJson,
                 'queued', SYSUTCDATETIME());";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            row.Id,
            row.RequesterUserId,
            row.RequesterEmail,
            row.RequesterName,
            row.JobType,
            row.FilterJson,
        }, cancellationToken: ct));
    }

    public async Task UpdateRunningAsync(Guid id, CancellationToken ct = default)
    {
        // Hangfire retries on a failed job rerun RunAsync — set StartedAt
        // only on the first attempt so the original kick-off time is
        // preserved. The COALESCE handles the rerun case.
        const string sql = @"
            UPDATE dbo.ExportJobsLog
            SET    Status = 'running',
                   StartedAt = COALESCE(StartedAt, SYSUTCDATETIME()),
                   ErrorMessage = NULL
            WHERE  Id = @Id;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new { Id = id }, cancellationToken: ct));
    }

    public async Task UpdateSucceededAsync(Guid id, string fileName, int rowsExported, CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.ExportJobsLog
            SET    Status = 'succeeded',
                   CompletedAt = SYSUTCDATETIME(),
                   FileName = @FileName,
                   RowsExported = @Rows,
                   ErrorMessage = NULL
            WHERE  Id = @Id;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            Id = id,
            FileName = fileName,
            Rows = rowsExported,
        }, cancellationToken: ct));
    }

    public async Task UpdateFailedAsync(Guid id, string errorMessage, CancellationToken ct = default)
    {
        // ErrorMessage is NVARCHAR(2000) in schema — truncate defensively.
        var trimmed = errorMessage.Length > 2000 ? errorMessage[..2000] : errorMessage;
        const string sql = @"
            UPDATE dbo.ExportJobsLog
            SET    Status = 'failed',
                   CompletedAt = SYSUTCDATETIME(),
                   ErrorMessage = @Err
            WHERE  Id = @Id;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            Id = id,
            Err = trimmed,
        }, cancellationToken: ct));
    }

    public async Task<(IReadOnlyList<ExportJobLogRow> Items, int Total)> QueryPagedAsync(
        Guid? requesterUserId, string? tab, int skip, int take, CancellationToken ct = default)
    {
        var clauses = new List<string>();
        if (requesterUserId.HasValue) clauses.Add("RequesterUserId = @UserId");

        // Tab predicate. "pending" includes expired-file rows on purpose —
        // the UI badges them as "Expired" so the operator sees they're not
        // actionable. The badge count (GetTabCountsAsync) DOES filter out
        // expired so it represents true actionable backlog; here in the
        // list we preserve the full bucket so the user can see the row
        // and know "yes, the system noticed it expired."
        if (string.Equals(tab, "pending", StringComparison.OrdinalIgnoreCase))
        {
            clauses.Add(@"(Status IN ('queued','running','failed')
                          OR (Status = 'succeeded' AND DownloadedAt IS NULL))");
        }
        else if (string.Equals(tab, "downloaded", StringComparison.OrdinalIgnoreCase))
        {
            clauses.Add("Status = 'succeeded' AND DownloadedAt IS NOT NULL");
        }

        var where = clauses.Count > 0 ? "WHERE " + string.Join(" AND ", clauses) : "";

        // IX_ExportJobsLog_UserDate covers the (UserId, EnqueuedAt DESC) seek;
        // the cross-user variant falls back to a scan (small table, fine).
        // IX_ExportJobsLog_UserPending narrows the pending path further when
        // both the user filter + Status='succeeded' AND DownloadedAt IS NULL
        // overlap (db/023 filtered index).
        var sql = $@"
            SELECT  Id, RequesterUserId, RequesterEmail, RequesterName, JobType,
                    FilterJson, Status, EnqueuedAt, StartedAt, CompletedAt,
                    FileName, RowsExported, ErrorMessage, DownloadedAt
            FROM    dbo.ExportJobsLog
            {where}
            ORDER BY EnqueuedAt DESC, Id DESC
            OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

            SELECT COUNT(*) FROM dbo.ExportJobsLog {where};";

        var p = new { UserId = requesterUserId, Skip = Math.Max(0, skip), Take = Math.Clamp(take, 1, 500) };
        using var conn = _factory.Create();
        using var multi = await conn.QueryMultipleAsync(new CommandDefinition(sql, p, cancellationToken: ct));
        var items = (await multi.ReadAsync<ExportJobLogRow>()).AsList();
        var total = await multi.ReadSingleAsync<int>();
        return (items, total);
    }

    public async Task<ExportTabCounts> GetTabCountsAsync(
        Guid? requesterUserId, ISet<string> presentIdHexes, CancellationToken ct = default)
    {
        var userClause = requesterUserId.HasValue ? "WHERE RequesterUserId = @UserId" : "";
        // Three pieces:
        //   1. Always-pending raw count: queued | running | failed
        //   2. Succeeded-undownloaded row IDs (then intersected with files on disk in C#)
        //   3. Downloaded raw count: succeeded + DownloadedAt set
        // Single round-trip via QueryMultiple.
        var sql = $@"
            SELECT COUNT(*) FROM dbo.ExportJobsLog
            {userClause}
            {(string.IsNullOrEmpty(userClause) ? "WHERE" : "AND")} Status IN ('queued','running','failed');

            SELECT Id FROM dbo.ExportJobsLog
            {userClause}
            {(string.IsNullOrEmpty(userClause) ? "WHERE" : "AND")} Status = 'succeeded' AND DownloadedAt IS NULL;

            SELECT COUNT(*) FROM dbo.ExportJobsLog
            {userClause}
            {(string.IsNullOrEmpty(userClause) ? "WHERE" : "AND")} Status = 'succeeded' AND DownloadedAt IS NOT NULL;";

        using var conn = _factory.Create();
        using var multi = await conn.QueryMultipleAsync(new CommandDefinition(sql, new { UserId = requesterUserId }, cancellationToken: ct));
        var inFlightOrFailed = await multi.ReadSingleAsync<int>();
        var succeededUndownloadedIds = (await multi.ReadAsync<Guid>()).ToList();
        var downloaded = await multi.ReadSingleAsync<int>();

        // Intersect succeeded-undownloaded with on-disk file set — only
        // count what the operator can actually grab. Expired (file gone)
        // rows aren't actionable so they don't inflate the badge.
        var actionableSucceeded = 0;
        foreach (var id in succeededUndownloadedIds)
        {
            if (presentIdHexes.Contains(id.ToString("N"))) actionableSucceeded++;
        }

        return new ExportTabCounts
        {
            Pending = inFlightOrFailed + actionableSucceeded,
            Downloaded = downloaded,
        };
    }

    public async Task<int> MarkDownloadedAsync(Guid id, Guid requesterUserId, CancellationToken ct = default)
    {
        // Privacy guard: the WHERE clause refuses to touch another user's
        // row even if the caller supplies the wrong id. Combined with the
        // DownloadedAt IS NULL check, the operation is idempotent — a
        // re-click after the row's already marked returns 0 rows affected
        // (controller surfaces this as 404 so the smoke can assert it).
        const string sql = @"
            UPDATE dbo.ExportJobsLog
            SET    DownloadedAt = SYSUTCDATETIME()
            WHERE  Id = @Id
              AND  RequesterUserId = @UserId
              AND  Status = 'succeeded'
              AND  DownloadedAt IS NULL;";
        using var conn = _factory.Create();
        return await conn.ExecuteAsync(new CommandDefinition(sql, new { Id = id, UserId = requesterUserId }, cancellationToken: ct));
    }

    public async Task<ExportJobLogRow?> GetByIdAsync(Guid id, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT  Id, RequesterUserId, RequesterEmail, RequesterName, JobType,
                    FilterJson, Status, EnqueuedAt, StartedAt, CompletedAt,
                    FileName, RowsExported, ErrorMessage
            FROM    dbo.ExportJobsLog
            WHERE   Id = @Id;";
        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<ExportJobLogRow>(
            new CommandDefinition(sql, new { Id = id }, cancellationToken: ct));
    }

    public async Task<int> CountUnreadSucceededAsync(Guid userId, ISet<string> presentIdHexes, CancellationToken ct = default)
    {
        // Two-stage filter: SQL narrows to (this user × succeeded × unread),
        // then C# intersects with the on-disk file set so expired files
        // don't inflate the badge. For the operational page size (<= a
        // few hundred unread tops) this is cheap; if it ever bloats, we
        // can flip to a TVP-based JOIN.
        const string sql = @"
            SELECT Id
            FROM   dbo.ExportJobsLog
            WHERE  RequesterUserId = @UserId
              AND  Status = 'succeeded'
              AND  ReadAt IS NULL;";
        using var conn = _factory.Create();
        var ids = (await conn.QueryAsync<Guid>(new CommandDefinition(sql, new { UserId = userId }, cancellationToken: ct))).ToList();
        var count = 0;
        foreach (var id in ids)
        {
            if (presentIdHexes.Contains(id.ToString("N"))) count++;
        }
        return count;
    }

    public async Task<int> MarkAllUnreadAsReadAsync(Guid userId, CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.ExportJobsLog
            SET    ReadAt = SYSUTCDATETIME()
            WHERE  RequesterUserId = @UserId
              AND  Status = 'succeeded'
              AND  ReadAt IS NULL;";
        using var conn = _factory.Create();
        return await conn.ExecuteAsync(new CommandDefinition(sql, new { UserId = userId }, cancellationToken: ct));
    }
}
