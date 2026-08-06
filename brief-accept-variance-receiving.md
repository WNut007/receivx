# Brief: Accept Variance on Goods Receipt

**System:** ReceivingOps, post-v3.5 on `feat/digital-signature` (.NET 8, Dapper, SQL Server)
**Revision:** rev 4 — grain decided, Stage 2 findings folded in. Where this document contradicts itself, section 2c wins.
**Screen:** "Receive Goods" modal (quantity entry against a scheduled pull slot)
**Type:** Schema change + service layer + API + UI

---

## 1. Goal

Today the receipt modal hard-caps the quantity at the outstanding amount and refuses anything above it ("MAXIMUM ALLOWED: N PCS. CANNOT RECEIVE OVER EXPECTED"). Real deliveries arrive short or over, and the operator currently has no way to record what actually turned up or to stop the line from sitting in the pending queue forever.

Change it so that:

1. The operator may enter **any** quantity, including above outstanding.
2. **Partial receipts behave exactly as they do today.** Entering less than outstanding without ticking anything records a partial and leaves the line open for the next delivery — no alert, no checkbox involvement. This is normal daily use and must not regress.
3. When the operator is on the **final** receipt for a SKU and the total will not reach expected, an **Accept variance** checkbox lets them close the line at the actual figure instead of leaving a permanent remainder.
4. Over-receipt is only possible with the checkbox ticked. There is no coherent "more coming later" reading of an over-delivery, so over is always terminal. Unticked over-receipt is blocked with the alert.
5. Ticking is a **once-per-SKU-line** action — it closes the line, and any later attempt to receive against that line is rejected.
6. A **note is mandatory** whenever variance is accepted — it is the audit reason.

---

## 2. Pre-flight — read this before writing any code

**Branch.** The production build appears to originate from `feat/digital-signature`, not `main`. Confirm which branch the currently deployed DLLs were built from **before** branching. Basing this on `main` risks reverting the live signature UI.

**Migration numbering.** `db/042`–`db/045` **are** tracked on `feat/digital-signature` — an earlier claim that they were unreconciled was wrong. The real hazard is different: there is **no migration ledger table**, so applied state can only be inferred by probing for the object each migration creates, and `db/040` and `db/041` each have two different files sharing the number. Do not assume the next free number and do not renumber the collisions — both members of each pair may already be applied on production under their current names.

**Deploy order is non-negotiable:** run migration → copy DLL → restart app pool. A DLL that references a column the DB does not have produces `SqlException 207` surfacing as a phantom HTTP 405.

**`deploy.ps1` does NOT run migrations.** It covers publish → inject web.config env vars → backup → stop pool → robocopy → start pool → health check → auto-rollback. The migration is a manual step that must be run against production **before** `deploy.ps1` is invoked. Its auto-rollback restores the DLL, not the schema — a rollback after a migration leaves the old DLL against the new schema, so verify the migration is backward-compatible with the currently deployed DLL before running it.

---

## 2b. Confirmed from the production probe (2026-08-06)

Run against the live `ReceivingOps` database.

- **Migration 047 is confirmed free.** Forward-check confirms `Receipts.VarianceAccepted`, `Receipts.VarianceQty`, and `IsClosed` on all three candidate line tables are absent on production.
- Applied: 039, 040a, 040b, 041b, 042, 043, 044, 045, 046. **Both members of the 040 collision are live** — record that, do not renumber.
- **041a `backfill_composite_itemcode` is NOT applied** — 506 fixable composite `PullItems.ItemCode` values remain.
- Newest schema object dates to 2026-06-29 (migration 043); `PoImportLog` last modified 2026-07-20 (migration 046). **Nothing on production is unexplained by a file in `db/`** — there are no undocumented hand-run migrations.

### Four things the probe exposed that this brief had not accounted for

**1. Grain — which table is "the line"?**

`PullItemWindows` holds `Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty`. Expected and received live **per SKU per hour slot**, and the modal header reads "SCHEDULED 23:00" with "RECENT TRANSACTIONS FOR THIS SLOT". The receipt is written against a *window*, not against a SKU outright.

The requirement is one accept-variance per **SKU**. If a SKU can hold more than one window in a pull, closing one window does not close the SKU, and the two readings diverge:

- `IsClosed` on `PullItemWindows` → closes that hour slot only
- `IsClosed` on `PullItems` → closes the SKU across every slot

