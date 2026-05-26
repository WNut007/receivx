# Changelog

All notable changes to ReceivingOps are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Retroactive entries below were consolidated at v2.2 from CLAUDE.md
status-footer history; per-tag commit hashes are the source of truth
for fine-grained authorship.

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
