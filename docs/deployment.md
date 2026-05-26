# Production deployment guide

Last updated: v3.0 (Phase 10 close — ERP integration).
Audience: whoever stands up a non-local ReceivingOps instance.
Scope: configuration, migrations, background-job runtime, operational
gaps. Not a step-by-step "ship to Azure" tutorial — those details depend
on your hosting target.

---

## 1. Prerequisites

| Component | Version | Notes |
|---|---|---|
| .NET runtime | 8.0 LTS | The web project targets `net8.0`. The ASP.NET Core runtime is enough; the SDK is only needed if you build on the host. |
| SQL Server | 2019+ | Tested on local SQL Server. Earlier 2017 may work but `dbo.PurchaseOrderLines` uses computed columns + filtered indexes that were tightened in 2019. |
| SMTP relay | TLS 1.2+ on port 587 | Default config assumes Gmail SMTP with an app password. Any STARTTLS-capable relay works (MailKit picks the right auth). |
| Disk | ~1 GB headroom under app root | XLSX exports land in `exports/` (sibling of `wwwroot/`). Files persist indefinitely — see §6. |
| Outbound network | port 587 to SMTP host, port 1433 to Receivx SQL, port 1433 to ERP SQL | The ERP host is whatever `ErpDb:ConnectionString` points at (Phase 10). If running behind a corporate firewall, allow all three before first start or Hangfire jobs will pile up failed retries. |
| ERP SQL access | Read-only login on the ERP DB | Phase 10 pull-style integration. `BPI_PRS` (and any joined tables) must be readable by the connection-string user. See §3 + `docs/erp-integration.md` §4.3. |

The Hangfire dashboard and the export download endpoint are served by
the same web process — no separate worker is required.

---

## 2. Database setup

### 2.1 Connection string

Lives in `ConnectionStrings:Default`. The repo does **not** ship a
connection string in `appsettings.json` (intentional — keeps SQL
credentials out of git). Provide it via one of:

- **Local / dev:** `dotnet user-secrets` (see §3).
- **Production:** environment variable `ConnectionStrings__Default`,
  Managed Identity (Azure SQL), or an injected secret from your vault.

If `ConnectionStrings:Default` is missing at startup, Hangfire
initialization throws — the app refuses to start with no DB. That is
deliberate.

### 2.2 Migration order

Run as a `sqlcmd` script in this order. Every file is re-runnable
(idempotent `IF NOT EXISTS` guards on every `CREATE`).

```
db/001_schema.sql                   -- baseline v1 schema
db/002_views.sql                    -- baseline v1 views
db/003_seed_users.sql               -- admin user + PBKDF2 hash placeholder
db/004_seed_warehouses.sql          -- 3 warehouses
db/005_seed_assignments.sql         -- user↔warehouse role grants
db/006_seed_pulls_and_items.sql     -- sample upstream pulls
db/007_seed_purchase_orders.sql     -- sample POs

db/010_schema_v2_additive.sql       -- adds v2 columns (nullable first)
db/011_schema_v2_strict.sql         -- tightens to NOT NULL after backfill
db/012_backfill_receipts.sql        -- backfills v2 Receipts state
db/013_views_v2.sql                 -- v2 view modernization
db/014_seed_smoke_po_lines.sql      -- additional smoke data
db/015_schema_po_pull_link.sql      -- §3.5 PO↔Pull link
db/016_seed_po_pull_link.sql        -- seed for §3.5
db/017_add_lockhourcap.sql          -- v2.1 per-pull hour-cap flag
db/018_pulls_reference_number.sql   -- Phase 7.1 reference number
db/019_pagination_indexes.sql       -- Phase 8.1 indexes for /Pos + /Reports
db/020_export_jobs_log.sql          -- Phase 8.4 ExportJobsLog table
db/021_po_lines_extended_fields.sql -- Phase 9 — 20 ERP-sourced PO line columns
db/022_export_jobs_log_read_at.sql  -- v2.1.12 nav-bar unread badge
db/023_export_jobs_log_downloaded_at.sql  -- v2.1.13 Pending/Downloaded tabs
db/024_pull_items_extended_fields.sql     -- Phase 9.1 — 7 ERP-sourced PullItem cols
db/025_vw_transactions_journal_pull_item_erp.sql  -- view extends with the 7 cols
db/026_rename_trailid_to_trialid.sql      -- v2.3.2 — typo fix on PullItems.TrialId
db/027_vw_transactions_journal_trialid.sql -- view re-alter post-rename
db/028_erp_sync_log.sql             -- Phase 10.6 — ErpSyncLog summary table
```

