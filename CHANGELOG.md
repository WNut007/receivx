# Changelog

All notable changes to ReceivingOps are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Retroactive entries below were consolidated at v2.2 from CLAUDE.md
status-footer history; per-tag commit hashes are the source of truth
for fine-grained authorship.

---

## [3.4.1] — 2026-05-30 — Receipt seed gap closure

Restores the historical PL-2847 Receipts that db/006 §5 seeded under v1
but couldn't recreate against the v2 strict schema (Receipts
.PurchaseOrderLineId NOT NULL since db/011). After v3.4's db/035 wipe,
the dev test bed lost all receipts; this migration brings them back.

### Migrations

- `db/038_phase_14_receipt_backfill.sql` — resolves PurchaseOrderLineId
  up-front via the same FIFO logic db/012 used during the v1→v2 cutover
  (oldest open PO line per item code), then INSERTs 18 receipts
  (16 positives + 2 reversal pairs) with explicit PurchaseOrderId +
  PurchaseOrderLineId. Set-from-truth POL/PIW cache recalcs at the
  end make it idempotent. NOT EXISTS guards on the receipt GUIDs.
  Same invariants as db/012 §2.4 are enforced before COMMIT.

### Fixed

- `smoke-pull-status-forward-transition` — fixture INSERT carried
  VendorCode/VendorName at the PO header (silently 0-row insert
  post-Phase-14 because those columns were dropped). Moved vendor
  to the POL INSERT per the db/036 shape.

### Smoke status delta vs v3.4

  Seed-gap failures at v3.4 ship: 4
  After v3.4.1:
    PASS  smoke-phase-9-1-pull-extended-fields  (regained Receipts coverage)
    PASS  smoke-phase-9-extended-fields          (regained Receipts coverage)
    PASS  smoke-pull-status-forward-transition   (Phase 14 INSERT patched)
    FAIL  smoke-stage-b                          (different gap — see below)

### Known gaps remaining for v3.4.2

- **smoke-stage-b** — PL-2844 carries `SUMMARY` (a db/006 §4 mockup
  placeholder with no PO backing), so by-number lookup returns an
  unreceivable item. The smoke worked pre-Phase-14 only via dev-DB
  residue from prior runs. Honest fix is a smoke refactor (use
  PL-2847 with a known-receivable item that has window headroom
  post-backfill, or inline-seed a real PullItem on PL-2844) — outside
  the Receipts-backfill scope this version closed.
- **New PO modal + PO Detail header form** still show Vendor Code /
  Vendor Name inputs at PO-header grain. Operator confusion risk
  (silently dropped post-Phase-14). Carried forward from v3.4 backlog.
- **PoListRow "Mixed" badge** when MIN=MAX collapse returns null —
  blank vs "Mixed" UI cue. Carried forward.

### Commits

- `4891ac9` feat(db): db/038 receipt backfill + smoke alignment

---

## [3.4.0] — 2026-05-30 — Phase 14: vendor at line grain

Mixed-vendor purchase orders are a real production case. The v3.2
import job's "take firstRow.VendorCode for the whole PO" silently
discarded lines 2..N's vendor whenever an Excel workbook covered
multiple vendors under one PRS_ID. Phase 14 moves `VendorCode` +
`VendorName` from `dbo.PurchaseOrders` (header) to
`dbo.PurchaseOrderLines` (line) and reshapes the Delivery Order
report so a single pull can now spawn multiple DOs — one per
(Vendor × FromSubInventory × ToLocation) shipment triple.

Destructive: db/035 wipes all transactional data on dev (production
guard active). The schema move is irreversible without restoring
from backup.

### Migrations

- `db/035_wipe_for_phase_14.sql` — destructive clear of Receipts,
  PullItemWindows, PullItems, Pulls, PurchaseOrderLines, PurchaseOrders,
  PoImportLog, ErpSyncLog, AuditLog. Production guard via
  `@@SERVERNAME` check (dev-only). Keeps AppSettings, Warehouses,
  Users, and the Hangfire schema. Single tx with rollback on any error.
- `db/036_vendor_to_po_lines.sql` — re-ALTERs `vw_TransactionsJournal`
  + `vw_PurchaseOrderAvailability` to source vendor from POL, ADDs
  `VendorCode VARCHAR(64)` + `VendorName NVARCHAR(160)` on
  PurchaseOrderLines, creates filtered index `IX_POL_Vendor`, and
  DROPs the vendor columns from PurchaseOrders header. Ordered so
  the views remain valid across the transition.
- `db/007_seed_purchase_orders.sql` + `db/016_seed_po_pull_link.sql` —
  seed scripts patched: vendor now lands on POL inserts (matched
  per-PO to preserve historical single-vendor display via the new
  MIN=MAX collapse).

### Schema

- `dbo.PurchaseOrders.VendorCode` / `VendorName` — **DROPPED**.
- `dbo.PurchaseOrderLines.VendorCode VARCHAR(64) NULL` — **ADDED**.
- `dbo.PurchaseOrderLines.VendorName NVARCHAR(160) NULL` — **ADDED**.
- Filtered index `IX_POL_Vendor` on (VendorCode) WHERE NOT NULL.

### Entities / DTOs

- `PurchaseOrder` loses vendor; `PurchaseOrderLine` gains vendor.
- `PoLineRow` + `PoLineCreateRequest` gain `VendorCode` /
  `VendorName` at line grain.
- `PoLineExtendedFieldsUpdateRequest` gains vendor in its Tracking
  section (modal-editable per line). Server-side validator widths:
  VendorCode ≤ 64, VendorName ≤ 160.
- `PoCreateRequest` + `PoUpdateRequest` drop vendor (no header
  write path).
