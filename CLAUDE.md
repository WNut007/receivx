# ReceivingOps — Project Context

Multi-warehouse receiving system. ASP.NET Core 8 MVC + Dapper + SQL Server.
**Currently on v3** of the spec (PO-driven receiving with FIFO allocation
+ Phase 10 ERP integration + Phase 11 admin config editor).
**Status:** v3.1.2 shipped on `main` (2026-05-26, tag `v3.1.2`, pushed
to origin). v3.1.2 closes **Phase 11** — admin-editable configuration
with encrypted secrets storage — across four tags: `v3.0.5` (Phase
11.1 — encryption + storage foundation), `v3.1` (Phase 11.2 — tabbed
UI editor), `v3.1.1` (audit gap closure + admin-only reveal fix), and
`v3.1.2` (UX polish — cron preset dropdown). v3.1.2 adds a 10-preset
dropdown (15 min / 30 min / hourly / 2 4 6 12 hr / midnight / 2 AM /
8 AM) on the Sync Schedule tab with a "Custom (advanced)…" escape
hatch that reveals the cron text input + a link to crontab.guru.
Architecture: hidden `#erpsync-CronExpression` mirror input retains
the `data-key` attribute so the save loop is untouched; the preset
`<select>` and the conditionally-visible custom text input both write
to it. Server validation unchanged (NCrontab gate). v3.1.1 closed 4
audit gaps from the post-v3.1 spec audit: (1) added
`POST /api/admin/config/test/smtp` wrapper (parallel to `/test/erp`,
calls `IEmailService` — the existing `/api/admin/email-test` from
Phase 8.4 stays untouched); (7) `ErpDb:ConnectionString` POST /secret
rejects values missing `Server=` AND `Database=` (cheap typo guard;
full parse still happens at SqlConnection.Open() via `/test/erp`);
(8) `Exports:BaseUrl` PUT requires `https` in Production env
(`IHostEnvironment.IsProduction()` gate — dev/staging still accept
http for localhost convenience); (9) `Exports:SigningKey` POST
/secret enforces min 32 chars (Regenerate writes 44 by default, so
this only constrains the manual /secret path; HMAC safety floor at
256-bit input). Skipped per audit Option A (YAGNI): response-shape
additive aliases (gaps 2-3), Smtp:Host hostname format (gap 4),
Username-if-Password-set conditional (gap 5), Password min length
(gap 6 — Gmail App Password is fixed 16 chars). v3.1.1 also fixed a
v2.1.9-era bug where `config.js:131` used `u.role === 'admin'` —
`/api/auth/me`'s `role` field is the DISPLAY name ("Administrator");
the machine value lives at `roleKey` (matches the convention in
`app-nav.js` + `receiving.js`). Result: the `[data-admin-only]`
section was hidden in every browser since v2.1.9, but the smoke
battery never caught it because all 51 assertions checked markup
presence or backend behavior; none simulated the JS reveal. Phase
11.2 made the flaw user-visible because the new editor lives behind
that gate. Fix: `(u.roleKey || '').toLowerCase() === 'admin'`. Two
new regression guards added (smoke step 5b source-level: config.js
must read `u.roleKey`; step 6b behavioral: `/api/auth/me` for sadmin
must return `roleKey === 'admin'`) — either alone is sufficient,
both together mean the editor is invisible to admins only if both
decay simultaneously. NuGet at Phase 11 baseline (no v3.1.x adds).
`docs/configuration.md §7` rewritten to match shipped reality:
removed mention of a separate Diagnostics tab (editor's 4 tabs
inherently show effective values), clarified that no
`GET /api/admin/erp/connection-test` exists (Phase 10.1 was
sqlcmd-based), documented that the warehouse dropdown sources from
`/api/warehouses` (existing all-authenticated endpoint, not an
admin-specific variant), and noted that supervisor/operator see
`/Config` but the Configuration section is hidden via
`data-admin-only` (API gate is the real boundary). `CHANGELOG.md`
gains a `[3.1.1]` entry covering the 4 ships + 5 skips with
rationale, plus a retroactive `[3.1.0]` consolidation for the
Phase 11 close. **smoke-phase-11-2-config-ui assertions: 30/30
PASS** at v3.1.2 (27 at v3.1.1, 25 at v3.1, 19 at v3.1 ship).
Full battery 49/51 with 2 known Hangfire-contention flakes
(`smoke-phase-8.4-exports`, `smoke-export-extensions`) — both pass
standalone, documented in CLAUDE.md flakes list since v3.1.

