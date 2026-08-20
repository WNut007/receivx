using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Services;
using ReceivingOps.Web.Services.ErpSync;

// ---------------------------------------------------------------------------
// ErpUpsertHarness — executes ErpUpsertService.UpsertAsync against the dev DB
// with a hand-built draft, with no ERP host in the loop.
//
// WHY THIS EXISTS
//
// Nothing in the repository executed the ETL. smoke-phase-10-2 and 10-3 assert
// on SOURCE TEXT; smoke-phase-10-7 skips whenever 103.13.229.21 is unreachable,
// which is any machine without the VPN. That gap is precisely why
// ErpUpsertService's `existing.ToDictionary(e => e.ItemCode)` could sit in the
// tree ready to throw ArgumentException the first time a pull legitimately held
// two storers' rows for one SKU: the only path that could have proven it needed
// a network nobody has at their desk.
//
// A draft is just POCOs (ErpSyncDraft / PullDraft / PullItemDraft), so the
// upsert can be driven directly. The ERP is only the thing that PRODUCES a
// draft; it is not needed to CONSUME one.
//
// USAGE
//   dotnet run --project tools/ErpUpsertHarness -- <scenario> [connection-string]
//
//   two-storer-insert   two same-SKU items on a fresh pull, different storers
//   two-storer-update   the same, applied to a pull that already holds one
//   rerun-stable        the same draft twice; second run must add/cancel nothing
//   withdraw-one-storer storer B removed from the draft; only B may cancel
//
//   transform-wip-sheet     an all-WIP sheet produces no pull
//   transform-wip-mixed     a mixed WIP/non-WIP sheet produces no pull either
//   transform-wip-casing    WIP detection is case-insensitive substring
//   transform-wip-and-clean a WIP sheet does not disturb an ordinary one
//
// Output is one JSON object on stdout so the smoke can assert on it, plus
// human-readable lines on stderr. Exit code 0 = scenario ran (assertions are
// the smoke's job), 2 = harness/infrastructure failure.
//
// THIS IS NOT INERT. It opens the dev database and WRITES: it inserts and
// deletes dbo.Pulls / dbo.PullItems / dbo.PullItemWindows rows, and the ETL it
// drives writes real dbo.AuditLog rows (etl-create / etl-update / etl-error /
// etl-cancel-synth) through a stand-in IAuditService. Point it at production
// and it will happily edit production. Fixtures are namespaced HARNESS- and
// purged on entry and exit — set HARNESS_KEEP=1 to leave them for inspection.
//
// Its own audit writer had a bug on first run (NEWID() into AuditLog.Id, which
// is BIGINT IDENTITY) that masked the ETL's outcome behind a SqlException. If
// something here looks impossible, suspect the harness before the code under
// test.
// ---------------------------------------------------------------------------

var scenario = args.Length > 0 ? args[0] : "two-storer-insert";
var connStr = args.Length > 1
    ? args[1]
    : "Server=LAPTOP-CSB3KO3E;Database=ReceivingOps;Integrated Security=True;"
      + "TrustServerCertificate=True;Encrypt=False;Application Name=ErpUpsertHarness;";

const string PullNumber = "HARNESS-STORER-1";
const string ItemCode = "HARNESS-SKU-A";
const string StorerA = "5732";           // stripped form, as BPI_PRS.VENDOR emits it
const string StorerB = "84600";
var warehouseId = Guid.Parse("22222222-2222-2222-2222-000000000001");

void Log(string m) => Console.Error.WriteLine($"[harness] {m}");

// Transform scenarios need no database at all: BpiPrsSource.Transform is a pure
// function from ERP rows to a draft, and the storer-grain grouping fix lives
// there. Handled before the DB is touched so they run anywhere.
if (scenario.StartsWith("transform-", StringComparison.Ordinal))
{
    return TransformScenarios.RunTransform(scenario, warehouseId);
}

