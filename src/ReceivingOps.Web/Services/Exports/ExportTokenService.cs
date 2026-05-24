using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;

namespace ReceivingOps.Web.Services.Exports;

/// <summary>
/// Phase 8.4 — HMAC-SHA256 download tokens for export files.
///
/// Wire format: <c>base64url(jobId|expiresAtUtcTicks).base64url(HMAC)</c>
///
/// The download endpoint validates: signature matches, jobId matches the
/// requested file, expiresAt is in the future. Compromise of one token
/// leaks one file for at most ~24h (the file's own lifetime); compromise
/// of the signing key leaks all current + future tokens until rotated.
/// </summary>
public class ExportTokenService
{
    private readonly byte[] _key;

    public ExportTokenService(IOptions<ExportOptions> opts)
    {
        _key = Encoding.UTF8.GetBytes(opts.Value.SigningKey);
    }

    public string Issue(Guid jobId, DateTime expiresAtUtc)
    {
        var payload = $"{jobId:N}|{expiresAtUtc.Ticks}";
        var sig = Compute(payload);
        return UrlEncode(payload) + "." + UrlEncode(sig);
    }

    /// <summary>Returns true when the token is well-formed, untampered, and not expired.</summary>
    public bool Validate(string token, Guid expectedJobId, out DateTime expiresAtUtc)
    {
        expiresAtUtc = default;
        if (string.IsNullOrWhiteSpace(token)) return false;
        var dot = token.IndexOf('.');
        if (dot <= 0 || dot == token.Length - 1) return false;

        byte[] payloadBytes, sigBytes;
        try
        {
            payloadBytes = UrlDecode(token[..dot]);
            sigBytes     = UrlDecode(token[(dot + 1)..]);
        }
        catch { return false; }

        var expected = Compute(Encoding.UTF8.GetString(payloadBytes));
        if (!CryptographicOperations.FixedTimeEquals(expected, sigBytes)) return false;

        var parts = Encoding.UTF8.GetString(payloadBytes).Split('|');
        if (parts.Length != 2) return false;
        if (!Guid.TryParseExact(parts[0], "N", out var jobId)) return false;
        if (jobId != expectedJobId) return false;
        if (!long.TryParse(parts[1], out var ticks)) return false;

        expiresAtUtc = new DateTime(ticks, DateTimeKind.Utc);
        return expiresAtUtc > DateTime.UtcNow;
    }

    private byte[] Compute(string payload)
    {
        using var hmac = new HMACSHA256(_key);
        return hmac.ComputeHash(Encoding.UTF8.GetBytes(payload));
    }

    // base64url: standard base64 with +/= replaced for URL safety.
    private static string UrlEncode(byte[] data)
        => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static string UrlEncode(string s) => UrlEncode(Encoding.UTF8.GetBytes(s));

    private static byte[] UrlDecode(string s)
    {
        var pad = s.Length % 4;
        if (pad > 0) s += new string('=', 4 - pad);
        return Convert.FromBase64String(s.Replace('-', '+').Replace('_', '/'));
    }
}
