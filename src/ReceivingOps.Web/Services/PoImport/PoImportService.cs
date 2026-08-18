using System.Text.Json;
using ReceivingOps.Web.Data;
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
    private readonly IDbConnectionFactory _factory;
    private readonly ILogger<PoImportService> _logger;

    public PoImportService(
        IPoImportLogRepository log,
        IPoImportReader reader,
        IAuditService audit,
        IDbConnectionFactory factory,
        ILogger<PoImportService> logger)
    {
        _log = log;
        _reader = reader;
        _audit = audit;
        _factory = factory;
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

        // 2b. WIP synthesis guard rails (§4.1). Stage 1 stays read-only and
        //     gains only these checks: a pull sheet that mixes WIP and
        //     non-WIP rows, a WIP sheet with more than one storer code or
        //     delivery date, or a WIP row with an unusable ROUND. All four
        //     have zero occurrences in the production export; if one appears
        //     the right response is a human looking at it, not a guessed
        //     merge rule. Only run when the parse itself is clean — otherwise
        //     the operator gets two unrelated error lists for one upload.
        var wipPlan = parse.IsValid ? WipPullSynthesis.Build(parse.Rows) : new WipSynthesisPlan();
        var allErrors = parse.ValidationErrors.Count > 0 ? parse.ValidationErrors : wipPlan.Errors;

        // 3. Persist outcome + audit it.
        if (allErrors.Count > 0)
        {
            // Cap the JSON to a reasonable size — the modal preview never
            // shows more than 50 rows of detail, so persisting 100k is
            // wasteful. Keep the first 1000 + an overflow marker.
            const int persistedErrorsCap = 1000;
            var persistedErrors = allErrors.Count > persistedErrorsCap
                ? allErrors.Take(persistedErrorsCap).ToList()
                : allErrors;

            var errorsJson = JsonSerializer.Serialize(persistedErrors, JsonOpts);

            await _log.MarkValidationFailedAsync(
                runId,
                parse.TotalRows,
                allErrors.Count,
                errorsJson,
                ct);

            await _audit.WriteSystemAsync(
                submission.UploadedBy,
                "po-import-rejected", "PoImportLog", runId.ToString(),
                $"Stage 1 rejected: {allErrors.Count} errors across {parse.TotalRows} rows",
                ct);

            _logger.LogInformation(
                "PoImport {RunId} validation_failed: {ErrorCount} errors / {TotalRows} rows",
                runId, allErrors.Count, parse.TotalRows);

            return new PoImportSubmissionResult
            {
                RunId = runId,
                Status = "validation_failed",
                TotalRowsRead = parse.TotalRows,
                DistinctPoCount = 0,
                ValidationErrorCount = allErrors.Count,
                ValidationErrorsPreview = allErrors
                    .Take(PoImportSubmissionResult.ValidationErrorPreviewCap)
                    .ToList(),
            };
        }

        await _log.MarkValidatedAsync(runId, parse.TotalRows, ct);

        var distinctPoCount = parse.Rows
            .Select(r => r.PoNumber)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();

        // 4. WIP preview. The confirm modal is the ONLY checkpoint before
        //    pulls and POs commit, so the operator has to see what will be
        //    created — and whether each sheet is a fresh create, a repair of
        //    a sheet whose PO landed before this feature existed, or a skip.
        //    Read-only: Stage 2 re-classifies under UPDLOCK inside its own
        //    transaction and is the authority. This can go stale between here
        //    and confirm, which is exactly why it is advisory.
        var wipSummary = await BuildWipPreviewAsync(wipPlan, ct);

        await _audit.WriteSystemAsync(
            submission.UploadedBy,
            "po-import-validated", "PoImportLog", runId.ToString(),
            $"Stage 1 passed: {parse.TotalRows} rows / {distinctPoCount} POs awaiting confirm" +
            (wipSummary is null
                ? ""
                : $"; WIP synthesis planned: {wipSummary.CreateCount} create, " +
                  $"{wipSummary.RepairCount} repair, {wipSummary.SkipCount} skip " +
                  $"({wipSummary.ItemCount} items / {wipSummary.TotalQty} units)"),
            ct);

        _logger.LogInformation(
            "PoImport {RunId} validated: {TotalRows} rows / {Pos} distinct POs / {WipPulls} WIP pull sheet(s)",
            runId, parse.TotalRows, distinctPoCount, wipSummary?.PullCount ?? 0);

        return new PoImportSubmissionResult
        {
            RunId = runId,
            Status = "validated",
            TotalRowsRead = parse.TotalRows,
            DistinctPoCount = distinctPoCount,
            ValidationErrorCount = 0,
            ValidationErrorsPreview = new(),
            Wip = wipSummary,
        };
    }

    /// <summary>
    /// Turns the plan into the operator-facing summary, classifying each
    /// sheet against what is already in the database. Returns null when the
    /// workbook has no WIP sheets at all — the common case, and the UI shows
    /// nothing rather than an empty section.
    /// </summary>
    private async Task<WipPreviewSummary?> BuildWipPreviewAsync(
        WipSynthesisPlan plan, CancellationToken ct)
    {
        if (!plan.HasWork) return null;

        using var conn = _factory.Create();
        conn.Open();
        var states = await WipSynthesisWriter.ClassifyAsync(
            conn, null, plan.Pulls.Select(p => p.PullNumber), lockRows: false, ct);

        var summary = new WipPreviewSummary();
        foreach (var pull in plan.Pulls)
        {
            var action = states.TryGetValue(pull.PullNumber, out var st)
                ? st.Action
                : WipSheetAction.Create;

            switch (action)
            {
                case WipSheetAction.Create: summary.CreateCount++; break;
                case WipSheetAction.Repair: summary.RepairCount++; break;
                default: summary.SkipCount++; break;
            }

            // Skipped sheets create nothing, so they must not inflate the
            // "will be created" totals the operator reads.
            if (action != WipSheetAction.Skip)
            {
                summary.ItemCount += pull.Items.Count;
                summary.WindowCount += pull.WindowCount;
                summary.TotalQty += pull.TotalQty;
            }

            if (summary.Pulls.Count < WipPreviewSummary.PullPreviewCap)
            {
                summary.Pulls.Add(new WipPreviewPull
                {
                    PullNumber = pull.PullNumber,
                    Action = action.ToString().ToLowerInvariant(),
                    ItemCount = pull.Items.Count,
                    WindowCount = pull.WindowCount,
                    TotalQty = pull.TotalQty,
                    VendorCode = pull.VendorCodeRaw,
                });
            }
        }

        summary.PullCount = plan.PullCount;
        return summary;
    }
}