v3.1 lineage:
v3.1 shipped Phase 11.2 (and the Phase 11.1 foundation under interim
tag `v3.0.5`). Migration `db/029` adds `dbo.AppSettings` ([Key] PK + [Value] NVARCHAR(MAX) NULL +
EncryptedValue VARBINARY(MAX) NULL + IsSecret BIT + UpdatedAt +
UpdatedBy + PreviousValueHash SHA-256 hex) with
`CK_AppSettings_ValueOrEncrypted` enforcing Value XOR EncryptedValue
per IsSecret (both-NULL allowed for cleared rows so the IsSecret flag
survives a temporary unset). Encryption via ASP.NET Data Protection
API (purpose `AppSettings.v1`, 90-day auto-rotated keys, persisted to
`.dp-keys/` under `ContentRootPath` — gitignored, MUST move with the
DB on backup/restore or every encrypted secret becomes
unrecoverable). `IAppSettingsService` is Singleton (encryption
protector + IConfiguration fallback) and bridges to scoped
`IAppSettingsRepository` + `IAuditService` via `IServiceScopeFactory`
on each call. Read precedence: **env vars > DB > user-secrets >
appsettings.json**. Known secrets (encrypted): `Smtp:Password`,
`ErpDb:ConnectionString`, `Exports:SigningKey`. Bootstrap exclusions
NEVER stored in DB (chicken-and-egg): `ConnectionStrings:Default`,
`DataProtection:KeyDirectory`, `ASPNETCORE_ENVIRONMENT`. Options
binding refactored from `Configure<T>(GetSection())` to
`AddOptions<T>().Configure(...).Configure<IAppSettingsService>(...)`
— two-stage: IConfiguration defaults first, then DB overlay (which
itself resolves env > DB > IConfiguration internally, so the binding
honors the full precedence chain). **Restart-required** — IOptions<T>
binds once at first resolution; no live reload (rejected to keep the
encryption layer + Hangfire worker caching simple). `AppSettingsSeeder`
runs at startup, idempotent (no-op if rows exist); on first boot it
copies the 4 owned sections from IConfiguration into the DB so the
editor has a baseline. Startup health check probes a known encrypted
key; CryptographicException → LogCritical + continue (don't crash —
let admin UI prompt for re-entry). Phase 11.2 UI: `/Config` extended
with admin-only `<section data-admin-only>` containing pill-style
tabs (`.config-tab` mirrors `.exports-tab` from Phase 8.4) — Email /
ERP Connection / Sync Schedule / Exports. Endpoints all
`[Authorize(Roles="admin")]` under `/api/admin/config/`: `GET sections`
(tab metadata + isSecret flags), `GET sections/{name}` (values with
secrets masked as `"***"`), `PUT sections/{name}` (rejects secret
keys → 400 with helpful "use POST .../secret" message), `POST
sections/{name}/secret` (single-secret update; rejects non-secret
keys), `DELETE sections/{name}` (reset to defaults — seeder
re-hydrates on next restart), `POST exports/regenerate-signing-key`
(32-byte `RandomNumberGenerator.GetBytes` → base64 → encrypted),
`POST test/erp` (live `IErpDbConnectionFactory.Create()` + SELECT
@@VERSION with 5s timeout). SMTP test send REUSES existing
`/api/admin/email-test` (Phase 8.4, unchanged). Per-key validation:
Port 1-65535, UseStartTls bool, FromAddress `MailAddress.TryCreate`,
Enabled bool, CronExpression `NCrontab.CrontabSchedule.TryParse`,
TimeoutSeconds 60-3600, BackfillDays 1-365, DefaultWarehouseId Guid +
`IWarehouseRepository.GetListRowAsync` existence check, BaseUrl
`Uri.TryCreate(absolute http/https)`. Errors return `{key, error}`
shape so the UI can highlight the offending field. DefaultWarehouseId
renders as `<select>` populated from `GET /api/warehouses` (existing
authenticated endpoint). Secret display: masked `"***"` + explicit
"Change" workflow (inline reveal of real input + Save/Cancel —
never modal indirection). Signing key has "Regenerate" only (no
operator-entered value — system-generated). Restart banner appears
on every successful save, persistent in session until Dismiss /
F5. JS architecture: 5 files — `config-editor.js` (shell + api
helpers + tab switching + `window.registerConfigTabRenderer`
extension point) + one renderer per tab (`config-editor-{smtp,erpdb,
erpsync,exports}.js`). The 5 native `confirm()` sites in renderers
swapped to `confirmAction({title, message, icon, danger,
confirmLabel})` per `smoke-confirm-modal.ps1` convention. Audit:
every set/delete writes `dbo.AuditLog` (ActionType `config-set` /
`config-delete`, EntityType `AppSettings`, EntityId = the key);
secret messages redact value (`Set Smtp:Password (secret value —
not logged) (prior hash: a3f5...)`). `PreviousValueHash` column on
AppSettings stores SHA-256 of prior bytes for tamper-evident audit
chaining without exposing plaintext. `IAppSettingsService.SetAsync`
takes `updatedBy` explicitly so the seeder can attribute
`[system-seed]` rows and the controllers can attribute admin
displayName. NuGet: + `NCrontab 3.3.3` (MIT, 30KB, single
transitive — no Cronos since Hangfire doesn't expose its parser).
New docs: `docs/security.md` (key custody, bootstrap exclusions,
threat model summary), `docs/configuration.md` (precedence chain,
restart-required workflow, full UI surface in §7). 2 new smokes:
`smoke-phase-11-1-app-settings.ps1` (10 steps — schema/wiring/
seeder/encrypt-decrypt/audit/.dp-keys/end-to-end-via-smtp-config)
+ `smoke-phase-11-2-config-ui.ps1` (19 steps — GET endpoints,
PUT non-secret, PUT rejects secret, POST secret + plaintext-leak
grep against AuditLog, validation per field, regenerate, DELETE
reset, ERP test, operator 403 at all 7 endpoints, bootstrap
exclusions absent from listings). 4 deployment items from Phase 10
deploy-blocker checklist are NOW operator-self-service via `/Config`
instead of requiring a redeploy: `ErpSync:DefaultWarehouseId`,
`Smtp:*`, `Exports:BaseUrl`, `Exports:SigningKey`. Battery at v3.1
ship: 51/51 PASS (later patches in v3.1.1 added 6 new smokes + a
JS reveal-gate fix; v3.1.2 added 3 more — see top status block).

v3.0 lineage:
v3.0 shipped on `main` (2026-05-26, tag `v3.0`). v3.0 closes
**Phase 10** — first external-system integration. Receivx pulls
planning data from an upstream ERP (`BPI_PRS` source table at
`103.13.229.21`) on an hourly Hangfire schedule + on-demand via the
admin "Sync ERP" button (dashboard) or the new `/Admin/ErpSync`
status page. Integration is **PULL** (one-way; Receivx owns the
schedule + failure handling); the earlier PUSH variant was abandoned
mid-planning and lives in git history at `v2.3.2`'s commit of the
spec doc. Concurrency invariants enforced by belt-and-braces:
`[DisableConcurrentExecution(600)]` blocks Hangfire-level recurring
overlap, and the singleton `ErpSyncMutex` (Interlocked-based)
excludes the recurring vs manual paths from each other since
Hangfire's lock scopes per-method. Endpoint pre-flight 409 on
`_mutex.IsRunning` gives operators instant feedback before enqueueing
a phantom job. **Sources of truth:** ERP owns planning fields
(PullDate, item codes, expected qtys, the 7 Phase 9.1 metadata
fields); Receivx owns operational state (Status, signatures,
ReceivedQty, lock flags, Notes, ETA). Per-pull upsert is
transactional — closed pulls SKIP (audit-only, no mutation; behavior
proven by `smoke-phase-10-7-integration.ps1` §2 via a sentinel
PullDate fixture); items missing from a draft flip to
`Status='canceled'` (never DELETE — receipts may FK them).
Migration `db/028` adds `dbo.ErpSyncLog` — the summary table the
status page reads (PK RunId + `IX_ErpSyncLog_StartedAt` covering
index). 18 columns including 8 outcome totals + ElapsedMs +
ErrorMessage; lifecycle is `InsertStartAsync` ('running') →
`MarkSucceededAsync` (totals) or `MarkFailedAsync` (truncated error).
Per-pull detail lives in `dbo.AuditLog` (Phase 10.5) keyed by
`PullNumber`, with `[run <runId>]` correlation in every message:
`etl-create` / `etl-update` inside the pull's tx (commit/rollback
together), `etl-skip` / `etl-error` standalone (visible regardless
of mutation state), `etl-start` / `etl-end` brackets at the run
level. `IAuditService.WriteSystemAsync` overloads pass actor name
explicitly so Hangfire worker threads can attribute rows to
`[system]` (recurring) or the operator's displayName (manual — the
controller captures it before `Enqueue` since HttpContext is gone
on the worker thread). Hangfire worker queues now `["exports",
"erp-sync", "default"]` — exports outrank ETL. New
`ErpSyncAdminController` exposes `POST /trigger` (admin-only, 202+
jobId or 409), `GET /jobs/{jobId}` (Hangfire monitoring), `GET /log`
(paginated `PaginatedResponse<ErpSyncLogRow>`), `GET /log/{runId}`
(drill-down), `GET /state` (`isRunning` for UI auto-disable).
`/Admin/ErpSync` Razor page polls `/state` every 5s + auto-refreshes
the list on running→idle transitions; reuses the `mountPagination`
component from Phase 8. Dashboard gains a JS-revealed admin-only
"Sync ERP" button mirroring the same modal pattern. New doc
`docs/erp-integration.md` is the operator + ops guide
(architecture, configuration, status page, audit drill-down,
troubleshooting, BPI_PRS mapping, security). `docs/deployment.md`
adds the Phase 10 deploy-blocker section (rotate "Pocket"
placeholder password, lock ERP user to read-only with explicit
DENY, firewall/VPN to `103.13.229.21:1433`, set
`ErpSync:DefaultWarehouseId` before flipping `Enabled=true`). 7
new smokes (`smoke-phase-10-1-erp-connection.ps1` through
`smoke-phase-10-7-integration.ps1`) all skip cleanly via a 2-second
TCP probe when ERP is unreachable so dev battery stays green
without VPN. 10.7 verifies cross-table consistency (ErpSyncLog
counters reconcile with per-pull AuditLog row counts; e.g.
`10+449+0+0 == 459`), closed-pull skip BEHAVIOR (sentinel PullDate
held), and mutex 409 under live contention. Battery: 49/49 PASS
at v3.0 tip.

