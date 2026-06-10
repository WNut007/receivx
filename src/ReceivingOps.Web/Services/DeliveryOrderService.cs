using System.IO;
using FastReport;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using ReceivingOps.Web.Data.Repositories;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// Path B — Builds the Delivery Order report from a designer-driven .frx
/// template loaded at runtime.
///
/// Pipeline per export:
///   1. GetReportDataAsync — aggregates the DO data into DoReportData
///      (DSV grouping = VendorCode × SubInventory × ToLocation × InvoiceNo).
///   2. EnsureFrxExists — bootstraps Reports/delivery-order.frx on first
///      miss by serializing DeliveryOrderTemplateBuilder.BuildTemplate()
///      to disk. Atomic temp-write + File.Move so concurrent requests on a
///      cold first run can't clobber each other.
///   3. Report.Load — reads the .frx (the same file that FastReport
///      Designer Community edits). Any in-place layout tweak the user
///      makes lands here without a redeploy as long as the .frx stays
///      under ContentRootPath/Reports/.
///   4. RegisterData — attaches the populated DataSet built by
///      DoReportDataSetBuilder (Orders master + Lines detail + OrdersLines
///      relation). Replaces the schema-only DataSet that was embedded in
///      the template at save time.
///   5. Prepare — FastReport iterates the master, runs detail bindings,
///      and produces the page tree; the controller exports via PDFSimpleExport.
///
/// Eligibility checks live in GetReportDataAsync so neither the HTML
/// preview path nor the PDF builder has to duplicate them.
///
/// Stage 6 reservation: warehouse logo and signature PictureObjects are
/// not yet present in delivery-order.frx — the template builder leaves
/// the corresponding regions empty. PDFs through Stage 5 will lack the
/// logo + signature mark (text caption still renders). The smoke-do-report
/// size floor is temporarily relaxed to match this interim.
/// </summary>
public class DeliveryOrderService : IDeliveryOrderService
{
    private readonly IPullRepository _pulls;
    private readonly IWarehouseRepository _warehouses;
    private readonly CompanyInfo _company;
    private readonly IWebHostEnvironment _env;
    private readonly ILogger<DeliveryOrderService> _log;

    public DeliveryOrderService(
        IPullRepository pulls,
        IWarehouseRepository warehouses,
        IOptions<CompanyInfo> company,
        IWebHostEnvironment env,
        ILogger<DeliveryOrderService> log)
    {
        _pulls = pulls;
        _warehouses = warehouses;
        _company = company.Value;
        _env = env;
        _log = log;
    }

    private string GetFrxPath() =>
        Path.Combine(_env.ContentRootPath, "Reports", "delivery-order.frx");

    private bool FrxExists() => File.Exists(GetFrxPath());

