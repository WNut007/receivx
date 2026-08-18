using System.Data;
using System.Diagnostics;
using Dapper;
using Hangfire;
using Microsoft.Data.SqlClient;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Data.Repositories;

namespace ReceivingOps.Web.Services.PoImport;

/// <summary>
/// Phase 12.5 — Hangfire job that performs the Stage 2 atomic insert
/// for a previously-validated PO Excel import.
///
/// <para>Lifecycle (joins the 12.3 state machine):</para>
/// <list type="number">
///   <item>Read the log row; abort if status != 'queued' (Hangfire retries
///         shouldn't re-execute a completed run).</item>
///   <item><see cref="IPoImportLogRepository.MarkRunningAsync"/>.</item>
///   <item>Re-parse from <c>log.StoragePath</c>. Stage 1 already validated;
///         a failure here implies file tampering or a missing file —
///         treated as catastrophic and the run is marked failed.</item>
///   <item>Group by PoNumber, then import each group in its OWN
///         transaction. Groups whose PoNumber already exists are SKIPPED,
///         not imported and not errored.</item>
///   <item><see cref="IPoImportLogRepository.MarkSucceededAsync"/> +
///         audit 'po-import-succeeded' (or 'po-import-partial' when the
///         run skipped at least one PO).</item>
/// </list>
///
/// <para><b>Import new, skip duplicates.</b> This job used to wrap the
/// whole file in ONE transaction and roll everything back if any single
/// PoNumber already existed — a re-uploaded workbook carrying one
/// already-imported PO imported nothing at all. Now each PO group commits
/// independently: new PoNumbers land, duplicates are recorded in the log
/// row's PosSkipped / SkippedPoNumbers (db/046) and reported to the
/// operator, and the run is still 'succeeded'.</para>
///
/// <para><b>Duplicate grain is the PoNumber group, never the SKU line.</b>
/// A skipped PoNumber means the pre-existing PurchaseOrder + its lines are
/// left completely untouched. There is deliberately no upsert-into-existing
/// path: merging a re-uploaded file into a PO that may already have
/// receipts against it would put ReceivedQty and OrderedQty into conflict.
/// Re-importing is therefore idempotent-by-skip.</para>
///
/// <para><b>What still fails the whole run.</b> A duplicate is a normal
/// outcome; anything else is not. If a per-PO insert throws for any reason
/// other than a unique violation, that transaction rolls back and the
/// exception propagates — the run is marked failed and Hangfire records
/// it. POs committed before the failure STAY committed (that is the point
/// of per-PO transactions), so a failed run may have imported some POs;
/// PosInserted is not written in that case, but the rows are real. The
/// operator's recovery is to re-upload the same file — the POs that landed
/// are now duplicates and will be skipped.</para>
///
/// <para>Schema notes (verified against db/010 + db/015 + db/021 + db/031 + db/033):</para>
/// <list type="bullet">
///   <item>PullId set NULL — imported POs have no Pull row at import
///         time. FK_PO_Pull is nullable; the v3.2 spec's "PullId =
///         PRS_ID denormalized" idea conflicted with the Guid FK, so
///         we take the conservative NULL path on PullId.</item>
///   <item>PullExternalRef = PoNumber (db/033) — captures the PRS_ID
///         from the workbook on a parallel NVARCHAR(50) column that
///         is independent of FK_PO_Pull. Receive flow (§7.15 lock-by-
///         pull, ReceiptService) and the PO detail UI both consult
///         PullExternalRef when PullId is NULL, so an imported PO
///         can join a receiving pull whose PullNumber matches the
///         PRS_ID without ever creating a Pulls row.</item>
///   <item>OrderDate set to <c>SYSUTCDATETIME()</c> truncated to DATE
///         — schema requires NOT NULL and the parser ignores ORDER DATE
///         (C4=A); semantically "date PO entered Receivx".</item>
///   <item>CreatedBy = log.UploadedByUserId (FK to Users.Id), NOT a
///         display name string.</item>
///   <item>PurchaseOrderLines.Description NOT NULL — parser may return
///         null, so we coalesce to empty string at insert.</item>
///   <item>LineNumber = 1-based ordinal within the PO group, in file
///         order (matches UQ_POL_LineNumber).</item>
/// </list>
/// </summary>
public class PoImportJob
{
    // Half-hour is the spec's upper bound (30 min) and matches a comfortable
    // ceiling for the ~6k-row sample file's expected throughput. Longer
    // imports should be a re-design signal, not a timeout bump.
    private const int DisableConcurrentTimeoutSeconds = 1800;

