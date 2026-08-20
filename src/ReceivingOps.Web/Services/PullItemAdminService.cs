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
            //
            // The key is (PullId, ItemCode, VendorCode): storer is part of item
            // identity. One pull sheet routinely carries the same SKU from two
            // storers with separate purchase orders, and since the ETL now
            // creates both rows, refusing an operator the same thing by hand
            // would leave the manual path unable to express what the automatic
            // one produces. NULL VendorCode is its own bucket — two rows with no
            // storer still collide, which is the pre-storer-grain behaviour for
            // hand-created items.
            var dup = await conn.ExecuteScalarAsync<int?>(new CommandDefinition(@"
                SELECT 1 FROM dbo.PullItems WITH (UPDLOCK, HOLDLOCK)
                WHERE  PullId = @PullId
                  AND  ItemCode = @ItemCode
                  AND  ((VendorCode IS NULL AND @VendorCode IS NULL) OR VendorCode = @VendorCode);",
                new { PullId = pullId, req.ItemCode, req.VendorCode }, transaction: tx, cancellationToken: ct));
            if (dup.HasValue)
                throw new BusinessException(
                    string.IsNullOrWhiteSpace(req.VendorCode)
                        // The blank-vendor case is the one the drawer's duplicate action
                        // lands on: duplicating a row that has no storer reproduces the
                        // existing key exactly. Naming the field to fill in turns the
                        // refusal into an instruction; without it the operator is told
                        // only that they are wrong, which they are not — they duplicated
                        // a row and have not yet said whose goods it is.
                        ? $"Item '{req.ItemCode}' already exists on pull {pull.PullNumber}. " +
                          "Set a storer (vendor code) to tell the two rows apart."
                        : $"Item '{req.ItemCode}' from storer '{req.VendorCode}' already exists on pull {pull.PullNumber}. " +
                          "Change the storer to add another row for this item.");

            var nextSort = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM dbo.PullItems WHERE PullId = @PullId;",
                new { PullId = pullId }, transaction: tx, cancellationToken: ct));

            var newId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.PullItems
                       (Id, PullId, ItemCode, Description, VendorCode, VendorName,
                        Tag, Status, Remark, SortOrder,
                        ProductFamily, FromSubInventory, ToSubInventory,
                        SpecialControl, TrialId, Location, [Phase])
                OUTPUT INSERTED.Id
                VALUES (NEWID(), @PullId, @ItemCode, @Description, @VendorCode, @VendorName,
                        @Tag, 'normal', @Remark, @SortOrder,
                        @ProductFamily, @FromSubInventory, @ToSubInventory,
                        @SpecialControl, @TrialId, @Location, @Phase);",
                new
                {
                    PullId = pullId, req.ItemCode, req.Description,
                    req.VendorCode, req.VendorName, req.Tag, req.Remark,
                    SortOrder = nextSort,
                    req.ProductFamily, req.FromSubInventory, req.ToSubInventory,
                    req.SpecialControl, req.TrialId, req.Location, req.Phase,
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
    // ADD WINDOW (Phase 6.2)
    // ========================================================================
    public async Task<byte> AddWindowAsync(Guid pullId, Guid itemId, PullItemWindowCreateRequest req, CancellationToken ct = default)
    {
        ValidateWindowHour(req.HourOfDay);
        if (req.ExpectedQty <= 0)
            throw new ValidationException("ExpectedQty must be positive");

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await LockPullAsync(conn, tx, pullId, ct);
            RefuseClosed(pull);
            var item = await LockItemOnPullAsync(conn, tx, pullId, itemId, ct);

            try
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
                    VALUES (NEWID(), @PullItemId, @HourOfDay, @ExpectedQty, 0);",
                    new { PullItemId = itemId, req.HourOfDay, req.ExpectedQty },
                    transaction: tx, cancellationToken: ct));
            }
            catch (SqlException ex) when (ex.Number is 2627 or 2601)
            {
                throw new BusinessException(
                    $"Hour {req.HourOfDay:D2}:00 already exists on item {item.ItemCode}.");
            }

            await _audit.WriteAsync(conn, tx, "create", "PullItemWindow",
                $"{itemId}:{req.HourOfDay:D2}",
                $"Added window {req.HourOfDay:D2}:00 ({req.ExpectedQty} pcs) to item {item.ItemCode} on pull {pull.PullNumber}", ct);

            tx.Commit();
            return req.HourOfDay;
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ========================================================================
    // UPDATE WINDOW (Phase 6.2)
    // ========================================================================
    public async Task UpdateWindowAsync(Guid pullId, Guid itemId, byte hourOfDay, PullItemWindowUpdateRequest req, CancellationToken ct = default)
    {
        ValidateWindowHour(hourOfDay);
        if (req.ExpectedQty <= 0)
            throw new ValidationException("ExpectedQty must be positive");

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await LockPullAsync(conn, tx, pullId, ct);
            RefuseClosed(pull);
            var item = await LockItemOnPullAsync(conn, tx, pullId, itemId, ct);

            var window = await conn.QuerySingleOrDefaultAsync<WindowLockRow>(new CommandDefinition(@"
                SELECT Id, HourOfDay, ExpectedQty, ReceivedQty
                FROM   dbo.PullItemWindows WITH (UPDLOCK, ROWLOCK)
                WHERE  PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { PullItemId = itemId, HourOfDay = hourOfDay },
                transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException($"Window {hourOfDay:D2}:00 not found on item {item.ItemCode}");

            // CK_PIW_Caps would reject this too, but pre-checking gives the operator the
            // *reason* instead of a constraint violation message.
            if (req.ExpectedQty < window.ReceivedQty)
                throw new BusinessException(
                    $"Cannot reduce ExpectedQty below ReceivedQty ({window.ReceivedQty} pcs already received in this window).");

            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItemWindows
                   SET ExpectedQty = @ExpectedQty
                 WHERE Id = @Id;",
                new { Id = window.Id, req.ExpectedQty },
                transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "update", "PullItemWindow",
                $"{itemId}:{hourOfDay:D2}",
                $"Updated window {hourOfDay:D2}:00 on item {item.ItemCode} in pull {pull.PullNumber} (qty: {window.ExpectedQty}→{req.ExpectedQty})", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ========================================================================
    // DELETE WINDOW (Phase 6.2)
    // ========================================================================
    public async Task DeleteWindowAsync(Guid pullId, Guid itemId, byte hourOfDay, CancellationToken ct = default)
    {
        ValidateWindowHour(hourOfDay);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await LockPullAsync(conn, tx, pullId, ct);
            RefuseClosed(pull);
            var item = await LockItemOnPullAsync(conn, tx, pullId, itemId, ct);

            var window = await conn.QuerySingleOrDefaultAsync<WindowLockRow>(new CommandDefinition(@"
                SELECT Id, HourOfDay, ExpectedQty, ReceivedQty
                FROM   dbo.PullItemWindows WITH (UPDLOCK, ROWLOCK)
                WHERE  PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { PullItemId = itemId, HourOfDay = hourOfDay },
                transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException($"Window {hourOfDay:D2}:00 not found on item {item.ItemCode}");

            if (window.ReceivedQty > 0)
                throw new BusinessException(
                    $"Cannot delete window {hourOfDay:D2}:00: {window.ReceivedQty} pcs already received. Cancel the receipts first.");

            await conn.ExecuteAsync(new CommandDefinition(
                "DELETE FROM dbo.PullItemWindows WHERE Id = @Id;",
                new { Id = window.Id }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "delete", "PullItemWindow",
                $"{itemId}:{hourOfDay:D2}",
                $"Deleted window {hourOfDay:D2}:00 from item {item.ItemCode} on pull {pull.PullNumber}", ct);

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ========================================================================
    // UPDATE EXTENDED FIELDS (Phase 9.1)
    // ========================================================================
    public async Task UpdateExtendedFieldsAsync(
        Guid pullId, Guid itemId, PullItemExtendedFieldsUpdateRequest req, CancellationToken ct = default)
    {
        ValidateExtendedFields(req);

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            var pull = await LockPullAsync(conn, tx, pullId, ct);
            RefuseClosed(pull);
            var item = await LockItemOnPullAsync(conn, tx, pullId, itemId, ct);

            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItems
                   SET ProductFamily    = @ProductFamily,
                       FromSubInventory = @FromSubInventory,
                       ToSubInventory   = @ToSubInventory,
                       SpecialControl   = @SpecialControl,
                       TrialId          = @TrialId,
                       Location         = @Location,
                       [Phase]          = @Phase
                 WHERE Id = @Id;",
                new
                {
                    Id = itemId,
                    req.ProductFamily,
                    req.FromSubInventory,
                    req.ToSubInventory,
                    req.SpecialControl,
                    req.TrialId,
                    req.Location,
                    req.Phase,
                }, transaction: tx, cancellationToken: ct));

            await _audit.WriteAsync(conn, tx, "update", "PullItem", itemId.ToString(),
                $"Updated extended fields on item {item.ItemCode} in pull {pull.PullNumber}", ct);

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

        // The seven Phase 9.1 columns are NVARCHAR(50) (db/024). Checked here so an
        // over-long value is a 400 naming the field rather than a SqlException
        // truncation error naming nothing.
        ValidateErpField(req.ProductFamily,    nameof(req.ProductFamily));
        ValidateErpField(req.FromSubInventory, nameof(req.FromSubInventory));
        ValidateErpField(req.ToSubInventory,   nameof(req.ToSubInventory));
        ValidateErpField(req.SpecialControl,   nameof(req.SpecialControl));
        ValidateErpField(req.TrialId,          nameof(req.TrialId));
        ValidateErpField(req.Location,         nameof(req.Location));
        ValidateErpField(req.Phase,            nameof(req.Phase));

        if (req.Windows is null || req.Windows.Count == 0)
            throw new ValidationException("At least one window is required");
        var dup = req.Windows.GroupBy(w => w.HourOfDay).FirstOrDefault(g => g.Count() > 1);
        if (dup is not null)
            throw new ValidationException($"Duplicate window hour {dup.Key} in request");
        foreach (var w in req.Windows)
        {
            if (w.HourOfDay > 23)
                throw new ValidationException($"HourOfDay {w.HourOfDay} out of range (0..23)");
            // Stays > 0, deliberately, and the drawer's duplicate action is why it
            // was examined rather than why it changed.
            //
            // Duplicate pre-fills the source row's HOURS and leaves each quantity
            // blank and required. An earlier draft carried the hours with
            // ExpectedQty = 0 instead; zero already means something here and it is
            // not "not yet known". isSettled() returns true for e <= 0
            // ("nothing scheduled is nothing owed"), the console's period status
            // skips such a window entirely and reports 'received', the close gate
            // and WindowsPending both test ExpectedQty > ReceivedQty, and since
            // db/047 rev 11 removed the hour cap, outstanding = 0 makes ANY receipt
            // an over-delivery needing the variance tick and a reason code.
            //
            // A freshly duplicated row would therefore have looked finished the
            // moment it existed, and its first genuine receipt would have been
            // recorded as a variance. Making the operator type a number they were
            // going to type anyway costs one field and avoids all of it.
            if (w.ExpectedQty <= 0)
                throw new ValidationException($"ExpectedQty for hour {w.HourOfDay} must be positive");
        }
    }

    /// <summary>
    /// Phase 9.1 columns are NVARCHAR(50); anything longer is a 400, not a
    /// truncation. Blank is allowed and stored as-is — the create path does not
    /// coalesce, so an omitted field stays NULL.
    /// </summary>
    private static void ValidateErpField(string? value, string fieldName)
    {
        if (value is not null && value.Length > 50)
            throw new ValidationException($"{fieldName} is too long (\u2264 50 chars)");
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

    private static void ValidateWindowHour(byte hourOfDay)
    {
        if (hourOfDay > 23)
            throw new ValidationException($"HourOfDay {hourOfDay} out of range (0..23)");
    }

    // Phase 9.1 — DB column width is NVARCHAR(50); reject anything that wouldn't
    // round-trip silently. We don't enforce a min length (null is a valid value
    // for "ERP hasn't filled this in yet").
    private static void ValidateExtendedFields(PullItemExtendedFieldsUpdateRequest req)
    {
        Check(req.ProductFamily,    nameof(req.ProductFamily));
        Check(req.FromSubInventory, nameof(req.FromSubInventory));
        Check(req.ToSubInventory,   nameof(req.ToSubInventory));
        Check(req.SpecialControl,   nameof(req.SpecialControl));
        Check(req.TrialId,          nameof(req.TrialId));
        Check(req.Location,         nameof(req.Location));
        Check(req.Phase,            nameof(req.Phase));

        static void Check(string? v, string name)
        {
            if (v is not null && v.Length > 50)
                throw new ValidationException($"{name} is too long (≤ 50 chars)");
        }
    }

    // Used by Phase 6.2 window endpoints — confirms (pullId, itemId) is a real
    // pair and locks the item row so the window mutation sees a stable parent.
    private static async Task<PullItemLockRow> LockItemOnPullAsync(
        System.Data.IDbConnection conn, System.Data.IDbTransaction tx,
        Guid pullId, Guid itemId, CancellationToken ct)
    {
        var item = await conn.QuerySingleOrDefaultAsync<PullItemLockRow>(new CommandDefinition(@"
            SELECT Id, PullId, ItemCode
            FROM   dbo.PullItems WITH (UPDLOCK, ROWLOCK)
            WHERE  Id = @Id;",
            new { Id = itemId }, transaction: tx, cancellationToken: ct))
            ?? throw new NotFoundException("Pull item not found");
        if (item.PullId != pullId)
            throw new NotFoundException("Pull item not found");
        return item;
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

    private sealed class WindowLockRow
    {
        public Guid Id { get; set; }
        public byte HourOfDay { get; set; }
        public int ExpectedQty { get; set; }
        public int ReceivedQty { get; set; }
    }
}
