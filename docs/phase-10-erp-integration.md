# Phase 10 — ERP Integration (PULL / ETL design)

Status: **SHIPPED at v3.0 (2026-05-26).**
Spec source: design conversations on 2026-05-25; this doc supersedes
the earlier PUSH design that lived at this path through v2.3.x.

> **Operators + ops:** the day-to-day usage guide is
> `docs/erp-integration.md` (architecture, configuration, status
> page, audit drill-down, troubleshooting). That doc is the one to
> bookmark — this one captures the design + open questions that
> drove the implementation, and stays for archaeology.
>
> **Deploy:** see `docs/deployment.md` §7 "Phase 10 ERP-integration
> deploy blockers" — `ErpDb:ConnectionString` set, ERP user
> read-only, "Pocket" placeholder rotated, firewall/VPN open, etc.
>
> **What landed for v3.0:** all sub-phases 10.1 through 10.8.
> Battery 49/49 PASS. See `CHANGELOG.md` `[3.0.0]` entry for the
> full change list.

> **History note (2026-05-25):** Phase 10 was originally specced as
> a PUSH integration (ERP POSTs to `/api/erp/pos`, `X-ERP-Api-Key`
> auth, payload upsert). That design was abandoned mid-planning in
> favor of PULL — the ERP team's roadmap couldn't commit to the
> push side in our timeframe, and a one-sided pull lets Receivx own
> the schedule and the failure handling without external dependency.
> The PUSH variant is preserved in git history at tag `v2.3.2`'s
> commit of this file if it's ever needed as a v3.1+ option.

---

## 1. Goal

Receivx **pulls** PullSheet data from the ERP system's SQL database
on a recurring schedule, transforms it into Receivx's `Pulls` /
`PullItems` / `PullItemWindows` shape, and upserts. The ERP is the
source of truth for the planning side (what was ordered, when, by
whom). Receivx remains the source of truth for the operational side
(what was actually received, by whom, when, signature-of-record).

Phase 9 (v2.3) already added 20 ERP-sourced nullable columns to
`PurchaseOrderLines`, but **PO lines are out of scope for Phase 10**.
Phase 11 will wire the PO-line ETL once the PullSheet path is proven
in production.

---

## 2. ETL pipeline

### 2.1 Data source

| Field | Value |
|---|---|
| ERP DB host | `103.13.229.21` |
| Source table | `BPI_PRS` (PullSheet header + lines, single denormalized table) |
| Authn | SQL login, read-only role, credentials in `dotnet user-secrets` |
| Network | direct from prod host (firewall / VPN to be confirmed) |

### 2.2 Schedule + trigger

- **Hangfire recurring job**, hourly by default. Cron expression
  lives in `appsettings.json` so ops can tune cadence without
  redeploying.
- **Manual "Sync now" button** on the admin-only sync status page
  (see §3) for operator-on-demand refresh.
- Both paths route through the same `ErpSyncService` so behavior is
  identical.

### 2.3 Concurrency

- Hangfire's `[DisableConcurrentExecution(timeoutSeconds: 600)]`
  attribute on the job method prevents two scheduled runs from
  overlapping if one stalls.
- The manual-trigger endpoint takes an app-level mutex (`SemaphoreSlim`
  with `WaitAsync(0)` timeout) so a click while the recurring is
  mid-run returns 409 "Sync already in progress" rather than racing.
- The two protections are belt-and-braces: the attribute covers the
  recurring path, the semaphore covers the manual path, and either
  can detect the other in flight.

### 2.4 Transformation

For each `BPI_PRS` row Receivx receives:

| BPI_PRS column | Receivx destination | Notes |
|---|---|---|
| `PRS_ID` | `Pulls.PullNumber` | Unique business key + idempotency match |
| `WAREHOUSE_CODE` | `Pulls.WarehouseId` | Lookup `Warehouses.Code` → Guid; reject row if not found |
| `PULL_DATE` | `Pulls.PullDate` | DATE; ETL assumes ICT input → store as UTC midnight |
| `ITEM_CODE` | `PullItems.ItemCode` | Composite key with PullId |
| `EXPECTED_QTY` | `PullItemWindows.ExpectedQty` | Whole units; reject if ≤0 |
| `HOUR_OF_DAY` | `PullItemWindows.HourOfDay` | 0..23; reject otherwise |
| ...remaining BPI_PRS columns | TBD — finalize during 10.2 | |

