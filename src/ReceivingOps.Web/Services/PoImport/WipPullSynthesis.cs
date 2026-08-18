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
    /// Parses a ROUND cell into an hour 0-23. Returns false for blank,
    /// multi-round ("03:00|04:00"), sub-hour ("07:30"), and out-of-range —
    /// all of which are validation errors, not defaults.
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

            // ROUND is per row and has no sensible default.
            var roundErrors = false;
            foreach (var r in wipRows)
            {
                if (TryParseRoundHour(r.OrderRound, out _)) continue;
                roundErrors = true;
                plan.Errors.Add(new PoImportValidationError
                {
                    RowNumber = r.RowNumber,
                    Column = "ROUND",
                    Message = string.IsNullOrWhiteSpace(r.OrderRound)
                        ? $"WIP row on pull sheet {pullNumber} has a blank ROUND. The receiving hour cannot be guessed."
                        : $"WIP row on pull sheet {pullNumber} has an unusable ROUND '{r.OrderRound}'. " +
                          "Expected a single whole hour such as 07:00.",
                });
            }
            if (roundErrors) continue;

            var pull = new WipPullPlan
            {
                PullNumber = pullNumber,
                PullDate = deliveryDates.Count == 1 ? deliveryDates[0] : DateTime.UtcNow.Date,
                VendorCodeRaw = storerCodes.Count == 1 ? storerCodes[0] : null,
                VendorName = wipRows.Select(r => r.VendorName).FirstOrDefault(v => !string.IsNullOrWhiteSpace(v)),
            };

            // Item grain = SKU. Window / PO-line grain = (SKU, ROUND).
            // 36 of the 48 production (sheet, SKU) pairs arrive as several
            // rows differing only by pallet — PullItemWindows is unique on
            // (PullItemId, HourOfDay), so those MUST be summed, not inserted
            // row by row.
            foreach (var itemGroup in wipRows
                         .GroupBy(r => r.ItemCode, StringComparer.Ordinal)
                         .OrderBy(g => g.Min(r => r.RowNumber)))
            {
                var sample = itemGroup.OrderBy(r => r.RowNumber).First();
                var item = new WipItemPlan
                {
                    ItemCode = itemGroup.Key,
                    Description = sample.Description,
                    VendorCodeRaw = pull.VendorCodeRaw,
                    VendorName = pull.VendorName,
                };

                foreach (var hourGroup in itemGroup
                             .GroupBy(r => { TryParseRoundHour(r.OrderRound, out var h); return h; })
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