- `PoListRow.VendorCode` / `Name` and `PoDetail.VendorCode` / `Name`
  are now MIN=MAX **collapsed summaries** in the repo: non-null when
  every line of a PO agrees on a single vendor, null when mixed or
  unset. UI surface stays wire-compatible.
- `DoOrder` drops `PoId` / `PoNumber` / `OrderDate` and gains
  `SubInventory` + `ToLocation` (grouping keys alongside vendor).
- `DoReportRow` promotes vendor + SubInventory + ToLocation from
  MAX'd metadata to first-class grouping columns.

### Repositories / services

- `PurchaseOrderRepository.QueryAsync` + `GetDetailAsync` use the
  MIN=MAX collapse subqueries for the header vendor summary. The
  multi-token search WHERE branches use `EXISTS POL` so a token
  matches when **any** line vendor matches.
- `GetLinesForPosAsync` sources vendor from `pol.*`.
- `PullRepository.GetDoReportRowsAsync` regroups by
  `(VendorCode, VendorName, SubInventory, ToLocation, PoId, PoNumber,
  LineNumber, ItemCode, Description)` so the service-layer LINQ
  GroupBy can split DOs per shipment triple while preserving the
  source PO per line.
- `PurchaseOrderAdminService.CreateAsync` writes per-line vendor on
  every POL INSERT; `UpdateAsync` no longer carries vendor;
  `AddLineAsync` writes vendor on the new line;
  `UpdateLineExtendedFieldsAsync` writes vendor in its UPDATE.
- `PoImportJob` drops vendor from the PO INSERT and writes per-row
  vendor on each POL INSERT (closes the v3.2 silent-loss defect).
- `DeliveryOrderService` GroupBy keyed on the (VendorCode, VendorName,
  SubInventory, ToLocation) anonymous tuple; PoLineRef sourced per-row
  PoNumber; PDF title band gains FROM SUBINVENTORY + TO LOCATION rows
  below Vendor/Warehouse (band height bumped 70 → 82mm).

### UI

- PO Detail line table: new leftmost ERP column "Vendor" displays
  VendorName (fallback VendorCode, em-dash). Tooltip carries both.
  Colspan 13 → 14.
- Phase 9.2 extended-fields modal Tracking section: VendorCode +
  VendorName at the top of the group.
- _DoPreview.cshtml: `do-number` displays the vendor (not PoNumber);
  metadata gains "From sub-inventory" + "To location" rows; legacy
  "Order date" row removed (per-line concept now).

### Smokes

- New: `smoke-phase-14-vendor-at-line` (mixed-vendor import →
  per-line vendor round-trip + collapsed-header assertion).
- New: `smoke-phase-14-do-multi-do` (pull → 2 DOs split by triple).
- New fixture: `tools/fixtures/po-import-mixed-vendor.xlsx` (3 rows,
  3 distinct vendors under one PoNumber). Generator at
  `tools/build-po-import-mixed-vendor-fixture.ps1` (one-shot, NOT
  in battery).
- Patched: `smoke-phase-9-2-po-line-extended-fields` (vendor in
  Tracking section + UI markers); `smoke-phase-12-7-integration`
  (per-line vendor assertions VEND-A x2 / VEND-B x2);
  `smoke-do-report` (vendor stamp + new DO header shape);
  `smoke-phase-5c` (drop header-vendor assertions, skip §7.13 path
  when no historical receipts).
- Backup: `.dp-keys-backup-phase14-pre/` taken before db/035.

### Known battery gaps (deferred to v3.4.1)

- Historical Receipts seed (db/006 §5) cannot run as-is against the
  v2 strict schema (Receipts.PurchaseOrderLineId NOT NULL since
  db/011). Smokes that depend on pre-existing receipts on
  PO-2401-018 / WH-02 pulls (`smoke-stage-b`,
  `smoke-pull-status-forward-transition`,
  `smoke-phase-9-1-pull-extended-fields`,
  `smoke-phase-9-extended-fields`) will fail or skip parts of their
  coverage until that gap is closed.
- New PO modal (`/Pos` newPoModal) still has Vendor Code + Vendor
  Name inputs at PO-header grain. Model binder silently drops them
  (`PoCreateRequest` no longer carries those). Same for the
  detail-view header form's `d-vendor-code` / `d-vendor-name`
  inputs and the `saveHeader` payload. Operator confusion risk;
  cleanup deferred.

### Commits

- `cecf42b` Stage 0 (pre-flight dashboard toast text fix)
- `7976a34` Stage 1+2 migration drafts (db/035 + db/036)
- `79a295f` Stage 1+2 mid-flight defect fixes (FK order, self-ref
  constraints, view-before-column ordering)
- `5c2fb71` Stage 3+4 entity + DTO + repo + service refactor
- `181b28a` Stage 5 DO report rewrite
- `c18e49d` Stage 6 PO line table + modal UI
- `b768b8f` Stage 7 smoke updates + new Phase 14 coverage
- `0b3fd33` smoke-phase-5c Phase 14 alignment

---

## [3.1.1] — 2026-05-26 — Phase 11.2 audit gap closure

Selective ship of 4 gaps surfaced by a post-v3.1 spec audit (others
deferred per YAGNI). All changes are server-side; UI untouched.

### Added

- `POST /api/admin/config/test/smtp` — wrapper that fires a one-shot
  send via the same `IEmailService` that backs `/api/admin/email-test`.
  Lives on the Config namespace so a future hardening pass can
  deprecate the older diagnostic endpoint without breaking the editor.
  Returns `{ sent, recipientEmail, error? }` (200 even on send
  failure — the operator wants the verbatim SMTP error in the panel,
  not a 500). Malformed recipient → 400.

### Tightened (validation)

- `ErpDb:ConnectionString` — POST `.../secret` now rejects values
  missing `Server=` or `Database=`. Cheap typo guard; the full parse
  still happens at the live `SqlConnection.Open()` probe via
  `POST /api/admin/config/test/erp`.
