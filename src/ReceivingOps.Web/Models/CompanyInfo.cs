namespace ReceivingOps.Web.Models;

/// <summary>
/// Static company-level info for the DO report header (Phase 7.3+).
/// Bound from appsettings.json "CompanyInfo" section via
/// IOptions&lt;CompanyInfo&gt; — see Program.cs.
///
/// All fields default to empty string so a missing config section yields
/// a renderable (if blank) header rather than a startup crash. The
/// LogoPath fallback is handled at render time: if the file is missing
/// the report renders a text-only header. Operators ship a real logo by
/// dropping the file at the configured path (typically
/// wwwroot/img/company-logo.png).
/// </summary>
public class CompanyInfo
{
    public string Name     { get; set; } = "";
    public string Address  { get; set; } = "";
    public string Phone    { get; set; } = "";
    public string TaxId    { get; set; } = "";
    /// <summary>Path relative to the app content root (e.g. "wwwroot/img/company-logo.png").</summary>
    public string LogoPath { get; set; } = "";
}
