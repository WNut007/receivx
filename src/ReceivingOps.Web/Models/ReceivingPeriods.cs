namespace ReceivingOps.Web.Models;

/// <summary>
/// One receiving period — a 4-hour block of the operating day.
/// </summary>
/// <param name="Key">Stable lowercase identifier used on the wire (query
/// strings, smoke assertions). Never localized, never displayed.</param>
/// <param name="Label">Display name ("Morning"). Also the Period column value
/// in the pull-sheet workbook and the trailing token of its filename.</param>
/// <param name="StartHour">First hour of the block, 0-23.</param>
public sealed record ReceivingPeriod(string Key, string Label, int StartHour)
{
    /// <summary>How many hours a period spans. Six of these tile the 24-hour day.</summary>
    public const int LengthHours = 4;

    /// <summary>
    /// The hours this period covers, in order, wrapped at 24.
    /// END HOUR IS INCLUSIVE: 07-10 is {7,8,9,10}, not {7,8,9}. This mirrors
    /// <c>currentPeriodHours()</c> in receiving.js — start + 0..3 — which is
    /// what the receiving grid has always rendered.
    /// </summary>
    public int[] Hours { get; } =
        Enumerable.Range(0, LengthHours).Select(i => (StartHour + i) % 24).ToArray();

    /// <summary>Last hour of the block, inclusive.</summary>
    public int EndHour => (StartHour + LengthHours - 1) % 24;

    /// <summary>
    /// True when the block wraps past midnight (Night, 23-02). Only such a
    /// period reads two calendar dates; see <see cref="HoursOnDayOffset"/>.
    /// </summary>
    public bool CrossesMidnight => StartHour + LengthHours > 24;

    /// <summary>"07:00 — 10:00" — the range as the picker shows it.</summary>
    public string RangeLabel =>
        $"{StartHour:00}:00 — {EndHour:00}:00";

    /// <summary>"07:00 — 10:00 · Morning" — the full option text.</summary>
    public string OptionText => $"{RangeLabel} · {Label}";

    /// <summary>The picker's option value — zero-padded start hour ("07").</summary>
    public string Value => StartHour.ToString("00");

    /// <summary>
    /// The hours of this period that fall on date D + <paramref name="dayOffset"/>.
    /// Every period returns all four hours at offset 0 except Night, which
    /// returns {23} at offset 0 and {0,1,2} at offset 1.
    /// </summary>
    public int[] HoursOnDayOffset(int dayOffset) => dayOffset switch
    {
        0 => Hours.Where(h => h >= StartHour).ToArray(),
        1 => Hours.Where(h => h < StartHour).ToArray(),
        _ => Array.Empty<int>(),
    };
}

/// <summary>
/// The canonical list of receiving periods — the ONE definition in the codebase.
///
/// It used to live as six hardcoded &lt;option&gt; elements in
/// Views/Receiving/Index.cshtml, with the hour arithmetic duplicated in
/// receiving.js. Both now render from here, as does the Reports → Pull Sheets
/// report, so a period cannot be redefined for the grid and not for the report.
///
/// The six blocks partition the day exactly: 6 x 4 = 24 hours, no gaps, no
/// overlap. <see cref="ReceivingPeriodsSelfTest"/> is the guard on that, and
/// smoke-pull-sheets-period-map asserts it from outside the process.
/// </summary>
public static class ReceivingPeriods
{
    public static readonly ReceivingPeriod Morning   = new("morning",   "Morning",   7);
    public static readonly ReceivingPeriod Midday    = new("midday",    "Midday",    11);
    public static readonly ReceivingPeriod Afternoon = new("afternoon", "Afternoon", 15);
    public static readonly ReceivingPeriod Evening   = new("evening",   "Evening",   19);
    public static readonly ReceivingPeriod Night     = new("night",     "Night",     23);
    public static readonly ReceivingPeriod PreDawn   = new("pre-dawn",  "Pre-dawn",  3);

    /// <summary>
    /// Picker order — the order the Receiving dropdown has always shown, which
    /// starts the operating day at 07:00 rather than at midnight. The prev/next
    /// stepper walks this list cyclically, so the order is behaviour, not taste.
    /// </summary>
    public static readonly IReadOnlyList<ReceivingPeriod> All = new[]
    {
        Morning, Midday, Afternoon, Evening, Night, PreDawn,
    };

    /// <summary>The period the Receiving picker opens on before JS jumps to now.</summary>
    public static ReceivingPeriod Default => Midday;

    /// <summary>Resolve by <see cref="ReceivingPeriod.Key"/>; null when unknown.</summary>
    public static ReceivingPeriod? ByKey(string? key) =>
        string.IsNullOrWhiteSpace(key)
            ? null
            : All.FirstOrDefault(p => string.Equals(p.Key, key, StringComparison.OrdinalIgnoreCase));

    /// <summary>The period containing an hour of the day. Total over 0-23.</summary>
    public static ReceivingPeriod ContainingHour(int hour) =>
        All.First(p => p.Hours.Contains(hour));
}

/// <summary>
/// Fail-fast guard that the six periods still tile the day. Called once at
/// startup: a bad edit to <see cref="ReceivingPeriods.All"/> stops the app
/// rather than silently dropping an hour out of every report that reads it.
/// </summary>
public static class ReceivingPeriodsSelfTest
{
    public static void Verify()
    {
        var hours = ReceivingPeriods.All.SelectMany(p => p.Hours).ToArray();

        var dupes = hours.GroupBy(h => h).Where(g => g.Count() > 1).Select(g => g.Key).ToArray();
        if (dupes.Length > 0)
            throw new InvalidOperationException(
                $"Receiving periods overlap on hour(s): {string.Join(", ", dupes)}.");

        var missing = Enumerable.Range(0, 24).Except(hours).ToArray();
        if (missing.Length > 0)
            throw new InvalidOperationException(
                $"Receiving periods leave hour(s) uncovered: {string.Join(", ", missing)}.");
    }
}
