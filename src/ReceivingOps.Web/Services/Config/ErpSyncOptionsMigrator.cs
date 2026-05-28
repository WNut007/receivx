using ReceivingOps.Web.Data.Repositories;

namespace ReceivingOps.Web.Services.Config;

/// <summary>
/// Phase 13.4 — one-time, idempotent migration that moves v3.2-shape
/// flat <c>ErpSync:DefaultWarehouseId</c> + <c>ErpSync:BackfillDays</c>
/// rows in <c>dbo.AppSettings</c> into the v3.3 nested
/// <c>ErpSync:Sources:Bpi:*</c> location.
///
/// <para>Why a dedicated migrator instead of extending
/// <see cref="AppSettingsSeeder"/>: the seeder is a "first-boot" path
/// (no-ops once the table has any row). This migrator must run on
/// EVERY startup until the flat rows are gone, so an upgrade from a
/// running v3.2 deployment lands cleanly. Each call is cheap (one
/// SELECT on a small table) so the every-startup cost is negligible.</para>
///
/// <para>Preserves operator intent: the existing flat DefaultWarehouseId
/// becomes the BPI source's warehouse (BPI is the legacy default-enabled
/// source). PRB stays untouched (Disabled-by-default per Phase 13.4).</para>
///
/// <para>Idempotent: a no-op when no flat rows exist OR when the nested
/// rows are already set. Safe to run repeatedly.</para>
/// </summary>
public sealed class ErpSyncOptionsMigrator
{
    // Source keys: v3.2 flat shape.
    private const string FlatWarehouseId = "ErpSync:DefaultWarehouseId";
    private const string FlatBackfillDays = "ErpSync:BackfillDays";

    // Target keys: v3.3 nested shape — flat rows always migrate into the
    // BPI sub-config (BPI is the legacy default-enabled source). PRB never
    // receives migrated values; operators set it explicitly via /Config.
    private const string NestedWarehouseId = "ErpSync:Sources:Bpi:DefaultWarehouseId";
    private const string NestedBackfillDays = "ErpSync:Sources:Bpi:BackfillDays";

    private const string MigratorActor = "[system-migrate-13.4]";

    private readonly IAppSettingsService _settings;
    private readonly IAppSettingsRepository _repo;
    private readonly ILogger<ErpSyncOptionsMigrator> _logger;

    public ErpSyncOptionsMigrator(
        IAppSettingsService settings,
        IAppSettingsRepository repo,
        ILogger<ErpSyncOptionsMigrator> logger)
    {
        _settings = settings;
        _repo = repo;
        _logger = logger;
    }

    public async Task RunAsync(CancellationToken ct = default)
    {
        var flatWh = await _repo.GetAsync(FlatWarehouseId, ct);
        var flatBd = await _repo.GetAsync(FlatBackfillDays, ct);

        if (flatWh is null && flatBd is null)
        {
            // No-op fast path — most boots after the first one land here.
            return;
        }

        var migrated = 0;

        if (flatWh is not null && !string.IsNullOrWhiteSpace(flatWh.Value))
        {
            // Only copy if the nested target isn't already populated — preserves
            // operator edits that may have ALREADY filled the new key directly
            // (admin edits the UI between deploy + flat-row sweep).
            var existing = await _repo.GetAsync(NestedWarehouseId, ct);
            if (existing is null || string.IsNullOrWhiteSpace(existing.Value))
            {
                await _settings.SetAsync(NestedWarehouseId, flatWh.Value,
                    isSecret: false, MigratorActor, ct);
                _logger.LogInformation(
                    "ErpSync 13.4 migrator: copied {Flat} -> {Nested}",
                    FlatWarehouseId, NestedWarehouseId);
                migrated++;
            }
            await _settings.DeleteAsync(FlatWarehouseId, MigratorActor, ct);
        }

        if (flatBd is not null && !string.IsNullOrWhiteSpace(flatBd.Value))
        {
            var existing = await _repo.GetAsync(NestedBackfillDays, ct);
            if (existing is null || string.IsNullOrWhiteSpace(existing.Value))
            {
                await _settings.SetAsync(NestedBackfillDays, flatBd.Value,
                    isSecret: false, MigratorActor, ct);
                _logger.LogInformation(
                    "ErpSync 13.4 migrator: copied {Flat} -> {Nested}",
                    FlatBackfillDays, NestedBackfillDays);
                migrated++;
            }
            await _settings.DeleteAsync(FlatBackfillDays, MigratorActor, ct);
        }

        if (migrated > 0)
        {
            _logger.LogInformation(
                "ErpSync 13.4 migrator: migrated {Count} flat row(s) into nested Bpi sub-section + deleted originals",
                migrated);
        }
    }
}
