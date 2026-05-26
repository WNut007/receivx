# ERP Integration — operator + ops guide

Last updated: v3.0 (Phase 10 close).
Audience: admins triggering syncs, ops investigating sync failures, devs
extending the pipeline.

Phase 10 wires Receivx to its upstream ERP (`BPI_PRS` source table on a
remote SQL Server). The integration is **PULL** — Receivx reads from the
ERP DB on a schedule, transforms rows into the Pulls / PullItems /
PullItemWindows shape, and upserts. ERP credentials live in
`dotnet user-secrets`; no inbound endpoints are exposed to the ERP team.

> **Design note.** The earlier PUSH variant (ERP POSTs to
> `/api/erp/pos`) was abandoned mid-planning so Receivx could own the
> schedule + failure handling without depending on the ERP team's
> roadmap. The original PUSH spec is preserved in git history at tag
> `v2.3.2`'s commit of `docs/phase-10-erp-integration.md`.

---

## 1. What it does

```
[Hangfire recurring (hourly)]                [Admin clicks "Sync now"]
            │                                            │
            │   ErpSyncJob.RunAsync()                    │   ErpSyncJob.RunForWarehouseAsync(
            │     warehouse = ErpSyncOptions.            │     warehouseId, backfillDays, operator)
            │                  DefaultWarehouseId        │
            ▼                                            ▼
                          ErpSyncMutex.TryAcquire()
                          │           │
                          │  acquired │  busy → skip with audit log line
                          ▼
            ┌─────────────────────────────────────────────┐
            │  1. INSERT ErpSyncLog row (Status='running')│
            │  2. INSERT AuditLog row    (etl-start)      │
            │  3. ErpSyncService.ReadAndTransformAsync()  │
            │     SELECT ... FROM ERP.dbo.BPI_PRS         │
            │       WHERE DeliveryDate >= today-Nbackfill │
            │     Group by PRS_ID → PullDraft graph       │
            │     ItemCode = SKU + "-" + TRIAL_ID         │
            │     WINDOWS_TIME NULL → HourOfDay=7         │
            │  4. ErpUpsertService.UpsertAsync(draft)     │
            │     per-pull tx:                            │
            │       Pull not found  → INSERT + items + windows
            │       Pull is closed  → SKIP (audit only)   │
            │       Pull is open    → UPDATE planning     │
            │                          fields; ETL never  │
            │                          touches            │
            │                          Status / locks /   │
            │                          ReceivedQty /      │
            │                          signature          │
            │     Items in DB not in draft → Status='canceled'
            │     audit row IN the same tx (or standalone │
            │     on skip / error)                        │
            │  5. UPDATE ErpSyncLog (succeeded + totals)  │
            │  6. INSERT AuditLog row (etl-end)           │
            └─────────────────────────────────────────────┘
                          │
                          ▼
                       (mutex released; status page reflects new row)
```

**Source of truth split:**
- ERP owns: planning fields (PullDate, item codes, expected qtys,
  ERP-sourced metadata — ProductFamily, FromSubInventory, etc.)
- Receivx owns: operational state (Status, signatures, ReceivedQty,
  LockPoByPull, LockHourCap, Notes, ETA)

If ETL sees a planning field changed in ERP, the change overwrites
Receivx. If an operator has edited an operational field, ETL leaves it
alone. The protected-field list is in `ErpUpsertService.cs` and
verified by `tools/smoke-phase-10-3-erp-upsert.ps1` (forbidden-column
scan against every UPDATE SET clause).

---

## 2. Triggering a sync

### 2.1 From the dashboard

Admin-only "Sync ERP" button on the Pull Controller toolbar. Opens a
modal — pick warehouse, set backfill days (default 30), Start. Modal
polls Hangfire job status every 2s; closes with a toast on Succeeded,
keeps the modal open with the reason on Failed.

### 2.2 From the status page

`/Admin/ErpSync` — same modal, plus visibility of past runs. The
button auto-disables while a sync is in flight (the page polls
`/api/admin/erp-sync/state` every 5s).

