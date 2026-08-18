using System.Data;
using Dapper;

namespace ReceivingOps.Web.Services.PoImport;

// ---------------------------------------------------------------------------
// WIP pull synthesis — the write.
//
// Classification and the INSERTs, both taking an open connection (+ optional
// transaction) so Stage 1 can classify read-only for the preview and Stage 2
// can classify and write inside the sheet's own transaction. Pull, items,
// windows and the PO commit or roll back together: a half-built pull with no
// PO, or a PO with no pull, is worse than a failed import.
// ---------------------------------------------------------------------------

public enum WipSheetAction
{
    /// <summary>Neither pull nor PO exists — build both.</summary>
    Create,

    /// <summary>
    /// The PO was imported before this feature existed but no pull was ever
    /// created — exactly the stuck state this synthesis exists to remove.
    /// Build the pull side only and leave the existing PO and its per-row
    /// lines untouched: PurchaseOrders.PullId is immutable after create
    /// (§7.15), and the existing PO already carries PullExternalRef =
    /// PoNumber, which is what the §7.15 lock-by-pull FIFO filter matches on
    /// (ReceiptService.ReadOpenPoLinesAsync). Receiving works without
    /// touching it.
    /// </summary>
    Repair,

    /// <summary>The pull already exists — leave everything alone.</summary>
    Skip,
}

public sealed record WipSheetState(string PullNumber, bool PullExists, bool PoExists)
{
    public WipSheetAction Action =>
        PullExists ? WipSheetAction.Skip
        : PoExists ? WipSheetAction.Repair
        : WipSheetAction.Create;
}

public sealed record WipWriteOutcome(
    Guid PullId,
    Guid? PurchaseOrderId,
    int ItemsCreated,
    int WindowsCreated,
    int LinesCreated,
    int TotalQty);

public static class WipSynthesisWriter
{
    /// <summary>
    /// Which of create / repair / skip each planned sheet needs.
    ///
    /// <para><paramref name="lockRows"/> adds UPDLOCK + ROWLOCK, which Stage 2
    /// passes so two concurrent imports of the same workbook cannot both
    /// decide "create". Stage 1's preview passes false — it is read-only and
    /// its answer is advisory; Stage 2 re-classifies inside the transaction
    /// and is the authority.</para>
    /// </summary>
    public static async Task<Dictionary<string, WipSheetState>> ClassifyAsync(
        IDbConnection conn, IDbTransaction? tx, IEnumerable<string> pullNumbers,
        bool lockRows, CancellationToken ct = default)
    {
        var numbers = pullNumbers
            .Where(n => !string.IsNullOrWhiteSpace(n))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        var result = new Dictionary<string, WipSheetState>(StringComparer.OrdinalIgnoreCase);
        if (numbers.Count == 0) return result;

        // Fixed strings — no user input reaches the SQL text.
        var hint = lockRows ? "WITH (UPDLOCK, ROWLOCK)" : "";

        using var multi = await conn.QueryMultipleAsync(new CommandDefinition($@"
            SELECT PullNumber FROM dbo.Pulls {hint} WHERE PullNumber IN @Numbers;
            SELECT PoNumber   FROM dbo.PurchaseOrders {hint} WHERE PoNumber IN @Numbers;",
            new { Numbers = numbers }, transaction: tx, cancellationToken: ct));

        var pulls = new HashSet<string>(await multi.ReadAsync<string>(), StringComparer.OrdinalIgnoreCase);
        var pos = new HashSet<string>(await multi.ReadAsync<string>(), StringComparer.OrdinalIgnoreCase);

        foreach (var n in numbers)
            result[n] = new WipSheetState(n, pulls.Contains(n), pos.Contains(n));

        return result;
    }