v2.3.2 lineage:
typo fix on v2.3.1 — the Phase 9.1 column shipped as `TrailId`
(T-R-A-I-L) but is actually a manufacturing **trial** identifier
(T-R-I-A-L). Migration `db/026` `sp_rename`s
`dbo.PullItems.TrailId` → `TrialId` (idempotent). Migration `db/027`
re-`CREATE OR ALTER`s `vw_TransactionsJournal` against `pi.TrialId`
(sp_rename doesn't update view bindings, so the view's SELECT would
be invalid between db/026 and db/027 — they're designed to run
together). Rename also propagated to: `PullItem` entity, `PullItemDto`,
`PullItemExtendedFieldsUpdateRequest`, `ReceiptJournalRow`,
`PullRepository` (3 SELECTs + UPDATE + `PullItemRow`),
`ReceiptRepository.JournalSelect`, `PullItemAdminService`,
`TransactionsExportJob` (XLSX col 27 header + cell), dashboard
drawer items-table "Trail" → "Trial" column header,
`iefm-trail-id` → `iefm-trial-id` input id, "Trail ID" → "Trial ID"
label, `dashboard.js` row render + modal load + save payload. Smoke
`smoke-phase-9-1-pull-extended-fields` updated end-to-end: payload
key, GET assertion, XLSX header check, cleanup SQL, marker value
`P91-TRAIL` → `P91-TRIAL`. No data migration needed (`sp_rename`
preserves values). Historical `db/024` + `db/025` left untouched —
fresh installs run `024 → 025 → 026 → 027` and land in the
corrected end-state. Battery: 42/42 PASS at v2.3.2 tip.

v2.3.1 lineage:
ships **Phase 9.1** — 7 ERP-sourced fields on `dbo.PullItems`:
`ProductFamily`, `FromSubInventory`, `ToSubInventory`, `SpecialControl`,
`TrialId` (renamed from `TrailId` in v2.3.2),
`Location`, `[Phase]` (all `NVARCHAR(50) NULL`). Migration
`db/024` adds the columns with the same idempotent per-column
`COL_LENGTH` pattern as `db/021`. Migration `db/025`
`CREATE OR ALTER vw_TransactionsJournal` to append the 7 PullItem
fields — `pi.Location` aliased `PullLocation` to dodge collision
with the Phase 9 `PurchaseOrderLines.Location`; `pi.[Phase]` aliased
`PullPhase`. **Unlike Phase 9, these fields are editable in-app**:
operators (admin + supervisor, gated by `CanManagePulls`) can fill
the gap until the Phase 10 ERP push lands. New endpoint **PUT
`/api/pulls/{id}/items/{itemId}/extended-fields`** — bulk-overwrite
DTO `PullItemExtendedFieldsUpdateRequest`; refuses closed pulls with
409; writes one audit row per call; reuses the existing service-layer
`LockPullAsync` → `RefuseClosed` → `LockItemOnPullAsync` pattern so
concurrency semantics match the rest of the items surface. Dashboard
drawer's items table grows 7 visually-grouped ERP columns
(`Family`/`From Sub`/`To Sub`/`Trial`/`Loc`/`Phase`/`Special`) with
`--surface-2` bg + mono 11px + ellipsis-clamp 110px + left border
separator. Tag icon in the actions column opens new
`itemExtendedFieldsModal`. Blank inputs save as NULL so the
ERP-vs-Receivx value comparison stays clean for Phase 10. Excel
export: `ReceiptJournalRow` DTO + `JournalSelect` SQL extend with 7
new columns; `TransactionsExportJob` writes them as cols 24..30
(SpecialControl-last to match the drawer band). View JOIN does all
the work — no separate repo method or join at export time.
Smoke `smoke-phase-9-1-pull-extended-fields` covers 9 paths: schema
(db/024), view (db/025), API round-trip (PUT + GET), operator
blocked (403), closed pull rejected (409), audit row, XLSX headers,
XLSX marker value end-to-end via PullItem JOIN, cleanup.
`WaitForFile` helper hardened to wait for non-zero-size +
exclusive-open success (avoids Hangfire-mid-write race).
**Battery: 42/42 PASS** at v2.3.1 tip (re-verified at v2.3.2 after rename).

