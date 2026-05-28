using Dapper;
using ReceivingOps.Web.Data;

namespace ReceivingOps.Web.Services.ErpSync;

public class ErpUpsertService : IErpUpsertService
{
    // Pulls.PullNumber is varchar(32); BPI_PRS.PRS_ID is up to varchar(50).
    // Drafts whose PullNumber would overflow are recorded as Errors so the
    // ETL run continues with the rest of the batch.
    private const int PullNumberMaxLength = 32;

    private readonly IDbConnectionFactory _factory;
    private readonly IAuditService _audit;
    private readonly ILogger<ErpUpsertService> _log;

    public ErpUpsertService(IDbConnectionFactory factory, IAuditService audit, ILogger<ErpUpsertService> log)
    {
        _factory = factory;
        _audit = audit;
        _log = log;
    }

    public async Task<ErpUpsertResult> UpsertAsync(
        ErpSyncDraft draft, Guid runId, string actorName,
        string? sourceName = null, CancellationToken ct = default)
    {
        var result = new ErpUpsertResult();
        // Per-source audit suffix — e.g. " [source BPI_PRS]". Empty for
        // legacy/single-source callers so v3.2 audit messages stay identical.
        var srcTag = string.IsNullOrWhiteSpace(sourceName) ? "" : $" [source {sourceName}]";

        foreach (var pull in draft.Pulls)
        {
            ct.ThrowIfCancellationRequested();

            if (string.IsNullOrWhiteSpace(pull.PullNumber) ||
                pull.PullNumber.Length > PullNumberMaxLength)
            {
                var detail = $"PullNumber is blank or exceeds {PullNumberMaxLength} chars";
                result.Errors++;
                result.PullOutcomes.Add(new PullOutcome
                {
                    PullNumber = pull.PullNumber ?? "(blank)",
                    Outcome = "error",
                    Detail = detail,
                });
                // Audit standalone (no tx) — never mutated anything.
                await _audit.WriteSystemAsync(actorName, "etl-error", "Pull",
                    pull.PullNumber ?? null,
                    $"[run {runId}]{srcTag} {detail}", ct);
                continue;
            }

            try
            {
                await UpsertOneAsync(pull, result, runId, actorName, srcTag, ct);
            }
            catch (Exception ex)
            {
                // Per-pull catchall so one corrupt row doesn't abort the
                // run. Surfaces full exception detail to logs; the outcome
                // list keeps a short summary suitable for audit + UI.
                _log.LogWarning(ex, "Upsert failed for pull {PullNumber}", pull.PullNumber);
                result.Errors++;
                var detail = ex.GetType().Name + ": " + ex.Message;
                result.PullOutcomes.Add(new PullOutcome
                {
                    PullNumber = pull.PullNumber,
                    Outcome = "error",
                    Detail = detail,
                });
                // Audit outside the (rolled-back) tx so the error is visible
                // regardless of mutation state.
                await _audit.WriteSystemAsync(actorName, "etl-error", "Pull",
                    pull.PullNumber, $"[run {runId}]{srcTag} {Truncate(detail, 900)}", ct);
            }
        }

        _log.LogInformation(
            "ErpUpsert applied — created={Created}, updated={Updated}, " +
            "skippedClosed={Skipped}, errors={Errors}, itemsAdded={Added}, itemsCanceled={Canceled}",
            result.Created, result.Updated, result.SkippedClosed,
            result.Errors, result.ItemsAdded, result.ItemsCanceled);

        return result;
    }

