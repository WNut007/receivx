# Changelog

All notable changes to ReceivingOps are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Retroactive entries below were consolidated at v2.2 from CLAUDE.md
status-footer history; per-tag commit hashes are the source of truth
for fine-grained authorship.

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
