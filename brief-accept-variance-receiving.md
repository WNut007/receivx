# Brief: Accept Variance on Goods Receipt

**System:** ReceivingOps, post-v3.5 on `feat/digital-signature` (.NET 8, Dapper, SQL Server)
**Revision:** rev 11. Decisions live in sections 2b–2g and override anything earlier in this document. Latest change: section 2f reverses the LockHourCap rule — over-receipt is now permitted on every pull with the final-receipt checkbox ticked.
**Screen:** "Receive Goods" modal (quantity entry against a scheduled pull slot)
**Type:** Schema change + service layer + API + UI

---

## 1. Goal

Today the receipt modal hard-caps the quantity at the outstanding amount and refuses anything above it ("MAXIMUM ALLOWED: N PCS. CANNOT RECEIVE OVER EXPECTED"). Real deliveries arrive short or over, and the operator currently has no way to record what actually turned up or to stop the line from sitting in the pending queue forever.

Change it so that:

1. The operator may enter **any** quantity, including above outstanding.
2. **Partial receipts behave exactly as they do today.** Entering less than outstanding without ticking anything records a partial and leaves the line open for the next delivery — no alert, no checkbox involvement. This is normal daily use and must not regress.
3. When the operator is on the **final** receipt for a SKU and the total will not reach expected, an **Accept variance** checkbox lets them close the line at the actual figure instead of leaving a permanent remainder.
4. Over-receipt is only possible with the checkbox ticked, **on every pull regardless of `LockHourCap`** — see section 2f. There is no coherent "more coming later" reading of an over-delivery, so over is always terminal. Unticked over-receipt is blocked with the alert.
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

Reproduced live 2026-08-06: entering 1,500 against 1,000 outstanding with `LockHourCap = false` and 10,000 PO headroom returned `200`, wrote `QtyReceived = 1000`, and rendered the line as 100% complete. The server would have accepted 1,500 — nothing server-side rejected it. The client invented the limit.

**Preview and confirm must agree.** `GET /api/receipts/preview` returned `200` and the panel promised "Will allocate: 1,500" one screen before confirm silently wrote 1,000. After this change, any quantity preview accepts must be the quantity confirm writes, and any quantity confirm would refuse must be refused by preview with the same reason. A preview that promises more than confirm delivers is the same defect wearing a different hat. Add a test asserting preview and confirm agree at: below outstanding, exactly outstanding, and above outstanding both with and without the variance flag.

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

## 2d. Zero-quantity close: DECIDED — no receipt row

`CK_Receipts_QtyNonZero` (`QtyReceived <> 0`) and `CK_Receipts_ReversalIntegrity` forbid zero-quantity receipts. **Do not relax either one.** `Receipts` is an append-only ledger where a row means goods moved; a zero row means nothing moved, and weakening that invariant for the whole table to serve one UI affordance is the wrong trade.

Earlier revisions of this brief called the zero-quantity receipt row "the audit record of who closed the line and why". That was written before `PullItemWindows` gained `ClosedBy` / `ClosedAt` / `ClosedReason`. The audit record now lives there. The zero receipt row adds nothing.

**Close-only path.** A confirm with `Qty = 0` and `VarianceAccepted = true` writes **no** `Receipts` row. It sets `IsClosed = 1`, `ClosedAt`, `ClosedBy`, `ClosedReason` on the window, via the same conditional `WHERE IsClosed = 0` update and the same mandatory note, and writes an audit entry. Nothing else changes. `PullItemWindows.ReceivedQty` is not touched.

Note what this removes: the `-0` reversal problem disappears entirely. `CancelAsync` would have inserted `NegQty = -0 = 0` against a branch requiring `QtyReceived < 0`. That edge case was manufactured by the design choice, not inherent to the requirement — which is the clearest sign the choice was wrong.

**Reopen action.** Because a zero-close leaves no receipt to reverse, add an explicit reopen:

- Clears `IsClosed`, `ClosedAt`, `ClosedBy`, `ClosedReason` on the window.
- Same permission as receiving (`CanReceive`), same warehouse check as `CancelAsync`.
- Requires a reason, written to audit. Reopening is a correction and must be attributable.
- Same conditional-update discipline: `WHERE PullItemId = @p AND HourOfDay = @h AND IsClosed = 1`, rowcount 0 → `409`.
- Available for **any** closed window, not only zero-closed ones. A line closed by a short receipt can also be reopened this way; reversing the receipt remains the other route and must stay working.
- Follows the canonical lock order from section 2c.

