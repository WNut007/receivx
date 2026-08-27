using System.Security.Cryptography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Services.Email;

namespace ReceivingOps.Web.Controllers.Api;

// Phase 8.4+ — admin-gated email diagnostic tools. Two endpoints:
//   GET  /api/admin/smtp-config    inspect what's configured (no credentials)
//   POST /api/admin/email-test     send a test message via the existing
//                                  IEmailService so an admin can verify
//                                  SMTP is reachable + authn works before
//                                  wiring more producers (Pos exports etc.)
//
// Lives under "admin" route prefix + [Authorize(Roles = "admin")] — operators
// don't need to poke at SMTP, and "user can send mail as the server" is
// inherently privileged.
[ApiController]
[Route("api/admin")]
[Authorize(Roles = "admin")]
public class AdminEmailController : ControllerBase
{
    /// <summary>Shown to the admin whenever the key ring can't decrypt the password.</summary>
    private const string KeyRingHelp =
        "The Data Protection key that encrypted Smtp:Password is missing from the key ring. " +
        "Re-enter the password via /Config → Email to re-encrypt it under the current key.";

    private readonly IEmailService _email;
    private readonly IOptions<SmtpOptions> _smtpOpts;
    private readonly ILogger<AdminEmailController> _log;

    public AdminEmailController(
        IEmailService email,
        IOptions<SmtpOptions> smtp,
        ILogger<AdminEmailController> log)
    {
        _email = email;
        // Same rule as MailKitEmailService: never bind SmtpOptions in a
        // constructor. Binding decrypts Smtp:Password, so a missing key ring
        // threw CryptographicException during controller activation and both
        // endpoints 500'd — precisely when an admin came here to find out why
        // email was broken. Resolve per-request via TryResolveSmtp instead.
        _smtpOpts = smtp;
        _log = log;
    }

    /// <summary>
    /// Binds SmtpOptions on demand, returning null when the key ring can't
    /// decrypt the password. Only CryptographicException is caught — any other
    /// binding failure is a real bug and must surface as a 500.
    /// </summary>
    private SmtpOptions? TryResolveSmtp()
    {
        try
        {
            return _smtpOpts.Value;
        }
        catch (CryptographicException ex)
        {
            _log.LogWarning(ex, "SMTP options could not be decrypted. {Help}", KeyRingHelp);
            return null;
        }
    }

    public class EmailTestRequest
    {
        public string To { get; set; } = "";
    }

    public class SmtpConfigResponse
    {
        public string Host { get; set; } = "";
        public int Port { get; set; }
        public bool UseStartTls { get; set; }
        public string FromAddress { get; set; } = "";
        public string FromName { get; set; } = "";
        public bool UsernameConfigured { get; set; }
        public bool PasswordConfigured { get; set; }
        /// <summary>True when MailKitEmailService would attempt real SMTP send (Host + FromAddress + Username + Password all set).</summary>
        public bool FullyConfigured { get; set; }

        /// <summary>
        /// False when the settings could not be read at all — currently only when
        /// the Data Protection key ring can't decrypt Smtp:Password. The other
        /// fields are meaningless in that case; read <see cref="Error"/> instead.
        /// </summary>
        public bool ConfigReadable { get; set; } = true;

        /// <summary>Why the config is unreadable, when <see cref="ConfigReadable"/> is false.</summary>
        public string? Error { get; set; }
    }

    public class EmailTestResponse
    {
        public bool Success { get; set; }
        public string Message { get; set; } = "";
        public DateTime SentAt { get; set; }
        public string SentTo { get; set; } = "";
        public string SmtpHost { get; set; } = "";
        public string SmtpFrom { get; set; } = "";
        public string? Error { get; set; }
        public string? ErrorType { get; set; }
        public string? InnerError { get; set; }
    }

