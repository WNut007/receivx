using Dapper;
using Microsoft.Data.SqlClient;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public class PullItemAdminService : IPullItemAdminService
{
    private static readonly HashSet<string> AllowedTags = new(StringComparer.Ordinal)
        { "pcba", "swap" };
    private static readonly HashSet<string> AllowedStatuses = new(StringComparer.Ordinal)
        { "normal", "new", "canceled" };

    private readonly IDbConnectionFactory _factory;
    private readonly IAuditService _audit;

    public PullItemAdminService(IDbConnectionFactory factory, IAuditService audit)
    {
        _factory = factory;
        _audit = audit;
    }

    // ========================================================================
    // CREATE
    // ========================================================================
    public async Task<Guid> CreateAsync(Guid pullId, PullItemCreateRequest req, CancellationToken ct = default)
    {
        ValidateCreate(req);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await LockPullAsync(conn, tx, pullId, ct);
            RefuseClosed(pull);

            // Natural-key duplicate check. No DB UNIQUE — the app is the enforcement layer.
            var dup = await conn.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM dbo.PullItems WITH (UPDLOCK, HOLDLOCK) WHERE PullId = @PullId AND ItemCode = @ItemCode;",
                new { PullId = pullId, req.ItemCode }, transaction: tx, cancellationToken: ct));
            if (dup.HasValue)
                throw new BusinessException(
                    $"Item '{req.ItemCode}' already exists on pull {pull.PullNumber}.");

            var nextSort = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM dbo.PullItems WHERE PullId = @PullId;",
                new { PullId = pullId }, transaction: tx, cancellationToken: ct));

            var newId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.PullItems
                       (Id, PullId, ItemCode, Description, VendorCode, VendorName,
                        Tag, Status, Remark, SortOrder)
                OUTPUT INSERTED.Id
                VALUES (NEWID(), @PullId, @ItemCode, @Description, @VendorCode, @VendorName,
                        @Tag, 'normal', @Remark, @SortOrder);",
                new
                {
                    PullId = pullId, req.ItemCode, req.Description,
                    req.VendorCode, req.VendorName, req.Tag, req.Remark,
                    SortOrder = nextSort,
                }, transaction: tx, cancellationToken: ct));

            foreach (var w in req.Windows)
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
                    VALUES (NEWID(), @PullItemId, @HourOfDay, @ExpectedQty, 0);",
                    new { PullItemId = newId, w.HourOfDay, w.ExpectedQty },
                    transaction: tx, cancellationToken: ct));
            }

            var windowsSummary = string.Join(", ", req.Windows
                .OrderBy(w => w.HourOfDay)
                .Select(w => $"{w.HourOfDay:D2}h:{w.ExpectedQty}"));
            await _audit.WriteAsync(conn, tx, "create", "PullItem", newId.ToString(),
                $"Added item {req.ItemCode} to pull {pull.PullNumber} (windows: {windowsSummary})", ct);

            tx.Commit();
            return newId;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            // UQ_PIW_Hour can fire if the request smuggles duplicate hours past the
            // pre-check (race-free in practice, since the pre-check is in-tx, but the
            // db is the last line of defense).
            tx.Rollback();
            throw new BusinessException("Duplicate window hour in request.");
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ========================================================================
    // UPDATE
    // ========================================================================
    public async Task UpdateAsync(Guid pullId, Guid itemId, PullItemUpdateRequest req, CancellationToken ct = default)
    {
        ValidateUpdate(req);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await LockPullAsync(conn, tx, pullId, ct);
            RefuseClosed(pull);

            var item = await conn.QuerySingleOrDefaultAsync<PullItemLockRow>(new CommandDefinition(@"
                SELECT Id, PullId, ItemCode
                FROM   dbo.PullItems WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = itemId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Pull item not found");

            if (item.PullId != pullId)
                throw new NotFoundException("Pull item not found");

            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItems
                   SET Description = @Description,
                       VendorCode  = @VendorCode,
                       VendorName  = @VendorName,
                       Tag         = @Tag,
                       Status      = @Status,
                       Remark      = @Remark
                 WHERE Id = @Id;",
                new
                {
                    Id = itemId,
                    req.Description, req.VendorCode, req.VendorName,
                    req.Tag, req.Status, req.Remark,
                }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "update", "PullItem", itemId.ToString(),
                $"Updated item {item.ItemCode} in pull {pull.PullNumber}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ========================================================================
    // DELETE
    // ========================================================================
    public async Task DeleteAsync(Guid pullId, Guid itemId, CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await LockPullAsync(conn, tx, pullId, ct);
            RefuseClosed(pull);

            var item = await conn.QuerySingleOrDefaultAsync<PullItemLockRow>(new CommandDefinition(@"
                SELECT Id, PullId, ItemCode
                FROM   dbo.PullItems WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = itemId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Pull item not found");

            if (item.PullId != pullId)
                throw new NotFoundException("Pull item not found");

            var anyReceived = await conn.ExecuteScalarAsync<int?>(new CommandDefinition(@"
                SELECT TOP 1 1
                FROM   dbo.PullItemWindows
                WHERE  PullItemId = @Id AND ReceivedQty > 0;",
                new { Id = itemId }, transaction: tx, cancellationToken: ct));
            if (anyReceived.HasValue)
                throw new BusinessException(
                    "Cannot delete item: at least one window has receipts. Cancel them first.");

            // FK_PIW_PullItem ON DELETE CASCADE drops the windows; no explicit DELETE needed.
            await conn.ExecuteAsync(new CommandDefinition(
                "DELETE FROM dbo.PullItems WHERE Id = @Id;",
                new { Id = itemId }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "delete", "PullItem", itemId.ToString(),
                $"Deleted item {item.ItemCode} from pull {pull.PullNumber}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ========================================================================
    // helpers
    // ========================================================================
    private static async Task<PullLockRow> LockPullAsync(
        System.Data.IDbConnection conn, System.Data.IDbTransaction tx, Guid pullId, CancellationToken ct)
    {
        var pull = await conn.QuerySingleOrDefaultAsync<PullLockRow>(new CommandDefinition(@"
            SELECT Id, PullNumber, Status
            FROM   dbo.Pulls WITH (UPDLOCK, ROWLOCK)
            WHERE  Id = @Id;",
            new { Id = pullId }, transaction: tx, cancellationToken: ct))
            ?? throw new NotFoundException("Pull not found");
        return pull;
    }

    private static void RefuseClosed(PullLockRow pull)
    {
        if (string.Equals(pull.Status, "closed", StringComparison.Ordinal))
            throw new BusinessException(
                "Cannot modify items on a closed pull. Reopen it first if you need to change items.");
    }

    private static void ValidateCreate(PullItemCreateRequest req)
    {
        if (string.IsNullOrWhiteSpace(req.ItemCode) || req.ItemCode.Length > 64)
            throw new ValidationException("ItemCode is required (≤ 64 chars)");
        if (string.IsNullOrWhiteSpace(req.Description) || req.Description.Length > 255)
            throw new ValidationException("Description is required (≤ 255 chars)");
        if (req.VendorCode is not null && req.VendorCode.Length > 64)
            throw new ValidationException("VendorCode is too long (≤ 64 chars)");
        if (req.VendorName is not null && req.VendorName.Length > 160)
            throw new ValidationException("VendorName is too long (≤ 160 chars)");
        if (req.Tag is not null && !AllowedTags.Contains(req.Tag))
            throw new ValidationException("Tag must be 'pcba', 'swap', or null");
        if (req.Remark is not null && req.Remark.Length > 255)
            throw new ValidationException("Remark is too long (≤ 255 chars)");

        if (req.Windows is null || req.Windows.Count == 0)
            throw new ValidationException("At least one window is required");
        var dup = req.Windows.GroupBy(w => w.HourOfDay).FirstOrDefault(g => g.Count() > 1);
        if (dup is not null)
            throw new ValidationException($"Duplicate window hour {dup.Key} in request");
        foreach (var w in req.Windows)
        {
            if (w.HourOfDay > 23)
                throw new ValidationException($"HourOfDay {w.HourOfDay} out of range (0..23)");
            if (w.ExpectedQty <= 0)
                throw new ValidationException($"ExpectedQty for hour {w.HourOfDay} must be positive");
        }
    }

    private static void ValidateUpdate(PullItemUpdateRequest req)
    {
        if (string.IsNullOrWhiteSpace(req.Description) || req.Description.Length > 255)
            throw new ValidationException("Description is required (≤ 255 chars)");
        if (req.VendorCode is not null && req.VendorCode.Length > 64)
            throw new ValidationException("VendorCode is too long (≤ 64 chars)");
        if (req.VendorName is not null && req.VendorName.Length > 160)
            throw new ValidationException("VendorName is too long (≤ 160 chars)");
        if (req.Tag is not null && !AllowedTags.Contains(req.Tag))
            throw new ValidationException("Tag must be 'pcba', 'swap', or null");
        if (!AllowedStatuses.Contains(req.Status))
            throw new ValidationException("Status must be 'normal', 'new', or 'canceled'");
        if (req.Remark is not null && req.Remark.Length > 255)
            throw new ValidationException("Remark is too long (≤ 255 chars)");
    }

    private sealed class PullLockRow
    {
        public Guid Id { get; set; }
        public string PullNumber { get; set; } = "";
        public string Status { get; set; } = "";
    }

    private sealed class PullItemLockRow
    {
        public Guid Id { get; set; }
        public Guid PullId { get; set; }
        public string ItemCode { get; set; } = "";
    }
}
