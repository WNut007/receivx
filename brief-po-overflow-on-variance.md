# Brief — Allow PO allocation to overflow past the pull-linked PO when variance is accepted

Target: `ReceivingOps` v3.2, `C:\dev\receivx`, project `src/ReceivingOps.Web`.
Type: **code-only, no migration.** Nothing in this brief changes schema.

---

## 1. Context — this is already established, do not re-investigate

Migration `db/047` is applied on production (2026-08-07) and the accept-variance
feature works. Verified live:

- `PullItemWindows.IsClosed / ClosedAt / ClosedBy / ClosedReason` and
  `Receipts.VarianceAccepted / VarianceQty` all exist on production.
- `ClosedBy` is `UNIQUEIDENTIFIER` (matches `Receipts.ReceivedBy`, which is also
  `uniqueidentifier`). This is correct — the system stores user GUIDs, not usernames.
  If `db/047` in the repo still says `NVARCHAR(100)`, fix the file to match production.
- `ClosedReason` is `NVARCHAR(1000)` on production. If the repo file says 500, fix
  the file, and confirm the DTO/`maxlength` on the textarea agree with 1000.
- The over-receipt gate at `ReceiptService.cs:429` (`req.Qty > outstanding && !variance`)
  passes correctly once the operator ticks the box. `varianceQty` is computed as
  `req.Qty - outstanding`. **This part is finished — leave it alone.**
- The `closeOnly` path (`req.Qty == 0`) already skips the PO walk entirely, so
  **short closes already work** even when the PO is exhausted or absent.

### The remaining gap

Over-receipt is still blocked, but by a *different* gate further down: PO line
capacity (`BUILD_PROMPT` §7.1 Cap 2). Concrete production case:

- Pull `0000026590`, warehouse `WH-BPI`, item `2063-810743-0E4`,
  vendor `COI-HSABP1` (Western Digital), hour 20:00.
- Window expects 400. Vendor delivered 401. Operator ticks accept-variance.
- `ReadOpenPoLinesAsync` returns exactly one line (PO `0000026590`, remaining 400).
- `totalAvailable (400) < req.Qty (401)` → `"Insufficient PO capacity. Need 401, have 400 pcs."`
- Confirm button is disabled client-side; nothing can be recorded.

### Why the fix is allocation-level, not accounting-level

Across `WH-BPI` for this item: **ordered 40,195, received 1,600, still open 38,595
across 112 PO lines**, all from the same vendor, every line `OrderedQty = 400`.

The over-delivered units **already have purchase-order cover** — just on a different
PO line than the one linked to this pull. ERP issues one PO per pull with a matching
number and links it via `PurchaseOrders.PullExternalRef` (a string equal to
`Pulls.PullNumber`), *not* via `PurchaseOrders.PullId`, which is NULL on ~60,323 of
60,331 PO lines.

So this is a **matching** problem, not an "unpurchased goods" problem. Therefore:

- Do **not** touch `CK_POL_Caps`.
- Do **not** allow `PurchaseOrderLines.ReceivedQty` to exceed `OrderedQty` on any line.
- Do **not** make `Receipts.PurchaseOrderLineId` nullable.
- Every received unit must still point at a real PO line. Reconciliation with ERP
  must stay exact.

> **Trap — `vw_PurchaseOrderAvailability` is misleading.** It exposes `po.PullId`
> with a comment calling it the "§3.5 lock-aware FIFO filter key", but the real
> filter is `po.PullId OR po.PullExternalRef`, and the view does not expose
> `PullExternalRef` at all. Any pull-scope query written against this view returns
> wrong answers. A separate brief covers fixing the view; for this work, query the
> base tables the way `ReadOpenPoLinesAsync` does.

---

## 2. Business rule to implement

> When — and only when — the operator has ticked accept-variance, FIFO allocation may
> overflow past the pull-linked PO(s) into other open PO lines for the **same vendor,
> same item, same warehouse**, filling the pull-linked PO(s) first.

### Decisions already made — implement as stated, do not re-open

1. **Overflow scope:** same `VendorCode` + same `ItemCode` + same `WarehouseId`.
   Never across vendors. Never across warehouses.
