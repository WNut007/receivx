using System.Security.Cryptography;
using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Extensions.Options;
using MimeKit;

namespace ReceivingOps.Web.Services.Email;

/// <summary>
/// Phase 8.4 — Gmail-compatible SMTP transport via MailKit. Uses STARTTLS
/// on port 587 (Gmail's recommended path; SSL on 465 also works but
/// STARTTLS is simpler to configure with most providers).
///
/// Fallback behavior: when <see cref="SmtpOptions.IsConfigured"/> is false
/// (host/from address missing), <c>SendAsync</c> logs the would-be message
/// at Information level and returns. This lets dev environments without
/// SMTP secrets exercise the export flow end-to-end without crashing —
/// operators see "queued; check your email" but the email lives in the
/// log instead. The job still succeeds.
///
/// Resolution of <see cref="SmtpOptions"/> is deferred to <see cref="SendAsync"/>
/// on purpose — see <see cref="ResolveOptions"/>. Constructing this service must
/// stay free of side effects, because DI activates it for every export job.
/// </summary>
public class MailKitEmailService : IEmailService
{
    private readonly IOptions<SmtpOptions> _opts;
    private readonly ILogger<MailKitEmailService> _log;

    public MailKitEmailService(IOptions<SmtpOptions> opts, ILogger<MailKitEmailService> log)
    {
        // Deliberately NOT opts.Value. Reading it here binds SmtpOptions, which
        // runs the Configure callback in Program.cs, which decrypts
        // Smtp:Password via the Data Protection key ring. A missing/rotated key
        // then throws CryptographicException inside this constructor — and since
        // every *ExportJob takes IEmailService, DI could not activate any of
        // them and every export failed before doing any work. Holding IOptions<T>
        // and resolving on demand keeps that cost at the send, where it belongs.
        _opts = opts;
        _log = log;
    }

    public async Task SendAsync(string toAddress, string subject, string htmlBody, string? textBody = null, CancellationToken ct = default)
    {
        var opts = ResolveOptions(toAddress, subject);
        if (opts is null) return;   // key ring can't decrypt the password — logged, skip sending

        if (!opts.IsConfigured)
        {
            _log.LogInformation(
                "SMTP not configured — would have sent email to {To} with subject '{Subject}' (body {Bytes} chars). " +
                "Set the Smtp:* user-secrets to enable real sending.",
                toAddress, subject, htmlBody.Length);
            return;
        }

        var msg = new MimeMessage();
        msg.From.Add(new MailboxAddress(opts.FromName, opts.FromAddress));
        msg.To.Add(MailboxAddress.Parse(toAddress));
        msg.Subject = subject;

        var builder = new BodyBuilder
        {
            HtmlBody = htmlBody,
            TextBody = textBody ?? StripHtml(htmlBody),
        };
        msg.Body = builder.ToMessageBody();

        using var smtp = new SmtpClient();
        // STARTTLS on 587 = SecureSocketOptions.StartTls; legacy SSL on 465
        // would be SslOnConnect. Gmail requires one of these — never None.
        var secure = opts.UseStartTls ? SecureSocketOptions.StartTls : SecureSocketOptions.SslOnConnect;
        await smtp.ConnectAsync(opts.Host, opts.Port, secure, ct);
        if (!string.IsNullOrEmpty(opts.Username))
        {
            await smtp.AuthenticateAsync(opts.Username, opts.Password, ct);
        }
        await smtp.SendAsync(msg, ct);
        await smtp.DisconnectAsync(true, ct);

        _log.LogInformation("Sent email to {To} (subject: '{Subject}')", toAddress, subject);
    }

    /// <summary>
    /// Binds SmtpOptions on demand. Returns null when the Data Protection key
    /// ring can't decrypt Smtp:Password, so the caller skips sending instead of
    /// throwing — an undeliverable notification must not fail the work it was
    /// announcing. Only CryptographicException is caught: anything else is a
    /// real configuration bug and should surface. The warning is the operator's
    /// signal that the key ring needs attention (re-enter the password via
    /// /Config → Email, which re-encrypts under the current key).
    /// </summary>
    private SmtpOptions? ResolveOptions(string toAddress, string subject)
    {
        try
        {
            return _opts.Value;
        }
        catch (CryptographicException ex)
        {
            _log.LogWarning(ex,
                "SMTP options could not be decrypted — skipping email to {To} (subject: '{Subject}'). " +
                "The Data Protection key that encrypted Smtp:Password is missing from the key ring; " +
                "re-enter the password via /Config → Email to re-encrypt it under the current key.",
                toAddress, subject);
            return null;
        }
    }

    /// <summary>Very loose HTML-to-text fallback for the text/plain alternative.</summary>
    private static string StripHtml(string html)
        => System.Text.RegularExpressions.Regex.Replace(html, "<[^>]+>", "").Trim();
}
