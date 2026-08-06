# db/047 Accept Variance — status

**Branch:** `feat/digital-signature` (no feature branch cut yet — production
is built from this branch plus what is now baselined in `def8f2e`).
**Last updated:** 2026-08-06.

## Done

- **Stage 1 baseline.** `def8f2e` + tag `prod-2026-07-30` records the
  working tree that is live in production (302 files). `f6a9a4c` adds
  `db/BASELINE_NOTES.md` — the tag excludes `secrets-backup.txt`
  (live credentials, never committed in any history, now gitignored).
  Full backup: `C:\dev\receivx-backup-2026-08-06-2010.zip` (177.7 MB).
- **`db/probe-migrations.sql`** (`4fb79d6`) — read-only migration-state probe.
  Prod run confirmed: 047 free, both 040s live, 041a NOT applied, nothing
  unexplained on prod.
- **`db/041_vw_transactions_journal_ktf.sql` (041b, the VIEW) applied to DEV
  ONLY** — blob `e8534032047bcad4bf92fda027abfe6a88e3ec0c`. Dev was behind
  prod and threw `SqlException 207` on `GET /api/receipts/pull/{id}`.
  **041a (the backfill) was NOT run and must not be.**
- **Brief committed through rev 6** (`bd17f7b`). §2c and §2d override
  everything earlier in that document.
- **Step 0 reproductions (live, on real records).**
  - *Silent clamp:* typed 1,500 against 1,000 outstanding → preview promised
    "Will allocate 1,500" → `POST` returned 200 → DB recorded **1,000** →
    screen showed 100% complete. No error. The server would have accepted
    1,500; the client invented the limit (`receiving.js:752`).
  - *Hour cap:* `qty=1500` with `LockHourCap=true` → `409 "Insufficient hour
    capacity…"`. ProblemDetails carries **no** machine-readable code.
- **MARK ZERO characterised.** Dead control: sets input to 0, Confirm stays
  enabled, **no request is sent**, red toast "Enter a quantity / Must be
  greater than zero". Crafted `qty=0` → `400`. Has never written a row.
- **Grain evidence.** 2,049 items from a live ERP sync across 20 distinct
  hours: **every one single-window**. All 13 multi-window items are demo
  (`PL-2847`) or smoke fixtures.
- **`CK_PIW_Caps` does not exist** — defined in `db/001:237`, dropped by
  `db/010:125-136`. Nothing to relax. The `ReceivedQty >= 0` floor went with
  it, so the service layer is the only thing preventing a negative.

- **Brief rev 7 committed** (`c0d3df3`) — adds §2e (quick-fill event bug,
  MARK ZERO characterisation) and drops the index from §4.
- **`db/047_receipt_variance_and_line_close.sql` written and APPLIED TO DEV
  ONLY.** Columns only — no index, no constraint change. Verified: all six
  columns present, 240/240 receipts backfilled `VarianceAccepted=0` +
  `VarianceQty NULL`, 50,388/50,388 windows `IsClosed=0`, `IX_PIW_Open`
  absent, both ledger CHECKs intact. Re-run is a clean no-op.
  **NOT applied to production.**

- **Service layer done** (`4c3b7f5`, `e4cd1b1`) — variance write path, FIFO-slice
  rule, `MAX(0, …)`, `IsClosed = 0` on all five queries, conditional close,
  zero-close with no `Receipts` row, multi-window guard, `CancelAsync` reopen +
  canonical lock order, error codes in `ProblemDetails.Extensions["code"]`.
- **§2f the lock stays a lock** — `LockHourCap=true` refuses over-receipt always
  (409, tick does NOT override); `LockHourCap=false` needs the tick (400
  otherwise). Short close unaffected on both. `PreviewAsync` applies the
  identical rule and returns the identical code.
- **Reopen action done** (§2d) — `POST /api/receipts/reopen`, `CanReceive`,
  reason required + audited, conditional on `IsClosed = 1`, works for any
  closed window.
- **Verified: the receive path has exactly one caller.** `ReceiveAsync` ←
  `ReceiptsApiController.cs:47` only; `IReceiptService` injected only there;
  `dbo.Receipts` written only by `ReceiptService`. No job/import/WDT/service
  writes receipts, so the §2f rule change reaches nothing but the UI.

## Not done

