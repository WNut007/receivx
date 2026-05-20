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
                CAST(CASE WHEN p.ReopenedAt IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsReopened,
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
            IsReopened = summary.IsReopened,
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
        public byte? HourOfDay { get; set; }
        public int? ExpectedQty { get; set; }
        public int? ReceivedQty { get; set; }
    }
}
