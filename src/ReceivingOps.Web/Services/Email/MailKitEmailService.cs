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
/// </summary>
public class MailKitEmailService : IEmailService
{
    private readonly SmtpOptions _opts;
    private readonly ILogger<MailKitEmailService> _log;

    public MailKitEmailService(IOptions<SmtpOptions> opts, ILogger<MailKitEmailService> log)
    {
        _opts = opts.Value;
        _log = log;
    }

    public async Task SendAsync(string toAddress, string subject, string htmlBody, string? textBody = null, CancellationToken ct = default)
    {
        if (!_opts.IsConfigured)
        {
            _log.LogInformation(
                "SMTP not configured — would have sent email to {To} with subject '{Subject}' (body {Bytes} chars). " +
                "Set the Smtp:* user-secrets to enable real sending.",
                toAddress, subject, htmlBody.Length);
            return;
        }

        var msg = new MimeMessage();
        msg.From.Add(new MailboxAddress(_opts.FromName, _opts.FromAddress));
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
        var secure = _opts.UseStartTls ? SecureSocketOptions.StartTls : SecureSocketOptions.SslOnConnect;
        await smtp.ConnectAsync(_opts.Host, _opts.Port, secure, ct);
        if (!string.IsNullOrEmpty(_opts.Username))
        {
            await smtp.AuthenticateAsync(_opts.Username, _opts.Password, ct);
        }
        await smtp.SendAsync(msg, ct);
        await smtp.DisconnectAsync(true, ct);

        _log.LogInformation("Sent email to {To} (subject: '{Subject}')", toAddress, subject);
    }

    /// <summary>Very loose HTML-to-text fallback for the text/plain alternative.</summary>
    private static string StripHtml(string html)
        => System.Text.RegularExpressions.Regex.Replace(html, "<[^>]+>", "").Trim();
}
