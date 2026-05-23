using System.Text.Json;
using System.Text.Json.Serialization;

namespace ReceivingOps.Web.Json;

/// <summary>
/// Forces every <see cref="DateTime"/> we serialize to JSON to be tagged as
/// UTC (ISO 8601 with the trailing <c>Z</c>). The DB stores every timestamp
/// via <c>SYSUTCDATETIME()</c> into <c>DATETIME2</c> columns (no tz info);
/// Dapper materializes those as <see cref="DateTime"/> with
/// <see cref="DateTimeKind.Unspecified"/>, and the default
/// <c>System.Text.Json</c> emitter drops the timezone marker for
/// <c>Unspecified</c>. That makes the browser's <c>new Date(iso)</c> parse
/// the string as <i>local</i> time — so a UTC value comes out displaying
/// as if it were already in the user's tz, off by the user's offset.
///
/// Reading: forward to the framework default (any tz the wire format
/// carries is honored). Writing: assume <c>Unspecified</c> means UTC,
/// convert <c>Local</c> to UTC, and append <c>Z</c>.
/// </summary>
public sealed class UtcDateTimeConverter : JsonConverter<DateTime>
{
    private const string Format = "yyyy-MM-ddTHH:mm:ss.fffZ";

    public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => reader.GetDateTime();

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options)
    {
        var utc = value.Kind switch
        {
            DateTimeKind.Utc         => value,
            DateTimeKind.Local       => value.ToUniversalTime(),
            _                        => DateTime.SpecifyKind(value, DateTimeKind.Utc),
        };
        writer.WriteStringValue(utc.ToString(Format));
    }
}

/// <summary>Sister converter for nullable DateTime fields.</summary>
public sealed class NullableUtcDateTimeConverter : JsonConverter<DateTime?>
{
    private static readonly UtcDateTimeConverter _inner = new();

    public override DateTime? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => reader.TokenType == JsonTokenType.Null ? null : reader.GetDateTime();

    public override void Write(Utf8JsonWriter writer, DateTime? value, JsonSerializerOptions options)
    {
        if (value is null) { writer.WriteNullValue(); return; }
        _inner.Write(writer, value.Value, options);
    }
}
