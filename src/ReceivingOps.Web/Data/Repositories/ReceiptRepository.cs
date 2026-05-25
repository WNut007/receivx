using System.Text;
using Dapper;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Data.Repositories;

public class ReceiptRepository : IReceiptRepository
{
    // Column list matches ReceiptJournalRow exactly so Dapper maps without explicit aliases.
    // PO context columns (§4.8 v2) are populated by 013_views_v2.sql.
    // Phase 9.1 — last 7 columns are the ERP-sourced PullItem fields added by db/025.
    private const string JournalSelect = @"
        SELECT  Id, PullItemId, PullId, PullNumber, WarehouseId, WarehouseCode, WarehouseName,
                ItemCode, ItemDescription,
                PurchaseOrderId, PoNumber, VendorCode, VendorName,
                PurchaseOrderLineId, PoLineNumber,
                HourOfDay, QtyReceived,
                LotBatch, PalletId, BinLocation, QcStatus, Note,
                ReceivedBy, ReceivedByName, ReceivedAt,
                ReversesReceiptId, ReversedById, CancelReason, Kind,
                ProductFamily, FromSubInventory, ToSubInventory, SpecialControl,
                TrailId, PullLocation, PullPhase
        FROM    dbo.vw_TransactionsJournal ";

    private readonly IDbConnectionFactory _factory;

    public ReceiptRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IReadOnlyList<ReceiptJournalRow>> GetJournalForPullAsync(Guid pullId, CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<ReceiptJournalRow>(new CommandDefinition(
            JournalSelect + "WHERE PullId = @PullId ORDER BY ReceivedAt DESC;",
            new { PullId = pullId }, cancellationToken: ct));
        return rows.AsList();
    }

    public async Task<ReceiptJournalRow?> GetJournalRowAsync(Guid receiptId, CancellationToken ct = default)
    {
        using var conn = _factory.Create();
        return await conn.QuerySingleOrDefaultAsync<ReceiptJournalRow>(new CommandDefinition(
            JournalSelect + "WHERE Id = @Id;",
            new { Id = receiptId }, cancellationToken: ct));
    }

    public async Task<PagedTransactions> QueryAsync(TransactionsQuery filter, CancellationToken ct = default)
    {
        // Build WHERE incrementally. All parameter values flow through DynamicParameters
        // (never string-concatenated) — even the multi-token search uses parameterized LIKEs.
        var where = new StringBuilder("WHERE 1 = 1 ");
        var p = new DynamicParameters();

        if (filter.WarehouseId is { } wh)
        {
            where.Append("AND WarehouseId = @WarehouseId ");
            p.Add("WarehouseId", wh);
        }
        if (!string.IsNullOrWhiteSpace(filter.WarehouseCode))
        {
            where.Append("AND WarehouseCode = @WarehouseCode ");
            p.Add("WarehouseCode", filter.WarehouseCode);
        }
        if (filter.DateFrom is { } from)
        {
            where.Append("AND ReceivedAt >= @DateFrom ");
            p.Add("DateFrom", from);
        }
        if (filter.DateTo is { } to)
        {
            where.Append("AND ReceivedAt <= @DateTo ");
            p.Add("DateTo", to);
        }
        if (!string.IsNullOrWhiteSpace(filter.Kind))
        {
            // Kind is derived in the view: 'receive' | 'voided' | 'reversal'.
            where.Append("AND Kind = @Kind ");
            p.Add("Kind", filter.Kind);
        }
        if (filter.OperatorId is { } op)
        {
            where.Append("AND ReceivedBy = @OperatorId ");
            p.Add("OperatorId", op);
        }
        if (!string.IsNullOrWhiteSpace(filter.ReceivedByName))
        {
            where.Append("AND ReceivedByName = @ReceivedByName ");
            p.Add("ReceivedByName", filter.ReceivedByName);
        }
        if (!string.IsNullOrWhiteSpace(filter.PullNumber))
        {
            where.Append("AND PullNumber = @PullNumber ");
            p.Add("PullNumber", filter.PullNumber);
        }
        if (!string.IsNullOrWhiteSpace(filter.PoNumber))
        {
            where.Append("AND PoNumber = @PoNumber ");
            p.Add("PoNumber", filter.PoNumber);
        }
        if (!string.IsNullOrWhiteSpace(filter.ItemCode))
        {
            where.Append("AND ItemCode = @ItemCode ");
            p.Add("ItemCode", filter.ItemCode);
        }
        if (filter.Hour is { } h)
        {
            where.Append("AND HourOfDay = @Hour ");
            p.Add("Hour", (byte)Math.Clamp(h, 0, 23));
        }
        if (!string.IsNullOrWhiteSpace(filter.Q))
        {
            // §6 v2 multi-token AND match: every token must appear somewhere in
            // (PullNumber + WarehouseCode + PoNumber + VendorName + ItemCode +
            //  ItemDescription + LotBatch + PalletId + BinLocation +
            //  ReceivedByName + Note).
            var tokens = filter.Q.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            for (int i = 0; i < tokens.Length; i++)
            {
                var name = $"Q{i}";
                where.Append($@"AND (
                    PullNumber           LIKE @{name} OR
                    WarehouseCode        LIKE @{name} OR
                    PoNumber             LIKE @{name} OR
                    ISNULL(VendorName,'') LIKE @{name} OR
                    ItemCode             LIKE @{name} OR
                    ItemDescription      LIKE @{name} OR
                    LotBatch             LIKE @{name} OR
                    PalletId             LIKE @{name} OR
                    BinLocation          LIKE @{name} OR
                    ReceivedByName       LIKE @{name} OR
                    ISNULL(Note,'')      LIKE @{name}
                ) ");
                p.Add(name, "%" + tokens[i] + "%");
            }
        }

        // Take/skip clamps — paging defaults handled at controller; here we just clamp.
        var take = Math.Clamp(filter.Take, 1, 500);
        var skip = Math.Max(0, filter.Skip);
        p.Add("Take", take);
        p.Add("Skip", skip);

        var pageSql = JournalSelect + where + @"
            ORDER BY ReceivedAt DESC
            OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;";
        var countSql = "SELECT COUNT(*) FROM dbo.vw_TransactionsJournal " + where + ";";

        using var conn = _factory.Create();
        var rows = (await conn.QueryAsync<ReceiptJournalRow>(
            new CommandDefinition(pageSql, p, cancellationToken: ct))).AsList();
        var total = await conn.ExecuteScalarAsync<int>(
            new CommandDefinition(countSql, p, cancellationToken: ct));

        return new PagedTransactions { Rows = rows, Total = total, Take = take, Skip = skip };
    }
}