### 2.3 From the recurring schedule

Set `ErpSync:Enabled = true` and `ErpSync:DefaultWarehouseId =
<your warehouse GUID>` in config (appsettings or user-secrets). On
startup, the app registers a Hangfire recurring job with the
configured cron (default `0 * * * *` — top of every hour). The
recurring runs as the `[system]` actor in audit rows; manual triggers
record the operator's display name.

### 2.4 From the Hangfire dashboard

`/hangfire/recurring` shows `erp-sync-hourly` once registered. Click
**Trigger now** to fire off-schedule. Admin-only.

---

## 3. Status visibility

### 3.1 Sync history page

`/Admin/ErpSync` — paginated list of past runs (latest first). Per
row: Started · Trigger · Status · Operator · Created · Updated ·
Skipped · Errors · Elapsed · RunId/Detail. Failed runs surface the
truncated `ErrorMessage` in the last column with a hover tooltip.

### 3.2 Per-pull audit detail

Every run writes per-pull rows to `dbo.AuditLog` keyed by the
`PullNumber`. To see what a specific run did:

```sql
DECLARE @runId UNIQUEIDENTIFIER = '<paste from the status page>';
SELECT TOP 200 ActionType, EntityId AS PullNumber, Message, OccurredAt, ActorName
FROM   dbo.AuditLog
WHERE  Message LIKE '%[run ' + CONVERT(VARCHAR(36), @runId) + ']%'
  AND  ActionType LIKE 'etl-%'
ORDER  BY Id;
```

`ActionType` values:
- `etl-start` / `etl-end` — run brackets, keyed on `EntityId = runId`
- `etl-create` — new pull inserted (with item + window counts in
  `Message`)
- `etl-update` — existing pull updated; `Message` carries
  `itemsAdded=N, itemsCanceled=N` deltas
- `etl-skip` — closed pull; ERP can't revise it
- `etl-error` — per-pull catchall with exception type + message

### 3.3 Quick "is anything running?" probe

```
GET /api/admin/erp-sync/state  →  { "isRunning": true|false }
```

Admin-only; backed by a single `Interlocked` read. Used by the status
page's 5s auto-refresh.

---

## 4. Configuration

| Key | Type | Default | Notes |
|---|---|---|---|
| `ErpDb:ConnectionString` | string | (none) | Required. SQL connection string to the ERP source. User-secret in dev; env var / vault in prod. |
| `ErpSync:Enabled` | bool | `false` | Master kill-switch for the recurring job. When false, startup explicitly removes the schedule. |
| `ErpSync:DefaultWarehouseId` | Guid | empty | Target warehouse for the recurring path. Empty → recurring fires but logs "no default" and exits (manual trigger still works). |
| `ErpSync:CronExpression` | string | `"0 * * * *"` | Standard 5-field crontab. |
| `ErpSync:BackfillDays` | int | `30` | DeliveryDate filter window on `BPI_PRS`. |
| `ErpSync:TimeoutSeconds` | int | `600` | `[DisableConcurrentExecution]` lock wait. The C# attribute literal hardcodes 600; this option exists for symmetry but is informational only (the attribute literal wins if you change the option). |

### 4.1 Production user-secrets

```powershell
dotnet user-secrets set "ErpDb:ConnectionString" `
    "Server=<erp-host>;Database=<db>;User Id=<readonly-user>;Password=<strong>;TrustServerCertificate=true" `
    --project src/ReceivingOps.Web
```

For the recurring path you'll typically also set:

```powershell
dotnet user-secrets set "ErpSync:Enabled" "true" --project src/ReceivingOps.Web
dotnet user-secrets set "ErpSync:DefaultWarehouseId" "<warehouse-guid>" --project src/ReceivingOps.Web
```

### 4.2 Network requirements

- Outbound TCP from the app host to the ERP SQL host (default port
  1433, unless `ErpDb:ConnectionString` overrides). Allow this through
  firewall / VPN before first start.
