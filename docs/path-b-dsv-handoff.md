# Path B + DSV Delivery Note — Handoff to fresh session

## Branch
- **`dsv-redesign`** (pushed to `origin/dsv-redesign`) — **NOT** merged to `main`
- **Baseline commit**: `d84afec` ("feat(do-report): DSV Delivery Note redesign baseline + warehouse logo")
- **Rollback inside branch**: `git reset --hard d84afec` if Path B refactor goes off-rails
- **Rollback to v3.4.1**: `git checkout main` — main is untouched at `73d2ea0`

## Current state (verified at handoff time)

- `main` = **v3.4.1** (`73d2ea0`) — last shipped tag, receipt backfill closed
- Phase 14 (vendor → POL line grain) = **shipped** at v3.4
- DSV redesign baseline = **committed on `dsv-redesign`** at `d84afec`
- `Warehouses.LogoDataUrl` (`db/039_warehouses_logo.sql`) = **committed** on the baseline
- Invoice-split DO identity = **5-tuple** `(VendorCode × VendorName × SubInventory × ToLocation × InvoiceNo)`
- `.gitignore` extended to exclude `.dp-keys-backup*/` (prevents recurrence of staging encrypted key snapshots)

## Locked decisions

| # | Decision | Source |
|---|---|---|
| Path strategy | **Path B — Hybrid bootstrap**: auto-generate `delivery-order.frx` from programmatic code if missing → `Report.Load()` at runtime → user edits via FastReport Designer Community | session call |
| Designer | **FastReport Designer Community 2023.2.15** (Windows desktop, free). **Dc**: test the 2023.2 ↔ runtime 2026.2 round-trip first; only upgrade Designer if it breaks | session call |
| Q1 — Delivery Note No | `PurchaseOrderLines.OrderId` (current baseline uses derived `Pull.Id[..8] + letter` — revisit in Path B if user prefers OrderId) | revisit |
| Q2a — DELIVERY TO | `Warehouse.Address` | confirmed |
| Q3c — Delivered By / Approved | Empty boxes for manual fill; APPROVED FOR DELIVERY BY also accepts `Pulls.SignatureSvg` when present | confirmed |
| Q5a — Delivery Note No + Inv | `"{OrderId}+{InvoiceNo}"` concat (baseline currently uses `{DeliveryNoteNo}+{InvoiceNo}`; align in Path B) | revisit |
| Q6b — Logo | `Warehouse.LogoDataUrl` (data URL, NVARCHAR(MAX)) — **done in baseline** | confirmed |
| Q8a — Page X of Y | FastReport native `[Page#] / [TotalPages#]` system variables | confirmed |

## DSV field mapping — all present in `DoReportDtos.cs`

| DSV field | DTO location |
|---|---|
| Vendor Code / Name | `DoOrder.VendorCode`, `DoOrder.VendorName` |
| FROM / TO | `DoOrder.SubInventory` / `DoOrder.ToLocation` (also on `DoLine`) |
| Invoice | `DoOrder.InvoiceNo` / `DoLine.InvoiceNo` |
| Header PO# | `DoOrder.HeaderPoNumber` (dominant-PO derived ordinal-min) |
| Delivery Note No | `DoOrder.DeliveryNoteNo` (baseline = deterministic `Pull.Id[..8] + DO-letter`; revisit if OrderId-based wanted) |
| Pallet ID | `DoLine.PalletId` |
| Order ID | `DoLine.OrderId` |
| Kanban | `DoLine.KanbanNo` |
| ASN | `DoLine.AsnNo` |
| Round | `DoLine.OrderRound` |
| STORING NOTE Date Received | `DoOrder.LastReceivedAt` / `DoLine.LastReceivedAt` (sourced via `MAX(r.ReceivedAt) WHERE r.ReversedById IS NULL`) |
| Warehouse Address | `DoPullHeader.WarehouseAddress` |
| Warehouse Logo | `DoPullHeader.WarehouseLogoDataUrl` |

## FastReport packages (csproj)