- `Exports:BaseUrl` — PUT `.../sections/Exports` now requires
  `https://` in the Production environment (`IHostEnvironment.IsProduction()`).
  Dev / Staging continue to accept `http://` for localhost convenience.
  Rationale: HMAC download tokens travel in the URL query string;
  plain HTTP exposes them to any on-path observer.
- `Exports:SigningKey` — POST `.../secret` now enforces a 32-character
  minimum. The `Regenerate` button always writes 44 chars (base64 of
  32 random bytes), so this only constrains the manual `/secret`
  path. Floors HMAC input at the 256-bit safety threshold.

### Docs

- `docs/configuration.md §7` updated to match shipped reality:
  - SMTP test endpoint table now lists both
    `/api/admin/config/test/smtp` and the legacy
    `/api/admin/email-test`.
  - Clarified that no `GET /api/admin/erp/connection-test` endpoint
    exists (Phase 10.1 had a sqlcmd-based smoke, not an HTTP probe).
  - Warehouse dropdown source documented as `/api/warehouses`
    (existing, all-authenticated) rather than an `/api/admin/`
    variant.
  - Removed misleading "Diagnostics tab/footer" mention — the
    editor's 4 tabs already render every effective value with
    secrets masked, so a parallel read-only view is redundant.
  - Supervisor + operator access clarified: page reachable but
    Configuration section hidden via `data-admin-only`; API gate
    is the actual security boundary (operator → 403 at every
    endpoint).
  - Validation rules table extended with the 3 new constraints +
    annotation marking them as v3.1.1 additions.

### Skipped (audit Option A — explicitly NOT shipped)

- **Gap 2-3 (response-shape additive)** — proposed adding `title`,
  `keyCount`, `hasSecrets`, `secretKeys` aliases alongside the
  shipped property names. The editor UI consumes the v3.1 shape and
  doesn't need both; additive duplication would have been
  YAGNI bloat.
- **Gap 4 (Smtp:Host hostname format)** — browsers validate text
  input client-side; server-side hostname validation rarely catches
  more than a typo before the SMTP send attempt does.
- **Gap 5 (Smtp:Username required-if-Password-set conditional)** —
  surface the failure at test-send time where the operator can act
  on the verbatim SMTP error; conditional UI rules tend to confuse
  more than they help.
- **Gap 6 (Smtp:Password 8+ chars)** — Gmail App Passwords are
  fixed 16 chars; the only operators putting shorter values into
  this field would be intentionally bypassing the test send, which
  is their problem.

### Smoke

- `tools/smoke-phase-11-2-config-ui.ps1` extended from 19 to 25
  assertions: test/smtp happy path + bad recipient, ErpDb format
  guard (good + bad), SigningKey min length (good + bad).
- Gap 8 (BaseUrl Production-https) is NOT covered by the smoke —
  needs `ASPNETCORE_ENVIRONMENT=Production` at boot, which would
  break the rest of the battery. Manual verify: set the env,
  restart, PUT `http://...` → expect 400.

### Tag

`v3.1.1` — Phase 11.2 audit gap closure (3 commits).

---

## [3.1.0] — 2026-05-26 — Phase 11: configurable settings via admin UI

Encrypted config storage (Phase 11.1, interim tag `v3.0.5`) +
tabbed `/Config` editor (Phase 11.2). Admin can now edit Smtp,
ErpDb, ErpSync, Exports config via the UI without touching
`appsettings.json` or `user-secrets`. Secrets stay encrypted in
`dbo.AppSettings` via ASP.NET Data Protection (purpose
`AppSettings.v1`, 90-day key lifetime). Precedence chain:
env vars > DB > user-secrets > appsettings.json.

### Added

- Migration `db/029` — `dbo.AppSettings` table with Value/EncryptedValue XOR CHECK
- `IAppSettingsService` (Singleton + IServiceScopeFactory bridge) + `IAppSettingsRepository` (Scoped, Dapper MERGE upsert)
- `AppSettingsSeeder` — idempotent IConfiguration → DB hydration on first start
- Options binding refactored: `AddOptions<T>().Configure<IAppSettingsService>(...)` for SmtpOptions / ExportOptions / ErpSyncOptions
- 7 admin endpoints under `/api/admin/config/` (sections list, section detail, PUT non-secret, POST secret, DELETE reset, regenerate signing key, test ERP)
- Tabbed `/Config` admin section: 4 pill-style tabs (Email / ERP Connection / Sync Schedule / Exports) replaces v2.1.9 Email-test diagnostic
- 5 editor JS files with `window.registerConfigTabRenderer` extension point
- `docs/security.md` + `docs/configuration.md`
- + `NCrontab 3.3.3` NuGet for cron validation
- 2 new smokes (10 + 19 assertions)

### Tags

`v3.0.5` (Phase 11.1 interim) → `v3.1.0` (Phase 11.2 close).
Battery: 51/51 PASS at v3.1 tip.

---

## [3.0.0] — 2026-05-26 — Phase 10: ERP integration (PULL/ETL)

**First external-system integration.** Receivx now pulls planning
data from an upstream ERP (`BPI_PRS` source table on a remote SQL
Server) on an hourly schedule + on-demand via admin trigger. The
integration is one-way pull — no inbound endpoints exposed to the
ERP team; the only contract is "give Receivx a read-only SQL login +
open the firewall".

Major-version bump because this is a new external surface area and a
new run-time dependency (ERP DB reachable on the network). Same
in-process Hangfire worker; no new app processes.

### Added

- Migration `db/028` — `dbo.ErpSyncLog` summary table (RunId PK +
  trigger + actor + warehouse + status + 8 totals + ElapsedMs +
  ErrorMessage) + `IX_ErpSyncLog_StartedAt` covering index.