    private readonly IDbConnectionFactory _factory;
    private readonly IPoImportLogRepository _logRepo;
    private readonly IPoImportReader _reader;
    private readonly IAuditService _audit;
    private readonly ILogger<PoImportJob> _logger;

    public PoImportJob(
        IDbConnectionFactory factory,
        IPoImportLogRepository logRepo,
        IPoImportReader reader,
        IAuditService audit,
        ILogger<PoImportJob> logger)
    {
        _factory = factory;
        _logRepo = logRepo;
        _reader = reader;
        _audit = audit;
        _logger = logger;
    }

    /// <summary>
    /// Entry point invoked by Hangfire. <paramref name="actorName"/> is
    /// captured by the controller before enqueue (HttpContext is gone on
    /// the worker thread); it's the same display name the 12.4 audit
    /// rows use, so the trail stays attributable.
    /// </summary>
    [DisableConcurrentExecution(timeoutInSeconds: DisableConcurrentTimeoutSeconds)]
    [Queue("po-import")]
    public async Task RunAsync(Guid runId, string actorName)
    {
        if (runId == Guid.Empty)
        {
            _logger.LogWarning("PoImportJob fired with empty runId — aborting.");
            return;
        }
        var safeActor = string.IsNullOrWhiteSpace(actorName) ? "(unknown)" : actorName;

        var log = await _logRepo.GetByRunIdAsync(runId);
        if (log is null)
        {
            _logger.LogError("PoImportJob {RunId} — log row not found; aborting.", runId);
            return;
        }

        // Idempotency: Hangfire retries (or a stuck-state cleanup that
        // re-enqueues a partially-run job) must not re-run a completed
        // import. Only the 'queued' state allows progression.
        if (!string.Equals(log.Status, "queued", StringComparison.Ordinal))
        {
            _logger.LogWarning(
                "PoImportJob {RunId} in unexpected status {Status} — aborting (expected 'queued').",
                runId, log.Status);
            return;
        }

        await _logRepo.MarkRunningAsync(runId);
        var sw = Stopwatch.StartNew();

        try
        {
            // ---- Re-parse the file ---------------------------------------------
            // Stage 1 already validated; a failure here means the file moved or
            // was tampered with between validate-time and the operator's confirm.
            var parse = await _reader.ParseAsync(log.StoragePath);
            if (!parse.IsValid)
            {
                throw new InvalidOperationException(
                    $"Re-validation failed: {parse.ValidationErrors.Count} error(s) across {parse.TotalRows} rows. " +
                    "The file may have been replaced or moved after Stage 1 validation.");
            }

            // ---- WIP synthesis plan --------------------------------------------
            // Same planner Stage 1 previewed with, re-run on the re-parsed
            // file so the commit cannot diverge from what was shown. Guard
            // rails re-checked here too: Stage 1 validated the file that was
            // uploaded, and this is the file that is on disk now.
            var wipPlan = WipPullSynthesis.Build(parse.Rows);
            if (wipPlan.Errors.Count > 0)
            {
                throw new InvalidOperationException(
                    $"WIP synthesis re-validation failed: {wipPlan.Errors.Count} error(s). " +
                    $"First: {wipPlan.Errors[0].Message}");
            }

            // ---- Import: new POs land, duplicates skip --------------------------
            int posInserted, linesInserted;
            List<string> skipped;
            WipRunTotals wipTotals;
            using (var conn = _factory.Create())
            {
                conn.Open();
                (posInserted, linesInserted, skipped, wipTotals) =
                    await ImportGroupsAsync(conn, log, parse.Rows, wipPlan, safeActor, runId);
            }

            sw.Stop();
            var elapsedMs = (int)sw.ElapsedMilliseconds;

            await _logRepo.MarkSucceededAsync(runId, posInserted, linesInserted, elapsedMs, skipped);

            // A run that skipped nothing keeps the original ActionType, so the
            // dashboard's existing filters and the 12.7 smoke are unaffected.
            // 'po-import-partial' (17 chars — fits VARCHAR(32) since db/032;
            // it would have silently truncated under the original VARCHAR(16))
            // marks the runs an operator may want to look at: their file
            // carried POs that were already in the system.
            var actionType = skipped.Count > 0 ? "po-import-partial" : "po-import-succeeded";
            await _audit.WriteSystemAsync(
                safeActor, actionType, "PoImportLog", runId.ToString(),
                $"Imported {posInserted} PO(s) / {linesInserted} line(s) from {log.FileName} " +
                $"in {elapsedMs}ms; skipped {skipped.Count} duplicate PO(s){FormatSkipped(skipped)}" +
                wipTotals.AuditSuffix());

            _logger.LogInformation(
                "PoImport {RunId} succeeded: {Pos} POs, {Lines} lines, {Skipped} skipped, " +
                "WIP created={WipCreated} repaired={WipRepaired} skipped={WipSkipped} in {Elapsed}ms",
                runId, posInserted, linesInserted, skipped.Count,
                wipTotals.PullsCreated, wipTotals.PullsRepaired, wipTotals.PullsSkipped, elapsedMs);
        }
        catch (Exception ex)
        {
            sw.Stop();
            var elapsedMs = (int)sw.ElapsedMilliseconds;

            await _logRepo.MarkFailedAsync(runId, ex.Message, elapsedMs);
            await _audit.WriteSystemAsync(
                safeActor, "po-import-failed", "PoImportLog", runId.ToString(),
                $"Stage 2 aborted after {elapsedMs}ms. The failing PO rolled back, but PO(s) " +
                $"committed earlier in the run remain — re-upload the file to import the rest " +
                $"(the committed POs will skip as duplicates). Error: {Truncate(ex.Message, 300)}");

            _logger.LogError(ex,
                "PoImport {RunId} failed after {Elapsed}ms — failing PO rolled back; earlier POs in the run stay committed",
                runId, elapsedMs);

            // Rethrow so Hangfire records Failed state for the dashboard /
            // status drill-down. Note this does NOT re-run the import:
            // MarkFailedAsync just moved the row off 'queued', so every
            // AutomaticRetry attempt aborts at the status guard above. The
            // rethrow is for visibility only. Operator recovery is a
            // re-upload (fresh runId), where the POs that already committed
            // skip as duplicates.
            throw;
        }
    }