Skip seed scripts (`003`–`007`, `014`, `016`) in production — they
contain dev fixtures with weak passwords. For prod, seed the first
admin manually after the schema lands:

```sql
-- Hash with: dotnet run --project tools/HashPassword -- <plaintext>
INSERT INTO dbo.Users (UserId, Email, PasswordHash, DisplayName, GlobalRole, CreatedAt)
VALUES (NEWID(), 'admin@your.org', '<PBKDF2 hash>', 'Admin', 'admin', SYSUTCDATETIME());
```

Then assign that admin to at least one warehouse via `dbo.WarehouseAssignments`.

### 2.3 Verify

```sql
-- Should list ErpSyncLog as most-recent (Phase 10.6, db/028)
SELECT TOP 10 name, create_date
FROM sys.tables
WHERE schema_id = SCHEMA_ID('dbo')
ORDER BY create_date DESC;

-- Confirms Phase 8.4 column shape
SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'ExportJobsLog'
ORDER BY ORDINAL_POSITION;

-- Confirms Phase 10.6 ErpSyncLog (18 cols incl. RunId PK + IX_StartedAt)
SELECT COUNT(*) AS columns FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'ErpSyncLog';  -- 18

-- Confirms Phase 9.1 PullItems extended fields (post-v2.3.2 rename: TrialId not TrailId)
SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'PullItems'
  AND COLUMN_NAME IN ('ProductFamily', 'FromSubInventory', 'ToSubInventory',
                       'SpecialControl', 'TrialId', 'Location', 'Phase');
```

### 2.4 Backup

Out of scope for this doc, but two notes:

- `dbo.Receipts` is **append-only by convention** (no UPDATE except
  `ReversedById`, no DELETE). A point-in-time restore is the only
  legitimate way to undo a receive in prod. Your backup cadence should
  reflect that — full nightly + 15-min log shipping is the floor.
- The `[HangFire]` schema is regenerable. Job history can be dropped
  without affecting business state; the table is recreated on next
  start (`PrepareSchemaIfNecessary = true` in `Program.cs`).

---

## 3. Configuration via user-secrets

In production, set these via env vars, vault injection, or
`dotnet user-secrets` (acceptable for single-host deployments —
secrets live outside the repo under the user profile).

```powershell
# Database
dotnet user-secrets set "ConnectionStrings:Default" "Server=...;Database=ReceivingOps;..." `
    --project src/ReceivingOps.Web

# Exports — file generation + signed download links
dotnet user-secrets set "Exports:BaseUrl" "https://your.public.host" `
    --project src/ReceivingOps.Web
dotnet user-secrets set "Exports:SigningKey" "<random 32+ char string>" `
    --project src/ReceivingOps.Web
# Optional: override storage path or file lifetime
# dotnet user-secrets set "Exports:StorageRoot" "D:/receivx-exports" --project src/ReceivingOps.Web
# dotnet user-secrets set "Exports:FileLifetime" "1.00:00:00" --project src/ReceivingOps.Web  (24h)

# SMTP — Gmail app-password example. Substitute your relay.
dotnet user-secrets set "Smtp:Host" "smtp.gmail.com" --project src/ReceivingOps.Web
dotnet user-secrets set "Smtp:Port" "587" --project src/ReceivingOps.Web
dotnet user-secrets set "Smtp:UseStartTls" "true" --project src/ReceivingOps.Web
dotnet user-secrets set "Smtp:Username" "<gmail address>" --project src/ReceivingOps.Web
dotnet user-secrets set "Smtp:Password" "<16-char app password>" --project src/ReceivingOps.Web
dotnet user-secrets set "Smtp:FromAddress" "<gmail address>" --project src/ReceivingOps.Web

# Phase 10 — ERP integration. Required if you want the recurring sync
# or the manual-trigger UI to work. See docs/erp-integration.md §4.
dotnet user-secrets set "ErpDb:ConnectionString" `
    "Server=<erp-host>;Database=<db>;User Id=<readonly-user>;Password=<strong>;TrustServerCertificate=true" `
    --project src/ReceivingOps.Web
