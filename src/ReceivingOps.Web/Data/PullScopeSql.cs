namespace ReceivingOps.Web.Data;

/// <summary>
/// The ONE definition of "these purchase-order rows belong to this pull", as SQL.
///
/// <para>Two columns carry the link and both are needed. <c>PurchaseOrders.PullId</c>
/// is the FK, set only where a <c>dbo.Pulls</c> row existed at import time (27 of
/// 1,761 POs, measured 2026-08-25). <c>PurchaseOrders.PullExternalRef</c> is the A1
/// denormalization (db/033) holding the upstream PRS ID verbatim — the same string
/// as <c>PoNumber</c> on all 1,742 POs that carry it, and the same string as
/// <c>Pulls.PullNumber</c> on the 1,429 that reach a pull. Matching on the FK alone
/// misses almost every imported PO; matching on the ref alone misses the WIP-synthesised
/// ones. Together they reach 1,431 pulls, a strict superset of either half.</para>
///
/// <para>It moved out of <c>ReceiptService</c> when Reports → Pull Sheets needed the
/// same scope to resolve <c>Building</c>. A pull's Building and a pull's FIFO candidate
/// POs disagreeing about which purchase orders belong to that pull would be a defect
/// neither side could see from where it sits, which is exactly the drift
/// <see cref="VendorCodeSql"/> exists to prevent for the storer rule.</para>
///
/// <para>Both operands are identifiers — callers pass a parameter NAME or a column
/// NAME, never a value. Nothing user-supplied reaches this string.</para>
/// </summary>
public static class PullScopeSql
{
    /// <param name="pullIdOperand">Parameter or column holding the pull's Id, e.g. <c>@PullId</c> or <c>p.Id</c>.</param>
    /// <param name="pullNumberOperand">Parameter or column holding the pull's number, e.g. <c>@PullNumberStr</c> or <c>p.PullNumber</c>.</param>
    /// <param name="poAlias">Alias of <c>dbo.PurchaseOrders</c> in the calling query.</param>
    public static string MatchPredicate(
        string pullIdOperand, string pullNumberOperand, string poAlias = "po") =>
        $"({poAlias}.PullId = {pullIdOperand} OR {poAlias}.PullExternalRef = {pullNumberOperand})";
}