- New connection factory `IErpDbConnectionFactory` /
  `ErpSqlConnectionFactory` — separate from the Receivx
  `IDbConnectionFactory` so misregistered DI can't accidentally
  write to the ERP host. Throws at `Create()` (not construction) so
  startup stays healthy when ERP integration is disabled.
- New service `IErpSyncService` / `ErpSyncService` — Dapper-queries
  `BPI_PRS` filtered by `DeliveryDate >= today - backfillDays`,
  groups rows by `PRS_ID`, synthesizes
  `ItemCode = SKU + "-" + TRIAL_ID` (so multiple trials of the
  same SKU become distinct items without breaking `UNIQUE(PullId,
  ItemCode)`), applies `WINDOWS_TIME NULL → HourOfDay=7` defaulting
  rule, builds the in-memory `ErpSyncDraft` graph
  (`PullDraft` → `PullItemDraft` → `PullItemWindowDraft`). Pure
  transform, no DB writes.
- New service `IErpUpsertService` / `ErpUpsertService` — per-pull
  transactional MERGE into Pulls / PullItems / PullItemWindows.
  Honors closed-pull skip (Status='closed' → SkippedClosed++, no
  mutation, audit row written standalone outside the rolled-back
  tx). Items in DB but not in draft → flip Status='canceled' (never
  DELETE — receipts may FK them). ETL never writes to Receivx-
  managed columns: `Pulls.{Status, LockPoByPull, LockHourCap,
  ClosedAt, ClosedBy, SignatureSvg, ReopenedAt, ReopenedBy,
  ReopenReason}`, `PullItemWindows.ReceivedQty`, and
  `PullItems.Status` on the update path.
- `ErpSyncJob` — Hangfire-scheduled. Two entry points: `RunAsync()`
  for the recurring fire (uses `ErpSyncOptions.DefaultWarehouseId`)
  and `RunForWarehouseAsync(warehouseId, backfillDays, actorName)`
  for manual triggers. Both share a private `ExecuteAsync` guarded
  by the singleton `ErpSyncMutex` (Interlocked-based; excludes the
  two paths since `[DisableConcurrentExecution]` scopes per-method).
  Wraps every run in `etl-start` + `etl-end` audit rows + an
  `ErpSyncLog` row for the status page.
- `ErpSyncMutex` — singleton app-level lock (in-process only;
  distributed lock would be needed for multi-instance deploy).
  `TryAcquire` / `Release` / `IsRunning` — the third is read by the
  trigger endpoint for fast-fail 409 UX.
- `IAuditService.WriteSystemAsync` overloads (tx-scoped +
  standalone) — write audit rows with an explicit actor name (no
  HttpContext needed), so Hangfire worker threads can attribute
  rows to `[system]` (recurring) or the operator's displayName
  (manual).
- Per-pull audit rows in `dbo.AuditLog` keyed by `PullNumber`:
  `etl-create` / `etl-update` (in the pull's tx; commit/rollback
  together with the mutation) + `etl-skip` / `etl-error`
  (standalone; visible regardless of mutation state). Every message
  embeds `[run <runId>]` for cross-row correlation; the start/end
  rows use `EntityId = runId` directly.
- `ErpSyncAdminController` (`[Authorize(Roles="admin")]`,
  `/api/admin/erp-sync/*`):
  - `POST /trigger` — `{ warehouseId, backfillDays? }` → 202 + jobId
    on success, 409 when `_mutex.IsRunning`, 400 on empty warehouseId.
  - `GET /jobs/{jobId}` — polls Hangfire's `IMonitoringApi` for
    current state + reason.
  - `GET /log` — `PaginatedResponse<ErpSyncLogRow>` for the
    status-page history list.
  - `GET /log/{runId}` — single-row drill-down.
  - `GET /state` — `{ isRunning: bool }` for UI auto-disable.
- `IErpSyncLogRepository` + `ErpSyncLogRepository` — lifecycle
  CRUD: `InsertStartAsync` → `MarkSucceededAsync` (totals + elapsed)
  / `MarkFailedAsync` (truncated ErrorMessage + elapsed) +
  `QueryPagedAsync` / `GetByRunIdAsync`. Matches the
  `ExportJobsLog` repository conventions.
- `/Admin/ErpSync` Razor page (`AdminController.ErpSync`) — paginated
  history list with status badges + truncated error previews,
  manual "Sync now" button that opens a warehouse-picker modal,
  5-second auto-refresh polling `/state` (refetches list on
  running→idle transitions to pick up the terminal status).
- `/Dashboard` "Sync ERP" button — admin-only convenience entry
  point so operators don't have to navigate to `/Admin/ErpSync` for
  the common case of "fire a sync now". Same modal pattern as the
  status page.
- New `ErpSyncOptions` keys in `appsettings.json` (documented
  defaults): `Enabled = false`, `CronExpression = "0 * * * *"`,
  `TimeoutSeconds = 600`, `DefaultWarehouseId =
  "00000000-0000-0000-0000-000000000000"`, `BackfillDays = 30`.
- 7 new smokes (`smoke-phase-10-1-erp-connection.ps1` through
  `smoke-phase-10-7-integration.ps1`) — all source-level checks +
  behavioral end-to-end paths; all skip cleanly via 2s TCP probe
  when the ERP host is unreachable so the battery stays green on a
  dev box without VPN. The 10.7 integration smoke verifies
  cross-table consistency (ErpSyncLog counters vs AuditLog row
  counts), closed-pull skip BEHAVIOR (SQL fixture flips a pull to
  closed + sentinel PullDate; smoke asserts PullDate stayed at the
  sentinel post-sync), and mutex 409 under live contention.
- New doc `docs/erp-integration.md` — operator + ops guide
  (architecture, configuration, status page, audit drill-down,
  troubleshooting, security, BPI_PRS column mapping).
