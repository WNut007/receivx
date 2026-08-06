using System.Security.Claims;
using Dapper;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// §7.2 receive / §7.3 cancel.
///
/// CANONICAL LOCK ACQUISITION ORDER — db/047. Every write path in this class MUST
/// take locks in this order, and must not take a later lock before an earlier one:
///
///     1. dbo.Receipts             (UPDLOCK, ROWLOCK)  — cancel only; receive inserts
///     2. dbo.Pulls                (UPDLOCK, ROWLOCK)
///     3. dbo.PullItemWindows      (UPDLOCK, ROWLOCK)
///     4. dbo.PurchaseOrderLines   (UPDLOCK, HOLDLOCK, ROWLOCK)
///
/// Why it matters: before db/047, ReceiveAsync took PullItemWindows (via the hour-cap
/// check) BEFORE PurchaseOrderLines, while CancelAsync took PurchaseOrderLines first and
/// then blind-UPDATEd the window with no lock at all. That inversion was latent only
/// because cancel never locked the window. db/047 makes cancel lock the window — to clear
/// IsClosed — so without a single order the two paths would deadlock under concurrent
/// receive+cancel on the same SKU (brief §2c, regression test 15).
/// </summary>
public class ReceiptService : IReceiptService
{
    private static readonly HashSet<string> AllowedQcStatus =
        new(StringComparer.Ordinal) { "pending", "passed", "hold", "rejected" };

    private static readonly HashSet<string> AllowedCancelReason =
        new(StringComparer.Ordinal) { "miscount", "wrong-item", "qc-fail", "duplicate", "other" };

    private readonly IDbConnectionFactory _factory;
    private readonly IAuditService _audit;
    private readonly IHttpContextAccessor _httpContext;
    private readonly ILogger<ReceiptService> _logger;

    public ReceiptService(
        IDbConnectionFactory factory,
        IAuditService audit,
        IHttpContextAccessor httpContext,
        ILogger<ReceiptService> logger)
    {
        _factory = factory;
        _audit = audit;
        _httpContext = httpContext;
        _logger = logger;
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
    public async Task<ReceivePreviewResult> PreviewAsync(
        Guid pullItemId, int qty, byte? hourOfDay = null,
        bool varianceAccepted = false, CancellationToken ct = default)
    {
        // db/047 §2c — PREVIEW AND CONFIRM MUST AGREE. Every rule below is the same rule
        // ReceiveAsync applies, raising the same status, code and message. A preview that
        // promises more than confirm delivers is the same defect as the silent clamp
        // wearing a different hat: the screen states one quantity and the system uses
        // another. If you change a rule here, change it there in the same edit.
        if (qty < 0) throw new ValidationException("Quantity cannot be negative");
        if (qty == 0 && !varianceAccepted)
            throw new ValidationException(
                "A zero quantity records nothing. Tick 'accept variance' to close the line short.",
                "ZERO_QTY_WITHOUT_VARIANCE");
        if (hourOfDay is { } h && h > 23) throw new ValidationException("HourOfDay must be 0–23");

        var sessionWh = SessionWarehouseId();
        var isAdmin   = SessionIsAdmin();

        using var conn = _factory.Create();

        var pullCtx = await conn.QuerySingleOrDefaultAsync<PullItemContext>(new CommandDefinition(@"
            SELECT pi.Id AS PullItemId, pi.ItemCode,
                   p.Id  AS PullId, p.PullNumber, p.Status AS PullStatus, p.WarehouseId,
                   p.LockPoByPull, p.LockHourCap
            FROM   dbo.PullItems pi
            INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
            WHERE  pi.Id = @PullItemId;",
            new { PullItemId = pullItemId }, cancellationToken: ct))
            ?? throw new NotFoundException("Pull item not found");

        if (!isAdmin && sessionWh != pullCtx.WarehouseId)
            throw new ForbiddenException("You do not have access to this pull");

        if (string.Equals(pullCtx.PullStatus, "closed", StringComparison.Ordinal))
            throw new BusinessException("Pull is closed");

        // ----- Window rules, mirroring ReceiveAsync exactly (§2c agreement) -----
        // Only when the caller supplied an hour. Older clients that don't send ?hour= fall
        // through unchanged, and the commit-time checks inside ReceiveAsync remain the
        // authoritative gate — preview is a convenience, never the enforcement.
        var closeOnlyPreview = false;
        if (hourOfDay is { } hr)
        {
            var window = await ReadWindowStateAsync(conn, transaction: null, withLock: false,
                                                    pullCtx, hr, ct);

            if (window.IsClosed)
                throw new BusinessException(
                    $"This line was already closed at hour {hr:D2}:00 and cannot accept further receipts.",
                    "LINE_ALREADY_CLOSED");

            if (varianceAccepted)
            {
                var windowCount = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
                    "SELECT COUNT(*) FROM dbo.PullItemWindows WHERE PullItemId = @PullItemId;",
                    new { PullItemId = pullItemId }, cancellationToken: ct));

                if (windowCount > 1)
                    throw new ValidationException(
                        $"This SKU is scheduled across {windowCount} hour windows. Accepting variance would close only " +
                        $"the {hr:D2}:00 slot, not the SKU, so it is not supported.",
                        "MULTI_WINDOW_NOT_SUPPORTED");
            }

            var outstanding = window.Outstanding;
            var variance    = varianceAccepted && qty != outstanding;

            // §2f (rev 11) — no lock check here either. Preview and confirm apply the
            // same rule, and that rule no longer consults LockHourCap.
            if (qty > outstanding && !variance)
                throw new ValidationException(
                    $"Receiving {qty} pcs exceeds the {outstanding} pcs outstanding at hour {hr:D2}:00. " +
                    $"Tick 'accept variance' to record the over-delivery and close the line.",
                    "OVER_RECEIPT_NOT_ACCEPTED");

            // §2d — a close-only confirm allocates nothing, so preview must not pretend it
            // will consume PO capacity (and must not fail when the PO is exhausted).
            closeOnlyPreview = qty == 0;
        }

