using System.Security.Claims;
using FastReport.Export.PdfSimple;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services;

namespace ReceivingOps.Web.Controllers.Api;

// v2.x Phase 7.4 — JSON/HTML API surface for the Reports page.
//   GET /api/reports/do/{id}/preview     → HTML fragment from _DoPreview.cshtml
//   GET /api/reports/do/{id}/export.pdf  → PDF stream (FastReport, multi-page)
[ApiController]
[Authorize(Policy = "CanViewReports")]
[Route("api/reports")]
public class ReportsApiController : Controller
{
    private readonly IDeliveryOrderService _doService;
    private readonly IPullRepository _pulls;
    private readonly IPullSignatureService _sign;
    private readonly IAuthorizationService _authz;

    public ReportsApiController(
        IDeliveryOrderService doService,
        IPullRepository pulls,
        IPullSignatureService sign,
        IAuthorizationService authz)
    {
        _doService = doService;
        _pulls = pulls;
        _sign = sign;
        _authz = authz;
    }

    // GET /api/reports/do/{id}/preview → HTML fragment for the preview pane.
    // Non-admin sessions are restricted to their session warehouse — the
    // scope check happens before BuildData so a forbidden caller doesn't
    // even see the existence-or-not signal in the response timing.
    [HttpGet("do/{id:guid}/preview")]
    public async Task<IActionResult> Preview(Guid id, [FromQuery] string? type, CancellationToken ct)
    {
        try
        {
            if (!await EnsureWarehouseScopeAsync(id, ct)) return Forbid();
            var reportType = ParseReportType(type);
            var data = await _doService.GetReportDataAsync(id, reportType, ct);
            ApplySignEligibility(data);
            // Full path — the api controller's view discovery would look under
            // Views/ReportsApi/ otherwise (controller name → folder mapping).
            var partial = reportType == ReportType.DeliveryOrder
                ? "~/Views/Reports/_DsvOrderPreview.cshtml"
                : "~/Views/Reports/_DoPreview.cshtml";
            return PartialView(partial, data);
        }
        catch (NotFoundException) { return NotFound(); }
        catch (BusinessException ex) { return BadRequest(new { error = ex.Message }); }
    }

    // GET /api/reports/do/{id}/export.pdf → PDF download. Always attachment
    // (the iframe-preview disposition trick from Phase 7.3 is moot now that
    // the preview is an HTML render, not an embedded PDF). Filename uses
    // the pull number so the operator's downloads folder shows
    // PL-XXXX-DO.pdf rather than a bare GUID.
    [HttpGet("do/{id:guid}/export.pdf")]
    public async Task<IActionResult> ExportPdf(Guid id, [FromQuery] string? type, CancellationToken ct)
    {
        try
        {
            if (!await EnsureWarehouseScopeAsync(id, ct)) return Forbid();
            using var report = await _doService.BuildAsync(id, ParseReportType(type), ct);
            using var ms = new MemoryStream();
            using var pdf = new PDFSimpleExport();
            report.Export(pdf, ms);

            var detail = await _pulls.GetByIdAsync(id, ct);
            var filename = $"{(detail?.PullNumber ?? id.ToString())}-DO.pdf";
            Response.Headers["Content-Disposition"] = $"attachment; filename=\"{filename}\"";
            return File(ms.ToArray(), "application/pdf");
        }
        catch (NotFoundException) { return NotFound(); }
        catch (BusinessException ex) { return BadRequest(new { error = ex.Message }); }
    }

    // POST /api/reports/do/{id}/sign — sign one party box (Customer/Warehouse/
    // Production) of a pull. Defense-in-depth: (1) the party-specific CanSign{Party}
    // policy is checked here at runtime; (2) the service re-checks role + warehouse +
    // immutability. Per-pull grain: one signature per (pull, party).
    [HttpPost("do/{id:guid}/sign")]
    public async Task<IActionResult> Sign(Guid id, [FromBody] SignPartyRequest req, CancellationToken ct)
    {
        var party = (req?.Party ?? "").Trim();
        var policy = party.ToLowerInvariant() switch
        {
            "customer"   => "CanSignCustomer",
            "warehouse"  => "CanSignWarehouse",
            "production" => "CanSignProduction",
            _            => null,
        };
        if (policy is null)
            return Problem(
                title: $"Invalid party '{party}'. Expected Customer, Warehouse, or Production.",
                statusCode: 400);

        // Defense-in-depth #1 — the party-specific signer policy (Phase 1).
        var authz = await _authz.AuthorizeAsync(User, policy);
        if (!authz.Succeeded)
            return Problem(title: $"Your role does not permit signing the {party} box.", statusCode: 403);

        try
        {
            // Defense-in-depth #2 — service re-checks role + warehouse + immutability.
            return Ok(await _sign.SignAsync(id, party, ct));
        }
        catch (NotFoundException ex)  { return Problem(title: ex.Message, statusCode: 404); }
        catch (ForbiddenException ex) { return Problem(title: ex.Message, statusCode: 403); }
        catch (BusinessException ex)  { return Problem(title: ex.Message, statusCode: 409); }
    }

    // Sets per-party CanSign on the preview model: the current viewer may sign a
    // box when their whRole matches the party AND their session warehouse matches
    // the pull's AND the box is unsigned. Mirrors the server-side sign guards so
    // a "Sign as {Party}" button only appears when the POST would actually succeed.
    private void ApplySignEligibility(Models.Dtos.DoReportData data)
    {
        var whRole = User.FindFirstValue("whRole") ?? "";
        var sessionWh = Guid.TryParse(User.FindFirstValue("warehouseId"), out var g) ? g : Guid.Empty;
        var whMatch = sessionWh == data.Pull.WarehouseId;

        foreach (var party in data.Pull.Signatures.All)
            party.CanSign = whMatch
                && !party.IsSigned
                && string.Equals(whRole, party.Party.ToLowerInvariant(), StringComparison.Ordinal);
    }

    /// <summary>Returns false when the non-admin caller's warehouse claim doesn't match the pull's warehouse.</summary>
    private async Task<bool> EnsureWarehouseScopeAsync(Guid pullId, CancellationToken ct)
    {
        if (User.IsInRole("admin")) return true;
        var sessionWh = ParseGuid(User.FindFirstValue("warehouseId"));
        var pull = await _pulls.GetByIdAsync(pullId, ct);
        return pull is not null && pull.WarehouseId == sessionWh;
    }

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;

    /// <summary>Maps the ?type= query (order|order-dsv → DeliveryOrder; anything else → DeliveryNote).</summary>
    private static ReportType ParseReportType(string? type) =>
        string.Equals(type, "order", StringComparison.OrdinalIgnoreCase)
            ? ReportType.DeliveryOrder
            : ReportType.DeliveryNote;
}
