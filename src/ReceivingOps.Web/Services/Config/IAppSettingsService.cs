namespace ReceivingOps.Web.Services.Config;

/// <summary>
/// Phase 11.1 — single read/write surface for admin-edited configuration
/// values backed by <c>dbo.AppSettings</c>. The service owns:
///
///   * encryption (ASP.NET Data Protection, purpose <c>AppSettings.v1</c>)
///   * precedence resolution (env vars &gt; DB &gt; user-secrets &gt; appsettings.json)
///   * masking (secrets render as <c>"***"</c> in section reads)
///   * audit (every set/delete writes a row to dbo.AuditLog, never logs secret values)
///   * known-secret classification (Smtp:Password, ErpDb:ConnectionString, Exports:SigningKey)
///
/// Registered as <c>Singleton</c> — the encryption protector is thread-safe
/// and the service has no per-request state. Repository + audit dependencies
/// are scoped, resolved per call via IServiceScopeFactory.
/// </summary>
public interface IAppSettingsService
{
    /// <summary>
    /// Returns the effective value for <paramref name="key"/> applying the
    /// precedence chain. Decrypts secrets transparently. Returns null when
    /// the key isn't set in any source.
    /// </summary>
    Task<string?> GetAsync(string key, CancellationToken ct = default);

    /// <summary>
    /// Parses <see cref="GetAsync"/> into <typeparamref name="T"/>. Supported:
    /// <c>string</c>, <c>int</c>, <c>bool</c>, <c>Guid</c>, <c>TimeSpan</c>.
    /// Returns <c>default(T)</c> when the key isn't set or parse fails.
    /// </summary>
    Task<T?> GetTypedAsync<T>(string key, CancellationToken ct = default);

    /// <summary>
    /// Returns every key under <paramref name="prefix"/> (e.g. <c>"Smtp"</c>)
    /// with secrets MASKED as <c>"***"</c>. Safe to render in UI / log.
    /// Combines DB rows with the precedence chain.
    /// </summary>
    Task<IReadOnlyDictionary<string, string?>> GetSectionAsync(string prefix, CancellationToken ct = default);

    /// <summary>
    /// Upserts a value. <paramref name="isSecret"/> is normally derived from
    /// the known-secrets list (<see cref="IsKnownSecret"/>) — pass it explicitly
    /// so the seeder can write in batch without round-trip lookups.
    /// Audit row written via IAuditService with secret values redacted.
    /// </summary>
    Task SetAsync(string key, string? value, bool isSecret, string updatedBy,
        CancellationToken ct = default);

    Task DeleteAsync(string key, string updatedBy, CancellationToken ct = default);

    /// <summary>True for keys that must be stored as EncryptedValue (case-insensitive).</summary>
    bool IsKnownSecret(string key);

    /// <summary>True for keys that must NEVER be written to AppSettings (bootstrap exclusions).</summary>
    bool IsBootstrapExcluded(string key);
}
