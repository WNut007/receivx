using System.Net.Mail;
using System.Security.Cryptography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using NCrontab;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Services.Config;
using ReceivingOps.Web.Services.Email;

namespace ReceivingOps.Web.Controllers.Api;

// Phase 11.2 commit 2 — write surface for the config editor.
//
//   PUT    /api/admin/config/sections/{name}          update non-secrets
//   POST   /api/admin/config/sections/{name}/secret   update ONE secret
//   DELETE /api/admin/config/sections/{name}          reset section to defaults
//   POST   /api/admin/config/exports/regenerate-signing-key
//   POST   /api/admin/config/test/erp                 live SQL connectivity probe
//
// SMTP test send is NOT here — the UI reuses the existing
// /api/admin/email-test endpoint (admin-gated, ships in Phase 8.4+).
//
// Audit + secret encryption are handled by IAppSettingsService.SetAsync /
// DeleteAsync; this controller is only validation + orchestration.
[ApiController]
[Route("api/admin/config")]
[Authorize(Roles = "admin")]
public class ConfigWriteController : ControllerBase
{
    public sealed class UpdateSectionRequest
    {
        /// <summary>Key → new value. Secret keys here are REJECTED — use the /secret endpoint.</summary>
        public Dictionary<string, string?> Values { get; set; } = new();
    }

    public sealed class UpdateSecretRequest
    {
        public string Key { get; set; } = "";
        public string Value { get; set; } = "";
    }

    public sealed class WriteResponse
    {
        public bool Updated { get; set; }
        public int Count { get; set; }
        public bool RequiresRestart { get; set; }
        public IReadOnlyList<string>? ChangedKeys { get; set; }
    }

    public sealed class ErpConnectionTestResponse
    {
        public bool Success { get; set; }
        public string? Server { get; set; }
        public string? Database { get; set; }
        public string? Banner { get; set; }
        public string? Error { get; set; }
    }

    public sealed class RegenerateSigningKeyResponse
    {
        public bool Regenerated { get; set; }
        public string Warning { get; set; } = "";
    }

    /// <summary>v3.1.1 — wrapper for POST /test/smtp (parallel to /test/erp).</summary>
    public sealed class TestSmtpRequest
    {
        public string RecipientEmail { get; set; } = "";
    }

    public sealed class TestSmtpResponse
    {
        public bool Sent { get; set; }
        public string? RecipientEmail { get; set; }
        public string? Error { get; set; }
    }

    private readonly IAppSettingsService _settings;
    private readonly IWarehouseRepository _warehouses;
    private readonly IErpDbConnectionFactory _erpFactory;
    private readonly IEmailService _email;
    private readonly IHostEnvironment _env;
    private readonly ILogger<ConfigWriteController> _log;

    public ConfigWriteController(
        IAppSettingsService settings,
        IWarehouseRepository warehouses,
        IErpDbConnectionFactory erpFactory,
        IEmailService email,
        IHostEnvironment env,
        ILogger<ConfigWriteController> log)
    {
        _settings = settings;
        _warehouses = warehouses;
        _erpFactory = erpFactory;
        _email = email;
        _env = env;
        _log = log;
    }

    // ------------------------------------------------------------------
    // PUT /api/admin/config/sections/{name}
    // ------------------------------------------------------------------
    [HttpPut("sections/{name}")]
    public async Task<IActionResult> UpdateSection(
        string name, [FromBody] UpdateSectionRequest req, CancellationToken ct)
    {
        var section = ResolveSection(name);
        if (section is null) return NotFound(new { error = $"Unknown section '{name}'." });
        if (req is null || req.Values is null || req.Values.Count == 0)
            return BadRequest(new { error = "values is required and must not be empty." });

        // Reject unknown keys (typo guard) + secret keys (must go through POST /secret).
        var allowed = section.Keys.Where(k => !_settings.IsKnownSecret(k))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var key in req.Values.Keys)
        {
            if (_settings.IsKnownSecret(key))
                return BadRequest(new { error = $"'{key}' is a secret — use POST /sections/{name}/secret." });
            if (!allowed.Contains(key))
                return BadRequest(new { error = $"'{key}' is not a known key in section '{name}'." });
        }

