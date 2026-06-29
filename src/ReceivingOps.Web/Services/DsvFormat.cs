using System.Globalization;

namespace ReceivingOps.Web.Services;

/// <summary>
/// Formatting helpers for the DSV Delivery Order (2nd report). Kept in one
/// place so the HTML preview, the precomputed DTO strings, and the future
/// PDF template builder all render identical values — no drift between
/// screen and paper.
///
/// Field decisions (resolved 2026-06-11, confirmed against live data):
///   Locator  = SubInventory . DeliveryDate(dd-MMM-yyyy) . OrderId
///   DN/INV   = OrderId " +" InvoiceNo
///   Round    = union of distinct line hours, "[07:00],[08:00],…"
///   ProdLine = collapse-if-constant across the group, else null
/// </summary>
public static class DsvFormat
{
    /// <summary>
    /// Builds the Locator composite "SUB.DD-MMM-YYYY.ORDERID". Missing
    /// segments are dropped (joined with "."), so a line with no OrderId
    /// renders "SUB.DD-MMM-YYYY". Returns null when every segment is blank.
    /// </summary>
    public static string? Locator(string? subInventory, DateTime? deliveryDate, string? orderId)
    {
        var parts = new List<string>(3);
        if (!string.IsNullOrWhiteSpace(subInventory)) parts.Add(subInventory!.Trim());
        if (deliveryDate.HasValue)
            parts.Add(deliveryDate.Value.ToString("dd-MMM-yyyy", CultureInfo.InvariantCulture).ToUpperInvariant());
        if (!string.IsNullOrWhiteSpace(orderId)) parts.Add(orderId!.Trim());
        return parts.Count == 0 ? null : string.Join(".", parts);
    }

    /// <summary>
    /// Builds the DN/INV value "OrderId +InvoiceNo". When only one side is
    /// present, that side renders alone; both blank → null.
    /// </summary>
    public static string? DnInv(string? orderId, string? invoiceNo)
    {
        var dn = string.IsNullOrWhiteSpace(orderId) ? null : orderId!.Trim();
        var inv = string.IsNullOrWhiteSpace(invoiceNo) ? null : invoiceNo!.Trim();
        return (dn, inv) switch
        {
            (not null, not null) => $"{dn} +{inv}",
            (not null, null)     => dn,
            (null, not null)     => inv,
            _                    => null,
        };
    }

    /// <summary>
    /// Unions every line's pipe-delimited OrderRound into a single header
    /// string "[07:00],[08:00],…" — de-duplicated + sorted. Returns null
    /// when no line carries a round.
    /// </summary>
    public static string? RoundUnion(IEnumerable<string?> rounds)
    {
        var hours = rounds
            .Where(r => !string.IsNullOrWhiteSpace(r))
            .SelectMany(r => r!.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(h => h, StringComparer.Ordinal)
            .ToList();
        return hours.Count == 0 ? null : string.Join(",", hours.Select(h => $"[{h}]"));
    }

    /// <summary>
    /// Returns the single value shared by every non-blank entry, or null
    /// when the group is empty or disagrees. Used for the DSV header
    /// Production Line (numeric + unreliable, so usually null).
    /// </summary>
    public static string? CollapseConstant(IEnumerable<string?> values)
    {
        var distinct = values
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => v!.Trim())
            .Distinct(StringComparer.Ordinal)
            .Take(2)
            .ToList();
        return distinct.Count == 1 ? distinct[0] : null;
    }
}
