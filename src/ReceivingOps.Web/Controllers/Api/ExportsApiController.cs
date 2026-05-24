using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services.Exports;

namespace ReceivingOps.Web.Controllers.Api;

// Phase 8.4 — public surface for the export pipeline.
//
//   POST /api/exports/transactions       enqueue Transactions export
//   POST /api/exports/pos                enqueue Purchase Orders export (admin OR supervisor)
//   GET  /api/exports/{id}/download      HMAC-signed download. NOT [Authorize] —
//                                        the HMAC token IS the authn, so the email
//                                        recipient can download from any browser
//                                        without an active ReceivingOps session.
//
// The download endpoint globs the exports/ dir for any file containing the
// jobId hex string — that way each new job type works without touching the
// download path (Transactions writes "transactions-{id}.xlsx", Pos writes
// "pos-{id}.xlsx", future jobs whatever they want).
[ApiController]
[Route("api/exports")]
public class ExportsApiController : ControllerBase
{
    private readonly IExportService _exports;
    private readonly ExportTokenService _tokens;
    private readonly IExportJobLogRepository _jobsLog;
    private readonly ExportOptions _opts;
    private readonly ILogger<ExportsApiController> _log;

    public ExportsApiController(
        IExportService exports,
        ExportTokenService tokens,
        IExportJobLogRepository jobsLog,
        IOptions<ExportOptions> opts,
        ILogger<ExportsApiController> log)
    {
        _exports = exports;
        _tokens = tokens;
        _jobsLog = jobsLog;
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
    public async Task<IActionResult> QueueTransactions([FromBody] TransactionsExportRequest req, CancellationToken ct)
    {
        if (!TryGetRequester(out var userId, out var email, out var name, out var err)) return err!;

        var isAdmin = User.IsInRole("admin");
        if (!isAdmin)
        {
            var sessionWh = Guid.TryParse(User.FindFirstValue("warehouseId"), out var wh) ? wh : (Guid?)null;
            req.WarehouseId = sessionWh;
            req.WarehouseCode = null;
        }

        var jobId = await _exports.EnqueueTransactionsExportAsync(req, userId, email, name, ct);
        _log.LogInformation("Queued transactions export job {JobId} for {Email}", jobId, email);
        return Accepted(new EnqueueResponse
        {
            JobId = jobId,
            Email = email,
            Message = $"Export queued. You'll receive an email at {email} when it's ready (usually under a minute).",
        });
    }

    [HttpPost("pos")]
    [Authorize(Roles = "admin,supervisor")]
    public async Task<IActionResult> QueuePos([FromBody] PosExportRequest req, CancellationToken ct)
    {
        if (!TryGetRequester(out var userId, out var email, out var name, out var err)) return err!;

        if (!User.IsInRole("admin"))
        {
            var sessionWh = Guid.TryParse(User.FindFirstValue("warehouseId"), out var wh) ? wh : (Guid?)null;
            req.WarehouseId = sessionWh;
        }

        var jobId = await _exports.EnqueuePosExportAsync(req, userId, email, name, ct);
        _log.LogInformation("Queued POs export job {JobId} for {Email}", jobId, email);
        return Accepted(new EnqueueResponse
        {
            JobId = jobId,
            Email = email,
            Message = $"Export queued. You'll receive an email at {email} when it's ready (usually under a minute).",
        });
    }

    [HttpPost("audit-log")]
    [Authorize(Roles = "admin")]
    public async Task<IActionResult> QueueAuditLog([FromBody] AuditLogExportRequest req, CancellationToken ct)
    {
        if (!TryGetRequester(out var userId, out var email, out var name, out var err)) return err!;

        var jobId = await _exports.EnqueueAuditLogExportAsync(req, userId, email, name, ct);
        _log.LogInformation("Queued audit-log export job {JobId} for {Email}", jobId, email);
        return Accepted(new EnqueueResponse
        {
            JobId = jobId,
            Email = email,
            Message = $"Export queued. You'll receive an email at {email} when it's ready (usually under a minute).",
        });
    }

    [HttpGet("{id:guid}/download")]
    public IActionResult Download(Guid id, [FromQuery] string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return Problem(title: "Missing token", statusCode: 401);
        if (!_tokens.Validate(token, id, out var expiresAt))
            return Problem(title: "Invalid or expired token", statusCode: 401);

        // Find the file by jobId hex — each job type names its file with a
        // different prefix (transactions-, pos-, audit-log-, …). Globbing
        // the directory keeps this endpoint agnostic of the producer.
        var dir = ResolveExportDir();
        var idHex = id.ToString("N");
        var matches = Directory.Exists(dir)
            ? Directory.GetFiles(dir, $"*{idHex}*.xlsx")
            : Array.Empty<string>();
        if (matches.Length == 0)
        {
            _log.LogWarning("Download for job {JobId} requested but no file found in {Dir}", id, dir);
            return Problem(title: "Export file no longer available", statusCode: 410);
        }

        var path = matches[0];
        var fileName = Path.GetFileName(path);
        Response.Headers["Content-Disposition"] = $"attachment; filename=\"{fileName}\"";
        Response.Headers["X-Token-Expires-At"] = expiresAt.ToString("O");
        var bytes = System.IO.File.ReadAllBytes(path);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
    }

    // GET /api/exports/jobs — list the requester's recent export jobs.
    // ?all=true (admin only) widens to everyone's exports. Paginated.
    //
    // EffectiveStatus is derived: a Status='succeeded' job whose file has
    // been swept off disk past Exports:FileLifetime is "expired" (the row
    // stays so the operator can see "yes I asked for that 3 days ago").
    // Download URLs are only emitted for actually-downloadable rows.
    [HttpGet("jobs")]
    [Authorize]
    public async Task<ActionResult<PaginatedResponse<ExportJobView>>> ListJobs(
        [FromQuery] bool all = false,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 50,
        [FromQuery] string? tab = null,
        CancellationToken ct = default)
    {
        var userId = Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var u) ? u : Guid.Empty;
        if (userId == Guid.Empty)
            return Problem(title: "Could not identify the requesting user.", statusCode: 401);

        var isAdmin = User.IsInRole("admin");
        Guid? scope = (all && isAdmin) ? null : userId;

        var req = new PaginatedRequest { Page = page, PageSize = pageSize };
        var (rows, total) = await _jobsLog.QueryPagedAsync(scope, tab, req.Skip, req.Take, ct);

        // File existence check per row — used to flip succeeded→expired.
        // One Directory.GetFiles call per request, then HashSet lookups
        // (fast enough for the 50-row page; if this becomes a hot path
        // we can move to a dedicated FileExists per id).
        var dir = ResolveExportDir();
        var presentIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (Directory.Exists(dir))
        {
            foreach (var path in Directory.EnumerateFiles(dir, "*.xlsx"))
            {
                // Extract any 32-hex sequence in the filename (jobId in N form).
                var name = Path.GetFileNameWithoutExtension(path);
                var match = System.Text.RegularExpressions.Regex.Match(name, "[0-9a-fA-F]{32}");
                if (match.Success) presentIds.Add(match.Value);
            }
        }

        var expiresAt = DateTime.UtcNow.Add(_opts.FileLifetime);
        var items = rows.Select(r => new ExportJobView
        {
            Id = r.Id,
            JobType = r.JobType,
            Status = r.Status,
            EffectiveStatus = DeriveEffectiveStatus(r, presentIds),
            EnqueuedAt = r.EnqueuedAt,
            StartedAt = r.StartedAt,
            CompletedAt = r.CompletedAt,
            FileName = r.FileName,
            RowsExported = r.RowsExported,
            ErrorMessage = r.ErrorMessage,
            DownloadUrl = BuildDownloadUrl(r, presentIds, expiresAt),
            DownloadedAt = r.DownloadedAt,
            // Always populate requester fields — useful for self-identification
            // on the per-user view ("yes that's mine") and required for the
            // admin see-all view. Privacy is enforced by the WHERE scope above
            // (non-admin only sees their own rows), not by field omission.
            RequesterEmail = r.RequesterEmail,
            RequesterName  = r.RequesterName,
        }).ToList();

        return Ok(new PaginatedResponse<ExportJobView>
        {
            Items = items,
            Page = Math.Max(1, page),
            PageSize = req.Take,
            Total = total,
        });
    }

