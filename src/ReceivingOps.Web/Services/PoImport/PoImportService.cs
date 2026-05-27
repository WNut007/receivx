using System.Text.Json;
using ReceivingOps.Web.Data.Repositories;

namespace ReceivingOps.Web.Services.PoImport;

public class PoImportService : IPoImportService
{
    // Serializer options: camelCase + ignore-null so the persisted JSON
    // matches what the API will surface in 12.5+ (and stays compact —
    // ValidationErrors is stored in dbo.PoImportLog.ValidationErrors which
    // is NVARCHAR(MAX), but the typical row count keeps it well under 1 MB).
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition =
            System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly IPoImportLogRepository _log;
    private readonly IPoImportReader _reader;
    private readonly IAuditService _audit;
    private readonly ILogger<PoImportService> _logger;

    public PoImportService(
        IPoImportLogRepository log,
        IPoImportReader reader,
        IAuditService audit,
        ILogger<PoImportService> logger)
    {
        _log = log;
        _reader = reader;
        _audit = audit;
        _logger = logger;
    }

    public async Task<PoImportSubmissionResult> SubmitForValidationAsync(
        PoImportSubmission submission, CancellationToken ct = default)
    {
        var runId = Guid.NewGuid();

        // 1. Mint the log row up front so a crash during parse still leaves
        //    a 'validating' breadcrumb the operator can see (and ops can
        //    clean up via the list view's stuck-state filter, later).
        await _log.InsertSubmittedAsync(
            runId,
            submission.UploadedBy,
            submission.UploadedByUserId,
            submission.UploadedByRole,
            submission.WarehouseId,
            submission.FileName,
            submission.FileSizeBytes,
            submission.StoragePath,
            ct);

        // Audit the submission. EntityType matches the dbo.PoImportLog
        // table name (without dbo. prefix) for parity with ExportJobsLog
        // audit rows. EntityId is the runId — the canonical key.
        await _audit.WriteSystemAsync(
            submission.UploadedBy,
            "po-import-submit", "PoImportLog", runId.ToString(),
            $"Uploaded {submission.FileName} ({submission.FileSizeBytes:N0} bytes) for WH {submission.WarehouseId}",
            ct);

        // 2. Parse. The reader never throws for content errors — those land
        //    in ValidationErrors. Infra exceptions (file vanished, locked,
        //    corrupt) bubble out; the controller surfaces them as 500.
        var parse = await _reader.ParseAsync(submission.StoragePath, ct);

        // 3. Persist outcome + audit it.
        if (!parse.IsValid)
        {
            // Cap the JSON to a reasonable size — the modal preview never
            // shows more than 50 rows of detail, so persisting 100k is
            // wasteful. Keep the first 1000 + an overflow marker.
            const int persistedErrorsCap = 1000;
            var persistedErrors = parse.ValidationErrors.Count > persistedErrorsCap
                ? parse.ValidationErrors.Take(persistedErrorsCap).ToList()
                : parse.ValidationErrors;

            var errorsJson = JsonSerializer.Serialize(persistedErrors, JsonOpts);

            await _log.MarkValidationFailedAsync(
                runId,
                parse.TotalRows,
                parse.ValidationErrors.Count,
                errorsJson,
                ct);

            await _audit.WriteSystemAsync(
                submission.UploadedBy,
                "po-import-rejected", "PoImportLog", runId.ToString(),
                $"Stage 1 rejected: {parse.ValidationErrors.Count} errors across {parse.TotalRows} rows",
                ct);

            _logger.LogInformation(
                "PoImport {RunId} validation_failed: {ErrorCount} errors / {TotalRows} rows",
                runId, parse.ValidationErrors.Count, parse.TotalRows);

            return new PoImportSubmissionResult
            {
                RunId = runId,
                Status = "validation_failed",
                TotalRowsRead = parse.TotalRows,
                DistinctPoCount = 0,
                ValidationErrorCount = parse.ValidationErrors.Count,
                ValidationErrorsPreview = parse.ValidationErrors
                    .Take(PoImportSubmissionResult.ValidationErrorPreviewCap)
                    .ToList(),
            };
        }

        await _log.MarkValidatedAsync(runId, parse.TotalRows, ct);

        var distinctPoCount = parse.Rows
            .Select(r => r.PoNumber)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();

        await _audit.WriteSystemAsync(
            submission.UploadedBy,
            "po-import-validated", "PoImportLog", runId.ToString(),
            $"Stage 1 passed: {parse.TotalRows} rows / {distinctPoCount} POs awaiting confirm",
            ct);

        _logger.LogInformation(
            "PoImport {RunId} validated: {TotalRows} rows / {Pos} distinct POs",
            runId, parse.TotalRows, distinctPoCount);

        return new PoImportSubmissionResult
        {
            RunId = runId,
            Status = "validated",
            TotalRowsRead = parse.TotalRows,
            DistinctPoCount = distinctPoCount,
            ValidationErrorCount = 0,
            ValidationErrorsPreview = new(),
        };
    }
}