- Spec doc `docs/phase-10-erp-integration.md` rewritten for PULL
  design (the original PUSH variant lived there through v2.3.x — see
  `docs/phase-10-erp-integration.md` §0 for the history note).

### Changed

- `Pulls.PullNumber` (`varchar(32)`) is the idempotency key against
  `BPI_PRS.PRS_ID` (`varchar(50)`). Rows whose PullNumber would
  overflow 32 chars are recorded as `Errors` in the run summary; the
  ETL continues with the rest of the batch. Current sample data is
  ≤10 chars so this is purely defensive.
- Hangfire worker queue order extended to `["exports", "erp-sync",
  "default"]` — user-facing exports outrank background ETL when both
  are queued.
- `docs/deployment.md` — Phase 10 deploy-blocker section, network
  requirements, migration list updated through `db/028`,
  verification SQL extended, smoke battery count bumped to 49.

### Decisions / non-changes

- **PULL not PUSH.** The earlier PUSH design (ERP POSTs to
  `/api/erp/pos` with `X-ERP-Api-Key` auth) was abandoned mid-planning
  so Receivx could own the schedule + failure handling without
  depending on the ERP team's roadmap. PUSH spec preserved at tag
  `v2.3.2`'s commit of the spec doc.
- **In-process mutex.** Single Hangfire worker means an in-memory
  `Interlocked` flag is sufficient. Multi-instance deploy would
  need a distributed lock (Redis row-lock, SQL `sp_getapplock`);
  out of scope here.
- **No `WAREHOUSE_CODE` derivation from `FROM_SUB` / `TO_SUB`.**
  Caller picks the target warehouse (operator on manual, config
  default on recurring). A sub-inventory → warehouse lookup table
  is captured as a future enhancement in
  `docs/phase-10-erp-integration.md` §5.
- **PullItem.Status untouched on update.** When ETL re-syncs an
  existing item, ETL deliberately doesn't flip `Status` — operators
  may have marked it `canceled` or `new` and ETL shouldn't override
  their decision. Items that disappear from the draft DO get
  flipped to `canceled` (operator can re-activate if needed).
- **No `[AutomaticRetry]` on ErpSyncJob.** Per-pull errors are
  caught and audited individually; catastrophic errors propagate
  to Hangfire which marks the job Failed. Retry policy (with
  audit context) is a future enhancement if the operational
  pattern demands it.
- **Per-pull rows live in `dbo.AuditLog`, not `ErpSyncLog`.**
  Summary in ErpSyncLog (fast paginated list); detail in AuditLog
  (joined on `runId` via `Message LIKE '%[run <guid>]%'` or via
  `EntityId = runId` for start/end rows).

### Migration notes

Sequential `db/024` → `db/025` → `db/026` → `db/027` → `db/028`. All
idempotent (`IF NOT EXISTS` / `COL_LENGTH` / `CREATE OR ALTER` per
the project convention). `db/026` + `db/027` MUST run together (the
view created by db/025 references the pre-rename column name and
becomes invalid between db/026 and db/027).

### Deploy blockers

See `docs/deployment.md` §7 "Phase 10 ERP-integration deploy
blockers" — `ErpDb:ConnectionString` set, ERP user read-only,
placeholder password rotated, firewall/VPN open, recurring
`DefaultWarehouseId` set if applicable.

### Battery

49/49 PASS at v3.0 tip.

---

## [2.3.2] — 2026-05-25 — Typo fix: `TrailId` → `TrialId`

### Changed
- Migration `db/026` — `sp_rename dbo.PullItems.TrailId` → `TrialId`.
  Phase 9.1 (`db/024`) shipped the column as `TrailId` (T-R-A-I-L);
  the field is actually a manufacturing **trial** identifier
  (T-R-I-A-L), so the spelling was wrong. Rename is idempotent
  (no-ops if already renamed; throws if neither column exists so
  the operator runs `db/024` first).
- Migration `db/027` — `CREATE OR ALTER vw_TransactionsJournal` to
  reference `pi.TrialId` after the rename. The two migrations are
  designed to run together; running `db/026` without `db/027`
  leaves the view invalid until `db/027` re-defines it.
- Rename propagated everywhere `TrailId` appeared: `PullItem` entity,
  `PullItemDto`, `PullItemExtendedFieldsUpdateRequest`,
  `ReceiptJournalRow`, `PullRepository` (3 SELECTs + UPDATE +
  `PullItemRow` private), `ReceiptRepository.JournalSelect`,
  `PullItemAdminService` (SQL + validation), `TransactionsExportJob`
  (XLSX header + cell write), `Dashboard/Index.cshtml` (drawer
  items-table "Trail" column + `iefm-trail-id` → `iefm-trial-id` +
  "Trail ID" label → "Trial ID"), `dashboard.js` (modal load + save +
  row render). Smoke `smoke-phase-9-1-pull-extended-fields`
  updated: payload key, GET assertion, XLSX header check, cleanup
  SQL, plus marker value `P91-TRAIL` → `P91-TRIAL` for consistency.
- No data migration needed — `sp_rename` preserves all stored values.

### Notes
- Historical migrations `db/024` + `db/025` are NOT edited (they
  stay as their original shipped form). Fresh installs run the
  sequence `024 (create TrailId) → 025 (view w/ TrailId) → 026
  (rename) → 027 (view w/ TrialId)` and land in the corrected
  end-state.
- Wire format / JSON keys flip: clients sending `trailId` will be
  silently ignored (ASP.NET binder skips unknown keys) — the Phase
  9.1 modal/API only just shipped at v2.3.1 so no external integrations
  exist yet.
- Battery: 42/42 PASS.

---

## [2.3.1] — 2026-05-25 — Phase 9.1: 7 ERP-sourced PullItem fields