- The smokes `smoke-phase-10-1-erp-connection.ps1` through
  `smoke-phase-10-7-integration.ps1` all do a 2-second TCP probe first
  and skip cleanly when unreachable, so a dev box without VPN doesn't
  break the battery.

### 4.3 ERP DB user permissions

The connection-string user must have **read-only access** to `BPI_PRS`
(and any joined tables when the mapping evolves). Lock it down:

```sql
-- On the ERP server, in the ERP database
CREATE LOGIN [receivx_readonly] WITH PASSWORD = '<strong>';
CREATE USER  [receivx_readonly] FOR LOGIN [receivx_readonly];
ALTER ROLE   db_datareader ADD MEMBER [receivx_readonly];
-- Explicitly deny write capability even if a future role change tries to grant it
DENY INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::dbo TO [receivx_readonly];
```

---

## 5. Architecture

### 5.1 Type layout

| Layer | Type | What it does |
|---|---|---|
| Connection | `IErpDbConnectionFactory` / `ErpSqlConnectionFactory` | Reads `ErpDb:ConnectionString`; throws at `Create()` time when unset so startup stays healthy with ERP integration disabled. |
| Mutex | `ErpSyncMutex` | Singleton; `Interlocked` flag with `TryAcquire`/`Release`/`IsRunning`. Excludes the recurring and manual paths from each other (`[DisableConcurrentExecution]` only scopes per-method). |
| Read+transform | `IErpSyncService` / `ErpSyncService` | Dapper-queries `BPI_PRS`, synthesizes `ItemCode = SKU-TRIAL_ID`, applies the `WINDOWS_TIME NULL → 7` default, builds the `ErpSyncDraft` graph. Pure transform, no DB writes. |
| Upsert | `IErpUpsertService` / `ErpUpsertService` | Per-pull transactional MERGE. Honors closed-pull skip + ETL-immutable column list. Writes per-pull audit rows (in-tx for success, standalone for skip/error). |
| Summary | `IErpSyncLogRepository` / `ErpSyncLogRepository` | `dbo.ErpSyncLog` lifecycle: `InsertStartAsync` → `MarkSucceededAsync` (with totals) or `MarkFailedAsync`. |
| Audit | `IAuditService.WriteSystemAsync` | Phase 10.5 overloads — explicit actor name (no `HttpContext` needed). `[system]` for recurring, operator displayName for manual. |
| Job | `ErpSyncJob` | Two entry points (`RunAsync` recurring + `RunForWarehouseAsync` manual) sharing `ExecuteAsync`. Brackets every run with `InsertStartAsync` → `etl-start` audit → … → `MarkSucceededAsync` → `etl-end` audit. |
| Trigger UI | `ErpSyncAdminController` | `POST /trigger` (with mutex pre-check 409) · `GET /jobs/{jobId}` (Hangfire state) · `GET /log` (paginated history) · `GET /log/{runId}` · `GET /state`. |
| Page | `AdminController.ErpSync()` | `/Admin/ErpSync` Razor + `admin-erp-sync.js`. |

### 5.2 Concurrency invariants

