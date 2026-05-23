using Dapper;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public class PurchaseOrderRepository : IPurchaseOrderRepository
{
    private readonly IDbConnectionFactory _factory;

    public PurchaseOrderRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IReadOnlyList<PoListRow>> QueryAsync(
        Guid? warehouseId, string? status, string? itemCode, string? q,
        DateOnly? orderDateFrom, DateOnly? orderDateTo,
        CancellationToken ct = default)
    {
        var where = new List<string>();
        var p = new DynamicParameters();

        if (warehouseId is { } wh)
        {
            where.Add("po.WarehouseId = @WarehouseId");
            p.Add("WarehouseId", wh);
        }
        if (!string.IsNullOrWhiteSpace(status))
        {
            where.Add("po.Status = @Status");
            p.Add("Status", status.Trim());
        }
        if (!string.IsNullOrWhiteSpace(itemCode))
        {
            // Filter POs to those that contain a line for the given item.
            where.Add("EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol2 WHERE pol2.PurchaseOrderId = po.Id AND pol2.ItemCode = @ItemCode)");
            p.Add("ItemCode", itemCode.Trim());
        }
        // OrderDate is DATE (no time) so inclusive bounds are correct on both ends.
        if (orderDateFrom is { } from)
        {
            where.Add("po.OrderDate >= @OrderDateFrom");
            p.Add("OrderDateFrom", from.ToDateTime(TimeOnly.MinValue));
        }
        if (orderDateTo is { } to)
        {
            where.Add("po.OrderDate <= @OrderDateTo");
            p.Add("OrderDateTo", to.ToDateTime(TimeOnly.MinValue));
        }
        if (!string.IsNullOrWhiteSpace(q))
        {
            // Multi-token AND across PoNumber, VendorCode, VendorName.
            var tokens = q.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            for (var i = 0; i < tokens.Length; i++)
            {
                var name = $"Q{i}";
                p.Add(name, $"%{tokens[i]}%");
                where.Add($"(po.PoNumber LIKE @{name} OR ISNULL(po.VendorCode,'') LIKE @{name} OR ISNULL(po.VendorName,'') LIKE @{name})");
            }
        }

        var whereSql = where.Count == 0 ? "" : "WHERE " + string.Join(" AND ", where);
        var sql = $@"
            SELECT  po.Id, po.PoNumber, po.WarehouseId, w.Code AS WarehouseCode,
                    po.VendorCode, po.VendorName, po.OrderDate, po.ExpectedDate,
                    po.Status, po.CreatedAt, po.ClosedAt,
                    po.PullId, p.PullNumber,
                    (SELECT COUNT(*)          FROM dbo.PurchaseOrderLines pol WHERE pol.PurchaseOrderId = po.Id) AS LineCount,
                    (SELECT ISNULL(SUM(OrderedQty),0)  FROM dbo.PurchaseOrderLines pol WHERE pol.PurchaseOrderId = po.Id) AS TotalOrdered,
                    (SELECT ISNULL(SUM(ReceivedQty),0) FROM dbo.PurchaseOrderLines pol WHERE pol.PurchaseOrderId = po.Id) AS TotalReceived
            FROM    dbo.PurchaseOrders po
            INNER JOIN dbo.Warehouses w ON w.Id = po.WarehouseId
            LEFT  JOIN dbo.Pulls      p ON p.Id = po.PullId
            {whereSql}
            ORDER BY po.OrderDate DESC, po.PoNumber DESC;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<PoListRow>(new CommandDefinition(sql, p, cancellationToken: ct));
        return rows.AsList();
    }

    public async Task<PoDetail?> GetDetailAsync(Guid id, CancellationToken ct = default)
    {
        const string headerSql = @"
            SELECT  po.Id, po.PoNumber, po.WarehouseId, w.Code AS WarehouseCode, w.Name AS WarehouseName,
                    po.VendorCode, po.VendorName, po.OrderDate, po.ExpectedDate, po.Status, po.Notes,
                    po.CreatedBy, cb.Name AS CreatedByName, po.CreatedAt, po.ClosedAt,
                    po.PullId, p.PullNumber
            FROM    dbo.PurchaseOrders po
            INNER JOIN dbo.Warehouses w  ON w.Id  = po.WarehouseId
            LEFT  JOIN dbo.Users      cb ON cb.Id = po.CreatedBy
            LEFT  JOIN dbo.Pulls      p  ON p.Id  = po.PullId
            WHERE   po.Id = @Id;";

        const string linesSql = @"
            SELECT  Id, PurchaseOrderId, LineNumber, ItemCode, Description,
                    OrderedQty, ReceivedQty,
                    (OrderedQty - ReceivedQty) AS RemainingQty
            FROM    dbo.PurchaseOrderLines
            WHERE   PurchaseOrderId = @Id
            ORDER BY LineNumber;";

        using var conn = _factory.Create();
        var header = await conn.QuerySingleOrDefaultAsync<PoDetail>(
            new CommandDefinition(headerSql, new { Id = id }, cancellationToken: ct));
        if (header is null) return null;

        var lines = await conn.QueryAsync<PoLineRow>(
            new CommandDefinition(linesSql, new { Id = id }, cancellationToken: ct));
        header.Lines = lines.AsList();
        return header;
    }

    public async Task<IReadOnlyList<PoAvailabilityRow>> GetAvailabilityAsync(
        Guid warehouseId, string itemCode, CancellationToken ct = default)
    {
        // FIFO ordering by OrderDate, with PoNumber as a deterministic tiebreaker —
        // matches the receive service's allocator (§7.2).
        const string sql = @"
            SELECT  PurchaseOrderLineId, PurchaseOrderId, PoNumber, WarehouseId,
                    VendorCode, VendorName, OrderDate, PoStatus,
                    LineNumber, ItemCode, OrderedQty, ReceivedQty, RemainingQty
            FROM    dbo.vw_PurchaseOrderAvailability
            WHERE   WarehouseId = @WarehouseId
              AND   ItemCode    = @ItemCode
            ORDER BY OrderDate ASC, PoNumber ASC, LineNumber ASC;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<PoAvailabilityRow>(new CommandDefinition(sql,
            new { WarehouseId = warehouseId, ItemCode = itemCode }, cancellationToken: ct));
        return rows.AsList();
    }
}
