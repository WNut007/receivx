namespace ReceivingOps.Web.Data;

/// <summary>
/// The ONE definition of "these two vendor codes are the same storer", as SQL.
///
/// <para><c>PurchaseOrderLines.VendorCode</c> holds the PREFIXED ERP code
/// (<c>COI-5732</c>); <c>PullItems.VendorCode</c> holds the STRIPPED form
/// (<c>5732</c>) written from <c>BPI_PRS.VENDOR</c> verbatim. Written the
/// obvious way — <c>pol.VendorCode = @V</c> — a join across the two matches
/// ZERO rows and fails silently: the caller sees an empty result while the
/// code looks like it works. That near-miss has already happened twice on this
/// codebase, which is why the comparison lives here instead of being
/// transcribed at each site.</para>
///
/// <para>It moved out of <c>ReceiptService</c> when Reports → Pull Sheets
/// needed the same match to resolve <c>Building</c>. Two copies of this rule
/// would drift, and the drift would be invisible: both copies return rows,
/// just not the same rows.</para>
/// </summary>
public static class VendorCodeSql
{
    /// <summary>
    /// Matches exact, or prefixed-with-a-hyphen. No assumption about prefix
    /// length beyond the separator, so <c>COI-</c> and <c>WDT-</c> both work
    /// and a stripped value that itself contains a hyphen (<c>V-FORTIS</c>)
    /// still matches itself exactly.
    ///
    /// <para>The hyphen test is what pins the match: <c>COI-15732</c> ends with
    /// <c>5732</c> and must NOT match it, or stock leaks between two unrelated
    /// storers whose codes happen to share a tail.</para>
    ///
    /// <para>Both operands are identifiers — callers pass a column NAME and a
    /// parameter NAME, never values. Nothing user-supplied reaches this string.</para>
    /// </summary>
    /// <param name="poLineColumn">Qualified column holding the prefixed code, e.g. <c>pol.VendorCode</c>.</param>
    /// <param name="param">Parameter name holding the stripped code, e.g. <c>@ItemVendorCode</c>.</param>
    public static string MatchPredicate(string poLineColumn, string param) => $@"(
                   {poLineColumn} = {param}
                   OR (RIGHT({poLineColumn}, LEN({param})) = {param}
                       AND SUBSTRING({poLineColumn}, LEN({poLineColumn}) - LEN({param}), 1) = '-')
              )";
}