| Path A | Path B | Protection |
|---|---|---|
| recurring `RunAsync` × recurring `RunAsync` | (a slow run overlapping the next fire) | `[DisableConcurrentExecution(600)]` blocks at Hangfire layer |
| manual × manual | (two operators clicking simultaneously) | Same `[DisableConcurrentExecution]` (same method signature) |
| recurring × manual | (different method signatures — Hangfire locks DON'T compose) | `ErpSyncMutex.TryAcquire` inside `ExecuteAsync`; second caller logs "skipped" and returns |
| Endpoint click while sync running | (any combination) | Pre-flight `mutex.IsRunning` check → 409 with friendly message, no enqueue |

In-process scope: the mutex is a singleton, so a multi-instance deploy
would need a distributed lock (Redis row-lock, SQL `sp_getapplock`).
Out of scope for v3.0.

### 5.3 Closed-pull protection

ERP cannot revise a signed pull. When `ErpUpsertService` sees a target
pull with `Status='closed'`:

1. Transaction rolls back (no writes happened — we only took an
   `UPDLOCK + ROWLOCK` on the row).
2. Counter `SkippedClosed++`.
3. `etl-skip` audit row written standalone (outside the rolled-back
   tx) so the skip event survives the rollback.

The smoke `smoke-phase-10-7-integration.ps1 §2` verifies this
behaviorally: it flips a pending pull to `closed` + sets `PullDate` to
a sentinel `1990-01-01`, triggers sync, and asserts `PullDate` is
STILL the sentinel after the run (proving no UPDATE happened).

---

## 6. BPI_PRS column mapping

Source schema (18 columns, ~106K rows at v3.0 ship):

| BPI_PRS | Receivx destination | Notes |
|---|---|---|
| `PID` | (ignored) | ERP-side PK |
| `PRS_ID` | `Pulls.PullNumber` | Idempotency key for upsert |
| `SKU` + `TRIAL_ID` | `PullItems.ItemCode` (synthesized) | `SKU-TRIAL_ID` when TRIAL_ID present, else bare SKU |
| `DESCR` | `PullItems.Description` | Falls back to `SKU` when blank (100% NULL in current data) |
| `PRODUCT_FAMILY` | `PullItems.ProductFamily` | Phase 9.1 ERP field |
| `VENDOR` | `PullItems.VendorCode` | Single field; not split |
| `FROM_SUB` | `PullItems.FromSubInventory` | Phase 9.1 ERP field |
| `TO_SUB` | `PullItems.ToSubInventory` | Phase 9.1 ERP field |
| `SPECIAL_CONTROL` | `PullItems.SpecialControl` | Phase 9.1 ERP field |
| `TRIAL_ID` | `PullItems.TrialId` | Phase 9.1 ERP field (validates the v2.3.2 rename — ERP source uses TRIAL too) |
| `LOC` | `PullItems.Location` | Phase 9.1 ERP field |
| `PHASE` | `PullItems.[Phase]` | Phase 9.1 ERP field |
| `QTY` | `PullItemWindows.ExpectedQty` | One window per BPI_PRS row |
| `REMARK` | `PullItems.Remark` | |
| `ExportEntry` | (ignored) | 100% NULL/empty in samples |
| `AddDate` | (ignored) | Informational |
| `DeliveryDate` | `Pulls.PullDate` | Truncated to date |
| `WINDOWS_TIME` | `PullItemWindows.HourOfDay` | **NULL → 7** (user-confirmed default; 100% NULL in current data) |

### 6.1 Defaulting rules

- `WINDOWS_TIME IS NULL → HourOfDay = 7` (07:00). 100% of current
  rows are NULL so this is the only path the ETL exercises.
  Defensive parser handles `"HH"` and `"HH:mm"` formats for when the
  ERP team starts populating the column.
- `PullNumber` overflow (>32 chars): row recorded as `Errors` with a
  clear "exceeds 32 chars" detail. Current sample data is ≤10 chars
  so this is purely defensive.
- `SynthesizeItemCode` truncates the combined `SKU-TRIAL_ID` to 64
  chars (the `PullItems.ItemCode` column limit). Real data is well
  under this.

### 6.2 Warehouse assignment

`BPI_PRS` has no warehouse column. The caller (operator on manual
trigger, `ErpSync:DefaultWarehouseId` on recurring) picks the target
warehouse and ALL pulls in the run land under it. Future work: a
`SubInventoryWarehouse` lookup that derives the warehouse from
`FROM_SUB` / `TO_SUB` — captured as a future enhancement in
`docs/phase-10-erp-integration.md` §5 open questions.

---

## 7. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Recurring runs but immediately logs "DefaultWarehouseId is unset" | `ErpSync:DefaultWarehouseId` not configured | Set it in user-secrets; restart |
| `POST /trigger` returns 500 with "ErpDb:ConnectionString is not configured" | User-secret missing | `dotnet user-secrets set ErpDb:ConnectionString ...` |
| `POST /trigger` returns 409 | Another sync is in flight | Wait — the modal polls /state and re-enables itself |
| `/Admin/ErpSync` shows zero rows but `ErpSyncOptions:Enabled=true` | Recurring fires but skips on no DefaultWarehouseId — no log row written for skipped fires | Set DefaultWarehouseId or trigger manually |
| Sync job stuck in `Processing` state in Hangfire dashboard | Worker thread blocked or the ERP query is slow | Check the Hangfire dashboard's "Servers" tab; restart the app if a worker is genuinely hung. `[DisableConcurrentExecution(600)]` will eventually free the lock. |
| Per-pull `etl-error` rows for every row | Likely a schema mismatch (BPI_PRS columns changed) | Compare `INFORMATION_SCHEMA.COLUMNS` against `ErpSyncService.BpiPrsRow` |
| `ErpSyncLog.Status='failed'` with `ErrorMessage` mentioning ConnectionTimeout | Network change / VPN disconnect | Check firewall + run `tools/smoke-phase-10-1-erp-connection.ps1` |
| All pulls under wrong warehouse | Operator picked the wrong warehouse in the trigger modal, OR `DefaultWarehouseId` set incorrectly | The sync UPDATE path intentionally does NOT change `WarehouseId` on existing pulls, so the only fix is manual reassignment in the drawer (or a SQL cleanup) |

---

## 8. Smoke coverage

| Smoke | Validates |
|---|---|
| `smoke-phase-10-1-erp-connection.ps1` | Connection factory wiring + TCP/SQL reachability |
| `smoke-phase-10-2-erp-read-transform.ps1` | Service + draft DTOs + live `BPI_PRS` sample read |
| `smoke-phase-10-3-erp-upsert.ps1` | Upsert service shape + forbidden-column scan + cancel-not-delete invariant |
| `smoke-phase-10-4-erp-trigger.ps1` | Trigger endpoint + mutex + full Hangfire pipeline end-to-end |
| `smoke-phase-10-5-erp-audit.ps1` | Per-pull AuditLog correlation by runId + actor capture through Hangfire |
| `smoke-phase-10-6-erp-sync-page.ps1` | `/Admin/ErpSync` page + `/log` endpoint + `ErpSyncLog` write path |
| `smoke-phase-10-7-integration.ps1` | Cross-table consistency + closed-pull skip BEHAVIOR + mutex 409 under live contention |

All seven skip cleanly when the ERP host is unreachable (firewall/VPN
on the dev box). They share a 2-second TCP probe pattern so the
battery stays green regardless of network state.

### Heavy load test (opt-in)

The spec called for a 10× load test (~50K row writes). For a one-shot
pre-deploy verification:

1. Set `ErpSync:DefaultWarehouseId` to a non-production warehouse.
2. Trigger manually with `backfillDays = 365` — catches BPI_PRS's
   full ~100K+ row set.
3. Measure wall-clock from /trigger → terminal state.
4. During the run, repeatedly hit `/api/admin/erp-sync/state` and
   `/Admin/ErpSync` to confirm the UI stays responsive (< 1s).
5. Mid-run, try a second `POST /trigger` — should get 409 immediately
   without enqueueing.

Expected at current scale: < 3 minutes for ~100K rows. Adjust based
on your DB latency.

---

## 9. Security

- ERP credentials are read-only and live in user-secrets. They never
  appear in logs (the connection factory throws on a bare key, not a
  value).
- The integration is one-way pull. The ERP team needs no Receivx
  credentials; the only contract is "give Receivx a read-only SQL
  login + open the firewall".
- Manual trigger endpoint is `[Authorize(Roles = "admin")]`.
  Supervisors don't get sync access even though they can manage pulls
  in their warehouse — ETL is a global operation.
- `/Admin/ErpSync` page is admin-only at the controller layer too.
- `/api/admin/erp-sync/jobs/{jobId}` reads Hangfire's monitoring API
  with the admin's session — no signed-token side-channel.
- Audit rows record the actor (`[system]` or operator displayName) +
  the runId. Combined with the standard `dbo.AuditLog` retention, you
  can answer "who/when/why" for any past sync.
