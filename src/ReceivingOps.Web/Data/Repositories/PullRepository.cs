using System.Text;
using Dapper;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public class PullRepository : IPullRepository
{
    private const string SummarySelect = @"
        SELECT  p.Id,
                p.PullNumber,
                p.WarehouseId,
                w.Code AS WarehouseCode,
                w.Name AS WarehouseName,
                p.PullDate,
                p.Status,
                p.Eta,
                p.Notes,
                u.Name AS CreatedByName,
                p.FirstReceiptAt,
                p.LastActivityAt,
                p.ClosedAt,
                cb.Name AS ClosedByName,
                cb.Role AS ClosedByRole,           -- v2.x: closer global role for the drawer close-auth section
                p.SignatureSvg,                    -- v2.x: rendered in the same section; NULL on open pulls
                CAST(CASE WHEN p.ReopenedAt IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsReopened,
                p.LockPoByPull,
                p.LockHourCap,
                p.ReferenceNumber,                 -- v2.x Phase 7.1: per-pull reference (vendor invoice)
                ISNULL(vp.TotalExpected,  0) AS TotalExpected,
                ISNULL(vp.TotalReceived,  0) AS TotalReceived,
                ISNULL(vp.ActiveItemCount, 0) +
                  (SELECT COUNT(*) FROM dbo.PullItems pi2
                   WHERE pi2.PullId = p.Id AND pi2.Status = 'canceled') AS ItemCount,
                (SELECT COUNT(*) FROM dbo.PullItems pi
                 WHERE pi.PullId = p.Id AND pi.Status = 'canceled') AS CanceledCount,
                (SELECT COUNT(*) FROM dbo.PullItems pi
                 WHERE pi.PullId = p.Id AND pi.Status = 'new') AS NewCount,
                (SELECT COUNT(*) FROM dbo.PullItemWindows piw
                 INNER JOIN dbo.PullItems pi ON pi.Id = piw.PullItemId
                 WHERE pi.PullId = p.Id AND pi.Status <> 'canceled') AS WindowsTotal,
                (SELECT COUNT(*) FROM dbo.PullItemWindows piw
                 INNER JOIN dbo.PullItems pi ON pi.Id = piw.PullItemId
                 WHERE pi.PullId = p.Id AND pi.Status <> 'canceled'
                   AND piw.ExpectedQty > piw.ReceivedQty) AS WindowsPending
        FROM    dbo.Pulls p
        INNER JOIN dbo.Warehouses w  ON w.Id  = p.WarehouseId
        LEFT  JOIN dbo.Users u       ON u.Id  = p.CreatedBy
        LEFT  JOIN dbo.Users cb      ON cb.Id = p.ClosedBy
        LEFT  JOIN dbo.vw_PullProgress vp ON vp.PullId = p.Id ";

    private readonly IDbConnectionFactory _factory;

    public PullRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IReadOnlyList<PullSummary>> QueryAsync(PullQuery filter, CancellationToken ct = default)
    {
        var sql = new StringBuilder(SummarySelect);
        sql.Append("WHERE 1 = 1 ");

        var p = new DynamicParameters();
        if (filter.WarehouseId is { } wh)
        {
            sql.Append("AND p.WarehouseId = @WarehouseId ");
            p.Add("WarehouseId", wh);
        }
        if (filter.DateFrom is { } from)
        {
            sql.Append("AND p.PullDate >= @DateFrom ");
            p.Add("DateFrom", from.ToDateTime(TimeOnly.MinValue));
        }
        if (filter.DateTo is { } to)
        {
            sql.Append("AND p.PullDate <= @DateTo ");
            p.Add("DateTo", to.ToDateTime(TimeOnly.MinValue));
        }
        if (!string.IsNullOrWhiteSpace(filter.Status))
        {
            sql.Append("AND p.Status = @Status ");
            p.Add("Status", filter.Status);
        }
        if (!string.IsNullOrWhiteSpace(filter.Q))
        {
            // §6 multi-token AND match: every whitespace-separated token must appear somewhere
            // in (PullNumber, WarehouseCode, WarehouseName). Item codes are not searched here;
            // the cross-pull Transactions journal handles that.
            var tokens = filter.Q.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            for (int i = 0; i < tokens.Length; i++)
            {
                var name = $"Q{i}";
                sql.Append($"AND (p.PullNumber LIKE @{name} OR w.Code LIKE @{name} OR w.Name LIKE @{name}) ");
                p.Add(name, "%" + tokens[i] + "%");
            }
        }

        sql.Append("ORDER BY p.PullDate DESC, p.PullNumber DESC;");

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<PullSummary>(
            new CommandDefinition(sql.ToString(), p, cancellationToken: ct));
        return rows.AsList();
    }

    // §3.5 typeahead for the linked-pull picker on /Pos. Returns at most @Take
    // open pulls (pending OR in_progress) in @WarehouseId whose PullNumber or
    // Notes contains @Q. Ranking: prefix matches on PullNumber first, then
    // newest by PullDate, then alphabetical. Closed/fully_received pulls are
    // excluded so the picker can't surface a pull POs are forbidden to link to.
    public async Task<IReadOnlyList<PullSearchResult>> SearchAsync(
        Guid warehouseId, string q, int take, CancellationToken ct = default)
    {
        // Strip wildcards the user might have pasted — LIKE-escape would be more
        // surgical but this is a typeahead, the simpler answer is fine. Brackets
        // become class operators in T-SQL LIKE so they go too.
        var clean = (q ?? string.Empty)
            .Replace("%", string.Empty)
            .Replace("_", string.Empty)
            .Replace("[", string.Empty)
            .Trim();
        if (clean.Length == 0) return Array.Empty<PullSearchResult>();

        const string sql = @"
            SELECT TOP (@Take)
                   p.Id,
                   p.PullNumber,
                   p.PullDate,
                   p.Status,
                   p.LockPoByPull,
                   (SELECT COUNT(*) FROM dbo.PullItems pi WHERE pi.PullId = p.Id) AS ItemCount
            FROM   dbo.Pulls p
            WHERE  p.WarehouseId = @WarehouseId
              AND  p.Status IN ('pending', 'in_progress')
              AND  (p.PullNumber LIKE '%' + @Q + '%' OR p.Notes LIKE '%' + @Q + '%')
            ORDER BY
              CASE WHEN p.PullNumber LIKE @Q + '%' THEN 0 ELSE 1 END,
              p.PullDate DESC,
              p.PullNumber;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<PullSearchResult>(new CommandDefinition(
            sql,
            new { WarehouseId = warehouseId, Q = clean, Take = take },
            cancellationToken: ct));
        return rows.AsList();
    }

    public async Task<PullDetail?> GetByPullNumberAsync(string pullNumber, CancellationToken ct = default)
    {
        // Pulls.PullNumber is UNIQUE so this resolves at most one row.
        using var conn = _factory.Create();
        var id = await conn.QuerySingleOrDefaultAsync<Guid?>(new CommandDefinition(
            "SELECT Id FROM dbo.Pulls WHERE PullNumber = @PullNumber;",
            new { PullNumber = pullNumber }, cancellationToken: ct));
        return id is null ? null : await GetByIdAsync(id.Value, ct);
    }

    public async Task<PullDetail?> GetByIdAsync(Guid id, CancellationToken ct = default)
    {
        const string itemsSql = @"
            SELECT  pi.Id, pi.ItemCode, pi.Description, pi.VendorCode, pi.VendorName,
                    pi.Tag, pi.Status, pi.Remark, pi.SortOrder,
                    pi.ProductFamily, pi.FromSubInventory, pi.ToSubInventory,
                    pi.SpecialControl, pi.TrialId, pi.Location, pi.[Phase],
                    piw.HourOfDay, piw.ExpectedQty, piw.ReceivedQty
            FROM    dbo.PullItems pi
            LEFT JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
            WHERE   pi.PullId = @PullId
            ORDER BY pi.SortOrder, pi.ItemCode, piw.HourOfDay;";

        using var conn = _factory.Create();

        // Summary first
        var summary = await conn.QuerySingleOrDefaultAsync<PullSummary>(
            new CommandDefinition(SummarySelect + "WHERE p.Id = @Id;",
                new { Id = id }, cancellationToken: ct));
        if (summary is null) return null;

        // Items + windows in one round-trip; rebuild the parent/child shape client-side.
        var rows = await conn.QueryAsync<PullItemRow>(
            new CommandDefinition(itemsSql, new { PullId = id }, cancellationToken: ct));

        var itemsByGuid = new Dictionary<Guid, PullItemDto>();
        foreach (var r in rows)
        {
            if (!itemsByGuid.TryGetValue(r.Id, out var item))
            {
                item = new PullItemDto
                {
                    Id = r.Id,
                    ItemCode = r.ItemCode,
                    Description = r.Description,
                    VendorCode = r.VendorCode,
                    VendorName = r.VendorName,
                    Tag = r.Tag,
                    Status = r.Status,
                    Remark = r.Remark,
                    SortOrder = r.SortOrder,
                    ProductFamily = r.ProductFamily,
                    FromSubInventory = r.FromSubInventory,
                    ToSubInventory = r.ToSubInventory,
                    SpecialControl = r.SpecialControl,
                    TrialId = r.TrialId,
                    Location = r.Location,
                    Phase = r.Phase,
                };
                itemsByGuid.Add(r.Id, item);
            }
            if (r.HourOfDay is { } h)
            {
                item.Windows.Add(new PullItemWindowDto
                {
                    HourOfDay = h,
                    ExpectedQty = r.ExpectedQty ?? 0,
                    ReceivedQty = r.ReceivedQty ?? 0,
                });
            }
        }

        return new PullDetail
        {
            Id = summary.Id,
            PullNumber = summary.PullNumber,
            WarehouseId = summary.WarehouseId,
            WarehouseCode = summary.WarehouseCode,
            WarehouseName = summary.WarehouseName,
            PullDate = summary.PullDate,
            Status = summary.Status,
            Eta = summary.Eta,
            Notes = summary.Notes,
            CreatedByName = summary.CreatedByName,
            FirstReceiptAt = summary.FirstReceiptAt,
            LastActivityAt = summary.LastActivityAt,
            ClosedAt = summary.ClosedAt,
            ClosedByName = summary.ClosedByName,
            ClosedByRole = summary.ClosedByRole,
            SignatureSvg = summary.SignatureSvg,
            IsReopened = summary.IsReopened,
            LockPoByPull = summary.LockPoByPull,
            LockHourCap = summary.LockHourCap,
            ReferenceNumber = summary.ReferenceNumber,
            TotalExpected = summary.TotalExpected,
            TotalReceived = summary.TotalReceived,
            ItemCount = summary.ItemCount,
            CanceledCount = summary.CanceledCount,
            NewCount = summary.NewCount,
            WindowsTotal = summary.WindowsTotal,
            WindowsPending = summary.WindowsPending,
            Items = itemsByGuid.Values.OrderBy(i => i.SortOrder).ThenBy(i => i.ItemCode).ToList(),
        };
    }

    // v2.x Phase 7.3 — list view feeder for the Reports / DO page.
    // Closed pulls with at least one net-positive receipt (a DO needs proof
    // of delivery; pulls closed with everything cancelled produce nothing).
    // Phase 8.1: paged + total. ClosedAt covered by IX_Pulls_ClosedAt
    // (filtered Status='closed' INCLUDE WarehouseId+PullDate+PullNumber).
    public async Task<(IReadOnlyList<PullSummary> Items, int Total)> GetClosedWithReceiptsAsync(
        Guid? warehouseId, int skip, int take, CancellationToken ct = default)
    {
        const string whereSql = @"
            WHERE p.Status = 'closed'
              AND (@WarehouseId IS NULL OR p.WarehouseId = @WarehouseId)
              AND EXISTS (
                  SELECT 1 FROM dbo.Receipts r
                  INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
                  WHERE pi.PullId = p.Id
                    AND r.ReversedById IS NULL
              )
              AND (
                  SELECT SUM(r.QtyReceived)
                  FROM dbo.Receipts r
                  INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
                  WHERE pi.PullId = p.Id
              ) > 0";
        var pageSql = SummarySelect + whereSql + @"
            ORDER BY p.ClosedAt DESC, p.PullDate DESC, p.Id DESC
            OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;
            SELECT COUNT(*) FROM dbo.Pulls p " + whereSql + ";";

        var p = new
        {
            WarehouseId = warehouseId,
            Skip = Math.Max(0, skip),
            Take = Math.Clamp(take, 1, 500),
        };
        using var conn = _factory.Create();
        using var multi = await conn.QueryMultipleAsync(
            new CommandDefinition(pageSql, p, cancellationToken: ct));
        var items = (await multi.ReadAsync<PullSummary>()).AsList();
        var total = await multi.ReadSingleAsync<int>();
        return (items, total);
    }

    // v2.x Phase 7.4 — DO report aggregation. Filter notes:
    //   ReversedById IS NULL excludes voided originals but keeps the reversal
    //   rows (which carry the negative qty per the §6 CHECK constraint). The
    //   reversal negatives cancel the originals at SUM time, and HAVING
    //   SUM > 0 drops (PO × Line × Item) tuples that net to zero.
    public async Task<IReadOnlyList<DoReportRow>> GetDoReportRowsAsync(Guid pullId, CancellationToken ct = default)
    {
        // The remaining ERP-sourced extended fields below are invariant per
        // (PoId, LineNumber). MAX() lets us surface them without extending
        // GROUP BY (which would otherwise need duplicate listing of every
        // attribute) and is a no-op on uniqueness — never multiplies rows.
        // DO grouping = (VendorCode × SubInventory × ToLocation × InvoiceNo).
        // Invoice was promoted from a MAX'd line attribute to a first-class
        // grouping key so two distinct invoices under the same vendor / sub /
        // to-loc triple split into separate DOs (one page each in the PDF).
        const string sql = @"
            SELECT  pol.VendorCode,
                    pol.VendorName,
                    pol.SubInventory,
                    pol.ToLocation,
                    pol.InvoiceNo,
                    po.Id           AS PoId,
                    po.PoNumber,
                    pol.LineNumber  AS PoLineNumber,
                    pol.ItemCode,
                    pol.Description,
                    pol.OrderId,
                    SUM(r.QtyReceived) AS TotalQty,
                    MAX(r.ReceivedAt)     AS LastReceivedAt,
                    MAX(pol.PalletId)     AS PalletId,
                    MAX(pol.KanbanNo)     AS KanbanNo,
                    MAX(pol.AsnNo)        AS AsnNo,
                    MAX(pol.OrderRound)   AS OrderRound,
                    MAX(pol.SourcePoNo)   AS SourcePoNo
            FROM    dbo.Receipts r
            INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
            INNER JOIN dbo.PurchaseOrders po ON po.Id = r.PurchaseOrderId
            INNER JOIN dbo.PurchaseOrderLines pol ON pol.Id = r.PurchaseOrderLineId
            WHERE   pi.PullId = @PullId
              AND   r.ReversedById IS NULL
            GROUP BY pol.VendorCode, pol.VendorName,
                     pol.SubInventory, pol.ToLocation, pol.InvoiceNo,
                     pol.OrderId,
                     po.Id, po.PoNumber,
                     pol.LineNumber, pol.ItemCode, pol.Description
            HAVING  SUM(r.QtyReceived) > 0
            ORDER BY pol.VendorCode, pol.SubInventory, pol.ToLocation, pol.InvoiceNo,
                     po.PoNumber, pol.LineNumber, pol.ItemCode;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<DoReportRow>(
            new CommandDefinition(sql, new { PullId = pullId }, cancellationToken: ct));
        return rows.AsList();
    }

    // v2.1 — item-grained reads for /api/pulls/{id}/items[/{itemId}].
    public async Task<IReadOnlyList<PullItemDto>> GetItemsAsync(Guid pullId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT  pi.Id, pi.ItemCode, pi.Description, pi.VendorCode, pi.VendorName,
                    pi.Tag, pi.Status, pi.Remark, pi.SortOrder,
                    pi.ProductFamily, pi.FromSubInventory, pi.ToSubInventory,
                    pi.SpecialControl, pi.TrialId, pi.Location, pi.[Phase],
                    piw.HourOfDay, piw.ExpectedQty, piw.ReceivedQty
            FROM    dbo.PullItems pi
            LEFT JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
            WHERE   pi.PullId = @PullId
            ORDER BY pi.SortOrder, pi.ItemCode, piw.HourOfDay;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<PullItemRow>(
            new CommandDefinition(sql, new { PullId = pullId }, cancellationToken: ct));
        return AssembleItems(rows).ToList();
    }

    public async Task<PullItemDto?> GetItemByIdAsync(Guid pullId, Guid itemId, CancellationToken ct = default)
    {
        const string sql = @"
            SELECT  pi.Id, pi.ItemCode, pi.Description, pi.VendorCode, pi.VendorName,
                    pi.Tag, pi.Status, pi.Remark, pi.SortOrder,
                    pi.ProductFamily, pi.FromSubInventory, pi.ToSubInventory,
                    pi.SpecialControl, pi.TrialId, pi.Location, pi.[Phase],
                    piw.HourOfDay, piw.ExpectedQty, piw.ReceivedQty
            FROM    dbo.PullItems pi
            LEFT JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
            WHERE   pi.PullId = @PullId AND pi.Id = @ItemId
            ORDER BY piw.HourOfDay;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<PullItemRow>(
            new CommandDefinition(sql, new { PullId = pullId, ItemId = itemId }, cancellationToken: ct));
        return AssembleItems(rows).FirstOrDefault();
    }

    // Phase 9.1 — overwrite the 7 ERP-sourced fields on one PullItem. Pull
    // closed-state + role gating happens in the service layer; this is a
    // direct SQL UPDATE that returns the affected row count so the service
    // can map 0 → 404. [Phase] is bracketed because the column name shadows
    // the T-SQL PHASE keyword in some grammar contexts.
    public async Task<int> UpdateExtendedFieldsAsync(
        Guid itemId, PullItemExtendedFieldsUpdateRequest req, CancellationToken ct = default)
    {
        const string sql = @"
            UPDATE dbo.PullItems
               SET ProductFamily    = @ProductFamily,
                   FromSubInventory = @FromSubInventory,
                   ToSubInventory   = @ToSubInventory,
                   SpecialControl   = @SpecialControl,
                   TrialId          = @TrialId,
                   Location         = @Location,
                   [Phase]          = @Phase
             WHERE Id = @ItemId;";

        using var conn = _factory.Create();
        return await conn.ExecuteAsync(new CommandDefinition(sql, new
        {
            ItemId = itemId,
            req.ProductFamily,
            req.FromSubInventory,
            req.ToSubInventory,
            req.SpecialControl,
            req.TrialId,
            req.Location,
            req.Phase,
        }, cancellationToken: ct));
    }

    private static IEnumerable<PullItemDto> AssembleItems(IEnumerable<PullItemRow> rows)
    {
        var byGuid = new Dictionary<Guid, PullItemDto>();
        foreach (var r in rows)
        {
            if (!byGuid.TryGetValue(r.Id, out var item))
            {
                item = new PullItemDto
                {
                    Id = r.Id,
                    ItemCode = r.ItemCode,
                    Description = r.Description,
                    VendorCode = r.VendorCode,
                    VendorName = r.VendorName,
                    Tag = r.Tag,
                    Status = r.Status,
                    Remark = r.Remark,
                    SortOrder = r.SortOrder,
                    ProductFamily = r.ProductFamily,
                    FromSubInventory = r.FromSubInventory,
                    ToSubInventory = r.ToSubInventory,
                    SpecialControl = r.SpecialControl,
                    TrialId = r.TrialId,
                    Location = r.Location,
                    Phase = r.Phase,
                };
                byGuid.Add(r.Id, item);
            }
            if (r.HourOfDay is { } h)
            {
                item.Windows.Add(new PullItemWindowDto
                {
                    HourOfDay = h,
                    ExpectedQty = r.ExpectedQty ?? 0,
                    ReceivedQty = r.ReceivedQty ?? 0,
                });
            }
        }
        return byGuid.Values.OrderBy(i => i.SortOrder).ThenBy(i => i.ItemCode);
    }

    private sealed class PullItemRow
    {
        public Guid Id { get; set; }
        public string ItemCode { get; set; } = "";
        public string Description { get; set; } = "";
        public string? VendorCode { get; set; }
        public string? VendorName { get; set; }
        public string? Tag { get; set; }
        public string Status { get; set; } = "normal";
        public string? Remark { get; set; }
        public int SortOrder { get; set; }
        public string? ProductFamily { get; set; }
        public string? FromSubInventory { get; set; }
        public string? ToSubInventory { get; set; }
        public string? SpecialControl { get; set; }
        public string? TrialId { get; set; }
        public string? Location { get; set; }
        public string? Phase { get; set; }
        public byte? HourOfDay { get; set; }
        public int? ExpectedQty { get; set; }
        public int? ReceivedQty { get; set; }
    }
}
