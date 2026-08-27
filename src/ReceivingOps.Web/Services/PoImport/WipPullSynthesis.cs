using System.Globalization;
using System.Text.RegularExpressions;

namespace ReceivingOps.Web.Services.PoImport;

// ---------------------------------------------------------------------------
// WIP pull synthesis — the plan.
//
// For pull sheets whose STORER CODE contains "WIP", the ERP never sends the
// Receive feed. The PO import lands the lines but no Pulls / PullItems /
// PullItemWindows rows ever appear, so the goods physically arrive and the
// warehouse has nothing to receive against. Measured on the 2026-08-16
// production export: 647 of 4,401 rows across 25 pull sheets, 68,579 units,
// none of which has a Pulls row.
//
// This file computes what WOULD be created, from parsed rows alone. It is
// pure: no DB, no clock, no IO. Stage 1 runs it to validate (§4.1) and to
// show the operator a preview before anything commits; Stage 2 runs it again
// on the re-parsed file and commits the result. One planner, two callers —
// the preview cannot promise something the commit does not do.
// ---------------------------------------------------------------------------

/// <summary>
/// Static entry point for WIP detection, validation, and grouping.
/// </summary>
public static class WipPullSynthesis
{
    /// <summary>
    /// Value written to <c>dbo.Pulls.Origin</c> / <c>dbo.PurchaseOrders.Origin</c>
    /// (db/050) for rows this synthesis creates. NULL means ERP-fed,
    /// hand-created, or created before db/050 — the ordinary case.
    /// </summary>
    public const string OriginPoImport = "po-import";

