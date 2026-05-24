namespace ReceivingOps.Web.Services.Email;

/// <summary>
/// Phase 8.4 — minimal transactional email surface. Single method, no
/// templating engine (export notifications are short + plain HTML).
/// The interface exists primarily to enable a substitute in tests
/// (<c>CapturingEmailService</c>) so smokes don't spam real inboxes.
/// </summary>
public interface IEmailService
{
    /// <summary>
    /// Sends a single message. Throws on transport errors; the caller
    /// (background job) decides whether to retry. Plain-text body is
    /// optional — when null, HTML body is used as both alternatives.
    /// </summary>
    Task SendAsync(string toAddress, string subject, string htmlBody, string? textBody = null, CancellationToken ct = default);
}