Keep it minimal: one endpoint, one confirm dialog with a reason box. No bulk reopen, no reopen from list views, no separate admin screen.

### Reopen UI — placement

**In the existing receive modal, not a new surface.** Clicking a closed window already opens that modal; it should open in a closed state rather than being blocked or showing a quantity field that cannot be used.

Closed-state modal:

- Replace the quantity entry block with a closed banner: who closed it, when, and the close reason verbatim. The reason is the whole point of having stored it — show it in full, do not truncate it to a tooltip.
- Show the final figures plainly — expected, received, and the variance — so it is obvious the line closed short or over rather than complete.
- A single **Reopen line** button. No quantity controls, no checkbox, no note field in this state.
- Reopen opens a confirm dialog with a required reason box and a short line stating that the line returns to the pending queue at its previous outstanding. Empty reason → the button stays disabled; the server also refuses with `400 REOPEN_REASON_REQUIRED`.
- On success the modal returns to its normal receive state with outstanding restored, without a page reload.

**The list must show closed lines as closed.** A short-closed window reads `400 / 1,000` in the grid, which looks identical to a pending partial. Without a distinct closed pill an operator cannot tell a line that is finished from one still waiting for a truck — and that confusion is the thing this whole change exists to remove. Use a pill distinct from both the complete and pending states, and make a closed row's variance visible rather than styling it as an error.

Same `CanReceive` permission as receiving; do not invent a new one.

---

## 2e. The quick-fill buttons don't tell the preview

`receiving.js:739-741` sets `input.value` directly for FILL OUTSTANDING, ½ OUTSTANDING and MARK ZERO, without dispatching an `input` event. The debounced preview at `:704-728` therefore never re-runs, so after clicking a quick-fill button:

- the allocation panel keeps advertising the previous quantity (observed: input reading 0 while the panel promised "Will allocate: 1,000")
- the cap hint snaps back to the "Cannot receive over expected" copy that section 7 requires removing

This is the same defect class as the silent clamp: the screen states one thing and the system does another. Fix it by dispatching a real `input` event from all three buttons so the preview and hint recompute, and cover it in the preview/confirm agreement test from section 2c.

**MARK ZERO characterised (2026-08-06):** it has always been a dead control. `:741` sets 0, `:753` rejects `qty <= 0` and returns before the fetch, so no request is ever sent and the operator gets a red toast telling them the button's own output is invalid. Server-side agrees independently — a crafted `qty=0` POST returns `400 "Quantity must be positive"` (`ReceiptService.cs:220`). Under section 2d the button finally does something; that server-side guard needs the close-only path carved out of it.

---

## 2f. LockHourCap: REVERSED — the tick is the escape, on every pull

**This section replaces an earlier rule that made the lock absolute. That rule is withdrawn.**

Over-receipt is permitted on **any** pull, locked or not, and **only** with the final-receipt checkbox ticked and a note supplied. `LockHourCap` no longer changes the outcome of a receive.

| Case | Result |
| --- | --- |
| Over, unticked | `400 OVER_RECEIPT_NOT_ACCEPTED`, on locked and unlocked pulls alike |
| Over, ticked + note | Recorded at the entered figure, line closes, `VarianceQty` positive |
| Under / exact | Unchanged. The lock never constrained these |

### Why this reverses the earlier decision

The earlier rule argued that letting a tick bypass the lock would retire a shipped feature, and that a lock must mean what it says. That reasoning rested on an assumption never checked: that someone had deliberately locked those pulls.

The numbers say otherwise. **11,588 of the 11,594 open pulls with outstanding work are locked**, and the six that are not are fixtures created by this work. `ErpUpsertService.cs:189` writes a hardcoded `1` — not a parameter, not a default, not an upstream flag. `PullAdminService` and `dashboard.js:123` assert `true` a second and third time. Nobody ever chose per pull. The earlier rule was protecting an intent that does not exist.

A flag true on every row is not a control, it is a constant. Preserving it meant the over-receipt path this whole change exists to build would have been unreachable on live data — working in theory and never once in practice.

**Why not simply unlock everything instead:** unlocking would let over-receipt happen silently, with no acknowledgement and no reason recorded. That is the clamp defect inverted — the system accepting a figure nobody consciously approved. Requiring the tick keeps every over-receipt deliberate and attributable, which is worth more than the cap was.

