using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

/// <summary>
/// Phase 11.1 — Dapper repo for dbo.AppSettings. The repo does ONLY
/// storage; encryption + masking + audit live in AppSettingsService
/// so the same crypto/audit policy applies to every write path.
/// </summary>
public interface IAppSettingsRepository
{
    Task<AppSettingRow?> GetAsync(string key, CancellationToken ct = default);

    /// <summary>
    /// Returns every row whose key starts with <paramref name="prefix"/> +
    /// ':' — e.g. <c>"Smtp"</c> → all <c>Smtp:*</c> rows. Repo returns
    /// raw bytes; the service masks/decrypts.
    /// </summary>
    Task<IReadOnlyList<AppSettingRow>> GetSectionAsync(string prefix, CancellationToken ct = default);

    /// <summary>MERGE upsert. Caller is responsible for picking Value xor EncryptedValue per IsSecret.</summary>
    Task UpsertAsync(string key, string? value, byte[]? encryptedValue, bool isSecret,
        string updatedBy, string? previousValueHash, CancellationToken ct = default);

    Task<int> DeleteAsync(string key, CancellationToken ct = default);

    Task<int> CountAsync(CancellationToken ct = default);
}
