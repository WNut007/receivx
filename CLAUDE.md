# ReceivingOps — Project Context

Multi-warehouse receiving system. ASP.NET Core 8 MVC + Dapper + SQL Server.
**Currently on v2** of the spec (PO-driven receiving with FIFO allocation).
**Status:** v2.1 shipped on `main` (2026-05-23, tag `v2.1` at `3b6ed06`,
pushed to origin). v2.1 bundles PullItem admin (in-app authoring surface,
retires `tools/add-pull-item.ps1` as primary path) + Hour Cap (configurable
per-pull strict cap on per-hour ExpectedQty) + UI polish. 26/26 smoke
battery green. v2.0 tag `a43fab7` preserved. See
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
  - `db/018_pulls_close_note.sql` — `ALTER TABLE dbo.Pulls ADD CloseNote
    NVARCHAR(500) NULL` (additive, idempotent)
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
- Lower-priority janitorial items (Reports view, operator-dropdown
  source for transactions, audit retention policy) — see
  memory's `receivx_build_state.md` § "Next up".

## Out of scope (don't add unless asked)
See BUILD_PROMPT.md §14.
