using System.Data;
using System.Security.Claims;
using Dapper;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Models.Dtos;
using ReceivingOps.Web.Models.Entities;

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

    public async Task<ReceiveResult> ReceiveAsync(ReceiveRequest req, CancellationToken ct = default)
    {
        // ----- 0. Input validation (cheap, no DB hit) -----
        if (req.Qty <= 0)
            throw new BusinessException("Qty must be positive");
        if (req.HourOfDay > 23)
            throw new BusinessException("HourOfDay must be 0–23");

        var qcStatus = req.QcStatus ?? "pending";
        if (!AllowedQcStatus.Contains(qcStatus))
            throw new BusinessException($"Invalid QcStatus '{qcStatus}'");

        var actorId = CurrentUserId();
        var (sessionWh, isAdmin) = SessionWarehouseContext();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // ----- 1. Lock the parent Pull row + read its current status. -----
            // Joining via PullItems also confirms the item exists.
            var pullCtx = await conn.QuerySingleOrDefaultAsync<PullLockRow>(new CommandDefinition(@"
                SELECT p.Id AS PullId, p.PullNumber, p.Status, p.WarehouseId
                FROM dbo.Pulls p WITH (UPDLOCK, ROWLOCK)
                INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id
                WHERE pi.Id = @PullItemId;",
                new { req.PullItemId }, transaction: tx, cancellationToken: ct));

            if (pullCtx is null)
                throw new NotFoundException("Pull item not found");

            // §7.12 closed pull is read-only — server-enforced regardless of client UI.
            if (string.Equals(pullCtx.Status, "closed", StringComparison.Ordinal))
                throw new BusinessException("Pull is closed and cannot accept receipts");

            // Warehouse scoping (§5.5 / §7.9 admin override).
            if (!isAdmin && sessionWh != pullCtx.WarehouseId)
                throw new ForbiddenException("You do not have access to this pull");

            // ----- 2. Lock the specific window row. -----
            var window = await conn.QuerySingleOrDefaultAsync<PullItemWindow>(new CommandDefinition(@"
                SELECT Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty
                FROM dbo.PullItemWindows WITH (UPDLOCK, ROWLOCK)
                WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { req.PullItemId, req.HourOfDay }, transaction: tx, cancellationToken: ct));

            if (window is null)
                throw new NotFoundException(
                    $"No expected window for hour {req.HourOfDay} on this item");

            // §7.1 cap-at-expected — application-level check before the DB CHECK constraint.
            var remaining = window.ExpectedQty - window.ReceivedQty;
            if (req.Qty > remaining)
                throw new BusinessException(
                    $"Cannot receive {req.Qty}; only {remaining} remaining for hour {req.HourOfDay}.");

            // ----- 3. INSERT receipt row. Forward (positive) entry → ReversesReceiptId stays NULL. -----
            var receiptId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.Receipts
                    (PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation,
                     QcStatus, Note, ReceivedBy)
                OUTPUT INSERTED.Id
                VALUES (@PullItemId, @HourOfDay, @Qty, @LotBatch, @PalletId, @BinLocation,
                        @QcStatus, @Note, @ReceivedBy);",
                new
                {
                    req.PullItemId, req.HourOfDay, req.Qty,
                    req.LotBatch, req.PalletId, req.BinLocation,
                    QcStatus = qcStatus, req.Note,
                    ReceivedBy = actorId,
                }, transaction: tx, cancellationToken: ct));

            // ----- 4. UPDATE window cache. -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItemWindows
                   SET ReceivedQty = ReceivedQty + @Qty
                 WHERE Id = @Id;",
                new { Id = window.Id, req.Qty }, transaction: tx, cancellationToken: ct));

            // ----- 5. UPDATE pull timing + auto-promote (pending → in_progress). -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Pulls
                   SET LastActivityAt = SYSUTCDATETIME(),
                       FirstReceiptAt = ISNULL(FirstReceiptAt, SYSUTCDATETIME()),
                       Status         = CASE WHEN Status = 'pending' THEN 'in_progress' ELSE Status END
                 WHERE Id = @PullId;",
                new { pullCtx.PullId }, transaction: tx, cancellationToken: ct));

            // ----- 6. Audit (never throws — AuditService swallows). -----
            await _audit.WriteAsync(conn, tx, "receive", "Receipt", receiptId.ToString(),
                $"Received {req.Qty} pcs at hour {req.HourOfDay} (pull {pullCtx.PullNumber})", ct);

            tx.Commit();

            // TODO Phase 4: rewrite this whole method for FIFO allocation; the
            // INSERT below now fails at runtime (515) because Receipts.PurchaseOrder*
            // are NOT NULL. The return shape is stitched to compile only.
            return new ReceiveResult
            {
                Allocations = new List<AllocationResult>
                {
                    new() { ReceiptId = receiptId, Qty = req.Qty },
                },
                TotalQty = req.Qty,
                NewReceivedQty = window.ReceivedQty + req.Qty,
                FullyReceived = false,
            };
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    public async Task<CancelResult> CancelAsync(Guid receiptId, CancelRequest req, CancellationToken ct = default)
    {
        // ----- 0. Input validation -----
        var reason = (req.Reason ?? "").Trim();
        if (!AllowedCancelReason.Contains(reason))
            throw new BusinessException("Reason is required (miscount|wrong-item|qc-fail|duplicate|other)");

        var actorId = CurrentUserId();
        var (sessionWh, isAdmin) = SessionWarehouseContext();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // ----- 1. Lock the original receipt -----
            var orig = await conn.QuerySingleOrDefaultAsync<Receipt>(new CommandDefinition(@"
                SELECT Id, PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation,
                       QcStatus, Note, ReceivedBy, ReceivedAt,
                       ReversesReceiptId, ReversedById, CancelReason
                FROM dbo.Receipts WITH (UPDLOCK, ROWLOCK)
                WHERE Id = @Id;",
                new { Id = receiptId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Receipt not found");

            if (orig.QtyReceived < 0)
                throw new BusinessException("Cannot cancel a reversal entry");
            if (orig.ReversedById is not null)
                throw new BusinessException("Receipt is already voided");

            // ----- 2. Lock the parent pull, enforce closed/warehouse rules -----
            var pullCtx = await conn.QuerySingleAsync<PullLockRow>(new CommandDefinition(@"
                SELECT p.Id AS PullId, p.PullNumber, p.Status, p.WarehouseId
                FROM dbo.Pulls p WITH (UPDLOCK, ROWLOCK)
                INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id
                WHERE pi.Id = @PullItemId;",
                new { orig.PullItemId }, transaction: tx, cancellationToken: ct));

            if (string.Equals(pullCtx.Status, "closed", StringComparison.Ordinal))
                throw new BusinessException("Cannot cancel; pull is closed");

            if (!isAdmin && sessionWh != pullCtx.WarehouseId)
                throw new ForbiddenException("You do not have access to this pull");

            // ----- 3. INSERT the reversal row (negative qty, linked to original) -----
            var reversalId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                INSERT INTO dbo.Receipts
                    (PullItemId, HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation,
                     QcStatus, Note, ReceivedBy, ReversesReceiptId, CancelReason)
                OUTPUT INSERTED.Id
                VALUES (@PullItemId, @HourOfDay, @NegQty, @LotBatch, @PalletId, @BinLocation,
                        @QcStatus, @Note, @ReceivedBy, @OrigId, @Reason);",
                new
                {
                    orig.PullItemId, orig.HourOfDay,
                    NegQty = -orig.QtyReceived,
                    orig.LotBatch, orig.PalletId, orig.BinLocation,
                    orig.QcStatus,
                    Note = req.Note,
                    ReceivedBy = actorId,
                    OrigId = orig.Id,
                    Reason = reason,
                }, transaction: tx, cancellationToken: ct));

            // ----- 4. Mark the original as voided -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Receipts
                   SET ReversedById = @ReversalId
                 WHERE Id = @OrigId;",
                new { ReversalId = reversalId, OrigId = orig.Id },
                transaction: tx, cancellationToken: ct));

            // ----- 5. Subtract from PullItemWindows cache -----
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItemWindows
                   SET ReceivedQty = ReceivedQty - @Qty
                 WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { Qty = orig.QtyReceived, orig.PullItemId, orig.HourOfDay },
                transaction: tx, cancellationToken: ct));

            // ----- 6. UPDATE pull timing + demote fully_received → in_progress -----
            //         (Do NOT clear FirstReceiptAt — once goods have flowed, that fact stays.)
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Pulls
                   SET LastActivityAt = SYSUTCDATETIME(),
                       Status = CASE WHEN Status = 'fully_received' THEN 'in_progress' ELSE Status END
                 WHERE Id = @PullId;",
                new { pullCtx.PullId }, transaction: tx, cancellationToken: ct));

            // ----- 7. Audit -----
            var noteSuffix = string.IsNullOrWhiteSpace(req.Note) ? "" : $" {req.Note}";
            await _audit.WriteAsync(conn, tx, "cancel", "Receipt", orig.Id.ToString(),
                $"Cancelled receipt {orig.Id} (-{orig.QtyReceived} pcs). Reason: {reason}.{noteSuffix}", ct);

            tx.Commit();

            // Read post-commit ReceivedQty so the caller can refresh the cell.
            var newReceived = await conn.QuerySingleAsync<int>(new CommandDefinition(@"
                SELECT ReceivedQty FROM dbo.PullItemWindows
                WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { orig.PullItemId, orig.HourOfDay }, cancellationToken: ct));

            return new CancelResult
            {
                ReversalReceiptId = reversalId,
                NewReceivedQty = newReceived,
            };
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ---------- helpers ----------

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
    {
        var ctx = _httpContext.HttpContext;
        if (ctx is null) return (null, false);

        var isAdmin = ctx.User.IsInRole("admin");
        Guid? wh = null;
        if (Guid.TryParse(ctx.User.FindFirstValue("warehouseId"), out var g)) wh = g;
        return (wh, isAdmin);
    }

    // ---------- internal row shapes ----------

    private sealed class PullLockRow
    {
        public Guid PullId { get; set; }
        public string PullNumber { get; set; } = "";
        public string Status { get; set; } = "";
        public Guid WarehouseId { get; set; }
    }
}
