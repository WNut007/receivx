using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Services.Exports;

namespace ReceivingOps.Web.Controllers.Api;

// Phase 8.4.4 — public surface for the export pipeline.
//
//   POST /api/exports/transactions       → enqueues a Hangfire job, returns
//                                          { jobId } so the UI can show
//                                          "queued; check your email"
//   GET  /api/exports/{id}/download      → HMAC-signed download. No cookie
//                                          auth check — the token IS the
//                                          authn, so the email recipient can
//                                          download without an active session
//                                          (corp Gmail account ≠ ReceivingOps
//                                          account is common).
[ApiController]
[Route("api/exports")]
public class ExportsApiController : ControllerBase
{
    private readonly IExportService _exports;
    private readonly ExportTokenService _tokens;
    private readonly TransactionsExportJob _jobHelper;
    private readonly ExportOptions _opts;
    private readonly ILogger<ExportsApiController> _log;

    public ExportsApiController(
        IExportService exports,
        ExportTokenService tokens,
        TransactionsExportJob jobHelper,
        IOptions<ExportOptions> opts,
        ILogger<ExportsApiController> log)
    {
        _exports = exports;
        _tokens = tokens;
        _jobHelper = jobHelper;
        _opts = opts.Value;
        _log = log;
    }

    public class EnqueueResponse
    {
        public Guid JobId { get; set; }
        public string Email { get; set; } = "";
        public string Message { get; set; } = "";
    }

    [HttpPost("transactions")]
    [Authorize]
    public IActionResult QueueTransactions([FromBody] TransactionsExportRequest req)
    {
        // Email is the requester's account email (from the auth cookie's
        // email claim). The non-admin warehouse scoping mirrors the
        // /api/transactions endpoint — admins can pass any warehouse, non-
        // admins are pinned to their session warehouse.
        var email = User.FindFirstValue("email");
        var name  = User.FindFirstValue("displayName") ?? User.Identity?.Name ?? "Operator";
        if (string.IsNullOrWhiteSpace(email))
            return Problem(title: "Your account has no email on file — ask an admin to set one.", statusCode: 400);

        var isAdmin = User.IsInRole("admin");
        if (!isAdmin)
        {
            // Force the WH filter to the session warehouse so a non-admin
            // can't ask for an export covering data they can't see.
            var sessionWh = Guid.TryParse(User.FindFirstValue("warehouseId"), out var wh) ? wh : (Guid?)null;
            req.WarehouseId = sessionWh;
            req.WarehouseCode = null;
        }

        var jobId = _exports.EnqueueTransactionsExport(req, email, name);
        _log.LogInformation("Queued transactions export job {JobId} for {Email}", jobId, email);
        return Ok(new EnqueueResponse
        {
            JobId = jobId,
            Email = email,
            Message = $"Export queued. You'll receive an email at {email} when it's ready (usually under a minute).",
        });
    }

    // NOT [Authorize] — the HMAC token is the authn. The recipient may be
    // reading email outside their ReceivingOps session entirely; we don't
    // want to require a cookie round-trip just to download.
    [HttpGet("{id:guid}/download")]
    public IActionResult Download(Guid id, [FromQuery] string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return Problem(title: "Missing token", statusCode: 401);
        if (!_tokens.Validate(token, id, out var expiresAt))
            return Problem(title: "Invalid or expired token", statusCode: 401);

        var (path, fileName) = _jobHelper.ResolveFilePath(id);
        if (!System.IO.File.Exists(path))
        {
            _log.LogWarning("Download for job {JobId} requested but file gone (expected at {Path})", id, path);
            return Problem(title: "Export file no longer available", statusCode: 410);
        }

        Response.Headers["Content-Disposition"] = $"attachment; filename=\"{fileName}\"";
        Response.Headers["X-Token-Expires-At"] = expiresAt.ToString("O");
        var bytes = System.IO.File.ReadAllBytes(path);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
    }
}