# Optional — flip recurring on once DefaultWarehouseId is set
# dotnet user-secrets set "ErpSync:Enabled" "true" --project src/ReceivingOps.Web
# dotnet user-secrets set "ErpSync:DefaultWarehouseId" "<warehouse-guid>" --project src/ReceivingOps.Web
```

### Verify config landed

After deploy, hit `/Config` as an admin → "Email test" panel. The page
calls `GET /api/admin/smtp-config` (metadata only, never credentials)
and `POST /api/admin/email-test` to actually send. A failure surfaces
the SMTP exception inline (Gmail-specific troubleshooting tips are
baked into the page).

### What happens with missing config

| Missing | Behavior |
|---|---|
| `ConnectionStrings:Default` | App throws at startup. Hard fail. |
| `Smtp:Host` | Email service no-ops gracefully — logs the would-be email body. Useful for staging without a relay; **not** what you want in prod. |
| `Exports:SigningKey` | Falls back to the literal dev placeholder string. Anyone who reads the source can forge download tokens. **Set this before exposing the app externally.** |
| `Exports:BaseUrl` | Defaults to `http://localhost:5213`. Email links will point to localhost — recipients can't open them. |
| `ErpDb:ConnectionString` | App starts fine; `ErpSqlConnectionFactory.Create()` throws on first sync attempt. Manual trigger surfaces it as HTTP 500. Set this if you want any ERP sync at all. |
| `ErpSync:DefaultWarehouseId` | Recurring fires per schedule but logs "no default — skipping" and exits without touching ERP. Manual triggers (with operator-picked warehouse) still work. |
| `ErpSync:Enabled` (false) | Recurring is unregistered on startup (`RecurringJob.RemoveIfExists`). Manual triggers still work. Safe default for staging. |

---

## 4. Hangfire (background jobs)

### 4.1 What runs in-process

The web tier registers `AddHangfireServer` with 2 workers on queues
`exports`, `erp-sync`, and `default` (in that priority order — user-
facing exports outrank background ETL). Export jobs are queued onto
`exports`; the ERP sync goes to `erp-sync`. For the current volume
(a handful of exports per day per operator + one ERP sync per hour),
this is plenty.

If exports start contending with request threads (long-running XLSX
generation blocks a worker), the next step is splitting Hangfire into
its own process — the storage layer is already SQL-backed, so two web
processes can share the queue without code changes.

### 4.2 Dashboard

`GET /hangfire` — gated by `HangfireDashboardAuth` (admin role
required). Shows queued/running/succeeded/failed counts, retry
history, and lets you re-enqueue a failed job.

### 4.3 Schema bootstrap

`PrepareSchemaIfNecessary = true` (default). First-start writes tables
under the `[HangFire]` schema. Production has two reasonable choices:

- **Leave it on.** Safe — Hangfire only modifies its own schema and
  the operations are idempotent. This is the current behavior.
- **Bake the schema in.** Generate the install SQL once
  (`https://github.com/HangfireIO/Hangfire/wiki/Install-Automatically`),
  apply it as part of the migration step, then set
  `PrepareSchemaIfNecessary = false` in `Program.cs` and redeploy.
  Pays off if your DB user doesn't have DDL rights in prod.

### 4.4 Retry behavior

Each `*ExportJob.RunAsync` carries `[AutomaticRetry(Attempts = 3)]`
(see `Services/Exports/*.cs`). On failure the job updates the
`ExportJobsLog` row to `failed` and rethrows so Hangfire retries.
After exhaustion the row stays `failed` and surfaces in the operator's
"Pending" tab.

---

## 5. File lifecycle

Generated XLSX files land at `<app-root>/exports/<jobtype>-<jobId>.xlsx`,
where `<app-root>` is the parent of the running assembly (resolved
relative to `AppContext.BaseDirectory`). The directory is **outside
`wwwroot/`** so static-file middleware never serves them — every
download goes through `/api/exports/{id}/download?token=<HMAC>` and
is signed-token gated.

| Concern | Current behavior |
|---|---|
| Download token TTL | 24 hours (`Exports:FileLifetime`). |
| File deletion | **None.** No recurring janitor exists. Files stay on disk indefinitely. |
| "Expired" status | Computed at read time — if a `succeeded` row's file is absent from disk, the API flips its `effectiveStatus` to `expired`. So operationally, a file with a 24h-old token shows as Expired in the UI even though the bytes are still there. |
| Re-download after token expiry | Browsing `/Exports` reissues a fresh 24h token (still HMAC-signed) for any row whose file is on disk. The email link is one-shot; the on-page link is renewable until the file is gone. |

### Recommended operational janitor

Add this to your host's scheduled tasks / cron until a recurring
Hangfire cleanup job ships (deferred backlog item):

```powershell
# Delete files older than 7 days from the exports directory
Get-ChildItem -Path "C:\path\to\app\exports" -Filter *.xlsx `
    | Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).AddDays(-7).ToUniversalTime() } `
    | Remove-Item -Force
```

