using System.Security.Claims;
using Hangfire;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;
using ReceivingOps.Web.Services.PoImport;

namespace ReceivingOps.Web.Controllers.Api;

// Phase 12.5 — public surface for the PO Excel import pipeline.
//
//   POST /api/imports/po/upload         multipart upload — saves to staging,
//                                       runs Stage 1 (parse + validate),
//                                       returns runId + status + preview.
//   POST /api/imports/po/{runId}/confirm enqueue the Hangfire Stage 2 job
//                                       on an already-'validated' log row.
//   GET  /api/imports/po/{runId}        drill-down — used by the operator's
//                                       UI to poll for terminal status.
//
// admin OR supervisor — supervisor's session warehouse is forced onto the
// log row regardless of any form-supplied value (file content does NOT
// determine target warehouse; the spec is explicit on this).
[ApiController]
[Route("api/imports/po")]
[Authorize(Roles = "admin,supervisor")]
public class PoImportController : ControllerBase
{
    // 50 MB is a comfortable ceiling for the 6k-row sample (~3 MB) with
    // headroom for richer future templates. Above this, the operator
    // should be splitting their workbook anyway.
    private const long MaxFileSizeBytes = 50L * 1024 * 1024;

    private readonly IPoImportService _service;
    private readonly IPoImportLogRepository _logRepo;
    private readonly IBackgroundJobClient _bgClient;
    private readonly IAuditService _audit;
    private readonly IWebHostEnvironment _env;
    private readonly ILogger<PoImportController> _logger;

    public PoImportController(
        IPoImportService service,
        IPoImportLogRepository logRepo,
        IBackgroundJobClient bgClient,
        IAuditService audit,
        IWebHostEnvironment env,
        ILogger<PoImportController> logger)
    {
        _service = service;
        _logRepo = logRepo;
        _bgClient = bgClient;
        _audit = audit;
        _env = env;
        _logger = logger;
    }

    public class ConfirmResponse
    {
        public Guid RunId { get; set; }
        public string HangfireJobId { get; set; } = "";
        public string Message { get; set; } = "";
    }

    // -----------------------------------------------------------------
    // POST /api/imports/po/upload
    // -----------------------------------------------------------------
    [HttpPost("upload")]
    [RequestSizeLimit(MaxFileSizeBytes)]
    public async Task<IActionResult> Upload(IFormFile? file, CancellationToken ct)
    {
        if (file is null || file.Length == 0)
            return Problem(title: "A file is required.", statusCode: 400);

        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        if (ext != ".xls" && ext != ".xlsx")
            return Problem(
                title: $"Unsupported file extension: {ext}. Only .xls and .xlsx are accepted.",
                statusCode: 415);

        if (file.Length > MaxFileSizeBytes)
            return Problem(
                title: $"File exceeds {MaxFileSizeBytes / (1024 * 1024)} MB limit.",
                statusCode: 413);

        if (!TryGetRequester(out var userId, out var displayName, out var roleKey, out var sessionWh, out var err))
            return err!;

        // Target warehouse: admin may pass an explicit override via form
        // field; supervisors are pinned to their session WH. The file's
        // content NEVER determines the warehouse (spec invariant).
        Guid warehouseId;
        if (User.IsInRole("admin"))
        {
            // Form override `warehouseId` if provided + valid GUID, else fall
            // back to the admin's own session WH (admins typically don't have
            // a strict session WH — Guid.Empty is allowed; supervisor's path
            // catches the unset-on-non-admin case).
            warehouseId = TryParseFormGuid("warehouseId", out var wh) ? wh : sessionWh;
        }
        else
        {
            if (sessionWh == Guid.Empty)
                return Problem(
                    title: "Your session has no warehouse — contact an admin.",
                    statusCode: 400);
            warehouseId = sessionWh;
        }

        // Stage file to disk before parse — IPoImportReader works on a path.
        // Using runId as the filename so collisions are impossible and the
        // log row's StoragePath round-trips cleanly to the Hangfire worker.
        var stagingDir = ResolveStagingDir();
        Directory.CreateDirectory(stagingDir);
        var runIdGuess = Guid.NewGuid().ToString("N");
        var storagePath = Path.Combine(stagingDir, $"{runIdGuess}{ext}");

        await using (var fs = new FileStream(storagePath, FileMode.CreateNew, FileAccess.Write))
        {
            await file.CopyToAsync(fs, ct);
        }

        try
        {
            var result = await _service.SubmitForValidationAsync(new PoImportSubmission
            {
                FileName = file.FileName,
                StoragePath = storagePath,
                FileSizeBytes = file.Length,
                WarehouseId = warehouseId,
                UploadedBy = displayName,
                UploadedByUserId = userId,
                UploadedByRole = roleKey,
            }, ct);

            _logger.LogInformation(
                "PoImport upload {RunId} by {User} → {Status} ({Rows} rows, {Errors} errors)",
                result.RunId, displayName, result.Status, result.TotalRowsRead, result.ValidationErrorCount);

            return Accepted(result);
        }
        catch
        {
            // Best-effort cleanup if the service throws before persistence —
            // leaves no orphan files on infra errors. The success path leaves
            // the file in place: the Hangfire worker needs it for re-parse.
            try { System.IO.File.Delete(storagePath); } catch { /* swallow */ }
            throw;
        }
    }