**Do not choose this yourself.** Report how many `PullItemWindows` rows a typical `PullItemId` has across recent pulls. If it is always exactly one, the distinction is academic and window-level is right. If it is often more than one, **stop and ask** — that changes the requirement, not just the implementation.

**2. `ReceivedQty` is stored, not derived.**

`PullItemWindows.ReceivedQty` is a materialised column, so received quantity has two sources of truth: that column and the `Receipts` ledger. Establish which one the outstanding calculation actually reads, whether both are updated on every write, and whether they currently agree on production. `MAX(0, Expected − Received)` must be applied to whichever is authoritative, and an over-receipt must never drive the stored column negative.

**3. Receipts can be reversed — and this brief had no answer for it.**

`Receipts` carries `ReversesReceiptId`, `ReversedById`, `CancelReason`. A reversal path already exists in production.

Section 5 says re-opening a closed line is out of scope. That was written without knowing this, and it leaves a hole: if the receipt that closed a line with accepted variance is later reversed, the line stays closed while its closing quantity is undone — a permanently stuck line with no way back.

**Required:** reversing a receipt where `VarianceAccepted = 1` must clear `IsClosed`, `ClosedAt`, `ClosedBy` and `ClosedReason` on the parent line, in the same transaction as the reversal. This is not "unclose as a feature" — it is the existing reversal path continuing to be correct. Implement it in the reversal handler and cover it in tests.

**4. 041a is unapplied on production.**

506 `PullItems` rows carry composite `ItemCode` values (`SKU-TrialId`) that match no `PurchaseOrderLines.ItemCode`. If the outstanding calculation or the line-closing path joins `PullItems` to `PurchaseOrderLines` on `ItemCode`, those rows behave differently from every other row. Check whether your code path touches that join and report it. Do **not** run 041a as part of this change — it is a separate data migration carrying its own risk.

---

## 2c. Decisions from Stage 2 — these override anything earlier in this brief

### Grain: DECIDED — window level, with a guard

`IsClosed` goes on **`dbo.PullItemWindows`**, not `PullItems`.

`Receipts` has no `PullItemWindowId`; it stores `PullItemId + HourOfDay` and resolves the window by that pair. So the conditional close keys on `(PullItemId, HourOfDay)`, not on a single line id.

**The guard:** the accept-variance checkbox is offered **only when the parent `PullItem` has exactly one window.** If a SKU has more than one window, the checkbox is not rendered and the line cannot be variance-closed — behaviour there is unchanged from today. Enforce this **server-side as well as in the UI**: a request carrying `VarianceAccepted = true` for a multi-window `PullItem` returns `400`, code `MULTI_WINDOW_NOT_SUPPORTED`.

Rationale: 99.97% of items hold exactly one window, and all 13 multi-window items are demo or smoke fixtures — every ERP-synced item is 1:1. Option A would have required rewriting the outstanding arithmetic the modal gates on (`ReceiptService.cs:154`), the highest-risk code in this change, to serve a case that does not exist in real data. `BpiPrsSource.cs:155-162` can still produce multi-window items from upstream, so the guard is what keeps that case honest instead of silently mis-closing it. Log a warning when the guard fires — if it ever appears in real ERP data, we want to find out from a log, not from a wrong number.

### The silent clamp is a live defect — fixing it is part of this change

`receiving.js:752` does `const qty = Math.min(inputVal, activeMax)`. Entering 1,500 against 1,000 outstanding POSTs 1,000, with no alert, no error, and the "cannot receive over expected" hint already replaced at `:719` by copy stating over is allowed. **The operator believes they recorded 1,500.**

Removing the clamp is therefore not "relaxing a limit" — it is repairing silent data loss. Every over-entry must either be recorded at the entered figure or refused with a visible error. Nothing may be silently rewritten. This applies equally to the quick-fill buttons at `:735-743`, which currently clamp to `activeMax` by the same route.

### The five outstanding calculations

These are parallel copies, not one helper. All five need the `IsClosed = 0` filter, and **each gets its own named regression test** — a filter added to four of five is a bug that surfaces weeks later:

