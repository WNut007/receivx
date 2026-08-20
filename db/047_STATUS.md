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

- **UI done** — clamp removed and proven on the wire, variance checkbox, live
  variance readout, note-required styling, Confirm + ⌘/Ctrl+Enter gating,
  quick-fill `input` events (§2e), grid CLOSED pill, closed-state modal and
  reopen dialog (§2d), reopen round-trip verified end to end.
- **All 23 §8 cases covered.** See the suite table below.

- **Dev fixtures cleared** — `tools/clear-variance-dev-fixtures.ps1`. 89 pulls,
  8 receipts and 2 POs removed; SUMMARY capacity **47,050 → 56,300**. Dev is
  back to 243 receipts (the pre-existing history), 0 closed windows and 0
  variance receipts: the db/047 columns are present and unused, as on a fresh
  install.
- **Hangfire checked** — this machine registers against the LOCAL database
  only. See below.

## VarianceQty orphaning — found and fixed (2026-08-08)

**Symptom, captured on live records before any code changed.** Pull `0000026590`,
item `2063-810743-0E4`, hour 20, window expecting 400. A 401 with the tick allocates
`400@0000026590` (pull-linked) + `1@0000019123` (overflow), and per §2c writes
`VarianceAccepted=1` on both rows with `VarianceQty=1` on the first. Cancelling the
1-pc overflow slice left the window at exactly **400/400, IsClosed=0** — and the
surviving 400-row still carrying **VarianceQty=+1**. The ledger asserted an
over-delivery that had been reversed.

**Why it mattered more than it looked.** Nothing reads `VarianceQty` today — it
appears only on `ReceiveResult`, never in a repository query, view, journal or
export. That is why it would have gone unnoticed, not why it was tolerable. FIFO
has been able to split a confirm since v2, but the overflow change makes multi-slice
the *normal* shape of a variance receive, so a rare edge case became a daily one.