    /// <summary>
    /// WIP detection (§3 decision 1): case-insensitive substring of the
    /// storer code, NOT a fixed code list. The production export carries
    /// COI-WIPBP1 and COI-WIPBP3 today; a COI-WIPBP5 tomorrow must not need
    /// a code change to be receivable.
    /// </summary>
    public static bool IsWipStorerCode(string? storerCode)
        => !string.IsNullOrWhiteSpace(storerCode)
           && storerCode.Contains("WIP", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Vendor code as <c>dbo.PullItems.VendorCode</c> holds it.
    ///
    /// <para>The two tables disagree, and the disagreement is load-bearing:
    /// <c>PurchaseOrderLines.VendorCode</c> holds the file's raw prefixed
    /// STORER CODE (<c>COI-WIPBP1</c>) because that is what the importer
    /// writes, while <c>PullItems.VendorCode</c> holds the ERP's
    /// <c>BPI_PRS.VENDOR</c> verbatim, which is the stripped form
    /// (<c>WIPBP1</c>). Measured on the dev DB: of the 76 distinct
    /// COI-prefixed POL vendor codes, 71 match a PullItems vendor code once
    /// the prefix is stripped and <b>zero</b> match raw. Writing the raw form
    /// into PullItems would look right and match nothing.</para>
    ///
    /// <para>The rule strips a leading short alpha prefix + hyphen
    /// (<c>COI-</c>, and <c>WDT-</c> which also occurs) and leaves everything
    /// else alone, so seeded codes that legitimately contain a hyphen in
    /// their stripped form (<c>V-FORTIS</c>, <c>FXL-002</c>) are untouched —
    /// a blind cut at the first hyphen would corrupt those.</para>
    /// </summary>
    public static string? StripVendorPrefix(string? vendorCode)
    {
        if (string.IsNullOrWhiteSpace(vendorCode)) return null;
        var trimmed = vendorCode.Trim();
        var stripped = VendorPrefixPattern.Replace(trimmed, "", 1);
        // A code that is ENTIRELY a prefix (e.g. "COI-") strips to empty;
        // keep the original rather than writing a blank vendor.
        return string.IsNullOrWhiteSpace(stripped) ? trimmed : stripped;
    }

    private static readonly Regex VendorPrefixPattern =
        new(@"^[A-Za-z]{2,4}-", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    // ROUND is the hour window. Accepted: "07:00" / "7:00" (the production
    // shape) and a bare "7" / "07". Rejected on purpose:
    //   - "03:00|04:00" — a real value in NON-WIP rows of the production
    //     export. It names two windows, and picking one would put stock in
    //     the wrong hour. §4.1 says a human looks at it.
    //   - "07:30" — HourOfDay is an hour; a half-hour has nowhere to land.
    // Anything unaccepted is a validation error, never a default: an invented
    // HourOfDay is a receipt booked against the wrong window.
    private static readonly Regex RoundHourOnly =
        new(@"^\s*(\d{1,2})\s*$", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex RoundHourMinute =
        new(@"^\s*(\d{1,2})\s*:\s*00\s*$", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>
    /// The hour a WIP row with a BLANK ROUND falls back to. Always 07 — the
    /// start of <see cref="Models.ReceivingPeriods.Morning"/>, so a defaulted
    /// row reads as Morning on the Pull Sheets report.
    ///
    /// <para>Flat, not inferred. There is no period or date context to derive
    /// a better answer from, and a lookup that got it right most of the time
    /// would be worse than one that is always the same: an operator can learn
    /// "blank means 07" and correct it upstream, but cannot learn a rule that
    /// varies per file.</para>
    /// </summary>
    public const byte WipBlankRoundHour = 7;

    /// <summary>
    /// Parses a ROUND cell into an hour 0-23. Returns false for blank,
    /// multi-round ("03:00|04:00"), sub-hour ("07:30"), and out-of-range.
    ///
    /// <para>This is the PARSER and knows nothing about defaults — a blank is
    /// false here whatever the row is. Callers that may substitute a default
    /// go through <see cref="TryResolveRoundHour"/>, which is the only place
    /// the default lives.</para>
    /// </summary>
    public static bool TryParseRoundHour(string? round, out byte hourOfDay)
    {
        hourOfDay = 0;
        if (string.IsNullOrWhiteSpace(round)) return false;

        var m = RoundHourMinute.Match(round);
        if (!m.Success) m = RoundHourOnly.Match(round);
        if (!m.Success) return false;

        if (!int.TryParse(m.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var h))
            return false;
        if (h is < 0 or > 23) return false;   // CK_PIW_Hour

        hourOfDay = (byte)h;
        return true;
    }

    /// <summary>
    /// Resolves a row's receiving hour, applying the blank-WIP default.
    ///
    /// <para>The default is deliberately narrow and this is its ONE
    /// definition. Both conditions must hold:</para>
    /// <list type="number">
    ///   <item>the row is WIP (<paramref name="isWipRow"/>), and</item>
    ///   <item>ROUND is blank or whitespace.</item>
    /// </list>
    ///
    /// <para>A ROUND that carries a value is used as given, WIP or not — the
    /// default fills a gap and never overrides. A WIP row whose ROUND is
    /// present but unusable ("03:00|04:00", "07:30") still fails: those name
    /// something the operator meant, and picking one of two windows would put
    /// stock in the wrong hour. Only the ABSENCE of a value is defaulted, and
    /// only on rows an operator deliberately brought in through
    /// <c>/Imports</c>. Widening either condition would swallow a real data
    /// defect — see smoke-wip-round-default.ps1 §3 and §5.</para>
    ///
    /// <para>The ERP-pull path never reaches here: it skips WIP sheets whole
    /// at PRS_ID grain (BpiPrsSource / PrbPrsSource), using this class's
    /// <see cref="IsWipStorerCode"/> to decide. That asymmetry is the point —
    /// an operator uploading a workbook is making a choice the hourly ETL
    /// is not.</para>
    /// </summary>
    /// <param name="defaulted">True when the value came from
    /// <see cref="WipBlankRoundHour"/> rather than from the cell. Counted for
    /// the per-import log line; never surfaced to the operator.</param>
    public static bool TryResolveRoundHour(
        string? round, bool isWipRow, out byte hourOfDay, out bool defaulted)
    {
        defaulted = false;

        if (TryParseRoundHour(round, out hourOfDay)) return true;

        if (isWipRow && string.IsNullOrWhiteSpace(round))
        {
            hourOfDay = WipBlankRoundHour;
            defaulted = true;
            return true;
        }

        hourOfDay = 0;
        return false;
    }

    /// <summary>
    /// Builds the synthesis plan for a parsed workbook. Never throws for
    /// content problems — they land in <see cref="WipSynthesisPlan.Errors"/>,
    /// the same way the reader reports row errors.
    /// </summary>
    public static WipSynthesisPlan Build(IReadOnlyList<PoImportRow> rows)
    {
        var plan = new WipSynthesisPlan();
        if (rows.Count == 0) return plan;

        // Sheet grain, not row grain (§4.1). WIP is a property of the whole
        // pull sheet in the production data — zero sheets mix — so the
        // decision is made once per sheet and the sheet is treated as a unit.
        var sheets = rows
            .Select((r, idx) => (Row: r, Index: idx))
            .GroupBy(x => x.Row.PoNumber, StringComparer.OrdinalIgnoreCase)
            .OrderBy(g => g.Min(x => x.Index))
            .ToList();

        foreach (var sheet in sheets)
        {
            var sheetRows = sheet.Select(x => x.Row).ToList();
            var wipRows = sheetRows.Where(r => IsWipStorerCode(r.VendorCode)).ToList();
            if (wipRows.Count == 0) continue;                 // ordinary sheet — not ours

            var pullNumber = sheet.Key;
            var firstRowNumber = sheetRows.Min(r => r.RowNumber);

            // Guard rails. Each of these has ZERO occurrences in production;
            // if one ever appears the right response is a human looking at
            // it, not a silent partial import or a guessed merge rule.
            if (wipRows.Count != sheetRows.Count)
            {
                plan.Errors.Add(new PoImportValidationError
                {
                    RowNumber = firstRowNumber,
                    Column = "STORER CODE",
                    Message = $"Pull sheet {pullNumber} mixes WIP and non-WIP rows " +
                              $"({wipRows.Count} WIP of {sheetRows.Count}). A pull sheet must be all one or all the other.",
                });
                continue;
            }

            var storerCodes = wipRows
                .Select(r => (r.VendorCode ?? "").Trim())
                .Where(v => v.Length > 0)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (storerCodes.Count > 1)
            {
                plan.Errors.Add(new PoImportValidationError
                {
                    RowNumber = firstRowNumber,
                    Column = "STORER CODE",
                    Message = $"WIP pull sheet {pullNumber} carries {storerCodes.Count} storer codes " +
                              $"({string.Join(", ", storerCodes)}). Expected exactly one.",
                });
                continue;
            }

            var deliveryDates = wipRows
                .Where(r => r.DeliveryDate.HasValue)
                .Select(r => r.DeliveryDate!.Value.Date)
                .Distinct()
                .ToList();
            if (deliveryDates.Count > 1)
            {
                plan.Errors.Add(new PoImportValidationError
                {
                    RowNumber = firstRowNumber,
                    Column = "DELIVERY DATE",
                    Message = $"WIP pull sheet {pullNumber} carries {deliveryDates.Count} delivery dates " +
                              $"({string.Join(", ", deliveryDates.Select(d => d.ToString("dd/MM/yyyy", CultureInfo.InvariantCulture)))}). Expected exactly one.",
                });
                continue;
            }

            // ROUND is per row. A BLANK one on a WIP row defaults to hour 07
            // (TryResolveRoundHour); anything else unusable is still an error.
            // The default is silent by design — a defaulted row raises no
            // issue, warning, or notice on the review screen, so a workbook
            // whose only problem was blank WIP ROUNDs reviews clean. The count
            // is carried on the plan for the one log line Stage 2 emits.
            var roundErrors = false;
            var sheetDefaulted = 0;
            foreach (var r in wipRows)
            {
                if (TryResolveRoundHour(r.OrderRound, isWipRow: true, out _, out var defaulted))
                {
                    if (defaulted) sheetDefaulted++;
                    continue;
                }
                roundErrors = true;
                plan.Errors.Add(new PoImportValidationError
                {
                    RowNumber = r.RowNumber,
                    Column = "ROUND",
                    Message = $"WIP row on pull sheet {pullNumber} has an unusable ROUND '{r.OrderRound}'. " +
                              "Expected a single whole hour such as 07:00.",
                });
            }
            if (roundErrors) continue;

            // Counted only once the sheet is accepted — a sheet rejected by a
            // guard rail contributes nothing, so the logged figure always
            // matches rows that actually landed.
            plan.RoundDefaultedRowCount += sheetDefaulted;

            var pull = new WipPullPlan
            {
                PullNumber = pullNumber,
                PullDate = deliveryDates.Count == 1 ? deliveryDates[0] : DateTime.UtcNow.Date,
                VendorCodeRaw = storerCodes.Count == 1 ? storerCodes[0] : null,
                VendorName = wipRows.Select(r => r.VendorName).FirstOrDefault(v => !string.IsNullOrWhiteSpace(v)),
            };

            // Item grain = (SKU, STORER). Window / PO-line grain =
            // (SKU, STORER, ROUND).
            //
            // 36 of the 48 production (sheet, SKU) pairs arrive as several rows
            // differing only by pallet — PullItemWindows is unique on
            // (PullItemId, HourOfDay), so those MUST be summed, not inserted row
            // by row. What must NOT be summed is two different storers: they
            // hold separate purchase orders, and merging them loses the only
            // fact that says whose goods arrived.
            //
            // The §4.1 guard above still refuses a WIP sheet carrying more than
            // one storer, so on today's data this key can never split anything —
            // measured: 25 WIP sheets, all single-storer. The two are
            // complementary rather than redundant: the guard says "this shape is
            // unexpected, have a human look at it", the key says "if it ever
            // does arrive, do not silently merge it". Neither is a substitute
            // for the other, and the key costs nothing while the guard stands.
            foreach (var itemGroup in wipRows
                         .GroupBy(r => new WipItemKey(r.ItemCode, r.VendorCode))
                         .OrderBy(g => g.Min(r => r.RowNumber)))
            {
                var sample = itemGroup.OrderBy(r => r.RowNumber).First();
                var item = new WipItemPlan
                {
                    ItemCode = itemGroup.Key.ItemCode,
                    Description = sample.Description,
                    // From the group key, not the pull: with the guard removed
                    // or a future multi-storer sheet allowed, the pull-level
                    // vendor would be whichever storer was seen first.
                    VendorCodeRaw = itemGroup.Key.VendorCode ?? pull.VendorCodeRaw,
                    VendorName = sample.VendorName ?? pull.VendorName,
                };

                // Resolve, not parse — blank WIP rows have to land on hour 07
                // here too, or the validation loop would accept them and the
                // grouping would silently drop them into hour 0. Several blank
                // rows on one sheet therefore share a group key and collapse
                // into ONE hour-07 window with the summed quantity, which is
                // what PullItemWindows' uniqueness on (PullItemId, HourOfDay)
                // requires.
                foreach (var hourGroup in itemGroup
                             .GroupBy(r =>
                             {
                                 TryResolveRoundHour(r.OrderRound, isWipRow: true, out var h, out _);
                                 return h;
                             })
                             .OrderBy(g => g.Key))
                {
                    // The representative row supplies the ERP metadata the PO
                    // line carries (pallet, location, sub-inventory …). Rows
                    // inside a group differ only by those fields, so the first
                    // row in file order is as good as any and is at least
                    // deterministic. The quantity is the sum, never the
                    // sample's.
                    var winSample = hourGroup.OrderBy(r => r.RowNumber).First();
                    item.Windows.Add(new WipWindowPlan
                    {
                        HourOfDay = hourGroup.Key,
                        Qty = hourGroup.Sum(r => r.OrderedQty),
                        SourceRowCount = hourGroup.Count(),
                        Sample = winSample,
                    });
                }

                pull.Items.Add(item);
            }

            plan.Pulls.Add(pull);
        }

        return plan;
    }
}

/// <summary>What a workbook's WIP sheets would create. Pure data.</summary>
public class WipSynthesisPlan
{
    public List<WipPullPlan> Pulls { get; } = new();

    /// <summary>§4.1 guard-rail failures. Non-empty means the file is rejected.</summary>
    public List<PoImportValidationError> Errors { get; } = new();

    /// <summary>
    /// WIP rows whose blank ROUND was defaulted to
    /// <see cref="WipPullSynthesis.WipBlankRoundHour"/>, across accepted
    /// sheets only.
    ///
    /// <para>Diagnostic. This is NOT an error count and NOT an operator-facing
    /// figure — it never reaches the review screen. Stage 2 logs it once per
    /// import so a "why is this in Morning?" question is answerable later
    /// without re-reading the workbook.</para>
    /// </summary>
    public int RoundDefaultedRowCount { get; set; }

    public bool HasWork => Pulls.Count > 0;
    public int PullCount => Pulls.Count;
    public int ItemCount => Pulls.Sum(p => p.Items.Count);
    public int WindowCount => Pulls.Sum(p => p.Items.Sum(i => i.Windows.Count));
    public int TotalQty => Pulls.Sum(p => p.TotalQty);

    public WipPullPlan? Find(string pullNumber)
        => Pulls.FirstOrDefault(p => string.Equals(p.PullNumber, pullNumber, StringComparison.OrdinalIgnoreCase));
}

public class WipPullPlan
{
    public string PullNumber { get; set; } = "";
    public DateTime PullDate { get; set; }

    /// <summary>Raw STORER CODE — what PurchaseOrderLines.VendorCode holds.</summary>
    public string? VendorCodeRaw { get; set; }

    /// <summary>Prefix-stripped — what PullItems.VendorCode holds. See StripVendorPrefix.</summary>
    public string? VendorCodeStripped => WipPullSynthesis.StripVendorPrefix(VendorCodeRaw);

    public string? VendorName { get; set; }

    public List<WipItemPlan> Items { get; } = new();

    public int WindowCount => Items.Sum(i => i.Windows.Count);
    public int TotalQty => Items.Sum(i => i.TotalQty);
}

public class WipItemPlan
{
    public string ItemCode { get; set; } = "";
    public string? Description { get; set; }
    public string? VendorCodeRaw { get; set; }
    public string? VendorCodeStripped => WipPullSynthesis.StripVendorPrefix(VendorCodeRaw);
    public string? VendorName { get; set; }

    public List<WipWindowPlan> Windows { get; } = new();

    public int TotalQty => Windows.Sum(w => w.Qty);
}

public class WipWindowPlan
{
    public byte HourOfDay { get; set; }

    /// <summary>SUM(OPEN QTY) over every row in this (sheet, SKU, ROUND) group.</summary>
    public int Qty { get; set; }

    /// <summary>How many source rows were summed. Diagnostic only.</summary>
    public int SourceRowCount { get; set; }

    /// <summary>First row of the group in file order — supplies PO-line ERP metadata.</summary>
    public PoImportRow Sample { get; set; } = new();
}

/// <summary>
/// Identity of a synthesised pull item: SKU **and storer**.
///
/// <para>Mirrors <c>ErpSync.ItemKey</c> deliberately rather than sharing it —
/// this side keys on the RAW prefixed STORER CODE straight out of the
/// workbook (<c>COI-WIPBP1</c>), while the ETL side keys on the stripped ERP
/// form (<c>WIPBP1</c>). Sharing one type would invite someone to compare the
/// two keys across the boundary, which is exactly the silent-zero-match the
/// vendor formats keep causing.</para>
/// </summary>
public readonly record struct WipItemKey(string ItemCode, string? VendorCode)
{
    public bool Equals(WipItemKey other) =>
        string.Equals(ItemCode, other.ItemCode, StringComparison.Ordinal) &&
        string.Equals(VendorCode, other.VendorCode, StringComparison.OrdinalIgnoreCase);

    public override int GetHashCode() => HashCode.Combine(
        ItemCode is null ? 0 : StringComparer.Ordinal.GetHashCode(ItemCode),
        VendorCode is null ? 0 : StringComparer.OrdinalIgnoreCase.GetHashCode(VendorCode));
}