1. `ReceiptService.cs:154` — the authoritative gate that raises 409. `MAX(0, …)` lands here.
2. `ReceiptService.cs:387` — `NOT EXISTS` flipping the pull to `fully_received`. Without the filter a short-closed line pins the pull off `fully_received` forever.
3. `ReceiptService.cs:413` — `outstandingWindows` count feeding `ReceiveResult.FullyReceived`.
4. `PullRepository.cs:42-45` — `WindowsPending`, the dashboard badge. This is the "reappears in someone's worklist" query.
5. `CloseService.cs:67-72` — the close gate. Without the filter a short-closed pull can never be closed at all.

Do **not** consolidate these into a shared helper as part of this change. That is a separate refactor on a separate deploy; doing it here widens the blast radius of a deploy that already touches the receipt write path.

PO-side `OrderedQty - ReceivedQty` is a different concept — leave it alone.

Client-side derived outstanding (`receiving.js:56-60, 79-87, 290, 310-312, 428-429, 844, 1064-1068, 1096-1101, 1655-1667`; `dashboard.js:485, 1413`) is display-only but will render a stale outstanding against a closed line. Update it.

### FIFO slices — one confirm writes several Receipt rows

`ReceiptService.cs:301-318` inserts one row per FIFO allocation slice, so a single Confirm can produce several `Receipts` rows, and reversal (`POST /api/receipts/{id}/cancel`) acts on **one row at a time**.

Rule:

- `VarianceAccepted = 1` on **every** row written by that confirm.
- `VarianceQty` on **exactly one** of them, null on the rest, so `SUM(VarianceQty)` stays correct. Document this in the migration comment.
- Reversing **any** row with `VarianceAccepted = 1` clears `IsClosed` on the window.

The asymmetry is deliberate. Re-opening a line that did not strictly need re-opening is recoverable — the operator closes it again. Leaving it closed after part of the closing quantity was reversed is not.

### Approved without further discussion

- **Error codes:** carry them in `ProblemDetails.Extensions["code"]`. Additive, leaves existing status codes and messages intact, does not break current callers.
- **`CK_PIW_Caps`:** read the predicate first. If it asserts `ReceivedQty <= ExpectedQty`, over-receipt violates it and it must be relaxed in `db/047`. Relaxing a CHECK is backward-compatible with the currently deployed DLL, so it is safe against a rollback.
- **Lock ordering:** `CancelAsync` locks pull then PO line and blind-updates the window at `:554`; `EnforceHourCapAsync` locks the window at `:139` first. Adding a window update to cancel creates a lock-order inversion and a deadlock under test 15. Define one canonical acquisition order, write it as a comment at the top of both methods, and make both paths follow it.
- **Reversal wiring:** the `IsClosed` reset goes immediately after step 8 at `ReceiptService.cs:559`, conditional on the original receipt's `VarianceAccepted`. That means adding `VarianceAccepted` to the `SELECT` at `:467-470` and to `ReceiptLockRow`. Step 9's `fully_received → in_progress` demotion is not sufficient on its own.
- **Composite ItemCode:** the 506 unmigrated rows cannot be received at all today (`ReceiptService.cs:187` joins on `ItemCode` and matches zero PO lines). Do not use them as test fixtures. Do not run 041a.

---

## 3. Discovery — do not guess names

Before implementing, locate and report back:

- The table storing individual receipt transactions (the one written when Confirm Receipt is pressed).
- The table/entity representing the pull **line** (the thing that has Expected, and against which outstanding is computed).
- Every query, view, or repository method that computes **outstanding** or filters **pending / not-yet-received** lines. Grep for the outstanding arithmetic — it is likely expressed as `Expected - SUM(ReceivedQty)` in more than one place.
- The controller action and request DTO behind the modal's submit.
- The client-side validation that currently enforces the max (the `max` attribute on the number input plus whatever JS gates the Confirm button).

List these in your reply before editing. If the outstanding calculation appears in more than three places, flag it — that is a sign it should be centralised rather than patched in parallel.

---

## 4. Schema

New migration. Two concerns: recording that a given receipt accepted variance, and marking the line closed.

**On the receipt transaction table:**

| Column | Type | Notes |
| --- | --- | --- |
| `VarianceAccepted` | `BIT NOT NULL` | `DEFAULT 0`, backfills existing rows as 0 |
| `VarianceQty` | `INT NULL` | Signed. Positive = over, negative = short. Null when no variance. **INT, not decimal** — every quantity column in this schema is `INT` and `CLAUDE.md` carries whole-unit arithmetic as an invariant. A fractional variance column would be the only one in the system |