1. **UI** — clamp removal (`receiving.js:752`), checkbox, live variance
   readout, quick-fill `input` events (§2e), note-required styling,
   ⌘+Enter gating, reopen dialog.
2. Remaining §8 cases (23 total; the five-query, agreement, reopen and
   hour-cap suites cover a good part already).
3. `db/047` has not been run on production. Deploy order: migration first,
   then DLL, then app-pool restart. `deploy.ps1` does NOT run migrations.

## Exact next step

UI pass. Start with the clamp at `receiving.js:752` — it is the live data-loss
defect, not merely a limit.

## Smoke suite for this change

| Smoke | State |
|---|---|
| `smoke-variance-outstanding-queries` | 8 assertions, PASS |
| `smoke-variance-preview-confirm-agreement` | 20 pairs, PASS |
| `smoke-variance-reopen` | 11 assertions, PASS |
| `smoke-hourcap-6.2` (case 7 → 7a/7b) | 9 cases, PASS |
| `smoke-receiving-page-stage-b` | PASS |
| `smoke-pull-status-forward-transition` | PASS |
| `smoke-pull-close-display` | PASS |
| `smoke-pull-detail-refresh` | PASS |
| `smoke-confirm-modal` | PASS |

### Pre-existing reds, none caused by db/047

Each of these fails *before* reaching any code this change touches. Diagnosed,
not assumed:

- **`smoke-do-report`** and **`smoke-phase-14-do-multi-do`** — the DN/DO query
  gained an opt-in whitelist in **`c3c3afb`** (*"Delivery Note includes only
  'Transferred from WDT' lines"*), the tip commit of the deployed baseline. It
  keeps only receipts whose `Note` is exactly the WDT sentinel; both smokes
  create receipts without it, so the report legitimately returns zero rows and
  no `.dsv-do` element. Proof it is the fixture and not the code: the same
  preview endpoint renders **36** `.dsv-do` articles for pull `0000012949`.
  `PullRepository` is unchanged since `1d37ee6`, and `GetDoReportRowsAsync`
  never references `PullItemWindows`.
- **`smoke-pull-search`** — fails at a *login*: `swattana` is assigned to
  `WH-BPI` as supervisor, while the smoke expects `swattana@WH-02` as an
  operator. Assignment seed drift; it never reaches the search code.
- **`smoke-close-reopen`** — fails at its fixture-reset step because `PL-2843`
  does not exist. `db/035`'s Phase-14 wipe removed the `db/006` seed pulls
  (only `PL-2847` survives).

**Known pre-existing red, NOT caused by this change:** `smoke-close-reopen`
fails at its fixture-reset step because `PL-2843` does not exist — `db/035`'s
Phase-14 wipe removed the `db/006` seed pulls (only `PL-2847` survives) and
they were never re-seeded. Same family as the SUMMARY PO gap below. It is one
of the ~13 seed-gap smokes CLAUDE.md already tracks.

## Observation — four modal fields have no `id`, and nobody has missed them

**Not a defect queued for repair. Left exactly as found, deliberately.**

`Lot / Batch`, `Pallet ID`, `Bin / Location` and `QC Status` in the receive
modal carry no `id` attributes, so `confirmReceipt`'s `fieldVal()` never matches
them and they post as `null`. The evidence is unambiguous: **243 of 243
receipts** carry `NULL LotBatch`, `NULL PalletId`, `NULL BinLocation` and
`QcStatus = 'pending'`. The modal also ships hardcoded mockup values
(`LOT-2403-118`, `PLT-00482`, `A-12-03`, `Passed inspection`) that an operator
sees pre-filled.

The tempting reading is "silent data loss, same class as the clamp". **That
reading is wrong**, and the thing that settles it is not in the code:
the system has run in production for two weeks with no complaint about these
four fields. So this is not data being lost in transit — it is four fields
nobody fills in. Nothing that was ever captured is being dropped, and there is
no traceability regression, because no traceability was ever entered.

That changes the question. It is not *when do we wire these up*; it is
**whether these fields should exist at all** — which is a UI decision for the
operator to make, not a bug for an engineer to fix. Wiring them would also have
required two judgement calls that only matter if the fields stay: the `<option>`
values must become the server's tokens (`pending|passed|hold|rejected`, else
they 400 on the whitelist), and the pre-filled mockup values would have to go,
since a lot number the operator did not type is a fabricated record.

