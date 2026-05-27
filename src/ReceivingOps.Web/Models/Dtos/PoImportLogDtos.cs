namespace ReceivingOps.Web.Models.Dtos;

/// <summary>
/// Phase 12.3 — read shape for dbo.PoImportLog. Dapper materializes
/// columns by name so the property list mirrors the table exactly.
///
/// <para>State machine (Status column):</para>
/// <list type="bullet">
///   <item><c>validating</c> — file received, pre-flight parser running (transient; usually never persisted because parse is synchronous)</item>
///   <item><c>validation_failed</c> — Stage 1 rejected the file</item>
///   <item><c>validated</c> — Stage 1 passed; awaiting operator confirm</item>
///   <item><c>queued</c> — operator confirmed; Hangfire enqueued</item>
///   <item><c>running</c> — Hangfire worker started RunAsync</item>
///   <item><c>succeeded</c> — atomic insert tx committed</item>
///   <item><c>failed</c> — catastrophic error during Stage 2</item>
/// </list>
/// </summary>
public class PoImportLogRow
{
    public Guid RunId { get; set; }
    public string UploadedBy { get; set; } = "";
    public Guid UploadedByUserId { get; set; }
    public string UploadedByRole { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string FileName { get; set; } = "";
    public long FileSizeBytes { get; set; }
    public string StoragePath { get; set; } = "";
    public string Status { get; set; } = "validating";
    public DateTime SubmittedAt { get; set; }
    public DateTime? StartedAt { get; set; }
    public DateTime? CompletedAt { get; set; }
    public int? ElapsedMs { get; set; }
    public int? TotalRowsRead { get; set; }
    public int? ValidationErrorCount { get; set; }
    public string? ValidationErrors { get; set; }
    public int? PosInserted { get; set; }
    public int? LinesInserted { get; set; }
    public string? ErrorMessage { get; set; }
    public string? HangfireJobId { get; set; }
}