### Consequences to handle, not to discover later

- **`LockHourCap` becomes inert on the receive path.** Before declaring that, confirm what `dashboard.js:123` uses it for and whether anything else reads it. If it drives other behaviour, that behaviour is unaffected — but say so explicitly rather than leaving it implied.
- **`smoke-hourcap-6.2` cases 2, 4 and 8 will fail again.** They assert `409` for locked over-receipts. Update them. This is a rule change made deliberately with the numbers in hand, so rewriting the assertions is correct here — unlike the earlier case where a failing test was signalling an unnoticed collision. Record in the file header which decision changed and why.
- **The lock marker copy in the modal is now false.** "HOUR CAP LOCKED · CANNOT RECEIVE OVER 1,000" no longer describes what happens. Replace it on both pull types with copy stating that over is possible with the final-receipt box, and keep the hour figure visible as context.
- **Preview must match**, as always.
- **db/048 is no longer on the critical path.** It remains correct and can ship whenever convenient, but nothing here depends on it.

## 2g. Four more unwired fields — same defect class as the clamp

`m-lot`, `m-pallet`, `m-bin` and `m-qc` carry no `id` attributes, so `fieldVal()` never matches them and every value posts as `null`. Evidence, not inference: **243 of 243 receipts** carry `NULL LotBatch`, `NULL PalletId`, `NULL BinLocation` and `QcStatus = 'pending'`.

The operator sees `LOT-2403-118`, `PLT-00482`, `A-12-03` and `Passed inspection` sitting pre-filled in the modal and reasonably believes they were recorded. None ever were. For a warehouse this is heavier than a quantity discrepancy: there is no lot traceability anywhere in the receipt history, so a recall has nothing to trace.

**In scope for this change**, because it is four `id` attributes in the same modal currently under test, and shipping a screen we know lies about four more fields is not defensible.

Two conditions before wiring them:

1. **Check the consumers first.** These columns have only ever held `NULL` and `'pending'`. Confirm that exports, the DN/DO path, the KTF export and any report handle real values — and specifically that nothing branches on `QcStatus = 'pending'` in a way that changes behaviour once other values appear.
2. **Prove it on the wire**, the same way the clamp was proved: record the payload before and after, showing the four values actually reaching the server, and confirm they land in the columns rather than being accepted and dropped.

The note field (`m-note`) was unwired by the same cause and is already fixed — variance requires it.

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
| `ClosedBy` | `UNIQUEIDENTIFIER NULL` | Matches `Pulls.ClosedBy` / `Receipts.ReceivedBy`, and is exactly what `ReceiptService.CurrentUserId()` returns. `PullItemWindows` has no audit columns of its own — an earlier revision of this brief claimed otherwise and was wrong |
| `ClosedReason` | `NVARCHAR(1000) NULL` | Copied from `Receipts.Note`, which is `NVARCHAR(1000)`. At 500 a 1,000-character note either throws on close or silently truncates the one thing this column exists to preserve |

`IsClosed` is required — it cannot be derived. An under-receipt leaves `Expected - Received > 0`, so arithmetic alone will keep showing the line as pending forever. That is precisely the bug this change exists to fix.

Add a filtered index if the pending-lines query is hot:
**No index in db/047.** An earlier revision called for a filtered `IX_PIW_Open`. Dropped, for three reasons:

- `UQ_PIW_Hour (PullItemId, HourOfDay)` already leads on `PullItemId`, so the only thing gained is the `INCLUDE` and the filter.
- The table holds ~48,000 rows. Nothing suggests any of the five queries is slow, and this brief's own wording was "add a filtered index **if** the pending-lines query is hot".
- A filtered index imposes SET-option requirements on every subsequent `INSERT`/`UPDATE` against the table. `SqlClient` satisfies them by default, but the ERP sync also writes `PullItemWindows`, and a mismatch there breaks sync on production.

db/047 is therefore **columns only** — the safest shape a migration can take. Revisit the index when a query is measurably slow; it can be added `ONLINE` at any time without touching the DLL.

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

