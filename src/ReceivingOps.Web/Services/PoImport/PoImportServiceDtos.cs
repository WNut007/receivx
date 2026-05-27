namespace ReceivingOps.Web.Services.PoImport;

// ---------------------------------------------------------------------------
// Phase 12.4 — DTOs at the orchestrator boundary.
//
// PoImportSubmission carries everything the service needs to mint a log row
// + parse the file. It is constructed by the controller from the upload
// request (file path on disk, file metadata, session user, target WH).
//
// PoImportSubmissionResult is the Stage 1 outcome — what the controller
// returns to the operator's pre-flight modal. Status is either
// 'validated' (operator may confirm to enqueue Stage 2) or
// 'validation_failed' (operator must re-upload).
// ---------------------------------------------------------------------------

/// <summary>
/// Stage 1 input: file on disk + uploader + target warehouse. Built by
/// the upload controller (12.5+) before handing off to IPoImportService.
/// </summary>
public class PoImportSubmission
{
    /// <summary>Display filename — what the operator picked (e.g. "po-2026-05-27.xlsx").</summary>
    public string FileName { get; set; } = "";

    /// <summary>Absolute path on the server where the upload was saved.</summary>
    public string StoragePath { get; set; } = "";

    /// <summary>Byte size at upload time. Recorded to the log for auditing only.</summary>
    public long FileSizeBytes { get; set; }

    /// <summary>Target warehouse — taken from session for non-admin, from form for admin.</summary>
    public Guid WarehouseId { get; set; }

    /// <summary>Operator display name (used for audit/log; not a unique key).</summary>
    public string UploadedBy { get; set; } = "";

    /// <summary>Operator user id (FK to Users — the unique identity).</summary>
    public Guid UploadedByUserId { get; set; }

    /// <summary>Operator role machine value ("admin" / "supervisor"). Recorded for audit.</summary>
    public string UploadedByRole { get; set; } = "";
}

/// <summary>
/// Stage 1 outcome surfaced to the controller. The persisted log row carries
/// the canonical full data; this DTO is the trimmed shape the JSON API
/// returns to the operator's pre-flight modal.
/// </summary>
public class PoImportSubmissionResult
{
    /// <summary>The minted log RunId. Becomes the URL slug for the confirm endpoint.</summary>
    public Guid RunId { get; set; }

    /// <summary>'validated' or 'validation_failed'. Mirrors PoImportLog.Status.</summary>
    public string Status { get; set; } = "";

    /// <summary>Total data rows the parser attempted (valid + failing). 0 on parser-rejected-extension or no-data-sheet.</summary>
    public int TotalRowsRead { get; set; }

    /// <summary>Distinct PoNumber count among successfully-parsed rows. 0 on failure.</summary>
    public int DistinctPoCount { get; set; }

    /// <summary>Number of failing rows (or 0 if Status='validated').</summary>
    public int ValidationErrorCount { get; set; }

    /// <summary>
    /// First <see cref="ValidationErrorPreviewCap"/> validation errors for the
    /// pre-flight modal. The persisted log row carries the full list as JSON.
    /// </summary>
    public List<PoImportValidationError> ValidationErrorsPreview { get; set; } = new();

    /// <summary>Max items in <see cref="ValidationErrorsPreview"/>. Hard cap of 50 matches the 12.5 modal layout.</summary>
    public const int ValidationErrorPreviewCap = 50;
}