    // GET /api/admin/smtp-config — inspect non-secret SMTP knobs. Returns
    // configured flags for username/password (booleans only — credentials
    // NEVER leave the server).
    [HttpGet("smtp-config")]
    public IActionResult GetSmtpConfig()
    {
        var smtp = TryResolveSmtp();
        if (smtp is null)
        {
            // 200, not 500: "the password can't be decrypted" IS the diagnosis
            // this endpoint exists to deliver. A 500 would tell the admin
            // nothing. The key failure is still logged as a warning above and
            // still crits at startup — nothing is being hidden here.
            return Ok(new SmtpConfigResponse
            {
                ConfigReadable = false,
                Error = KeyRingHelp,
            });
        }

        return Ok(new SmtpConfigResponse
        {
            Host                = smtp.Host ?? "",
            Port                = smtp.Port,
            UseStartTls         = smtp.UseStartTls,
            FromAddress         = smtp.FromAddress ?? "",
            FromName            = smtp.FromName ?? "",
            UsernameConfigured  = !string.IsNullOrWhiteSpace(smtp.Username),
            PasswordConfigured  = !string.IsNullOrWhiteSpace(smtp.Password),
            FullyConfigured     = smtp.IsConfigured
                                  && !string.IsNullOrWhiteSpace(smtp.Username)
                                  && !string.IsNullOrWhiteSpace(smtp.Password),
        });
    }

    // POST /api/admin/email-test — fires a one-shot test via the same
    // IEmailService Hangfire jobs use. Surfaces the underlying exception
    // verbatim (admin-visible only — used to debug app-password / TLS /
    // firewall issues) so the operator doesn't have to dig through logs.
    [HttpPost("email-test")]
    public async Task<IActionResult> TestEmail([FromBody] EmailTestRequest req, CancellationToken ct)
    {
        if (req is null || string.IsNullOrWhiteSpace(req.To) || !IsValidEmail(req.To))
        {
            return BadRequest(new EmailTestResponse
            {
                Success = false,
                Error = "Please provide a valid email address.",
            });
        }

        // Resolve BEFORE sending. MailKitEmailService silently no-ops when the
        // password can't be decrypted, so without this check the test would
        // report "Email sent successfully" while nothing left the building —
        // the worst possible answer from a diagnostic.
        var smtp = TryResolveSmtp();
        if (smtp is null)
        {
            return BadRequest(new EmailTestResponse
            {
                Success   = false,
                SentTo    = req.To,
                Error     = $"SMTP password could not be decrypted — no email was sent. {KeyRingHelp}",
                ErrorType = nameof(CryptographicException),
            });
        }

        var sender = User.Identity?.Name ?? "(unknown)";
        var html = $@"<!DOCTYPE html><html><body style='font-family: Arial, sans-serif; color: #1a1d20; max-width: 600px;'>
<p>This is a <b>test email</b> from ReceivingOps.</p>
<p>If you received this, SMTP is configured correctly.</p>
<table style='border-collapse: collapse; font-size: 12px; color: #5a626c;'>
  <tr><td style='padding: 4px 12px 4px 0;'>Sent at</td><td>{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss} UTC</td></tr>
  <tr><td style='padding: 4px 12px 4px 0;'>SMTP host</td><td>{System.Net.WebUtility.HtmlEncode(smtp.Host ?? "(not set)")}</td></tr>
  <tr><td style='padding: 4px 12px 4px 0;'>From</td><td>{System.Net.WebUtility.HtmlEncode(smtp.FromAddress ?? "(not set)")}</td></tr>
  <tr><td style='padding: 4px 12px 4px 0;'>Triggered by</td><td>{System.Net.WebUtility.HtmlEncode(sender)}</td></tr>
</table>
<p style='color: #8a8f97; font-size: 11px; margin-top: 24px;'>Safe to delete. ReceivingOps — email diagnostic.</p>
</body></html>";

        try
        {
            await _email.SendAsync(req.To, "ReceivingOps — Email Test", html, ct: ct);
            _log.LogInformation("Email test sent to {To} by {User}", req.To, sender);
            return Ok(new EmailTestResponse
            {
                Success  = true,
                Message  = smtp.IsConfigured
                    ? "Email sent successfully."
                    : "SMTP not configured — email was logged instead of sent. Set Smtp:* user-secrets to send real emails.",
                SentAt   = DateTime.UtcNow,
                SentTo   = req.To,
                SmtpHost = smtp.Host ?? "",
                SmtpFrom = smtp.FromAddress ?? "",
            });
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Email test failed to {To}", req.To);
            return BadRequest(new EmailTestResponse
            {
                Success    = false,
                Error      = ex.Message,
                ErrorType  = ex.GetType().Name,
                InnerError = ex.InnerException?.Message,
            });
        }
    }

    private static bool IsValidEmail(string s)
    {
        try { return new System.Net.Mail.MailAddress(s).Address == s; }
        catch { return false; }
    }
}
