# v1 → v2 migration runbook

This is the operations checklist for taking a v1 ReceivingOps database forward
to v2 (PO-driven FIFO receiving) plus the §3.5 lock-aware extension.

**Branch:** `v2-migration`
**Spec:** `BUILD_PROMPT.md` (current = v2; v1 archived at `BUILD_PROMPT.v1.md`)
**Battery:** 15/15 PASS on commit `d954ef5` (run `tools/run-smokes.ps1`)

---

## Prerequisites

1. SQL Server reachable as `LAPTOP-CSB3KO3E` (or update the `Server=` in
   user-secrets). Smoke scripts assume integrated auth.
2. .NET 8 runtime (SDK 9 also works — the project targets `net8.0`).
3. `pwsh.exe` (PowerShell 7+) on PATH. Windows PowerShell 5.1 mangles UTF-8
   in the smoke `.ps1` source — `tools/run-smokes.ps1` prefers `pwsh` and
   falls back to `powershell` only as a last resort.
4. Connection string in user-secrets:
   ```powershell
   dotnet user-secrets set "ConnectionStrings:Default" `
     "Server=LAPTOP-CSB3KO3E;Database=ReceivingOps;Integrated Security=True;TrustServerCertificate=True;Encrypt=False;Application Name=ReceivingOps;" `
     --project src\ReceivingOps.Web
   ```

## Backup before each phase

The v2 migration is forward-only after Phase 1b ships (the strict cutover).
Take a full backup before each of the three breaking points:

| Before phase | Why | Restore window |
|---|---|---|
| **1a** | First DDL change | Trivial — phase is additive |
| **1b** | `NOT NULL` + FK on `Receipts.PurchaseOrderId/LineId` | Hard — needs backfill rerun if rolled back |
| **3.5** | New `PullId` column + filtered index + per-pull lock | Easy — phase is additive |

```sql
BACKUP DATABASE ReceivingOps TO DISK = N'C:\backups\receivingops-pre-phase-1a.bak';
```

## Apply order (clean DB)

Each script is idempotent — re-running on an already-migrated DB is safe (the
scripts gate on schema state with `IF NOT EXISTS` / `IF COL_LENGTH IS NULL`).

```powershell
# v1 base — only on a virgin DB
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\001_schema.sql
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\002_views.sql
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\003_seed_users.sql
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\004_seed_warehouses.sql
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\005_seed_assignments.sql
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\006_seed_pulls_and_items.sql

# v2 chain — apply 010 → 014 in order
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\010_schema_v2_additive.sql      # additive
.\tools\verify-phase-1a.ps1                                              # 9 checks

sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\007_seed_purchase_orders.sql    # 11 POs / 21 lines
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\012_backfill_receipts.sql       # FIFO walk existing receipts onto PO lines
.\tools\verify-phase-2.ps1                                               # backfill invariants

sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\011_schema_v2_strict.sql        # NOT NULL + FK + CK
.\tools\verify-phase-1b.ps1                                              # negative-path probes

sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\013_views_v2.sql                # vw_TransactionsJournal projects PO
.\tools\verify-phase-3.ps1

sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\014_seed_smoke_po_lines.sql     # SUMMARY PO lines for smokes
.\tools\verify-phase-4.ps1                                               # FIFO + auto-close + §7.13

# §3.5 lock-aware extension
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\015_schema_po_pull_link.sql     # PO.PullId + Pulls.LockPoByPull
sqlcmd -S LAPTOP-CSB3KO3E -E -C -b -i db\016_seed_po_pull_link.sql       # PL-2900/PL-2901 + PO-2405-001
.\tools\verify-phase-3.5.ps1                                             # 15 checks
```

## Full smoke battery

After the SQL chain ships, launch the app and run:

```powershell
cd src\ReceivingOps.Web
$env:ASPNETCORE_ENVIRONMENT='Development'
dotnet run --urls http://localhost:5213

# In another shell
.\tools\run-smokes.ps1
```

Default battery (15 suites, all must PASS):

```
verify-phase-3.5      smoke-phase-5a
smoke-phase-4a        smoke-phase-5b
smoke-phase-4b        smoke-phase-5c
smoke-phase-4c        smoke-phase-5d
smoke-phase-4d        smoke-phase-5e      (end-to-end happy path)
smoke-phase-4e        smoke-receive
smoke-stage-b         smoke-transactions
smoke-close-reopen
```

Aggregate EXITCODE is 0 iff every child exit is 0.

## Rollback steps (per phase)

Phases land in commit order — rolling back means undoing the most recent first.
For every undo, take a backup first.

### Phase 3.5 (lock-aware extension) — easy

```sql
SET QUOTED_IDENTIFIER ON;
ALTER TABLE dbo.PurchaseOrders DROP CONSTRAINT FK_PO_Pull;
DROP INDEX IX_PO_Pull ON dbo.PurchaseOrders;
ALTER TABLE dbo.PurchaseOrders DROP COLUMN PullId;
ALTER TABLE dbo.Pulls DROP CONSTRAINT DF_Pulls_LockPoByPull;
ALTER TABLE dbo.Pulls DROP COLUMN LockPoByPull;
-- vw_PurchaseOrderAvailability needs to be re-created without the PullId
-- projection — restore the pre-3.5 definition from db/010_schema_v2_additive.sql
```