### Added
- Migration `db/024` — 7 nullable `NVARCHAR(50)` columns on `dbo.PullItems`:
  `ProductFamily`, `FromSubInventory`, `ToSubInventory`, `SpecialControl`,
  `TrailId`, `Location`, `[Phase]`. Same idempotent per-column
  `COL_LENGTH` pattern as `db/021`.
- Migration `db/025` — `CREATE OR ALTER vw_TransactionsJournal` appending
  the 7 PullItem fields. `pi.Location` aliased `PullLocation` to avoid
  collision with the Phase 9 `PurchaseOrderLines.Location` column;
  `pi.[Phase]` aliased `PullPhase` so readers don't bracket-escape too.
- `PullItem` entity + `PullItemDto` (read shape) + nested `PullItemRow`
  projection all gain 7 new nullable properties; `PullRepository`'s 3
  item-grained SELECTs (`GetByIdAsync`, `GetItemsAsync`,
  `GetItemByIdAsync`) project them.
- New DTO `PullItemExtendedFieldsUpdateRequest` (bulk-overwrite shape).
- New endpoint **PUT `/api/pulls/{id}/items/{itemId}/extended-fields`** —
  `CanManagePulls` policy (admin OR supervisor); refuses closed pulls
  with 409; writes one audit row per call. Service layer reuses the
  existing `LockPullAsync` → `RefuseClosed` → `LockItemOnPullAsync`
  pattern so concurrency semantics match the rest of the items surface.
- Dashboard drawer items table grows 7 visually-grouped ERP columns
  (`Family`, `From Sub`, `To Sub`, `Trail`, `Loc`, `Phase`, `Special`)
  with `--surface-2` background tint + mono 11px font + ellipsis-clamp
  at 110px + left border separator. Tag icon in actions opens the new
  `itemExtendedFieldsModal`. Blank inputs save as `NULL` to keep the
  ERP-vs-Receivx value comparison clean for the Phase 10 push.
- `ReceiptJournalRow` DTO + `JournalSelect` SQL extend with 7 new
  columns; `TransactionsExportJob` writes them as columns 24..30 in
  the XLSX (`SpecialControl`-last ordering matches the drawer band).
- Smoke `smoke-phase-9-1-pull-extended-fields.ps1` covers 9 paths:
  schema (db/024) · view (db/025) · API round-trip (PUT + GET) ·
  operator-blocked 403 · closed-pull 409 · audit row written · XLSX
  headers · XLSX marker value via PullItem JOIN · cleanup. Picks an
  open pull dynamically (no hard-coded fixture) so it's rerunnable.
- `WaitForFile` smoke helper hardened: waits for non-zero size AND
  exclusive-open success, sidestepping a Hangfire-mid-write race the
  original 0-byte path-exists check fell into.

### Notes
- **Editable by operators**, unlike the Phase 9 PO Line fields: the
  ERP push isn't a hard prerequisite — supervisor/admin can fill in
  the gap by paper/email until Phase 10 lands.
- No indexes — same policy as `db/021`/Phase 9; observe before adding.
- Battery: **42/42 PASS** (Phase 9.1 smoke added to default battery).

---

## [2.3] — 2026-05-25 — Phase 9: 20 ERP-sourced PO Line fields

### Added
- Migration `db/021` — 20 nullable columns on `PurchaseOrderLines`
  for ERP-sourced metadata: 10 tracking IDs (`InvoiceNo`, `KanbanNo`,
  `AsnNo`, `PCCNo`, `BatchNo`, `ManufacturingControlNo`,
  `ManufacturingReferenceNo`, `CustomerReferenceNo`,
  `ExportDeclarationNo`, `VendorItem`), 6 location (`PalletId`,
  `VmiPalletId`, `Location`, `Building`, `SubInventory`, `ToLocation`),
  2 operations (`ProductionLine`, `OrderRound`), 1 date
  (`DeliveryDate` DATE), 1 free-text (`Note` NVARCHAR(500)).
- `PoLineRow` DTO carries all 20 fields; `GET /api/pos/{id}` surfaces
  them in JSON.
- New repo method `GetLinesForPosAsync(poIds[])` — single SQL JOIN of
  lines → PO header → warehouse for the export pipeline.
- New DTO `PoLineExportRow` with inlined PO header context.
- PO Detail page shows **5 priority ERP columns** (`Invoice`,
  `SubInv`, `ToLoc`, `Pallet`, `VMI Pallet`) with visual grouping
  (`--surface-2` bg tint + `--border` left separator); nulls render
  as muted em-dash with hover-recoverable title tooltip.
- PO Excel export gains a third **"Lines" sheet** (33 cols: PO
  context + line basic + all 20 ERP fields). Existing
  "Purchase Orders" header-summary sheet unchanged — purely additive.
- Smoke `smoke-phase-9-extended-fields.ps1` covers schema, API
  round-trip (visible + hidden fields), and XLSX content verification.
- Planning doc `docs/phase-10-erp-integration.md` — endpoint design,
  upsert semantics, Receivx-managed-field protection, auth options,
  open questions, sub-phase breakdown 10.1–10.7 (~8–12 hr).

### Notes
- **No write API** for these fields — they're ERP-source-of-truth.
  Phase 10 (target tag v3.0) ships `POST /api/erp/pos`.
- **No indexes** — deferred to Phase 10 when ERP query patterns are
  observed.
- Field redistribution from the original 24-field design: SKIPPED 3
  duplicates (`OrderDate`, `CreatedAt`, `ReceivedDate`); RENAMED
  `Round → OrderRound` (SQL reserved word); SIZED `Note` to 500 chars.
- Battery: **41/41 PASS** after pre-existing test-data drift cleanup
  (rogue `PL-DOR-*` smoke artifact deleted, 3 `ReceivedQty` caches
  recomputed from truth).

