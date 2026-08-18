using System.Security.Claims;
using Dapper;
using ReceivingOps.Web.Data;
using ReceivingOps.Web.Models;
using ReceivingOps.Web.Models.Dtos;

namespace ReceivingOps.Web.Services;

/// <summary>
/// §7.2 receive / §7.3 cancel.
///
/// CANONICAL LOCK ACQUISITION ORDER — db/047. Every write path in this class MUST
/// take locks in this order, and must not take a later lock before an earlier one:
///
///     1. dbo.Pulls                (UPDLOCK, ROWLOCK)
///     2. dbo.Receipts             (UPDLOCK, ROWLOCK)  — cancel only; receive inserts
///     3. dbo.PullItemWindows      (UPDLOCK, ROWLOCK)
///     4. dbo.PurchaseOrderLines   (UPDLOCK, HOLDLOCK, ROWLOCK)
///
/// Why it matters: before db/047, ReceiveAsync took PullItemWindows (via the hour-cap
/// check) BEFORE PurchaseOrderLines, while CancelAsync took PurchaseOrderLines first and
/// then blind-UPDATEd the window with no lock at all. That inversion was latent only
/// because cancel never locked the window. db/047 makes cancel lock the window — to clear
/// IsClosed — so without a single order the two paths would deadlock under concurrent
/// receive+cancel on the same SKU (brief §2c, regression test 15).
///
/// WHY Pulls MOVED AHEAD OF Receipts (variance-recompute change)
/// -------------------------------------------------------------
/// Cancel used to touch exactly one Receipts row, so locking that row before the pull was
/// harmless. Step 8c now rewrites VarianceQty on the OTHER live rows of the same window,
/// which makes sibling rows part of cancel's write set. With Receipts locked first, two
/// operators cancelling two slices of the same confirm deadlock outright: T1 holds slice 1
/// and needs slice 2 for 8c, T2 holds slice 2 and is queued behind T1 on the Pulls row.
/// Taking dbo.Pulls first makes that row the single serialization point for every receive
/// and every cancel on a pull, so the sibling rows cannot be held by anyone else by the
/// time 8c reaches them. Cancel therefore identifies its pull with an UNLOCKED read first
/// (Receipts.PullItemId and HourOfDay are immutable on an append-only ledger, so there is
/// nothing to race), then locks Pulls, then re-reads the target row under UPDLOCK — so the
/// already-voided guard is still evaluated against locked state.
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
            SELECT pi.Id AS PullItemId, pi.ItemCode, pi.VendorCode,
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

        // Overflow is gated on a real over-receipt, which is only knowable once an hour has
        // been supplied. Older clients that omit ?hour= therefore never widen — they fall
        // through to the unchanged narrow walk, and ReceiveAsync stays the authoritative gate.
        var previewVariance = false;

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
            previewVariance = variance;

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

        // §6.1 — preview must widen on exactly the same condition confirm does, or the
        // modal shows a failure the server would not have raised and the Confirm button
        // stays disabled on a receive that would have succeeded.
        var openLines = (await ReadOpenPoLinesAsync(conn, transaction: null, withLocks: false,
                                                    pullCtx,
                                                    varianceAccepted: previewVariance,
                                                    allowOverflow: previewVariance, ct)).AsList();

        if (pullCtx.LockPoByPull && openLines.Count == 0)
            throw new BusinessException(
                "No PO linked to this pull. Procurement must link a PO before receiving.");

        var totalAvailable = openLines.Sum(l => l.OrderedQty - l.ReceivedQty);
        if (totalAvailable < qty)
            throw new BusinessException(await BuildCapacityMessageAsync(
                conn, transaction: null, pullCtx, qty, totalAvailable, previewVariance, ct));

        var plan = BuildAllocationPlan(openLines, qty);

        return new ReceivePreviewResult
        {
            Allocations      = plan,
            TotalAllocatable = totalAvailable,
            Shortage         = 0,
            Scope            = ScopeLabel(pullCtx, plan.Any(a => !a.IsPullLinked), "warehouse-wide"),
        };
    }

    // §5.2 — the capacity refusal states a remedy, not just a fact. The old text
    // ("Insufficient PO capacity. Need 401, have 400 pcs.") was a dead end: true, and no
    // help. Which sentence the operator gets depends on whether widening is available to
    // them, so the message is composed from the mode rather than templated once.
    //
    // No PO numbers appear here. The allocation preview already shows them, but a refusal
    // is not an allocation and has no reason to name POs this pull is not linked to.
    private async Task<string> BuildCapacityMessageAsync(
        System.Data.IDbConnection conn,
        System.Data.IDbTransaction? transaction,
        PullItemContext pullCtx,
        int qty,
        int totalAvailable,
        bool variance,
        CancellationToken ct)
    {
        // Mode A is already warehouse-wide — there is nothing wider left to offer.
        if (!pullCtx.LockPoByPull)
            return $"Insufficient PO capacity. Need {qty}, have {totalAvailable} pcs.";

        if (variance)
            return $"Insufficient PO capacity. Need {qty} pcs; only {totalAvailable} pcs remain across all " +
                   $"open POs for this vendor and item at this warehouse. " +
                   $"Procurement must open or link another PO.";

        // Not ticked. Only advertise the tick when it would actually have covered the
        // quantity — pointing at a remedy that still fails is worse than the bare fact.
        // Error-message path: ask the same question the walk would ask, so the
        // advice offered matches what a retry would actually do.
        var msgVendorScoped = !string.IsNullOrWhiteSpace(pullCtx.VendorCode)
            && await AnyVendorMatchedLineAsync(conn, transaction, withLocks: false, pullCtx, ct);
        var anchor = await ReadPullVendorAnchorAsync(
            conn, transaction, withLocks: false, pullCtx, msgVendorScoped, ct);
        if (anchor is not null)
        {
            var wide = await ReadVendorWideAvailableAsync(conn, transaction, pullCtx, anchor, ct);
            if (wide >= qty)
                return $"The PO linked to this pull has {totalAvailable} pcs left, short of the {qty} pcs entered. " +
                       $"Tick 'accept variance' to draw the remaining {qty - totalAvailable} pcs from other " +
                       $"open POs for the same vendor.";
        }

        return $"Insufficient PO capacity. Need {qty}, have {totalAvailable} pcs.";
    }

    // Total open capacity for the anchored vendor across this item + warehouse.
    // Deliberately lock-free: it runs only on a refusal path, to compose an error string,
    // inside a transaction that is about to roll back.
    private static async Task<int> ReadVendorWideAvailableAsync(
        System.Data.IDbConnection conn,
        System.Data.IDbTransaction? transaction,
        PullItemContext pullCtx,
        string vendorAnchor,
        CancellationToken ct)
        => await conn.ExecuteScalarAsync<int>(new CommandDefinition(@"
            SELECT ISNULL(SUM(pol.OrderedQty - pol.ReceivedQty), 0)
            FROM   dbo.PurchaseOrderLines pol
            INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
            WHERE  po.WarehouseId = @WarehouseId
              AND  po.Status      = 'open'
              AND  pol.ItemCode   = @ItemCode
              AND  pol.OrderedQty > pol.ReceivedQty
              AND  pol.VendorCode = @VendorAnchor;",
            new
            {
                pullCtx.WarehouseId,
                pullCtx.ItemCode,
                VendorAnchor = vendorAnchor,
            },
            transaction: transaction,
            cancellationToken: ct));

    // §5.1 — three states, decided from the plan that was actually built and never from
    // the request flag. A 401-unit receive against a pull PO that happened to have 500
    // remaining is not an overflow, and labelling it as one would make the audit trail
    // lie in the direction of alarm.
    //
    // modeALabel differs by surface and that is deliberate: the audit message has always
    // read "warehouse-wide FIFO" while the preview's wire value has always read
    // "warehouse-wide". Both are asserted by existing smokes (phase-4b and phase-4a), so
    // the difference is preserved rather than tidied into one string.
    private static string ScopeLabel(PullItemContext pullCtx, bool overflowed, string modeALabel)
        => !pullCtx.LockPoByPull ? modeALabel
         : overflowed            ? "pull-locked + variance overflow"
         :                         "pull-locked";

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
                    IsPullLinked        = line.IsPullLinked,
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
    //
    // Variance overflow (§4.1): when the operator has ticked accept-variance, a
    // lock-by-pull receive may spill past the pull's own PO into other open PO lines
    // for the SAME vendor, item and warehouse — pull-linked lines first. The
    // over-delivered units already have purchase-order cover; it just sits on a
    // different line. This is a matching problem, not an unpurchased-goods problem,
    // so every unit still lands on a real PO line and CK_POL_Caps is never stressed.
    private static async Task<IEnumerable<PoLineAvailability>> ReadOpenPoLinesAsync(
        System.Data.IDbConnection conn,
        System.Data.IDbTransaction? transaction,
        bool withLocks,
        PullItemContext pullCtx,
        bool varianceAccepted,
        bool allowOverflow,
        CancellationToken ct)
    {
        // §4.1 — allowOverflow may never outrun the operator's tick. A caller that widens
        // the PO scope without variance accepted is a programming error, not a user error:
        // fail loudly here rather than quietly draw on another pull's PO in production.
        if (allowOverflow && !varianceAccepted)
            throw new InvalidOperationException(
                "ReadOpenPoLinesAsync: allowOverflow requires varianceAccepted. " +
                "Overflow is gated on the operator's tick (§4.1).");

        const string pullMatch = "(po.PullId = @PullId OR po.PullExternalRef = @PullNumberStr)";

        // Storer grain — the second half of the fix, and the half that
        // actually stops the liability landing on the wrong supplier.
        //
        // Graining pull items by (ItemCode, VendorCode) stops the ERP merging
        // two storers into one row, but on its own it changes nothing here:
        // this walk matched on ItemCode alone, so receiving against COI-5732's
        // item would still consume whichever line sorted first — including
        // COI-84600's. Measured on one day's export: 107 (pull, SKU) pairs
        // span two storers, 2,500,523 units, and the two storers have
        // SEPARATE purchase orders. Tidier rows with the same mis-allocation
        // would look like a fix and not be one.
        //
        // Applied ONLY when the pull item carries a vendor AND that vendor
        // actually has a candidate line. Both halves are load-bearing.
        //
        // A NULL VendorCode means a historical merged row (§4.3 "left alone"
        // data) or a hand-created item; those keep today's behaviour exactly.
        //
        // The second half was found the hard way. A hard vendor filter looked
        // safe on the measurement "items whose only open lines carry a NULL
        // vendor" — zero rows. That was the wrong question. The population that
        // breaks is items whose lines carry a DIFFERENT non-null vendor:
        // measured 593 open pull items on the dev DB, real ERP storer codes
        // (HSABP3, 90179, 84380), where the pull's storer has no line of its
        // own but other storers' lines exist. Filtering those to nothing turns
        // "receive it against the pool, as today" into "Insufficient PO
        // capacity. Need 500, have 0" — making live items unreceivable, which
        // is the opposite of leaving historical data alone. smoke-phase-4a
        // caught it.
        //
        // So: when the item's storer HAS a line, scope hard to it — no leakage,
        // including on the overflow path. When it has none, fall back to the
        // pre-change behaviour and walk the whole SKU pool. The mis-allocation
        // this exists to stop is "two storers each with their own PO"; an item
        // whose storer has no PO at all was never that case.
        var vendorScoped = false;
        if (!string.IsNullOrWhiteSpace(pullCtx.VendorCode))
        {
            vendorScoped = await AnyVendorMatchedLineAsync(
                conn, transaction, withLocks, pullCtx, ct);
        }

        // Overflow only means anything inside lock-by-pull mode. Mode A is already
        // warehouse-wide, and adding a vendor filter there would be a behaviour change
        // nobody asked for (§4.1).
        var overflow = allowOverflow && pullCtx.LockPoByPull;

        string? vendorAnchor = null;
        if (overflow)
        {
            vendorAnchor = await ReadPullVendorAnchorAsync(conn, transaction, withLocks, pullCtx, vendorScoped, ct);

            // No anchor means no pull-linked line to take a vendor from. Do NOT widen on a
            // guess: fall back to today's narrow scope so the caller raises the existing
            // "No PO linked to this pull" error rather than silently draining the warehouse.
            if (vendorAnchor is null) overflow = false;
        }

        var hints = withLocks ? "WITH (UPDLOCK, HOLDLOCK, ROWLOCK)" : "";
        var sql = $@"
            SELECT pol.Id AS PurchaseOrderLineId, pol.PurchaseOrderId, po.PoNumber, po.OrderDate,
                   pol.LineNumber, pol.OrderedQty, pol.ReceivedQty,
                   CAST(CASE WHEN {pullMatch} THEN 1 ELSE 0 END AS BIT) AS IsPullLinked
            FROM   dbo.PurchaseOrderLines pol {hints}
            INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
            WHERE  po.WarehouseId = @WarehouseId
              AND  po.Status      = 'open'
              AND  pol.ItemCode   = @ItemCode
              AND  pol.OrderedQty > pol.ReceivedQty";

        // Storer scope, in BOTH lock modes: a warehouse-wide pull mis-attributing
        // stock across storers is the same defect as a pull-locked one.
        // Skipped entirely when the item has no vendor (see above).
        if (vendorScoped) sql += $" AND {VendorMatchSql("pol.VendorCode", "@ItemVendorCode")}";

        // The row-restricting predicate stays INSIDE the locked scan on both paths. On the
        // normal path that keeps the UPDLOCK+HOLDLOCK range exactly as narrow as it is
        // today (§4.2); filtering after the fact would lock the whole warehouse pool to
        // return one line.
        var tier = "";
        if (pullCtx.LockPoByPull)
        {
            if (overflow)
            {
                sql += " AND pol.VendorCode = @VendorAnchor";
                tier  = $"CASE WHEN {pullMatch} THEN 0 ELSE 1 END, ";
            }
            else
            {
                sql += $" AND {pullMatch}";
            }
        }

        sql += $" ORDER BY {tier}po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;";

        return await conn.QueryAsync<PoLineAvailability>(new CommandDefinition(
            sql,
            new
            {
                pullCtx.WarehouseId,
                pullCtx.ItemCode,
                pullCtx.PullId,
                PullNumberStr = pullCtx.PullNumber,
                VendorAnchor  = vendorAnchor,
                ItemVendorCode = pullCtx.VendorCode,
            },
            transaction: transaction,
            cancellationToken: ct));
    }

    /// <summary>
    /// Does this pull item's storer have any candidate PO line of its own?
    ///
    /// <para>Decides whether the vendor filter applies at all. When the answer
    /// is yes, the walk is scoped hard to that storer and cannot leak onto
    /// another supplier's purchase order. When it is no — the item's storer has
    /// no line here, but other storers' lines exist for the same SKU — the
    /// filter is skipped entirely and the walk behaves exactly as it did before
    /// storer grain. 593 open pull items on the dev DB are in that second
    /// bucket; filtering them to nothing made them unreceivable.</para>
    ///
    /// <para>Scope mirrors the main walk's, including the lock-by-pull
    /// restriction, and takes the same hints so the answer cannot shift
    /// underneath the read that follows.</para>
    /// </summary>
    private static async Task<bool> AnyVendorMatchedLineAsync(
        System.Data.IDbConnection conn,
        System.Data.IDbTransaction? transaction,
        bool withLocks,
        PullItemContext pullCtx,
        CancellationToken ct)
    {
        var hints = withLocks ? "WITH (UPDLOCK, HOLDLOCK, ROWLOCK)" : "";
        var pullTerm = pullCtx.LockPoByPull
            ? " AND (po.PullId = @PullId OR po.PullExternalRef = @PullNumberStr)"
            : "";

        var hit = await conn.ExecuteScalarAsync<int?>(new CommandDefinition($@"
            SELECT TOP 1 1
            FROM   dbo.PurchaseOrderLines pol {hints}
            INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
            WHERE  po.WarehouseId = @WarehouseId
              AND  po.Status      = 'open'
              AND  pol.ItemCode   = @ItemCode
              AND  pol.OrderedQty > pol.ReceivedQty{pullTerm}
              AND  {VendorMatchSql("pol.VendorCode", "@ItemVendorCode")};",
            new
            {
                pullCtx.WarehouseId,
                pullCtx.ItemCode,
                pullCtx.PullId,
                PullNumberStr = pullCtx.PullNumber,
                ItemVendorCode = pullCtx.VendorCode,
            },
            transaction: transaction, cancellationToken: ct));

        return hit.HasValue;
    }

    /// <summary>
    /// Cross-format vendor match. <c>PurchaseOrderLines.VendorCode</c> holds the
    /// PREFIXED ERP code (<c>COI-5732</c>); <c>PullItems.VendorCode</c> holds the
    /// STRIPPED form (<c>5732</c>) written from <c>BPI_PRS.VENDOR</c> verbatim.
    ///
    /// <para>Written the obvious way — <c>pol.VendorCode = @V</c> — this matches
    /// ZERO rows and fails silently: the operator sees "no capacity anywhere"
    /// while the code looks like it works. That near-miss has already happened
    /// twice on this codebase, which is why the comparison is centralised here
    /// instead of transcribed at each site.</para>
    ///
    /// <para>Matches exact, or prefixed-with-a-hyphen. No assumption about
    /// prefix length beyond the separator, so <c>COI-</c> and <c>WDT-</c> both
    /// work and a stripped value that itself contains a hyphen
    /// (<c>V-FORTIS</c>) still matches itself exactly. Both operands are
    /// parameters — the caller passes column and parameter NAMES, never
    /// values.</para>
    /// </summary>
    private static string VendorMatchSql(string poLineColumn, string param) => $@"(
                   {poLineColumn} = {param}
                   OR (RIGHT({poLineColumn}, LEN({param})) = {param}
                       AND SUBSTRING({poLineColumn}, LEN({poLineColumn}) - LEN({param}), 1) = '-')
              )";

    // §4.1 — the vendor the pull is actually transacting with, taken from the pull-linked
    // PO line(s) themselves.
    //
    // PullItems.VendorCode is deliberately NOT a fallback. The two columns hold different
    // formats on live data: PurchaseOrderLines carries the prefixed ERP code ('COI-HSABP1',
    // 14,554 of 14,623 non-null rows) while PullItems carries the bare form ('HSABP1', 0 of
    // 47,813 prefixed). Anchoring on PullItems would compare the two and match nothing —
    // widening to an empty set, which reads to the operator as "no capacity anywhere" while
    // looking like a working feature from the code. The divergence is left as-is; reconciling
    // the two encodings is an ERP-semantics question, not something to guess at here.
    //
    // Read under the same hints as the main walk when locking, so the anchor rows are held
    // from here on and cannot shift beneath the widened read that follows.
    private static async Task<string?> ReadPullVendorAnchorAsync(
        System.Data.IDbConnection conn,
        System.Data.IDbTransaction? transaction,
        bool withLocks,
        PullItemContext pullCtx,
        bool vendorScoped,
        CancellationToken ct)
    {
        var hints = withLocks ? "WITH (UPDLOCK, HOLDLOCK, ROWLOCK)" : "";

        // Storer grain — the anchor has to belong to the item's own storer.
        // Without this, a pull carrying the same SKU from two storers picks
        // whichever line sorts first as the anchor, and overflow then widens
        // to the WRONG supplier's other POs — turning a mis-allocation inside
        // one pull into a mis-allocation across the warehouse. Same NULL rule
        // as the main walk: no vendor on the item, no extra term.
        // Same fallback rule as the main walk: only scope the anchor when the
        // item's storer actually has a line here. Otherwise this is one of the
        // 593 fallback items and the pre-change anchor behaviour applies.
        var vendorTerm = vendorScoped
            ? $" AND {VendorMatchSql("pol.VendorCode", "@ItemVendorCode")}"
            : "";

        return await conn.ExecuteScalarAsync<string?>(new CommandDefinition($@"
            SELECT TOP 1 pol.VendorCode
            FROM   dbo.PurchaseOrderLines pol {hints}
            INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
            WHERE  po.WarehouseId = @WarehouseId
              AND  po.Status      = 'open'
              AND  pol.ItemCode   = @ItemCode
              AND  pol.OrderedQty > pol.ReceivedQty
              AND  (po.PullId = @PullId OR po.PullExternalRef = @PullNumberStr)
              AND  pol.VendorCode IS NOT NULL{vendorTerm}
            ORDER BY po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;",
            new
            {
                pullCtx.WarehouseId,
                pullCtx.ItemCode,
                pullCtx.PullId,
                PullNumberStr = pullCtx.PullNumber,
                ItemVendorCode = pullCtx.VendorCode,
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

        // db/049 — the audit reason is now the REASON CODE, not the note.
        //
        // What used to be here: "VarianceAccepted with a blank Note" → refuse. That rule
        // required prose on a path that fires constantly (over-delivery happens on nearly
        // every pull at this site), so in production it converted into a required keystroke
        // and the first real use recorded ".". A required field that can be satisfied
        // without saying anything is not a control.
        //
        // The replacement is NOT a second check layered on that one: the note requirement
        // moves to OTHER only, and a required code takes its place. Both live below, after
        // `outstanding` is known — required-ness depends on whether a variance is actually
        // being accepted, which depends on the quantity. Only the shape check that needs no
        // database is done here: a code that is not in the set is malformed regardless of
        // quantity, and saying so early gives a clearer error than "invalid for direction".
        if (req.VarianceReasonCode is not null && !VarianceReasonCodes.IsKnown(req.VarianceReasonCode))
            throw new ValidationException(
                $"Unknown variance reason code '{req.VarianceReasonCode}'.",
                "VARIANCE_REASON_UNKNOWN");

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
                SELECT pi.Id AS PullItemId, pi.ItemCode, pi.VendorCode,
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

            // db/049 §4.2 — reason validation, now that we know whether this IS a variance.
            //
            // Gated on `variance`, not on req.VarianceAccepted: an exact-quantity final
            // receipt closes through the ordinary full-receipt path and is not a variance,
            // so it must not demand a reason (§4.1). A code sent with one is ignored, not
            // rejected — the request is well-formed, the field simply does not apply.
            //
            // Server-side is authoritative (BUILD_PROMPT §7). The client hides invalid
            // options and gates Confirm, but a crafted request must be refused here.
            string? reasonCode = null;
            if (variance)
            {
                var direction = req.Qty > outstanding
                    ? VarianceDirection.Over
                    : VarianceDirection.Short;          // includes qty = 0, the zero-close

                if (string.IsNullOrWhiteSpace(req.VarianceReasonCode))
                    throw new ValidationException(
                        "A reason is required when accepting variance. Valid codes for this " +
                        $"{(direction == VarianceDirection.Over ? "over-receipt" : "short close")}: " +
                        $"{VarianceReasonCodes.ValidCodesFor(direction)}.",
                        "VARIANCE_REASON_REQUIRED");

                // Known (checked at step 0) but wrong way round — e.g. OVER_DELIVERY on a
                // short close. Named explicitly so the caller can tell this from a typo.
                if (!VarianceReasonCodes.IsValidFor(req.VarianceReasonCode, direction))
                    throw new ValidationException(
                        $"Reason '{req.VarianceReasonCode}' is not valid for a " +
                        $"{(direction == VarianceDirection.Over ? "over-receipt" : "short close")}. " +
                        $"Valid codes: {VarianceReasonCodes.ValidCodesFor(direction)}.",
                        "VARIANCE_REASON_WRONG_DIRECTION");

                // OTHER is the only code that still demands prose — it is the one that says
                // nothing on its own. The floor rejects "." and "-" without frustrating a
                // terse but real answer; whitespace-only fails it too, since we trim first.
                if (string.Equals(req.VarianceReasonCode, VarianceReasonCodes.Other, StringComparison.Ordinal)
                    && (req.Note ?? "").Trim().Length < VarianceReasonCodes.MinNoteLength)
                    throw new ValidationException(
                        $"'{VarianceReasonCodes.Other}' requires a note of at least " +
                        $"{VarianceReasonCodes.MinNoteLength} characters describing what happened. " +
                        "Pick a specific reason instead if one fits.",
                        "VARIANCE_NOTE_REQUIRED");

                reasonCode = req.VarianceReasonCode;
            }

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
                // §4.1/§4.2 — the widened UPDLOCK+HOLDLOCK range (up to every open line for
                // this vendor+item+warehouse) is taken ONLY on the variance path, which is
                // operator-initiated and rare per unit time. The normal path's lock footprint
                // is unchanged.
                var openLines = (await ReadOpenPoLinesAsync(conn, transaction: tx, withLocks: true,
                                                           pullCtx,
                                                           varianceAccepted: variance,
                                                           allowOverflow: variance, ct)).AsList();

                // §3.5 strict mode: pull is locked but no PO is linked → procurement must act
                if (pullCtx.LockPoByPull && openLines.Count == 0)
                    throw new BusinessException(
                        "No PO linked to this pull. Procurement must link a PO before receiving.");

                var totalAvailable = openLines.Sum(l => l.OrderedQty - l.ReceivedQty);
                if (totalAvailable < req.Qty)
                    throw new BusinessException(await BuildCapacityMessageAsync(
                        conn, tx, pullCtx, req.Qty, totalAvailable, variance, ct));

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
                    IsPullLinked        = line.IsPullLinked,
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
                       SET IsClosed           = 1,
                           ClosedAt           = SYSUTCDATETIME(),
                           ClosedBy           = @ClosedBy,
                           ClosedReason       = @ClosedReason,
                           VarianceReasonCode = @VarianceReasonCode   -- db/049
                     WHERE PullItemId = @PullItemId
                       AND HourOfDay  = @HourOfDay
                       AND IsClosed   = 0;",
                    new
                    {
                        req.PullItemId,
                        req.HourOfDay,
                        ClosedBy     = actorId,
                        // Free text still stored verbatim; db/049 makes it optional, not gone.
                        ClosedReason = req.Note,
                        VarianceReasonCode = reasonCode,
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
            var scopeLbl = ScopeLabel(pullCtx, plan.Any(p => !p.Line.IsPullLinked), "warehouse-wide FIFO");

            // db/049 §5 — record the CODE, and that a note exists, not the note itself. The
            // note is already stored verbatim on the window's ClosedReason; pasting it here
            // would duplicate free text into a line meant to be skimmed, and a long one
            // would bury the quantities. The code is what a human reading the trail can act
            // on, and what a later report will group by.
            var reasonLbl = reasonCode is null
                ? ""
                : $" Reason: {reasonCode}{(string.IsNullOrWhiteSpace(req.Note) ? "" : " (note recorded)")}.";

            await _audit.WriteAsync(conn, tx, "receive", "Receipt", $"pi={req.PullItemId}",
                $"Received {req.Qty} pcs of {pullCtx.ItemCode} at hour {req.HourOfDay}. Scope: {scopeLbl}. Allocated: {summary}.{reasonLbl}", ct);

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
                SELECT pi.Id AS PullItemId, pi.ItemCode, pi.VendorCode,
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
                   SET IsClosed           = 0,
                       ClosedAt           = NULL,
                       ClosedBy           = NULL,
                       ClosedReason       = NULL,
                       VarianceReasonCode = NULL   -- db/049 §4.4: an explicit reopen clears
                 WHERE PullItemId = @PullItemId    -- the decision for the same reason cancel
                   AND HourOfDay  = @HourOfDay     -- does — the window no longer holds it.
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
            // ----- 0. Identify the pull WITHOUT locking (see the class summary).
            // PullItemId and HourOfDay never change on a Receipts row — the table is
            // append-only apart from ReversedById — so this read cannot go stale in a way
            // that matters. Everything it decides is re-read under lock below.
            var ident = await conn.QuerySingleOrDefaultAsync<ReceiptIdentity>(new CommandDefinition(
                "SELECT PullItemId, HourOfDay FROM dbo.Receipts WHERE Id = @Id;",
                new { Id = receiptId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Receipt not found");

            // ----- 1. Lock the parent pull — step 1 of the canonical order, and the
            // serialization point that lets step 8c write sibling receipt rows safely.
            var pullCtx = await conn.QuerySingleAsync<PullItemContext>(new CommandDefinition(@"
                SELECT pi.Id AS PullItemId, pi.ItemCode, pi.VendorCode, p.Id AS PullId, p.PullNumber, p.Status AS PullStatus, p.WarehouseId
                FROM   dbo.Pulls p WITH (UPDLOCK, ROWLOCK)
                INNER JOIN dbo.PullItems pi ON pi.PullId = p.Id
                WHERE  pi.Id = @PullItemId;",
                new { ident.PullItemId }, transaction: tx, cancellationToken: ct));

            // ----- 2. Lock the original receipt + read its PO line -----
            var orig = await conn.QuerySingleOrDefaultAsync<ReceiptLockRow>(new CommandDefinition(@"
                SELECT Id, PullItemId, PurchaseOrderId, PurchaseOrderLineId,
                       HourOfDay, QtyReceived, LotBatch, PalletId, BinLocation,
                       QcStatus, ReversedById, VarianceAccepted
                FROM   dbo.Receipts WITH (UPDLOCK, ROWLOCK)
                WHERE  Id = @Id;",
                new { Id = receiptId }, transaction: tx, cancellationToken: ct))
                ?? throw new NotFoundException("Receipt not found");

            // Guard precedence is unchanged from before the lock reorder: the receipt's own
            // state is judged first, then the pull's. Only the READS moved.
            if (orig.QtyReceived < 0)
                throw new BusinessException("Cannot cancel a reversal entry");
            if (orig.ReversedById is not null)
                throw new BusinessException("Receipt is already voided");

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
                       SET IsClosed           = 0,
                           ClosedAt           = NULL,
                           ClosedBy           = NULL,
                           ClosedReason       = NULL,
                           VarianceReasonCode = NULL   -- db/049 §4.4
                     WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay;",
                    new { orig.PullItemId, orig.HourOfDay },
                    transaction: tx, cancellationToken: ct));
            }

            // ----- 8c. Recompute VarianceQty for the window from the rows that survive.
            //
            // VarianceQty describes a DECISION about a window ("401 arrived against 400
            // outstanding"), but §2c stores it on one arbitrary slice of the confirm that
            // recorded it. Cancel is scoped to a receipt ROW, so reversing any other slice
            // used to leave that number behind describing a receive that no longer exists:
            // cancel the 1-pc overflow slice of a 401 and the surviving 400-row still
            // claimed VarianceQty = +1 against a window sitting at exactly 400/400.
            // Nothing reads the column today, which is why that would have gone unnoticed
            // rather than why it was acceptable.
            //
            // THE INVARIANT, restored here on every cancel. For a window carrying at least
            // one live VarianceAccepted row:
            //     SUM(VarianceQty) over live rows of (PullItemId, HourOfDay)
            //         == SUM(QtyReceived) over those rows - window.ExpectedQty
            //     SIGNED — negative when short, positive when over — and NULL only when
            //     that difference is exactly zero.
            //
            // The carrier qualifier is load-bearing, not a hedge. A window where variance
            // was never accepted also has a non-zero difference — an ordinary partial is
            // live < expected — and there is no ticked row to carry it. Stamping the figure
            // on a plain row would turn every partial into something that reads as an
            // accepted variance. So where no row carries the tick, VarianceQty stays NULL
            // on every row and the invariant does not apply.
            //
            // It needs no batch/confirm key, because it is a WINDOW-level aggregate: which
            // row carries the figure is arbitrary by construction, so any surviving
            // variance row is as good a carrier as the original. That is also why this
            // runs unconditionally rather than only when the cancelled row was itself a
            // variance row — cancelling a plain partial that shares a window with a closed
            // variance receipt moves the same total and orphans the same number.
            //
            // Signed rather than overage-only: an over-only rule would make the column mean
            // different things before and after a cancel touched the window, with nothing in
            // the data to say which regime a row is in. Derivability (ExpectedQty - live) is
            // equally true of the positive case, so it cannot be the argument for dropping
            // one sign and keeping the other. One signed path also replaces a sign test plus
            // two behaviours.
            //
            // Zero-quantity closes are unaffected either way: §2d writes no Receipts row, so
            // ClosedBy/ClosedAt/ClosedReason remain their sole record.
            //
            // Live = neither voided (ReversedById) nor itself a reversal
            // (ReversesReceiptId); the same definition the window cache reconciles against.
            // Seeks IX_Receipts_PullItem (PullItemId, HourOfDay) — no new index, and the
            // sibling rows are safe to write because the Pulls row was locked at step 1.
            var recompute = await conn.QuerySingleAsync<VarianceRecompute>(new CommandDefinition(@"
                DECLARE @live INT = (
                    SELECT ISNULL(SUM(QtyReceived), 0) FROM dbo.Receipts
                     WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay
                       AND ReversedById IS NULL AND ReversesReceiptId IS NULL);

                DECLARE @expected INT = ISNULL((
                    SELECT ExpectedQty FROM dbo.PullItemWindows
                     WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay), 0);

                DECLARE @delta INT = @live - @expected;

                -- One carrier, chosen the way the receive path chooses it: the earliest
                -- surviving slice that carries the operator's tick.
                DECLARE @carrier UNIQUEIDENTIFIER = (
                    SELECT TOP (1) Id FROM dbo.Receipts
                     WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay
                       AND ReversedById IS NULL AND ReversesReceiptId IS NULL
                       AND VarianceAccepted = 1
                     ORDER BY ReceivedAt, Id);

                UPDATE dbo.Receipts
                   SET VarianceQty = NULL
                 WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay
                   AND ReversedById IS NULL AND ReversesReceiptId IS NULL
                   AND VarianceQty IS NOT NULL;

                DECLARE @stamped INT = 0;
                IF @carrier IS NOT NULL AND @delta <> 0
                BEGIN
                    UPDATE dbo.Receipts SET VarianceQty = @delta WHERE Id = @carrier;
                    SET @stamped = @@ROWCOUNT;
                END

                SELECT @delta AS Delta, @stamped AS Stamped, @live AS LiveQty, @expected AS ExpectedQty,
                       CASE WHEN @carrier IS NULL THEN 0 ELSE 1 END AS HasCarrier;",
                new { orig.PullItemId, orig.HourOfDay },
                transaction: tx, cancellationToken: ct));

            // A window OVER expected with no surviving ticked row should be unreachable: a
            // receive above outstanding is refused unless the box is ticked, so live rows can
            // only exceed ExpectedQty if at least one of them carries the flag. (The negative
            // case is ordinary — every plain partial is short — so it is not warned on.)
            // Log rather than throw: failing an operator's correction over a bookkeeping
            // column would be the worse outcome, and the warning is what makes it findable.
            if (recompute.Delta > 0 && recompute.HasCarrier == 0)
            {
                _logger.LogWarning(
                    "Variance recompute found no carrier: PullItem {PullItemId} hour {Hour} on pull {PullNumber} " +
                    "is over by {Delta} ({Live} live vs {Expected} expected) but no live row carries VarianceAccepted=1.",
                    orig.PullItemId, orig.HourOfDay, pullCtx.PullNumber,
                    recompute.Delta, recompute.LiveQty, recompute.ExpectedQty);
            }

            // ----- 9. Update Pulls timing + demote fully_received → in_progress -----
            //
            // KNOWN DEFECT, LOGGED AND DELIBERATELY NOT FIXED HERE (see db/047_STATUS.md).
            // This demotes on the STATUS ALONE. ReceiveAsync's step 7 recomputes the pull
            // from `NOT EXISTS (outstanding window)`; cancel does not, so a cancel that
            // leaves every window satisfied still drops the pull to in_progress — e.g.
            // reversing the 1-pc overflow slice of a 401, which lands the window back on
            // exactly 400/400 with nothing outstanding.
            //
            // It is a SEPARATE defect, not a consequence of row-scoped cancel: the demote
            // is unconditional, so it fires identically whether the confirm wrote one row
            // or five, and fixing the row-scoping would not touch it. The cause is the
            // asymmetry between step 7 here and step 7 in ReceiveAsync — cancel never grew
            // the recompute that the Pull 0000009383 fix added to the receive side.
            // Left alone because changing pull-status transitions is a behaviour change
            // with its own blast radius (the pending queue, /Reports, the close gate), and
            // it is not what this change is for.
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

        // Storer grain. PullItems.VendorCode holds the STRIPPED ERP form
        // ('5732'); PurchaseOrderLines.VendorCode holds the PREFIXED form
        // ('COI-5732'). Any comparison across the two must normalise — see
        // VendorMatchSql. NULL on historical merged rows and on hand-created
        // items, where the FIFO walk keeps its pre-storer-grain behaviour.
        public string? VendorCode { get; set; }

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

        // §5.1 — projected on every read so the audit scope label can be decided from the
        // allocation that actually happened rather than from the request flag.
        public bool IsPullLinked { get; set; }
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

    /// <summary>
    /// The two immutable columns cancel needs before it can decide WHICH pull row to lock.
    /// Read without a lock on purpose — see the class summary's lock-order note.
    /// </summary>
    private sealed class ReceiptIdentity
    {
        public Guid PullItemId { get; set; }
        public byte HourOfDay { get; set; }
    }

    /// <summary>Outcome of cancel's step 8c variance recompute, for the unreachable-case warning.</summary>
    private sealed class VarianceRecompute
    {
        public int Delta { get; set; }
        public int Stamped { get; set; }
        public int LiveQty { get; set; }
        public int ExpectedQty { get; set; }

        /// <summary>1 when a live row carries VarianceAccepted — i.e. when the invariant applies.</summary>
        public int HasCarrier { get; set; }
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
