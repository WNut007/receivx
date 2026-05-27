using System.Data;
using System.Diagnostics;
using Dapper;
using Hangfire;
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
///   <item>Inside ONE transaction (Q3=A atomic): re-check duplicates
///         (PoNumber is globally unique per schema), group by PoNumber,
///         insert one PurchaseOrder + N PurchaseOrderLines per group.</item>
///   <item><see cref="IPoImportLogRepository.MarkSucceededAsync"/> +
///         audit 'po-import-succeeded'.</item>
/// </list>
///
/// <para>On any exception during Stage 2 the transaction rolls back
/// (so nothing partial commits), the log row is marked failed with the
/// truncated error message, an audit row 'po-import-failed' is written,
/// and the exception rethrows so Hangfire records the job as Failed
/// (which lets <c>[AutomaticRetry]</c> kick in — though for atomic
/// imports we leave the default Attempts=10 since the data error is
/// reproducible and retries would just spam failures).</para>
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

            // ---- Atomic insert -------------------------------------------------
            int posInserted, linesInserted;
            using (var conn = _factory.Create())
            {
                conn.Open();
                using var tx = conn.BeginTransaction();
                try
                {
                    (posInserted, linesInserted) = await InsertAllAsync(conn, tx, log, parse.Rows);
                    tx.Commit();
                }
                catch
                {
                    tx.Rollback();
                    throw;
                }
            }

            sw.Stop();
            var elapsedMs = (int)sw.ElapsedMilliseconds;

            await _logRepo.MarkSucceededAsync(runId, posInserted, linesInserted, elapsedMs);
            await _audit.WriteSystemAsync(
                safeActor, "po-import-succeeded", "PoImportLog", runId.ToString(),
                $"Imported {posInserted} PO(s) / {linesInserted} line(s) from {log.FileName} in {elapsedMs}ms");

            _logger.LogInformation(
                "PoImport {RunId} succeeded: {Pos} POs, {Lines} lines in {Elapsed}ms",
                runId, posInserted, linesInserted, elapsedMs);
        }
        catch (Exception ex)
        {
            sw.Stop();
            var elapsedMs = (int)sw.ElapsedMilliseconds;

            await _logRepo.MarkFailedAsync(runId, ex.Message, elapsedMs);
            await _audit.WriteSystemAsync(
                safeActor, "po-import-failed", "PoImportLog", runId.ToString(),
                $"Stage 2 rolled back after {elapsedMs}ms — no partial state. Error: {Truncate(ex.Message, 300)}");

            _logger.LogError(ex,
                "PoImport {RunId} failed after {Elapsed}ms — tx rolled back, no partial state",
                runId, elapsedMs);

            // Rethrow so Hangfire records Failed state for the dashboard /
            // status drill-down. AutomaticRetry default applies; for atomic
            // data errors the retries will fail identically — acceptable
            // cost for visibility.
            throw;
        }
    }

    // -------------------------------------------------------------------
    // Inside-tx insert. Splitting this out keeps RunAsync's control flow
    // (status transitions + audit + logging) separate from the SQL itself.
    // -------------------------------------------------------------------
    private async Task<(int posInserted, int linesInserted)> InsertAllAsync(
        IDbConnection conn, IDbTransaction tx, Models.Dtos.PoImportLogRow log,
        List<PoImportRow> rows)
    {
        // Group by PoNumber preserving file order. The OrderBy on the first
        // row's index gives stable PO ordering for both audit and for
        // operator-eyeballing the result (matches the order in their sheet).
        var groups = rows
            .Select((r, idx) => (Row: r, Index: idx))
            .GroupBy(x => x.Row.PoNumber, StringComparer.OrdinalIgnoreCase)
            .OrderBy(g => g.Min(x => x.Index))
            .ToList();

        // Re-check duplicates inside the tx. PoNumber is globally UNIQUE per
        // db/010 — the WH filter the v3.2 spec suggested would miss a
        // cross-warehouse collision. Stage 1 dedupes within the file; this
        // catches the race where another operator imported the same PoNumber
        // between validate-time and run-time.
        var poNumbers = groups.Select(g => g.Key).ToList();
        var existing = (await conn.QueryAsync<string>(new CommandDefinition(@"
            SELECT PoNumber
            FROM   dbo.PurchaseOrders WITH (UPDLOCK, ROWLOCK)
            WHERE  PoNumber IN @PoNumbers;",
            new { PoNumbers = poNumbers }, transaction: tx))).ToList();

        if (existing.Count > 0)
        {
            var head = string.Join(", ", existing.Take(5));
            var more = existing.Count > 5 ? $" (+{existing.Count - 5} more)" : "";
            throw new InvalidOperationException(
                $"PoNumber already exists in dbo.PurchaseOrders: {head}{more}. " +
                "Another import may have committed the same PoNumber after Stage 1 validation.");
        }

        // OrderDate is required NOT NULL DATE; parser doesn't supply it.
        // Use the import's run date (today, UTC, date-only). Consistent
        // semantic: "the date this PO entered Receivx".
        var orderDate = DateTime.UtcNow.Date;

        int posInserted = 0, linesInserted = 0;

        foreach (var group in groups)
        {
            var firstRow = group.First().Row;

            var newPoId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.PurchaseOrders
                    (Id, PoNumber, WarehouseId, PullId, PullExternalRef,
                     VendorCode, VendorName,
                     OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt)
                OUTPUT INSERTED.Id
                VALUES
                    (NEWID(), @PoNumber, @WarehouseId, NULL, @PullExternalRef,
                     @VendorCode, @VendorName,
                     @OrderDate, NULL, 'open', NULL, @CreatedBy, SYSUTCDATETIME());",
                new
                {
                    firstRow.PoNumber,
                    log.WarehouseId,
                    PullExternalRef = firstRow.PoNumber,   // db/033 — Q1=B denormalized
                    firstRow.VendorCode,
                    firstRow.VendorName,
                    OrderDate = orderDate,
                    CreatedBy = log.UploadedByUserId,
                }, transaction: tx));

            posInserted++;

            int lineNumber = 0;
            foreach (var (row, _) in group)
            {
                lineNumber++;

                // 24 parser fields + 4 server-set fields (Id, PoId, LineNumber,
                // ReceivedQty=0). Description NOT NULL — coalesce parser null.
                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.PurchaseOrderLines (
                        Id, PurchaseOrderId, LineNumber,
                        ItemCode, Description, OrderedQty, ReceivedQty,
                        OrderId, AsnNo, InvoiceNo, KanbanNo, PCCNo, BatchNo,
                        ManufacturingControlNo, ManufacturingReferenceNo,
                        CustomerReferenceNo, ExportDeclarationNo, VendorItem,
                        PalletId, VmiPalletId, Location, Building, SubInventory, ToLocation,
                        ProductionLine, OrderRound, DeliveryDate, Note
                    ) VALUES (
                        NEWID(), @PoId, @LineNumber,
                        @ItemCode, @Description, @OrderedQty, 0,
                        @OrderId, @AsnNo, @InvoiceNo, @KanbanNo, @PCCNo, @BatchNo,
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
                        row.OrderId, row.AsnNo, row.InvoiceNo, row.KanbanNo,
                        row.PCCNo, row.BatchNo,
                        row.ManufacturingControlNo, row.ManufacturingReferenceNo,
                        row.CustomerReferenceNo, row.ExportDeclarationNo, row.VendorItem,
                        row.PalletId, row.VmiPalletId, row.Location, row.Building,
                        row.SubInventory, row.ToLocation,
                        row.ProductionLine, row.OrderRound, row.DeliveryDate, row.Note,
                    }, transaction: tx));

                linesInserted++;
            }
        }

        return (posInserted, linesInserted);
    }

    private static string Truncate(string s, int max)
        => string.IsNullOrEmpty(s) ? "" : (s.Length > max ? s[..max] + "…" : s);
}
