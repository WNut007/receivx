# ReceivingOps — Project Context

Multi-warehouse receiving system. ASP.NET Core 8 MVC + Dapper + SQL Server.
**Currently on v2** of the spec (PO-driven receiving with FIFO allocation).
**Status:** v2.0 shipped on `main` (2026-05-23, tag `v2.0`). v2.1 in
progress on `v2.1-migration` — Phases 6.1/6.2/6.3/6.4 done (PullItem
admin: backend CRUD + windows sub-resource + drawer UI + add-pull-item
script retired). 19/19 smoke battery green. See `docs/migration/v1-to-v2.md`
for the v2 runbook + rollback steps.

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
- **PO cap is the hard limit (§7.1).** Per-hour `PullItemWindows.ExpectedQty`
  is a planning hint; overage is allowed if PO capacity exists.
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
  concurrent receivers can't double-spend a line.
- **§3.5 per-pull lock (§7.15 immutability)**: `Pulls.LockPoByPull` set at
  create-time and immutable thereafter. When true, FIFO scope is restricted
  to POs whose `PullId` matches; otherwise FIFO is warehouse-wide. Audit
  message carries the `Scope:` tag (wire contract per BUILD_PROMPT.md §8.1).
  `PurchaseOrders.PullId` is also immutable post-create — stricter than the
  §7.13 receipt-reference rule (applies even when no receipts reference).

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

## v2.1 backlog
- **PullItem admin** — DONE (Phases 6.1/6.2/6.3/6.4 on `v2.1-migration`).
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