        // Validate each value before touching the DB. Surface the first error
        // so the UI can highlight the offending field; per-key validation is
        // cheap enough to not need a multi-error response.
        foreach (var kvp in req.Values)
        {
            var (ok, error) = await ValidateValueAsync(kvp.Key, kvp.Value, ct);
            if (!ok) return BadRequest(new { key = kvp.Key, error });
        }

        var actor = ResolveActor();
        var changed = new List<string>();
        foreach (var kvp in req.Values)
        {
            // Empty / whitespace = clear → SetAsync passes null to UpsertAsync.
            var v = string.IsNullOrWhiteSpace(kvp.Value) ? null : kvp.Value;
            await _settings.SetAsync(kvp.Key, v, isSecret: false, actor, ct);
            changed.Add(kvp.Key);
        }

        _log.LogInformation("Config: section '{Section}' updated by {Actor} — {Count} key(s) changed",
            section.Name, actor, changed.Count);

        return Ok(new WriteResponse
        {
            Updated = true,
            Count = changed.Count,
            RequiresRestart = true,
            ChangedKeys = changed,
        });
    }

    // ------------------------------------------------------------------
    // POST /api/admin/config/sections/{name}/secret
    // ------------------------------------------------------------------
    [HttpPost("sections/{name}/secret")]
    public async Task<IActionResult> UpdateSecret(
        string name, [FromBody] UpdateSecretRequest req, CancellationToken ct)
    {
        var section = ResolveSection(name);
        if (section is null) return NotFound(new { error = $"Unknown section '{name}'." });
        if (req is null || string.IsNullOrWhiteSpace(req.Key))
            return BadRequest(new { error = "key is required." });
        if (!section.Keys.Contains(req.Key, StringComparer.OrdinalIgnoreCase))
            return BadRequest(new { error = $"'{req.Key}' is not part of section '{name}'." });
        if (!_settings.IsKnownSecret(req.Key))
            return BadRequest(new { error = $"'{req.Key}' is not a secret key — use PUT /sections/{name}." });
        if (string.IsNullOrEmpty(req.Value))
            return BadRequest(new { error = "value is required (use DELETE to clear a secret)." });
        if (req.Value.Length > 4000)
            return BadRequest(new { error = "value exceeds 4000 characters." });

        // v3.1.1 gap 9 — SigningKey min length. The Regenerate endpoint
        // always writes 32+ chars (44 actually — base64 of 32 bytes), but a
        // direct /secret call could write a short key; HMAC truncation
        // attacks need ≥256-bit input, so floor at 32.
        if (string.Equals(req.Key, "Exports:SigningKey", StringComparison.OrdinalIgnoreCase)
            && req.Value.Length < 32)
        {
            return BadRequest(new
            {
                key = req.Key,
                error = "SigningKey must be at least 32 characters.",
                actualLength = req.Value.Length,
            });
        }

        // v3.1.1 gap 7 — ErpDb:ConnectionString format sanity. Cheap guard
        // against typos that would only surface at SqlConnection.Open(); we
        // don't try to fully parse the connection string here.
        if (string.Equals(req.Key, "ErpDb:ConnectionString", StringComparison.OrdinalIgnoreCase))
        {
            if (req.Value.IndexOf("Server=", StringComparison.OrdinalIgnoreCase) < 0 ||
                req.Value.IndexOf("Database=", StringComparison.OrdinalIgnoreCase) < 0)
            {
                return BadRequest(new
                {
                    key = req.Key,
                    error = "Connection string must contain 'Server=' and 'Database='.",
                });
            }
        }

        var actor = ResolveActor();
        await _settings.SetAsync(req.Key, req.Value, isSecret: true, actor, ct);

        _log.LogInformation("Config: secret '{Key}' updated by {Actor}", req.Key, actor);

        return Ok(new WriteResponse
        {
            Updated = true,
            Count = 1,
            RequiresRestart = true,
            ChangedKeys = new[] { req.Key },
        });
    }

    // ------------------------------------------------------------------
    // DELETE /api/admin/config/sections/{name}  — reset section
    // ------------------------------------------------------------------
    [HttpDelete("sections/{name}")]
    public async Task<IActionResult> ResetSection(string name, CancellationToken ct)
    {
        var section = ResolveSection(name);
        if (section is null) return NotFound(new { error = $"Unknown section '{name}'." });

        var actor = ResolveActor();
        var deleted = 0;
        foreach (var key in section.Keys)
        {
            await _settings.DeleteAsync(key, actor, ct);
            deleted++;
        }

        _log.LogInformation("Config: section '{Section}' reset by {Actor} — {Count} row(s) deleted",
            section.Name, actor, deleted);

        return Ok(new WriteResponse
        {
            Updated = true,
            Count = deleted,
            RequiresRestart = true,
            ChangedKeys = section.Keys.ToList(),
        });
    }

    // ------------------------------------------------------------------
    // POST /api/admin/config/exports/regenerate-signing-key
    // ------------------------------------------------------------------
    [HttpPost("exports/regenerate-signing-key")]
    public async Task<IActionResult> RegenerateSigningKey(CancellationToken ct)
    {
        // 32 random bytes → 256-bit key, base64-url-safe.
        var raw = RandomNumberGenerator.GetBytes(32);
        var newKey = Convert.ToBase64String(raw);

        var actor = ResolveActor();
        await _settings.SetAsync("Exports:SigningKey", newKey, isSecret: true, actor, ct);

        _log.LogWarning(
            "Exports:SigningKey regenerated by {Actor}. Pending download URLs will be invalidated on restart.",
            actor);

        return Ok(new RegenerateSigningKeyResponse
        {
            Regenerated = true,
            Warning = "Pending download URLs will be invalidated after restart.",
        });
    }

    // ------------------------------------------------------------------
    // POST /api/admin/config/test/erp
    // Live SQL probe using the IErpDbConnectionFactory (which reads
    // ErpDb:ConnectionString through the precedence chain — env > DB >
    // secrets > appsettings). NO ConfigController-side decryption of
    // secrets-in-transit; the factory + framework do it on connection-open.
    // ------------------------------------------------------------------
    [HttpPost("test/erp")]
    public async Task<IActionResult> TestErp(CancellationToken ct)
    {
        try
        {
            using var conn = _erpFactory.Create();
            if (conn is Microsoft.Data.SqlClient.SqlConnection sql)
            {
                await sql.OpenAsync(ct);
                using var cmd = sql.CreateCommand();
                cmd.CommandText = "SELECT @@VERSION";
                cmd.CommandTimeout = 5;
                var banner = (await cmd.ExecuteScalarAsync(ct))?.ToString() ?? "";
                var first = banner.Split('\n').FirstOrDefault()?.Trim() ?? banner;
                return Ok(new ErpConnectionTestResponse
                {
                    Success = true,
                    Server = sql.DataSource,
                    Database = sql.Database,
                    Banner = first.Length > 200 ? first[..200] : first,
                });
            }
            return BadRequest(new ErpConnectionTestResponse
            {
                Success = false,
                Error = "Unsupported connection type (expected SqlConnection).",
            });
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "ERP connection test failed");
            return Ok(new ErpConnectionTestResponse
            {
                Success = false,
                Error = ex.Message,
            });
        }
    }

    // ------------------------------------------------------------------
    // v3.1.1 gap 1 — POST /api/admin/config/test/smtp
    // Thin wrapper around IEmailService for API uniformity — parallel to
    // /test/erp. The existing /api/admin/email-test endpoint (Phase 8.4
    // diagnostic) is unchanged and still serves the same purpose; this
    // endpoint just keeps the test surface on the Config namespace so a
    // future hardening pass can deprecate /api/admin/email-test without
    // breaking the editor.
    // ------------------------------------------------------------------
    [HttpPost("test/smtp")]
    public async Task<IActionResult> TestSmtp([FromBody] TestSmtpRequest req, CancellationToken ct)
    {
        if (req is null || string.IsNullOrWhiteSpace(req.RecipientEmail))
            return BadRequest(new TestSmtpResponse
            {
                Sent = false,
                Error = "recipientEmail is required.",
            });
        if (!MailAddress.TryCreate(req.RecipientEmail, out _))
            return BadRequest(new TestSmtpResponse
            {
                Sent = false,
                Error = "recipientEmail is not a valid email.",
            });

        try
        {
            await _email.SendAsync(
                req.RecipientEmail,
                "Receivx — Config test send",
                "<p>Configuration test successful.</p>" +
                "<p style=\"color:#888;font-size:11px\">Sent by /api/admin/config/test/smtp.</p>",
                ct: ct);
            _log.LogInformation("Config test/smtp sent to {To} by {Actor}", req.RecipientEmail, ResolveActor());
            return Ok(new TestSmtpResponse { Sent = true, RecipientEmail = req.RecipientEmail });
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Config test/smtp failed to {To}", req.RecipientEmail);
            // 200 with sent=false (parallel to /test/erp shape) — the
            // operator wants the error verbatim in the UI panel, not a
            // generic 500.
            return Ok(new TestSmtpResponse
            {
                Sent = false,
                RecipientEmail = req.RecipientEmail,
                Error = ex.Message,
            });
        }
    }

    // ==================================================================
    // Helpers
    // ==================================================================

    private static ConfigController.SectionInfo? ResolveSection(string name) =>
        ConfigController.KnownSections.FirstOrDefault(
            s => string.Equals(s.Name, name, StringComparison.OrdinalIgnoreCase));

    private string ResolveActor() =>
        User.FindFirst("displayName")?.Value ?? User.Identity?.Name ?? "(unknown)";

    /// <summary>Per-key validation. Returns (ok, errorMessage).</summary>
    private async Task<(bool ok, string? error)> ValidateValueAsync(string key, string? value, CancellationToken ct)
    {
        // Empty / null is always valid — clears the row to the appsettings.json default.
        if (string.IsNullOrWhiteSpace(value)) return (true, null);

        switch (key)
        {
            case "Smtp:Port":
                if (!int.TryParse(value, out var port) || port < 1 || port > 65535)
                    return (false, "Port must be an integer between 1 and 65535.");
                return (true, null);

            case "Smtp:UseStartTls":
                if (!bool.TryParse(value, out _))
                    return (false, "UseStartTls must be 'true' or 'false'.");
                return (true, null);

            case "Smtp:FromAddress":
                if (!MailAddress.TryCreate(value, out _))
                    return (false, "FromAddress must be a valid email.");
                return (true, null);

            case "ErpSync:Enabled":
            case "ErpSync:Sources:Bpi:Enabled":
            case "ErpSync:Sources:Prb:Enabled":
                if (!bool.TryParse(value, out _))
                    return (false, "Enabled must be 'true' or 'false'.");
                return (true, null);

            case "ErpSync:CronExpression":
                // NCrontab returns null on parse failure (TryParse-style overload).
                if (CrontabSchedule.TryParse(value) is null)
                    return (false, "CronExpression is not a valid 5-field cron string (e.g. '0 * * * *').");
                return (true, null);

            case "ErpSync:TimeoutSeconds":
                if (!int.TryParse(value, out var t) || t < 60 || t > 3600)
                    return (false, "TimeoutSeconds must be between 60 and 3600.");
                return (true, null);

            // Phase 13.4 — per-source BackfillDays. Parallel cases (instead of
            // sharing one branch) so a future per-source range tweak doesn't
            // need to fork the case.
            case "ErpSync:Sources:Bpi:BackfillDays":
            case "ErpSync:Sources:Prb:BackfillDays":
                if (!int.TryParse(value, out var d) || d < 1 || d > 365)
                    return (false, "BackfillDays must be between 1 and 365.");
                return (true, null);

            case "ErpSync:Sources:Bpi:DefaultWarehouseId":
            case "ErpSync:Sources:Prb:DefaultWarehouseId":
                if (!Guid.TryParse(value, out var whId))
                    return (false, "DefaultWarehouseId must be a valid GUID.");
                if (whId == Guid.Empty) return (true, null);  // explicit "unset" sentinel
                var wh = await _warehouses.GetListRowAsync(whId, ct);
                if (wh is null)
                    return (false, $"Warehouse '{whId}' not found.");
                return (true, null);

            case "Exports:BaseUrl":
                if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
                    || (uri.Scheme != "http" && uri.Scheme != "https"))
                    return (false, "BaseUrl must be an absolute http(s):// URL.");
                // v3.1.1 gap 8 — Production must use https. Download URLs
                // include the HMAC token in the query string; over plain
                // http that token is visible to any on-path observer.
                if (_env.IsProduction() && !string.Equals(uri.Scheme, "https",
                        StringComparison.OrdinalIgnoreCase))
                    return (false, "Production environment requires an https:// BaseUrl.");
                return (true, null);

            // Strings with no parsing rules — accept as-is.
            default:
                return (true, null);
        }
    }
}
