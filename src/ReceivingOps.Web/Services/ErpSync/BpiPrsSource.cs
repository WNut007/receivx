using Dapper;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data;

namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 13.2 — BPI_PRS reader + transform. Body relocated from the v3.2
/// <c>ErpSyncService</c> (pure refactor; no behavior change). Implements
/// <see cref="IErpSource"/> so the Phase 13.5 fan-out loop can iterate it
/// alongside <c>PrbPrsSource</c>.
///
/// <para>SQL + Transform are unchanged from the v3.2 implementation. Only
/// the surrounding class shape (interface + Enabled getter) is new.</para>
/// </summary>
public class BpiPrsSource : IErpSource
{
    private const int ItemCodeMaxLength = 64;  // matches Receivx PullItems.ItemCode

    private readonly IErpDbConnectionFactory _factory;
    private readonly ErpSyncOptions _opts;
    private readonly ILogger<BpiPrsSource> _log;

    public BpiPrsSource(
        IErpDbConnectionFactory factory,
        IOptions<ErpSyncOptions> opts,
        ILogger<BpiPrsSource> log)
    {
        _factory = factory;
        _opts = opts.Value;
        _log = log;
    }

    public string SourceName => "BPI_PRS";

    // 13.4 — per-source toggle reads from the nested Sources.Bpi sub-config.
    // The top-level ErpSyncOptions.Enabled is the MASTER kill-switch (gates
    // recurring registration in Program.cs) — IErpSource.Enabled is the
    // PER-SOURCE toggle the fan-out loop checks for inclusion.
    public bool Enabled => _opts.Sources.Bpi.Enabled;

    public async Task<ErpSyncDraft> ReadAndTransformAsync(
        Guid warehouseId, int backfillDays, CancellationToken ct = default)
    {
        if (warehouseId == Guid.Empty)
            throw new ArgumentException("warehouseId is required", nameof(warehouseId));
        if (backfillDays < 1) backfillDays = 1;

        var sinceUtc = DateTime.UtcNow.AddDays(-backfillDays).Date;

        // Read window-filtered by DeliveryDate so the ETL doesn't drag in
        // historical pulls every run. ORDER BY (PRS_ID, SKU, TRIAL_ID) so
        // the GroupBy walk in Transform sees deterministic input order —
        // helps when a same-SKU group has multiple TRIAL_IDs and we want
        // reproducible "first wins" semantics on tie-breakers.
        const string sql = @"
            SELECT PID, PRS_ID, SKU, DESCR, PRODUCT_FAMILY, VENDOR,
                   FROM_SUB, TO_SUB, SPECIAL_CONTROL, TRIAL_ID, LOC, [PHASE],
                   QTY, REMARK, ExportEntry, AddDate, DeliveryDate, WINDOWS_TIME
            FROM   dbo.BPI_PRS
            WHERE  DeliveryDate >= @SinceUtc
            ORDER BY PRS_ID, SKU, TRIAL_ID, PID;";

        using var conn = _factory.Create();
        var rows = (await conn.QueryAsync<BpiPrsRow>(
            new CommandDefinition(sql, new { SinceUtc = sinceUtc }, cancellationToken: ct))).AsList();

        _log.LogInformation(
            "BPI_PRS read {Count} rows since {SinceUtc:yyyy-MM-dd}",
            rows.Count, sinceUtc);

        return Transform(warehouseId, rows);
    }

