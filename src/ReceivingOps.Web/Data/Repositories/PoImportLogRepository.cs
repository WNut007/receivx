using Dapper;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public class PoImportLogRepository : IPoImportLogRepository
{
    // ErrorMessage is NVARCHAR(MAX) but a 4000-char truncation cap keeps the
    // /Admin/PoImport list-view payload predictable — the long-form
    // stack trace lives in app logs anyway, not the operator's drill-down.
    private const int ErrorMessageMaxLength = 4000;

    private readonly IDbConnectionFactory _factory;

    public PoImportLogRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task InsertSubmittedAsync(
        Guid runId, string uploadedBy, Guid uploadedByUserId, string uploadedByRole,
        Guid warehouseId, string fileName, long fileSizeBytes, string storagePath,
        CancellationToken ct = default)
    {
        // Status is explicit ('validating') even though the column has a
        // 'queued' DEFAULT — the default exists for a future code path that
        // skips Stage 1 (e.g. a re-run from an already-validated log row).
        const string sql = @"
            INSERT INTO dbo.PoImportLog
                (RunId, UploadedBy, UploadedByUserId, UploadedByRole, WarehouseId,
                 FileName, FileSizeBytes, StoragePath, Status, SubmittedAt)
            VALUES
                (@RunId, @UploadedBy, @UploadedByUserId, @UploadedByRole, @WarehouseId,
                 @FileName, @FileSizeBytes, @StoragePath, 'validating', SYSUTCDATETIME());";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            RunId = runId,
            UploadedBy = uploadedBy,
            UploadedByUserId = uploadedByUserId,
            UploadedByRole = uploadedByRole,
            WarehouseId = warehouseId,
            FileName = fileName,
            FileSizeBytes = fileSizeBytes,
            StoragePath = storagePath,
        }, cancellationToken: ct));
    }

    public async Task MarkValidationFailedAsync(
        Guid runId, int totalRowsRead, int validationErrorCount,
        string validationErrorsJson, CancellationToken ct = default)
    {
        // CompletedAt fires here because validation_failed is terminal —
        // the file is rejected and the operator cannot resurrect this row.
        // They'd re-upload, which mints a fresh RunId.
        const string sql = @"
            UPDATE dbo.PoImportLog
            SET    Status               = 'validation_failed',
                   CompletedAt          = SYSUTCDATETIME(),
                   TotalRowsRead        = @TotalRowsRead,
                   ValidationErrorCount = @ValidationErrorCount,
                   ValidationErrors     = @ValidationErrors
            WHERE  RunId = @RunId;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            RunId = runId,
            TotalRowsRead = totalRowsRead,
            ValidationErrorCount = validationErrorCount,
            ValidationErrors = validationErrorsJson,
        }, cancellationToken: ct));
    }

    public async Task MarkValidatedAsync(
        Guid runId, int totalRowsRead, CancellationToken ct = default)
    {
        // Non-terminal — operator confirms next. CompletedAt deliberately stays NULL.
        const string sql = @"
            UPDATE dbo.PoImportLog
            SET    Status        = 'validated',
                   TotalRowsRead = @TotalRowsRead
            WHERE  RunId = @RunId;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            RunId = runId,
            TotalRowsRead = totalRowsRead,
        }, cancellationToken: ct));
    }

    public async Task MarkQueuedAsync(
        Guid runId, string hangfireJobId, CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.PoImportLog
            SET    Status        = 'queued',
                   HangfireJobId = @HangfireJobId
            WHERE  RunId = @RunId;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            RunId = runId,
            HangfireJobId = hangfireJobId,
        }, cancellationToken: ct));
    }

    public async Task MarkRunningAsync(Guid runId, CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.PoImportLog
            SET    Status    = 'running',
                   StartedAt = SYSUTCDATETIME()
            WHERE  RunId = @RunId;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(
            sql, new { RunId = runId }, cancellationToken: ct));
    }

    public async Task MarkSucceededAsync(
        Guid runId, int posInserted, int linesInserted, int elapsedMs,
        CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.PoImportLog
            SET    Status        = 'succeeded',
                   CompletedAt   = SYSUTCDATETIME(),
                   ElapsedMs     = @ElapsedMs,
                   PosInserted   = @PosInserted,
                   LinesInserted = @LinesInserted,
                   ErrorMessage  = NULL
            WHERE  RunId = @RunId;";
        using var conn = _factory.Create();
        await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            RunId = runId,
            ElapsedMs = elapsedMs,
            PosInserted = posInserted,
            LinesInserted = linesInserted,
        }, cancellationToken: ct));
    }

    public async Task MarkFailedAsync(
        Guid runId, string errorMessage, int elapsedMs, CancellationToken ct = default)
    {
        var trimmed = errorMessage.Length > ErrorMessageMaxLength
            ? errorMessage[..ErrorMessageMaxLength]
            : errorMessage;
        const string sql = @"
            UPDATE dbo.PoImportLog
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

    public async Task<(IReadOnlyList<PoImportLogRow> Items, int Total)> QueryPagedAsync(
        int skip, int take, Guid? warehouseId, CancellationToken ct = default)
    {
        // Two indexes carry the dominant orderings:
        //   IX_PoImportLog_WarehouseId_Submitted for the warehouse-scoped path
        //   IX_PoImportLog_SubmittedAt           for the see-all (admin) path
        // The SARGable predicate `(WarehouseId = @Wh OR @Wh IS NULL)` won't use
        // either index when @Wh is NULL because the OR breaks selectivity, but
        // SQL Server's plan cache picks the right index per parameter value at
        // first execution. For correctness this is fine; if the see-all path
        // ever shows up hot in profiling, split into two SQL statements.
        const string sql = @"
            SELECT  RunId, UploadedBy, UploadedByUserId, UploadedByRole, WarehouseId,
                    FileName, FileSizeBytes, StoragePath, Status,
                    SubmittedAt, StartedAt, CompletedAt, ElapsedMs,
                    TotalRowsRead, ValidationErrorCount, ValidationErrors,
                    PosInserted, LinesInserted, ErrorMessage, HangfireJobId
            FROM    dbo.PoImportLog
            WHERE   (@Wh IS NULL OR WarehouseId = @Wh)
            ORDER BY SubmittedAt DESC, RunId DESC
            OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

            SELECT COUNT(*) FROM dbo.PoImportLog
            WHERE  (@Wh IS NULL OR WarehouseId = @Wh);";
        var p = new
        {
            Skip = Math.Max(0, skip),
            Take = Math.Clamp(take, 1, 500),
            Wh = warehouseId,
        };
        using var conn = _factory.Create();
        using var multi = await conn.QueryMultipleAsync(
            new CommandDefinition(sql, p, cancellationToken: ct));
        var items = (await multi.ReadAsync<PoImportLogRow>()).AsList();
        var total = await multi.ReadSingleAsync<int>();
        return (items, total);
    }

    public async Task<PoImportLogRow?> GetByRunIdAsync(Guid runId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT  RunId, UploadedBy, UploadedByUserId, UploadedByRole, WarehouseId,
                    FileName, FileSizeBytes, StoragePath, Status,
                    SubmittedAt, StartedAt, CompletedAt, ElapsedMs,
                    TotalRowsRead, ValidationErrorCount, ValidationErrors,
                    PosInserted, LinesInserted, ErrorMessage, HangfireJobId
            FROM    dbo.PoImportLog
            WHERE   RunId = @RunId;";
        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<PoImportLogRow>(
            new CommandDefinition(sql, new { RunId = runId }, cancellationToken: ct));
    }
}
