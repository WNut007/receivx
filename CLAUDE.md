# ReceivingOps — Project Context

Multi-warehouse receiving system. ASP.NET Core 8 MVC + Dapper + SQL Server.
**Currently on v2** of the spec (PO-driven receiving with FIFO allocation).
**Status:** v2.1.10 shipped on `main` (2026-05-25, tag `v2.1.10`,
pushed to origin). v2.1.10 extends the Phase 8.4 export pipeline to
**/Pos + /Masters Audit Log**. Three jobs now produce XLSX via the
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