2. **Ordering:** consume pull-linked PO lines to exhaustion first, then overflow
   lines in the existing FIFO order (`po.OrderDate ASC, po.PoNumber ASC,
   pol.LineNumber ASC`). The PO that was deliberately linked to the pull should be
   the one that closes.
3. **Gated on the tick:** overflow happens only when `variance == true`. With the
   box unticked, behaviour is byte-for-byte what it is today, including the same
   error text.
4. **No cap.** The ledger records what was physically counted. Overflow walks as
   many PO lines as the quantity requires. Do not add a percentage limit or a
   "one extra PO" limit.

### Consequence to be explicit about in the audit trail

Decision 4 means a large over-delivery can consume PO lines that another pull will
later expect to draw from. That is accepted. It must therefore be **visible**: every
overflow allocation is recorded distinctly (see §5), so when a later pull comes up
short, the reason is traceable rather than mysterious.

---

## 3. Discovery — report before editing

1. **Vendor anchor.** `ReadOpenPoLinesAsync` currently filters on warehouse + item +
   status only (plus the pull clause). It does not know the vendor.
   `PurchaseOrderLines` carries `VendorCode`/`VendorName`; `PullItems` also carries
   `VendorCode`/`VendorName`. Report which is populated in practice, and how often
   `PullItems.VendorCode` is NULL. State which you will use as the anchor and why.
   - Preferred: take the vendor from the **pull-linked PO line(s)** — it is the
     vendor the pull is actually transacting with.
   - Fallback when there are no pull-linked lines at all: `PullItems.VendorCode`.
   - If both are unavailable: **do not widen.** Keep today's `"No PO linked"` error.
2. **Hour cap interaction.** This pull has `LockHourCap = 1`. Confirm where the
   §7.1 Cap 1 check sits relative to the `variance` flag, and confirm that ticking
   the box already clears it. If it does not, this fix alone will not unblock the
   case — say so before writing code.
3. **Preview path.** `GET /api/receipts/preview` must run the same widened logic
   (lock-free) or the modal will keep showing a failure and keep the Confirm button
   disabled. Locate the preview handler and confirm it calls
   `ReadOpenPoLinesAsync(..., withLocks: false, ...)`. Report whether the preview
   request currently carries the variance flag — if it does not, that is a required
   API change (§6).
4. **Client-side gate.** Find what disables the Confirm button in the Receive Goods
   modal. In the production screenshot the button is disabled with the PO-capacity
   error shown, so a client-side check is involved. Report the file and the condition.
5. **Cancel/reverse with multi-row receipts.** `CancelAsync` (~line 870) locks
   `orig.PurchaseOrderLineId` — a single line. Overflow makes multi-row allocations
   common. Confirm that cancelling a receive that produced N rows reverses **all N**
   rows against their own PO lines, not just one. If it does not, stop and report —
   that is a correctness bug that must be fixed before overflow ships, not after.

---

## 4. Implementation

### 4.1 `ReadOpenPoLinesAsync` (`ReceiptService.cs:262-296`)

Add a parameter for the variance flag and the vendor anchor. Keep the existing
signature shape and the `withLocks` hint mechanism.

Current pull clause (line 280-281):

```csharp
if (pullCtx.LockPoByPull)
    sql += " AND (po.PullId = @PullId OR po.PullExternalRef = @PullNumberStr)";
```

Replace with a tiered form. When `LockPoByPull` is true **and** variance is accepted
**and** a vendor anchor is available, do not restrict the row set to the pull —
instead keep every candidate line and rank pull-linked lines first:

```csharp
var pullMatch = "(po.PullId = @PullId OR po.PullExternalRef = @PullNumberStr)";

if (pullCtx.LockPoByPull && !allowOverflow)
{
    sql += $" AND {pullMatch}";
}
else if (pullCtx.LockPoByPull && allowOverflow)
{
    // Overflow: widen to the same vendor, but consume the pull's own PO first.
    sql += " AND pol.VendorCode = @VendorCode";
}

var tier = (pullCtx.LockPoByPull && allowOverflow)
    ? $"CASE WHEN {pullMatch} THEN 0 ELSE 1 END, "
    : "";

sql += $" ORDER BY {tier}po.OrderDate ASC, po.PoNumber ASC, pol.LineNumber ASC;";
```

