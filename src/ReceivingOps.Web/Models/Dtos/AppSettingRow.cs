namespace ReceivingOps.Web.Models.Dtos;

/// <summary>
/// Phase 11.1 — raw row shape from dbo.AppSettings. Repo-layer only;
/// service callers consume <c>string?</c> values (decrypt + mask logic
/// lives in AppSettingsService).
/// </summary>
public sealed class AppSettingRow
{
    public string Key { get; set; } = "";
    public string? Value { get; set; }
    public byte[]? EncryptedValue { get; set; }
    public bool IsSecret { get; set; }
    public DateTime UpdatedAt { get; set; }
    public string UpdatedBy { get; set; } = "";
    public string? PreviousValueHash { get; set; }
}
