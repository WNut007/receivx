# ReceivingOps — Project Context

Multi-warehouse receiving system. ASP.NET Core 8 MVC + Dapper + SQL Server.
**Currently on v2** of the spec (PO-driven receiving with FIFO allocation).
**Status:** v2.3.1 shipped on `main` (2026-05-25, tag `v2.3.1`). v2.3.1
ships **Phase 9.1** — 7 ERP-sourced fields on `dbo.PullItems`:
`ProductFamily`, `FromSubInventory`, `ToSubInventory`, `SpecialControl`,
`TrailId`, `Location`, `[Phase]` (all `NVARCHAR(50) NULL`). Migration
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
(`Family`/`From Sub`/`To Sub`/`Trail`/`Loc`/`Phase`/`Special`) with
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
**Battery: 42/42 PASS** at v2.3.1 tip.

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

# Session handoff — 2026-05-25

Latest tag: v2.3.1 (Phase 9.1 close — 7 ERP-sourced PullItem fields)
Battery: 42/42 PASS · main 6 commits ahead of origin/main · all clean

## Phase 9.1 — Done

- ✅ Migration db/024 — 7 nullable ERP columns on PullItems
  (ProductFamily, FromSubInventory, ToSubInventory, SpecialControl,
   TrailId, Location, [Phase])
- ✅ Migration db/025 — CREATE OR ALTER vw_TransactionsJournal appends
  the 7 fields (PullLocation + PullPhase aliased)
- ✅ PullItem entity + PullItemDto + PullItemRow extended
- ✅ PullRepository.UpdateExtendedFieldsAsync + 3 SELECTs project new cols
- ✅ PullItemExtendedFieldsUpdateRequest DTO + service +
  PUT /api/pulls/{id}/items/{itemId}/extended-fields (CanManagePulls)
- ✅ Dashboard drawer items table: 7 visually-grouped ERP columns +
  itemExtendedFieldsModal + tag-icon action
- ✅ ReceiptJournalRow + JournalSelect + TransactionsExportJob extended
  for XLSX (cols 24..30, SpecialControl-last)
- ✅ Smoke smoke-phase-9-1-pull-extended-fields covers 9 paths
  (schema/view/API/operator-403/closed-409/audit/XLSX headers/XLSX
  marker via PullItem JOIN/cleanup)
- ✅ WaitForFile helper hardened (non-zero size + exclusive-open)
- ✅ Tag v2.3.1 — Phase 9.1 milestone closed

## Phase 9 — Done

- ✅ Migration db/021 — 20 nullable ERP columns on PurchaseOrderLines
- ✅ PoLineRow DTO + GetDetailAsync SELECT extended
- ✅ PO Detail page shows 5 priority ERP columns
- ✅ Excel export gains "Lines" sheet (33 cols incl. all 20 ERP)
- ✅ Smoke smoke-phase-9-extended-fields covers schema + API + XLSX
- ✅ docs/phase-10-erp-integration.md spec doc (planning only)
- ✅ Tag v2.3 — Phase 9 milestone closed

## Operational gap addressed during Phase 9 ship

- **Test-data drift cleanup** — one rogue `PL-DOR-*` test pull (no
  receipts, crashed-smoke artifact) deleted; 3 PO line `ReceivedQty`
  caches recomputed from `SUM(Receipts.QtyReceived)` truth. Both
  within CLAUDE.md conventions: the cache is documented as
  denormalized/reproducible, and the deleted pull had no receipts so
  the append-only invariant on Receipts wasn't touched. **Root cause
  unfixed:** smoke teardowns that create receipts then DELETE them
  don't recompute the cache. Worth a janitorial pass in a future
  slice (low priority — only affects smoke reruns against a dev DB).

## Phase 8 — Done

- ✅ My Exports page (v2.1.11) — ExportJobsLog + auto-refresh + admin see-all
- ✅ Phase 8.5 load test (validated at scale)
- ✅ Phase 8.6 docs (this slice):
  - `docs/deployment.md` — env, migrations, user-secrets, Hangfire, file lifecycle, hardening
  - `docs/api-pagination.md` — PaginatedRequest/Response contract + surfaces
  - `docs/exports.md` — feature doc, lifecycle, HMAC, status states, API ref
  - `CHANGELOG.md` — v2.0 → v2.2 retroactively consolidated
- ✅ Tag v2.2 — Phase 8 milestone closed

## Operational gap noted (not blocking v2.2 ship)

- **No recurring file-cleanup job.** Generated XLSX files live at
  `exports/` (project root, NOT wwwroot) and stay indefinitely.
  Token expires in 24h but the bytes remain. `docs/deployment.md §5`
  ships a host-cron recipe (7-day sweep) as the interim until a
  Hangfire recurring job is added.

## Phase 9 — Designed, ready to implement (~5 hr)

Spec confirmed:
- Add 20 ERP-sourced fields to PurchaseOrderLines (migration db/021)
- Field list (renamed/sized):
  InvoiceNo, Location, PalletId, VmiPalletId, ProductionLine, Building,
  KanbanNo, AsnNo, OrderRound (renamed from Round), SubInventory, ToLocation,
  PCCNo, ManufacturingControlNo, BatchNo, ExportDeclarationNo,
  CustomerReferenceNo, ManufacturingReferenceNo, VendorItem, DeliveryDate (DATE),
  Note (NVARCHAR(500))
- SKIP: OrderDate, CreatedAt, ReceivedDate (duplicates)
- NO indexes (defer to Phase 10)
- NO edit form (data from ERP)
- NO search (defer to Phase 10)

UI display:
- PO Detail line table adds 5 visible columns:
  Invoice, SubInventory, ToLocation, PalletId, VmiPalletId
- Other 15 fields: API + Excel export only

Excel export: all 20 fields included

Tag: v2.3

## Phase 10 — Final phase, spec doc only

ERP integration (POST /api/erp/pos):
- Vendor system pushes PO data → Receivx ingests
- Auth: API key (or OAuth client credentials)
- Upsert by PoNumber (idempotent)
- Preserve Receivx-managed fields (PullId, lock states, ReceivedQty)
- Add search indexes after observing usage patterns

Tag: v3.0 (major release — external integration)

## Production blockers (before deploy)

Run before any non-local deployment:

```powershell
dotnet user-secrets set Exports:BaseUrl https://your.public.host --project src/ReceivingOps.Web
dotnet user-secrets set Exports:SigningKey <random-32-char-string> --project src/ReceivingOps.Web
dotnet user-secrets set Smtp:Host smtp.gmail.com --project src/ReceivingOps.Web
dotnet user-secrets set Smtp:Port 587 --project src/ReceivingOps.Web
dotnet user-secrets set Smtp:UseStartTls true --project src/ReceivingOps.Web
dotnet user-secrets set Smtp:Username <gmail> --project src/ReceivingOps.Web
dotnet user-secrets set Smtp:Password <16-char-gmail-app-password> --project src/ReceivingOps.Web
dotnet user-secrets set Smtp:FromAddress <gmail> --project src/ReceivingOps.Web
```

Currently configured: dev placeholder values

## v2.x backlog (defer)

- closeNote vertical slice (~150-200 LOC) — drawer hook ready in renderCloseAuth
- Profile editor + Help page (restore dropdown when destinations exist)
- Item-search typeahead in Add-Line modal (when catalog grows)
- Operator-dropdown source for /Transactions (janitorial)
- Audit retention policy (design decision needed)
- CHANGELOG.md consolidation (retroactive v2.0 → v2.1.10)