Notes:

- `allowOverflow` must be **false** unless the caller passed variance = true. A
  receive without the tick must produce the identical SQL it produces today.
- Declare `allowOverflow` as a **required parameter with no default value**, so
  every call site must state its intent explicitly and a future caller cannot
  inherit overflow by omission.
- Assert the invariant at the top of the method: if `allowOverflow` is true while
  the variance flag is false, throw immediately. This is a programming error, not a
  user error — fail loudly in development rather than silently widening in
  production.
- Mode A (`LockPoByPull == false`) is untouched: it is already warehouse-wide, and
  adding a vendor filter there would be a behaviour change nobody asked for.
- The single-query tiered form is preferred over two round trips: one lock
  acquisition, one deterministic order, no window between reads.

### 4.2 Locking and contention

Widening the row set widens the `UPDLOCK, HOLDLOCK` range from ~1 line to
potentially ~112 lines for that (vendor, item, warehouse). That is acceptable
**because it only happens on the variance path**, which is operator-initiated and
comparatively rare per unit time. Do not widen the lock on the normal path.

Keep `HOLDLOCK`. Dropping it to reduce contention would let two concurrent
over-receipts both see the same overflow line as available and double-spend it.

### 4.3 Allocation walk

The existing FIFO walk (`ReceiptService.cs:470-476`) needs no logic change — with
the tiered ordering it naturally fills the pull-linked line first and then spills.
Verify the `totalAvailable < req.Qty` guard (line 465-468) now sums the widened set,
so the 401-vs-400 case no longer trips it.

If `totalAvailable` is still short even after widening (genuinely not enough PO
cover anywhere for that vendor+item+warehouse), keep failing — but with the improved
message from §5.

---

## 5. Audit and error messages

### 5.1 Scope label

`ReceiptService.cs:645` currently produces two labels:

```csharp
var scopeLbl = pullCtx.LockPoByPull ? "pull-locked" : "warehouse-wide FIFO";
```

Add a third state so an overflow is never silently indistinguishable from a normal
pull-locked receive:

- `"pull-locked"` — locked, no overflow occurred
- `"pull-locked + variance overflow"` — locked, and at least one allocated slice
  came from a PO line not linked to this pull
- `"warehouse-wide FIFO"` — Mode A, unchanged

Decide the label from the **actual plan**, not from the request flag: overflow is
only real if a slice landed on a non-pull-linked line. A 401-unit receive where the
pull PO happened to have 500 remaining is not an overflow.

The existing allocation summary (`"{Take}@{PoNumber}"` joined with `+`) already
names every PO consumed — keep it, it is what makes overflow traceable.

### 5.2 Error text

`"Insufficient PO capacity. Need 401, have 400 pcs."` states a fact and no remedy.
Replace with mode-aware text:

- **Pull-locked, no variance ticked, and widening would have helped:**
  say that the PO linked to this pull has N pcs left, and that ticking accept
  variance will draw the remainder from other open POs for the same vendor.
  This is the message that turns today's dead end into a self-service action.
- **Pull-locked, variance ticked, still short:** say how much is available across
  all open POs for that vendor/item/warehouse, and that procurement must open or
  link another PO.
- **Mode A (warehouse-wide):** keep today's meaning — open another PO.

Do not put PO numbers the operator has no permission to see into these strings;
follow whatever the existing modal already exposes (it currently shows PO numbers
in the allocation preview, so this is likely fine — confirm).

---

## 6. API and UI

1. **Preview must accept the variance flag.** If `GET /api/receipts/preview` does
   not currently take it, add it (query param, defaulting to false) and thread it
   into `ReadOpenPoLinesAsync`. Without this the modal cannot show a successful plan
   and the Confirm button stays disabled.
2. **Preview response should surface overflow.** The modal already renders
   "Will allocate 1500 from PO-A + 500 from PO-B". When a slice comes from a
   non-linked PO, mark it visibly (a badge or suffix) so the operator sees they are
   drawing on another PO before confirming, not after.
3. **Re-run preview when the checkbox toggles.** Ticking accept-variance changes
   the allocation plan, so the modal must refetch rather than reuse the pre-tick
   preview.
