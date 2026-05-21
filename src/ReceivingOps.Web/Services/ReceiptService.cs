using System.Security.Claims;
using Dapper;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

public class ReceiptService : IReceiptService
{
    private static readonly HashSet<string> AllowedQcStatus =
        new(StringComparer.Ordinal) { "pending", "passed", "hold", "rejected" };

    private static readonly HashSet<string> AllowedCancelReason =
        new(StringComparer.Ordinal) { "miscount", "wrong-item", "qc-fail", "duplicate", "other" };

    private readonly IDbConnectionFactory _factory;
    private readonly IAuditService _audit;
    private readonly IHttpContextAccessor _httpContext;

    public ReceiptService(IDbConnectionFactory factory, IAuditService audit, IHttpContextAccessor httpContext)
    {
        _factory = factory;
        _audit = audit;
        _httpContext = httpContext;
    }

    // ============================================================================
    // §7.2 / §3.5 read-only FIFO preview (lock-aware)
    //
    //   - Reads Pulls.LockPoByPull from the parent pull. When true, restricts the
    //     FIFO scope to POs with PullId = this pull (per-pull strict mode).
    //     When false (default), scope is warehouse-wide (legacy behavior).
    //   - 400 on qty <= 0
    //   - 404 on missing pullItem
    //   - 403 on warehouse mismatch (non-admin)
    //   - 409 on closed pull, lock=true & no PO linked, or insufficient capacity
    // ============================================================================
    public async Task<ReceivePreviewResult> PreviewAsync(Guid pullItemId, int qty, CancellationToken ct = default)
    {
        if (qty <= 0) throw new ValidationException("Quantity must be positive");

        var sessionWh = SessionWarehouseId();
        var isAdmin   = SessionIsAdmin();

        using var conn = _factory.Create();

        var pullCtx = await conn.QuerySingleOrDefaultAsync<PullItemContext>(new CommandDefinition(@"
            SELECT pi.Id AS PullItemId, pi.ItemCode,
                   p.Id  AS PullId, p.PullNumber, p.Status AS PullStatus, p.WarehouseId,
                   p.LockPoByPull
            FROM   dbo.PullItems pi
            INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
            WHERE  pi.Id = @PullItemId;",
            new { PullItemId = pullItemId }, cancellationToken: ct))
            ?? throw new NotFoundException("Pull item not found");

        if (!isAdmin && sessionWh != pullCtx.WarehouseId)
            throw new ForbiddenException("You do not have access to this pull");

        if (string.Equals(pullCtx.PullStatus, "closed", StringComparison.Ordinal))
            throw new BusinessException("Pull is closed");

        var openLines = (await ReadOpenPoLinesAsync(conn, transaction: null, withLocks: false,
                                                    pullCtx, ct)).AsList();

        if (pullCtx.LockPoByPull && openLines.Count == 0)
            throw new BusinessException(
                "No PO linked to this pull. Procurement must link a PO before receiving.");

        var totalAvailable = openLines.Sum(l => l.OrderedQty - l.ReceivedQty);
        if (totalAvailable < qty)
            throw new BusinessException(
                $"Insufficient PO capacity. Need {qty}, have {totalAvailable} pcs.");

        var plan = BuildAllocationPlan(openLines, qty);

        return new ReceivePreviewResult
        {
            Allocations      = plan,
            TotalAllocatable = totalAvailable,
            Shortage         = 0,
            Scope            = pullCtx.LockPoByPull ? "pull-locked" : "warehouse-wide",
        };
    }

    // ----- helpers shared by Preview (no locks) and Receive (UPDLOCK + HOLDLOCK in 4b) -----

