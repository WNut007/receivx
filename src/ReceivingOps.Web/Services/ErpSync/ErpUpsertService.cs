using Dapper;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Services.PoImport;

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
            "skippedClosed={Skipped}, skippedSynthesised={SkippedSynth}, errors={Errors}, " +
            "itemsAdded={Added}, itemsCanceled={Canceled}",
            result.Created, result.Updated, result.SkippedClosed, result.SkippedSynthesised,
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
            SELECT Id, Status, WarehouseId, Origin
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

        // ------------------------------------------------------------------
        // The ERP feed does not own pulls the PO import synthesised.
        //
        // WIP pull sheets arrive through the importer, which builds the pull,
        // its items, its windows, and a purchase order to receive against. This
        // feed knows nothing about that synthetic PO, so an item the draft omits
        // is canceled below while its PO line keeps the ReceivedQty already
        // booked against it — a canceled pull item with live received quantity
        // behind it and nothing to detect the mismatch.
        //
        // BpiPrsSource / PrbPrsSource now drop WIP sheets before they ever reach
        // a draft, so in the ordinary case this guard never sees one. It is here
        // because the two defences key on different things and can disagree: the
        // source filter keys on the STORER CODE, this keys on PROVENANCE. A
        // synthesised pull whose sheet later appears in the feed under a non-WIP
        // storer passes the filter and arrives right here, and nothing upstream
        // forbids that.
        //
        // Measured 2026-08-20: 964 ERP-fed pulls carry WIP items against 25
        // synthesised ones, the pull-number ranges are disjoint, and not one of
        // the 25 has ever drawn an etl-* audit row. That is why the takeover has
        // never fired — a property of the data, not of the code. Sheet filtering
        // alone would leave the invariant resting on that coincidence.
        //
        // Checked BEFORE the closed check on purpose: one of the 25 synthesised
        // pulls is already closed, and attributing that skip to "closed" would
        // undercount this guard and hide the fact that it was needed at all.
        // ------------------------------------------------------------------
        if (string.Equals(existing.Origin, WipPullSynthesis.OriginPoImport, StringComparison.Ordinal))
        {
            // Nothing was written; roll back the open tx and record the skip
            // standalone, same shape as the closed-pull path below.
            tx.Rollback();
            await _audit.WriteSystemAsync(actorName, "etl-skip", "Pull",
                pull.PullNumber,
                $"[run {runId}]{srcTag} Skipped — pull was synthesised by the PO import " +
                $"(Origin={WipPullSynthesis.OriginPoImport}); the ERP feed does not update, " +
                "add to, or cancel these. Nothing on the pull was read or written.", ct);
            result.SkippedSynthesised++;
            result.PullOutcomes.Add(new PullOutcome
            {
                PullNumber = pull.PullNumber,
                Outcome = "skipped-synthesised",
                Detail = null,
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
        await UpdatePullAsync(conn, tx, pull, existing.Id, existing.Origin, result, runId, actorName, srcTag, ct);
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
    //
    // That list is STATIC and stays exactly as it is: it names columns ETL
    // must never write for anybody. db/052 adds a second, orthogonal gate —
    // dbo.OperatorFieldEdits, read per pull below — which is PER ROW and PER
    // FIELD and decided at runtime: any field an operator has actually edited
    // is never written again, for the life of the pull, even if ERP later
    // sends a different value. The two do not overlap and neither replaces
    // the other. Do not migrate entries from one to the other.
    // ------------------------------------------------------------------
    private async Task UpdatePullAsync(
        System.Data.IDbConnection conn, System.Data.IDbTransaction tx,
        PullDraft pull, Guid pullId, string? pullOrigin, ErpUpsertResult result,
        Guid runId, string actorName, string srcTag, CancellationToken ct)
    {
        // 0. db/052 — every operator ownership mark covering this pull, in ONE
        // round trip, read INSIDE this transaction. The pull row is already
        // UPDLOCK'd by the caller, so an operator edit cannot land between
        // this read and the writes below. Reading once per RUN instead would
        // be cheaper but would miss exactly that case — which is the failure
        // this feature exists to prevent.
        //
        // A pull with no marks (every pre-db/052 row) yields an empty set and
        // the writes below behave exactly as they did before.
        var owned = await OperatorFieldEdits.ReadForPullAsync(conn, tx, pullId, ct);

        // 1. Pull header — only PullDate is mutable from ETL. WarehouseId
        // intentionally NOT updated even if the caller passes a different
        // one; warehouse changes for an existing pull would surprise ops
        // (operators trust the warehouse a pull was created under). 10.5
        // can add a conflict audit if WarehouseId differs.
        if (owned.IsOwned(OperatorFieldEdits.Pull, pullId, OperatorFieldEdits.Fields.PullDate))
        {
            result.NoteField(OperatorFieldEdits.Fields.PullDate, skipped: true);
            result.RowsWithAnySkip++;
        }
        else
        {
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Pulls
                   SET PullDate = @PullDate
                 WHERE Id = @Id;",
                new { Id = pullId, pull.PullDate },
                transaction: tx, cancellationToken: ct));
            result.NoteField(OperatorFieldEdits.Fields.PullDate, skipped: false);
        }

        // 2. Items — fetch what's currently on the pull so we can diff.
        // Origin joins the shape so the cancel path can tell an
        // operator-created item from an ERP-sourced one (db/052).
        var existing = (await conn.QueryAsync<ExistingItem>(new CommandDefinition(@"
            SELECT Id, ItemCode, VendorCode, Status, Origin
            FROM   dbo.PullItems WITH (UPDLOCK)
            WHERE  PullId = @PullId;",
            new { PullId = pullId }, transaction: tx, cancellationToken: ct))).AsList();

        // Keyed by (ItemCode, VendorCode), not ItemCode. ToDictionary on the
        // SKU alone THROWS ArgumentException the moment a pull legitimately
        // holds two storers' rows for one SKU — killing the whole ETL run for
        // that pull. It never fired only because the source collapsed the two
        // upstream; graining the source without fixing this line would have
        // started failing on the ~40% of pull sheets that carry more than one
        // storer.
        //
        // Historical merged rows have a vendor too (whichever one won), so
        // they key cleanly. A row whose VendorCode is NULL keys as
        // (SKU, null) and still matches a draft item with no vendor.
        var existingByKey = new Dictionary<ItemKey, ExistingItem>();
        foreach (var e in existing)
        {
            var key = new ItemKey(e.ItemCode, e.VendorCode);
            // Defensive: pre-change data can hold two rows that collapse to the
            // same key only if the same storer was written twice, which the old
            // grouping made impossible. First wins, and the duplicate is treated
            // as an orphan below rather than throwing mid-run.
            if (!existingByKey.ContainsKey(key)) existingByKey[key] = e;
        }

        // SortOrder for new items continues past the current max so the
        // drawer items grid doesn't get reshuffled on every ETL run.
        var nextSort = await conn.ExecuteScalarAsync<int>(new CommandDefinition(@"
            SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM dbo.PullItems WHERE PullId = @PullId;",
            new { PullId = pullId }, transaction: tx, cancellationToken: ct));

        // Storer-grained too. On the SKU alone, storer A surviving in the draft
        // keeps the SKU in this set, so storer B's withdrawn row is never
        // cancelled and lingers as live outstanding on the operator's worklist
        // forever — a phantom that no amount of receiving clears.
        var draftKeys = new HashSet<ItemKey>();
        foreach (var item in pull.Items)
        {
            var draftKey = new ItemKey(item.ItemCode, item.VendorCode);
            draftKeys.Add(draftKey);

            if (existingByKey.TryGetValue(draftKey, out var ex))
            {
                // ---- Operator-cancelled → SKIP THE WHOLE ROW -------------
                //
                // Note the grain. Everything else in this method skips FIELDS:
                // an owned Remark drops one assignment from the SET clause and
                // the rest of the row still updates. This skips the ROW — no
                // field update, no window sync, no un-cancel, nothing.
                //
                // The distinguishing signal is the OperatorFieldEdits mark on
                // Status, NOT the Status value. Both cancels write the identical
                // string 'canceled': ETL's own, a few lines below, and the
                // operator's, in PullItemAdminService.CancelAsync. Only the
                // operator's carries a mark, and marks are never released, so
                // this holds for the life of the pull no matter how many times
                // the ERP keeps sending the line.
                //
                // An ETL-cancelled row reaching here has no mark and falls
                // through to the ordinary update — it stays cancelled (nothing
                // in this method writes Status back to 'normal'), which is the
                // pre-existing behaviour and is deliberately unchanged.
                if (string.Equals(ex.Status, "canceled", StringComparison.Ordinal) &&
                    owned.IsOwned(OperatorFieldEdits.PullItem, ex.Id, OperatorFieldEdits.Fields.Status))
                {
                    result.ItemsSkippedOperatorCanceled++;
                    continue;
                }

                // Existing item — update ERP-sourced fields. Status is
                // intentionally NOT touched: an operator may have set it
                // to 'canceled' or 'new', and we don't want ETL to flip it
                // back to 'normal' on every run.
                // db/052 — the SET list is now built per row, dropping every
                // field this item's operator owns. Ten candidates; a row with
                // no marks gets all ten and behaves exactly as before.
                //
                // Column names come from OperatorFieldEdits.Fields, which are
                // compile-time constants, never operator input — that is what
                // makes interpolating them into the SET clause safe. The
                // VALUES stay parameterised.
                var candidates = new (string Field, string Column, object? Value)[]
                {
                    (OperatorFieldEdits.Fields.Description,      "Description",      item.Description),
                    (OperatorFieldEdits.Fields.VendorCode,       "VendorCode",       item.VendorCode),
                    (OperatorFieldEdits.Fields.Remark,           "Remark",           item.Remark),
                    (OperatorFieldEdits.Fields.ProductFamily,    "ProductFamily",    item.ProductFamily),
                    (OperatorFieldEdits.Fields.FromSubInventory, "FromSubInventory", item.FromSubInventory),
                    (OperatorFieldEdits.Fields.ToSubInventory,   "ToSubInventory",   item.ToSubInventory),
                    (OperatorFieldEdits.Fields.SpecialControl,   "SpecialControl",   item.SpecialControl),
                    (OperatorFieldEdits.Fields.TrialId,          "TrialId",          item.TrialId),
                    (OperatorFieldEdits.Fields.Location,         "Location",         item.Location),
                    (OperatorFieldEdits.Fields.Phase,            "[Phase]",          item.Phase),
                };

                var setClauses = new List<string>(candidates.Length);
                var parameters = new DynamicParameters();
                parameters.Add("Id", ex.Id);
                var skippedHere = 0;

                foreach (var (field, column, value) in candidates)
                {
                    if (owned.IsOwned(OperatorFieldEdits.PullItem, ex.Id, field))
                    {
                        result.NoteField(field, skipped: true);
                        skippedHere++;
                        continue;
                    }

                    setClauses.Add($"{column} = @{field}");
                    parameters.Add(field, value);
                    result.NoteField(field, skipped: false);
                }

                if (skippedHere > 0) result.RowsWithAnySkip++;

                // Every field owned → no UPDATE at all, rather than an UPDATE
                // with an empty SET list (which is a syntax error).
                if (setClauses.Count > 0)
                {
                    await conn.ExecuteAsync(new CommandDefinition(
                        $"UPDATE dbo.PullItems SET {string.Join(", ", setClauses)} WHERE Id = @Id;",
                        parameters, transaction: tx, cancellationToken: ct));
                }

                await SyncWindowsAsync(conn, tx, ex.Id, item.Windows, owned, result, ct);
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
        var isSynthesised = string.Equals(
            pullOrigin, WipPullSynthesis.OriginPoImport, StringComparison.Ordinal);

        // db/052 — operator-created items are exempt ENTIRELY: never canceled,
        // never touched. Such an item is by definition absent from the ERP
        // draft, so without this clause it was canceled on the very next
        // in-window sync. One traceable victim in production: WIDGET-1000 on
        // pull 0000015899, created 2026-06-11 08:32:46 and canceled by the
        // 09:00:14 run 28 minutes later.
        //
        // This also settles a real inconsistency: the update path above
        // deliberately preserves PullItems.Status so ETL never overrides an
        // operator's decision, while this path overrode that same column.
        //
        // ERP-sourced items that later vanish from the draft keep the existing
        // behaviour — flipped to 'canceled', never DELETEd (§2.5: receipts may
        // FK the row).
        var operatorCreated = existing
            .Count(e => string.Equals(e.Origin, OperatorFieldEdits.OriginOperator, StringComparison.Ordinal)
                        && !draftKeys.Contains(new ItemKey(e.ItemCode, e.VendorCode)));
        result.ItemsExemptCreated += operatorCreated;

        // An operator who has set this row's Status owns it, so ETL must not
        // overwrite that decision — the same rule every other field follows,
        // applied to the one column this path writes.
        //
        // Marked on ANY operator status change, not only a change to 'canceled'.
        // A row an operator moved to 'new' that then vanishes from the draft is
        // exempt too. That widening is deliberate: they decided something about
        // the row's status and cancelling it would undo that.
        //
        // Already-'canceled' rows are filtered out one line below regardless, so
        // in practice this clause earns its keep on the non-canceled statuses.
        bool StatusOwnedByOperator(ExistingItem e) =>
            owned.IsOwned(OperatorFieldEdits.PullItem, e.Id, OperatorFieldEdits.Fields.Status);

        foreach (var orphan in existing.Where(e =>
                     !draftKeys.Contains(new ItemKey(e.ItemCode, e.VendorCode)) &&
                     !string.Equals(e.Status, "canceled", StringComparison.Ordinal) &&
                     !string.Equals(e.Origin, OperatorFieldEdits.OriginOperator, StringComparison.Ordinal) &&
                     !StatusOwnedByOperator(e)))
        {
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItems SET Status = 'canceled' WHERE Id = @Id;",
                new { Id = orphan.Id }, transaction: tx, cancellationToken: ct));
            result.ItemsCanceled++;

            // db/050 — detection only, never a behaviour change.
            //
            // NOW UNREACHABLE BY DESIGN — and deliberately kept. The Origin
            // guard in UpsertOneAsync returns before UpdatePullAsync is ever
            // called for a synthesised pull, so isSynthesised is false on every
            // path that reaches here. Deleting this block would mean that
            // removing the guard silently restores the original hole with no
            // trail at all. Left in place it is a tripwire instead: an
            // 'etl-cancel-synth' audit row appearing in production means the
            // guard was bypassed or removed, and the row names the item, the
            // storer, and the ReceivedQty stranded behind it.
            //
            // When the ERP finally does feed a pull the PO import synthesised,
            // this takeover is mostly graceful: PullDate is refreshed, item
            // metadata is overwritten with the same values, windows are
            // diffed with ExpectedQty clamped so receipts can't be orphaned.
            // The one hole is right here. The ERP draft knows nothing about
            // the synthetic PO, so an item the feed omits is canceled while
            // its PO line keeps whatever ReceivedQty has already been booked
            // against it — a canceled pull item with live received quantity
            // behind it, visible to nobody until somebody reconciles. Same
            // shape as the orphaned VarianceQty (7c15ef9).
            //
            // The takeover is deliberately NOT blocked or altered: the ERP is
            // the source of truth for planning, and refusing its update would
            // trade a silent inconsistency for a stuck sync. What was missing
            // was the trail. Only synthesised pulls pay for this query.
            if (!isSynthesised) continue;

            // Storer-scoped, and this is a CROSS-FORMAT comparison: the orphan's
            // VendorCode is the STRIPPED ERP form ('5732') while
            // PurchaseOrderLines.VendorCode is PREFIXED ('COI-5732'). Written as
            // plain equality it matches nothing and the audit reports 0 — worse
            // than no audit, because a zero reads as "nothing outstanding".
            // Matched either-form via the same rule ReceiptService uses.
            //
            // Without the vendor term at all, this sums EVERY storer's lines for
            // the SKU and reports a figure that belongs to no one. This audit
            // exists precisely to make a mismatch findable; a wrong number here
            // is worse than none.
            //
            // NULL vendor on the orphan → no term, today's whole-SKU sum. That
            // is the honest answer for a row that never carried a storer.
            var vendorTerm = string.IsNullOrWhiteSpace(orphan.VendorCode)
                ? ""
                : @" AND (pol.VendorCode = @VendorCode
                          OR (RIGHT(pol.VendorCode, LEN(@VendorCode)) = @VendorCode
                              AND SUBSTRING(pol.VendorCode, LEN(pol.VendorCode) - LEN(@VendorCode), 1) = '-'))";

            var received = await conn.ExecuteScalarAsync<int?>(new CommandDefinition($@"
                SELECT SUM(pol.ReceivedQty)
                FROM   dbo.PurchaseOrderLines pol
                INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
                WHERE  (po.PullId = @PullId OR po.PullExternalRef = @PullNumber)
                  AND  pol.ItemCode = @ItemCode{vendorTerm};",
                new { PullId = pullId, pull.PullNumber, orphan.ItemCode, orphan.VendorCode },
                transaction: tx, cancellationToken: ct)) ?? 0;

            var storerLbl = string.IsNullOrWhiteSpace(orphan.VendorCode)
                ? "(no storer recorded)"
                : orphan.VendorCode;

            await _audit.WriteSystemAsync(conn, tx, actorName, "etl-cancel-synth", "Pull",
                pull.PullNumber,
                $"[run {runId}]{srcTag} ERP feed omitted item {orphan.ItemCode} " +
                $"[storer {storerLbl}] on pull " +
                $"{pull.PullNumber}, which the PO import synthesised (Origin=" +
                $"{WipPullSynthesis.OriginPoImport}). The item is now canceled; that storer's " +
                $"purchase-order line(s) still carry ReceivedQty={received}. Nothing was blocked " +
                "or rolled back — this row exists so the mismatch is findable before someone " +
                "reconciles.", ct);
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
        Guid itemId, List<PullItemWindowDraft> windows,
        OperatorFieldEdits.OperatorEditSet owned, ErpUpsertResult result,
        CancellationToken ct)
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
                // db/052 — an operator-set ExpectedQty is never overwritten.
                // Checked before the clamp below so the skip is recorded even
                // when ERP happens to agree with the operator this run.
                if (owned.IsOwned(OperatorFieldEdits.PullItemWindow, ex.Id,
                                  OperatorFieldEdits.Fields.ExpectedQty))
                {
                    result.NoteField(OperatorFieldEdits.Fields.ExpectedQty, skipped: true);
                    result.RowsWithAnySkip++;
                    continue;
                }

                // Don't drop ExpectedQty below ReceivedQty — CK_PIW_Caps
                // would reject, and the operator's already-booked
                // receipts would be implicitly orphaned. The operator
                // adjusts manually via the Windows modal if needed.
                // Counted as written whenever ETL HAS authority over the
                // field, not only when the value happened to move. The
                // PullItems path above writes every unowned field each run and
                // counts each one, so counting only changes here would make
                // "written" mean two different things in one report.
                result.NoteField(OperatorFieldEdits.Fields.ExpectedQty, skipped: false);

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
    // Origin (db/050): NULL for ERP-fed and hand-created pulls; 'po-import' for
    // pulls the WIP synthesis built. Read here so the cancel path can tell the
    // difference — see the etl-cancel-synth audit in UpdatePullAsync.
    private sealed record ExistingPull(Guid Id, string Status, Guid WarehouseId, string? Origin);
    // VendorCode joins the shape so the diff can key on (ItemCode, VendorCode).
    // Origin (db/052) joins the shape so the cancel path can exempt
    // operator-created items. NULL = ERP-fed or pre-migration.
    private sealed record ExistingItem(
        Guid Id, string ItemCode, string? VendorCode, string Status, string? Origin);
    private sealed record ExistingWindow(Guid Id, byte HourOfDay, int ExpectedQty, int ReceivedQty);
}