    /// <summary>
    /// Writes one planned WIP sheet. Caller owns the transaction and has
    /// already decided the action; Skip never reaches here.
    /// </summary>
    public static async Task<WipWriteOutcome> ApplyAsync(
        IDbConnection conn, IDbTransaction tx, WipPullPlan plan, WipSheetAction action,
        Guid warehouseId, Guid? createdBy, CancellationToken ct = default)
    {
        if (action == WipSheetAction.Skip)
            throw new InvalidOperationException("WipSynthesisWriter.ApplyAsync called for a Skip sheet.");

        var pullId = await InsertPullAsync(conn, tx, plan, warehouseId, createdBy, ct);

        var itemsCreated = 0;
        var windowsCreated = 0;
        foreach (var item in plan.Items)
        {
            itemsCreated++;
            var itemId = await InsertPullItemAsync(conn, tx, pullId, item, itemsCreated, ct);

            foreach (var win in item.Windows)
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.PullItemWindows
                           (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
                    VALUES (NEWID(), @PullItemId, @HourOfDay, @ExpectedQty, 0);",
                    new { PullItemId = itemId, win.HourOfDay, ExpectedQty = win.Qty },
                    transaction: tx, cancellationToken: ct));
                windowsCreated++;
            }
        }

        // Repair: the PO is already there and stays exactly as imported.
        if (action == WipSheetAction.Repair)
            return new WipWriteOutcome(pullId, null, itemsCreated, windowsCreated, 0, plan.TotalQty);

        var poId = await InsertPurchaseOrderAsync(conn, tx, plan, pullId, warehouseId, createdBy, ct);
        var lines = await InsertPurchaseOrderLinesAsync(conn, tx, poId, plan, ct);

        return new WipWriteOutcome(pullId, poId, itemsCreated, windowsCreated, lines, plan.TotalQty);
    }

    // ------------------------------------------------------------------
    // Pull side
    // ------------------------------------------------------------------

    private static Task<Guid> InsertPullAsync(
        IDbConnection conn, IDbTransaction tx, WipPullPlan plan,
        Guid warehouseId, Guid? createdBy, CancellationToken ct)
    {
        // Defaults deliberately copied from ErpUpsertService.InsertPullAsync —
        // status 'pending', LockPoByPull = 1, LockHourCap = 1 — so a
        // synthesised pull behaves exactly like an ERP-fed one on the
        // receiving console. The one deviation is CreatedBy: the ETL writes
        // NULL because it has no signed-in user, whereas an import always
        // has the uploader, and attributing the row is strictly better than
        // a NULL that means "we could not say".
        return conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
            INSERT INTO dbo.Pulls
                   (Id, PullNumber, WarehouseId, PullDate, Status,
                    LockPoByPull, LockHourCap, CreatedBy, Origin)
            OUTPUT INSERTED.Id
            VALUES (NEWID(), @PullNumber, @WarehouseId, @PullDate, 'pending',
                    1, 1, @CreatedBy, @Origin);",
            new
            {
                plan.PullNumber,
                WarehouseId = warehouseId,
                plan.PullDate,
                CreatedBy = createdBy,
                Origin = WipPullSynthesis.OriginPoImport,
            }, transaction: tx, cancellationToken: ct));
    }

    private static Task<Guid> InsertPullItemAsync(
        IDbConnection conn, IDbTransaction tx, Guid pullId, WipItemPlan item,
        int sortOrder, CancellationToken ct)
    {
        // VendorCode is the STRIPPED form — PullItems holds what the ERP's
        // BPI_PRS.VENDOR column holds (WIPBP1), not the file's prefixed
        // STORER CODE (COI-WIPBP1) that the PO line carries. See
        // WipPullSynthesis.StripVendorPrefix; writing the raw form here would
        // match zero rows against every ERP-fed item.
        //
        // The 7 Phase-9.1 ERP fields (ProductFamily, FromSubInventory, …) are
        // left NULL: the import has no source for them, and they are
        // operator-editable via the drawer if anyone needs them.
        return conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
            INSERT INTO dbo.PullItems
                   (Id, PullId, ItemCode, Description, VendorCode, VendorName,
                    Tag, Status, Remark, SortOrder)
            OUTPUT INSERTED.Id
            VALUES (NEWID(), @PullId, @ItemCode, @Description, @VendorCode, @VendorName,
                    NULL, 'normal', NULL, @SortOrder);",
            new
            {
                PullId = pullId,
                item.ItemCode,
                Description = item.Description ?? "",     // NOT NULL
                VendorCode = item.VendorCodeStripped,
                item.VendorName,
                SortOrder = sortOrder,
            }, transaction: tx, cancellationToken: ct));
    }

    // ------------------------------------------------------------------
    // PO side
    // ------------------------------------------------------------------

    private static Task<Guid> InsertPurchaseOrderAsync(
        IDbConnection conn, IDbTransaction tx, WipPullPlan plan, Guid pullId,
        Guid warehouseId, Guid? createdBy, CancellationToken ct)
    {
        // PullId AND PullExternalRef are both set. PullId because we are
        // creating both sides in one transaction, so the real FK is free and
        // it is what /Pos renders as a live "Linked Pull" link instead of the
        // muted "<ext> (import)" badge. PullExternalRef because the §7.15
        // FIFO filter is `po.PullId = @PullId OR po.PullExternalRef =
        // @PullNumberStr` and the string path keeps working even if the pull
        // row is ever rebuilt under a new Id.
        //
        // OrderDate comes from the sheet's DELIVERY DATE rather than "today"
        // (the ordinary import's rule). For a synthesised PO there is no date
        // a buyer placed an order; the delivery date is the only real date the
        // sheet carries, and having OrderDate and the pull's PullDate agree
        // keeps the two sides reconcilable by eye.
        return conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
            INSERT INTO dbo.PurchaseOrders
                   (Id, PoNumber, WarehouseId, PullId, PullExternalRef,
                    OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt, Origin)
            OUTPUT INSERTED.Id
            VALUES (NEWID(), @PoNumber, @WarehouseId, @PullId, @PullExternalRef,
                    @OrderDate, @ExpectedDate, 'open', NULL, @CreatedBy, SYSUTCDATETIME(), @Origin);",
            new
            {
                PoNumber = plan.PullNumber,
                WarehouseId = warehouseId,
                PullId = pullId,
                PullExternalRef = plan.PullNumber,
                OrderDate = plan.PullDate,
                ExpectedDate = plan.PullDate,
                CreatedBy = createdBy,
                Origin = WipPullSynthesis.OriginPoImport,
            }, transaction: tx, cancellationToken: ct));
    }

    private static async Task<int> InsertPurchaseOrderLinesAsync(
        IDbConnection conn, IDbTransaction tx, Guid poId, WipPullPlan plan, CancellationToken ct)
    {
        // ONE line per (SKU, ROUND) — the same grain as the windows, with the
        // summed quantity. The ordinary import writes one line per source row;
        // for WIP sheets that would mean 9 lines for a SKU that arrives as 9
        // pallet rows, against a single window. Nobody can check these lines
        // against a procurement document, so a 1:1 correspondence with the
        // thing the operator actually receives is worth more than fidelity to
        // the source rows.
        //
        // The ERP metadata columns come from the group's first row in file
        // order (rows within a group differ only by pallet-level fields).
        var lineNumber = 0;
        foreach (var item in plan.Items)
        {
            foreach (var win in item.Windows)
            {
                lineNumber++;
                var s = win.Sample;

                await conn.ExecuteAsync(new CommandDefinition(@"
                    INSERT INTO dbo.PurchaseOrderLines (
                        Id, PurchaseOrderId, LineNumber,
                        ItemCode, Description, OrderedQty, ReceivedQty,
                        VendorCode, VendorName,
                        OrderId, SourcePoNo, AsnNo, InvoiceNo, KanbanNo, PCCNo, BatchNo,
                        ManufacturingControlNo, ManufacturingReferenceNo,
                        CustomerReferenceNo, ExportDeclarationNo, VendorItem,
                        PalletId, VmiPalletId, Location, Building, SubInventory, ToLocation,
                        ProductionLine, OrderRound, DeliveryDate, Note
                    ) VALUES (
                        NEWID(), @PoId, @LineNumber,
                        @ItemCode, @Description, @OrderedQty, 0,
                        @VendorCode, @VendorName,
                        @OrderId, @SourcePoNo, @AsnNo, @InvoiceNo, @KanbanNo, @PCCNo, @BatchNo,
                        @ManufacturingControlNo, @ManufacturingReferenceNo,
                        @CustomerReferenceNo, @ExportDeclarationNo, @VendorItem,
                        @PalletId, @VmiPalletId, @Location, @Building, @SubInventory, @ToLocation,
                        @ProductionLine, @OrderRound, @DeliveryDate, @Note
                    );",
                    new
                    {
                        PoId = poId,
                        LineNumber = lineNumber,
                        item.ItemCode,
                        Description = item.Description ?? "",
                        OrderedQty = win.Qty,
                        // RAW prefixed form here — the mirror image of PullItems above.
                        VendorCode = item.VendorCodeRaw,
                        item.VendorName,
                        s.OrderId, s.SourcePoNo, s.AsnNo, s.InvoiceNo, s.KanbanNo,
                        s.PCCNo, s.BatchNo,
                        s.ManufacturingControlNo, s.ManufacturingReferenceNo,
                        s.CustomerReferenceNo, s.ExportDeclarationNo, s.VendorItem,
                        s.PalletId, s.VmiPalletId, s.Location, s.Building,
                        s.SubInventory, s.ToLocation,
                        s.ProductionLine, s.OrderRound,
                        DeliveryDate = plan.PullDate,
                        s.Note,
                    }, transaction: tx, cancellationToken: ct));
            }
        }

        return lineNumber;
    }
}

/// <summary>
/// Per-run WIP counters. Not persisted — dbo.PoImportLog's counters are
/// about POs and lines, and widening that schema for this would mean a
/// second migration for numbers the audit trail already carries.
/// </summary>
public sealed class WipRunTotals
{
    public int PullsCreated { get; set; }
    public int PullsRepaired { get; set; }
    public int PullsSkipped { get; set; }
    public int ItemsCreated { get; set; }
    public int WindowsCreated { get; set; }
    public int QtyPlanned { get; set; }

    public bool Any => PullsCreated > 0 || PullsRepaired > 0 || PullsSkipped > 0;

    /// <summary>
    /// Appended to the run's audit message. Empty for a file with no WIP
    /// sheets, so ordinary imports keep the exact message they had.
    /// </summary>
    public string AuditSuffix()
        => !Any
            ? ""
            : $"; WIP pulls: {PullsCreated} created, {PullsRepaired} repaired, {PullsSkipped} skipped " +
              $"({ItemsCreated} item(s) / {WindowsCreated} window(s) / {QtyPlanned} unit(s))";
}