**Already-closed lines are read-only.** Attempting to receive against a line where `IsClosed = 1` returns `409 Conflict`. Re-opening is handled by the explicit reopen action in section 2d, not by receiving.

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
| `Qty > Outstanding` and `VarianceAccepted == false` | `400`, error code `OVER_RECEIPT_NOT_ACCEPTED`, message naming outstanding and entered figures. Applies on locked and unlocked pulls alike — see section 2f |
| `VarianceAccepted == true` and note is null/whitespace | `400`, error code `VARIANCE_REASON_REQUIRED` |
| `VarianceAccepted == true` and `Qty == Outstanding` | Accept, but ignore the flag — persist `VarianceAccepted = 0`. The line closes through the existing full-receipt path, not the variance path |
| `Qty == 0` and `VarianceAccepted == false` | `400` — a zero-quantity partial records nothing |
| `Qty == 0` and `VarianceAccepted == true` | Close-only path — see section 2d. **No `Receipts` row is written.** |

The asymmetry is deliberate: **under is ambiguous, over is not.** An under-entry could mean "the rest arrives Thursday" or "this is all we're getting" — the checkbox is what disambiguates, so it must stay optional there. An over-entry has only one meaning, so the tick is mandatory.

`Qty = 0` with the box ticked closes the line without writing a receipt. See section 2d.

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

**Recovery path.** If the operator forgets to tick on the final short receipt, the line sits open at 1,000 outstanding. To close it afterwards they reopen the modal, enter 0, tick, and give a note. This takes the close-only path in section 2d — no receipt row is written; the audit record lives in the window's `ClosedBy` / `ClosedAt` / `ClosedReason`.

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
> The line closes at the quantity entered and leaves the pending queue. It can be reopened later with a reason.

Earlier revisions ended that copy with "This cannot be undone." Section 2d's reopen action makes that false, and shipping a fresh lie on the screen while removing three others would be its own kind of failure. Do not restore the sentence.

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

**Quick buttons.** FILL OUTSTANDING / ½ OUTSTANDING / MARK ZERO stay. ½ OUTSTANDING produces a normal partial and must **not** force the checkbox. MARK ZERO produces qty 0, which requires the tick plus a note and routes to the close-only path.

**First, find out what MARK ZERO does today.** Zero of 240 existing receipts have `QtyReceived = 0`, and `CK_Receipts_QtyNonZero` forbids it — so the button has never successfully recorded anything. Establish its current behaviour (silent failure? disabled Confirm? a 500?) and report it before redesigning around it.

**Keyboard.** ⌘+Enter must obey the same gating as the button. It must not bypass validation.

---

## 8. Regression tests

Cover each of these:

1. Qty == outstanding, checkbox hidden → saves, line completes through the existing full-receipt path.
2. **Qty < outstanding, unticked → saves as a partial, line stays open, remaining outstanding correct, no alert.** This is the regression that matters most; run it first.
3. Two sequential partials that together equal expected → line completes normally, `IsClosed` untouched by the variance path.
4. **Full sequence 3,000 → 1,000 → 1,500 against expected 5,000.** First two save unticked as partials; the third has Confirm disabled until ticked, then closes the line with `VarianceQty = +500` and total received 5,500.
5. **Full sequence 3,000 → 1,000 against expected 5,000, second receipt ticked** → line closed, `VarianceQty = −1,000`, total received 4,000, line gone from the pending queue. Re-run with the second receipt unticked → line stays open at 1,000 outstanding.
6. **Recovery:** on that open 1,000, submit qty 0 ticked with a note → line closes via the close-only path, **no `Receipts` row is created**, and the window carries `ClosedBy` / `ClosedAt` / `ClosedReason`.
7. Qty < outstanding, ticked, note filled → saves, line `IsClosed = 1`, disappears from the pending queue, remaining quantity written off.
8. Qty > outstanding, unticked → Confirm disabled; API returns `400 OVER_RECEIPT_NOT_ACCEPTED` when called directly.
9. Qty > outstanding, ticked, note filled → saves, outstanding reads 0 (never negative), line closed.
10. Qty = 0, ticked, note filled → line closed with no receipt row. Assert `SELECT COUNT(*) FROM Receipts WHERE QtyReceived = 0` is still zero afterwards.
10b. **Reopen:** a zero-closed line is reopened via the section 2d action → `IsClosed` and all three `Closed*` columns cleared, outstanding restored, line back in the pending queue, audit row written.
10c. **Ledger constraints untouched:** `CK_Receipts_QtyNonZero` and `CK_Receipts_ReversalIntegrity` have the same definitions after db/047 as before it.
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

- Bulk reopen, or reopening from any surface other than the modal.
- Over-receipt caps or tolerance percentages.
- Restricting who may accept variance (see open question below).
- Any change to the signature/close flow or the DN tab filter rule.