    // -------------------------------------------------------------------
    // Per-PO import loop. Splitting this out keeps RunAsync's control flow
    // (status transitions + audit + logging) separate from the SQL itself.
    // -------------------------------------------------------------------
    private async Task<(int posInserted, int linesInserted, List<string> skipped, WipRunTotals wip)> ImportGroupsAsync(
        IDbConnection conn, Models.Dtos.PoImportLogRow log, List<PoImportRow> rows,
        WipSynthesisPlan wipPlan, string actorName, Guid runId)
    {
        // Group by PoNumber preserving file order. The OrderBy on the first
        // row's index gives stable PO ordering for both audit and for
        // operator-eyeballing the result (matches the order in their sheet).
        var groups = rows
            .Select((r, idx) => (Row: r, Index: idx))
            .GroupBy(x => x.Row.PoNumber, StringComparer.OrdinalIgnoreCase)
            .OrderBy(g => g.Min(x => x.Index))
            .ToList();

        // Pre-filter: which PoNumbers are already in the system? PoNumber is
        // globally UNIQUE per db/010 — a WarehouseId filter would miss a
        // cross-warehouse collision, so this read is deliberately global.
        //
        // This is a PLAIN READ, and it is NOT the correctness guarantee.
        // Locking hints here would be theatre: each PO below commits in its
        // own transaction, so no lock taken here could still be held when
        // the inserts run. Its only job is to skip the duplicates we can see
        // up front, so the common case doesn't churn through failed INSERTs.
        // The race (someone commits the same PoNumber between this read and
        // our insert) is closed by UQ_PurchaseOrders_PoNumber and the 2627/
        // 2601 catch below — that unique index is the sole authority on
        // whether a PoNumber is a duplicate.
        var poNumbers = groups.Select(g => g.Key).ToList();
        var existing = new HashSet<string>(
            await conn.QueryAsync<string>(new CommandDefinition(@"
                SELECT PoNumber
                FROM   dbo.PurchaseOrders
                WHERE  PoNumber IN @PoNumbers;",
                new { PoNumbers = poNumbers })),
            StringComparer.OrdinalIgnoreCase);

        // OrderDate is required NOT NULL DATE; parser doesn't supply it.
        // Use the import's run date (today, UTC, date-only). Consistent
        // semantic: "the date this PO entered Receivx".
        var orderDate = DateTime.UtcNow.Date;

        int posInserted = 0, linesInserted = 0;
        var skipped = new List<string>();
        var wip = new WipRunTotals();

        foreach (var group in groups)
        {
            var firstRow = group.First().Row;

            // WIP pull sheets take the synthesis path instead of the ordinary
            // PO build: their PO lines are grouped 1:1 with the windows the
            // operator receives against, and the pull side is created in the
            // same transaction. The ordinary duplicate pre-filter does not
            // apply — "PO exists" is not automatically a skip here; a PO
            // whose pull was never created is the stuck state this exists to
            // repair.
            var wipSheet = wipPlan.Find(group.Key);
            if (wipSheet is not null)
            {
                var (poCount, lineCount) = await SynthesiseWipSheetAsync(
                    conn, log, wipSheet, wip, actorName, runId);
                posInserted += poCount;
                linesInserted += lineCount;
                continue;
            }

            if (existing.Contains(group.Key))
            {
                skipped.Add(group.Key);
                _logger.LogInformation(
                    "PoImport {RunId} — PoNumber {PoNumber} already exists; skipping group ({Lines} line(s)).",
                    log.RunId, group.Key, group.Count());
                continue;
            }

            using var tx = conn.BeginTransaction();
            try
            {
                var lineCount = await InsertOneGroupAsync(
                    conn, tx, log, firstRow, group, orderDate);
                tx.Commit();
                posInserted++;
                linesInserted += lineCount;
            }
            catch (SqlException ex) when (ex.Number is 2627 or 2601)
            {
                // Lost the race: someone committed this PoNumber between the
                // pre-filter read and now. UQ_PurchaseOrders_PoNumber caught
                // it. Same outcome as a pre-filtered duplicate — skip, don't
                // fail the run.
                tx.Rollback();
                skipped.Add(group.Key);
                _logger.LogInformation(ex,
                    "PoImport {RunId} — PoNumber {PoNumber} hit a unique violation (concurrent import); skipping.",
                    log.RunId, group.Key);
            }
            catch
            {
                // Anything else is a genuine error — roll this PO back and
                // fail the run. POs committed earlier stay committed.
                tx.Rollback();
                throw;
            }
        }

        return (posInserted, linesInserted, skipped, wip);
    }

