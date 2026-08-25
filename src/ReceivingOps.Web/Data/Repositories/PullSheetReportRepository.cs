using Dapper;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

/// <summary>
/// The Reports → Pull Sheets query. See <see cref="IPullSheetReportRepository"/>
/// for the contract.
///
/// NIGHT ROLLOVER — the load-bearing rule in this file.
///
/// Pulls.PullDate is DATE and PullItemWindows.HourOfDay is TINYINT 0-23. There
/// is no datetime anywhere on a window, so "the night of date D" cannot be
/// expressed as a range and has to be constructed from two (date, hours) pairs:
///
///     hour 23 of pulls where PullDate = D
///   + hours 0,1,2 of pulls where PullDate = D + 1
///
/// Every other period is a single PullDate with four hours. The pair list below
/// is built from <see cref="ReceivingPeriod.HoursOnDayOffset"/> so the rule
/// comes out of the shared period definition rather than being restated here.
///
/// Measured on production 2026-08-21: hours 0-2 carry 261 windows all-time (64
/// in the last 30 days) against 691 at hour 23, out of 54,641 windows overall.
/// Sparse — about half a percent — but live. Without the rollover those rows
/// would either vanish from the Night report or be filed under the wrong date.
/// </summary>
public class PullSheetReportRepository : IPullSheetReportRepository
{
    private readonly IDbConnectionFactory _factory;

    public PullSheetReportRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// The literal a collapsed cell carries when its contributing PO lines
    /// disagree. A word, not a comma-joined list: the column is a VLOOKUP key
    /// downstream, and "B2, B4" is neither a building nor a usable key.
    /// </summary>
    public const string MixedMarker = "*mixed*";

    // Cross-format storer match, from the ONE definition of that rule. POL holds
    // the prefixed code (COI-5732), PullItems the stripped one (5732); written
    // as a plain equality this joins nothing and reports it as "no data".
    private static readonly string BuildingVendorMatch =
        VendorCodeSql.MatchPredicate("pol.VendorCode", "pi.VendorCode");

    // Window-grained projection. INNER JOIN on windows, not LEFT: a pull item
    // with no window in the period is not part of that period, and a NULL hour
    // row would be a phantom on the Detail sheet.
    //
    // BUILDING rides an OUTER APPLY, not a join, and that is load-bearing.
    // Building sits at PO-LINE grain and one pull item can reach many lines --
    // measured on 2026-08-20, one item resolves to 181 of them. Joining POL
    // into this SELECT would multiply every window row by its line count and
    // silently inflate every ExpectedQty and ReceivedQty on all four sheets.
    // The APPLY collapses to one value before it reaches the projection, so the
    // grain of this query is exactly what it was before the column existed.
    //
    // NBSP (U+00A0) is folded to a space BEFORE the collapse, not only when the
    // cell is written. SetText/Normalize already covers the workbook, but by then
    // the comparison has happened: SQL Server's LTRIM/RTRIM do not treat NBSP as
    // whitespace, so an NBSP-padded "B4" and a plain "B4" are two distinct values
    // and would collapse to *mixed* -- a disagreement invented by padding. The
    // feed is known to carry NBSP in this position (304 VendorName rows on
    // 2026-08-21); Building has none today and this is what keeps it that way.
    //
    // MIN = MAX is the collapse (the same one PurchaseOrderRepository uses for
    // the collapsed header vendor): all contributing lines agree -> that value;
    // they disagree -> MixedMarker; none contribute or all are NULL -> NULL,
    // which renders as an em-dash. The explicit MIN IS NULL branch is required
    // -- with every line NULL the aggregates are NULL, MIN = MAX evaluates to
    // UNKNOWN rather than true, and the row would fall through to MixedMarker.
    private static readonly string DetailSelect = $@"
        SELECT  p.PullNumber,
                w.Code            AS WarehouseCode,
                w.Name            AS WarehouseName,
                p.PullDate,
                p.Status          AS PullStatus,
                pi.ItemCode,
                pi.Description,
                pi.Tag,
                pi.Status         AS RowStatus,
                pi.VendorCode,
                pi.VendorName,
                pi.Remark,
                CAST(piw.HourOfDay AS INT) AS HourOfDay,
                piw.ExpectedQty,
                piw.ReceivedQty,
                ISNULL(piw.IsClosed, 0) AS IsClosed,
                bld.Building
        FROM    dbo.PullItemWindows piw
        JOIN    dbo.PullItems  pi ON pi.Id = piw.PullItemId
        JOIN    dbo.Pulls      p  ON p.Id  = pi.PullId
        JOIN    dbo.Warehouses w  ON w.Id  = p.WarehouseId
        OUTER APPLY (
            SELECT CASE
                     WHEN MIN(m.B) = MAX(m.B) THEN MAX(m.B)
                     WHEN MIN(m.B) IS NULL     THEN NULL
                     ELSE '{MixedMarker}'
                   END AS Building
            FROM (
                SELECT NULLIF(LTRIM(RTRIM(REPLACE(pol.Building, NCHAR(160), N' '))), '') AS B
                FROM   dbo.PurchaseOrderLines pol
                JOIN   dbo.PurchaseOrders     po ON po.Id = pol.PurchaseOrderId
                WHERE  pol.ItemCode   = pi.ItemCode
                  AND  po.WarehouseId = p.WarehouseId
                  AND  pi.VendorCode IS NOT NULL
                  AND  {BuildingVendorMatch}
            ) m
        ) bld
";
    private const string DetailOrderBy = @"
        ORDER BY p.PullNumber, pi.ItemCode, pi.VendorCode, pi.SortOrder, piw.HourOfDay;";

