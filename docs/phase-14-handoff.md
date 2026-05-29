# Phase 14 — Handoff to fresh session (from 2026-05-29 session end)

## v3.3.1 state (current HEAD context)
- Tag v3.3.1 → e577fe4 (signature → PageFooterBand)
- HEAD → 977c4ba (CLAUDE.md doc patch, 1 commit ahead of tag, code identical to v3.3.1)
- v3.3.1 pushed to origin (confirmed via git ls-remote)
- Dirty worktree: M src/ReceivingOps.Web/wwwroot/js/dashboard.js (unrelated, decide in next session)

## Locked decisions (Phase 14 — confirmed in prior session)
- Q1=C: Wipe all data, Dev env only (no prod yet)
- Q2: Mixed vendor per PO is a real case → drop PO-level VendorCode/VendorName
- Q3: ERP sync (Phase 13) code untouched; only ErpSyncLog rows wiped
- Q4: PoImportJob reads vendor per row from Excel — **column mapping deferred to fresh session**
- Q5: DO grouping key = FromSubInventory × ToLocation × VendorCode → one Pull spawns multiple DOs

## Pre-flight findings (this session, Stage 0 only)

### Dev env confirmed
- ServerName: LAPTOP-CSB3KO3E
- DbName: ReceivingOps
- IsLocalDB: 0 (real local SQL, not LocalDB)
- ✅ NOT production

### Baseline row counts (snapshot for verification after wipe)
| Bucket | Table              | Rows    |
|--------|--------------------|---------|
| WIPE   | AuditLog           | 126,962 |
| WIPE   | Receipts           | 2,006   |
| WIPE   | PullItems          | 11,485  |
| WIPE   | Pulls              | 1,778   |
| WIPE   | PurchaseOrderLines | 49      |
| WIPE   | PurchaseOrders     | 90      |
| WIPE   | PoImportLog        | 11      |
| WIPE   | ErpSyncLog         | 234     |
| KEEP   | AppSettings        | 12      |
| KEEP   | Warehouses         | 6       |
| KEEP   | Users              | 6       |

### Gaps flagged from handoff doc
1. **PullItemWindows (11,572 rows)** — FK-bound to PullItems, NOT in handoff wipe list. Must add to db/035. TRUNCATE order: Windows → PullItems → Pulls.
2. **Hangfire schema (`[HangFire].*`)** — should it be cleared?
   - Job state (in-flight/recurring) — wiping = loses scheduled ERP sync recurring
   - Recommendation: KEEP Hangfire (recurring jobs preserved); clear if user wants fresh state
   - Decision deferred to fresh session

### .dp-keys/ backup
- 1 file: `key-e1147762-3493-46af-9a87-d3237ecff022.xml` (mtime 2026-05-26)
- Snapshot NOT yet made
- Recommendation (fresh session): copy to `.dp-keys-backup-phase14-pre/` BEFORE running db/035

## Open decisions for fresh session
1. dashboard.js dirty worktree — commit/discard?
2. PullItemWindows wipe order in db/035
3. Hangfire schema wipe — keep or clear?
4. .dp-keys/ snapshot location
5. Q4 column mapping — which Excel column → VendorCode + VendorName at line level?
   (Phase 12 currently has STORER CODE/NAME at PO header, need verify per-row mapping)
6. Mixed-vendor PoImport behavior — same PO with different vendors per line: allow? warn? error?

## Multi-stage plan (carry over from earlier handoff)
- Stage 0: Pre-checks ✅ (done in this session)
- Stage 1: db/035 destructive wipe (+ PullItemWindows + Hangfire decision)
- Stage 2: db/036 schema (DROP from PO, ADD to POL, filtered index)
- Stage 3: Entity + DTO updates
- Stage 4: Repository + service refactor (incl. Phase 12 import — Q4 column mapping)
- Stage 5: DO report logic rewrite (split DO per group)
- Stage 6: UI updates (Phase 9.2 modal: add VendorCode/Name to Tracking section)
- Stage 7: Smoke updates
- Stage 8: Tag v3.4 + push

## Files affected (preliminary)
- Models/Entities/PurchaseOrder.cs + PurchaseOrderLine.cs
- Models/Dtos/PurchaseOrderDtos.cs + DoReportDtos.cs
- Data/Repositories/PurchaseOrderRepository.cs + PullRepository.cs (DO query)
- Services/PurchaseOrderAdminService.cs
- Services/PoImport/PoImportJob.cs (Phase 12)
- Services/DeliveryOrderService.cs (DO splitting logic)
- Controllers/Api/PoApiController.cs
- Views/Purchase-Orders/Detail.cshtml
- wwwroot/js/po-detail.js (Phase 9.2 modal)
- Views/Reports/_DoPreview.cshtml
- db/035_wipe_for_phase_14.sql
- db/036_vendor_to_po_lines.sql
- tools/smoke-*.ps1

## Effort estimate
6-10 hours fresh session

## ห้าม (carry over to fresh session)
- ห้ามรัน db/035 ใน production environment
- ห้ามแตะ ERP sync code (Phase 13 untouched per Q3)
- ห้ามแตะ Pulls/PullItems entities
- ห้ามทำ stages ข้าม (run sequential)
- ห้าม push จนกว่า Stage 7 smoke green

## How to use this doc
1. Open fresh Claude Code session
2. Paste this doc as initial context
3. Confirm pre-conditions: HEAD = v3.3.1 (+/- doc patches), dev env, .dp-keys/ exists
4. Confirm Q1-Q5 still hold + answer 6 open decisions above
5. Then: implement Stage 0 confirm + Stage 1