    private static List<AllocationResult> BuildAllocationPlan(IReadOnlyList<PoLineAvailability> lines, int qty)
    {
        var allocations = new List<AllocationResult>();
        var remaining = qty;
        foreach (var line in lines)
        {
            var lineRemaining = line.OrderedQty - line.ReceivedQty;
            var take = Math.Min(lineRemaining, remaining);
            if (take > 0)
            {
                allocations.Add(new AllocationResult
                {
                    PurchaseOrderId     = line.PurchaseOrderId,
                    PoNumber            = line.PoNumber,
                    PurchaseOrderLineId = line.PurchaseOrderLineId,
                    PoLineNumber        = line.LineNumber,
                    Qty                 = take,
                    // ReceiptId stays Guid.Empty for preview — no row inserted.
                });
                remaining -= take;
            }
            if (remaining == 0) break;
        }
        return allocations;
    }

    // Builds the FIFO read query. SQL is fixed strings; the only branch is appended
    // when the pull is in lock=true mode (no user input flows into the string).
    private static async Task<IEnumerable<PoLineAvailability>> ReadOpenPoLinesAsync(
        System.Data.IDbConnection conn,
        System.Data.IDbTransaction? transaction,
        bool withLocks,
        PullItemContext pullCtx,
        CancellationToken ct)
    {
        var hints = withLocks ? "WITH (UPDLOCK, HOLDLOCK, ROWLOCK)" : "";
        var sql = $@"
            SELECT pol.Id AS PurchaseOrderLineId, pol.PurchaseOrderId, po.PoNumber, po.OrderDate,
                   pol.LineNumber, pol.OrderedQty, pol.ReceivedQty
            FROM   dbo.PurchaseOrderLines pol {hints}
            INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
            WHERE  po.WarehouseId = @WarehouseId
              AND  po.Status      = 'open'
              AND  pol.ItemCode   = @ItemCode
              AND  pol.OrderedQty > pol.ReceivedQty";

        if (pullCtx.LockPoByPull)
            sql += " AND po.PullId = @PullId";

        sql += " ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;";

        return await conn.QueryAsync<PoLineAvailability>(new CommandDefinition(
            sql,
            new { pullCtx.WarehouseId, pullCtx.ItemCode, pullCtx.PullId },
            transaction: transaction,
            cancellationToken: ct));
    }