For the record, if the decision is ever to wire them, the consumer check was
done and came back clean: **nothing branches on `QcStatus`** (zero SQL
`WHERE`/`CASE`, zero C# comparisons); `transactions.css` already styles all four
badge states; the KTF export reads none of the four; the DO/DN `PalletId` comes
from `MAX(pol.PalletId)` on `PurchaseOrderLines`, not `Receipts`; and receipt
search `LIKE`s the three text columns, so real values would make search work
rather than break it.

**`m-note` is the exception and IS wired** — it had the same missing-`id` cause,
but the accept-variance flow requires a mandatory note as its audit reason, so
it is load-bearing for this change.

### Dev fixture: SUMMARY PO capacity

`db/014_seed_smoke_po_lines.sql` seeded SUMMARY purchase-order coverage in WH-01
at 50,000. `db/035_wipe_for_phase_14.sql` wiped it and db/014 was never re-run,
so the assumption stated in `smoke-hourcap-6.2.ps1`'s own header — *"db/014
already seeded SUMMARY PO coverage at 50k capacity in WH-01"* — has been false
on any database that has had db/035 applied. The symptom is misleading: a
receive that should obviously work returns *"Insufficient PO capacity. Need 100,
have 0 pcs."*, which points suspicion at the receive code rather than the
fixture.

**Fix: run `tools/seed-summary-po-capacity.ps1`.** Idempotent, tops capacity back
up to 50,000, refuses to run against anything but a local dev server. It
restores what db/014 intended and db/035 removed.

### Capacity drain — the suite has a finite number of runs

The older smokes delete their pulls and receipts on cleanup but **never restore
`PurchaseOrderLines.ReceivedQty`**. That column is a denormalised cache the
receive path increments, and deleting the receipt rows does not decrement it. So
every run permanently consumes a slice of the shared SUMMARY capacity, and after
enough runs the suite starts failing for reasons that have nothing to do with
the code under test.

Measured, not theoretical: capacity fell from 50,000 to **47,050** across this
change's smoke runs alone.

Re-run `tools/seed-summary-po-capacity.ps1` when it bites. The newer
`smoke-variance-*.ps1` smokes seed their own PO per case and drain nothing —
that is the pattern to use for new smokes. Retrofitting it to the older smokes
is deliberately **out of scope** here.

## Decisions locked (do not relitigate)

- `IsClosed` on **`dbo.PullItemWindows`**, keyed `(PullItemId, HourOfDay)` —
  `Receipts` has no `PullItemWindowId`. Guard: variance offered only when the
  `PullItem` has exactly one window; server-side `400
  MULTI_WINDOW_NOT_SUPPORTED`.
- `ClosedBy UNIQUEIDENTIFIER`, `ClosedReason NVARCHAR(1000)`.
- **Zero-close writes NO `Receipts` row.** `CK_Receipts_QtyNonZero` and
  `CK_Receipts_ReversalIntegrity` are **not** relaxed. Audit lives in the
  window's `Closed*` columns. An explicit reopen action replaces the
  reverse-the-zero-receipt path (rev 6 §2d).
- `VarianceAccepted = 1` on every FIFO slice; `VarianceQty` on exactly one.
- Error codes via `ProblemDetails.Extensions["code"]`.
- Do not consolidate the five outstanding queries; each gets its own test.
- Quick-fill buttons must dispatch a real `input` event (rev 7 §2e).

## Environment

- Dev DB `LAPTOP-CSB3KO3E` / `ReceivingOps`. user-secrets point here, **not**
  prod. Verify before any `dotnet run`.
- Dev server: `dotnet run --project src/ReceivingOps.Web --launch-profile http`
  → `:5213`. Never the `https` profile (breaks auth-redirect smokes).
- Login `sadmin` / `admin`; WH-01 = `22222222-2222-2222-2222-000000000001`.
- Receiving page takes **`?pull=<PullNumber>`**, not the GUID.
- Fixtures still in place (needed for §8): `PL-VAR-1786030621-CLAMP`
  (consumed, 1000/1000), `PL-VAR-1786030622-CAP` (1,000 outstanding,
  `LockHourCap=true`), `PO-VAR-1786031171` (10k SUMMARY capacity, WH-01).
  Clean up the `PL-VAR-*` / `PO-VAR-*` namespace at the end.
- No prod app-DB credentials, by decision. Prod checks go through
  `db/probe-migrations.sql`, run by the operator.