The C# code still references `LockPoByPull` and `PullId` after this rollback,
so you'd also need to roll the branch back to before `65bef9e`.

### Phase 5 (frontend wiring) — pure JS/CSS/Razor

`git revert` the Phase 5 commits (`99c8db1`, `6190d4a`, `12e07dd`, `9aef608`,
`ad908c3`, `d954ef5`, plus the fixes). No DB changes.

### Phase 4 (FIFO + admin) — code-only, no DB

`git revert cf771af` and earlier 4a–4e commits. DB state stays valid against
the rolled-back service layer; `db/014` (smoke sandbox) can stay or be removed
with `DELETE FROM dbo.PurchaseOrderLines WHERE Description LIKE 'Smoke-test%';`.

### Phase 3 (view modernization) — DDL

```sql
DROP VIEW dbo.vw_TransactionsJournal;
-- Restore the v1 version from db/002_views.sql.
```

The Phase 4 controllers reference the new view shape, so revert 3 + 4 together.

### Phase 1b (strict cutover) — **high-risk**

This is the one-way door. To go back you need:

1. `git revert db134e3`
2. Drop the strict constraints:
   ```sql
   ALTER TABLE dbo.Receipts DROP CONSTRAINT CK_Receipts_ReversalIntegrity;
   ALTER TABLE dbo.Receipts DROP CONSTRAINT FK_Receipts_PO;
   ALTER TABLE dbo.Receipts DROP CONSTRAINT FK_Receipts_POLine;
   DROP INDEX IX_Receipts_POLine ON dbo.Receipts;
   ALTER TABLE dbo.Receipts ALTER COLUMN PurchaseOrderId UNIQUEIDENTIFIER NULL;
   ALTER TABLE dbo.Receipts ALTER COLUMN PurchaseOrderLineId UNIQUEIDENTIFIER NULL;
   ```
3. **The 18 backfilled receipts** (Phase 2) still carry valid PO references
   from `db/007_seed_purchase_orders.sql`. Don't truncate them — leaving the
   columns populated is harmless, and you'd otherwise need to reconcile
   `PullItemWindows.ReceivedQty` from scratch.

### Phase 2 (backfill) — data only

```sql
UPDATE dbo.Receipts SET PurchaseOrderId = NULL, PurchaseOrderLineId = NULL;
DELETE FROM dbo.PurchaseOrderLines;
DELETE FROM dbo.PurchaseOrders;
```

Phase 1a's `CHECK CK_PIW_Caps` (capping per-hour qty) was DROPped by 1a — if
the rollback target is v1 logic, re-create it from `db/001_schema.sql`.

### Phase 1a (additive schema) — easy

```sql
ALTER TABLE dbo.Receipts DROP COLUMN PurchaseOrderId;
ALTER TABLE dbo.Receipts DROP COLUMN PurchaseOrderLineId;
DROP TABLE dbo.PurchaseOrderLines;
DROP TABLE dbo.PurchaseOrders;
DROP VIEW dbo.vw_PurchaseOrderAvailability;
-- Re-create CK_PIW_Caps from db/001_schema.sql if reverting to v1 cap-at-expected.
```

## Notes / gotchas captured during the migration

- **`SET QUOTED_IDENTIFIER ON`** is mandatory for DML on `Pulls` after 015
  (the filtered `IX_PO_Pull` requires it — sqlcmd's default is OFF, leading
  to Msg 1934). Add `-I` to sqlcmd or `SET QUOTED_IDENTIFIER ON;` at the top
  of the script.
- **`dotnet run --no-launch-profile`** strips `ASPNETCORE_ENVIRONMENT=Development`
  — user-secrets won't load and the API returns 405 on every endpoint. Set
  the env var explicitly or drop `--no-launch-profile`.
- **Audit message format is a wire contract** (BUILD_PROMPT.md §8.1) — the
  Receive message always carries `Scope: warehouse-wide FIFO` or
  `Scope: pull-locked`; Cancel never carries Scope. Anything parsing the
  audit log relies on this exact format.
- **PowerShell 7 only** for the smoke scripts — Windows PowerShell 5.1 reads
  `.ps1` files as the system codepage and mangles em-dashes / Thai text into
  parser errors.
- **Smokes that create `LockPoByPull=true` pulls** MUST clean up afterwards
  (use a `PL-SMOKE-{phase}-` prefix + SqlCleanup helper) — `verify-phase-3.5`
  asserts "all non-PL-2900/PL-2901 pulls have LockPoByPull = 0", and a stray
  test artifact will break the verifier.

## Connection between SQL phases and code commits

| SQL  | Code commit | Phase |
|---|---|---|
| 010  | `6bb0516`   | 1a — additive schema |
| 007  | `14e6299`   | 2 — backfill 18 receipts |
| 012  | `14e6299`   | 2 — backfill walk |
| 011  | `db134e3`   | 1b — strict cutover |
| 013  | `34df9e4`   | 3 — view modernization |
| 014  | `cf771af`   | 4 — smoke sandbox PO lines |
| 015  | `65bef9e`   | 3.5 — additive PO↔Pull link |
| 016  | `65bef9e`   | 3.5 — seed PL-2900/2901 + PO-2405-001 |

After commit `9aef608` ships, all SQL phases are persisted in the DB and the
C# code path matches. Don't roll back SQL phases independently of the matching
code commit — they're coupled.