        if (closeOnlyPreview)
            return new ReceivePreviewResult
            {
                Allocations      = new List<AllocationResult>(),
                TotalAllocatable = 0,
                Shortage         = 0,
                Scope            = pullCtx.LockPoByPull ? "pull-locked" : "warehouse-wide",
            };

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

    // v2.1 Phase 6.2 — enforce per-hour cap when pull.LockHourCap = true.
    // Reads the (PullItemId, HourOfDay) window row (optionally with UPDLOCK
    // for the Receive transaction), computes remaining capacity, and throws
    // BusinessException → 409 if the requested qty would push the window
    // over its ExpectedQty. Message format is the user-facing contract
    // — UI parses ProblemDetails.title to surface in the alloc panel.
    // db/047 §2f (rev 11) — EnforceHourCapAsync is GONE, not merely unused.
    //
    // It raised "Insufficient hour capacity … " (409, HOUR_CAP_EXCEEDED) whenever a
    // receive exceeded the window on a pull with LockHourCap = true. Over-receipt is now
    // governed solely by the accept-variance tick, on every pull, so there is nothing
    // left for it to decide. Leaving it in place as dead code would suggest the cap
    // still had teeth. `PullItemContext.LockHourCap` is still hydrated because the
    // column is part of the pull row the receive path already reads, but nothing on
    // this path consults it any more.

    // db/047 — single reader for the (PullItemId, HourOfDay) window. Lock step 3 of the
    // canonical order; pass withLock:true only from inside a transaction that has already
    // taken the Pulls lock.
    //
    // Outstanding is MAX(0, Expected - Received) per §5: an over-received window must never
    // surface a negative outstanding anywhere in the UI or in exports. Note the raw
    // subtraction CAN be negative — db/010 dropped CK_PIW_Caps, so the schema permits
    // ReceivedQty > ExpectedQty and has done since v2.
    private static async Task<WindowState> ReadWindowStateAsync(
        System.Data.IDbConnection conn,
        System.Data.IDbTransaction? transaction,
        bool withLock,
        PullItemContext pullCtx,
        byte hourOfDay,
        CancellationToken ct)
    {
        var hints = withLock ? "WITH (UPDLOCK, ROWLOCK)" : "";
        var sql = $@"
            SELECT Id, ExpectedQty, ReceivedQty, IsClosed, ClosedReason
            FROM   dbo.PullItemWindows {hints}
            WHERE  PullItemId = @PullItemId AND HourOfDay = @HourOfDay;";

        var window = await conn.QuerySingleOrDefaultAsync<WindowState>(new CommandDefinition(
            sql, new { pullCtx.PullItemId, HourOfDay = hourOfDay },
            transaction: transaction, cancellationToken: ct));

        if (window is null)
            throw new BusinessException(
                $"Hour {hourOfDay:D2}:00 has no planned window on item {pullCtx.ItemCode}. " +
                $"Add the window first (or pick a different hour).");

        return window;
    }