    private static string DeriveEffectiveStatus(ExportJobLogRow row, HashSet<string> presentIds)
    {
        if (row.Status != "succeeded") return row.Status;
        return presentIds.Contains(row.Id.ToString("N")) ? "succeeded" : "expired";
    }

    private string? BuildDownloadUrl(ExportJobLogRow row, HashSet<string> presentIds, DateTime expiresAt)
    {
        if (row.Status != "succeeded") return null;
        if (!presentIds.Contains(row.Id.ToString("N"))) return null;
        // Same HMAC pattern the email path uses. The browser session is
        // already authenticated so the URL is consumed in the same tab;
        // still HMAC-gated to keep the surface uniform with the email-
        // delivered links.
        var token = _tokens.Issue(row.Id, expiresAt);
        return $"/api/exports/{row.Id:D}/download?token={token}";
    }

    // GET /api/exports/unread-count — drives the nav-bar badge. Counts
    // succeeded jobs whose file is still on disk (operator can act on
    // them). Per-user only — non-admin "see all" mode doesn't widen the
    // badge because the badge represents "things I haven't downloaded yet."
    [HttpGet("unread-count")]
    [Authorize]
    public async Task<IActionResult> UnreadCount(CancellationToken ct)
    {
        var userId = Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var u) ? u : Guid.Empty;
        if (userId == Guid.Empty) return Ok(new { count = 0 });