| Package | Version |
|---|---|
| `FastReport.OpenSource` | `2026.2.1` |
| `FastReport.OpenSource.Export.PdfSimple` | `2026.2.1` |
| `FastReport.OpenSource.Web` | `2026.2.1` |

`Report.Save(string)` and `Report.Load(string)` are in the core `FastReport` assembly — no additional packages needed for Path B. Verified via reflection in pre-Path-B audit.

## Designer ↔ runtime compatibility verdict (from pre-Path-B audit)

- Forward direction (Designer **older** + Runtime **newer**) is the safer direction.
- Object set used (`TextObject`, `BarcodeObject`, `PictureObject`, `LineObject`, `DataBand`, `ReportTitleBand`, `ReportSummaryBand`, `PageFooterBand`, `ReportPage`, `DataTable`) is core OS, supported by Designer Community 2023.2.
- Code128 via `BarcodeObject.SymbologyName = "Code128"` is available in both.
- No Enterprise-only objects in scope.

## Path B multi-stage plan

| Stage | Scope |
|---|---|
| **1** | `Reports/` folder + bootstrap scaffold (csproj `CopyToOutputDirectory` on `Reports/*.frx`) |
| **2** | DataSet refactor (`DoReportData` → `DataTable Orders` master + `DataTable Lines` detail, master-detail Relation) |
| **3** | Programmatic .frx gen — DSV layout (header logo+addr, title, PO/PRS info grid, barcodes, items DataBand, totals, STORING NOTE strip, signature boxes) |
| **4** | Bootstrap glue: auto-gen if missing → `Report.Load()` → `RegisterData()` → `Prepare()` → export pipeline |
| **5** | Barcodes (Code128): PO, PRS, DN, Part (per row?), Invoice, Pallet, Qty, Total |
| **6** | Warehouse logo `byte[]` binding via `PictureObject.DataColumn` |
| **7** | HTML preview alignment (`_DoPreview.cshtml` mirrors the new .frx layout) |
| **8** | Smoke + Designer round-trip test: open `delivery-order.frx` in CE 2023.2.15, save back, re-render, diff |
| **9** | Merge `dsv-redesign` → `main` + tag `v3.5` |

**Estimated effort**: 10–15 hr.

## ห้าม (hard prohibitions)

- ห้าม merge `dsv-redesign` → `main` จนกว่า Stage 8 verified end-to-end (Designer round-trip + smoke battery)
- ห้าม commit `.dp-keys-backup*/` (encrypted key snapshots — same secrets as `.dp-keys/`, never enter git)
- ห้ามทำ stages ข้าม (each stage builds on the previous; no jumping ahead)
- ห้าม upgrade Designer Community ก่อน Stage 8 test (Dc: prove 2023.2.15 ↔ 2026.2.1 round-trip works first; only upgrade if it doesn't)
- ห้ามแตะ `main` branch (all work isolated on `dsv-redesign`)
- ห้าม tag v3.5 จนกว่า Stage 9 merge complete + smokes green

## How to resume in a fresh Claude Code session

1. Open a new Claude Code session in this repo (`C:\dev\receivx`).
2. `git checkout dsv-redesign` (verify HEAD = `d84afec` or later).
3. Paste this doc into the first message of the new session.
4. Have Claude confirm baseline commit + branch state before starting.
5. Begin **Stage 1**.

## Files to skim first in the fresh session

- `src/ReceivingOps.Web/Services/DeliveryOrderService.cs` — programmatic DSV layout (Path B will refactor this to use expressions + DataTable bindings)
- `src/ReceivingOps.Web/Models/Dtos/DoReportDtos.cs` — DTO shape that maps to the future DataTable columns
- `src/ReceivingOps.Web/Data/Repositories/PullRepository.cs` (`GetDoReportRowsAsync` ~line 299) — SQL source for the data
- `src/ReceivingOps.Web/Views/Reports/_DoPreview.cshtml` — HTML mirror that needs to track the new layout
- `db/039_warehouses_logo.sql` — schema substrate for the warehouse logo