**Root cause.** `VarianceQty` describes a decision about a WINDOW ("401 arrived
against 400 outstanding") but §2c stores it on one arbitrary slice, and cancel is
scoped to a receipt ROW. Any cancel of a different slice orphans the figure.

**Fix — `ReceiptService.CancelAsync` step 8c, code only, no schema change.** The
recompute runs on EVERY cancel and restores the rule below.

### THE RULE (both clauses are the rule; the second is a boundary, not a footnote)

**1. For a window carrying at least one live `VarianceAccepted` row:**

    SUM(VarianceQty) over live rows of (PullItemId, HourOfDay)
        == SUM(QtyReceived) over those rows - window.ExpectedQty
    SIGNED — negative when short, positive when over —
    and NULL only when that difference is exactly zero.

**2. For a window where no live row carries the tick, `VarianceQty` is NULL on
every row and clause 1 does not apply.** An ordinary partial also sits below
`ExpectedQty`, but there is no accepted decision behind it and no ticked row to
carry one. Stamping the difference on a plain row would manufacture a variance
nobody recorded — every partial in the system would start reading as an accepted
one. Smoke case 11 is the guard on this clause.

`VarianceQty` measures QUANTITY. `IsClosed` records whether the line was closed.
They are independent by design: coupling them is how the column came to mean
different things in different contexts, which is the defect this removes. A window
can therefore be open and carry a non-zero figure (smoke case 9: 1 received of 400,
`IsClosed=0`, carrier holds `-399`).

"Live" = not voided (`ReversedById`) and not itself a reversal (`ReversesReceiptId`)
— the same set the window cache reconciles against. The carrier is the earliest
surviving ticked row (`ORDER BY ReceivedAt, Id`), chosen the way the receive path
chooses it.

It needs **no batch/confirm key**: the rule is a window-level aggregate, so which
surviving row carries the figure is arbitrary by construction, exactly as it was at
receive time. Seeks the existing `IX_Receipts_PullItem (PullItemId, HourOfDay)`.

It runs unconditionally rather than only when the cancelled row carried the flag,
because a plain partial sharing a window with a closed variance receipt moves the
same total and orphans the same number (smoke case 12).

**Signed rather than overage-only.** An earlier draft of this fix recorded overage
only and nulled negatives, on the argument that a short is derivable from
`ExpectedQty - live`. That was rejected: derivability is equally true of the
positive case, so it cannot justify keeping one sign and dropping the other — if it
were sufficient the column would not exist. Worse, it left the field meaning
different things before and after a cancel touched a window, with nothing in the
data to say which regime a row was in. One signed path also replaces a sign test
plus two behaviours. `ReceiveAsync` is untouched and still writes the signed figure
at receive time, so §8.5 is unaffected and the two paths now agree.

**Zero-quantity closes are unaffected.** §2d writes no `Receipts` row at all, so
`ClosedBy/ClosedAt/ClosedReason` remain their sole record.

**Lock order changed: `dbo.Pulls` now precedes `dbo.Receipts` in cancel.** Step 8c
writes SIBLING receipt rows, which were not previously in cancel's write set. With
Receipts locked first, two operators cancelling two slices of the same confirm
deadlock outright (T1 holds slice 1 and needs slice 2; T2 holds slice 2 and is queued
behind T1 on the Pulls row). Taking `dbo.Pulls` first makes that row the single
serialization point for every receive and every cancel on a pull. Cancel now
identifies its pull with an unlocked read of `PullItemId`/`HourOfDay` — immutable
columns on an append-only ledger — then locks Pulls, then re-reads the target row
under `UPDLOCK`, so the already-voided guard is still evaluated against locked state.
Guard *precedence* is unchanged; only the reads moved.

**Coverage** — `smoke-po-overflow-variance` cases 8–13, all PASS:

| Case | Asserts |
|---|---|
| 8  | 401 → cancel overflow slice → window 400/400, IsClosed=0, difference exactly zero → SUM(VarianceQty) NULL |
| 9  | 401 → cancel pull-linked slice → live 1 of 400, IsClosed=0, carrier restated to **−399** on an OPEN window |
| 10 | 1,200 across 3 slices → cancel middle → positive figure RESTATED 800 → **400** on a surviving row |
| 11 | Non-variance 2-slice receive → cancel one → VarianceQty NULL throughout (clause 2: 8c inert where nothing was ticked) |
| 12 | Plain sibling of a short close cancelled → window stays CLOSED, stale −100 restated to **−200** |
| 13 | Short close (300 of 400, ticked) split across 2 lines → cancel the NON-carrier slice → carrier re-picked among survivors, value `live − 400`, negative, exactly 1 row carries it |

Cases 8–13 assert the rule itself (`live qty − expected`), not hardcoded numbers,
and each checks the **count** of rows carrying a non-NULL `VarianceQty` as well as
the SUM — a SUM that is right while two rows each carry half of it would satisfy the
arithmetic and still be the bug.

Case 12 is the one that would have been hardest to question in the field: a closed
window reading "100 short" while actually 200 short of 400. Nothing in the UI
contradicts it.

## Separate defect, LOGGED AND LEFT: cancel demotes the pull on status alone

Observed in the same capture: after cancelling the 1-pc overflow slice the window
sits at 400/400 with **zero** outstanding windows, yet the pull drops from
`fully_received` to **`in_progress`**.

`CancelAsync` step 9 is `Status = CASE WHEN Status = 'fully_received' THEN
'in_progress' ELSE Status END` — it demotes on the STATUS ALONE. `ReceiveAsync`
step 7 recomputes from `NOT EXISTS (outstanding window)`; cancel never grew the
matching recompute when the Pull `0000009383` fix added it to the receive side.

**It is separate, not a consequence of row-scoped cancel.** The demote is
unconditional, so it fires identically whether the confirm wrote one row or five,
and confirm-scoped cancel would not change it. It is reachable whenever a cancel
leaves every window satisfied — i.e. when the window was over-received, or closed
short and therefore excluded from the outstanding count.

**Left alone deliberately.** Changing pull-status transitions has its own blast
radius (the pending queue, `/Reports`, the close gate) and is not what this change
is for. `smoke-po-overflow-variance` case 8 REPORTS it as a yellow `KNOWN DEFECT`
line rather than asserting it green, so the suite records the real behaviour without
blessing it; when step 9 grows the recompute that line turns into a PASS and no
assertion has to change.

## OPEN ITEM — five db/047 smokes are documented PASS but the battery never runs them

**The claim that needs correcting is in this file.** The suite table below lists
`smoke-variance-section8`, `smoke-variance-outstanding-queries`,
`smoke-variance-preview-confirm-agreement`, `smoke-variance-reopen` and the 7a/7b
split in `smoke-hourcap-6.2` as PASS. They do pass — **by hand**. None of them is in
the default battery in `tools/run-smokes.ps1`, so no suite run has ever executed
them. `smoke-po-overflow-variance` was in the same position until this change wired
it in; the other five were deliberately left out of that commit to keep its scope
honest.

That is the same failure shape as a health check that reports healthy without
running: a guard exists, a document asserts it is green, and nothing executes it.
The gap is found by reading the battery file, or by a 500 in production. Treat it as
higher priority than a documentation tidy-up.

**To close it:** add the five to the battery list, run the suite, and reconcile the
result against the table below — some may need fixture work to survive battery load
(shared SUMMARY capacity, Hangfire contention), which is precisely the information a
by-hand run does not give you. Until then, read every PASS in that table as
"passes standalone", not "passes in CI".

## MIGRATION LEDGER — production

**This repo has no migration ledger table or tool. This section IS the ledger.**
Nothing else records what has been applied to production. Treat an entry here as
the authoritative answer to "is this migration live?", and update it in the same
commit as any migration that ships.

Deploy order for every migration in this family: **migration first, then DLL, then
app-pool restart.** `deploy.ps1` does NOT run migrations, and its auto-rollback
restores the DLL, not the schema. On 2026-08-07 a DLL went out against an
unmigrated schema and `/api/pulls` returned 500 on `Invalid column name 'IsClosed'`
until the migration was run by hand.

| Migration | Production | Verified |
|---|---|---|
| `db/047_receipt_variance_and_line_close.sql` | **APPLIED 2026-08-07** | All six columns confirmed via `COL_LENGTH` from SSMS: `IsClosed`, `ClosedAt`, `ClosedBy`, `ClosedReason` on `dbo.PullItemWindows`; `VarianceAccepted`, `VarianceQty` on `dbo.Receipts`. `ClosedBy` is `uniqueidentifier`, `ClosedReason` is `nvarchar(1000)` — production matches the file as committed. |
| `db/048_lockhourcap_default_unlocked.sql` | **NOT APPLIED** — dev only | Re-points `DF_Pulls_LockHourCap` from `((1))` to `((0))`. Deliberately not shipped: the default was never what produced locked pulls (see the db/048 section below), so applying it alone changes nothing and the three application sites are the real decision. |
| `db/049_pull_item_windows_variance_reason_code.sql` | **APPLIED 2026-08-08 17:01 ICT** | `COL_LENGTH('dbo.PullItemWindows','VarianceReasonCode')` returns **64** (bytes; `NVARCHAR(32)` × 2). Post-check reported the column present, nullable and unconstrained, with the db/047 columns intact. Applied ahead of the DLL per §7 — the column is nullable with no default, so the then-live build was unaffected. |

An earlier revision of this section claimed db/047 had **not** been run on
production. That was stale from 2026-08-06 and wrong from 2026-08-07 onward; the
PO-overflow work has been live and reading those columns since. Corrected
2026-08-08 against SSMS. The staleness is recorded rather than quietly overwritten,
because a "not done" entry that is actually done is the same failure shape as the
outage above — and it survived precisely because nothing forced this file to be
touched when the migration ran.

## Not done

1. **`db/probe-hangfire-workers.sql` has not been run on production.** It is
   read-only and answers whether any machine other than the prod web host is
   registered as a Hangfire worker there.

## db/048 — LockHourCap default, and why it changes nothing on its own

`db/048_lockhourcap_default_unlocked.sql` re-points `DF_Pulls_LockHourCap` from
`((1))` to `((0))`. **Applied to dev only. No existing row was touched** — the
split is identical before and after: **11,621 locked / 40 unlocked / 11,661
total**.

**The default was never what produced locked pulls.** Every insert path writes
the column explicitly, so the default never fired. Demonstrated rather than
inferred, after applying db/048:

| Path | Result |
|---|---|
| Raw `INSERT` omitting the column | `LockHourCap = 0` ← the new default works |
| `POST /api/pulls` omitting `lockHourCap` | **`LockHourCap = 1`** ← still locked |

The three sites that actually decide it:

1. `Services/ErpSync/ErpUpsertService.cs:189` — hardcoded literal `1, 1` for
   `LockPoByPull, LockHourCap`. Nearly every pull in the system comes from here.
2. `Services/PullAdminService.cs:49,54` — writes `req.LockHourCap`, and
   `Models/Dtos/PullDtos.cs:229` declares `= true`, so omitting the field still
   yields a locked pull.
3. `wwwroot/js/dashboard.js:123` — `s.lockHourCap === undefined ? true : …`,
   the same true-by-default a third time.

So db/048 is necessary but not sufficient. Changing what NEW pulls get means
changing those three sites, which is an application decision, not a schema one.

**How much the hour cap currently expresses:** 11,588 of the 11,594 open pulls
with outstanding work are locked. Six are not, and those six are fixtures this
work created. Existing locked pulls are left locked — unlocking them is the
operator's call and has not been made.

## Hangfire: this machine is not a production worker

Hangfire storage is `ConnectionStrings:Default` (`Program.cs:322-332`) — the
same database as the app, with no separate credential. So a worker registers
wherever that connection string points.

Verified on this machine:

- No `ConnectionStrings__Default` environment override; `appsettings.json`
  contains no server; the effective value is the user-secret, which is
  `Server=LAPTOP-CSB3KO3E` with integrated security.
- `HangFire.Server` in the **local** database holds exactly one row,
  `laptop-csb3ko3e:14472:…`, heartbeating live — and PID 14472 is the only
  `ReceivingOps.Web` process running, from `bin\Debug\net8.0`.
- No IIS (`C:\Programs` absent, no `W3SVC`), no Windows service and no
  scheduled task referencing the app. There is no second instance that could
  hold a different connection string.

So the dev build carrying variance code, against a dev database carrying
db/047, is confined to the local database.

**The production side still needs checking, and only the operator can do it.**
`RECEIVINGOPS_HARDENING.md` records that on 2026-07-16 this machine's
user-secret pointed at the production host; any `dotnet run` in that window
would have registered the laptop in production's `HangFire.Server` and let it
execute production jobs. Hangfire's ServerWatchdog sweeps lapsed heartbeats, so
a stale row has probably gone — but "probably" is not a check. Run
`db/probe-hangfire-workers.sql` on production: any `MachineName` that is not
the production web host is the finding, and `*** LIVE NOW ***` means it is
still taking jobs.

## The capacity drain, now measured exactly

`PurchaseOrderLines.ReceivedQty` is a cache the receive path increments, and
deleting a receipt does not decrement it. Every smoke that tears down its own
receipts therefore leaks a little capacity permanently.

Measured at cleanup time: **5 PO lines overstated consumption by 17,550 units**,
and all five were fixture-capacity lines (`PO-SEED-SUMMARY-*`, `PO-VAR-*`) —
i.e. the leak came entirely from this change's own test runs, not from real
data. `clear-variance-dev-fixtures.ps1` restores what the fixtures consumed
*and* reconciles those fixture lines set-from-truth against
`SUM(Receipts.QtyReceived)`, the same technique `db/038` used. After it,
**zero** PO lines in the whole database disagree with the ledger and none is
negative.

## Exact next step

Ship review, then the production run of `db/047` followed by the DLL.

## Smoke suite for this change

**Read "PASS" in this table as "passes standalone".** Only
`smoke-po-overflow-variance` is in the default battery — see the open item above.

| Smoke | State |
|---|---|
| `smoke-variance-section8` | 29 assertions, PASS |
| `smoke-variance-outstanding-queries` | 8 assertions, PASS |
| `smoke-variance-preview-confirm-agreement` | 20 pairs, PASS |
| `smoke-variance-reopen` | 11 assertions, PASS |
| `smoke-hourcap-6.2` (case 7 → 7a/7b) | 9 cases, PASS |
| `smoke-po-overflow-variance` | 13 cases (8–13 new: the VarianceQty recompute), PASS |
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

#### ADDENDUM — recorded 2026-08-20. A second leak this section does not cover.

The paragraph above is correct as written, and measurement confirms its
mechanism: `smoke-variance-outstanding-queries.ps1` and the DO-report smokes do
delete their receipts and never restore `PurchaseOrderLines.ReceivedQty`.

What it does not cover is that **the pulls, items and windows are not deleted
either**, and have not been since `db/042`.

`db/042` added `dbo.PullSignatures` with `FK_PullSig_Pull` as `NO_ACTION`, where
`FK_PullItems_Pull` is `CASCADE`. A pull closed with a signature cannot be
deleted until its signature row goes first, and no cleanup does that. The
cleanups delete by `LIKE` in one set-based statement, so a single signed pull
refuses the whole range and takes the unsigned rows with it. The receipt DELETE
that runs first has no such blocker, which is why the receipts DO go and the
pulls do not — and why the leak this section describes is real while the rows
themselves quietly accumulate behind it.

Measured 2026-08-20 before the purge: **148 stranded pulls** — 130 `PL-VQ-%`
(oldest 2026-08-06, only 26 actually signed) and 18 `PL-DOR-%` (oldest
2026-07-16, all 18 signed) — carrying 226 items and 244 windows. 218 of those
windows still hold `ReceivedQty > 0` totalling 67,740 units against receipts
that no longer exist, which is this section's drain made visible: the caches
were never decremented and now have no ledger rows behind them at all.

The failure was invisible because every cleanup ends `2>&1 | Out-Null`, which
sends the SQL error to the same place as the success output. The smoke prints
its cleanup step and reports ALL PASS.

An earlier draft of this addendum claimed the receipts were never deleted
either. That was wrong — corrected the same day, before the purge, against the
counts above.

Full account: `docs/defect-pull-signature-fk-blocks-smoke-cleanup.md`.
The rule this violates: `docs/smoke-conventions.md` §2.

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