v2.3 lineage: shipped **Phase 9** — schema + display + Excel prep
for the Phase 10 ERP integration. Migration `db/021` adds 20
nullable columns to
`PurchaseOrderLines`: 10 tracking IDs (`InvoiceNo`, `KanbanNo`,
`AsnNo`, `PCCNo`, `BatchNo`, `ManufacturingControlNo`,
`ManufacturingReferenceNo`, `CustomerReferenceNo`,
`ExportDeclarationNo`, `VendorItem`), 6 location fields (`PalletId`,
`VmiPalletId`, `Location`, `Building`, `SubInventory`, `ToLocation`),
2 operations (`ProductionLine`, `OrderRound`), 1 date (`DeliveryDate`
DATE), 1 free-text (`Note` NVARCHAR(500)). Per-column COL_LENGTH
guards match project's idempotent convention. **No indexes** —
deferred to Phase 10 when ERP query patterns are observed; speculative
indexes waste write throughput on cold paths. **No write API** — these
fields are ERP-source-of-truth, populated by Phase 10's
`POST /api/erp/pos`. Existing `PoCreateRequest` / `PoUpdateRequest`
DTOs intentionally don't mention them. Field redistribution from the
original 24-field design: SKIPPED 3 duplicates (`OrderDate` on PO
header, `CreatedAt` audit, `ReceivedDate` on Receipts), RENAMED
`Round → OrderRound` (SQL reserved word), SIZED `Note` to 500 chars
(matches `PurchaseOrders.Notes`). `PoLineRow` DTO carries all 20; repo
`GetDetailAsync.linesSql` selects them so `GET /api/pos/{id}` surfaces
the full set without extra round trip. PO Detail page shows **5
priority ERP columns** (`Invoice`, `SubInv`, `ToLoc`, `Pallet`, `VMI
Pallet`) to the right of `Remaining`, visually grouped via
`--surface-2` bg tint + `--border` left separator; mono 11px font
matches the convention for machine-sourced identifiers; nulls render
as muted em-dash. Other 15 fields = API + Excel only (PO detail is
already wide). Excel export gets a new **third "Lines" sheet** (33
cols: 8 PO context + 5 line basic + 20 ERP) via new repo method
`GetLinesForPosAsync(poIds[])` — single SQL JOIN of lines → PO header
→ warehouse, ordered by (PoNumber, LineNumber). Existing
"Purchase Orders" header-summary sheet is unchanged so operators
relying on aggregated `LineCount`/`TotalOrdered`/`TotalReceived` view
aren't affected — purely additive. Smoke `smoke-phase-9-extended-fields`
covers schema (20 cols, Note=500, DeliveryDate=DATE), API round-trip
(8 fields incl. hidden ones — `kanbanNo`, `note`, `deliveryDate`
verified surface in JSON), and XLSX content (Lines sheet exists, 10
sampled ERP headers present, test marker value reaches sheet body).
**Phase 10 spec doc** `docs/phase-10-erp-integration.md` captures the
endpoint design (POST /api/erp/pos, upsert by PoNumber, line upsert by
(PoId, LineNumber), Receivx-managed fields write-protected → 422,
closed/canceled POs → 409), auth recommendation (start with
X-ERP-Api-Key, migrate to OAuth later), open questions for ERP team,
and sub-phase breakdown 10.1–10.7 (~8–12 hr, target tag v3.0).
**Battery: 41/41 PASS** — one pre-existing drift cleanup applied as
part of getting to green (rogue PL-DOR-* test pull deleted; 3 PO line
ReceivedQty caches recomputed from `SUM(Receipts.QtyReceived)` truth).
Both fixes are within CLAUDE.md conventions (the ReceivedQty cache is
explicitly denormalized/reproducible; the deleted pull had 0 receipts
and was a crashed-smoke artifact).

v2.2 lineage: closes Phase 8 with the documentation set + retroactive changelog: new
`docs/deployment.md` (env reqs, migration order incl. db/021 reserved
for Phase 9, user-secrets block, Hangfire dashboard auth, file-
lifecycle gap with operational janitor recipe, hardening checklist),
`docs/api-pagination.md` (PaginatedRequest 1-based + 500-row cap +
PaginatedResponse<T> with computed TotalPages/HasMore, JSON vs
server-rendered surfaces, mountPagination + _Pagination.cshtml,
filter-changes-reset-page-1 convention), `docs/exports.md` (3 job
types + permission matrix, enqueue→run→email→download lifecycle,
HMAC-SHA256 token format `base64url(payload).base64url(HMAC)` with
24h expiry, 2-tab UI, status state machine incl. derived `expired`,
Hangfire retry policy `[AutomaticRetry(Attempts=3, DelaysInSeconds={30,120,600})]`,
troubleshooting matrix), and `CHANGELOG.md` (Keep a Changelog format,
v2.0 → v2.2 retroactively consolidated from this status footer + git
tag history). Also: `/Exports` pill-style tabs replace underline tabs
(visual-only CSS refactor — `.exports-tabs` becomes a tight inline-
flex container with `--surface` bg + 10px radius, `.exports-tab`
pills with `--accent` fill on active state; midnight theme gets a
dark-overlay override for the in-pill badge since `--accent-fg`
flips to near-black there; JS untouched — all selectors survive).
Battery: 40/40 PASS. **Operational gaps documented** (not fixed): no
recurring file-cleanup job exists — `docs/deployment.md §5` ships a
host-cron recipe as the interim. Phase 8 closed; Phase 9 (ERP-sourced
PurchaseOrderLines columns) is next, migration slot `db/021` reserved.

v2.1.13 lineage: splits **/Exports into Pending /
Downloaded tabs**. Migration `db/023` adds
`ExportJobsLog.DownloadedAt` (nullable) + filtered index
`IX_ExportJobsLog_UserPending` (WHERE Status='succeeded' AND
DownloadedAt IS NULL — narrow predicate keeps the index tiny because
rows graduate out as soon as the operator clicks Download).
Repository gains `GetTabCountsAsync` (Pending = queued+running+failed
PLUS succeeded-undownloaded × on-disk file set intersection;
Downloaded = succeeded + DownloadedAt set) and `MarkDownloadedAsync`
(WHERE RequesterUserId = @UserId privacy guard, idempotent — second
call returns 0 rows = controller 404). New endpoints `GET
/api/exports/tab-counts` and `POST /api/exports/{id}/mark-downloaded`
+ `/jobs` accepts optional `?tab=pending|downloaded` filter (purely
additive). `/Exports` page: tabs above the section card, Pending
default, empty-state copy adapts per tab, Download click → fire-and-
forget mark-downloaded → 800ms later list+counts refresh → row drifts
to Downloaded. Re-click in Downloaded tab still grabs the file but
skips the mark call. Asymmetry preserved on purpose: tab-counts
filter out expired-undownloaded rows (badge = actionable) while the
Pending list keeps them visible with "Expired" pill (list = bucket
contents). Smoke `smoke-exports-2tab` covers all 9 paths incl.
idempotency + cross-user privacy + DB-level DownloadedAt verify.
Battery: 40/40 PASS.

v2.1.12 lineage: nav-bar badge for unread completed exports so
operators don't have to keep checking /Exports or their inbox.
Migration `db/022` adds `ExportJobsLog.ReadAt` (nullable) +
backfills existing succeeded rows as read so day-1 operators don't
face a flood. Endpoints `GET /api/exports/unread-count` and
`POST /api/exports/mark-all-read` are per-user (admin's see-all
toggle does NOT widen the badge). Count uses the on-disk file scan
so expired files don't inflate it. `app-nav.js` renders
`#exports-badge` inside the Exports menu entry (pill-shaped + subtle
pulse on count-increase + compact-dot variant for collapsed vertical
nav) and auto-injects `wwwroot/js/components/exports-badge.js`.
Badge polls every 10s, silent on network errors. `/Exports` page
calls mark-all-read after initial render + manually refreshes the
badge for instant clear.

