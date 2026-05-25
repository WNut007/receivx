using Dapper;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public class ErpSyncLogRepository : IErpSyncLogRepository
{
    // ErrorMessage is NVARCHAR(2000); guard against overrun by truncating
    // in C# so the SQL never throws on an oversized parameter.
    private const int ErrorMessageMaxLength = 2000;

    private readonly IDbConnectionFactory _factory;

    public ErpSyncLogRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task InsertStartAsync(
        Guid runId, string triggeredBy, string actorName,
        Guid warehouseId, int backfillDays, CancellationToken ct = default)
    {
        const string sql = @"
            INSERT INTO dbo.ErpSyncLog
                (RunId, TriggeredBy, ActorName, WarehouseId, BackfillDays, Status, StartedAt)
            VALUES
                (@RunId, @TriggeredBy, @ActorName, @WarehouseId, @BackfillDays, 'running', SYSUTCDATETIME());";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            RunId = runId,
            TriggeredBy = triggeredBy,
            ActorName = actorName,
            WarehouseId = warehouseId,
            BackfillDays = backfillDays,
        }, cancellationToken: ct));
    }

    public async Task MarkSucceededAsync(
        Guid runId, ErpSyncLogTotals totals, int elapsedMs, CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.ErpSyncLog
            SET    Status         = 'succeeded',
                   CompletedAt    = SYSUTCDATETIME(),
                   ElapsedMs      = @ElapsedMs,
                   SourceRowCount = @SourceRowCount,
                   DraftPullCount = @DraftPullCount,
                   Created        = @Created,
                   Updated        = @Updated,
                   SkippedClosed  = @SkippedClosed,
                   Errors         = @Errors,
                   ItemsAdded     = @ItemsAdded,
                   ItemsCanceled  = @ItemsCanceled,
                   ErrorMessage   = NULL
            WHERE  RunId = @RunId;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            RunId = runId,
            ElapsedMs = elapsedMs,
            totals.SourceRowCount,
            totals.DraftPullCount,
            totals.Created,
            totals.Updated,
            totals.SkippedClosed,
            totals.Errors,
            totals.ItemsAdded,
            totals.ItemsCanceled,
        }, cancellationToken: ct));
    }

    public async Task MarkFailedAsync(
        Guid runId, string errorMessage, int elapsedMs, CancellationToken ct = default)
    {
        var trimmed = errorMessage.Length > ErrorMessageMaxLength
            ? errorMessage[..ErrorMessageMaxLength]
            : errorMessage;
        const string sql = @"
            UPDATE dbo.ErpSyncLog
            SET    Status       = 'failed',
                   CompletedAt  = SYSUTCDATETIME(),
                   ElapsedMs    = @ElapsedMs,
                   ErrorMessage = @Err
            WHERE  RunId = @RunId;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            RunId = runId,
            ElapsedMs = elapsedMs,
            Err = trimmed,
        }, cancellationToken: ct));
    }

    public async Task<(IReadOnlyList<ErpSyncLogRow> Items, int Total)> QueryPagedAsync(
        int skip, int take, CancellationToken ct = default)
    {
        // IX_ErpSyncLog_StartedAt covers the ORDER BY + the INCLUDE list
        // gives all summary columns the list view needs without a heap lookup.
        const string sql = @"
            SELECT  RunId, TriggeredBy, ActorName, WarehouseId, BackfillDays,
                    Status, StartedAt, CompletedAt, ElapsedMs,
                    SourceRowCount, DraftPullCount,
                    Created, Updated, SkippedClosed, Errors,
                    ItemsAdded, ItemsCanceled, ErrorMessage
            FROM    dbo.ErpSyncLog
            ORDER BY StartedAt DESC, RunId DESC
            OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

            SELECT COUNT(*) FROM dbo.ErpSyncLog;";
        var p = new { Skip = Math.Max(0, skip), Take = Math.Clamp(take, 1, 500) };
        using var conn = _factory.Create();
        using var multi = await conn.QueryMultipleAsync(
            new CommandDefinition(sql, p, cancellationToken: ct));
        var items = (await multi.ReadAsync<ErpSyncLogRow>()).AsList();
        var total = await multi.ReadSingleAsync<int>();
        return (items, total);
    }

    public async Task<ErpSyncLogRow?> GetByRunIdAsync(Guid runId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT  RunId, TriggeredBy, ActorName, WarehouseId, BackfillDays,
                    Status, StartedAt, CompletedAt, ElapsedMs,
                    SourceRowCount, DraftPullCount,
                    Created, Updated, SkippedClosed, Errors,
                    ItemsAdded, ItemsCanceled, ErrorMessage
            FROM    dbo.ErpSyncLog
            WHERE   RunId = @RunId;";
        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<ErpSyncLogRow>(
            new CommandDefinition(sql, new { RunId = runId }, cancellationToken: ct));
    }
}