**On `dbo.PullItemWindows`:**

| Column | Type | Notes |
| --- | --- | --- |
| `IsClosed` | `BIT NOT NULL` | `DEFAULT 0` |
| `ClosedAt` | `DATETIME2 NULL` | |
| `ClosedBy` | `NVARCHAR(100) NULL` | User identifier, same convention as the existing audit columns on that table |
| `ClosedReason` | `NVARCHAR(500) NULL` | Copy of the operator's note at close time |

`IsClosed` is required — it cannot be derived. An under-receipt leaves `Expected - Received > 0`, so arithmetic alone will keep showing the line as pending forever. That is precisely the bug this change exists to fix.

Add a filtered index if the pending-lines query is hot:
`CREATE INDEX IX_<Line>_Open ON <LineTable>(<PullId>) WHERE IsClosed = 0`

Use `WITH (ONLINE = ON)`. Verified on production 2026-08-06: Enterprise Edition (64-bit), EngineEdition 3, ProductVersion 16.0.1000.6.

Reuse the existing note column on the receipt transaction as the variance reason. Do **not** add a second note field; the operator sees one box and it should map to one column.

---

## 5. Service layer

**Outstanding calculation.** Change it to `MAX(0, Expected - SUM(ReceivedQty))`. Over-receipt must never surface a negative outstanding anywhere in the UI or in exports.

**Pending / open-line filters.** Every query identified in §3 must add `AND IsClosed = 0`. This is the highest-risk part of the change — a missed query means closed lines keep reappearing in someone's worklist. Enumerate them explicitly in your reply when done.

**Closing.** When a receipt is saved with `VarianceAccepted = 1`, in the same transaction set `IsClosed = 1`, `ClosedAt = SYSUTCDATETIME()`, `ClosedBy = <current user>`, `ClosedReason = <note>` on the parent line. Receipt insert and line close must be atomic — one is meaningless without the other.

**Once per line, enforced in SQL.** Two operators can have the modal open on the same SKU at the same time. Do not read-then-write. Close the line with a conditional update:

```sql
UPDATE dbo.PullItemWindows
SET IsClosed = 1, ClosedAt = SYSUTCDATETIME(), ClosedBy = @User, ClosedReason = @Note
WHERE PullItemId = @PullItemId AND HourOfDay = @HourOfDay AND IsClosed = 0;
```

If the affected row count is 0, another user already closed it — roll back the whole transaction including the receipt insert, and return `409`. A `WHERE IsClosed = 0` guard is the only thing that makes "check once per SKU" actually true rather than merely likely.

**Already-closed lines are read-only.** Attempting to receive against a line where `IsClosed = 1` returns `409 Conflict`. Re-opening a closed line is **out of scope** for this phase; do not build an unclose path, but do not make the flag hard to reverse later either.

---

## 6. API contract

Extend the receipt request DTO with:

```
bool VarianceAccepted
```

The note field already exists — reuse it.

**Server-side validation. The client gate is a convenience; this is the actual enforcement.** Validate in this order:

| Condition | Response |
| --- | --- |
| `Qty < 0` | `400` — quantity cannot be negative |
| Line already `IsClosed = 1` | `409`, error code `LINE_ALREADY_CLOSED` |
| `Qty < Outstanding` and `VarianceAccepted == false` | **Valid partial.** Save, line stays open. Existing behaviour — must not regress |
| `Qty > Outstanding` and `VarianceAccepted == false` | `400`, error code `OVER_RECEIPT_NOT_ACCEPTED`, message naming outstanding and entered figures |
| `VarianceAccepted == true` and note is null/whitespace | `400`, error code `VARIANCE_REASON_REQUIRED` |
| `VarianceAccepted == true` and `Qty == Outstanding` | Accept, but ignore the flag — persist `VarianceAccepted = 0`. The line closes through the existing full-receipt path, not the variance path |
| `Qty == 0` and `VarianceAccepted == false` | `400` — a zero-quantity partial records nothing. Zero is only meaningful as a short close |

The asymmetry is deliberate: **under is ambiguous, over is not.** An under-entry could mean "the rest arrives Thursday" or "this is all we're getting" — the checkbox is what disambiguates, so it must stay optional there. An over-entry has only one meaning, so the tick is mandatory.