v2.1.11 lineage: My Exports page — visibility UI for export job status. New `dbo.ExportJobsLog` table (migration
`db/020`) persists every Hangfire export job's lifecycle (queued →
running → succeeded/failed). `ExportService.Enqueue*Async` writes the
queued row BEFORE handing to Hangfire; each `*ExportJob.RunAsync`
updates running on entry + succeeded/failed on exit (failure path
rethrows so Hangfire's `[AutomaticRetry]` still triggers). New
`/api/exports/jobs` endpoint returns `PaginatedResponse<ExportJobView>`
— per-user by default, admin can pass `?all=true` for the see-all
view which fills in RequesterEmail/Name. `EffectiveStatus` is derived
per-row: a Status='succeeded' row whose file has been swept off disk
past `Exports:FileLifetime` flips to 'expired'. `/Exports` page reuses
the shared `mountPagination()` component; auto-refreshes every 5 s
while any row is in flight (queued or running), goes quiet otherwise.
Status badges (queued/running/succeeded/failed/expired) themed via
existing CSS vars. Nav: 'My Exports' entry between Reports and Master
Data (every authenticated user sees their own; admin's see-all toggle
on the page itself). Smoke `smoke-my-exports` covers 7 paths incl.
non-admin `?all=true` privacy boundary (regression guard: admin's job
must not leak into supervisor's response). Battery: 38/38 PASS.

v2.1.10 lineage: Phase 8.4 export pipeline extended to /Pos +
/Masters Audit Log — Three jobs now produce XLSX via the
same path (TransactionsExportJob + PosExportJob + AuditLogExportJob,
all on Hangfire "exports" queue, all using ClosedXML +
MailKitEmailService). New endpoints: POST `/api/exports/pos` (admin OR
supervisor — procurement leads need it; supervisor pinned to session
WH) and POST `/api/exports/audit-log` (admin only — audit data is
sensitive). Download path globs the exports/ dir by jobId hex, so new
job types add cleanly without controller change. Files: transactions-,
pos-, audit-log- prefixes. Export buttons added: `/Pos` header (next
to Refresh, hidden until JS reveals for admin/supervisor),
`/Masters → Audit Log` toolbar (hidden until admin via
`/api/auth/me`). New AuditExportQuery + `IAuditRepository.QueryForExportAsync`
(parallel to existing 500-row-capped QueryAsync, bumped to 100K +
adds OccurredFrom/To date window covered by IX_Audit_When). POSTs
return 202 Accepted (was 200 OK, now semantically correct since real
work runs later). Smoke `smoke-export-extensions` covers all 4 paths
+ permission matrix (operator/supervisor 403 where expected). Battery:
37/37 PASS.

v2.1.9 lineage: admin email diagnostic —
`AdminEmailController` with `GET /api/admin/smtp-config` (metadata +
configured flags, NEVER credentials) and `POST /api/admin/email-test`
(send a test via the same `IEmailService` Hangfire jobs use, surfaces
exception detail on failure). `/Config` page gains an admin-gated
"Email test" section: SMTP config display + test form + alert panel
with Gmail-specific troubleshooting (app-password / 2FA / firewall /
TLS) on failure. UI hidden via `[data-admin-only]` toggled by
`/api/auth/me` role check; endpoints have their own
`[Authorize(Roles="admin")]` gate so UI is convenience-only.
`smoke-email-test` covers all 6 cases (metadata leak check, input
validation, valid send, supervisor-blocked at both endpoints, page
DOM hooks). Bumped the 8.4 export-smoke timeout 20s → 30s to absorb
Hangfire pickup latency under battery load. Battery: 36/36 PASS.

v2.1.8 lineage: Phase 8.4 — decoupled export pipeline.
**Stack added:** Hangfire.AspNetCore + Hangfire.SqlServer 1.8.x
(background jobs persisted in the existing DB under `[HangFire]`
schema, in-process worker with 2 threads on the "exports" queue);
MailKit 4.x (Gmail SMTP via STARTTLS:587); ClosedXML 0.105 (server-
side XLSX writer). **Flow:** Transactions Export button POSTs to
`/api/exports/transactions` with the current filter; controller forces
non-admin's `WarehouseId` to session-WH; `ExportService` enqueues a
Hangfire job with the pre-generated jobId; `TransactionsExportJob`
fetches up to MaxRows (100K), writes XLSX to
`src/ReceivingOps.Web/exports/{jobId}.xlsx`, issues an HMAC-SHA256-
signed token (24h expiry), emails the requester via MailKit. Download
endpoint at `/api/exports/{id}/download?token=...` is NOT
`[Authorize]` — the HMAC IS the authn (recipient may open from a
different browser session). Hangfire dashboard at `/hangfire`
admin-only. SMTP unconfigured in dev falls back to log line
(`MailKitEmailService.SendAsync` no-ops gracefully + logs the email).
Production must set `Exports:SigningKey` + `Smtp:*` via user-secrets.
Battery: 35/35 PASS.

v2.1.7 lineage: Phase 8.2 + 8.3 — shared pagination component + wiring. `wwwroot/js/components/pagination.js`
exposes `mountPagination({page, pageSize, total, onChange})` with
page-aware ellipsis windowing (always shows first + last + cur±1);
`Views/Shared/_Pagination.cshtml` is the Razor partial with the same
DOM shape but `<a href="?page=N&...">` for full-reload nav. One
`wwwroot/css/components/pagination.css` themes both via existing CSS
variables. Reports drops the partial below the list pane (server-
rendered, BaseQuery preserves filters across navigation); Pos +
Transactions mount the JS control. Filter changes reset to page 1
everywhere. Transactions PAGE_SIZE flipped 500 → 50 (matches the rest
of the app); data-limit-notice banner kept as the "use Export for
everything" CTA. Smokes 8.2 (Node module assertions + served-file
checks) and 8.3 (per-page wire-up + Reports partial render) added.
Battery: 34/34 PASS.

v2.1.6 lineage: Phase 8.1 — pagination `db/019_pagination_indexes.sql` adds `IX_Pulls_ClosedAt`
(filtered `Status='closed'`, INCLUDE WH/PullDate/PullNumber) +
`IX_PO_OrderDate` (status-agnostic). New `Models/Pagination.cs` carries
shared `PaginatedRequest`/`PaginatedResponse<T>` (1-based page, hard cap
500). `/api/pos` returns `PaginatedResponse<PoListRow>` via Dapper
`QueryMultiple` (page slice + count in one round trip); `pos.js` reads
`.items` + surfaces total in the list-count badge. `/Reports`
server-renders `PaginatedResponse<PullSummary>` driven by
`?page=N&pageSize=M`; result count shows "X of Total". Transactions
endpoint was already paginated since Phase 5/6; v2.1.6 adds the
`data-limit-notice` banner that surfaces "Showing X of Total. Use
Export…" only when the page slice doesn't cover the server total.
Smoke `smoke-phase-8.1-pagination.ps1` covers all 4 surfaces. Page nav
UI (prev/next) deferred to Phase 8.3 — for now `?page=N` is the URL
knob. Phase 8.0 plan also called for `IX_Receipts_WhWhen` but Receipts
has no WarehouseId column (lives on Pulls via the join chain);
deferred until Phase 8.5 load test reveals if the join-chain filter
actually needs help. Battery: 32/32 PASS.

v2.1.5 lineage: Phase 7.4 — Reports DO refactor:
two-pane layout (closed-pull list on left, inline HTML preview on right)
+ aggregated lines (one row per Item × PO·Line, hour column gone) +
canonicalized URLs. `/Reports` is now a single page rendering the
two-pane shell; row click fetches
`/api/reports/do/{id}/preview` (HTML fragment from `_DoPreview.cshtml`
partial) and injects it into the preview pane. The Export PDF button
hits `/api/reports/do/{id}/export.pdf` (multi-page A4, one DO per PO).
Print button opens a stand-alone window with the preview HTML +
`reports.css` and calls `window.print()`.

`DoReportData` is the single source of truth — both the HTML partial
and the FastReport programmatic builder consume it, so paper and screen
never drift. Aggregation lives in SQL
(`PullRepository.GetDoReportRowsAsync` — `GROUP BY (PO, PoLineNumber,
ItemCode) SUM(QtyReceived) HAVING SUM > 0`); reversal pair math nets out
because reversal rows carry negative qty and the voided originals are
excluded via `ReversedById IS NULL`. Vendor display fallback:
`VendorName → VendorCode → em-dash` (no more "(unknown vendor)").

Removed: standalone `Do.cshtml` page, the
`/Reports/Do/{id}` route, the `/Reports/Do/{id}/pdf?dl=1` URL, the
embedded PDF iframe pattern (FastReport.OpenSource.Web's missing JS
viewer made it the wrong tool anyway — see
`feedback_fastreport_opensource_web` memory). `DeliveryOrderService`
shed its `IReceiptRepository` dependency.

Lineage: v2.1.4 (`87e8e48`) shipped Phase 7.3 (initial DO render via
iframe-to-PDF). v2.1.3 (`e0e3820`) added FastReport.OpenSource
bootstrap (Phase 7.2). v2.1.2 (`59bcf37`) added
`Pulls.ReferenceNumber` (Phase 7.1).

Earlier lineage: v2.1.6 (`d1c16f8`) shipped Phase 8.1 pagination
foundation. v2.1.5 (`6008fa6`) shipped Phase 7.4 Reports DO refactor.
v2.1.1 (`5d88b86`) added the drawer's close-auth section (signer +
role + signature SVG + PNG download). v2.1 (`3b6ed06`) bundled PullItem
admin (retires `tools/add-pull-item.ps1` as primary path) + Hour Cap
(configurable per-pull strict cap) + UI polish. v2.0 (`a43fab7`)
preserved. 29/29 smoke battery green at v2.1.3 tip. See
`docs/migration/v1-to-v2.md` for the v2 runbook + rollback steps; v2.1
spec lives in `BUILD_PROMPT.md` (§4.4/§4.6/§7.1/§7.2/§7.15/§6 API).