4. **Confirm button gating.** With variance ticked and the preview succeeding, the
   button must enable. Keep the server as the source of truth — the client check is
   advisory only, per §7 of `BUILD_PROMPT`.
5. **Do not change** the accept-variance checkbox copy, the `OVER BY n PCS` hint,
   or the final-receipt close semantics. Those are correct as shipped.

---

## 7. Test cases

Reproduce the live failure first (pull `0000026590`, item `2063-810743-0E4`,
hour 20, qty 401, box ticked) and confirm the 409 before changing anything.

1. Over-receipt 401 against a pull-linked PO with 400 remaining, box ticked →
   succeeds; **two** `Receipts` rows (400 on the pull's PO line, 1 on the FIFO-next
   line for the same vendor); window `ReceivedQty` = 401; `IsClosed = 1`;
   `VarianceAccepted = 1`; `VarianceQty = 1`.
2. Same request, box **unticked** → fails exactly as today, same error code, no rows.
3. Over-receipt where the pull-linked PO alone covers the quantity → one row, on the
   pull's PO line; audit label is `"pull-locked"`, not the overflow label.
4. Over-receipt spanning three PO lines (e.g. 1,200 against a 400 line) → three rows
   in `OrderDate` order, first slice on the pull-linked line; no cap error.
5. Overflow never crosses vendors: seed an open PO for the same item and warehouse
   under a different `VendorCode` with ample quantity, request more than the
   vendor's own lines can cover → fails, and the other vendor's line is untouched.
6. Overflow never crosses warehouses (same check, different `WarehouseId`).
7. `LockPoByPull = 0` (Mode A) pull, over-receipt with box ticked → behaviour
   unchanged from today; no vendor filter applied.
8. No PO linked at all + box ticked + `PullItems.VendorCode` NULL → still returns
   `"No PO linked"`; does not silently widen to the whole warehouse.
9. Short close (`qty = 0`, box ticked) with the PO exhausted → still succeeds, still
   writes no `Receipts` row, still sets `IsClosed`. Regression guard on §2d.
10. Normal in-range receive (qty < outstanding, box unticked) → allocation plan and
    lock footprint identical to pre-change. Capture the generated SQL for both and
    diff them.
11. Concurrency: two operators over-receive the same SKU simultaneously, both
    ticking variance, combined quantity exceeding one PO line. Exactly one wins the
    `IsClosed` race; the loser's whole transaction rolls back including its receipt
    rows; no PO line ends with `ReceivedQty > OrderedQty`.
12. Cancel a receive that produced N rows across N PO lines → all N reversed, each
    against its own line; `PurchaseOrderLines.ReceivedQty` returns to the pre-receive
    value on every line; window `IsClosed` cleared per db/047 §8b.
13. A PO fully consumed by an overflow slice auto-closes (step 5) and disappears
    from subsequent FIFO availability.
14. Audit row for an overflow receive carries the overflow label and names every PO
    in the allocation summary.

---

## 8. Out of scope

- Relaxing `CK_POL_Caps` or allowing `ReceivedQty > OrderedQty` on any line.
- Making `Receipts.PurchaseOrderLineId` nullable, or any "over-receipt pending PO"
  state.
- Changing `LockPoByPull` defaults, or reconciling the ~14,629 pulls that have
  `LockPoByPull = 1`. **Do not touch this.** Those pulls work today via
  `PullExternalRef`; changing the default or the clause risks stopping receiving
  system-wide.
- Fixing `vw_PurchaseOrderAvailability` (separate brief).
- The `deploy.ps1` pre-flight schema guard (separate brief).
- Reopening a closed line; tolerance percentages; who may accept variance.

---

## 9. Deploy

Code-only — no migration, no schema change. Standard flow: build → `deploy.ps1`
(publish → inject web.config env vars → backup → stop pool → robocopy → start pool →
health check). `deploy.ps1` does not run migrations and none is needed here.

Confirm before deploying which branch production is built from. Production has
previously been observed to originate from `feat/digital-signature` rather than
`main`; basing this work on `main` risks reverting live signature UI. Report the
branch you based on.