    // -------------------------------------------------------------------
    // One WIP pull sheet: pull + items + windows (+ PO and its grouped lines
    // unless the PO is already there), all inside ONE transaction. A
    // half-built pull with no PO, or a PO with no pull, is worse than a
    // failed import — so this either lands whole or not at all.
    //
    // Returns what to add to the run's PO/line counters: a repair creates no
    // PO and no lines, so it contributes (0, 0).
    // -------------------------------------------------------------------
    private async Task<(int poCount, int lineCount)> SynthesiseWipSheetAsync(
        IDbConnection conn, Models.Dtos.PoImportLogRow log, WipPullPlan plan,
        WipRunTotals totals, string actorName, Guid runId)
    {
        using var tx = conn.BeginTransaction();
        try
        {
            // Re-classify HERE, under UPDLOCK, inside the transaction. Stage
            // 1's preview was read-only and advisory; between the preview and
            // this moment another import (or the ERP) may have created the
            // pull. This read is the authority.
            var states = await WipSynthesisWriter.ClassifyAsync(
                conn, tx, new[] { plan.PullNumber }, lockRows: true);
            var action = states.TryGetValue(plan.PullNumber, out var st)
                ? st.Action
                : WipSheetAction.Create;

            if (action == WipSheetAction.Skip)
            {
                // Nothing was written, so roll the (empty) transaction back
                // and record the skip standalone — the same shape
                // ErpUpsertService uses for its closed-pull skip.
                tx.Rollback();
                totals.PullsSkipped++;
                await _audit.WriteSystemAsync(
                    actorName, "pull-synth-skip", "Pull", plan.PullNumber,
                    $"[run {runId}] WIP pull sheet already exists — nothing written. " +
                    "Re-importing the same export is expected and must not double anything.");
                _logger.LogInformation(
                    "PoImport {RunId} — WIP pull {PullNumber} already exists; skipping synthesis.",
                    log.RunId, plan.PullNumber);
                return (0, 0);
            }

            var outcome = await WipSynthesisWriter.ApplyAsync(
                conn, tx, plan, action, log.WarehouseId, log.UploadedByUserId);

            // Audit INSIDE the transaction so the trail commits or rolls back
            // with the rows it describes (ErpUpsertService's etl-create rule).
            // This is the record that answers "why does this pull have a PO
            // nobody in procurement remembers issuing" three months from now.
            var isRepair = action == WipSheetAction.Repair;
            await _audit.WriteSystemAsync(
                conn, tx, actorName,
                isRepair ? "pull-synth-repair" : "pull-synthesized",
                "Pull", plan.PullNumber,
                $"[run {runId}] " +
                (isRepair
                    ? "Repaired WIP pull sheet — the PO was already imported but no pull existed; " +
                      "built the pull side only and left the existing PO and its lines untouched. "
                    : "Synthesised WIP pull sheet from the PO import — no ERP Receive feed exists for WIP storer codes. ") +
                $"items={outcome.ItemsCreated}, windows={outcome.WindowsCreated}, " +
                $"qty={outcome.TotalQty}, vendor={plan.VendorCodeRaw ?? "(none)"}, " +
                $"po={(outcome.PurchaseOrderId is null ? "(pre-existing)" : $"created with {outcome.LinesCreated} line(s)")}, " +
                $"file={log.FileName}");

            tx.Commit();

            if (isRepair) totals.PullsRepaired++; else totals.PullsCreated++;
            totals.ItemsCreated += outcome.ItemsCreated;
            totals.WindowsCreated += outcome.WindowsCreated;
            totals.QtyPlanned += outcome.TotalQty;

            _logger.LogInformation(
                "PoImport {RunId} — WIP pull {PullNumber} {Action}: {Items} item(s), {Windows} window(s), {Qty} unit(s).",
                log.RunId, plan.PullNumber, isRepair ? "repaired" : "created",
                outcome.ItemsCreated, outcome.WindowsCreated, outcome.TotalQty);

            return (outcome.PurchaseOrderId is null ? 0 : 1, outcome.LinesCreated);
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            // Lost a race against a concurrent import that created the same
            // pull or PO between the UPDLOCK read and the insert. Same
            // outcome as a classified skip — this file has nothing to add.
            tx.Rollback();
            totals.PullsSkipped++;
            _logger.LogInformation(ex,
                "PoImport {RunId} — WIP pull {PullNumber} hit a unique violation (concurrent import); skipping.",
                log.RunId, plan.PullNumber);
            return (0, 0);
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // -------------------------------------------------------------------
    // Inserts ONE PurchaseOrder + its lines inside the caller's transaction.
    // Every invariant here is unchanged from the all-or-nothing version.
    // -------------------------------------------------------------------
    private async Task<int> InsertOneGroupAsync(
        IDbConnection conn, IDbTransaction tx, Models.Dtos.PoImportLogRow log,
        PoImportRow firstRow, IEnumerable<(PoImportRow Row, int Index)> group,
        DateTime orderDate)
    {
        // Phase 14: vendor moved to PurchaseOrderLines. The v3.2 behavior
        // of "take firstRow.VendorCode for the whole PO" silently lost
        // lines 2..N's vendor whenever the workbook carried mixed vendors
        // under a single PRS_ID — which is a real production case.
        // Each line now writes its own VendorCode/Name below.
        var newPoId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
            INSERT INTO dbo.PurchaseOrders
                (Id, PoNumber, WarehouseId, PullId, PullExternalRef,
                 OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt)
            OUTPUT INSERTED.Id
            VALUES
                (NEWID(), @PoNumber, @WarehouseId, NULL, @PullExternalRef,
                 @OrderDate, NULL, 'open', NULL, @CreatedBy, SYSUTCDATETIME());",
            new
            {
                firstRow.PoNumber,
                log.WarehouseId,
                PullExternalRef = firstRow.PoNumber,   // db/033 — Q1=B denormalized
                OrderDate = orderDate,
                CreatedBy = log.UploadedByUserId,
            }, transaction: tx));

        int lineNumber = 0;
        foreach (var (row, _) in group)
        {
            lineNumber++;

            // 27 parser fields (Phase 14 vendor + db/040 SourcePoNo)
            // + 4 server-set fields (Id, PoId, LineNumber, ReceivedQty=0).
            // Description NOT NULL — coalesce parser null.
            await conn.ExecuteAsync(new CommandDefinition(@"
                INSERT INTO dbo.PurchaseOrderLines (
                    Id, PurchaseOrderId, LineNumber,
                    ItemCode, Description, OrderedQty, ReceivedQty,
                    VendorCode, VendorName,
                    OrderId, SourcePoNo, AsnNo, InvoiceNo, KanbanNo, PCCNo, BatchNo,
                    ManufacturingControlNo, ManufacturingReferenceNo,
                    CustomerReferenceNo, ExportDeclarationNo, VendorItem,
                    PalletId, VmiPalletId, Location, Building, SubInventory, ToLocation,
                    ProductionLine, OrderRound, DeliveryDate, Note
                ) VALUES (
                    NEWID(), @PoId, @LineNumber,
                    @ItemCode, @Description, @OrderedQty, 0,
                    @VendorCode, @VendorName,
                    @OrderId, @SourcePoNo, @AsnNo, @InvoiceNo, @KanbanNo, @PCCNo, @BatchNo,
                    @ManufacturingControlNo, @ManufacturingReferenceNo,
                    @CustomerReferenceNo, @ExportDeclarationNo, @VendorItem,
                    @PalletId, @VmiPalletId, @Location, @Building, @SubInventory, @ToLocation,
                    @ProductionLine, @OrderRound, @DeliveryDate, @Note
                );",
                new
                {
                    PoId = newPoId,
                    LineNumber = lineNumber,
                    row.ItemCode,
                    Description = row.Description ?? "",
                    row.OrderedQty,
                    row.VendorCode, row.VendorName,
                    row.OrderId, row.SourcePoNo, row.AsnNo, row.InvoiceNo, row.KanbanNo,
                    row.PCCNo, row.BatchNo,
                    row.ManufacturingControlNo, row.ManufacturingReferenceNo,
                    row.CustomerReferenceNo, row.ExportDeclarationNo, row.VendorItem,
                    row.PalletId, row.VmiPalletId, row.Location, row.Building,
                    row.SubInventory, row.ToLocation,
                    row.ProductionLine, row.OrderRound, row.DeliveryDate, row.Note,
                }, transaction: tx));
        }

        return lineNumber;
    }

    /// <summary>
    /// Names the skipped POs in the audit detail, capped so a file that is
    /// entirely duplicates can't write an unbounded audit message. The full
    /// list always lands in PoImportLog.SkippedPoNumbers (db/046).
    /// </summary>
    private static string FormatSkipped(List<string> skipped)
    {
        if (skipped.Count == 0) return "";
        const int cap = 10;
        var head = string.Join(", ", skipped.Take(cap));
        var more = skipped.Count > cap ? $" (+{skipped.Count - cap} more)" : "";
        return $": {head}{more}";
    }

    private static string Truncate(string s, int max)
        => string.IsNullOrEmpty(s) ? "" : (s.Length > max ? s[..max] + "…" : s);
}