## Stack
- .NET 8 LTS, C# 12
- Dapper (no EF Core, no string concat in SQL)
- SQL Server (local: LAPTOP-CSB3KO3E)
- Cookie auth, PBKDF2 password hashing
- Bootstrap 5.3 + Bootstrap Icons frontend

## Source of truth
- `BUILD_PROMPT.md` — **v2 spec** (read this first). PO is the quantity cap;
  receives are FIFO-allocated across PO lines server-side.
- `BUILD_PROMPT.v1.md` — archived v1 spec (per-hour cap; single-row receive).
  Kept for archaeology only; live build follows v2.
- `mockups/` — HTML files that define the UI exactly (do not redesign).
- `db/` — schema migrations 001–016. Re-runnable: 001/002 idempotent +
  010–014 are the v1→v2 migration chain (additive 1a → backfill 2 → strict
  1b → view modernize 3 → smoke sandbox 4); 015/016 add the §3.5 lock-aware
  extension (PO↔Pull link + per-pull LockPoByPull). Apply order +
  rollback steps documented in `docs/migration/v1-to-v2.md`.

## Conventions
- PascalCase SQL columns matching POCO properties (no Dapper mapping)
- Repositories `Scoped`, services `Scoped`, password hasher `Singleton`
- Every write writes an audit row via `IAuditService`
- Receipts table is APPEND-ONLY (no UPDATE except `ReversedById`, no DELETE)
- All numeric arithmetic is whole units (int, not decimal)

## v2 invariants (load-bearing)
- **Dual-cap model (§7.1)** — receive enforces two independent caps in this
  order: (1) per-hour `ExpectedQty` *when* `Pulls.LockHourCap = true`; (2) PO
  line `OrderedQty` always. Cap 1 fires before the FIFO walk so the operator
  gets the localized error first and no PO line locks are taken when the
  window will reject anyway.
- **PO cap is always the hard limit (§7.1).** No matter the per-pull
  hour-cap setting, total received against a PO line can never exceed
  `OrderedQty`.
- **Per-hour cap is configurable per pull (v2.1, §7.1).**
  `Pulls.LockHourCap` set at create-time and immutable thereafter. Default
  `true` (strict). When `false`, per-hour `ExpectedQty` is a planning hint
  only — legacy v2 behavior. The Phase 6.1 backfill set every existing pull
  to `true`; pre-existing over-state is preserved as-is but FUTURE receives
  on the same window are now blocked.
- **FIFO is server-only (§7.14).** The modal MUST NOT expose a PO selector.
  The server allocates by `PurchaseOrders.OrderDate ASC, PoNumber ASC`.
- **One receive call may produce multiple `Receipts` rows (§7.2a)** when the
  FIFO walk splits qty across PO lines. The response shape is
  `{ allocations[], totalQty, newReceivedQty, fullyReceived }`.
- **Cancel restores qty to the SAME PO line the original consumed (§7.3).**
  No FIFO logic on the way back. Auto-reopens the PO if it had auto-closed.
- **PO immutability (§7.13).** PUT/DELETE on PO or PO line refused (409)
  while any receipt references it. `POST /api/pos/{id}/close` is the only
  way to retire a PO with outstanding qty.
- **Locking pattern**: receive transaction uses
  `WITH (UPDLOCK, HOLDLOCK, ROWLOCK)` on the FIFO read of
  `dbo.PurchaseOrderLines` — gives serializable range protection so two
  concurrent receivers can't double-spend a line. The hour-cap pre-check
  also takes `UPDLOCK + ROWLOCK` on the matching `PullItemWindows` row.
- **§3.5 per-pull lock (§7.15 immutability)**: `Pulls.LockPoByPull` set at
  create-time and immutable thereafter. When true, FIFO scope is restricted
  to POs whose `PullId` matches; otherwise FIFO is warehouse-wide. Audit
  message carries the `Scope:` tag (wire contract per BUILD_PROMPT.md §8.1).
  Application-layer default flipped to `true` (strict-by-default) in v2.1
  — symmetry with LockHourCap. DB column DEFAULT stays `0` so the
  column-add migration didn't retroactively flip pre-feature pulls.
  `PurchaseOrders.PullId` is also immutable post-create — stricter than the
  §7.13 receipt-reference rule (applies even when no receipts reference).
  The v2.1 `LockHourCap` flag follows the same immutability pattern — PUT
  echoes current value or 409.
- **Close gate is hour-cap-agnostic (§7.4).** `POST /api/pulls/{id}/close`
  counts windows where `ExpectedQty > ReceivedQty` (outstanding). Over-
  windows are `Expected < Received` and therefore not outstanding — a pull
  carrying legacy over-state from before the v2.1 migration can still be
  closed normally.

## Workflow
1. Schema first (`db/001_schema.sql` then `db/010_…`–`014_…` for v2) before
   any C# code.
