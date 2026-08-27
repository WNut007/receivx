using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Services.Reports;

namespace ReceivingOps.Web.Controllers.Api;

/// <summary>
/// Reports → Pull Sheets. Preview and export, both read-only.
///
///   GET /api/reports/pull-sheets/preview      → metrics + first page of Summary
///   GET /api/reports/pull-sheets/export.xlsx  → the workbook
///
/// Delivery is SYNCHRONOUS — generated in-request and returned. One period in
/// one warehouse is a small result set, and routing it through Hangfire would
/// buy queueing and emailing that nobody asked for while taking on the worker
/// attribution question that is still open in production. The size guard below
/// is what keeps that choice safe; the service already returns bytes, so
/// wrapping it in a job later needs no change on this side either.
/// </summary>
[ApiController]
[Authorize(Policy = "CanViewReports")]
[Route("api/reports/pull-sheets")]
public class PullSheetsApiController : ControllerBase
{
    private const string XlsxContentType =
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    /// <summary>How many Summary rows the on-screen preview shows before the "N more" footer.</summary>
    private const int PreviewRows = 20;

    private readonly IPullSheetExportService _service;
    private readonly IPullRepository _pulls;

    public PullSheetsApiController(IPullSheetExportService service, IPullRepository pulls)
    {
        _service = service;
        _pulls = pulls;
    }

    // ---- Preview -----------------------------------------------------------

    /// <summary>
    /// Runs the SAME query the export runs and reports what it found. A preview
    /// that disagreed with the file it offers would be worse than no preview,
    /// so both go through <see cref="IPullSheetExportService.QueryAsync"/> and
    /// neither has a query of its own.
    /// </summary>
    [HttpGet("preview")]
    public async Task<IActionResult> Preview(
        [FromQuery] Guid? warehouseId,
        [FromQuery] string? date,
        [FromQuery] string? period,
        [FromQuery] string? status,
        CancellationToken ct)
    {
        var (criteria, error) = BuildCriteria(warehouseId, date, period, status);
        if (error is not null) return BadRequest(new { error });

        var result = await _service.QueryAsync(criteria!, ct);

        var over = result.Detail.Count > IPullSheetExportService.DetailRowLimit;
        return Ok(new PullSheetPreviewResponse
        {
            PullCount = result.PullCount,
            ItemCount = result.Summary.Count,
            TotalExpected = result.TotalExpected,
            TotalReceived = result.TotalReceived,
            DetailRowCount = result.Detail.Count,
            SummaryRowCount = result.Summary.Count,
            SummaryPreview = result.Summary.Take(PreviewRows).Select(r => new PullSheetPreviewRow
            {
                PullNumber = r.PullNumber,
                ItemCode = r.ItemCode,
                Description = r.Description,
                VendorName = r.VendorName,
                Building = r.Building,
                ExpectedQty = r.ExpectedQty,
                ReceivedQty = r.ReceivedQty,
                Outstanding = r.Outstanding,
                Progress = r.Progress,
                ItemStatus = r.ItemStatus,
            }).ToList(),
            PeriodLabel = result.PeriodLabel,
            PeriodHours = result.PeriodHours,
            PeriodDateRange = result.PeriodDateRange,
            PullNumbers = result.PullNumbers,
            ExceedsRowLimit = over,
            Message = over ? RowLimitMessage(result.Detail.Count) : null,
        });
    }

    // ---- Export ------------------------------------------------------------

    [HttpGet("export.xlsx")]
    public async Task<IActionResult> Export(
        [FromQuery] Guid? warehouseId,
        [FromQuery] string? date,
        [FromQuery] string? period,
        [FromQuery] string? status,
        CancellationToken ct)
    {
        var (criteria, error) = BuildCriteria(warehouseId, date, period, status);
        if (error is not null) return BadRequest(new { error });

        criteria!.ExportedBy = DisplayName();
        var result = await _service.QueryAsync(criteria, ct);

        if (result.Detail.Count > IPullSheetExportService.DetailRowLimit)
            return BadRequest(new { error = RowLimitMessage(result.Detail.Count) });

        var wb = _service.Build(result, criteria);
        return File(wb.Content, XlsxContentType, wb.FileName);
    }

    // ---- Per-pull export ---------------------------------------------------

    /// <summary>
    /// The Receiving Console's Export button. Same generator, different
    /// criteria — one pull, all 24 hours — which is the whole point of the
    /// criteria object. Warehouse-scoped like every other per-pull route here.
    /// </summary>
    [HttpGet("pull/{id:guid}/export.xlsx")]
    public async Task<IActionResult> ExportPull(Guid id, CancellationToken ct)
    {
        var pull = await _pulls.GetByIdAsync(id, ct);
        if (pull is null) return NotFound();
        if (!User.IsInRole("admin") &&
            pull.WarehouseId != ParseGuid(User.FindFirstValue("warehouseId")))
            return Forbid();

        var criteria = new PullSheetCriteria
        {
            PullId = id,
            WarehouseId = pull.WarehouseId,
            Date = DateOnly.FromDateTime(pull.PullDate),
            ExportedBy = DisplayName(),
        };

        var result = await _service.QueryAsync(criteria, ct);
        if (result.Detail.Count > IPullSheetExportService.DetailRowLimit)
            return BadRequest(new { error = RowLimitMessage(result.Detail.Count) });

        var wb = _service.Build(result, criteria);
        return File(wb.Content, XlsxContentType, wb.FileName);
    }

    // ---- Helpers -----------------------------------------------------------

    /// <summary>
    /// Validates and scopes the query string. Non-admins are pinned to their
    /// session warehouse regardless of what they asked for — the UI only offers
    /// them their own, and this is the gate that makes that more than a
    /// convenience.
    /// </summary>
    private (PullSheetCriteria? Criteria, string? Error) BuildCriteria(
        Guid? warehouseId, string? date, string? period, string? status)
    {
        if (!DateOnly.TryParse(date, out var parsedDate))
            return (null, "Pick a date.");

        var resolved = ReceivingPeriods.ByKey(period);
        if (resolved is null)
            return (null, "Pick a period.");

        if (!string.IsNullOrWhiteSpace(status) && !AllowedStatuses.Contains(status))
            return (null, $"Unknown status '{status}'.");

        var sessionWh = ParseGuid(User.FindFirstValue("warehouseId"));
        var effectiveWh = User.IsInRole("admin") ? warehouseId : sessionWh;

        return (new PullSheetCriteria
        {
            WarehouseId = effectiveWh,
            Date = parsedDate,
            PeriodKey = resolved.Key,
            Status = string.IsNullOrWhiteSpace(status) ? null : status,
            ExportedBy = DisplayName(),
        }, null);
    }

    /// <summary>Mirrors CK_Pulls_Status. 'closed' is here but is not the default — open pulls are the point.</summary>
    private static readonly HashSet<string> AllowedStatuses =
        new(StringComparer.OrdinalIgnoreCase)
        { "pending", "in_progress", "fully_received", "closed" };

    private static string RowLimitMessage(int rows) =>
        $"This selection resolves to {rows:N0} detail rows, over the {IPullSheetExportService.DetailRowLimit:N0} limit. " +
        "Narrow the filter — pick a single warehouse, or a single status — and try again.";

    private string DisplayName() =>
        User.FindFirstValue("displayName")
        ?? User.FindFirstValue(ClaimTypes.Name)
        ?? User.Identity?.Name
        ?? "unknown";

    private static Guid? ParseGuid(string? s) => Guid.TryParse(s, out var g) ? g : null;
}