        var present = SnapshotPresentIds();
        var count = await _jobsLog.CountUnreadSucceededAsync(userId, present, ct);
        return Ok(new { count });
    }

    // POST /api/exports/mark-all-read — fired by the My Exports page on
    // visit (auto-dismiss). Returns the affected row count for the smoke.
    [HttpPost("mark-all-read")]
    [Authorize]
    public async Task<IActionResult> MarkAllRead(CancellationToken ct)
    {
        var userId = Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var u) ? u : Guid.Empty;
        if (userId == Guid.Empty) return Ok(new { marked = 0 });

        var marked = await _jobsLog.MarkAllUnreadAsReadAsync(userId, ct);
        return Ok(new { marked });
    }

    // GET /api/exports/tab-counts — Pending vs Downloaded badge numbers
    // for the 2-tab My Exports layout. Scope mirrors ListJobs: admin can
    // opt into ?all=true to see everyone; default is per-user.
    //
    // Pending count is "actionable" — queued|running|failed plus the
    // subset of succeeded-undownloaded rows whose files are still on
    // disk. Expired rows aren't counted (operator can't act on them).
    [HttpGet("tab-counts")]
    [Authorize]
    public async Task<ActionResult<ExportTabCounts>> TabCounts(
        [FromQuery] bool all = false,
        CancellationToken ct = default)
    {
        var userId = Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var u) ? u : Guid.Empty;
        if (userId == Guid.Empty)
            return Problem(title: "Could not identify the requesting user.", statusCode: 401);

        var isAdmin = User.IsInRole("admin");
        Guid? scope = (all && isAdmin) ? null : userId;

        var present = SnapshotPresentIds();
        var counts = await _jobsLog.GetTabCountsAsync(scope, present, ct);
        return Ok(counts);
    }

    // POST /api/exports/{id}/mark-downloaded — fired by the My Exports
    // page when the operator clicks Download. Stamps DownloadedAt on the
    // row so it moves from Pending → Downloaded. Privacy guard lives in
    // the repo (WHERE RequesterUserId = @UserId); 404 = no row updated
    // (wrong user OR already-marked OR not-yet-succeeded). Idempotent —
    // re-click after marked returns 404 with no state change.
    [HttpPost("{id:guid}/mark-downloaded")]
    [Authorize]
    public async Task<IActionResult> MarkDownloaded(Guid id, CancellationToken ct)
    {
        var userId = Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var u) ? u : Guid.Empty;
        if (userId == Guid.Empty)
            return Problem(title: "Could not identify the requesting user.", statusCode: 401);

        var affected = await _jobsLog.MarkDownloadedAsync(id, userId, ct);
        if (affected == 0)
            return NotFound(new { id, message = "Not your row, already marked, or not yet succeeded." });

        return Ok(new { id, downloadedAt = DateTime.UtcNow });
    }

    /// <summary>One disk scan → HashSet of jobId hex strings for the present XLSX files. Same pattern as ListJobs.</summary>
    private HashSet<string> SnapshotPresentIds()
    {
        var dir = ResolveExportDir();
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(dir)) return set;
        foreach (var path in Directory.EnumerateFiles(dir, "*.xlsx"))
        {
            var name = Path.GetFileNameWithoutExtension(path);
            var match = System.Text.RegularExpressions.Regex.Match(name, "[0-9a-fA-F]{32}");
            if (match.Success) set.Add(match.Value);
        }
        return set;
    }

    /// <summary>Same path-resolution logic the job classes use — kept local so the controller doesn't take a job dependency just for one helper.</summary>
    private string ResolveExportDir()
    {
        return Path.IsPathRooted(_opts.StorageRoot)
            ? _opts.StorageRoot
            : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", _opts.StorageRoot));
    }

    /// <summary>Pulls the requester's userId + email + display name from the auth cookie. Returns 400 when email or userId missing.</summary>
    private bool TryGetRequester(out Guid userId, out string email, out string name, out IActionResult? error)
    {
        userId = Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var id) ? id : Guid.Empty;
        email  = User.FindFirstValue("email") ?? "";
        name   = User.FindFirstValue("displayName") ?? User.Identity?.Name ?? "Operator";
        if (userId == Guid.Empty)
        {
            error = Problem(title: "Could not identify the requesting user.", statusCode: 401);
            return false;
        }
        if (string.IsNullOrWhiteSpace(email))
        {
            error = Problem(title: "Your account has no email on file — ask an admin to set one.", statusCode: 400);
            return false;
        }
        error = null;
        return true;
    }
}
