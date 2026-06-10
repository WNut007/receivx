using System.IO;
using FastReport;
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

    public DeliveryOrderService(
        IPullRepository pulls,
        IWarehouseRepository warehouses,
        IOptions<CompanyInfo> company,
        IWebHostEnvironment env)
    {
        _pulls = pulls;
        _warehouses = warehouses;
        _company = company.Value;
        _env = env;
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

        // DO grouping key = (VendorCode × SubInventory × ToLocation × InvoiceNo).
        // VendorName tags along under (VendorCode, VendorName) so the display
        // name surfaces without a second lookup but isn't part of the key.
        // Null parts of the key collapse to "" so all all-null-key lines
        // share one DO instead of LINQ's default split-per-row-on-null.
        var orders = rows
            .GroupBy(r => new
            {
                VendorCode   = r.VendorCode   ?? "",
                VendorName   = r.VendorName   ?? "",
                SubInventory = r.SubInventory ?? "",
                ToLocation   = r.ToLocation   ?? "",
                InvoiceNo    = r.InvoiceNo    ?? "",
            })
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
                    InvoiceNo      = g.Key.InvoiceNo.Length    == 0 ? null : g.Key.InvoiceNo,
                    KanbanNo       = r.KanbanNo,
                    SubInventory   = g.Key.SubInventory.Length == 0 ? null : g.Key.SubInventory,
                    ToLocation     = g.Key.ToLocation.Length   == 0 ? null : g.Key.ToLocation,
                    AsnNo          = r.AsnNo,
                    OrderRound     = r.OrderRound,
                    SourcePoNo     = r.SourcePoNo,
                }).ToList();
                // Dominant PO# for the DSV header — ordinal-min so it's
                // stable when multiple POs feed a single DO.
                var headerPo = g.Select(r => r.PoNumber)
                                .Where(s => !string.IsNullOrEmpty(s))
                                .OrderBy(s => s, StringComparer.Ordinal)
                                .FirstOrDefault();
                return new DoOrder
                {
                    VendorCode     = g.Key.VendorCode.Length   == 0 ? null : g.Key.VendorCode,
                    VendorName     = g.Key.VendorName.Length   == 0 ? null : g.Key.VendorName,
                    SubInventory   = g.Key.SubInventory.Length == 0 ? null : g.Key.SubInventory,
                    ToLocation     = g.Key.ToLocation.Length   == 0 ? null : g.Key.ToLocation,
                    InvoiceNo      = g.Key.InvoiceNo.Length    == 0 ? null : g.Key.InvoiceNo,
                    HeaderPoNumber = headerPo,
                    LastReceivedAt = lines.Max(l => l.LastReceivedAt),
                    Lines          = lines,
                    TotalQty       = lines.Sum(l => l.TotalQty),
                };
            })
            .OrderBy(o => o.VendorCode ?? "")
                .ThenBy(o => o.SubInventory ?? "")
                .ThenBy(o => o.ToLocation ?? "")
                .ThenBy(o => o.InvoiceNo ?? "")
            .ToList();

        // Delivery Note No — deterministic per-DO id: first 8 hex chars of
        // Pull.Id + DO letter by index. Stable across re-renders, no schema
        // change. Q5a says display as "{DN}+{InvoiceNo}".
        var pullHex = pull.Id.ToString("N").Substring(0, 8).ToUpperInvariant();
        for (int i = 0; i < orders.Count; i++)
            orders[i].DeliveryNoteNo = pullHex + IndexToLetters(i);

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

    /// <summary>0 → "A", 25 → "Z", 26 → "AA", … per-DO suffix on Delivery Note No.</summary>
    private static string IndexToLetters(int idx)
    {
        if (idx < 0) throw new ArgumentOutOfRangeException(nameof(idx));
        var s = "";
        do
        {
            s = (char)('A' + (idx % 26)) + s;
            idx = idx / 26 - 1;
        } while (idx >= 0);
        return s;
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