    // ------------------------------------------------------------------
    // One pull, one transaction. Either fully applied or rolled back.
    // Audit row for created/updated is written INSIDE the tx so it commits
    // or rolls back with the business mutation. For skipped-closed the
    // audit row is written standalone — the tx was rolled back since no
    // mutation happened, but the SKIP event itself should still be visible.
    // ------------------------------------------------------------------
    private async Task UpsertOneAsync(
        PullDraft pull, ErpUpsertResult result, Guid runId,
        string actorName, string srcTag, CancellationToken ct)
    {
        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();

        // UPDLOCK + ROWLOCK so two concurrent ETL fires can't race on the
        // same pull. DisableConcurrentExecution at the job level makes
        // this belt-and-braces, but local-process concurrency isn't the
        // only path (a future warm-trigger from 10.4 could overlap).
        var existing = await conn.QuerySingleOrDefaultAsync<ExistingPull?>(new CommandDefinition(@"
            SELECT Id, Status, WarehouseId
            FROM   dbo.Pulls WITH (UPDLOCK, ROWLOCK)
            WHERE  PullNumber = @PullNumber;",
            new { pull.PullNumber }, transaction: tx, cancellationToken: ct));

        if (existing is null)
        {
            await InsertPullAsync(conn, tx, pull, ct);
            await _audit.WriteSystemAsync(conn, tx, actorName, "etl-create", "Pull",
                pull.PullNumber,
                $"[run {runId}]{srcTag} Created from ERP — items={pull.Items.Count}, " +
                $"totalExpected={pull.Items.Sum(i => i.Windows.Sum(w => w.ExpectedQty))}", ct);
            tx.Commit();
            result.Created++;
            result.PullOutcomes.Add(new PullOutcome
            {
                PullNumber = pull.PullNumber,
                Outcome = "created",
                Detail = $"items={pull.Items.Count}",
            });
            return;
        }

        if (string.Equals(existing.Status, "closed", StringComparison.Ordinal))
        {
            // ERP cannot retroactively revise a signed pull. Roll back the
            // open transaction (no writes happened) and record the skip
            // via a standalone audit write.
            tx.Rollback();
            await _audit.WriteSystemAsync(actorName, "etl-skip", "Pull",
                pull.PullNumber,
                $"[run {runId}]{srcTag} Skipped — pull is closed; ERP cannot revise signed pulls.", ct);
            result.SkippedClosed++;
            result.PullOutcomes.Add(new PullOutcome
            {
                PullNumber = pull.PullNumber,
                Outcome = "skipped-closed",
                Detail = null,
            });
            return;
        }

        var preItemsAdded = result.ItemsAdded;
        var preItemsCanceled = result.ItemsCanceled;
        await UpdatePullAsync(conn, tx, pull, existing.Id, result, ct);
        var deltaAdded = result.ItemsAdded - preItemsAdded;
        var deltaCanceled = result.ItemsCanceled - preItemsCanceled;
        await _audit.WriteSystemAsync(conn, tx, actorName, "etl-update", "Pull",
            pull.PullNumber,
            $"[run {runId}]{srcTag} Updated from ERP — items={pull.Items.Count}, " +
            $"itemsAdded={deltaAdded}, itemsCanceled={deltaCanceled}", ct);
        tx.Commit();
        result.Updated++;
        result.PullOutcomes.Add(new PullOutcome
        {
            PullNumber = pull.PullNumber,
            Outcome = "updated",
            Detail = $"items={pull.Items.Count}",
        });
    }

    private static string Truncate(string s, int max)
        => s.Length <= max ? s : s.Substring(0, max) + "…";