Exact column list is dependent on the live `BPI_PRS` schema —
finalize the mapping at the start of 10.2 by running `INFORMATION_SCHEMA`
against the source DB. (Per the
`feedback_check_existing_schema` memory: always query first, never
assume.)

### 2.5 Upsert semantics

- Match on `Pulls.PullNumber = BPI_PRS.PRS_ID`.
- New pulls: INSERT with `Status = 'pending'`,
  `LockHourCap = true`, `LockPoByPull = true` (project defaults).
- Existing pulls in `pending` / `in_progress`: UPDATE planning fields
  (ItemCount, window expectations) but never touch
  `ReceivedQty`, `Receipts`, `LockPoByPull`, `LockHourCap`,
  `SignatureSvg`, `ClosedAt`, `ClosedBy` — those are
  Receivx-managed.
- **Closed-pull protection**: pulls with `Status = 'closed'` are
  skipped entirely. The ERP cannot retroactively revise a signed
  pull. The skip is audited with the PRS_ID + the differing fields
  so ops can see what the ERP wanted to change.
- Items removed from the ERP side: keep the Receivx row, mark the
  item's `Status` as `canceled` (the existing v2 cancel semantic).
  Do NOT delete — receipts may reference it.

### 2.6 Audit

Every sync run writes:
- One audit row at start: `EntityType='ErpSync'`, action `'start'`,
  with the trigger source (`recurring` or `manual`) and operator
  (`system` for recurring, signed-in user for manual).
- One audit row per pull processed: `action ∈ {created, updated, skipped, error}`,
  message includes the PRS_ID + a 1-line summary.
- One audit row at end: `action='complete'` with totals
  (`{created: N, updated: N, skipped: N, errors: N, elapsed_ms: N}`).

Per-row errors do NOT abort the run — the ETL is best-effort per
pull and surfaces the error in the audit + sync-status page.

---

## 3. Sync status page

Admin-only route (e.g. `/Admin/ErpSync`). Pattern matches the
existing `/Exports` page (Phase 8.1).

- Last 50 sync runs, paginated.
- Per-run row: trigger source, started-at, elapsed, totals
  (created/updated/skipped/errors), expand-to-detail link.
- Manual "Sync now" button at the top — disabled while a sync is in
  flight; polls every 5s to re-enable.
- Next scheduled run time from Hangfire dashboard data.

Backed by a new table `dbo.ErpSyncLog` (parallel to
`ExportJobsLog`) — `Id`, `TriggeredBy`, `TriggeredByUserId NULL`,
`StartedAt`, `CompletedAt NULL`, `Created INT`, `Updated INT`,
`Skipped INT`, `Errors INT`, `ErrorDetailJson NVARCHAR(MAX) NULL`,
`Status` (`running|succeeded|failed`).

---

## 4. Authentication

ERP DB read-only login. Connection string lives in `dotnet user-secrets`:

```
ErpDb:ConnectionString = Server=103.13.229.21;Database=...;User Id=...;Password=...;TrustServerCertificate=True;
```

Production checklist (per `phase_10_pull_pivot` memory):
- Rotate the placeholder ERP password ("Pocket") to a strong one
  before any non-local deployment.
- Confirm the SQL login has only SELECT rights on `BPI_PRS` and any
  joined tables — no INSERT/UPDATE/DELETE/EXEC.
- Confirm firewall / VPN allows traffic from the prod host to
  `103.13.229.21` on the SQL port.

No application-layer authn is needed since the pull is initiated
inside Receivx — the surface area is the DB credential, not an HTTP
endpoint.

---

## 5. Open questions

To resolve before or during Phase 10.2 (most are answerable by
reading `BPI_PRS` ourselves rather than waiting on the ERP team):

1. **Exact column mapping.** Run `SELECT TOP 0 *` against `BPI_PRS`
   at the start of 10.2 to get the live schema. The mapping in §2.4
   above is approximate.
2. **Cancellation semantics.** When a pull exists in Receivx but
   not in the ERP's current `BPI_PRS` result set, is that a delete
   (skip — no longer planned) or an error (data inconsistency)?
   Recommend skip-with-audit-trail; flag as anomaly only if the
   skip rate jumps suddenly.