    public async Task<List<PullSheetDetailRow>> GetDetailRowsAsync(
        PullSheetCriteria criteria, CancellationToken ct = default)
    {
        using var conn = _factory.Create();

        // ---- Single-pull mode: one pull, all 24 hours ----------------------
        if (criteria.PullId is { } pullId)
        {
            var single = await conn.QueryAsync<PullSheetDetailRow>(new CommandDefinition(
                DetailSelect + " WHERE p.Id = @PullId " + DetailOrderBy,
                new { PullId = pullId }, cancellationToken: ct));
            return single.AsList();
        }

        // ---- Period mode ---------------------------------------------------
        var period = ReceivingPeriods.ByKey(criteria.PeriodKey)
            ?? throw new ArgumentException(
                $"Unknown period '{criteria.PeriodKey}'.", nameof(criteria));

        // One (date, hours) pair per day the period touches. Length 1 for every
        // period except Night, which yields {D: [23]} and {D+1: [0,1,2]}.
        var segments = BuildDateSegments(period, criteria.Date);

        // Segments are OR'd rather than run as separate queries so the ORDER BY
        // sorts across both halves of a Night — a Night workbook whose D+1 rows
        // were appended after all the D rows would interleave item codes wrongly.
        var clauses = new List<string>(segments.Count);
        var args = new DynamicParameters();
        args.Add("WarehouseId", criteria.WarehouseId);
        args.Add("Status", string.IsNullOrWhiteSpace(criteria.Status) ? null : criteria.Status);

        for (var i = 0; i < segments.Count; i++)
        {
            var (date, hours) = segments[i];
            args.Add($"Date{i}", date.ToDateTime(TimeOnly.MinValue).Date, System.Data.DbType.Date);
            // Dapper expands an int[] into an IN (...) list of parameters.
            args.Add($"Hours{i}", hours);
            clauses.Add($"(p.PullDate = @Date{i} AND piw.HourOfDay IN @Hours{i})");
        }

        var where = $@"
        WHERE   ({string.Join(" OR ", clauses)})
          AND   (@WarehouseId IS NULL OR p.WarehouseId = @WarehouseId)
          AND   (@Status      IS NULL OR p.Status      = @Status)";

        var rows = await conn.QueryAsync<PullSheetDetailRow>(new CommandDefinition(
            DetailSelect + where + DetailOrderBy, args, cancellationToken: ct));
        return rows.AsList();
    }

    /// <summary>
    /// Split a period into the (PullDate, hours) pairs it reads. Derived from
    /// the period's own hour set, so a period that started crossing midnight
    /// would pick this up without a change here.
    /// </summary>
    internal static List<(DateOnly Date, int[] Hours)> BuildDateSegments(
        ReceivingPeriod period, DateOnly date)
    {
        var segments = new List<(DateOnly, int[])>(2);

        var sameDay = period.HoursOnDayOffset(0);
        if (sameDay.Length > 0) segments.Add((date, sameDay));

        var nextDay = period.HoursOnDayOffset(1);
        if (nextDay.Length > 0) segments.Add((date.AddDays(1), nextDay));

        return segments;
    }
}