---

## [2.2] — 2026-05-25 — Phase 8 close

### Added
- **Documentation set** for production deployment, pagination contract,
  and the exports feature: `docs/deployment.md`, `docs/api-pagination.md`,
  `docs/exports.md`.
- `CHANGELOG.md` (this file) — retroactively consolidated v2.0 → v2.1.13.
- `/Exports` pill-style tabs replace the underline-tab styling
  (`refactor(exports)` — visual-only; tab switching logic untouched).

### Notes
- Phase 8 milestone closes here. Phase 9 (ERP-sourced
  PurchaseOrderLines columns) is the next planned slice;
  migration slot `db/021` is reserved for it.
- Smoke battery: **40/40 PASS**.

---

## [2.1.13] — 2026-05-25 — Pending/Downloaded export tabs

### Added
- Two-tab `/Exports` page split: **Pending** (actionable backlog) and
  **Downloaded** (archive). Pending counts cover queued + running +
  failed + succeeded-undownloaded rows whose files are on disk.
- Migration `db/023` — `ExportJobsLog.DownloadedAt` (nullable) plus
  filtered index `IX_ExportJobsLog_UserPending` (rows graduate out as
  they're downloaded → narrow index).
- `GET /api/exports/tab-counts`, `POST /api/exports/{id}/mark-downloaded`,
  optional `?tab=pending|downloaded` filter on `/api/exports/jobs`.
- Smoke `smoke-exports-2tab.ps1` — 9 paths including idempotency,
  cross-user privacy, and DB-level `DownloadedAt` verification.

### Notes
- Asymmetry preserved on purpose: tab-counts hide expired-undownloaded
  rows (badge = actionable), the Pending list keeps them visible with
  an "Expired" pill (list = bucket contents).

---

## [2.1.12] — 2026-05-25 — Nav-bar unread badge

### Added
- Pill badge on the Exports nav entry showing the operator's unread
  completed exports. Polls `/api/exports/unread-count` every 10 s.
- Migration `db/022` — `ExportJobsLog.ReadAt` (nullable); existing
  succeeded rows backfilled as read so day-1 operators don't see a
  flood.
- `GET /api/exports/unread-count`, `POST /api/exports/mark-all-read`
  (both per-user; admin's see-all toggle on `/Exports` does **not**
  widen the badge).
- `app-nav.js` auto-injects `components/exports-badge.js`; compact-dot
  variant for collapsed nav.

---

## [2.1.11] — 2026-05-25 — My Exports page

### Added
- `/Exports` page with status badges, auto-refresh while jobs are in
  flight, and pagination via the shared `mountPagination()` component.
- Migration `db/020` — `dbo.ExportJobsLog` persists every Hangfire
  export job's lifecycle (queued → running → succeeded/failed).
- `GET /api/exports/jobs` — paginated per-user list; admin
  `?all=true` for the see-all view with requester identification.
- `EffectiveStatus` derived per-row: succeeded rows whose files have
  been swept off disk past `Exports:FileLifetime` flip to `expired`.

---

## [2.1.10] — 2026-05-25 — Exports for POs + Audit Log

### Added
- `POST /api/exports/pos` (admin OR supervisor; supervisor pinned to
  session warehouse) and `POST /api/exports/audit-log` (admin only).
- Three job types now share the pipeline: `TransactionsExportJob`,
  `PosExportJob`, `AuditLogExportJob` — all on Hangfire queue
  `exports`, all ClosedXML + MailKit.
- Export buttons on `/Pos` and `/Masters → Audit Log` (hidden until
  JS reveals via `/api/auth/me` role check).
- `AuditExportQuery` + `IAuditRepository.QueryForExportAsync` with the
  Phase 8.1 `IX_Audit_When` date-window index in play.

### Changed
- Enqueue endpoints return `202 Accepted` instead of `200 OK`
  (semantically correct — real work runs later).

---

## [2.1.9] — 2026-05-24 — Admin email diagnostic

### Added
- `/Config → Email test` section (admin-gated): SMTP metadata display,
  send-test form, Gmail-specific troubleshooting tips on failure.
- `GET /api/admin/smtp-config` (metadata + configured flags, **never**
  credentials) and `POST /api/admin/email-test` (sends via the same
  `IEmailService` Hangfire jobs use; surfaces exception detail).
- Smoke `smoke-email-test.ps1` covers all 6 cases including metadata
  leak check and supervisor-blocked at both endpoints.

### Changed
- Phase 8.4 export-smoke timeout bumped 20 s → 30 s to absorb Hangfire
  pickup latency under battery load.

---

## [2.1.8] — 2026-05-24 — Decoupled export pipeline (Phase 8.4)

### Added
- **Hangfire** (`Hangfire.AspNetCore` + `Hangfire.SqlServer` 1.8.x)
  with in-process worker, 2 threads on queue `exports`, SQL-backed
  storage under `[HangFire]` schema.
- **MailKit** (4.x) for Gmail SMTP via STARTTLS:587.
- **ClosedXML** (0.105) for server-side XLSX writing.
- `POST /api/exports/transactions` enqueues a job; worker writes
  `exports/{prefix}-{jobId}.xlsx`, issues an HMAC-SHA256 24h-expiry
  token, emails the requester.
- `GET /api/exports/{id}/download?token=…` — NOT `[Authorize]`; HMAC
  is the authn so recipients can open from any browser session.
- `/hangfire` dashboard (admin only via `HangfireDashboardAuth`).

### Notes
- SMTP unconfigured falls back to a log line — dev doesn't crash.
- Production must set `Exports:SigningKey` + `Smtp:*` via user-secrets.

---

## [2.1.7] — 2026-05-24 — Pagination wireup (Phase 8.2 + 8.3)

### Added
- Shared pagination component: `wwwroot/js/components/pagination.js`
  (`mountPagination()`) with page-aware ellipsis windowing.
- Razor partial `Views/Shared/_Pagination.cshtml` — same DOM shape,
  `<a href="?page=N&...">` for full-reload nav.
- Shared CSS at `wwwroot/css/components/pagination.css` themes both
  variants via existing CSS variables.
- Reports drops the partial below the list pane; Pos + Transactions
  mount the JS control.
- Smokes 8.2 + 8.3 added.

### Changed
- Transactions page size 500 → 50 (matches the rest of the app).
- Filter changes reset to page 1 everywhere.

---

## [2.1.6] — 2026-05-24 — Pagination foundation (Phase 8.1)

### Added
- Migration `db/019_pagination_indexes.sql`: `IX_Pulls_ClosedAt`
  (filtered, INCLUDE WH/PullDate/PullNumber) + `IX_PO_OrderDate`.
- Shared `Models/Pagination.cs`: `PaginatedRequest` (1-based, hard cap
  500) + `PaginatedResponse<T>` (Items + computed TotalPages/HasMore).
- `/api/pos` returns `PaginatedResponse<PoListRow>` via Dapper
  `QueryMultiple` (slice + count in one round trip).
- `/Reports` server-renders `PaginatedResponse<PullSummary>` driven
  by `?page=N&pageSize=M`.
- `data-limit-notice` banner on Transactions: "Showing X of Total.
  Use Export…" when the slice doesn't cover the server total.

---

## [2.1.5] — 2026-05-24 — Reports DO refactor (Phase 7.4)

### Added
- Two-pane Reports layout: closed-pull list left, inline HTML preview
  right.
- Aggregated DO lines (one row per Item × PO·Line, hour column gone)
  via SQL `GROUP BY (PO, PoLineNumber, ItemCode) SUM(QtyReceived)
  HAVING SUM > 0`.
- `GET /api/reports/do/{id}/preview` (HTML fragment from
  `_DoPreview.cshtml`) + `/api/reports/do/{id}/export.pdf`
  (multi-page A4, one DO per PO).
- Print button — opens a stand-alone window with the preview HTML +
  `reports.css` and calls `window.print()`.
- Vendor display fallback: `VendorName → VendorCode → em-dash`.

### Removed
- Standalone `Do.cshtml` page, `/Reports/Do/{id}` route,
  `/Reports/Do/{id}/pdf?dl=1` URL, embedded-PDF iframe pattern.
- `DeliveryOrderService.IReceiptRepository` dependency.

---

## [2.1.4] — 2026-05-23 — DO render (Phase 7.3)

### Added
- Initial DO render via iframe-to-PDF (later refactored away in
  v2.1.5 — see `feedback_fastreport_opensource_web` memory).

---

## [2.1.3] — 2026-05-23 — FastReport.OpenSource bootstrap (Phase 7.2)

### Added
- FastReport.OpenSource + .Web NuGet packages, DI registration,
  `CompanyInfo` options binding. No reports yet — just the bootstrap.

---

## [2.1.2] — 2026-05-23 — `Pulls.ReferenceNumber` (Phase 7.1)

### Added
- Migration `db/018_pulls_reference_number.sql`.
- `Pulls.ReferenceNumber` column wired through create/read paths;
  smoke covers persist + read round trip.

---

## [2.1.1] — 2026-05-23 — Close-authorization drawer section

### Added
- Dashboard drawer shows signer name + global role + signature SVG
  + PNG download for closed pulls. Active pulls hide the section.

---

## [2.1] — 2026-05-23 — PullItem admin + Hour Cap + UI polish

### Added
- PullItem authoring inside the Pull drawer's Items grid (replaces
  `tools/add-pull-item.ps1` as the primary path; the script stays as
  a headless / CI fallback).