`Qty = 0` with the box ticked is valid and is what the existing MARK ZERO button now feeds into: nothing arrived, close the line short by the full outstanding amount.

**No upper bound on over-receipt** — per decision, any quantity is permitted. Do not introduce a percentage cap or a config key for one.

Return the recomputed outstanding and the line's `IsClosed` state in the response so the caller can update without a refetch.

---

### Worked examples

Variance is always measured against **remaining outstanding at the moment of that receipt**, never against Expected.

**Over-delivery — SKU A, expected 5,000**

| # | Entered | Outstanding before | Tick | Result |
| --- | --- | --- | --- | --- |
| 1 | 3,000 | 5,000 | no | partial, outstanding → 2,000 |
| 2 | 1,000 | 2,000 | no | partial, outstanding → 1,000 |
| 3 | 1,500 | 1,000 | **forced** | over by 500, line closed, total received 5,500 |

**Short delivery — SKU A, expected 5,000**

| # | Entered | Outstanding before | Tick | Result |
| --- | --- | --- | --- | --- |
| 1 | 3,000 | 5,000 | no | partial, outstanding → 2,000 |
| 2 | 1,000 | 2,000 | **operator's choice** | unticked → partial, 1,000 stays outstanding<br>ticked → short by 1,000, line closed, total received 4,000 |

Compare the last row of each table. In the over case the system can tell the receipt is terminal — 1,500 cannot fit into 1,000 outstanding — so it forces the tick. In the short case it cannot: 1,000 short is indistinguishable from 1,000 still in transit. Only the operator knows the truck isn't coming back. **That is the whole reason the checkbox is optional on under-receipt and must never be auto-ticked or inferred.**

**Invariant worth asserting in a test:** every preceding partial reduces outstanding exactly, so `VarianceQty` on the closing receipt equals `TotalReceived − Expected` for the line — `+500` and `−1,000` in the two tables above.

**Recovery path.** If the operator forgets to tick on the final short receipt, the line sits open at 1,000 outstanding. To close it afterwards they reopen the modal, enter 0, tick, and give a note — this is what MARK ZERO now feeds. The resulting zero-quantity receipt row is intentional: it is the audit record of who closed the line and why. Do not suppress it.

---

## 7. UI

**Quantity input.** Remove the `max` attribute and any JS clamping. Keep `min="0"`.

**Static hint line.** The current "MAXIMUM ALLOWED: N PCS. CANNOT RECEIVE OVER EXPECTED" is now false. Replace with a live variance readout that updates as the operator types:

- Qty equals outstanding → green, e.g. `COMPLETES THE LINE · 20,000 PCS`
- Qty below → neutral, e.g. `PARTIAL · 1,200 PCS WILL REMAIN OUTSTANDING`
- Qty below **with the box ticked** → red, e.g. `SHORT CLOSE · 1,200 PCS WRITTEN OFF`
- Qty above → amber, e.g. `OVER BY 500 PCS · REQUIRES ACCEPT VARIANCE`

Under-receipt must not be styled as an error state until the operator ticks the box. It is a normal partial until they say otherwise.

Use the same diff colour convention as the Production Receiving screen (match = green, short = red, over = amber).

**Checkbox.** Inside the green "How many units?" band, below the input:

> ☐ **This is the final receipt — close the line at this quantity**
> The line will be closed at the quantity entered and will not appear as outstanding again. This cannot be undone.

Rules:
- Hidden when qty equals outstanding.
- Shown when qty is **below** outstanding — optional. Unticked = partial, ticked = short close.
- Shown when qty is **above** outstanding — mandatory. Render it with the required styling and keep Confirm disabled until it is ticked.
- Auto-unticks and hides if the operator edits the quantity back to an exact match — never leave a stale tick.
- Never pre-ticked, in any state.

**Confirm Receipt button.** Disabled when any of:
- qty > outstanding and checkbox unticked
- checkbox ticked and note empty/whitespace
- qty = 0 and checkbox unticked

**Alert on blocked save.** Fires only for **unticked over-receipt**. Use the existing alert region — same styling as the current "No PO linked to this pull" banner — naming the over amount and pointing at the checkbox. Do not alert on under-receipt; that is a legitimate partial. No second confirmation dialog once the box is ticked; ticking *is* the confirmation.

