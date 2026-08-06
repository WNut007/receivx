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

## Not done

1. Commit brief **rev 7** (adds §2e: quick-fill event bug + MARK ZERO).
2. **Revise `db/047`** — delete `IX_PIW_Open` and the whole `EngineEdition`
   branch (rev 7 §4: not hot, and a filtered index imposes SET-option
   requirements on every later write to a table the ERP sync also writes).
   Keep the column post-conditions and the assertion that both ledger CHECKs
   still exist. **Then run it on DEV ONLY.**
3. Service → API → UI → tests (§8, 23 cases). Not started.

## Exact next step

Read `brief-accept-variance-receiving_ver_7.md` §2e, commit rev 7, strip the
index from `db/047`, run on dev, report the six columns.

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
