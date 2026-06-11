# DSV Delivery Order Report — Handoff (2nd report)

## Goal
Add 2nd report "DSV Delivery Order" alongside existing "Delivery Note".
UI: same Reports page + toggle/dropdown (Note vs Order).

## Existing report (DONE)
- "Delivery Note" = group by OrderId (1 DO = 1 OrderId), DeliveryNoteNo = OrderId
  - Committed at `7adbe8e` (`feat(do-report): regroup DO by OrderId`).
  - `DeliveryOrderService` groups on `r.OrderId ?? "{pullHex}-{PoNumber}L{LineNumber}"`
    (NULL-OrderId fallback + warning log — 8 receipt lines lack OrderId).
  - Vendor / SubInv / ToLoc / Invoice are now per-DO display attributes
    (1 line per DO), no longer grouping keys.
- File: src/.../Reports/delivery-order.frx (⚠️ misnamed — it's the NOTE;
  DnTitle text = "Delivery Note", DnNoValue = `[Orders.DeliveryNoteNo]`)

## New report: DSV Delivery Order
### Grouping (CONFIRMED by user)
- Key = PullId × FromSubInventory × ToSubInventory
- Break page per (Pull × FromSub × ToSub)
- ⚠️ Vendor + InvoiceNo become PER-LINE columns (not grouping keys) — opposite of current
- Verified DO count on the busiest real pull: DSV-style (FromSub × ToLoc) = **2 DOs**
  vs current OrderId grouping = many single-line DOs. (Earlier 4-tuple grouping = 38.)

### Layout (per DSV reference, Dec-2024 FOAMTEC/CALCOMP sample)
Header: Delivery Order#, Order Time, Production Line, Round, From Sub, To Sub
Lines (dense table, barcode under each): Part Number | Qty Issue | Locator | Vendor | DN/INV Number

### Field mapping (VERIFIED against live DB — LAPTOP-CSB3KO3E.ReceivingOps)
| Field | DB source | Status |
|---|---|---|
| From Sub | pol.SubInventory | ✅ in SELECT |
| To Sub | pol.ToLocation | ✅ in SELECT |
| Round | pol.OrderRound | ✅ (reformat pipe→bracket: `07:00\|08:00` → `[07:00],[08:00]`) |
| Order Time | pol.DeliveryDate | ⚠️ available, ADD to SELECT (DATE; always 00:00:00, matches `3-Dec-2024 0:00:00`) |
| Part Number | pol.ItemCode | ✅ |
| Qty Issue | SUM(r.QtyReceived) | ✅ (add thousands sep) |
| Vendor | pol.VendorName | ✅ (demote to line col) |
| INV | pol.InvoiceNo | ✅ (real DN/inv values: `DUF26050248`, `FZ2604079`, `3210123076`) |
| Locator p1-2 | SubInventory.DeliveryDate | ✅ (add DeliveryDate; format `dd-MMM-yyyy`) |

### 🚩 UNSOURCED — must resolve before build
1. Production Line NAME (CARMEL) — `pol.ProductionLine` is numeric (`2033`, `3808`, `256`…), no name column.
   (`Customer/ManufacturingReferenceNo` carry free-text program tags like `DANOLSAN` but are not a clean line name.)
2. Delivery Order# (`0001233579`, 10-digit) — no upstream DO number stored.
   Current `DeliveryNoteNo` = OrderId (mixed-format `DN260606-423` / `1523564B40`); `PullNumber` = `0000009382` (pull-grain).
3. Locator serial part 3 (`0029381837`) — no exact column. Closest format = `KanbanNo` (`0000015369`, zero-padded 10-digit).
   `Location` col holds TRB txn refs (`TRB250013355`), not this serial.
4. DN number (`0029381838`) — not stored; current code fabricates from Pull.Id hex. INV side (`3130127593`) maps to `pol.InvoiceNo`.

### Root gap (items 2-4)
Upstream DSV DN/serial numbers NOT imported into any Receivx column.
⚠️ ACTION: check source Excel workbook for "DN NO"/"DELIVERY NOTE" column
that PoImportReader currently DROPS. If exists → add to import first.
(PoImportReader maps headers in src/ReceivingOps.Web/Services/PoImport/PoImportReader.cs:180-215 —
no "DN"/"DELIVERY NOTE" header is currently consumed.)

### Available-but-unused POL columns (could add to SELECT)
VmiPalletId, Location, Building, DeliveryDate, ProductionLine, VendorItem,
PCCNo, BatchNo, ManufacturingControlNo/ReferenceNo, CustomerReferenceNo,
ExportDeclarationNo, Note

## Architecture (proposed)
ReportType enum { DeliveryNote, DeliveryOrder }
DeliveryOrderService.Build(pull, reportType):
  DeliveryNote  → groupBy OrderId           → [current .frx]
  DeliveryOrder → groupBy (Pull,FromSub,ToSub) → [new .frx]
⚠️ Rename: current delivery-order.frx → delivery-note.frx (it's the note)
   New DSV order → delivery-order.frx (real order)

## Open decisions (fresh session must resolve with user)
1. 4 unsourced fields — import from Excel? synthesize? leave blank?
2. Source workbook check — does DN column exist upstream?
3. .frx naming/rename strategy
4. UI toggle design (dropdown vs tabs)

## Branch / baseline
- branch: feat/import-source-po-no
- baseline commit: 7adbe8e (HEAD after DO regroup by OrderId)
- ⚠️ Uncommitted at handoff: src/ReceivingOps.Web/Reports/delivery-order.frx
  (user Designer round-trip 06/11/2026 11:05 — layout edits: grid reposition,
  10pt→8pt fonts, dd/MM/yyyy date format, 3 text objects removed). Decide
  whether to commit before continuing.
- Not yet tagged: v3.5.x work (erp-sync ItemCode fix, SourcePoNo import,
  composite-ItemCode backfill, DO regroup) sits on top of tag v3.5.