    // ============================================================================
    // §7.2a atomic FIFO receive
    // ============================================================================
    public async Task<ReceiveResult> ReceiveAsync(ReceiveRequest req, CancellationToken ct = default)
    {
        // ----- 0. Validation -----
        if (req.Qty <= 0) throw new BusinessException("Qty must be positive");
        if (req.HourOfDay > 23) throw new BusinessException("HourOfDay must be 0–23");

        var qcStatus = req.QcStatus ?? "pending";
        if (!AllowedQcStatus.Contains(qcStatus))
            throw new BusinessException($"Invalid QcStatus '{qcStatus}'");

        var actorId   = CurrentUserId();
        var sessionWh = SessionWarehouseId();
        var isAdmin   = SessionIsAdmin();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // ----- 1. Lock the parent pull row + read its current status -----
            var pullCtx = await conn.QuerySingleOrDefaultAsync<PullItemContext>(new CommandDefinition(@"
                SELECT pi.Id AS PullItemId, pi.ItemCode, p.Id AS PullId, p.PullNumber, p.Status AS PullStatus, p.WarehouseId
                FROM   dbo.Pulls p WITH (UPDLOCK, ROWLOCK)
                INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id
                WHERE  pi.Id = @PullItemId;",
                new { req.PullItemId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Pull item not found");

            // §7.12 closed pull is read-only
            if (string.Equals(pullCtx.PullStatus, "closed", StringComparison.Ordinal))
                throw new BusinessException("Pull is closed and cannot accept receipts");

            // §5.5 / §7.9 admin override
            if (!isAdmin && sessionWh != pullCtx.WarehouseId)
                throw new ForbiddenException("You do not have access to this pull");

            // ----- 2. Lock all open PO lines for this (warehouse, item) — FIFO order -----
            // UPDLOCK + HOLDLOCK gives serializable range protection for the FIFO query.
            var openLines = (await conn.QueryAsync<PoLineAvailability>(new CommandDefinition(@"
                SELECT pol.Id AS PurchaseOrderLineId, pol.PurchaseOrderId, po.PoNumber, po.OrderDate,
                       pol.LineNumber, pol.OrderedQty, pol.ReceivedQty
                FROM   dbo.PurchaseOrderLines pol WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
                INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
                WHERE  po.WarehouseId = @WarehouseId
                  AND  po.Status      = 'open'
                  AND  pol.ItemCode   = @ItemCode
                  AND  pol.OrderedQty > pol.ReceivedQty
                ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;",
                new { pullCtx.WarehouseId, pullCtx.ItemCode },
                transaction: tx, cancellationToken: ct))).AsList();

            var totalAvailable = openLines.Sum(l => l.OrderedQty - l.ReceivedQty);
            if (totalAvailable < req.Qty)
                throw new BusinessException(
                    $"Insufficient PO capacity. Requested {req.Qty} but only {totalAvailable} pcs remain across all open POs for {pullCtx.ItemCode}. Open another PO before receiving.");

            // ----- 3. Build the allocation plan (FIFO walk) -----
            var plan = new List<(PoLineAvailability Line, int Take)>();
            var remaining = req.Qty;
            foreach (var line in openLines)
            {
                var lineRemaining = line.OrderedQty - line.ReceivedQty;
                var take = Math.Min(lineRemaining, remaining);
                if (take > 0)
                {
                    plan.Add((line, take));
                    remaining -= take;
                }
                if (remaining == 0) break;
            }

            // ----- 4. Insert one Receipts row per allocation slice + update PO line cache -----
            var allocations = new List<AllocationResult>(plan.Count);
            foreach (var (line, take) in plan)
            {
                var receiptId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                    INSERT INTO dbo.Receipts
                        (PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived,
                         LotBatch, PalletId, BinLocation, QcStatus, Note, ReceivedBy)
                    OUTPUT INSERTED.Id
                    VALUES (@PullItemId, @PoId, @PoLineId, @HourOfDay, @Qty,
                            @LotBatch, @PalletId, @BinLocation, @QcStatus, @Note, @ReceivedBy);",
                    new
                    {
                        req.PullItemId,
                        PoId       = line.PurchaseOrderId,
                        PoLineId   = line.PurchaseOrderLineId,
                        req.HourOfDay,
                        Qty        = take,
                        req.LotBatch, req.PalletId, req.BinLocation,
                        QcStatus   = qcStatus,
                        req.Note,
                        ReceivedBy = actorId,
                    }, transaction: tx, cancellationToken: ct));

                await conn.ExecuteAsync(new CommandDefinition(@"
                    UPDATE dbo.PurchaseOrderLines
                       SET ReceivedQty = ReceivedQty + @Take
                     WHERE Id = @LineId;",
                    new { Take = take, LineId = line.PurchaseOrderLineId },
                    transaction: tx, cancellationToken: ct));

                allocations.Add(new AllocationResult
                {
                    ReceiptId           = receiptId,
                    PurchaseOrderId     = line.PurchaseOrderId,
                    PoNumber            = line.PoNumber,
                    PurchaseOrderLineId = line.PurchaseOrderLineId,
                    PoLineNumber        = line.LineNumber,
                    Qty                 = take,
                });
            }

            // ----- 5. Auto-close any PO that's now fully received -----
            var poIdsTouched = plan.Select(p => p.Line.PurchaseOrderId).Distinct().ToList();
            if (poIdsTouched.Count > 0)
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    UPDATE dbo.PurchaseOrders
                       SET Status   = 'closed',
                           ClosedAt = SYSUTCDATETIME()
                     WHERE Id IN @PoIds
                       AND Status = 'open'
                       AND NOT EXISTS (
                           SELECT 1 FROM dbo.PurchaseOrderLines pol
                           WHERE pol.PurchaseOrderId = dbo.PurchaseOrders.Id
                             AND pol.OrderedQty > pol.ReceivedQty
                       );",
                    new { PoIds = poIdsTouched }, transaction: tx, cancellationToken: ct));
            }

            // ----- 6. Update PullItemWindows cache (single +Qty for the hour) -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItemWindows
                   SET ReceivedQty = ReceivedQty + @Qty
                 WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { Qty = req.Qty, req.PullItemId, req.HourOfDay },
                transaction: tx, cancellationToken: ct));

            // ----- 7. Update Pulls timing + auto-promote pending → in_progress -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Pulls
                   SET LastActivityAt = SYSUTCDATETIME(),
                       FirstReceiptAt = ISNULL(FirstReceiptAt, SYSUTCDATETIME()),
                       Status         = CASE WHEN Status = 'pending' THEN 'in_progress' ELSE Status END
                 WHERE Id = @PullId;",
                new { pullCtx.PullId }, transaction: tx, cancellationToken: ct));

            // ----- 8. Audit (one summary row) -----
            var summary = string.Join(" + ", plan.Select(p => $"{p.Take}@{p.Line.PoNumber}"));
            await _audit.WriteAsync(conn, tx, "receive", "Receipt", $"pi={req.PullItemId}",
                $"Received {req.Qty} pcs of {pullCtx.ItemCode} at hour {req.HourOfDay}. Allocated: {summary}", ct);

            // ----- 9. Compute response fields before commit -----
            var newWindowQty = await conn.QuerySingleAsync<int>(new CommandDefinition(@"
                SELECT ReceivedQty FROM dbo.PullItemWindows
                WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { req.PullItemId, req.HourOfDay }, transaction: tx, cancellationToken: ct));

            var outstandingWindows = await conn.QuerySingleAsync<int>(new CommandDefinition(@"
                SELECT COUNT(*) FROM dbo.PullItems pi
                INNER JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
                WHERE pi.PullId = @PullId
                  AND pi.Status <> 'canceled'
                  AND piw.ExpectedQty > piw.ReceivedQty;",
                new { pullCtx.PullId }, transaction: tx, cancellationToken: ct));

            tx.Commit();

            return new ReceiveResult
            {
                Allocations    = allocations,
                TotalQty       = req.Qty,
                NewReceivedQty = newWindowQty,
                FullyReceived  = outstandingWindows == 0,
            };
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ============================================================================
    // §7.3 reverse-entry cancel
    // ============================================================================
    public async Task<CancelResult> CancelAsync(Guid receiptId, CancelRequest req, CancellationToken ct = default)
    {
        var reason = (req.Reason ?? "").Trim();
        if (!AllowedCancelReason.Contains(reason))
            throw new BusinessException("Reason is required (miscount|wrong-item|qc-fail|duplicate|other)");

        var actorId   = CurrentUserId();
        var sessionWh = SessionWarehouseId();
        var isAdmin   = SessionIsAdmin();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // ----- 1. Lock the original receipt + read its PO line -----
            var orig = await conn.QuerySingleOrDefaultAsync<ReceiptLockRow>(new CommandDefinition(@"
                SELECT Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId,
                       HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation,
                       QcStatus, ReversedById
                FROM   dbo.Receipts WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = receiptId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Receipt not found");

            if (orig.QtyReceived < 0)
                throw new BusinessException("Cannot cancel a reversal entry");
            if (orig.ReversedById is not null)
                throw new BusinessException("Receipt is already voided");

            // ----- 2. Lock the parent pull, enforce closed/warehouse rules -----
            var pullCtx = await conn.QuerySingleAsync<PullItemContext>(new CommandDefinition(@"
                SELECT pi.Id AS PullItemId, pi.ItemCode, p.Id AS PullId, p.PullNumber, p.Status AS PullStatus, p.WarehouseId
                FROM   dbo.Pulls p WITH (UPDLOCK, ROWLOCK)
                INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id
                WHERE  pi.Id = @PullItemId;",
                new { orig.PullItemId }, transaction: tx, cancellationToken: ct));

            if (string.Equals(pullCtx.PullStatus, "closed", StringComparison.Ordinal))
                throw new BusinessException("Cannot cancel; pull is closed");

            if (!isAdmin && sessionWh != pullCtx.WarehouseId)
                throw new ForbiddenException("You do not have access to this pull");

            // ----- 3. Lock the PO line the original consumed; capture PoNumber + state for audit + response -----
            var poLine = await conn.QuerySingleAsync<PoLineLockRow>(new CommandDefinition(@"
                SELECT pol.Id AS PurchaseOrderLineId, pol.PurchaseOrderId, po.PoNumber, po.Status AS PoStatus,
                       pol.LineNumber, pol.OrderedQty, pol.ReceivedQty
                FROM   dbo.PurchaseOrderLines pol WITH (UPDLOCK, ROWLOCK)
                INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
                WHERE  pol.Id = @LineId;",
                new { LineId = orig.PurchaseOrderLineId },
                transaction: tx, cancellationToken: ct));

            // ----- 4. Insert the reversal row (negative qty, SAME PO line as original) -----
            var reversalId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.Receipts
                    (PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived,
                     LotBatch, PalletId, BinLocation, QcStatus, Note, ReceivedBy,
                     ReversesReceiptId, CancelReason)
                OUTPUT INSERTED.Id
                VALUES (@PullItemId, @PoId, @PoLineId, @HourOfDay, @NegQty,
                        @LotBatch, @PalletId, @BinLocation, @QcStatus, @Note, @ReceivedBy,
                        @OrigId, @Reason);",
                new
                {
                    orig.PullItemId,
                    PoId       = orig.PurchaseOrderId,
                    PoLineId   = orig.PurchaseOrderLineId,
                    orig.HourOfDay,
                    NegQty     = -orig.QtyReceived,
                    orig.LotBatch, orig.PalletId, orig.BinLocation, orig.QcStatus,
                    Note       = req.Note,
                    ReceivedBy = actorId,
                    OrigId     = orig.Id,
                    Reason     = reason,
                }, transaction: tx, cancellationToken: ct));

            // ----- 5. Back-link original → reversal -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Receipts SET ReversedById = @RevId WHERE Id = @OrigId;",
                new { RevId = reversalId, OrigId = orig.Id },
                transaction: tx, cancellationToken: ct));

            // ----- 6. Restore qty to the PO line -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PurchaseOrderLines
                   SET ReceivedQty = ReceivedQty - @Qty
                 WHERE Id = @LineId;",
                new { Qty = orig.QtyReceived, LineId = orig.PurchaseOrderLineId },
                transaction: tx, cancellationToken: ct));

            // ----- 7. Auto-reopen the PO if cancel restored capacity to a previously-auto-closed PO -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PurchaseOrders
                   SET Status   = 'open',
                       ClosedAt = NULL
                 WHERE Id = @PoId
                   AND Status = 'closed';",
                new { PoId = orig.PurchaseOrderId },
                transaction: tx, cancellationToken: ct));

            // ----- 8. Decrement PullItemWindows cache -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItemWindows
                   SET ReceivedQty = ReceivedQty - @Qty
                 WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { Qty = orig.QtyReceived, orig.PullItemId, orig.HourOfDay },
                transaction: tx, cancellationToken: ct));

            // ----- 9. Update Pulls timing + demote fully_received → in_progress -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Pulls
                   SET LastActivityAt = SYSUTCDATETIME(),
                       Status = CASE WHEN Status = 'fully_received' THEN 'in_progress' ELSE Status END
                 WHERE Id = @PullId;",
                new { pullCtx.PullId }, transaction: tx, cancellationToken: ct));

            // ----- 10. Audit -----
            var noteSuffix = string.IsNullOrWhiteSpace(req.Note) ? "" : $" {req.Note}";
            await _audit.WriteAsync(conn, tx, "cancel", "Receipt", orig.Id.ToString(),
                $"Cancelled receipt {orig.Id} (-{orig.QtyReceived} pcs of {pullCtx.ItemCode} from {poLine.PoNumber}). Reason: {reason}.{noteSuffix}", ct);

            // ----- 11. Read post-commit window qty + PO line restored state -----
            var newWindowQty = await conn.QuerySingleAsync<int>(new CommandDefinition(@"
                SELECT ReceivedQty FROM dbo.PullItemWindows
                WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { orig.PullItemId, orig.HourOfDay }, transaction: tx, cancellationToken: ct));

            // poLine.ReceivedQty was the pre-restore value; after step 6 the restored remaining is OrderedQty - (ReceivedQty - origQty)
            var newRemainingQty = poLine.OrderedQty - (poLine.ReceivedQty - orig.QtyReceived);

            tx.Commit();

            return new CancelResult
            {
                ReversalReceiptId = reversalId,
                NewReceivedQty    = newWindowQty,
                PoLineRestored    = new PoLineRestored
                {
                    PurchaseOrderId     = orig.PurchaseOrderId,
                    PoNumber            = poLine.PoNumber,
                    PurchaseOrderLineId = orig.PurchaseOrderLineId,
                    LineNumber          = poLine.LineNumber,
                    NewRemainingQty     = newRemainingQty,
                },
            };
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ============================================================================
    // helpers
    // ============================================================================

    private Guid CurrentUserId()
    {
        var ctx = _httpContext.HttpContext
            ?? throw new InvalidOperationException("HttpContext unavailable");
        var idClaim = ctx.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!Guid.TryParse(idClaim, out var id))
            throw new InvalidOperationException("Authenticated user has no NameIdentifier claim");
        return id;
    }

    private (Guid? warehouseId, bool isAdmin) SessionWarehouseContext()
        => (SessionWarehouseId(), SessionIsAdmin());

    private Guid? SessionWarehouseId()
    {
        var ctx = _httpContext.HttpContext;
        if (ctx is null) return null;
        return Guid.TryParse(ctx.User.FindFirstValue("warehouseId"), out var g) ? g : null;
    }

    private bool SessionIsAdmin()
        => _httpContext.HttpContext?.User.IsInRole("admin") ?? false;

    // ---------- internal row shapes ----------

    private sealed class PullItemContext
    {
        public Guid PullItemId { get; set; }
        public string ItemCode { get; set; } = "";
        public Guid PullId { get; set; }
        public string PullNumber { get; set; } = "";
        public string PullStatus { get; set; } = "";
        public Guid WarehouseId { get; set; }
        // §3.5 — Preview/Receive SELECTs hydrate this from Pulls.LockPoByPull.
        // Receive's existing SELECT doesn't include this column yet (4a touches Preview only);
        // Dapper leaves the property at default(false), preserving warehouse-wide FIFO until 4b.
        public bool LockPoByPull { get; set; }
    }

    private sealed class PoLineAvailability
    {
        public Guid PurchaseOrderLineId { get; set; }
        public Guid PurchaseOrderId { get; set; }
        public string PoNumber { get; set; } = "";
        public DateTime OrderDate { get; set; }
        public int LineNumber { get; set; }
        public int OrderedQty { get; set; }
        public int ReceivedQty { get; set; }
    }

    private sealed class ReceiptLockRow
    {
        public Guid Id { get; set; }
        public Guid PullItemId { get; set; }
        public Guid PurchaseOrderId { get; set; }
        public Guid PurchaseOrderLineId { get; set; }
        public byte HourOfDay { get; set; }
        public int QtyReceived { get; set; }
        public string? LotBatch { get; set; }
        public string? PalletId { get; set; }
        public string? BinLocation { get; set; }
        public string QcStatus { get; set; } = "pending";
        public Guid? ReversedById { get; set; }
    }

    private sealed class PoLineLockRow
    {
        public Guid PurchaseOrderLineId { get; set; }
        public Guid PurchaseOrderId { get; set; }
        public string PoNumber { get; set; } = "";
        public string PoStatus { get; set; } = "";
        public int LineNumber { get; set; }
        public int OrderedQty { get; set; }
        public int ReceivedQty { get; set; }
    }
}