try
{
    var factory = new HarnessConnectionFactory(connStr);
    using (var seed = factory.Create())
    {
        seed.Open();
        Purge(seed);

        // Every scenario except the plain insert needs the pull to already
        // exist, because the defect lives in the UPDATE path's diff.
        if (scenario != "two-storer-insert")
            SeedPull(seed, scenario);
    }

    // Logs go to stderr so stdout stays a single clean JSON line for the smoke
    // to parse. AddConsole writes to stdout, so it is deliberately not used.
    var logger = LoggerFactory
        .Create(b => b.AddProvider(new StderrLoggerProvider()))
        .CreateLogger<ErpUpsertService>();

    var service = new ErpUpsertService(factory, new HarnessAuditService(factory), logger);

    var draft = BuildDraft(scenario, warehouseId);
    var runId = Guid.Parse("00000000-0000-0000-0000-0000000000AA");

    string? threw = null;
    ErpUpsertResult? result = null;
    try
    {
        result = await service.UpsertAsync(draft, runId, "[harness]", "BPI_PRS");
    }
    catch (Exception ex)
    {
        // UpsertAsync has a per-pull catchall, so an ArgumentException from the
        // dictionary is recorded as an outcome rather than thrown. Capture both
        // shapes: the smoke asserts on whichever the build produces.
        threw = $"{ex.GetType().Name}: {ex.Message}";
    }

    using var read = factory.Create();
    read.Open();
    var items = (await read.QueryAsync<ItemRow>(@"
        SELECT pi.ItemCode, pi.VendorCode, pi.Status, pi.SortOrder,
               ISNULL((SELECT SUM(w.ExpectedQty) FROM dbo.PullItemWindows w
                       WHERE w.PullItemId = pi.Id), 0) AS ExpectedQty
        FROM   dbo.PullItems pi
        INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
        WHERE  p.PullNumber = @PullNumber
        ORDER BY pi.SortOrder, pi.VendorCode;", new { PullNumber })).AsList();

    var outcome = new
    {
        scenario,
        threw,
        errors = result?.Errors ?? -1,
        created = result?.Created ?? -1,
        updated = result?.Updated ?? -1,
        itemsAdded = result?.ItemsAdded ?? -1,
        itemsCanceled = result?.ItemsCanceled ?? -1,
        outcomes = result?.PullOutcomes.Select(o => new { o.PullNumber, o.Outcome, o.Detail }),
        items,
    };

    Console.WriteLine(JsonSerializer.Serialize(outcome, new JsonSerializerOptions { WriteIndented = false }));
    Log($"scenario '{scenario}' finished — {items.Count} item(s) on {PullNumber}"
        + (threw is null ? "" : $", THREW {threw}"));

    if (Environment.GetEnvironmentVariable("HARNESS_KEEP") != "1")
    {
        using var cleanup = factory.Create();
        cleanup.Open();
        Purge(cleanup);
    }
    return 0;
}
catch (Exception ex)
{
    Log($"HARNESS FAILURE: {ex}");
    return 2;
}

// ---------------------------------------------------------------------------

void Purge(System.Data.IDbConnection conn) => conn.Execute(@"
    DELETE w FROM dbo.PullItemWindows w
      INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
      INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
    WHERE p.PullNumber LIKE 'HARNESS-%';
    DELETE pi FROM dbo.PullItems pi
      INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
    WHERE p.PullNumber LIKE 'HARNESS-%';
    DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'HARNESS-%';
    DELETE FROM dbo.AuditLog WHERE EntityId LIKE 'HARNESS-%';");

// Seeds the pull as it would exist BEFORE the run under test.
//   rerun-stable / withdraw-one-storer: both storers already present, which is
//     the post-storer-grain steady state.
//   two-storer-update: only storer A present, so the run must ADD B — and the
//     dictionary at the top of the diff is built from a single-SKU set, which
//     is the shape that used to be the only one possible.
void SeedPull(System.Data.IDbConnection conn, string sc)
{
    var pullId = conn.QuerySingle<Guid>(@"
        INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status,
                               LockPoByPull, LockHourCap, CreatedBy)
        OUTPUT INSERTED.Id
        VALUES (NEWID(), @PullNumber, @WarehouseId, CAST(SYSUTCDATETIME() AS DATE),
                'pending', 1, 1, NULL);",
        new { PullNumber, WarehouseId = warehouseId });

    var storers = sc == "two-storer-update"
        ? new[] { StorerA }
        : new[] { StorerA, StorerB };

    var sort = 0;
    foreach (var storer in storers)
    {
        sort++;
        var itemId = conn.QuerySingle<Guid>(@"
            INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode,
                                       Tag, Status, Remark, SortOrder)
            OUTPUT INSERTED.Id
            VALUES (NEWID(), @PullId, @ItemCode, 'harness item', @VendorCode,
                    NULL, 'normal', NULL, @SortOrder);",
            new { PullId = pullId, ItemCode, VendorCode = storer, SortOrder = sort });

        conn.Execute(@"
            INSERT INTO dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
            VALUES (NEWID(), @PullItemId, 7, 100, 0);", new { PullItemId = itemId });
    }
}

// Both storers on the SAME hour — the 60-case shape from the brief, and the one
// the SKU-only key collapsed hardest.
ErpSyncDraft BuildDraft(string sc, Guid whId)
{
    var pull = new PullDraft
    {
        PullNumber = PullNumber,
        WarehouseId = whId,
        PullDate = DateTime.UtcNow.Date,
    };

    var storers = sc == "withdraw-one-storer"
        ? new[] { StorerA }                  // B withdrawn: only B may cancel
        : new[] { StorerA, StorerB };

    foreach (var storer in storers)
    {
        var item = new PullItemDraft
        {
            ItemCode = ItemCode,             // bare SKU on BOTH — that is the point
            Description = "harness item",
            VendorCode = storer,
        };
        item.Windows.Add(new PullItemWindowDraft { HourOfDay = 7, ExpectedQty = 100 });
        pull.Items.Add(item);
    }

    var draft = new ErpSyncDraft { SourceRowCount = pull.Items.Count };
    draft.Pulls.Add(pull);
    return draft;
}

sealed record ItemRow(string ItemCode, string? VendorCode, string Status, int SortOrder, int ExpectedQty);

sealed class HarnessConnectionFactory(string connStr) : IDbConnectionFactory
{
    public System.Data.IDbConnection Create() => new SqlConnection(connStr);
}

// The real IAuditService needs IHttpContextAccessor and a scope; the ETL only
// uses the WriteSystemAsync overloads, so this stands in for them and records
// what was written so the smoke can assert on etl-cancel-synth.
sealed class HarnessAuditService(IDbConnectionFactory factory) : IAuditService
{
    public Task WriteAsync(string actionType, string? entityType, string? entityId,
        string message, CancellationToken ct = default)
        => WriteSystemAsync("[harness]", actionType, entityType, entityId, message, ct);

    public Task WriteAsync(System.Data.IDbConnection conn, System.Data.IDbTransaction? tx,
        string actionType, string? entityType, string? entityId, string message,
        CancellationToken ct = default)
        => WriteSystemAsync(conn, tx, "[harness]", actionType, entityType, entityId, message, ct);

    public async Task WriteSystemAsync(System.Data.IDbConnection conn, System.Data.IDbTransaction? tx,
        string actorName, string actionType, string? entityType, string? entityId,
        string message, CancellationToken ct = default)
        => await conn.ExecuteAsync(new CommandDefinition(Sql,
            new { ActionType = actionType, EntityType = entityType, EntityId = entityId,
                  Message = message, ActorName = actorName },
            transaction: tx, cancellationToken: ct));

    public async Task WriteSystemAsync(string actorName, string actionType,
        string? entityType, string? entityId, string message, CancellationToken ct = default)
    {
        using var conn = factory.Create();
        conn.Open();
        await conn.ExecuteAsync(new CommandDefinition(Sql,
            new { ActionType = actionType, EntityType = entityType, EntityId = entityId,
                  Message = message, ActorName = actorName },
            cancellationToken: ct));
    }

    // Id is a BIGINT IDENTITY — it must NOT be supplied.
    private const string Sql = @"
        INSERT INTO dbo.AuditLog (OccurredAt, ActorUserId, ActorName, ActionType,
                                  EntityType, EntityId, Message)
        VALUES (SYSUTCDATETIME(), NULL, @ActorName, @ActionType,
                @EntityType, @EntityId, @Message);";
}

// Minimal stderr logger: the ETL logs a warning per failed pull, and that text
// is diagnostic gold when a scenario misbehaves — but it must not contaminate
// stdout, which carries the JSON the smoke parses.
sealed class StderrLoggerProvider : ILoggerProvider
{
    public ILogger CreateLogger(string categoryName) => new StderrLogger(categoryName);
    public void Dispose() { }

    private sealed class StderrLogger(string category) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state,
            Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;
            Console.Error.WriteLine($"[{logLevel}] {category}: {formatter(state, exception)}");
            if (exception is not null) Console.Error.WriteLine(exception.ToString());
        }
    }
}

