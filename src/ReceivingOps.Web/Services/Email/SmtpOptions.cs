namespace ReceivingOps.Web.Services.Email;

/// <summary>
/// SMTP configuration for the Phase 8.4 export email notifications.
/// Bound from <c>Smtp</c> section — typically lives in <c>user-secrets</c>
/// (or environment variables in prod), NEVER in <c>appsettings.json</c>
/// because the app password is a secret.
///
/// For Gmail SMTP:
///   Host       = "smtp.gmail.com"
///   Port       = 587
///   UseStartTls = true
///   Username   = "you@gmail.com"
///   Password   = "<app password>"   (Google Account → Security → App passwords)
///   FromAddress = "you@gmail.com"
///   FromName    = "ReceivingOps Notifications"
///
/// Leaving Host empty disables the real transport — <c>MailKitEmailService</c>
/// falls back to logging the email so dev environments without SMTP
/// don't crash on every export.
/// </summary>
public class SmtpOptions
{
    public string Host        { get; set; } = "";
    public int    Port        { get; set; } = 587;
    public bool   UseStartTls { get; set; } = true;
    public string Username    { get; set; } = "";
    public string Password    { get; set; } = "";
    public string FromAddress { get; set; } = "";
    public string FromName    { get; set; } = "ReceivingOps Notifications";

    /// <summary>True when at least Host + From are populated — gates whether to attempt real SMTP.</summary>
    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(Host) && !string.IsNullOrWhiteSpace(FromAddress);
}