7 days is a soft suggestion — the `ExportJobsLog` row stays even after
the file is gone, so operators retain audit trail of past exports.

---

## 6. Smoke verification

After deploy, run the full battery against the live instance (point
the env at the deployed host first, or run locally pointed at the prod
DB via tunneled connection string — your call):

```powershell
pwsh -File tools/run-smokes.ps1
```

Expected at v3.0: **49/49 PASS**.

Production-relevant subset if you can't run the full battery:

| Smoke | Validates |
|---|---|
| `smoke-phase-8.4-exports.ps1` | Transactions export enqueue → run → download |
| `smoke-export-extensions.ps1` | POs + Audit-Log exports + permission matrix |
| `smoke-my-exports.ps1` | `/Exports` listing + admin see-all privacy boundary |
| `smoke-exports-2tab.ps1` | Pending/Downloaded split + idempotency + cross-user privacy |
| `smoke-email-test.ps1` | Admin email diagnostic + SMTP config metadata |
| `smoke-phase-10-1-erp-connection.ps1` | ERP connection factory + TCP/SQL reachability |
| `smoke-phase-10-4-erp-trigger.ps1` | Manual ERP sync end-to-end (Hangfire → upsert) |
| `smoke-phase-10-6-erp-sync-page.ps1` | `/Admin/ErpSync` status page + `ErpSyncLog` writes |
| `smoke-phase-10-7-integration.ps1` | Cross-table consistency + closed-pull skip + mutex 409 |

The ERP smokes (`10-*`) skip cleanly when the ERP host is unreachable
(2s TCP probe), so they don't break the battery on a dev box without
VPN. To exercise them fully against the prod ERP DB, run them from
the deployed host with `ErpDb:ConnectionString` set.

---

## 7. Production hardening checklist

Tick before exposing the app externally:

- [ ] `Exports:SigningKey` overridden — not the dev placeholder.
- [ ] `Exports:BaseUrl` matches the public hostname (so email links resolve).
- [ ] `Smtp:*` configured and verified via `/Config → Email test`.
- [ ] Admin user seeded with a strong PBKDF2-hashed password
      (regenerate via `tools/HashPassword`).
- [ ] Database backups configured (full + log shipping).
- [ ] Reverse proxy / load balancer terminates TLS — the app sets
      `UseHttpsRedirection` + `UseHsts` in non-Development environments.
- [ ] `/hangfire` is reachable only from your admin network if you
      treat the dashboard as sensitive (the route is admin-gated by
      cookie auth, but an extra IP allowlist doesn't hurt).
- [ ] Cron janitor in place per §5 (or accept unbounded disk growth
      and live with it).

### Phase 10 ERP-integration deploy blockers (v3.0)

Add to the checklist if you're enabling the ERP sync:

- [ ] `ErpDb:ConnectionString` set via user-secret / env var (never
      committed to `appsettings.json`).
- [ ] ERP DB user is **read-only** — explicitly DENY
      INSERT/UPDATE/DELETE/EXECUTE on the schema, even if the role
      shouldn't grant them. Recipe in `docs/erp-integration.md` §4.3.
- [ ] Placeholder password (the dev secret used `"Pocket007"`) has
      been rotated to a strong production credential.
- [ ] Firewall / VPN allows outbound TCP from the app host to the ERP
      SQL host on port 1433 (or your `ErpDb:ConnectionString` port).
- [ ] For recurring runs: `ErpSync:Enabled = true` AND
      `ErpSync:DefaultWarehouseId = <your warehouse Guid>` both set —
      without DefaultWarehouseId the recurring fires but no-ops.
- [ ] `dbo.ErpSyncLog` and `dbo.AuditLog` retention plan in place if
      you expect the integration to run for years (the per-pull audit
      rows accumulate at ~N pulls × M syncs/day).
- [ ] Smoke `smoke-phase-10-1-erp-connection.ps1` passes from the
      deployed host (proves credentials + network are good).
- [ ] One-shot manual load probe per `docs/erp-integration.md` §8 to
      confirm wall-clock is acceptable at full backfill on first run.

### Migration slot policy

Future migrations append at the next `db/0NN`. Past gaps:
- `db/021` was reserved for Phase 9 (PurchaseOrderLines ERP cols);
  filled at v2.3.
- `db/024–025` filled at v2.3.1 (PullItems ERP cols + view).
- `db/026–027` filled at v2.3.2 (TrialId rename + view re-alter).
- `db/028` filled at v3.0 (ErpSyncLog).
