namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 — runtime config for the export pipeline. Bound from the
/// <c>Exports</c> section (typically appsettings.json — these aren't
/// secrets, just paths + URLs + lifetimes).
///
/// <para>StorageRoot:</para> directory under the app root where generated
/// files land. Defaults to <c>exports/</c> — outside <c>wwwroot/</c> so
/// the static-files middleware can't serve them directly; downloads go
/// through the signed-token controller action.
///
/// <para>SigningKey:</para> HMAC-SHA256 key for download tokens. Treat as a
/// secret in production (set via user-secrets / env vars). Defaults to a
/// dev-only placeholder so missing config doesn't crash; the placeholder
/// is rejected with a startup warning in production (see Program.cs).
///
/// <para>BaseUrl:</para> public root for download links sent via email.
/// Required when SMTP is configured; the email body builds the link as
/// <c>{BaseUrl}/api/exports/{jobId}/download?token=...</c>.
///
/// <para>FileLifetime:</para> how long generated files live before the
/// cleanup job deletes them. Default 24h.
/// </summary>
public class ExportOptions
{
    public string StorageRoot { get; set; } = "exports";
    public string SigningKey  { get; set; } = "DEV-ONLY-PLACEHOLDER-SET-Exports:SigningKey-IN-USER-SECRETS";
    public string BaseUrl     { get; set; } = "http://localhost:5213";
    public TimeSpan FileLifetime { get; set; } = TimeSpan.FromHours(24);
}
