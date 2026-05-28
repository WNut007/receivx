using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Services.Config;

namespace ReceivingOps.Web.Controllers.Api;

// Phase 11.2 — admin-gated config editor backed by IAppSettingsService.
// Read-only endpoints in this file (GET); writes + tests live in
// ConfigWriteController (Phase 11.2 commit 2) to keep the surface scannable.
//
// Authorization: admin-only. The bootstrap-exclusion keys
// (ConnectionStrings:Default, DataProtection:KeyDirectory, ...) are
// invisible from this surface — IAppSettingsService never returns them
// and the static section metadata below doesn't list them.
[ApiController]
[Route("api/admin/config")]
[Authorize(Roles = "admin")]
public class ConfigController : ControllerBase
{
    // Single source of truth for "what sections does the UI render?". The
    // order here is the order the tabs appear in. Keys inside each section
    // determine which form fields render and in what order.
    //
    // Keep this in sync with:
    //   - AppSettingsSeeder.OwnedSections (which sections the seeder hydrates)
    //   - AppSettingsService.KnownSecretKeys (which keys are encrypted)
    internal static readonly IReadOnlyList<SectionInfo> KnownSections = new[]
    {
        new SectionInfo("Smtp", "Email", new[]
        {
            "Smtp:Host", "Smtp:Port", "Smtp:UseStartTls",
            "Smtp:Username", "Smtp:Password",
            "Smtp:FromAddress", "Smtp:FromName",
        }),
        new SectionInfo("ErpDb", "ERP Connection", new[]
        {
            "ErpDb:ConnectionString",
        }),
        new SectionInfo("ErpSync", "Sync Schedule", new[]
        {
            // Shared keys (Phase 13.4 nested options).
            "ErpSync:Enabled",
            "ErpSync:CronExpression",
            "ErpSync:TimeoutSeconds",
            // BPI source sub-config.
            "ErpSync:Sources:Bpi:Enabled",
            "ErpSync:Sources:Bpi:BackfillDays",
            "ErpSync:Sources:Bpi:DefaultWarehouseId",
            // PRB source sub-config (new in Phase 13.3).
            "ErpSync:Sources:Prb:Enabled",
            "ErpSync:Sources:Prb:BackfillDays",
            "ErpSync:Sources:Prb:DefaultWarehouseId",
        }),
        new SectionInfo("Exports", "Exports", new[]
        {
            "Exports:BaseUrl", "Exports:SigningKey",
        }),
    };

    internal sealed record SectionInfo(string Name, string Label, IReadOnlyList<string> Keys);

    public sealed class SectionsResponse
    {
        public IReadOnlyList<SectionMetaDto> Sections { get; set; } = Array.Empty<SectionMetaDto>();
    }

    public sealed class SectionMetaDto
    {
        public string Name { get; set; } = "";
        public string Label { get; set; } = "";
        public IReadOnlyList<KeyMetaDto> Keys { get; set; } = Array.Empty<KeyMetaDto>();
    }

    public sealed class KeyMetaDto
    {
        public string Key { get; set; } = "";
        public bool IsSecret { get; set; }
    }

    public sealed class SectionDetailResponse
    {
        public string Name { get; set; } = "";
        public string Label { get; set; } = "";
        /// <summary>Key → effective value. Secrets render as "***" (the same masking IAppSettingsService.GetSectionAsync applies).</summary>
        public Dictionary<string, string?> Values { get; set; } = new();
        public IReadOnlyList<KeyMetaDto> Keys { get; set; } = Array.Empty<KeyMetaDto>();
    }

    private readonly IAppSettingsService _settings;

    public ConfigController(IAppSettingsService settings) => _settings = settings;

    /// <summary>
    /// GET /api/admin/config/sections — metadata for the Phase 11.2 tab UI.
    /// Returns 4 sections (Smtp, ErpDb, ErpSync, Exports) with their key
    /// lists + secret classifications. NO values — those come from
    /// the per-section detail endpoint so the UI can lazily render tabs.
    /// </summary>
    [HttpGet("sections")]
    public IActionResult GetSections()
    {
        var dto = new SectionsResponse
        {
            Sections = KnownSections.Select(s => new SectionMetaDto
            {
                Name = s.Name,
                Label = s.Label,
                Keys = s.Keys.Select(k => new KeyMetaDto
                {
                    Key = k,
                    IsSecret = _settings.IsKnownSecret(k),
                }).ToList(),
            }).ToList(),
        };
        return Ok(dto);
    }

    /// <summary>
    /// GET /api/admin/config/sections/{name} — current values for one
    /// section. Secrets are masked as "***" by
    /// <see cref="IAppSettingsService.GetSectionAsync"/>; the UI uses
    /// the explicit "Change" workflow + POST .../secret to write them.
    /// </summary>
    [HttpGet("sections/{name}")]
    public async Task<IActionResult> GetSection(string name, CancellationToken ct)
    {
        var section = KnownSections.FirstOrDefault(
            s => string.Equals(s.Name, name, StringComparison.OrdinalIgnoreCase));
        if (section is null)
            return NotFound(new { error = $"Unknown section '{name}'." });

        var raw = await _settings.GetSectionAsync(section.Name, ct);
        // Project onto only the keys this section declares — keeps the
        // response stable even if other rows live under the same prefix
        // (defensive; the seeder doesn't write any).
        //
        // Phase 13.4 nested keys: IAppSettingsService.GetSectionAsync's
        // IConfiguration overlay walks GetChildren() one level only, so
        // ErpSync:Sources:Bpi:* + Prb:* may not appear in `raw` even
        // when set in appsettings.json. Fall back to per-key GetAsync
        // (which DOES honor the full precedence chain incl. nested
        // IConfiguration access) — 6 extra cheap calls per /Config page
        // load on the Sync Schedule tab.
        var values = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in section.Keys)
        {
            if (raw.TryGetValue(key, out var v) && v != null)
            {
                values[key] = v;
                continue;
            }
            var resolved = await _settings.GetAsync(key, ct);
            // Honor secret masking: GetAsync returns plaintext; the UI must
            // see "***" instead so /Config never round-trips real secrets.
            if (_settings.IsKnownSecret(key) && !string.IsNullOrEmpty(resolved))
                values[key] = "***";
            else
                values[key] = resolved;
        }

        return Ok(new SectionDetailResponse
        {
            Name = section.Name,
            Label = section.Label,
            Values = values,
            Keys = section.Keys.Select(k => new KeyMetaDto
            {
                Key = k,
                IsSecret = _settings.IsKnownSecret(k),
            }).ToList(),
        });
    }
}