2. Run SQL → verify with `tools/verify-phase-*.ps1` → then build
   repositories → services → controllers.
3. Demo each layer before moving on (see BUILD_PROMPT.md §15).

## Connection string
Local dev only — lives in `dotnet user-secrets` (set by
`tools/verify-phase-1a.ps1` / committed in `appsettings.Development.json`
breadcrumb). Production must use Managed Identity or a vault — never a
hardcoded SQL login.

## Tooling
- `tools/run-smokes.ps1` — aggregate smoke runner (PowerShell 7+).
  Default battery = 16 suites; verify + phase smokes + legacy smokes.
  See `## Smoke test inventory` in memory's `receivx_build_state.md`.
- `tools/HashPassword` — `dotnet run --project tools/HashPassword -- <plaintext>`
  to regenerate PBKDF2 hashes for seed files.
- `tools/slice-*.ps1` + `tools/build-*-view.ps1` — mockup → wwwroot
  pipeline. Pass `-SyncJs` to also overwrite hand-written Stage B JS;
  otherwise JS is preserved across re-slices.
- `tools/add-pull-item.ps1` — interactive PullItem creator. **Superseded
  by v2.1 UI as the primary path** (Pull drawer → Items grid on
  `/Dashboard`); kept as a headless / CI / pre-UI-deploy fallback. Same
  contract: pull-open check, `(PullId, ItemCode)` dedupe, transactional,
  audit row tagged `[script: <SQL_LOGIN>]` to keep scripted mutations
  visually distinct from operator-driven ones. See
  `docs/runbooks/add-pull-items.md`.

## Design decisions (load-bearing)
- **Pulls are upstream artifacts**, analogous to an ASN sourced from an ERP.
  The seed migration `db/006` is the bulk path; ad-hoc adds go through the
  v2.1 UI (Pull drawer → Items grid) or, for headless/scripted use,
  `tools/add-pull-item.ps1`. v2 had no in-app authoring; v2.1 added it
  without changing the upstream-artifact framing — the new endpoints are
  `CanManagePulls`-gated and audit-tagged the same way.
- **Purchase Orders are in-app artifacts** (`/Pos` admin UI, Phase 5c) —
  intentionally different from pulls because procurement *authors* POs
  in-house, while pulls *arrive* from planning.

## v2.x backlog
- **PullItem admin** — DONE in v2.1 (tag `v2.1`, commits `b577aa5`/
  `1301df5`/`e598fbb`/`00b3409`).
- **Pull close note** — **deferred from v2.x close-display work** (commit
  `2241737`). The dashboard drawer now shows signer + role + timestamp
  + signature, but the "Note" field in the approved mockup was Scenario
  D (no schema). To ship it:
  - `db/019_pulls_close_note.sql` — `ALTER TABLE dbo.Pulls ADD CloseNote
    NVARCHAR(500) NULL` (additive, idempotent). **Re-slotted from db/018
    after Phase 7.1 took 018 for ReferenceNumber.**
  - `CloseRequest` DTO gains optional `Note`; `CloseService.CloseAsync`
    persists + audits it (suffix the existing "Closed pull X" audit
    message with the note when present)
  - Receiving page close modal (where the operator signs) gets a note
    input above the signature pad — already-implemented modal lives in
    `wwwroot/js/receiving.js` and `Views/Receiving/Index.cshtml`
  - Dashboard drawer's close-auth section adds the conditional note row
    (the markup hook is already there — see `renderCloseAuth` in
    `dashboard.js` for where it would slot in)
  - Estimated scope: 150-200 LOC across 4-5 files; mirror the Hour Cap
    Phase 6.1-6.4 sub-phase rhythm. Use case: supervisor records context
    like "verified against PO-2401-018" or "partial receive due to
    vendor short-ship". Audit value is medium — signer + role +
    timestamp already cover ~80% of the "who authorized this" story.
- **Profile editor + Help page** — dropdown entries were trimmed in 5f
  pre-merge (commit `e69667a`); restore when there's a real destination.
- **Item-search typeahead in Add-Line modal** — same pattern as the
  pull-search autocomplete (commit `8ebfff8`) once the candidate item
  catalog grows past a few hundred per warehouse.
- **Reports view (Phase 7)** — DO (delivery order) report rendering with
  browser preview + PDF export + multi-page support. **Tool chosen: FastReport
  Open Source** (MIT license, NuGet `FastReport.OpenSource` +
  `FastReport.OpenSource.Web`, .NET 8 compatible, web viewer included,
  basic PDF export — sufficient for internal warehouse DO; no encryption/
  signing needed). Designer = FastReport Designer Community Edition
  (Windows desktop, free). The local commercial copy at `C:\Nut\FastReport
  .NET & FastReport.Core Enterprise v2025.2.12` is **not** to be
  committed — repo stays on the MIT OS package. Migration effort is low
  (2 package refs + DI + 1 controller). Stale NuGet-restore traces in
  `obj/project.assets.json` referencing `fastreport.web 2020.1.12` and
  `fastreport.core3.web.demo 2024.1.6` are leftovers from earlier local
  experimentation; they don't bind to any code.
- Lower-priority janitorial items (operator-dropdown source for
  transactions, audit retention policy) — see memory's
  `receivx_build_state.md` § "Next up".

## Out of scope (don't add unless asked)
See BUILD_PROMPT.md §14.

# Session handoff — 2026-05-26

Latest tag: **v3.1.2** (Phase 11.2 UX polish — cron preset dropdown). Pushed to origin.
Battery: **49/51 in-battery; 51/51 with standalone re-run of 2 flakes** · `main` at `7c3c7c0` · clean
smoke-phase-11-2-config-ui: **30/30 PASS** (was 19 at v3.1 ship).

## Phase 11 — Done (v3.0.5 + v3.1 + v3.1.1 + v3.1.2)

### Phase 11.1 (tag v3.0.5, interim) — encryption foundation

