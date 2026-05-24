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
        Guid? requesterUserId, int skip, int take, CancellationToken ct = default)
    {
        var where = requesterUserId.HasValue ? "WHERE RequesterUserId = @UserId" : "";
        // IX_ExportJobsLog_UserDate covers the (UserId, EnqueuedAt DESC) seek;
        // the cross-user variant falls back to a scan (small table, fine).
        var sql = $@"
            SELECT  Id, RequesterUserId, RequesterEmail, RequesterName, JobType,
                    FilterJson, Status, EnqueuedAt, StartedAt, CompletedAt,
                    FileName, RowsExported, ErrorMessage
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
}