- `Pulls.LockHourCap` (per-pull strict cap toggle), migration
  `db/017_add_lockhourcap.sql`. Default `true` (strict) at the
  application layer; pre-existing pulls backfilled to `true`.
- UI polish across Dashboard, Receiving, and Pull drawer.

### Notes
- Two parallel "Phase 6" series under v2.1 — PullItem admin uses
  `smoke-phase-6.x.ps1`, Hour Cap uses `verify-hourcap-6.1.ps1` +
  `smoke-hourcap-6.x.ps1`. Don't mix names.

---

## [2.0] — 2026-05-22 — PO-driven FIFO

### Added
- v1 → v2 migration: PO is the quantity cap; receives are
  FIFO-allocated across PO lines server-side.
- Dual-cap model (per-hour `ExpectedQty` when `Pulls.LockHourCap`
  true; PO line `OrderedQty` always).
- Per-pull `Pulls.LockPoByPull` (§3.5) — when true, FIFO scope is
  restricted to POs whose `PullId` matches; otherwise FIFO is
  warehouse-wide. Set at create-time, immutable thereafter.
- `WITH (UPDLOCK, HOLDLOCK, ROWLOCK)` on the FIFO read for
  serializable range protection against double-spend.
- PO immutability (`PUT/DELETE` on PO/PO line refused 409 while any
  receipt references it). `POST /api/pos/{id}/close` is the only
  way to retire a PO with outstanding qty.
- `Receipts` table is append-only by convention (no UPDATE except
  `ReversedById`, no DELETE).
- Cancel restores qty to the **same** PO line the original consumed
  (no FIFO on the way back).
- Migration chain `db/010` → `db/016` (additive 1a → backfill 2 →
  strict 1b → view modernize 3 → smoke sandbox 4 → §3.5 lock-aware
  extension). Apply order + rollback steps in
  `docs/migration/v1-to-v2.md`.

### Notes
- v1 spec preserved at `BUILD_PROMPT.v1.md` for archaeology.