    // ------------------------------------------------------------------
    // Pure transform — exposed internal so smokes can exercise it with
    // hand-crafted rows (no live ERP required). Side-effect-free.
    // ------------------------------------------------------------------
    internal ErpSyncDraft Transform(Guid warehouseId, IReadOnlyList<BpiPrsRow> rows)
    {
        var draft = new ErpSyncDraft { SourceRowCount = rows.Count };
        var skipped = 0;

        foreach (var pullGroup in rows.GroupBy(r => r.PRS_ID))
        {
            if (string.IsNullOrWhiteSpace(pullGroup.Key))
            {
                skipped += pullGroup.Count();
                continue;
            }

            // Pull-level fields come from any row in the group. Earliest
            // DeliveryDate wins for PullDate so an ERP-side correction
            // moving the pull earlier is honored.
            var pullDate = pullGroup
                .Where(r => r.DeliveryDate.HasValue)
                .Select(r => r.DeliveryDate!.Value.Date)
                .DefaultIfEmpty(DateTime.UtcNow.Date)
                .Min();

            var pull = new PullDraft
            {
                PullNumber = pullGroup.Key,
                WarehouseId = warehouseId,
                PullDate = pullDate,
            };

            // Group by SYNTHESIZED ItemCode (Q1 decision: SKU-TRIAL_ID when
            // TRIAL_ID present, else bare SKU). Two BPI_PRS rows with
            // identical SKU but different TRIAL_ID become two distinct
            // items on the Receivx side.
            foreach (var itemGroup in pullGroup
                .Where(r => !string.IsNullOrWhiteSpace(r.SKU))
                .GroupBy(r => SynthesizeItemCode(r.SKU!, r.TRIAL_ID)))
            {
                if (string.IsNullOrWhiteSpace(itemGroup.Key))
                {
                    skipped += itemGroup.Count();
                    continue;
                }

                var sample = itemGroup.First();
                var item = new PullItemDraft
                {
                    ItemCode = itemGroup.Key,
                    Description = !string.IsNullOrWhiteSpace(sample.DESCR)
                        ? sample.DESCR!
                        : sample.SKU ?? "(no description)",
                    VendorCode = NullIfBlank(sample.VENDOR),
                    Remark = NullIfBlank(sample.REMARK),
                    ProductFamily = NullIfBlank(sample.PRODUCT_FAMILY),
                    FromSubInventory = NullIfBlank(sample.FROM_SUB),
                    ToSubInventory = NullIfBlank(sample.TO_SUB),
                    SpecialControl = NullIfBlank(sample.SPECIAL_CONTROL),
                    TrialId = NullIfBlank(sample.TRIAL_ID),
                    Location = NullIfBlank(sample.LOC),
                    Phase = NullIfBlank(sample.PHASE),
                };

                // One window per BPI_PRS row. After the ItemCode synthesis
                // each group should typically contain 1 row, but if the
                // ERP emits multiples for the same SKU+TRIAL_ID + window
                // we sum qty into a single window.
                foreach (var row in itemGroup)
                {
                    var qty = row.QTY ?? 0;
                    if (qty <= 0) { skipped++; continue; }

                    var hour = ParseHour(row.WINDOWS_TIME) ?? (byte)7;
                    var win = item.Windows.FirstOrDefault(w => w.HourOfDay == hour);
                    if (win is not null)
                    {
                        win.ExpectedQty += qty;
                    }
                    else
                    {
                        item.Windows.Add(new PullItemWindowDraft
                        {
                            HourOfDay = hour,
                            ExpectedQty = qty,
                        });
                    }
                }

                if (item.Windows.Count > 0)
                    pull.Items.Add(item);
                else
                    skipped++;
            }

            if (pull.Items.Count > 0)
                draft.Pulls.Add(pull);
        }

        draft.SkippedRowCount = skipped;
        return draft;
    }

    // ------------------------------------------------------------------
    // helpers (internal for smoke / unit-test reach)
    // ------------------------------------------------------------------

    internal static string SynthesizeItemCode(string sku, string? trialId)
    {
        var s = sku.Trim();
        var t = (trialId ?? string.Empty).Trim();
        var combined = t.Length == 0 ? s : $"{s}-{t}";

        // Receivx's PullItems.ItemCode caps at 64. Truncate hard if the
        // synthesized code would overflow — rare given typical SKU(<=15)
        // + TRIAL_ID(<=14) data, but defensible.
        if (combined.Length > ItemCodeMaxLength)
            combined = combined[..ItemCodeMaxLength];

        return combined;
    }

    /// <summary>
    /// Parse BPI_PRS.WINDOWS_TIME into an hour-of-day byte. Returns null
    /// for inputs the caller should default (the 07:00 fallback per the
    /// project memory). Accepts:
    ///   - "HH"          (e.g. "7", "07", "13")
    ///   - "HH:mm"       (e.g. "07:00", "13:30" — minutes ignored)
    ///   - whitespace-padded variants of the above
    /// Returns null for null/blank/multi-window-list/anything weird.
    /// </summary>
    internal static byte? ParseHour(string? windowsTime)
    {
        if (string.IsNullOrWhiteSpace(windowsTime)) return null;
        var s = windowsTime.Trim();
        // First token of a colon-split — covers "HH:mm" + "HH" cleanly.
        var hourPart = s.Split(':', 2)[0].Trim();
        if (byte.TryParse(hourPart, out var h) && h <= 23) return h;
        return null;
    }

    private static string? NullIfBlank(string? s)
        => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    // ------------------------------------------------------------------
    // Dapper materialization shape. Internal because nothing outside the
    // ETL service should see raw BPI_PRS columns.
    // ------------------------------------------------------------------
    internal sealed class BpiPrsRow
    {
        public long PID { get; set; }
        public string? PRS_ID { get; set; }
        public string? SKU { get; set; }
        public string? DESCR { get; set; }
        public string? PRODUCT_FAMILY { get; set; }
        public string? VENDOR { get; set; }
        public string? FROM_SUB { get; set; }
        public string? TO_SUB { get; set; }
        public string? SPECIAL_CONTROL { get; set; }
        public string? TRIAL_ID { get; set; }
        public string? LOC { get; set; }
        public string? PHASE { get; set; }
        public int? QTY { get; set; }
        public string? REMARK { get; set; }
        public string? ExportEntry { get; set; }
        public DateTime? AddDate { get; set; }
        public DateTime? DeliveryDate { get; set; }
        public string? WINDOWS_TIME { get; set; }
    }
}