3. **Field-level conflict.** If an operator edits a pull field
   in-app (e.g. ETA, Notes via the drawer's Edit modal) and the
   ETL later sees a different ERP value, does ERP win or Receivx
   win? Recommend ERP wins for planning fields (PullDate, expected
   qtys), Receivx wins for operational fields (ETA, Notes — the
   operator added them deliberately).
4. **Time-zone for `PULL_DATE`.** ERP almost certainly stores
   local time (ICT); Receivx stores UTC. Confirm during 10.2
   smoke and bake the convention into `ErpSyncService`.
5. **Index design.** Deferred — wait for production query patterns
   on `Pulls.PullNumber` (UNIQUE already) + the lookup paths added
   in §2.5. The existing IX on PullNumber should suffice for the
   ETL's idempotency check.
6. **Backfill strategy.** First production run will see thousands
   of historical pulls. Decide whether to: (a) cap at `PULL_DATE
   >= today - N days` and ignore the rest, (b) backfill everything
   in one slow run, (c) backfill in batches over N hours. Lean
   toward (a) with N=30 — Receivx's audit story doesn't need
   pre-go-live pulls.

---

## 6. Performance budget

Order-of-magnitude estimates:

| Metric | Estimate |
|---|---|
| Pulls per day | ~50–200 |
| Items per pull | ~5–20 |
| Hourly ETL volume | ~5–20 new/updated pulls |
| Total daily reads | ~1,000–5,000 rows from `BPI_PRS` |
| Single-run wall clock | seconds, not minutes |

This is well within Hangfire + Dapper + a single connection's
capacity. The ETL is a `SELECT` against `BPI_PRS` + N `MERGE`s
against Receivx tables, all read/write trivial at this scale.

Load-test as part of 10.7 with 10× the expected daily volume to
confirm the manual trigger UI stays responsive while a recurring
run is in flight (the mutex protection should make this a no-op,
but verify).

---

## 7. Implementation sub-phases (~12 hr, 2-3 sessions)

| Sub-phase | Scope | Est |
|---|---|---|
| 10.1 | ERP SQL connection wiring + Hangfire recurring stub + smoke connectivity test | 1–1.5 hr |
| 10.2 | `ErpSyncService` — read `BPI_PRS` + finalize column mapping + transform to Receivx shape | 2 hr |
| 10.3 | Upsert logic for Pulls / PullItems / PullItemWindows (transactional MERGE) | 2.5 hr |
| 10.4 | Hangfire recurring registration + manual trigger endpoint (admin-only) + concurrency mutex | 1.5 hr |
| 10.5 | Field-level conflict handling + closed-pull protection + per-pull audit rows | 1 hr |
| 10.6 | Sync status page (`/Admin/ErpSync`) + `ErpSyncLog` table + pagination + auto-refresh | 2 hr |
| 10.7 | Integration smoke (battery-runnable) + load test at 10× expected volume | 1.5 hr |
| 10.8 | Docs (`docs/erp-integration.md`) + production deployment guide entry in `docs/deployment.md` | 1 hr |

**Total: ~12 hr, target tag v3.0.**

---

## 8. Phase 9 prep summary (reference)

What v2.3 shipped to enable the future Phase 11 PO-line ETL (NOT
used by Phase 10):

- Migration `db/021` adds 20 nullable columns to
  `PurchaseOrderLines`: `InvoiceNo`, `KanbanNo`, `AsnNo`, `PCCNo`,
  `BatchNo`, `ManufacturingControlNo`, `ManufacturingReferenceNo`,
  `CustomerReferenceNo`, `ExportDeclarationNo`, `VendorItem`,
  `PalletId`, `VmiPalletId`, `Location`, `Building`, `SubInventory`,
  `ToLocation`, `ProductionLine`, `OrderRound`, `DeliveryDate`,
  `Note`.
- `PoLineRow` DTO carries all 20; `GET /api/pos/{id}` surfaces them.
- PO Detail UI shows 5 priority columns; other 15 are API + Excel
  export only.
- `PosExportJob` writes a "Lines" sheet with all 20 fields.
- No indexes — Phase 11 will design them against real ERP query
  patterns.
