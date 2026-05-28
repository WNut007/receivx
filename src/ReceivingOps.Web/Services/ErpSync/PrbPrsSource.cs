using Dapper;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data;

namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 13.3 — PRB_PRS reader + transform. Schema mirrors BPI_PRS
/// (per design Q2 = identical schema, same host per Q1). Implementation
/// is deliberately parallel to <see cref="BpiPrsSource"/> — extracting
/// a shared base class is premature for two sources and would obscure
/// the divergent SQL FROM clause + source-name string.
///
/// <para>PRS_ID namespace is disjoint from BPI_PRS (Q3 = no collisions),
/// so the upsert keys on <c>Pulls.PullNumber</c> alone — no source
/// discriminator needed.</para>
/// </summary>
public class PrbPrsSource : IErpSource
{
    private const int ItemCodeMaxLength = 64;  // matches Receivx PullItems.ItemCode

    private readonly IErpDbConnectionFactory _factory;
    private readonly ErpSyncOptions _opts;
    private readonly ILogger<PrbPrsSource> _log;

    public PrbPrsSource(
        IErpDbConnectionFactory factory,
        IOptions<ErpSyncOptions> opts,
        ILogger<PrbPrsSource> log)
    {
        _factory = factory;
        _opts = opts.Value;
        _log = log;
    }

    public string SourceName => "PRB_PRS";

    public bool Enabled => _opts.Sources.Prb.Enabled;

    public async Task<ErpSyncDraft> ReadAndTransformAsync(
        Guid warehouseId, int backfillDays, CancellationToken ct = default)
    {
        if (warehouseId == Guid.Empty)
            throw new ArgumentException("warehouseId is required", nameof(warehouseId));
        if (backfillDays < 1) backfillDays = 1;

        var sinceUtc = DateTime.UtcNow.AddDays(-backfillDays).Date;

        const string sql = @"
            SELECT PID, PRS_ID, SKU, DESCR, PRODUCT_FAMILY, VENDOR,
                   FROM_SUB, TO_SUB, SPECIAL_CONTROL, TRIAL_ID, LOC, [PHASE],
                   QTY, REMARK, ExportEntry, AddDate, DeliveryDate, WINDOWS_TIME
            FROM   dbo.PRB_PRS
            WHERE  DeliveryDate >= @SinceUtc
            ORDER BY PRS_ID, SKU, TRIAL_ID, PID;";

        using var conn = _factory.Create();
        var rows = (await conn.QueryAsync<PrbPrsRow>(
            new CommandDefinition(sql, new { SinceUtc = sinceUtc }, cancellationToken: ct))).AsList();

        _log.LogInformation(
            "PRB_PRS read {Count} rows since {SinceUtc:yyyy-MM-dd}",
            rows.Count, sinceUtc);

        return Transform(warehouseId, rows);
    }

    internal ErpSyncDraft Transform(Guid warehouseId, IReadOnlyList<PrbPrsRow> rows)
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

    internal static string SynthesizeItemCode(string sku, string? trialId)
    {
        var s = sku.Trim();
        var t = (trialId ?? string.Empty).Trim();
        var combined = t.Length == 0 ? s : $"{s}-{t}";
        if (combined.Length > ItemCodeMaxLength)
            combined = combined[..ItemCodeMaxLength];
        return combined;
    }

    internal static byte? ParseHour(string? windowsTime)
    {
        if (string.IsNullOrWhiteSpace(windowsTime)) return null;
        var s = windowsTime.Trim();
        var hourPart = s.Split(':', 2)[0].Trim();
        if (byte.TryParse(hourPart, out var h) && h <= 23) return h;
        return null;
    }

    private static string? NullIfBlank(string? s)
        => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    internal sealed class PrbPrsRow
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
