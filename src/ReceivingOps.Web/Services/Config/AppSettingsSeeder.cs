namespace ReceivingOps.Web.Services.Config;

/// <summary>
/// Phase 11.1 — one-time bootstrap that hydrates dbo.AppSettings from the
/// existing IConfiguration sources (appsettings.json + user-secrets +
/// environment variables) when the table is empty. After the first run,
/// the DB row is authoritative and subsequent edits go through
/// <see cref="IAppSettingsService"/>.
///
/// Idempotent: if any row already exists in AppSettings, the seeder
/// no-ops. It does NOT reconcile — that's an explicit operator decision
/// (Phase 11.2 admin UI may add a "re-import" button).
///
/// Scope: the four known sections (Smtp, ErpDb, Exports, ErpSync) and
/// nothing else. CompanyInfo + Logging stay in appsettings.json. The
/// three bootstrap exclusions (see AppSettingsService) are filtered out
/// even if they happen to appear in IConfiguration.
/// </summary>
public sealed class AppSettingsSeeder
{
    // The sections we own. Order doesn't matter — used only for iteration.
    private static readonly string[] OwnedSections = { "Smtp", "ErpDb", "Exports", "ErpSync" };

    private const string SeedActor = "[system-seed]";

    private readonly IAppSettingsService _settings;
    private readonly Data.Repositories.IAppSettingsRepository _repo;
    private readonly IConfiguration _configuration;
    private readonly ILogger<AppSettingsSeeder> _logger;

    public AppSettingsSeeder(
        IAppSettingsService settings,
        Data.Repositories.IAppSettingsRepository repo,
        IConfiguration configuration,
        ILogger<AppSettingsSeeder> logger)
    {
        _settings = settings;
        _repo = repo;
        _configuration = configuration;
        _logger = logger;
    }

    public async Task RunAsync(CancellationToken ct = default)
    {
        var count = await _repo.CountAsync(ct);
        if (count > 0)
        {
            _logger.LogInformation("AppSettings seeder: table already has {Count} row(s); skipping", count);
            return;
        }

        var written = 0;
        foreach (var section in OwnedSections)
        {
            foreach (var child in _configuration.GetSection(section).GetChildren())
            {
                var fullKey = $"{section}:{child.Key}";

                if (_settings.IsBootstrapExcluded(fullKey))
                {
                    _logger.LogDebug("AppSettings seeder: skipping bootstrap-excluded key {Key}", fullKey);
                    continue;
                }

                var value = child.Value;
                if (string.IsNullOrWhiteSpace(value)) continue;  // empty value — nothing to seed

                var isSecret = _settings.IsKnownSecret(fullKey);
                await _settings.SetAsync(fullKey, value, isSecret, SeedActor, ct);
                written++;
            }
        }

        _logger.LogInformation(
            "AppSettings seeder: wrote {Count} row(s) from IConfiguration into dbo.AppSettings", written);
    }
}
