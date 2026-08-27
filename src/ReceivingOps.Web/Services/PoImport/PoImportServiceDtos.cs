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

    /// <summary>
    /// WIP pull synthesis preview — null when the workbook has no WIP pull
    /// sheets. Advisory: Stage 2 re-classifies under UPDLOCK and is the
    /// authority on what actually gets created.
    /// </summary>
    public WipPreviewSummary? Wip { get; set; }
}

// ---------------------------------------------------------------------------
// WIP pull synthesis — preview shape (§5).
//
// The confirm modal is the only checkpoint before rows commit, so the
// operator has to see what a WIP file will create BEFORE confirming. These
// numbers are advisory: Stage 2 re-classifies each sheet under UPDLOCK
// inside its own transaction and is the authority on create / repair / skip.
// ---------------------------------------------------------------------------

/// <summary>
/// What the workbook's WIP pull sheets will do. Null on the result DTO when
/// the file has no WIP sheets — the common case.
/// </summary>
public class WipPreviewSummary
{
    /// <summary>Max sheets listed individually. 25 is the production figure; the cap is headroom.</summary>
    public const int PullPreviewCap = 50;

    /// <summary>WIP pull sheets detected, including ones that will be skipped.</summary>
    public int PullCount { get; set; }

    /// <summary>Sheets with neither pull nor PO — both sides get built.</summary>
    public int CreateCount { get; set; }

    /// <summary>
    /// Sheets whose PO was imported before this feature existed but which
    /// never got a pull. The pull is built; the existing PO and its per-row
    /// lines are left exactly as they are.
    /// </summary>
    public int RepairCount { get; set; }

    /// <summary>Sheets whose pull already exists — nothing is written.</summary>
    public int SkipCount { get; set; }

    /// <summary>Pull items that will be created (skipped sheets excluded).</summary>
    public int ItemCount { get; set; }

    /// <summary>Windows that will be created (skipped sheets excluded).</summary>
    public int WindowCount { get; set; }

    /// <summary>Units across everything that will be created (skipped sheets excluded).</summary>
    public int TotalQty { get; set; }

    /// <summary>Per-sheet detail, capped at <see cref="PullPreviewCap"/>.</summary>
    public List<WipPreviewPull> Pulls { get; set; } = new();
}

public class WipPreviewPull
{
    public string PullNumber { get; set; } = "";

    /// <summary>"create" | "repair" | "skip" — lowercase for the UI.</summary>
    public string Action { get; set; } = "";

    public int ItemCount { get; set; }
    public int WindowCount { get; set; }
    public int TotalQty { get; set; }

    /// <summary>Raw STORER CODE, as it appears in the file.</summary>
    public string? VendorCode { get; set; }
}
