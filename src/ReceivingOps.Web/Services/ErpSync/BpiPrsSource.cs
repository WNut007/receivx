using Dapper;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Services.PoImport;

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

        var draft = Transform(warehouseId, rows);

        // Operator-visible at the run level via SourceTotals + the etl-end audit
        // row; logged here too because a 24%-of-rows filter that leaves no trace
        // in the log reads as a shrinking feed.
        if (draft.WipSkippedRowCount > 0)
        {
            _log.LogInformation(
                "{Src} WIP filter skipped {Rows} rows across {Sheets} pull sheet(s) — " +
                "WIP pulls are built by the PO import, not this feed. " +
                "{Mixed} of those sheet(s) also carried {NonWipRows} non-WIP row(s) / " +
                "{NonWipQty} units, dropped with them{Sample}.",
                SourceName, draft.WipSkippedRowCount, draft.WipSkippedPullCount,
                draft.WipMixedPullCount, draft.WipMixedNonWipRowCount, draft.WipMixedNonWipQty,
                draft.WipMixedPullNumbers.Count > 0
                    ? " (" + string.Join(", ", draft.WipMixedPullNumbers) + ")"
                    : "");
        }

        return draft;
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

            // ------------------------------------------------------------------
            // WIP sheets belong to the PO import, not to this feed.
            //
            // The filter is at SHEET grain — one WIP row anywhere on a PRS_ID
            // drops the whole sheet — and the grain is the entire point. Dropping
            // only the WIP rows would leave the sheet in the draft carrying its
            // non-WIP items, and ErpUpsertService's orphan pass cancels anything
            // on the pull that the draft no longer mentions. That leaves a
            // canceled pull item with live ReceivedQty still booked against its
            // PO line and nothing to detect the mismatch — the exact failure this
            // filter exists to prevent, reintroduced by the filter itself.
            //
            // Two mixed sheets exist upstream (measured 2026-08-20, all-time):
            // 0000023492 (37 WIP rows + 1 non-WIP row) and 0000028412 (1 WIP row
            // + 2 non-WIP rows, 1,640 units). 0000023492 survives a row-grain
            // filter today only because its one non-WIP row has QTY = 0, which
            // the qty guard below drops anyway, leaving an empty sheet. That is
            // accidental safety: someone editing that 0 upstream re-arms the bug
            // with no code change. Sheet grain makes the outcome structurally
            // impossible instead of luckily avoided.
            //
            // The predicate is WipPullSynthesis.IsWipStorerCode — the same one
            // the importer uses to decide a sheet is WIP. A second copy here
            // would let the two sides drift on what WIP means, and the failure
            // mode is a sheet that NEITHER path builds a pull for.
            //
            // Non-WIP rows on a mixed sheet are dropped too. That is a real cost,
            // so it is counted and reported rather than absorbed silently.
            if (pullGroup.Any(r => WipPullSynthesis.IsWipStorerCode(r.VENDOR)))
            {
                var nonWip = pullGroup
                    .Where(r => !WipPullSynthesis.IsWipStorerCode(r.VENDOR))
                    .ToList();
                draft.NoteWipSkippedSheet(
                    pullGroup.Key!, pullGroup.Count(), nonWip.Count,
                    nonWip.Sum(r => r.QTY ?? 0));
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

            // Group by BARE SKU — the item identity that matches the PO
            // import side (PurchaseOrderLines.ItemCode is the bare SKU from
            // the "SKU" column). Multiple BPI_PRS rows sharing a SKU but
            // differing only in TRIAL_ID collapse into ONE Receivx item;
            // their qty sums across windows below. TRIAL_ID is lot/trial
            // metadata, captured separately in PullItemDraft.TrialId — it is
            // NOT part of item identity. (Previously this synthesized
            // "SKU-TRIAL_ID", which broke the §7.15 FIFO match against the
            // bare-SKU PO lines and left receives blocked.)
            // Storer grain: the key is (ItemCode, VendorCode), NOT ItemCode alone.
            // One pull sheet routinely carries the same SKU from two storers —
            // 107 such (pull, SKU) pairs in a single day, 2,500,523 units — and the
            // two storers hold SEPARATE purchase orders. Grouping on SKU alone kept
            // whichever VENDOR sorted first, summed both quantities into one item,
            // and left receiving unable to say whose goods arrived. Nothing errored;
            // the second storer was simply gone before anything was written.
            //
            // ItemCode itself STAYS the bare SKU (see the note above) — only the
            // grouping key widens, so the §7.15 FIFO match against bare-SKU PO lines
            // is untouched. VendorCode stays the stripped ERP form on PullItems.
            foreach (var itemGroup in pullGroup
                .Where(r => !string.IsNullOrWhiteSpace(r.SKU))
                .GroupBy(r => new ItemKey(NormalizeItemCode(r.SKU!), NullIfBlank(r.VENDOR))))
            {
                if (string.IsNullOrWhiteSpace(itemGroup.Key.ItemCode))
                {
                    skipped += itemGroup.Count();
                    continue;
                }

                var sample = itemGroup.First();
                var item = new PullItemDraft
                {
                    ItemCode = itemGroup.Key.ItemCode,
                    Description = !string.IsNullOrWhiteSpace(sample.DESCR)
                        ? sample.DESCR!
                        : sample.SKU ?? "(no description)",
                    // From the KEY, not the sample: the group is now storer-scoped,
                    // so every row in it carries this vendor. Reading the sample
                    // again would work but would re-introduce the "first row wins"
                    // shape that caused the defect.
                    VendorCode = itemGroup.Key.VendorCode,
                    Remark = NullIfBlank(sample.REMARK),
                    ProductFamily = NullIfBlank(sample.PRODUCT_FAMILY),
                    FromSubInventory = NullIfBlank(sample.FROM_SUB),
                    ToSubInventory = NullIfBlank(sample.TO_SUB),
                    SpecialControl = NullIfBlank(sample.SPECIAL_CONTROL),
                    TrialId = NullIfBlank(sample.TRIAL_ID),
                    Location = NullIfBlank(sample.LOC),
                    Phase = NullIfBlank(sample.PHASE),
                };

                // One window per hour-of-day. Rows that collapsed into this
                // SKU (different TRIAL_IDs, or the same SKU emitted multiple
                // times for one hour) sum their qty into the matching window.
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

    // ItemCode = bare SKU, trimmed only. Trial/lot identity lives in
    // PullItemDraft.TrialId, never in the ItemCode — the PO lines this
    // must FIFO-match against carry the bare SKU. No length cap: the PO
    // import (PoImportReader) doesn't cap either, and capping only one
    // side would re-break the match for any SKU > 64 chars.
    internal static string NormalizeItemCode(string sku) => sku.Trim();

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
