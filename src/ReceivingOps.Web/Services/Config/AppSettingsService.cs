using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.DataProtection;
using ReceivingOps.Web.Data.Repositories;

namespace ReceivingOps.Web.Services.Config;

public sealed class AppSettingsService : IAppSettingsService
{
    // Versioned purpose string — switching to v2 invalidates old ciphertext,
    // useful as a manual rotation lever later. Don't change this casually.
    private const string ProtectorPurpose = "AppSettings.v1";
    private const string MaskedSecret = "***";

    // Known classifications. Case-insensitive matching is the contract since
    // config keys land here from multiple sources (env var conventions can
    // change casing in transit through some hosts).
    private static readonly HashSet<string> KnownSecretKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "Smtp:Password",
        "ErpDb:ConnectionString",
        "Exports:SigningKey",
    };

    // Bootstrap exclusions — chicken-and-egg keys that must never be stored
    // in the AppSettings table because the storage layer itself depends on
    // them being readable before any DB query runs.
    private static readonly HashSet<string> BootstrapExclusions = new(StringComparer.OrdinalIgnoreCase)
    {
        "ConnectionStrings:Default",
        "DataProtection:KeyDirectory",
        "ASPNETCORE_ENVIRONMENT",
    };

    private readonly IDataProtector _protector;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly IConfiguration _configuration;
    private readonly ILogger<AppSettingsService> _logger;

    public AppSettingsService(
        IDataProtectionProvider dataProtection,
        IServiceScopeFactory scopeFactory,
        IConfiguration configuration,
        ILogger<AppSettingsService> logger)
    {
        _protector = dataProtection.CreateProtector(ProtectorPurpose);
        _scopeFactory = scopeFactory;
        _configuration = configuration;
        _logger = logger;
    }

    public bool IsKnownSecret(string key) => KnownSecretKeys.Contains(key);
    public bool IsBootstrapExcluded(string key) => BootstrapExclusions.Contains(key);

    public async Task<string?> GetAsync(string key, CancellationToken ct = default)
    {
        // 1. Env vars beat everything. ASP.NET's convention: ':' → '__' in env names.
        var envName = key.Replace(":", "__");
        var envVal = Environment.GetEnvironmentVariable(envName);
        if (!string.IsNullOrEmpty(envVal)) return envVal;

        // 2. AppSettings table.
        if (!IsBootstrapExcluded(key))
        {
            using var scope = _scopeFactory.CreateScope();
            var repo = scope.ServiceProvider.GetRequiredService<IAppSettingsRepository>();
            var row = await repo.GetAsync(key, ct);
            if (row is not null)
            {
                if (row.IsSecret)
                {
                    if (row.EncryptedValue is null) return null;  // cleared
                    try
                    {
                        return Encoding.UTF8.GetString(_protector.Unprotect(row.EncryptedValue));
                    }
                    catch (CryptographicException)
                    {
                        // Bubble up so the startup health check can log Critical;
                        // callers in normal request paths see this as a 500 (the
                        // operator's signal that the key ring is wrong).
                        throw;
                    }
                }
                if (row.Value is not null) return row.Value;
                // row exists but cleared — fall through to IConfiguration.
            }
        }

        // 3. user-secrets / appsettings.json (merged by the framework).
        return _configuration[key];
    }

    public async Task<T?> GetTypedAsync<T>(string key, CancellationToken ct = default)
    {
        var raw = await GetAsync(key, ct);
        if (raw is null) return default;

        try
        {
            var t = typeof(T);
            if (t == typeof(string))   return (T)(object)raw;
            if (t == typeof(int))      return (T)(object)int.Parse(raw);
            if (t == typeof(bool))     return (T)(object)bool.Parse(raw);
            if (t == typeof(Guid))     return (T)(object)Guid.Parse(raw);
            if (t == typeof(TimeSpan)) return (T)(object)TimeSpan.Parse(raw);
            throw new NotSupportedException($"GetTypedAsync<{t.Name}> is not supported");
        }
        catch (FormatException ex)
        {
            _logger.LogWarning(ex,
                "AppSettings key {Key} value could not be parsed as {Type}; returning default",
                key, typeof(T).Name);
            return default;
        }
    }

    public async Task<IReadOnlyDictionary<string, string?>> GetSectionAsync(
        string prefix, CancellationToken ct = default)
    {
        var result = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);

        // Start with the IConfiguration view so keys present only in
        // appsettings.json / user-secrets still appear (helpful for the
        // Phase 11.2 UI to render every known key, not just the seeded ones).
        var cfgSection = _configuration.GetSection(prefix);
        foreach (var child in cfgSection.GetChildren())
        {
            var fullKey = $"{prefix}:{child.Key}";
            result[fullKey] = IsKnownSecret(fullKey) ? MaskedSecret : child.Value;
        }

        // Env var overlay — only for keys we already know about (no scanning
        // the whole env block for unrelated vars).
        foreach (var key in result.Keys.ToList())
        {
            var envName = key.Replace(":", "__");
            var envVal = Environment.GetEnvironmentVariable(envName);
            if (!string.IsNullOrEmpty(envVal))
                result[key] = IsKnownSecret(key) ? MaskedSecret : envVal;
        }

        // DB overlay — wins over IConfiguration, loses to env vars (handled
        // above by capturing the env vars before this overlay would have
        // a chance to apply, then re-applying env at the end).
        if (!IsBootstrapExcluded(prefix))
        {
            using var scope = _scopeFactory.CreateScope();
            var repo = scope.ServiceProvider.GetRequiredService<IAppSettingsRepository>();
            var dbRows = await repo.GetSectionAsync(prefix, ct);
            foreach (var row in dbRows)
            {
                if (row.IsSecret)
                {
                    // Mask in section reads — Phase 11.2 UI calls a different
                    // path with explicit "Change" intent to reveal/replace.
                    result[row.Key] = row.EncryptedValue is null ? null : MaskedSecret;
                }
                else
                {
                    result[row.Key] = row.Value;
                }
            }
        }

        // Re-apply env so env vars beat the DB overlay we just did.
        foreach (var key in result.Keys.ToList())
        {
            var envName = key.Replace(":", "__");
            var envVal = Environment.GetEnvironmentVariable(envName);
            if (!string.IsNullOrEmpty(envVal))
                result[key] = IsKnownSecret(key) ? MaskedSecret : envVal;
        }

        return result;
    }

    public async Task SetAsync(string key, string? value, bool isSecret, string updatedBy,
        CancellationToken ct = default)
    {
        if (IsBootstrapExcluded(key))
            throw new InvalidOperationException(
                $"'{key}' is a bootstrap exclusion and must not be stored in AppSettings.");

        using var scope = _scopeFactory.CreateScope();
        var repo = scope.ServiceProvider.GetRequiredService<IAppSettingsRepository>();
        var audit = scope.ServiceProvider.GetRequiredService<IAuditService>();

        var prior = await repo.GetAsync(key, ct);
        var priorHash = ComputePriorHash(prior);

        string? plaintextValue = null;
        byte[]? cipher = null;

        var hasValue = !string.IsNullOrEmpty(value);
        if (hasValue)
        {
            if (isSecret)
                cipher = _protector.Protect(Encoding.UTF8.GetBytes(value!));
            else
                plaintextValue = value;
        }

        await repo.UpsertAsync(key, plaintextValue, cipher, isSecret, updatedBy, priorHash, ct);

        var auditMessage = BuildSetAuditMessage(key, value, isSecret, prior, priorHash);
        await audit.WriteSystemAsync(updatedBy, "config-set", "AppSettings", key, auditMessage, ct);
    }

    public async Task DeleteAsync(string key, string updatedBy, CancellationToken ct = default)
    {
        if (IsBootstrapExcluded(key))
            throw new InvalidOperationException(
                $"'{key}' is a bootstrap exclusion and cannot be deleted from AppSettings.");

        using var scope = _scopeFactory.CreateScope();
        var repo = scope.ServiceProvider.GetRequiredService<IAppSettingsRepository>();
        var audit = scope.ServiceProvider.GetRequiredService<IAuditService>();

        var prior = await repo.GetAsync(key, ct);
        var priorHash = ComputePriorHash(prior);

        var affected = await repo.DeleteAsync(key, ct);
        if (affected == 0) return;  // nothing to audit

        var auditMessage = BuildDeleteAuditMessage(key, prior, priorHash);
        await audit.WriteSystemAsync(updatedBy, "config-delete", "AppSettings", key, auditMessage, ct);
    }

    private static string? ComputePriorHash(Models.Dtos.AppSettingRow? prior)
    {
        if (prior is null) return null;
        byte[]? source = prior.IsSecret
            ? prior.EncryptedValue
            : (prior.Value is null ? null : Encoding.UTF8.GetBytes(prior.Value));
        if (source is null) return null;
        var hash = SHA256.HashData(source);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string BuildSetAuditMessage(string key, string? value, bool isSecret,
        Models.Dtos.AppSettingRow? prior, string? priorHash)
    {
        // Secret values NEVER appear in the audit message — only their hash
        // (post-encrypt) and the redaction marker. Non-secret values are
        // included verbatim so audit drill-down can confirm what changed.
        if (isSecret)
        {
            var verb = string.IsNullOrEmpty(value) ? "Cleared" : "Set";
            return prior is null
                ? $"{verb} {key} (secret value — not logged)"
                : $"{verb} {key} (secret value — not logged) (prior hash: {priorHash ?? "<none>"})";
        }

        var newDisplay = value is null ? "<null>" : $"'{value}'";
        var priorDisplay = prior?.Value is null ? "<none>" : $"'{prior.Value}'";
        return $"Set {key} = {newDisplay} (prior: {priorDisplay})";
    }

    private static string BuildDeleteAuditMessage(string key, Models.Dtos.AppSettingRow? prior, string? priorHash)
    {
        if (prior is null) return $"Deleted {key} (no prior row)";
        if (prior.IsSecret) return $"Deleted {key} (prior: [secret], hash: {priorHash ?? "<none>"})";
        var priorDisplay = prior.Value is null ? "<null>" : $"'{prior.Value}'";
        return $"Deleted {key} (prior: {priorDisplay})";
    }
}