    // ------------------------------------------------------------------
    // INSERT path — brand new pull. All draft items + windows are inserted.
    // ------------------------------------------------------------------
    private static async Task InsertPullAsync(
        System.Data.IDbConnection conn, System.Data.IDbTransaction tx,
        PullDraft pull, CancellationToken ct)
    {
        // Status defaults to pending; LockHourCap/LockPoByPull default true
        // (project convention — strict-by-default since v2.1). CreatedBy is
        // NULL — ETL has no signed-in user; the audit story (10.5) records
        // the trigger source separately.
        var pullId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
            INSERT INTO dbo.Pulls
                   (Id, PullNumber, WarehouseId, PullDate, Status,
                    LockPoByPull, LockHourCap, CreatedBy)
            OUTPUT INSERTED.Id
            VALUES (NEWID(), @PullNumber, @WarehouseId, @PullDate, 'pending',
                    1, 1, NULL);",
            new { pull.PullNumber, pull.WarehouseId, pull.PullDate },
            transaction: tx, cancellationToken: ct));

        var sortOrder = 0;
        foreach (var item in pull.Items)
        {
            sortOrder++;
            var itemId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.PullItems
                       (Id, PullId, ItemCode, Description, VendorCode, Tag,
                        Status, Remark, SortOrder,
                        ProductFamily, FromSubInventory, ToSubInventory,
                        SpecialControl, TrialId, Location, [Phase])
                OUTPUT INSERTED.Id
                VALUES (NEWID(), @PullId, @ItemCode, @Description, @VendorCode, @Tag,
                        'normal', @Remark, @SortOrder,
                        @ProductFamily, @FromSubInventory, @ToSubInventory,
                        @SpecialControl, @TrialId, @Location, @Phase);",
                new
                {
                    PullId = pullId,
                    item.ItemCode, item.Description, item.VendorCode, item.Tag,
                    item.Remark, SortOrder = sortOrder,
                    item.ProductFamily, item.FromSubInventory, item.ToSubInventory,
                    item.SpecialControl, item.TrialId, item.Location, item.Phase,
                }, transaction: tx, cancellationToken: ct));

            foreach (var win in item.Windows)
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.PullItemWindows
                           (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
                    VALUES (NEWID(), @PullItemId, @HourOfDay, @ExpectedQty, 0);",
                    new { PullItemId = itemId, win.HourOfDay, win.ExpectedQty },
                    transaction: tx, cancellationToken: ct));
            }
        }
    }

    // ------------------------------------------------------------------
    // UPDATE path — pull exists and is not closed. Planning fields only.
    //
    // Receivx-managed fields that MUST NOT appear in any UPDATE SET here:
    //   Pulls:     Status, LockPoByPull, LockHourCap, ClosedAt, ClosedBy,
    //              SignatureSvg, ReopenedAt, ReopenedBy, ReopenReason
    //   PullItems: Status (operator-managed; ETL only flips to 'canceled'
    //              for items that DISAPPEARED from the draft, never on
    //              update of present items)
    //   PullItemWindows: ReceivedQty (only the receive/cancel services
    //              touch this; the cache is denormalized from Receipts)
    // ------------------------------------------------------------------
    private async Task UpdatePullAsync(
        System.Data.IDbConnection conn, System.Data.IDbTransaction tx,
        PullDraft pull, Guid pullId, ErpUpsertResult result, CancellationToken ct)
    {
        // 1. Pull header — only PullDate is mutable from ETL. WarehouseId
        // intentionally NOT updated even if the caller passes a different
        // one; warehouse changes for an existing pull would surprise ops
        // (operators trust the warehouse a pull was created under). 10.5
        // can add a conflict audit if WarehouseId differs.
        await conn.ExecuteAsync(new CommandDefinition(@"
            UPDATE dbo.Pulls
               SET PullDate = @PullDate
             WHERE Id = @Id;",
            new { Id = pullId, pull.PullDate },
            transaction: tx, cancellationToken: ct));

        // 2. Items — fetch what's currently on the pull so we can diff.
        var existing = (await conn.QueryAsync<ExistingItem>(new CommandDefinition(@"
            SELECT Id, ItemCode, Status
            FROM   dbo.PullItems WITH (UPDLOCK)
            WHERE  PullId = @PullId;",
            new { PullId = pullId }, transaction: tx, cancellationToken: ct))).AsList();
        var existingByCode = existing.ToDictionary(e => e.ItemCode, StringComparer.Ordinal);

        // SortOrder for new items continues past the current max so the
        // drawer items grid doesn't get reshuffled on every ETL run.
        var nextSort = await conn.ExecuteScalarAsync<int>(new CommandDefinition(@"
            SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM dbo.PullItems WHERE PullId = @PullId;",
            new { PullId = pullId }, transaction: tx, cancellationToken: ct));

        var draftCodes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in pull.Items)
        {
            draftCodes.Add(item.ItemCode);

            if (existingByCode.TryGetValue(item.ItemCode, out var ex))
            {
                // Existing item — update ERP-sourced fields. Status is
                // intentionally NOT touched: an operator may have set it
                // to 'canceled' or 'new', and we don't want ETL to flip it
                // back to 'normal' on every run.
                await conn.ExecuteAsync(new CommandDefinition(@"
                    UPDATE dbo.PullItems
                       SET Description      = @Description,
                           VendorCode       = @VendorCode,
                           Remark           = @Remark,
                           ProductFamily    = @ProductFamily,
                           FromSubInventory = @FromSubInventory,
                           ToSubInventory   = @ToSubInventory,
                           SpecialControl   = @SpecialControl,
                           TrialId          = @TrialId,
                           Location         = @Location,
                           [Phase]          = @Phase
                     WHERE Id = @Id;",
                    new
                    {
                        Id = ex.Id,
                        item.Description, item.VendorCode, item.Remark,
                        item.ProductFamily, item.FromSubInventory, item.ToSubInventory,
                        item.SpecialControl, item.TrialId, item.Location, item.Phase,
                    }, transaction: tx, cancellationToken: ct));

                await SyncWindowsAsync(conn, tx, ex.Id, item.Windows, ct);
            }
            else
            {
                // Net-new item. Insert + windows. SortOrder continues past
                // the current max.
                var newItemId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                    INSERT INTO dbo.PullItems
                           (Id, PullId, ItemCode, Description, VendorCode, Tag,
                            Status, Remark, SortOrder,
                            ProductFamily, FromSubInventory, ToSubInventory,
                            SpecialControl, TrialId, Location, [Phase])
                    OUTPUT INSERTED.Id
                    VALUES (NEWID(), @PullId, @ItemCode, @Description, @VendorCode, @Tag,
                            'normal', @Remark, @SortOrder,
                            @ProductFamily, @FromSubInventory, @ToSubInventory,
                            @SpecialControl, @TrialId, @Location, @Phase);",
                    new
                    {
                        PullId = pullId,
                        item.ItemCode, item.Description, item.VendorCode, item.Tag,
                        item.Remark, SortOrder = nextSort++,
                        item.ProductFamily, item.FromSubInventory, item.ToSubInventory,
                        item.SpecialControl, item.TrialId, item.Location, item.Phase,
                    }, transaction: tx, cancellationToken: ct));

                foreach (var win in item.Windows)
                {
                    await conn.ExecuteAsync(new CommandDefinition(@"
                        INSERT INTO dbo.PullItemWindows
                               (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
                        VALUES (NEWID(), @PullItemId, @HourOfDay, @ExpectedQty, 0);",
                        new { PullItemId = newItemId, win.HourOfDay, win.ExpectedQty },
                        transaction: tx, cancellationToken: ct));
                }
                result.ItemsAdded++;
            }
        }

        // 3. Items in DB but missing from draft → flip to 'canceled'. Spec
        // §2.5: never DELETE (receipts may FK the row). Skip items that
        // are ALREADY canceled to avoid noise + keep the count meaningful.
        foreach (var orphan in existing.Where(e =>
                     !draftCodes.Contains(e.ItemCode) &&
                     !string.Equals(e.Status, "canceled", StringComparison.Ordinal)))
        {
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItems SET Status = 'canceled' WHERE Id = @Id;",
                new { Id = orphan.Id }, transaction: tx, cancellationToken: ct));
            result.ItemsCanceled++;
        }
    }

    // ------------------------------------------------------------------
    // Window-level diff for an existing item. Insert new hours, update
    // ExpectedQty (but never below ReceivedQty — that would violate
    // CK_PIW_Caps). Hours present in DB but not in draft are LEFT ALONE
    // (the ETL doesn't know whether an absent hour means "ERP dropped it"
    // or "ERP just didn't emit that window this run"). Operator can
    // delete via the existing Windows modal.
    // ------------------------------------------------------------------
    private static async Task SyncWindowsAsync(
        System.Data.IDbConnection conn, System.Data.IDbTransaction tx,
        Guid itemId, List<PullItemWindowDraft> windows, CancellationToken ct)
    {
        var existing = (await conn.QueryAsync<ExistingWindow>(new CommandDefinition(@"
            SELECT Id, HourOfDay, ExpectedQty, ReceivedQty
            FROM   dbo.PullItemWindows WITH (UPDLOCK)
            WHERE  PullItemId = @PullItemId;",
            new { PullItemId = itemId }, transaction: tx, cancellationToken: ct))).AsList();
        var existingByHour = existing.ToDictionary(e => e.HourOfDay);

        foreach (var win in windows)
        {
            if (existingByHour.TryGetValue(win.HourOfDay, out var ex))
            {
                // Don't drop ExpectedQty below ReceivedQty — CK_PIW_Caps
                // would reject, and the operator's already-booked
                // receipts would be implicitly orphaned. The operator
                // adjusts manually via the Windows modal if needed.
                var safeQty = Math.Max(win.ExpectedQty, ex.ReceivedQty);
                if (safeQty != ex.ExpectedQty)
                {
                    await conn.ExecuteAsync(new CommandDefinition(@"
                        UPDATE dbo.PullItemWindows
                           SET ExpectedQty = @ExpectedQty
                         WHERE Id = @Id;",
                        new { Id = ex.Id, ExpectedQty = safeQty },
                        transaction: tx, cancellationToken: ct));
                }
            }
            else
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.PullItemWindows
                           (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
                    VALUES (NEWID(), @PullItemId, @HourOfDay, @ExpectedQty, 0);",
                    new { PullItemId = itemId, win.HourOfDay, win.ExpectedQty },
                    transaction: tx, cancellationToken: ct));
            }
        }
    }

    // ------------------------------------------------------------------
    // Dapper materialization shapes (private)
    // ------------------------------------------------------------------
    private sealed record ExistingPull(Guid Id, string Status, Guid WarehouseId);
    private sealed record ExistingItem(Guid Id, string ItemCode, string Status);
    private sealed record ExistingWindow(Guid Id, byte HourOfDay, int ExpectedQty, int ReceivedQty);
}