**Note field.** Label flips from `NOTE (OPTIONAL)` to `NOTE · REQUIRED` when the checkbox is ticked. Red border and inline message if submitted empty. Reverts to optional if the box is unticked.

**Quick buttons.** FILL OUTSTANDING / ½ OUTSTANDING / MARK ZERO stay. ½ OUTSTANDING produces a normal partial and must **not** force the checkbox. MARK ZERO produces qty 0, which now requires the tick plus a note.

**Keyboard.** ⌘+Enter must obey the same gating as the button. It must not bypass validation.

---

## 8. Regression tests

Cover each of these:

1. Qty == outstanding, checkbox hidden → saves, line completes through the existing full-receipt path.
2. **Qty < outstanding, unticked → saves as a partial, line stays open, remaining outstanding correct, no alert.** This is the regression that matters most; run it first.
3. Two sequential partials that together equal expected → line completes normally, `IsClosed` untouched by the variance path.
4. **Full sequence 3,000 → 1,000 → 1,500 against expected 5,000.** First two save unticked as partials; the third has Confirm disabled until ticked, then closes the line with `VarianceQty = +500` and total received 5,500.
5. **Full sequence 3,000 → 1,000 against expected 5,000, second receipt ticked** → line closed, `VarianceQty = −1,000`, total received 4,000, line gone from the pending queue. Re-run with the second receipt unticked → line stays open at 1,000 outstanding.
6. **Recovery:** on that open 1,000, submit qty 0 ticked with a note → line closes, zero-quantity receipt row persists with `VarianceQty = −1,000`.
7. Qty < outstanding, ticked, note filled → saves, line `IsClosed = 1`, disappears from the pending queue, remaining quantity written off.
8. Qty > outstanding, unticked → Confirm disabled; API returns `400 OVER_RECEIPT_NOT_ACCEPTED` when called directly.
9. Qty > outstanding, ticked, note filled → saves, outstanding reads 0 (never negative), line closed.
10. Qty = 0, ticked, note filled → saves, line closed, `VarianceQty` = negative full outstanding.
11. Qty = 0, unticked → `400`.
12. Ticked but note blank → `400 VARIANCE_REASON_REQUIRED`.
13. Qty typed over, then corrected back to an exact match → checkbox hides and unticks, note reverts to optional, save proceeds.
14. Receiving against an already-closed line → `409 LINE_ALREADY_CLOSED`.
15. **Concurrency:** two sessions open on the same SKU, both tick and submit. One succeeds, the other gets `409`, and exactly one receipt row exists for the second attempt — i.e. the losing request's insert rolled back with it.
16. A line closed with variance still appears correctly on the Delivery Note / Delivery Order exports and on the Production Receiving review screen, with a non-zero DIFF.
17. **Reversal:** close a line via accepted variance, then reverse that receipt through the existing reversal path → `IsClosed`, `ClosedAt`, `ClosedBy`, `ClosedReason` all cleared, line returns to the pending queue with the correct outstanding restored.
18. **Multi-window SKU:** checkbox is not rendered; a hand-crafted request with `VarianceAccepted = true` returns `400 MULTI_WINDOW_NOT_SUPPORTED`. Run this against PL-2847 (LCD-3.5-IPS, 16 windows).
19. **Test 2 against a multi-window item.** PL-2847 is the existing regression fixture — confirm under-receipt partials still behave there with the checkbox absent.
20. **Silent clamp is gone:** enter 1,500 against 1,000 outstanding. The request carries 1,500, not a silently rewritten 1,000. Same for the quick-fill buttons.
21. **FIFO slices:** a variance confirm that allocates across two PO lines writes two `Receipts` rows, both `VarianceAccepted = 1`, exactly one carrying `VarianceQty`. Reversing *either* row clears `IsClosed`.
22. One named test per outstanding query (2c list, items 1-5) proving each honours `IsClosed = 0`.
23. Existing rows before the migration: `VarianceAccepted = 0`, `IsClosed = 0`, no behaviour change.

Reproduce the current blocking behaviour live before changing it, so the before/after is confirmed on real data rather than assumed.

---

## 9. Out of scope

- Re-opening a closed line.
- Over-receipt caps or tolerance percentages.
- Restricting who may accept variance (see open question below).
- Any change to the signature/close flow or the DN tab filter rule.