    // -----------------------------------------------------------------
    // POST /api/imports/po/{runId}/confirm
    // -----------------------------------------------------------------
    [HttpPost("{runId:guid}/confirm")]
    public async Task<IActionResult> Confirm(Guid runId, CancellationToken ct)
    {
        var log = await _logRepo.GetByRunIdAsync(runId, ct);
        if (log is null) return NotFound();

        if (!TryGetRequester(out var userId, out var displayName, out _, out _, out var err))
            return err!;

        // Ownership: admin may confirm anyone's; supervisor only their own.
        if (!User.IsInRole("admin") && log.UploadedByUserId != userId)
            return Forbid();

        if (!string.Equals(log.Status, "validated", StringComparison.Ordinal))
            return BadRequest(new
            {
                error = $"Cannot confirm — log row is in status '{log.Status}'.",
                expectedStatus = "validated",
                actualStatus = log.Status,
            });

        // Capture actorName here — Hangfire serializes the lambda args, and
        // by the time the worker runs there's no HttpContext. The job's
        // audit rows attribute back to this display name.
        var hangfireJobId = _bgClient.Enqueue<PoImportJob>(j => j.RunAsync(runId, displayName));

        await _logRepo.MarkQueuedAsync(runId, hangfireJobId, ct);

        await _audit.WriteAsync(
            "po-import-confirmed", "PoImportLog", runId.ToString(),
            $"Confirmed import {log.FileName} ({log.TotalRowsRead ?? 0} rows) — Hangfire jobId={hangfireJobId}",
            ct);

        _logger.LogInformation(
            "PoImport {RunId} confirmed by {User} — Hangfire jobId={JobId}",
            runId, displayName, hangfireJobId);

        return Accepted(new ConfirmResponse
        {
            RunId = runId,
            HangfireJobId = hangfireJobId,
            Message = "Import enqueued — poll /api/imports/po/{runId} for terminal status.",
        });
    }

    // -----------------------------------------------------------------
    // GET /api/imports/po/{runId}
    // -----------------------------------------------------------------
    [HttpGet("{runId:guid}")]
    public async Task<IActionResult> Get(Guid runId, CancellationToken ct)
    {
        var log = await _logRepo.GetByRunIdAsync(runId, ct);
        if (log is null) return NotFound();

        if (!TryGetRequester(out var userId, out _, out _, out _, out var err)) return err!;

        // Same ownership rule as confirm.
        if (!User.IsInRole("admin") && log.UploadedByUserId != userId)
            return Forbid();

        return Ok(log);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    private string ResolveStagingDir()
        => Path.Combine(_env.ContentRootPath, "imports", "staging");

    private bool TryGetRequester(
        out Guid userId, out string displayName, out string roleKey,
        out Guid sessionWarehouseId, out IActionResult? errorResult)
    {
        userId = Guid.Empty;
        displayName = "(unknown)";
        roleKey = "";
        sessionWarehouseId = Guid.Empty;
        errorResult = null;

        var sub = User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!Guid.TryParse(sub, out userId))
        {
            errorResult = Problem(title: "Could not identify the requesting user.", statusCode: 401);
            return false;
        }

        displayName = User.FindFirstValue("displayName") ?? User.Identity?.Name ?? "(unknown)";
        roleKey = User.IsInRole("admin") ? "admin"
            : User.IsInRole("supervisor") ? "supervisor"
            : "operator";

        if (Guid.TryParse(User.FindFirstValue("warehouseId"), out var wh))
            sessionWarehouseId = wh;

        return true;
    }

    private bool TryParseFormGuid(string key, out Guid value)
    {
        value = Guid.Empty;
        if (!Request.HasFormContentType) return false;
        var raw = Request.Form[key].ToString();
        return Guid.TryParse(raw, out value);
    }
}