// ---------------------------------------------------------------------------
// Transform scenarios — the grouping fix itself, exercised with hand-crafted
// BPI_PRS rows. No database, no ERP.
//
//   transform-two-storers    same SKU, two storers, SAME hour → 2 items, each
//                            with its own quantity (the §1 defect, and the
//                            60-case same-ROUND shape)
//   transform-same-storer    same SKU, SAME storer, 3 rows → 1 item, summed
//                            (the over-split guard)
//   transform-single-storer  a single-storer pull → unchanged shape
// ---------------------------------------------------------------------------
static class TransformScenarios
{
    internal static int RunTransform(string scenario, Guid warehouseId)
{
    var logger = LoggerFactory.Create(b => b.AddProvider(new StderrLoggerProvider()))
        .CreateLogger<BpiPrsSource>();

    var rows = scenario switch
    {
        "transform-two-storers" => new List<BpiPrsSource.BpiPrsRow>
        {
            Row("HARNESS-T1", "HARNESS-SKU-A", "5732",  100, "07:00"),
            Row("HARNESS-T1", "HARNESS-SKU-A", "84600", 250, "07:00"),
        },
        "transform-same-storer" => new List<BpiPrsSource.BpiPrsRow>
        {
            Row("HARNESS-T2", "HARNESS-SKU-A", "5732", 100, "07:00"),
            Row("HARNESS-T2", "HARNESS-SKU-A", "5732",  40, "07:00"),
            Row("HARNESS-T2", "HARNESS-SKU-A", "5732",  10, "07:00"),
        },
        "transform-single-storer" => new List<BpiPrsSource.BpiPrsRow>
        {
            Row("HARNESS-T3", "HARNESS-SKU-A", "5732", 100, "07:00"),
            Row("HARNESS-T3", "HARNESS-SKU-B", "5732", 200, "08:00"),
        },
        // ------------------------------------------------------------------
        // WIP sheet filter (sheet grain). WIP pulls are built by the PO
        // import; the ERP feed must not create, update, or take one over.
        // ------------------------------------------------------------------

        // An all-WIP sheet: nothing survives, counters record what went.
        "transform-wip-sheet" => new List<BpiPrsSource.BpiPrsRow>
        {
            Row("HARNESS-W1", "HARNESS-SKU-A", "WIPBP1", 100, "07:00"),
            Row("HARNESS-W1", "HARNESS-SKU-B", "WIPBP1", 250, "08:00"),
        },

        // THE case the sheet grain exists for. A row-grain filter would leave
        // this sheet in the draft carrying only its non-WIP item, and the
        // upsert's orphan pass would then cancel the WIP item on the pull —
        // canceling stock whose PO line may already carry ReceivedQty. Sheet
        // grain drops the whole thing, so no pull is produced at all.
        //
        // Both non-WIP rows carry a positive QTY on purpose: the real upstream
        // mixed sheet (0000023492) escapes a row-grain filter only because its
        // one non-WIP row has QTY = 0 and the qty guard drops it anyway. Testing
        // with a zero would test the luck, not the rule.
        "transform-wip-mixed" => new List<BpiPrsSource.BpiPrsRow>
        {
            Row("HARNESS-W2", "HARNESS-SKU-A", "WIPBP3", 500, "07:00"),
            Row("HARNESS-W2", "HARNESS-SKU-B", "76575",  900, "07:00"),
            Row("HARNESS-W2", "HARNESS-SKU-C", "76575",  740, "09:00"),
        },

        // Case-insensitivity + substring, matching WipPullSynthesis.IsWipStorerCode.
        // A code that merely CONTAINS wip in any casing is a WIP storer; the
        // importer decides the same way, and the two must not drift.
        "transform-wip-casing" => new List<BpiPrsSource.BpiPrsRow>
        {
            Row("HARNESS-W3", "HARNESS-SKU-A", "coi-WiPbp1", 100, "07:00"),
        },

        // A WIP sheet and an ordinary sheet in one batch: the ordinary one must
        // come through completely untouched, items and quantities intact.
        "transform-wip-and-clean" => new List<BpiPrsSource.BpiPrsRow>
        {
            Row("HARNESS-W4-WIP",   "HARNESS-SKU-A", "WIPBP1", 100, "07:00"),
            Row("HARNESS-W4-CLEAN", "HARNESS-SKU-A", "5732",   300, "07:00"),
            Row("HARNESS-W4-CLEAN", "HARNESS-SKU-B", "84600",  450, "11:00"),
        },

        _ => throw new ArgumentException($"unknown transform scenario '{scenario}'"),
    };

    // Options are only read by the READ path (backfill window); Transform never
    // touches them, which is what makes it testable without any of this.
    var options = Microsoft.Extensions.Options.Options.Create(new ErpSyncOptions());
    var draft = new BpiPrsSource(new NullErpDbConnectionFactory(), options, logger)
        .Transform(warehouseId, rows);

    var shaped = draft.Pulls.Select(p => new
    {
        p.PullNumber,
        items = p.Items.Select(i => new
        {
            i.ItemCode,
            i.VendorCode,
            qty = i.Windows.Sum(w => w.ExpectedQty),
            hours = i.Windows.Select(w => (int)w.HourOfDay).OrderBy(h => h).ToArray(),
        }),
    });

    // Counters ride along with the pulls: a filter that drops rows silently is
    // indistinguishable from a feed that shrank, so the smoke asserts on both
    // what survived and what was reported as dropped.
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        scenario,
        pulls = shaped,
        skippedRowCount = draft.SkippedRowCount,
        wipSkippedRowCount = draft.WipSkippedRowCount,
        wipSkippedPullCount = draft.WipSkippedPullCount,
        wipMixedPullCount = draft.WipMixedPullCount,
        wipMixedNonWipRowCount = draft.WipMixedNonWipRowCount,
        wipMixedNonWipQty = draft.WipMixedNonWipQty,
        wipMixedPullNumbers = draft.WipMixedPullNumbers,
    }));
    Console.Error.WriteLine($"[harness] transform '{scenario}': "
        + $"{draft.Pulls.Sum(p => p.Items.Count)} item(s) from {rows.Count} row(s); "
        + $"wipSkipped={draft.WipSkippedRowCount} row(s) / {draft.WipSkippedPullCount} sheet(s), "
        + $"mixed={draft.WipMixedPullCount}");
    return 0;
    }

    internal static BpiPrsSource.BpiPrsRow Row(string prs, string sku, string vendor, int qty, string window) =>
    new()
    {
        PRS_ID = prs,
        SKU = sku,
        VENDOR = vendor,
        DESCR = "harness item",
        QTY = qty,
        WINDOWS_TIME = window,
        DeliveryDate = new DateTime(2026, 8, 19),
    };
}

// BpiPrsSource's constructor wants an ERP connection factory, but Transform
// never touches it — it is a pure function over rows already read.
sealed class NullErpDbConnectionFactory : IErpDbConnectionFactory
{
    public System.Data.IDbConnection Create() =>
        throw new InvalidOperationException(
            "Transform must not open an ERP connection — that is the point of exercising it directly.");
}