- ✅ Migration `db/029` — `dbo.AppSettings` table with Value-XOR-EncryptedValue CHECK
- ✅ ASP.NET Data Protection wired (purpose `AppSettings.v1`, 90-day key lifetime, `.dp-keys/` gitignored)
- ✅ `IAppSettingsService` (Singleton + IServiceScopeFactory bridge) + `IAppSettingsRepository` (Scoped, Dapper MERGE upsert)
- ✅ `AppSettingsSeeder` — idempotent IConfiguration → DB hydration on first start
- ✅ Options binding refactored: SmtpOptions / ExportOptions / ErpSyncOptions through `AddOptions<T>().Configure<IAppSettingsService>(...)`
- ✅ Precedence: env vars > DB > user-secrets > appsettings.json
- ✅ Startup health check (CryptographicException → LogCritical, don't crash)
- ✅ `docs/security.md` (key custody, threat model) + `docs/configuration.md` (precedence + bootstrap exclusions)
- ✅ Smoke `smoke-phase-11-1-app-settings.ps1` (10 steps)

### Phase 11.2 (tag v3.1) — tabbed UI editor

- ✅ `ConfigController` (GET sections + GET sections/{name}) + `ConfigWriteController` (PUT/POST secret/DELETE reset/regenerate signing key/test ERP)
- ✅ Per-key validation: NCrontab for cron, MailAddress for from, Uri.TryCreate for BaseUrl, range checks, warehouse existence
- ✅ `/Config` admin section replaced: 4 pill-style tabs (Email / ERP Connection / Sync Schedule / Exports)
- ✅ 5 JS files: `config-editor.js` (shell) + `config-editor-{smtp,erpdb,erpsync,exports}.js` (renderers via `registerConfigTabRenderer`)
- ✅ Secrets masked `"***"`; "Change" workflow (inline reveal) for password/connection string; "Regenerate" only for signing key
- ✅ DefaultWarehouseId `<select>` populated from `/api/warehouses`
- ✅ Restart banner appears on save (session-persistent until Dismiss)
- ✅ All 5 confirm() sites swapped to `confirmAction(...)` per smoke-confirm-modal convention
- ✅ + `NCrontab 3.3.3` NuGet
- ✅ Smoke `smoke-phase-11-2-config-ui.ps1` (19 steps: GETs/PUTs/POST secret/validation/regenerate/DELETE reset/ERP test/operator 403 at all 7 endpoints/bootstrap exclusions absent)
- ✅ Tag v3.0.5 (Phase 11.1) + v3.1 (Phase 11.2)

### Phase 11.2 audit closure (tag v3.1.1) — gap fixes + admin-reveal

- ✅ `POST /api/admin/config/test/smtp` wrapper (parallel to `/test/erp`; existing `/api/admin/email-test` untouched)
- ✅ `ErpDb:ConnectionString` POST /secret rejects values missing `Server=` AND `Database=` (400 + helpful error)
- ✅ `Exports:BaseUrl` PUT requires `https://` in Production (`IHostEnvironment.IsProduction()`); dev/staging unchanged
- ✅ `Exports:SigningKey` POST /secret min 32 chars (Regenerate writes 44 by default; this floors the manual path)
- ✅ Skipped per audit Option A (YAGNI): response-shape additive (gaps 2-3), hostname format / Username conditional / Password length (gaps 4-6)
- ✅ **Bug fix:** `config.js:131` admin-only reveal gate was `u.role === 'admin'` (display name) since v2.1.9 — switched to `u.roleKey` (machine value, matches `app-nav.js` + `receiving.js`). The bug kept the entire admin section hidden in every browser for any admin user; Phase 11.2 made it user-visible because the new editor lives behind the gate
- ✅ 2 new smoke regression guards (5b source: config.js reads `u.roleKey`; 6b behavioral: /api/auth/me returns `roleKey='admin'` for sadmin)
- ✅ 4 docs `docs/configuration.md §7` items synced to shipped reality (no `/api/admin/erp/connection-test`, no separate Diagnostics tab, warehouse dropdown via `/api/warehouses`, supervisor visibility model)
- ✅ `CHANGELOG.md` [3.1.1] + retroactive [3.1.0] entries

### Phase 11.2 UX polish (tag v3.1.2) — schedule preset dropdown

- ✅ Sync Schedule tab cron input → 10-preset dropdown (15min / 30min / hourly / 2 4 6 12 hr / midnight / 2 AM / 8 AM) + "Custom (advanced)…" escape hatch
- ✅ Hidden `#erpsync-CronExpression` mirror input retains `data-key` so the save loop is untouched; preset `<select>` + custom `<input>` both write to it
- ✅ Custom branch reveals text input + link to crontab.guru
- ✅ Initial render: matches preset → dropdown selected, custom wrap hidden. No match → dropdown on "Custom", custom input pre-filled
- ✅ Server validation unchanged — NCrontab still validates every cron, presets and custom go through the same gate
- ✅ New CSS `.config-field-secondary` (12px left-border indent) — named generically for future reveal-on-Custom patterns
- ✅ 3 new smoke assertions (preset round-trip, custom round-trip, source-level dropdown wiring)

## Production blockers — UI-editable now

These 4 items used to require `dotnet user-secrets set ... + redeploy`. With
v3.1 they are operator-self-service via `/Config`:

- `ErpSync:DefaultWarehouseId` (was GUID-of-zeros) → Sync Schedule tab
- `Smtp:Host` / `Port` / `Username` / `FromAddress` / `Password` → Email tab
- `ErpDb:ConnectionString` (rotate the placeholder password) → ERP Connection tab
- `Exports:BaseUrl` / `SigningKey` (32-byte random) → Exports tab

Still strictly deployment-side (NOT in AppSettings — bootstrap exclusions):

- `ConnectionStrings:Default` — opens the DB that holds AppSettings
- `DataProtection:KeyDirectory` — needed to decrypt anything
- `ASPNETCORE_ENVIRONMENT`

**`.dp-keys/` custody is now a deploy concern.** Lose the directory →
every encrypted secret in DB is unrecoverable. Back up alongside the DB.
`docs/security.md` is the operator guide.

## v3.x backlog (defer)

- closeNote vertical slice (~150-200 LOC) — drawer hook ready in renderCloseAuth
- Exports cleanup Hangfire job (file purge 7-day; host-cron recipe in `docs/deployment.md §5` is the interim)
- Profile editor + Help page (restore dropdown when destinations exist)
- Item-search typeahead in Add-Line modal (when catalog grows)
- Operator-dropdown source for /Transactions (janitorial)
- Audit retention policy (design decision needed)
- Phase 11.2 "re-import from config files" admin button (alternative to manual `DELETE FROM dbo.AppSettings` + restart)
- Phase 12: PO data source — Phase 9's 20 ERP-sourced PurchaseOrderLines columns currently have no writer; either extend the BPI_PRS pull or add a vendor PUSH endpoint

## Known flakes (pre-existing; pass standalone)

- `smoke-phase-8.4-exports.ps1`, `smoke-export-extensions.ps1`, `smoke-my-exports.ps1`, `smoke-exports-badge.ps1`, `smoke-exports-2tab.ps1` — Hangfire worker contention under battery load. Each passes on standalone re-run. Battery is reliably 51/51 after one retry; never had genuine regressions across Phases 10 + 11.

## Gmail App Password — episodic block

Gmail auto-blocks the configured App Password after ~30+ rapid SMTP sends in a day (e.g. running the full smoke battery several times back-to-back). Symptom: every mail-dependent smoke fails with `5.7.8 Username and Password not accepted`. Recovery: wait ~1-6h for the block to lapse, OR rotate the App Password at `myaccount.google.com/apppasswords` and update via `/Config` → Email tab → Password row → "Change". Test with the Send-test button before re-running the battery.

## Dev-environment notes

- Run smoke battery with `dotnet run --launch-profile http` (NOT `https`). The https profile activates `UseHttpsRedirection` which returns 307 instead of 302 on auth redirects, breaking `smoke-phase-5c`.
- `.dp-keys/` lives under `src/ReceivingOps.Web/.dp-keys/` in dev (under `ContentRootPath`). Already gitignored at both `/` and `src/ReceivingOps.Web/` paths.