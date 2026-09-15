using System.Text;
using Dapper;
using ReceivingOps.Web.Models;
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
                p.Origin,                          -- db/050: 'po-import' when the WIP synthesis built this pull; NULL otherwise
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
                -- db/047 §2c query 4 — the dashboard / pull-list badge. Without the
                -- IsClosed filter a variance-closed line keeps reappearing in the
                -- operator's worklist forever, which is the bug this change exists to fix.
                (SELECT COUNT(*) FROM dbo.PullItemWindows piw
                 INNER JOIN dbo.PullItems pi ON pi.Id = piw.PullItemId
                 WHERE pi.PullId = p.Id AND pi.Status <> 'canceled'
                   AND piw.IsClosed = 0
                   AND piw.ExpectedQty > piw.ReceivedQty) AS WindowsPending,
                -- Phase 7c: digital-signature progress. One grouped join to the
                -- tiny PullSignatures table (UQ_PullSig_Party caps it at 3 rows/
                -- pull). SignedCount drives the N/3 badge; the per-party bits feed
                -- the left-menu chips (7e) + the 'unsigned for my role' filter.
                ISNULL(sg.SignedCount, 0)                     AS SignedCount,
                CAST(ISNULL(sg.CustomerSigned,   0) AS BIT)   AS CustomerSigned,
                CAST(ISNULL(sg.WarehouseSigned,  0) AS BIT)   AS WarehouseSigned,
                CAST(ISNULL(sg.ProductionSigned, 0) AS BIT)   AS ProductionSigned
        FROM    dbo.Pulls p
        INNER JOIN dbo.Warehouses w  ON w.Id  = p.WarehouseId
        LEFT  JOIN dbo.Users u       ON u.Id  = p.CreatedBy
        LEFT  JOIN dbo.Users cb      ON cb.Id = p.ClosedBy
        LEFT  JOIN dbo.vw_PullProgress vp ON vp.PullId = p.Id
        LEFT  JOIN (
            SELECT  ps.PullId,
                    COUNT(*) AS SignedCount,
                    MAX(CASE WHEN ps.Party = 'Customer'   THEN 1 ELSE 0 END) AS CustomerSigned,
                    MAX(CASE WHEN ps.Party = 'Warehouse'  THEN 1 ELSE 0 END) AS WarehouseSigned,
                    MAX(CASE WHEN ps.Party = 'Production' THEN 1 ELSE 0 END) AS ProductionSigned
            FROM    dbo.PullSignatures ps
            GROUP BY ps.PullId
        ) sg ON sg.PullId = p.Id ";

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

    public async Task<(IReadOnlyList<PullSummary> Items, PullDashboardAggregates Aggregates)>
        QueryDashboardAsync(PullQuery filter, CancellationToken ct = default)
    {
        // ---- Shared WHERE — identical predicate on the page slice AND the aggregate ----
        var where = new StringBuilder("WHERE 1 = 1 ");
        var p = new DynamicParameters();

        // Warehouse: two mutually-exclusive, null-guarded clauses, BOTH keyed on
        // p.WarehouseId (admin-resolved Guid vs non-admin session force). "All
        // warehouses" arrives as both params NULL ⇒ no predicate. Keying on
        // WarehouseId (not w.Code) hits IX_Pulls_Date's INCLUDE(WarehouseId).
        where.Append("AND (@WarehouseId        IS NULL OR p.WarehouseId = @WarehouseId) ");
        where.Append("AND (@SessionWarehouseId IS NULL OR p.WarehouseId = @SessionWarehouseId) ");
        p.Add("WarehouseId", filter.WarehouseId);
        p.Add("SessionWarehouseId", filter.SessionWarehouseId);

        // Date range — SAME inclusive predicate the old QueryAsync used (PullDate is DATE).
        where.Append("AND (@DateFrom IS NULL OR p.PullDate >= @DateFrom) ");
        where.Append("AND (@DateTo   IS NULL OR p.PullDate <= @DateTo) ");
        p.Add("DateFrom", filter.DateFrom?.ToDateTime(TimeOnly.MinValue));
        p.Add("DateTo",   filter.DateTo?.ToDateTime(TimeOnly.MinValue));

        // Status (inert for the dashboard — it never sends one — but honored if present).
        if (!string.IsNullOrWhiteSpace(filter.Status))
        {
            where.Append("AND p.Status = @Status ");
            p.Add("Status", filter.Status);
        }

        // §3.5 lock filter (client bit filter, promoted server-side).
        where.Append("AND (@Lock IS NULL OR p.LockPoByPull = @Lock) ");
        p.Add("Lock", filter.LockPoByPull);

        // Search — preserve the EXACT current visible behavior (unchanged per sign-off):
        //   (a) existing multi-token AND over PullNumber / w.Code / w.Name (server), plus
        //   (b) the client substring over PullNumber + Code + Name + operator (u.Name).
        // ANDing them reproduces today's intersection; operator search stays inert.
        var searchActive = !string.IsNullOrWhiteSpace(filter.Q);
        if (searchActive)
        {
            var raw = filter.Q!.Trim();
            where.Append(
                "AND LOWER(CONCAT(p.PullNumber, ' ', w.Code, ' ', w.Name, ' ', ISNULL(u.Name, ''))) LIKE @QSub ");
            p.Add("QSub", "%" + raw.ToLowerInvariant() + "%");

            var tokens = raw.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            for (int i = 0; i < tokens.Length; i++)
            {
                var name = $"Q{i}";
                where.Append($"AND (p.PullNumber LIKE @{name} OR w.Code LIKE @{name} OR w.Name LIKE @{name}) ");
                p.Add(name, "%" + tokens[i] + "%");
            }
        }

        p.Add("Skip", Math.Max(0, (Math.Max(1, filter.Page) - 1) * Math.Clamp(filter.PageSize, 1, 500)));
        p.Add("Take", Math.Clamp(filter.PageSize, 1, 500));

        // ---- Result set 1: page of cards (UNCHANGED projection + UNCHANGED default sort) ----
        var pageSql = SummarySelect + where + @"
            ORDER BY p.PullDate DESC, p.PullNumber DESC
            OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;";

        // ---- Result set 2: aggregates over the FULL filtered set (one row) ----
        // vw_PullProgress is 1:1 with a pull (GROUP BY p.Id), so the LEFT JOIN does
        // not change COUNT(*). ItemsTotal = Σ (all PullItems per pull, active +
        // canceled) so it matches PullSummary.ItemCount exactly — NOT vp.ActiveItemCount
        // (which would drop canceled items and undercount). PullItems is pre-aggregated
        // in the `pic` derived table and LEFT JOINed 1:1, because SUM() cannot wrap a
        // correlated subquery (SQL error 130). ReceivedTotal/ExpectedTotal SUM joined
        // vw_PullProgress COLUMNS (vp), not subqueries, so they are already legal. The
        // Warehouses/Users joins are added only when searching, so the default hot path
        // stays Pulls + view + pic.
        var aggJoins = searchActive
            ? "INNER JOIN dbo.Warehouses w ON w.Id = p.WarehouseId LEFT JOIN dbo.Users u ON u.Id = p.CreatedBy "
            : "";
        var aggSql = @"
            SELECT
                COUNT(*)                                                            AS TotalPulls,
                ISNULL(SUM(CASE WHEN p.Status='pending'        THEN 1 ELSE 0 END),0) AS Pending,
                ISNULL(SUM(CASE WHEN p.Status='in_progress'    THEN 1 ELSE 0 END),0) AS InProgress,
                ISNULL(SUM(CASE WHEN p.Status='fully_received' THEN 1 ELSE 0 END),0) AS FullyReceived,
                ISNULL(SUM(CASE WHEN p.Status='closed'         THEN 1 ELSE 0 END),0) AS Closed,
                ISNULL(SUM(ISNULL(pic.ItemCount, 0)), 0)                   AS ItemsTotal,
                ISNULL(SUM(ISNULL(vp.TotalReceived, 0)), 0)                AS ReceivedTotal,
                ISNULL(SUM(ISNULL(vp.TotalExpected, 0)), 0)                AS ExpectedTotal
            FROM dbo.Pulls p
            LEFT JOIN dbo.vw_PullProgress vp ON vp.PullId = p.Id
            LEFT JOIN (
                SELECT PullId, COUNT(*) AS ItemCount
                FROM dbo.PullItems
                GROUP BY PullId
            ) pic ON pic.PullId = p.Id
            " + aggJoins + where + ";";

        using var conn = _factory.Create();
        using var multi = await conn.QueryMultipleAsync(
            new CommandDefinition(pageSql + aggSql, p, cancellationToken: ct));
        var items = (await multi.ReadAsync<PullSummary>()).AsList();
        var agg = await multi.ReadSingleAsync<PullDashboardAggregates>();
        return (items, agg);
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
                    piw.HourOfDay, piw.ExpectedQty, piw.ReceivedQty,
                    piw.IsClosed, piw.ClosedAt, piw.ClosedReason,  -- db/047
                    piw.VarianceReasonCode                        -- db/049
            FROM    dbo.PullItems pi
            LEFT JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
            WHERE   pi.PullId = @PullId
            ORDER BY pi.ItemCode, pi.VendorCode, pi.SortOrder, piw.HourOfDay;";

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
                    IsClosed = r.IsClosed ?? false,   // db/047
                    ClosedAt = r.ClosedAt,
                    ClosedReason = r.ClosedReason,
                    // db/049 — code plus its label, resolved from the one map in
                    // VarianceReasonCodes so no client holds a second copy of the labels
                    // and none can render a raw code by accident.
                    VarianceReasonCode = (string?)r.VarianceReasonCode,
                    VarianceReasonLabel = VarianceReasonCodes.Label((string?)r.VarianceReasonCode),
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
            Origin = summary.Origin,                    // db/050 — drawer provenance row
            TotalExpected = summary.TotalExpected,
            TotalReceived = summary.TotalReceived,
            ItemCount = summary.ItemCount,
            CanceledCount = summary.CanceledCount,
            NewCount = summary.NewCount,
            WindowsTotal = summary.WindowsTotal,
            WindowsPending = summary.WindowsPending,
            // Ordered by SKU, not by insertion order (same rule as itemsSql above).
            // VendorCode second because a SKU carried by two storers is two legitimate
            // rows (fa8a0e2): they belong next to each other, and a storer split that
            // lands at MAX(SortOrder)+1 must not fall to the bottom of the grid.
            // Ordinal to match ItemKey — a culture-aware compare orders these machine
            // codes differently depending on the host locale.
            //
            // SortOrder is the last key so two rows can never swap between loads, and
            // it stays the last key. It carries no unique constraint, so all three can
            // in principle tie; zero groups do today across 51,960 rows. Do not
            // "complete" this with .ThenBy(i => i.Id) — an Id tiebreaker pins the order
            // back to insertion sequence, the exact thing this ordering moves away
            // from. A tie appearing is a data question worth noticing, not one to bury
            // under a GUID.
            Items = itemsByGuid.Values
                .OrderBy(i => i.ItemCode, StringComparer.Ordinal)
                .ThenBy(i => i.VendorCode, StringComparer.Ordinal)
                .ThenBy(i => i.SortOrder)
                .ToList(),
        };
    }

    // v2.x Phase 7.3 — list view feeder for the Reports / DO page.
    // Closed pulls with at least one net-positive receipt (a DO needs proof
    // of delivery; pulls closed with everything cancelled produce nothing).
    // Phase 8.1: paged + total. ClosedAt covered by IX_Pulls_ClosedAt
    // (filtered Status='closed' INCLUDE WarehouseId+PullDate+PullNumber).
    //
    // Every filter the /Reports bar exposes is applied HERE, in SQL. The page
    // slice and the total share one `where` string — built once below and
    // appended to both statements — so the two can never drift into reporting
    // different populations, which is exactly what the header counter ("N
    // pulls", visible DOM rows) and the pager ("X closed pulls", unfiltered
    // COUNT) used to do.
    //
    // The WHERE is deliberately self-contained on `p`: it touches no alias from
    // SummarySelect's join list, so `SELECT COUNT(*) FROM dbo.Pulls p` plus the
    // same string is a valid statement. Keep it that way when adding filters.
    public async Task<(IReadOnlyList<PullSummary> Items, int Total)> GetClosedWithReceiptsAsync(
        ClosedPullQuery filter, CancellationToken ct = default)
    {
        var p = new DynamicParameters();
        var where = new StringBuilder(@"
            WHERE p.Status = 'closed'
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
              ) > 0 ");

        // ----- Warehouse -------------------------------------------------
        // At most one of these is set: the controller forces SessionWarehouseId
        // for non-admins (so a crafted ?warehouseId= can't widen their scope)
        // and passes the operator's picked WarehouseId only for admins.
        var effectiveWh = filter.SessionWarehouseId ?? filter.WarehouseId;
        if (effectiveWh is { } wh)
        {
            where.Append("AND p.WarehouseId = @WarehouseId ");
            p.Add("WarehouseId", wh);
        }

        // ----- Pull number ------------------------------------------------
        // Two OR'd alternatives, both PREFIX matches:
        //   1. against the stored value as typed — finds 'PL-DOR-...' and any
        //      operator who types the full zero-padded '0000031539';
        //   2. against the zero-stripped numeric value — so typing '31539',
        //      or a partial '315', finds stored '0000031539'.
        // TRY_CAST yields NULL for every non-numeric PullNumber (and for digit
        // strings too long for bigint), so those rows simply fall out of (2)
        // instead of raising a conversion error.
        if (!string.IsNullOrWhiteSpace(filter.PullNumber))
        {
            var raw = filter.PullNumber.Trim();
            where.Append(@"AND (p.PullNumber LIKE @PullRaw ESCAPE '\'
                                OR (@PullDigits IS NOT NULL
                                    AND CAST(TRY_CAST(p.PullNumber AS bigint) AS varchar(32))
                                        LIKE @PullDigits ESCAPE '\')) ");
            p.Add("PullRaw", EscapeLike(raw) + "%");
            p.Add("PullDigits", NormalizeDigits(raw));
        }

        // ----- Search: PO number + item code ------------------------------
        // EXISTS, never a JOIN: a pull with 40 lines matching the term must
        // still come back as ONE row, and must still be counted once.
        if (!string.IsNullOrWhiteSpace(filter.Q))
        {
            where.Append(@"AND (EXISTS (
                                    SELECT 1 FROM dbo.PullItems pi
                                    WHERE pi.PullId = p.Id
                                      AND pi.ItemCode LIKE @Q ESCAPE '\')
                                OR EXISTS (
                                    SELECT 1
                                    FROM dbo.Receipts r
                                    INNER JOIN dbo.PullItems pi2     ON pi2.Id = r.PullItemId
                                    INNER JOIN dbo.PurchaseOrders po ON po.Id  = r.PurchaseOrderId
                                    WHERE pi2.PullId = p.Id
                                      AND po.PoNumber LIKE @Q ESCAPE '\')) ");
            p.Add("Q", "%" + EscapeLike(filter.Q.Trim()) + "%");
        }

        // ----- Closed-at window -------------------------------------------
        // Half-open [from, to). "All dates" leaves both null and appends
        // nothing at all — the absence of a predicate is the feature.
        if (filter.ClosedFromUtc is { } from)
        {
            where.Append("AND p.ClosedAt >= @ClosedFrom ");
            p.Add("ClosedFrom", from);
        }
        if (filter.ClosedToUtc is { } to)
        {
            where.Append("AND p.ClosedAt < @ClosedTo ");
            p.Add("ClosedTo", to);
        }

        // ----- Signature status -------------------------------------------
        // UQ_PullSig_Party caps dbo.PullSignatures at 3 rows per pull, so the
        // correlated COUNT is a 3-row seek on the unique index.
        switch ((filter.Sign ?? "all").Trim().ToLowerInvariant())
        {
            case "complete":
                where.Append(@"AND (SELECT COUNT(*) FROM dbo.PullSignatures ps
                                    WHERE ps.PullId = p.Id) >= 3 ");
                break;
            case "awaiting":
                where.Append(@"AND (SELECT COUNT(*) FROM dbo.PullSignatures ps
                                    WHERE ps.PullId = p.Id) < 3 ");
                break;
            case "unsigned_mine":
                // "Any party I can sign that isn't signed on this pull." The
                // parties arrive as a list; rather than splicing an IN list into
                // the SQL, each of the 3 fixed parties gets a bit parameter and
                // the VALUES row-set does the matching.
                var mine = filter.SignParties ?? Array.Empty<string>();
                where.Append(@"AND EXISTS (
                                   SELECT 1
                                   FROM (VALUES ('Customer',   @MineCustomer),
                                                ('Warehouse',  @MineWarehouse),
                                                ('Production', @MineProduction)) AS v(Party, Mine)
                                   WHERE v.Mine = 1
                                     AND NOT EXISTS (
                                         SELECT 1 FROM dbo.PullSignatures ps
                                         WHERE ps.PullId = p.Id AND ps.Party = v.Party)) ");
                p.Add("MineCustomer",   Has(mine, "customer"));
                p.Add("MineWarehouse",  Has(mine, "warehouse"));
                p.Add("MineProduction", Has(mine, "production"));
                break;
        }

        var whereSql = where.ToString();
        var paging = new PaginatedRequest { Page = filter.Page, PageSize = filter.PageSize };
        p.Add("Skip", paging.Skip);
        p.Add("Take", paging.Take);

        var sql = SummarySelect + whereSql + @"
            ORDER BY p.ClosedAt DESC, p.PullDate DESC, p.Id DESC
            OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;
            SELECT COUNT(*) FROM dbo.Pulls p " + whereSql + ";";

        using var conn = _factory.Create();
        using var multi = await conn.QueryMultipleAsync(
            new CommandDefinition(sql, p, cancellationToken: ct));
        var items = (await multi.ReadAsync<PullSummary>()).AsList();
        var total = await multi.ReadSingleAsync<int>();
        return (items, total);
    }

    /// <summary>1 when the caller holds that signing party, else 0. Passed as a bit parameter.</summary>
    private static int Has(IReadOnlyList<string> parties, string party)
    {
        for (int i = 0; i < parties.Count; i++)
            if (string.Equals(parties[i], party, StringComparison.OrdinalIgnoreCase)) return 1;
        return 0;
    }

    /// <summary>
    /// Neutralises LIKE metacharacters in operator input so a search for "50%"
    /// looks for the literal text rather than matching every row. Pairs with
    /// ESCAPE '\' on every LIKE that consumes the result — the backslash itself
    /// is escaped first, or a hand-typed "\%" would arrive already-escaped.
    /// </summary>
    private static string EscapeLike(string s) => s
        .Replace("\\", "\\\\")
        .Replace("%", "\\%")
        .Replace("_", "\\_")
        .Replace("[", "\\[");

    /// <summary>
    /// The zero-stripped LIKE prefix for a pull-number search, or null when the
    /// operator typed anything that isn't a digit (in which case only the raw
    /// prefix alternative applies). "0000031539" becomes "31539%", "315" stays
    /// "315%", and an all-zeros input becomes "0%" rather than a bare "%" that
    /// would match everything.
    /// </summary>
    private static string? NormalizeDigits(string raw)
    {
        if (raw.Length == 0) return null;
        foreach (var c in raw) if (!char.IsAsciiDigit(c)) return null;
        var trimmed = raw.TrimStart('0');
        return (trimmed.Length == 0 ? "0" : trimmed) + "%";
    }

    // v2.x Phase 7.4 — DO report aggregation. Filter notes:
    //   ReversedById IS NULL excludes voided originals but keeps the reversal
    //   rows (which carry the negative qty per the §6 CHECK constraint). The
    //   reversal negatives cancel the originals at SUM time, and HAVING
    //   SUM > 0 drops (PO × Line × Item) tuples that net to zero.
    public async Task<IReadOnlyList<DoReportRow>> GetDoReportRowsAsync(
        Guid pullId, bool wdtTransferLinesOnly = false, CancellationToken ct = default)
    {
        // The remaining ERP-sourced extended fields below are invariant per
        // (PoId, LineNumber). MAX() lets us surface them without extending
        // GROUP BY (which would otherwise need duplicate listing of every
        // attribute) and is a no-op on uniqueness — never multiplies rows.
        // DO grouping = (VendorCode × SubInventory × ToLocation × InvoiceNo).
        // Invoice was promoted from a MAX'd line attribute to a first-class
        // grouping key so two distinct invoices under the same vendor / sub /
        // to-loc triple split into separate DOs (one page each in the PDF).
        // DN opt-in whitelist: keep ONLY lines whose Note is exactly the WDT
        // sentinel; every other line — including NULL/empty Note — is excluded
        // (NULL falls out of `=` naturally; no ISNULL/COALESCE wrapper). Exact
        // equality only — no LIKE/prefix — so 'Transferred from WDT2' is excluded.
        var wdtFilter = wdtTransferLinesOnly
            ? "\n              AND   pol.Note = @WdtTransferNote"
            : "";

        var sql = @"
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
                    pol.DeliveryDate,
                    SUM(r.QtyReceived) AS TotalQty,
                    MAX(r.ReceivedAt)     AS LastReceivedAt,
                    MAX(pol.PalletId)     AS PalletId,
                    MAX(pol.KanbanNo)     AS KanbanNo,
                    MAX(pol.AsnNo)        AS AsnNo,
                    MAX(pol.OrderRound)   AS OrderRound,
                    MAX(pol.SourcePoNo)   AS SourcePoNo,
                    MAX(pol.ProductionLine) AS ProductionLine
            FROM    dbo.Receipts r
            INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
            INNER JOIN dbo.PurchaseOrders po ON po.Id = r.PurchaseOrderId
            INNER JOIN dbo.PurchaseOrderLines pol ON pol.Id = r.PurchaseOrderLineId
            WHERE   pi.PullId = @PullId
              AND   r.ReversedById IS NULL" + wdtFilter + @"
            GROUP BY pol.VendorCode, pol.VendorName,
                     pol.SubInventory, pol.ToLocation, pol.InvoiceNo,
                     pol.OrderId, pol.DeliveryDate,
                     po.Id, po.PoNumber,
                     pol.LineNumber, pol.ItemCode, pol.Description
            HAVING  SUM(r.QtyReceived) > 0
            ORDER BY pol.VendorCode, pol.SubInventory, pol.ToLocation, pol.InvoiceNo,
                     po.PoNumber, pol.LineNumber, pol.ItemCode;";

        using var conn = _factory.Create();
        var rows = await conn.QueryAsync<DoReportRow>(
            new CommandDefinition(
                sql,
                new { PullId = pullId, WdtTransferNote = DoReportConstants.WdtTransferNote },
                cancellationToken: ct));
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
                    piw.HourOfDay, piw.ExpectedQty, piw.ReceivedQty,
                    piw.IsClosed, piw.ClosedAt, piw.ClosedReason,  -- db/047
                    piw.VarianceReasonCode                        -- db/049
            FROM    dbo.PullItems pi
            LEFT JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
            WHERE   pi.PullId = @PullId
            ORDER BY pi.ItemCode, pi.VendorCode, pi.SortOrder, piw.HourOfDay;";

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
                    piw.HourOfDay, piw.ExpectedQty, piw.ReceivedQty,
                    piw.IsClosed, piw.ClosedAt, piw.ClosedReason,  -- db/047
                    piw.VarianceReasonCode                        -- db/049
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
                    IsClosed = r.IsClosed ?? false,   // db/047
                    ClosedAt = r.ClosedAt,
                    ClosedReason = r.ClosedReason,
                    // db/049 — code plus its label, resolved from the one map in
                    // VarianceReasonCodes so no client holds a second copy of the labels
                    // and none can render a raw code by accident.
                    VarianceReasonCode = (string?)r.VarianceReasonCode,
                    VarianceReasonLabel = VarianceReasonCodes.Label((string?)r.VarianceReasonCode),
                });
            }
        }
        // Same order as GetByIdAsync — SKU, then storer, then SortOrder as the
        // final tiebreaker. See the comment there for why.
        return byGuid.Values
            .OrderBy(i => i.ItemCode, StringComparer.Ordinal)
            .ThenBy(i => i.VendorCode, StringComparer.Ordinal)
            .ThenBy(i => i.SortOrder);
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
        // db/047 — nullable because the window join is a LEFT JOIN: an item with no
        // windows yields NULLs across the whole window group, not just the quantities.
        public bool? IsClosed { get; set; }
        public DateTime? ClosedAt { get; set; }
        public string? ClosedReason { get; set; }
        // db/049 — NULL on open windows AND on windows closed before reason codes existed.
        public string? VarianceReasonCode { get; set; }
    }
}