    public async Task<DoReportData> GetReportDataAsync(Guid pullId, CancellationToken ct = default)
    {
        var pull = await _pulls.GetByIdAsync(pullId, ct)
            ?? throw new NotFoundException("Pull not found");

        if (!string.Equals(pull.Status, "closed", StringComparison.Ordinal))
            throw new BusinessException(
                "Delivery Order can only be rendered for closed pulls. " +
                "Close the pull first (it must be fully received and signed off).");

        var rows = await _pulls.GetDoReportRowsAsync(pullId, ct);
        if (rows.Count == 0)
            throw new BusinessException(
                "This pull has no delivered receipts. A Delivery Order requires at least one " +
                "non-cancelled receipt to render.");

        // DO identity = OrderId. OrderId is unique per PO line, so each DO is
        // exactly one received line and DeliveryNoteNo = OrderId (DSV's
        // delivery-note-per-OrderId semantics). The former 4-tuple
        // (Vendor × SubInventory × ToLocation × InvoiceNo) is now per-DO
        // display only — with one line per DO each carries a single value.
        //
        // NULL OrderId (a few ERP lines lack it) can't serve as a key / DataSet
        // PK / relation value, so synthesize a deterministic, unique fallback
        // per line and warn so procurement can chase the missing OrderId.
        var pullHex = pull.Id.ToString("N").Substring(0, 8).ToUpperInvariant();

        var orders = rows
            .GroupBy(r => r.OrderId ?? $"{pullHex}-{r.PoNumber}L{r.PoLineNumber}")
            .Select(g =>
            {
                var lines = g.Select(r => new DoLine
                {
                    ItemCode       = r.ItemCode,
                    Description    = r.Description,
                    PoLineNumber   = r.PoLineNumber,
                    PoLineRef      = $"{r.PoNumber}·L{r.PoLineNumber}",
                    TotalQty       = r.TotalQty,
                    LastReceivedAt = r.LastReceivedAt,
                    PalletId       = r.PalletId,
                    OrderId        = r.OrderId,
                    InvoiceNo      = string.IsNullOrEmpty(r.InvoiceNo)    ? null : r.InvoiceNo,
                    KanbanNo       = r.KanbanNo,
                    SubInventory   = string.IsNullOrEmpty(r.SubInventory) ? null : r.SubInventory,
                    ToLocation     = string.IsNullOrEmpty(r.ToLocation)   ? null : r.ToLocation,
                    AsnNo          = r.AsnNo,
                    OrderRound     = r.OrderRound,
                    SourcePoNo     = r.SourcePoNo,
                }).ToList();
                // Per-DO display attributes come from the line(s) in the group —
                // one line per DO, so first == only. Ordinal-min PO# kept as the
                // header PO for parity with the old multi-line behaviour.
                var first = g.First();
                var headerPo = g.Select(r => r.PoNumber)
                                .Where(s => !string.IsNullOrEmpty(s))
                                .OrderBy(s => s, StringComparer.Ordinal)
                                .FirstOrDefault();
                return new DoOrder
                {
                    VendorCode     = string.IsNullOrEmpty(first.VendorCode)   ? null : first.VendorCode,
                    VendorName     = string.IsNullOrEmpty(first.VendorName)   ? null : first.VendorName,
                    SubInventory   = string.IsNullOrEmpty(first.SubInventory) ? null : first.SubInventory,
                    ToLocation     = string.IsNullOrEmpty(first.ToLocation)   ? null : first.ToLocation,
                    InvoiceNo      = string.IsNullOrEmpty(first.InvoiceNo)    ? null : first.InvoiceNo,
                    HeaderPoNumber = headerPo,
                    DeliveryNoteNo = g.Key,                  // = OrderId (or synthesized fallback)
                    LastReceivedAt = lines.Max(l => l.LastReceivedAt),
                    Lines          = lines,
                    TotalQty       = lines.Sum(l => l.TotalQty),
                };
            })
            .OrderBy(o => o.DeliveryNoteNo, StringComparer.Ordinal)
            .ToList();

        // Surface NULL-OrderId fallbacks without blocking the report.
        foreach (var o in orders.Where(o => o.Lines.Any(l => l.OrderId is null)))
            _log.LogWarning(
                "DO report (pull {PullNumber}): line {PoLineRef} has NULL OrderId — " +
                "synthesized DeliveryNoteNo {DeliveryNoteNo}",
                pull.PullNumber, o.Lines[0].PoLineRef, o.DeliveryNoteNo);

        // Per-warehouse logo + address for the DSV header — null when unset.
        var wh = await _warehouses.GetByIdAsync(pull.WarehouseId, ct);

        return new DoReportData
        {
            Pull = new DoPullHeader
            {
                Id                   = pull.Id,
                PullNumber           = pull.PullNumber,
                PullDate             = pull.PullDate,
                ReferenceNumber      = pull.ReferenceNumber,
                WarehouseCode        = pull.WarehouseCode,
                WarehouseName        = pull.WarehouseName,
                WarehouseAddress     = wh?.Address,
                WarehouseLogoDataUrl = wh?.LogoDataUrl,
                ClosedAt             = pull.ClosedAt,
                ClosedByName         = pull.ClosedByName,
                ClosedByRole         = pull.ClosedByRole,
                SignatureSvg         = pull.SignatureSvg,
                TotalQty             = orders.Sum(o => o.TotalQty),
            },
            Orders  = orders,
            Company = _company,
        };
    }

    public async Task<Report> BuildAsync(Guid pullId, CancellationToken ct = default)
    {
        var data = await GetReportDataAsync(pullId, ct);
        return Build(data);
    }

    private Report Build(DoReportData data)
    {
        EnsureFrxExists();

        var report = new Report();
        report.Load(GetFrxPath());

        // Replace the schema-only DataSet that lives in the .frx dictionary
        // with the populated one. RegisterData(name) matches by data-source
        // name, so the bands keep their existing references — only the
        // underlying rows swap.
        var ds = DoReportDataSetBuilder.Build(data);
        report.RegisterData(ds, DoReportDataSetBuilder.DataSetName);

        // Load() can leave registered sources in Enabled=false; re-enable
        // them so the bands actually iterate at Prepare time.
        var ordersDs = report.GetDataSource(DoReportDataSetBuilder.OrdersTableName);
        var linesDs  = report.GetDataSource(DoReportDataSetBuilder.LinesTableName);
        if (ordersDs is not null) ordersDs.Enabled = true;
        if (linesDs  is not null) linesDs.Enabled  = true;

        report.Prepare();
        return report;
    }

    /// <summary>
    /// Hybrid bootstrap (Path B) — on first miss, serialize the programmatic
    /// template to disk so subsequent loads use the same .frx the Designer
    /// edits. Atomic temp-write + File.Move handles concurrent first-run
    /// requests safely: the loser of the race silently discards their temp
    /// copy and reads the winner's file.
    /// </summary>
    private void EnsureFrxExists()
    {
        var finalPath = GetFrxPath();
        if (File.Exists(finalPath)) return;

        var dir = Path.GetDirectoryName(finalPath)!;
        Directory.CreateDirectory(dir);

        var tempPath = finalPath + ".tmp." + Guid.NewGuid().ToString("N");
        using (var template = DeliveryOrderTemplateBuilder.BuildTemplate())
        {
            template.Save(tempPath);
        }

        try
        {
            File.Move(tempPath, finalPath);
        }
        catch (IOException)
        {
            // Another writer beat us to it — drop our copy and use theirs.
            // Re-throw only if the destination is somehow still missing
            // (genuine FS error, not a race).
            if (File.Exists(tempPath)) File.Delete(tempPath);
            if (!File.Exists(finalPath)) throw;
        }
    }
}