    // Builds the FIFO read query. SQL is fixed strings; the only branch is appended
    // when the pull is in lock=true mode (no user input flows into the string).
    //
    // A1 (db/033): in lock-by-pull mode the FIFO scope also accepts imported POs
    // whose denormalized PullExternalRef matches the current pull's PullNumber.
    // This lets a Phase 12 import join a live receive without ever creating a
    // Pulls row for that PRS_ID. Cross-table race (import-after-FIFO-walk) is
    // benign — the line-level UPDLOCK+HOLDLOCK still serializes actual qty
    // allocation; at worst the receiver retries on "Insufficient capacity".
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
            sql += " AND (po.PullId = @PullId OR po.PullExternalRef = @PullNumberStr)";

        sql += " ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;";

        return await conn.QueryAsync<PoLineAvailability>(new CommandDefinition(
            sql,
            new
            {
                pullCtx.WarehouseId,
                pullCtx.ItemCode,
                pullCtx.PullId,
                PullNumberStr = pullCtx.PullNumber,
            },
            transaction: transaction,
            cancellationToken: ct));
    }

    // ============================================================================
    // §7.2a / §3.5 atomic FIFO receive (lock-aware)
    //
    //   Same FIFO walk as Preview, but inside one transaction with
    //   UPDLOCK + HOLDLOCK + ROWLOCK on the PO-line read for serializable
    //   range protection (two concurrent receivers can't double-spend a line).
    //   Audit row captures the scope so the journal explains WHY a given
    //   allocation went where it did.
    // ============================================================================
    public async Task<ReceiveResult> ReceiveAsync(ReceiveRequest req, CancellationToken ct = default)
    {
        // ----- 0. Validation (shape only; anything needing the DB happens under lock) -----
        //
        // db/047 — the qty guard is now conditioned on VarianceAccepted, not on qty alone.
        // Qty = 0 with the flag set is the close-only path (§2d): it records that nothing
        // more is coming and closes the window. Without the flag, zero still means nothing
        // and is still refused — a zero-quantity partial records literally nothing.
        // Negative is always refused.
        if (req.Qty < 0)
            throw new ValidationException("Quantity cannot be negative");
        if (req.Qty == 0 && !req.VarianceAccepted)
            throw new ValidationException(
                "A zero quantity records nothing. Tick 'accept variance' to close the line short.",
                "ZERO_QTY_WITHOUT_VARIANCE");

        if (req.HourOfDay > 23)  throw new ValidationException("HourOfDay must be 0–23");

        // The note is the audit reason and is copied to PullItemWindows.ClosedReason, so it
        // is mandatory whenever variance is accepted (§6).
        if (req.VarianceAccepted && string.IsNullOrWhiteSpace(req.Note))
            throw new ValidationException(
                "A note is required when accepting variance — it is the audit reason.",
                "VARIANCE_REASON_REQUIRED");

        var qcStatus = req.QcStatus ?? "pending";
        if (!AllowedQcStatus.Contains(qcStatus))
            throw new ValidationException($"Invalid QcStatus '{qcStatus}'");

        var actorId   = CurrentUserId();
        var sessionWh = SessionWarehouseId();
        var isAdmin   = SessionIsAdmin();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // ----- 1. Lock the parent pull row + read its current status (incl. LockPoByPull + LockHourCap) -----
            var pullCtx = await conn.QuerySingleOrDefaultAsync<PullItemContext>(new CommandDefinition(@"
                SELECT pi.Id AS PullItemId, pi.ItemCode,
                       p.Id  AS PullId, p.PullNumber, p.Status AS PullStatus, p.WarehouseId,
                       p.LockPoByPull, p.LockHourCap
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

            // ----- 1b. Window state — lock step 3 of the canonical order. -----
            // Taken BEFORE the PO lines (step 4) and before any quantity decision, so a
            // concurrent receive cannot race past the outstanding figure we are about to
            // validate against.
            var window = await ReadWindowStateAsync(conn, transaction: tx, withLock: true,
                                                    pullCtx, req.HourOfDay, ct);

            // db/047 §5 — a closed window is read-only. Checked before anything else that
            // could mutate, so a late arrival against a line someone already closed is
            // refused rather than silently appended.
            if (window.IsClosed)
                throw new BusinessException(
                    $"This line was already closed at hour {req.HourOfDay:D2}:00 and cannot accept further receipts.",
                    "LINE_ALREADY_CLOSED");

            // db/047 §2c — the accept-variance guard. Closing one hour slot does not close
            // the SKU, so variance is offered only when the item has exactly one window.
            // Enforced here as well as in the UI: the UI hides the checkbox, but a crafted
            // request must still be refused. Logged at warning because on real ERP data this
            // has never fired — 2,049 upstream items across 20 hours were all single-window —
            // so if it ever does, we want to learn it from a log rather than a wrong number.
            if (req.VarianceAccepted)
            {
                var windowCount = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
                    "SELECT COUNT(*) FROM dbo.PullItemWindows WHERE PullItemId = @PullItemId;",
                    new { req.PullItemId }, transaction: tx, cancellationToken: ct));

                if (windowCount > 1)
                {
                    _logger.LogWarning(
                        "Accept-variance refused: PullItem {PullItemId} ({ItemCode}) on pull {PullNumber} has {WindowCount} windows. " +
                        "Multi-window variance is not supported (db/047 §2c guard).",
                        req.PullItemId, pullCtx.ItemCode, pullCtx.PullNumber, windowCount);

                    throw new ValidationException(
                        $"This SKU is scheduled across {windowCount} hour windows. Accepting variance would close only " +
                        $"the {req.HourOfDay:D2}:00 slot, not the SKU, so it is not supported.",
                        "MULTI_WINDOW_NOT_SUPPORTED");
                }
            }

            var outstanding = window.Outstanding;   // MAX(0, Expected - Received) — never negative

            // §6 — the flag is IGNORED on an exact completion: the line closes through the
            // existing full-receipt path and VarianceAccepted persists as 0. There is no
            // variance to record when the quantity lands exactly on outstanding.
            var variance = req.VarianceAccepted && req.Qty != outstanding;

            // §2f (rev 11) — THE TICK IS THE ESCAPE, ON EVERY PULL. LockHourCap no longer
            // changes the outcome of a receive; the hour-cap refusal that used to sit here
            // is gone.
            //
            // The rule it replaces treated the lock as absolute, on the reasoning that a
            // tick must not bypass a deliberately-set cap. That rested on an assumption
            // that was never true: 11,588 of the 11,594 open pulls with outstanding work
            // are locked, ErpUpsertService.cs:189 writes a hardcoded 1, and nobody has ever
            // chosen the value per pull. A flag true on every row is a constant, not a
            // control, and honouring it made the over-receipt path unreachable on live
            // data — correct in theory and never once in practice.
            //
            // Unlocking everything instead would let over-receipt happen silently, which is
            // the clamp defect inverted. Requiring the tick keeps every over-receipt
            // deliberate and attributable, which is worth more than the cap was.

            // §6 — over-receipt is terminal and has only one reading, so the tick is
            // mandatory. Under-receipt is ambiguous and stays optional, which is why there
            // is deliberately no matching guard below outstanding.
            if (req.Qty > outstanding && !variance)
                throw new ValidationException(
                    $"Receiving {req.Qty} pcs exceeds the {outstanding} pcs outstanding at hour {req.HourOfDay:D2}:00. " +
                    $"Tick 'accept variance' to record the over-delivery and close the line.",
                    "OVER_RECEIPT_NOT_ACCEPTED");

            // Signed variance measured against outstanding AT THIS MOMENT, never against
            // Expected (§6 worked examples). Because every preceding partial reduced
            // outstanding exactly, this equals TotalReceived - Expected for the line.
            int? varianceQty = variance ? req.Qty - outstanding : null;

            // §2d — a zero-quantity close writes NO Receipts row: the ledger's "a row means
            // goods moved" invariant is not weakened, and CK_Receipts_QtyNonZero stays intact.
            // The audit record is the window's ClosedBy/ClosedAt/ClosedReason.
            var closeOnly = req.Qty == 0;

            // ----- 2. Lock all candidate PO lines — FIFO order (lock-aware via pullCtx.LockPoByPull) -----
            // UPDLOCK + HOLDLOCK gives serializable range protection for the FIFO query.
            // db/047 §2d — the close-only path moves no goods, so it consumes no PO capacity
            // and takes no PO-line locks. Skipping the walk entirely also means a short close
            // still works when the PO is exhausted or absent, which is exactly when an
            // operator needs it.
            var plan = new List<(PoLineAvailability Line, int Take)>();

            if (!closeOnly)
            {
                var openLines = (await ReadOpenPoLinesAsync(conn, transaction: tx, withLocks: true,
                                                           pullCtx, ct)).AsList();

                // §3.5 strict mode: pull is locked but no PO is linked → procurement must act
                if (pullCtx.LockPoByPull && openLines.Count == 0)
                    throw new BusinessException(
                        "No PO linked to this pull. Procurement must link a PO before receiving.");

                var totalAvailable = openLines.Sum(l => l.OrderedQty - l.ReceivedQty);
                if (totalAvailable < req.Qty)
                    throw new BusinessException(
                        $"Insufficient PO capacity. Need {req.Qty}, have {totalAvailable} pcs.");

                // ----- 3. Build the allocation plan (FIFO walk) -----
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
            }

            // ----- 4. Insert one Receipts row per allocation slice + update PO line cache -----
            //
            // db/047 §2c — VarianceAccepted goes on EVERY row this confirm writes, but
            // VarianceQty on EXACTLY ONE (the first slice). A single confirm can split
            // across several PO lines; stamping the variance on each would multiply it by
            // the slice count and make SUM(VarianceQty) over the line wrong. Reversing ANY
            // of these rows clears IsClosed, which is why the flag — not the quantity — is
            // what every row carries.
            var allocations = new List<AllocationResult>(plan.Count);
            var varianceStamped = false;
            foreach (var (line, take) in plan)
            {
                int? sliceVarianceQty = null;
                if (variance && !varianceStamped)
                {
                    sliceVarianceQty = varianceQty;
                    varianceStamped  = true;
                }

                var receiptId = await conn.QuerySingleAsync<Guid>(new CommandDefinition(@"
                    INSERT INTO dbo.Receipts
                        (PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived,
                         LotBatch, PalletId, BinLocation, QcStatus, Note, ReceivedBy,
                         VarianceAccepted, VarianceQty)
                    OUTPUT INSERTED.Id
                    VALUES (@PullItemId, @PoId, @PoLineId, @HourOfDay, @Qty,
                            @LotBatch, @PalletId, @BinLocation, @QcStatus, @Note, @ReceivedBy,
                            @VarianceAccepted, @VarianceQty);",
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
                        VarianceAccepted = variance,
                        VarianceQty      = sliceVarianceQty,
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
            // §2d — the close-only path moves no goods, so ReceivedQty is not touched.
            if (!closeOnly)
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    UPDATE dbo.PullItemWindows
                       SET ReceivedQty = ReceivedQty + @Qty
                     WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                    new { Qty = req.Qty, req.PullItemId, req.HourOfDay },
                    transaction: tx, cancellationToken: ct));
            }

            // ----- 6b. Close the window when variance was accepted (db/047 §5) -----
            //
            // Conditional update, never read-then-write: two operators can have the modal
            // open on the same SKU at once, and `AND IsClosed = 0` is the only thing that
            // makes "once per line" actually true rather than merely likely. A rowcount of
            // 0 means somebody closed it between our read at step 1b and here, so the whole
            // transaction — including the receipt rows inserted above — rolls back and the
            // caller gets 409. One without the other is meaningless.
            if (variance)
            {
                var closed = await conn.ExecuteAsync(new CommandDefinition(@"
                    UPDATE dbo.PullItemWindows
                       SET IsClosed     = 1,
                           ClosedAt     = SYSUTCDATETIME(),
                           ClosedBy     = @ClosedBy,
                           ClosedReason = @ClosedReason
                     WHERE PullItemId = @PullItemId
                       AND HourOfDay  = @HourOfDay
                       AND IsClosed   = 0;",
                    new
                    {
                        req.PullItemId,
                        req.HourOfDay,
                        ClosedBy     = actorId,
                        ClosedReason = req.Note,
                    }, transaction: tx, cancellationToken: ct));

                if (closed == 0)
                    throw new BusinessException(
                        "This line was closed by another user while you were entering the receipt. " +
                        "Reload to see the current state.",
                        "LINE_ALREADY_CLOSED");
            }

            // ----- 7. Update Pulls timing + forward status transitions -----
            // CASE order: NOT EXISTS (no outstanding windows) wins first, so a
            // receive that both creates the first receipt AND fills the last
            // window jumps pending → fully_received in one shot rather than
            // getting stuck at in_progress (the bug Pull 0000009383 surfaced).
            // The cancel reverse path at line 527 handles the symmetric
            // fully_received → in_progress demotion when a receipt undoes a
            // window. UPDLOCK on this Pulls row was taken at line 228 of
            // ReceiveAsync, so the NOT EXISTS subquery sees a consistent
            // window-receipt picture for the duration of the transaction.
            await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.Pulls
                   SET LastActivityAt = SYSUTCDATETIME(),
                       FirstReceiptAt = ISNULL(FirstReceiptAt, SYSUTCDATETIME()),
                       Status         = CASE
                           WHEN Status IN ('pending', 'in_progress')
                                AND NOT EXISTS (
                                    SELECT 1
                                    FROM   dbo.PullItems pi
                                    INNER JOIN dbo.PullItemWindows piw
                                            ON piw.PullItemId = pi.Id
                                    WHERE  pi.PullId = @PullId
                                      AND  pi.Status <> 'canceled'
                                      AND  piw.IsClosed = 0   -- db/047 §2c query 2
                                      AND  piw.ExpectedQty > piw.ReceivedQty
                                )
                                THEN 'fully_received'
                           WHEN Status = 'pending' THEN 'in_progress'
                           ELSE Status
                       END
                 WHERE Id = @PullId;",
                new { pullCtx.PullId }, transaction: tx, cancellationToken: ct));

            // ----- 8. Audit (one summary row, with §3.5 scope label) -----
            var summary  = string.Join(" + ", plan.Select(p => $"{p.Take}@{p.Line.PoNumber}"));
            var scopeLbl = pullCtx.LockPoByPull ? "pull-locked" : "warehouse-wide FIFO";
            await _audit.WriteAsync(conn, tx, "receive", "Receipt", $"pi={req.PullItemId}",
                $"Received {req.Qty} pcs of {pullCtx.ItemCode} at hour {req.HourOfDay}. Scope: {scopeLbl}. Allocated: {summary}", ct);

            // ----- 9. Compute response fields before commit -----
            // db/047 §6 — the caller gets the recomputed outstanding and the window's
            // IsClosed state so it can update without a refetch.
            var post = await conn.QuerySingleAsync<WindowState>(new CommandDefinition(@"
                SELECT Id, ExpectedQty, ReceivedQty, IsClosed FROM dbo.PullItemWindows
                WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                new { req.PullItemId, req.HourOfDay }, transaction: tx, cancellationToken: ct));

            var newWindowQty = post.ReceivedQty;

            var outstandingWindows = await conn.QuerySingleAsync<int>(new CommandDefinition(@"
                SELECT COUNT(*) FROM dbo.PullItems pi
                INNER JOIN dbo.PullItemWindows piw ON piw.PullItemId = pi.Id
                WHERE pi.PullId = @PullId
                  AND pi.Status <> 'canceled'
                  AND piw.IsClosed = 0   -- db/047 §2c query 3
                  AND piw.ExpectedQty > piw.ReceivedQty;",
                new { pullCtx.PullId }, transaction: tx, cancellationToken: ct));

            // ----- 9b. If THIS receive flipped the pull to fully_received,
            //          emit a transition audit row. pullCtx.PullStatus captured
            //          BEFORE the UPDATE (loaded at lines 224-232 / line 50 of
            //          PreviewAsync's context query is the same shape); count
            //          + prior-state guard avoids double-emitting on later
            //          receives that no-op the status (forbidden by the
            //          capacity check at line 264, but belt-and-braces). -----
            if (outstandingWindows == 0
                && (pullCtx.PullStatus == "pending" || pullCtx.PullStatus == "in_progress"))
            {
                await _audit.WriteAsync(conn, tx,
                    "pull-fully-received", "Pull", pullCtx.PullId.ToString(),
                    $"Pull {pullCtx.PullNumber} reached fully_received — all windows filled (transitioned from {pullCtx.PullStatus})", ct);
            }

            tx.Commit();

            return new ReceiveResult
            {
                Allocations    = allocations,
                TotalQty       = req.Qty,
                NewReceivedQty = newWindowQty,
                FullyReceived  = outstandingWindows == 0,
                NewOutstanding = post.Outstanding,   // MAX(0, …) — never negative even on over-receipt
                IsClosed       = post.IsClosed,
                VarianceQty    = varianceQty,
            };
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ============================================================================
    // db/047 §2d — reopen a closed window
    //
    // A zero-quantity close writes no Receipts row, so there is nothing to reverse and
    // without this the line would be closed permanently with no route back. Kept
    // deliberately minimal: one endpoint, one reason box, no bulk reopen, no reopen from
    // list views. Re-closing is just an ordinary variance receipt.
    //
    // LOCK ORDER (canonical, see the class summary): Pulls → PullItemWindows. It touches
    // neither Receipts nor PurchaseOrderLines — the quantities are untouched, only the
    // close flags — so it takes steps 2 and 3 and stops.
    // ============================================================================
    public async Task<ReopenWindowResult> ReopenWindowAsync(ReopenWindowRequest req, CancellationToken ct = default)
    {
        var reason = (req.Reason ?? "").Trim();
        if (reason.Length == 0)
            throw new ValidationException(
                "A reason is required to reopen a line — reopening is a correction and must be attributable.",
                "REOPEN_REASON_REQUIRED");
        if (req.HourOfDay > 23) throw new ValidationException("HourOfDay must be 0–23");

        var actorId   = CurrentUserId();
        var sessionWh = SessionWarehouseId();
        var isAdmin   = SessionIsAdmin();

        using var conn = _factory.Create();
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            // ----- 1. Lock the parent pull (canonical step 2) -----
            var pullCtx = await conn.QuerySingleOrDefaultAsync<PullItemContext>(new CommandDefinition(@"
                SELECT pi.Id AS PullItemId, pi.ItemCode,
                       p.Id  AS PullId, p.PullNumber, p.Status AS PullStatus, p.WarehouseId,
                       p.LockPoByPull, p.LockHourCap
                FROM   dbo.Pulls p WITH (UPDLOCK, ROWLOCK)
                INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id
                WHERE  pi.Id = @PullItemId;",
                new { req.PullItemId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Pull item not found");

            // §7.12 — a closed pull is read-only. Reopening a window inside one would put
            // the pull back into a state its close gate has already signed off on.
            if (string.Equals(pullCtx.PullStatus, "closed", StringComparison.Ordinal))
                throw new BusinessException(
                    "Pull is closed. Reopen the pull before reopening a line within it.",
                    "PULL_CLOSED");

            // Same warehouse rule as CancelAsync.
            if (!isAdmin && sessionWh != pullCtx.WarehouseId)
                throw new ForbiddenException("You do not have access to this pull");

            // ----- 2. Window (canonical step 3). Read first so a missing window is a clean
            // 404 rather than an ambiguous 409 from the conditional update below. -----
            var window = await ReadWindowStateAsync(conn, transaction: tx, withLock: true,
                                                    pullCtx, req.HourOfDay, ct);

            // Conditional on IsClosed = 1, mirroring the close side's WHERE IsClosed = 0.
            // Rowcount 0 means it was not closed, or another operator reopened it between
            // the read above and here.
            var reopened = await conn.ExecuteAsync(new CommandDefinition(@"
                UPDATE dbo.PullItemWindows
                   SET IsClosed     = 0,
                       ClosedAt     = NULL,
                       ClosedBy     = NULL,
                       ClosedReason = NULL
                 WHERE PullItemId = @PullItemId
                   AND HourOfDay  = @HourOfDay
                   AND IsClosed   = 1;",
                new { req.PullItemId, req.HourOfDay },
                transaction: tx, cancellationToken: ct));

            if (reopened == 0)
                throw new BusinessException(
                    $"Hour {req.HourOfDay:D2}:00 on item {pullCtx.ItemCode} is not closed, so there is nothing to reopen.",
                    "LINE_NOT_CLOSED");

            // Carry the prior close reason into the audit line so the trail reads as a pair:
            // what it was closed for, and what it was reopened for.
            var priorReason = string.IsNullOrWhiteSpace(window.ClosedReason)
                ? "(no reason recorded)"
                : window.ClosedReason;

            await _audit.WriteAsync(conn, tx, "window-reopen", "PullItemWindow",
                $"pi={req.PullItemId};hour={req.HourOfDay}",
                $"Reopened hour {req.HourOfDay:D2}:00 on {pullCtx.ItemCode} (pull {pullCtx.PullNumber}). " +
                $"Reason: {reason}. Prior close reason: {priorReason}", ct);

            tx.Commit();

            return new ReopenWindowResult
            {
                PullItemId     = req.PullItemId,
                HourOfDay      = req.HourOfDay,
                IsClosed       = false,
                NewOutstanding = window.Outstanding,
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
    //
    // LOCK ORDER (canonical, see the class summary): Receipts → Pulls →
    // PullItemWindows → PurchaseOrderLines. db/047 moved the window lock ahead of the
    // PO-line lock; before that, cancel never locked the window at all and simply
    // blind-UPDATEd it, so the inversion against ReceiveAsync was invisible. Now that
    // cancel must also clear IsClosed, taking the window lock in the wrong order would
    // deadlock against a concurrent receive on the same SKU (regression test 15).
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
                       QcStatus, ReversedById, VarianceAccepted
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

            // ----- 2b. Lock the window — step 3 of the canonical order, BEFORE the PO line.
            // Cancel decrements this row at step 8 and (db/047) may clear IsClosed at 8b,
            // so it must hold the lock rather than blind-updating as it used to.
            await ReadWindowStateAsync(
                conn, transaction: tx, withLock: true,
                new PullItemContext { PullItemId = orig.PullItemId, ItemCode = pullCtx.ItemCode },
                orig.HourOfDay, ct);

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

            // ----- 8b. db/047 §2b — reversing a variance receipt reopens the window.
            //
            // If the receipt being reversed carried VarianceAccepted, the line was closed by
            // it. Undoing the quantity while leaving IsClosed set would strand the line:
            // permanently closed, with its closing quantity gone and no route back. This is
            // not "unclose as a feature" — it is the existing reversal path continuing to be
            // correct.
            //
            // Deliberately unconditional on which slice this is: one confirm can write
            // several rows and only one carries VarianceQty, so reversing ANY row with the
            // flag reopens. Reopening a line that did not strictly need reopening is
            // recoverable — the operator closes it again. Leaving it closed after part of
            // the closing quantity was reversed is not.
            if (orig.VarianceAccepted)
            {
                await conn.ExecuteAsync(new CommandDefinition(@"
                    UPDATE dbo.PullItemWindows
                       SET IsClosed     = 0,
                           ClosedAt     = NULL,
                           ClosedBy     = NULL,
                           ClosedReason = NULL
                     WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                    new { orig.PullItemId, orig.HourOfDay },
                    transaction: tx, cancellationToken: ct));
            }

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
        public bool LockPoByPull { get; set; }
        // v2.1 Phase 6 — Preview/Receive SELECTs hydrate this from Pulls.LockHourCap.
        // When true, receive 409s before the FIFO walk if qty would push the
        // (PullItemId, HourOfDay) window past its ExpectedQty.
        public bool LockHourCap { get; set; }
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

        /// <summary>db/047 — when true, reversing this row must reopen the parent window.</summary>
        public bool VarianceAccepted { get; set; }
    }

    // db/047 — supersedes the old WindowCapRow (Expected/Received only). Carries IsClosed
    // so the receive path can refuse a closed window, and exposes Outstanding as the single
    // MAX(0, ...) definition rather than letting each caller subtract for itself.
    private sealed class WindowState
    {
        public Guid Id { get; set; }
        public int ExpectedQty { get; set; }
        public int ReceivedQty { get; set; }
        public bool IsClosed { get; set; }
        public string? ClosedReason { get; set; }

        /// <summary>MAX(0, Expected - Received) — never negative (§5).</summary>
        public int Outstanding => Math.Max(0, ExpectedQty - ReceivedQty);
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
