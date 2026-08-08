namespace ReceivingOps.Web.Models;

/// <summary>
/// Which way the delivery missed. Computed from the quantity, never sent by the client:
/// over when qty > outstanding, short when qty &lt; outstanding (including qty = 0).
/// An exact quantity is neither and asks for no reason at all (brief §4.1).
/// </summary>
public enum VarianceDirection
{
    Over,
    Short,
}

/// <summary>
/// db/049 — the fixed reason set for an accepted variance.
///
/// THIS IS THE ONLY MAP. The labels appear here and nowhere else: not in Razor, not in
/// JavaScript, not in CSS. The client builds its dropdown from
/// GET /api/receipts/variance-reasons, which is served from this list, so changing a
/// label — or deciding the UI should be English one day — is an edit to this file alone
/// rather than a hunt through markup.
///
/// Corollaries, both load-bearing:
///   • A raw code is NEVER rendered to the operator. Display goes through <see cref="Label"/>.
///   • No logic anywhere keys off a label. Codes are the stable identifier; labels are
///     display strings and may change without notice.
///
/// The labels are Thai while the surrounding modal is English. That is deliberate and is
/// the point of the change: the operators using this dropdown read Thai fluently, and a
/// reason picked from a list they actually read is the difference between a real answer
/// and the reflex "." that free text was collecting. Do not translate them and do not
/// append an English gloss.
///
/// The set is fixed at six. Extending it is out of scope (brief §8) — and note the
/// schema deliberately carries no CHECK constraint, so a future addition is a change
/// here plus nothing else.
/// </summary>
public static class VarianceReasonCodes
{
    /// <summary>The one code that requires the free-text note (brief §4.2).</summary>
    public const string Other = "OTHER";

    /// <summary>
    /// Trimmed length a note must reach when the code is OTHER. Three characters stops
    /// "." and "-" — the exact input this change exists to eliminate — without frustrating
    /// a terse but real answer like "mix".
    /// </summary>
    public const int MinNoteLength = 3;

    /// <param name="ValidOver">Offered when the delivery came in above outstanding.</param>
    /// <param name="ValidShort">Offered when it came in below outstanding.</param>
    public sealed record Reason(string Code, string Label, bool ValidOver, bool ValidShort);

    /// <summary>
    /// Declaration order is display order. OTHER sits last on purpose: it is the fallback,
    /// and listing it first would make it the easy click, which is the habit being broken.
    /// </summary>
    private static readonly IReadOnlyList<Reason> Reasons = new[]
    {
        new Reason("OVER_DELIVERY",          "ส่งเกิน",                   ValidOver: true,  ValidShort: false),
        new Reason("SHORT_DELIVERY",         "ส่งขาด",                    ValidOver: false, ValidShort: true),
        new Reason("COUNT_MISMATCH",         "นับได้ต่างจากเอกสาร",        ValidOver: true,  ValidShort: true),
        new Reason("DAMAGED_PARTIAL_RETURN", "ของเสียหาย/ตีกลับบางส่วน",  ValidOver: false, ValidShort: true),
        new Reason("PO_SPLIT_MISMATCH",      "PO แตกไม่ตรงกับการส่ง",      ValidOver: true,  ValidShort: true),
        new Reason(Other,                    "อื่นๆ (ต้องระบุ)",           ValidOver: true,  ValidShort: true),
    };

    /// <summary>Ordinal lookup — codes are machine identifiers, never case-normalized input.</summary>
    private static readonly IReadOnlyDictionary<string, Reason> ByCode =
        Reasons.ToDictionary(r => r.Code, StringComparer.Ordinal);

    public static bool IsKnown(string? code)
        => !string.IsNullOrEmpty(code) && ByCode.ContainsKey(code);

    /// <summary>
    /// Whether the code may be used in this direction. Offering "ส่งเกิน" on a short close
    /// is noise that invites a wrong click, so the UI filters — and the server refuses,
    /// because the UI is advisory (BUILD_PROMPT §7).
    /// </summary>
    public static bool IsValidFor(string? code, VarianceDirection direction)
        => code is not null
           && ByCode.TryGetValue(code, out var r)
           && (direction == VarianceDirection.Over ? r.ValidOver : r.ValidShort);

    /// <summary>Display label, or null for an unknown code. Never returns the code itself:
    /// a caller that renders the fallback would be putting a raw code on screen.</summary>
    public static string? Label(string? code)
        => code is not null && ByCode.TryGetValue(code, out var r) ? r.Label : null;

    /// <summary>The codes offered for a direction, in display order.</summary>
    public static IReadOnlyList<Reason> For(VarianceDirection direction)
        => Reasons.Where(r => direction == VarianceDirection.Over ? r.ValidOver : r.ValidShort).ToList();

    /// <summary>Every reason, in display order — the payload behind the client dropdown.</summary>
    public static IReadOnlyList<Reason> All => Reasons;

    /// <summary>Comma-separated codes valid for a direction, for error messages.</summary>
    public static string ValidCodesFor(VarianceDirection direction)
        => string.Join(", ", For(direction).Select(r => r.Code));
}
