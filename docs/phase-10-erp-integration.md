# Phase 10 — ERP Integration (planning doc)

Status: **planning only — no code in this slice.**
Target tag: **v3.0** (major release — first external integration).
Spec source: design conversations summarized in CLAUDE.md "v2.x backlog";
this doc consolidates the decisions and surfaces the open questions.

---

## 1. Goal

Receive PO + Line data from an external ERP system via API push.
Phase 9 (v2.3) prepared the schema (`db/021` adds 20 ERP-sourced
nullable columns to `PurchaseOrderLines`); Phase 10 wires the
ingestion endpoint and the operational glue around it.

The ERP is the source of truth for the 20 ERP fields. Receivx is the
source of truth for receiving operations (Pulls, Receipts,
PullId/lock-state on POs). The integration boundary is intentionally
write-through-from-ERP for the new fields and write-protected-from-ERP
for Receivx-managed fields.

---

## 2. Endpoint design

### 2.1 Surface

```
POST /api/erp/pos
Authorization: <see §3>
Content-Type: application/json
```

### 2.2 Request payload (single PO)

```json
{
  "poNumber": "PO-2026-001",
  "vendorCode": "V-123",
  "vendorName": "Vendor Co., Ltd.",
  "warehouseCode": "WH-01",
  "orderDate": "2026-05-25",
  "expectedDate": "2026-05-30",
  "status": "open",
  "lines": [
    {
      "lineNumber": 1,
      "itemCode": "WIDGET-1000",
      "description": "Widget v2 power assembly",
      "orderedQty": 500,

      "invoiceNo": "INV-2026-001",
      "kanbanNo": "KAN-2026-001",
      "asnNo": "ASN-2026-123",
      "pccNo": "PCC-456",
      "batchNo": "B-20260525",
      "manufacturingControlNo": "MCN-001",
      "manufacturingReferenceNo": "MRN-001",
      "customerReferenceNo": "CR-2026-XYZ",
      "exportDeclarationNo": null,
      "vendorItem": "V-SKU-12345",

      "palletId": "P-001",
      "vmiPalletId": "VMI-2026-A",
      "location": "A1",
      "building": "B-1",
      "subInventory": "MAIN",
      "toLocation": "A1-B2",

      "productionLine": "PL-A",
      "orderRound": "R1",

      "deliveryDate": "2026-05-30",
      "note": "Priority shipment"
    }
  ]
}
```

The 20 ERP fields map 1:1 to the columns added in `db/021`. The
header fields (poNumber, vendor*, dates, status) are existing v2
columns; payload reuses them as-is.

### 2.3 Response codes

| Code | Meaning |
|---|---|
| `201 Created` | New PO created |
| `200 OK` | Existing PO updated (upsert by `poNumber`) |
| `400 Bad Request` | Payload validation failure (missing required fields, unknown warehouse code, bad date format) |
| `401 Unauthorized` | Missing or invalid credentials |
| `409 Conflict` | PO state forbids update — currently in `closed` or `canceled` state |
| `422 Unprocessable Entity` | Receivx-managed-field violation (caller tried to set `pullId`, `lockHourCap`, `lockPoByPull`, or `receivedQty`) |

### 2.4 Behavior

**Upsert semantics:**
- Match POs by `poNumber` (unique business key).
- Match lines within a PO by `(PurchaseOrderId, LineNumber)` composite.
- Updates are idempotent — repeated identical payloads produce no
  state change (and the response code reflects whether a row was
  actually written).

**Receivx-managed fields (never overwritten by ERP push):**
- `PurchaseOrders.PullId`, `LockHourCap`, `LockPoByPull` — these are
  immutable in v2; the existing PO admin path enforces 409 on
  attempted changes. Same gate applies here.
- `PurchaseOrderLines.ReceivedQty` — denormalized cache of
  `SUM(Receipts.QtyReceived)` for the line; updated only by the
  receive/cancel services.
- Anything in the `Receipts` table — append-only by convention; the
  ERP integration must not touch it.

**State gating:**
- A PO in `closed` or `canceled` state returns `409`. Reasoning: once
  the operator has finalized the receive, the ERP shouldn't be able
  to silently revise the order — that's a stale-data race that breaks
  audit semantics.
- A PO in `open` state with existing receipts can still be updated,
  but only for ERP-sourced fields. Attempting to lower `orderedQty`
  below `receivedQty` returns `409` (existing `CK_POL_Caps` check
  constraint enforces this at the DB layer anyway).

**Audit trail:**
- Every accepted push writes one audit row per PO via `IAuditService`.
- The full payload is archived as JSON in the audit message — Phase 8
  added `ExportJobsLog.FilterJson` as precedent for this pattern.
- Failed pushes also audit (with the rejection reason) so ERP-side
  retries are visible.

---

## 3. Authentication

Two options, pick one based on the ERP's capabilities:

### Option A — API key (simplest)

```
X-ERP-Api-Key: <opaque 32+ char string>
```

- Single shared secret per ERP environment (one for prod, one for
  staging — different keys).
- Stored in `dotnet user-secrets` like the other Phase 8 secrets.
- Rotation: deploy new key, ERP swaps, retire old key.
- Suitable for a single trusted system pushing data.

### Option B — OAuth client credentials (more secure)

```
Authorization: Bearer <JWT>
```

- ERP authenticates to a token endpoint with `client_id` + `client_secret`,
  gets a short-lived JWT, presents it on each push.
- More moving parts (token endpoint, refresh flow on ERP side, JWT
  validation middleware) but rotation is automatic.
- Suitable if multiple ERP-style systems eventually push, or if
  compliance demands per-request authn.

**Recommendation:** start with Option A in Phase 10.1 — it ships in
hours not days, and the upsert logic is the actually-interesting
work. Migrate to Option B in a later patch if the threat model warrants.

---

## 4. Open questions

To resolve with the ERP team before Phase 10 implementation starts:

1. **Push vs poll.** Recommend push — real-time updates, no polling
   cost. But some ERPs only expose pull-style APIs; if so, Receivx
   needs a scheduled job that reads from the ERP and applies the
   same upsert logic.
2. **Conflict resolution.** If Receivx admin edits a PO field
   (vendor name, expected date) in-app, and the ERP later pushes a
   different value — does the push win, or does Receivx have to
   reject? Recommend "push wins for ERP-sourced fields, Receivx wins
   for ops state" — matches the source-of-truth split.
3. **Status sync back to ERP.** Does Receivx push close/cancel state
   back to the ERP? If yes, that's a second integration direction
   (`POST` from Receivx to ERP) and adds significant scope. Defer to
   v3.1 unless the ERP team flags it as a hard requirement.
4. **Idempotency tokens.** A retry-safe header like `Idempotency-Key:
   <client-generated UUID>` lets the ERP retry on network failure
   without producing duplicate audit rows. Worth adding if ERP-side
   retry logic isn't already idempotent at the payload level.
5. **Batch payloads.** Single PO per call is the simplest contract
   but means N HTTP round trips per ERP batch. If the ERP pushes
   thousands of POs at once, a `POST /api/erp/pos/batch` accepting
   `{ pos: [...] }` (transactional, all-or-nothing per batch) cuts
   overhead. Decide based on actual ERP behavior.
6. **Validation strictness.** Required fields: `poNumber`,
   `warehouseCode`, `orderDate`, at least one line with `lineNumber`
   + `itemCode` + `orderedQty`. Everything else is optional. Confirm
   with ERP team — they may expect us to reject pushes missing
   business-critical fields.
7. **Index design.** Deferred from Phase 9 explicitly. Watch the
   actual query patterns in the first few weeks after ERP integration
   ships, then add indexes for the columns that are actually filtered
   (likely candidates: `InvoiceNo`, `KanbanNo`, `AsnNo`, `BatchNo`).
   Adding indexes speculatively wastes write throughput on cold paths.

---

## 5. Performance budget

Order-of-magnitude estimates based on current Receivx volume:

| Metric | Estimate |
|---|---|
| Receipts per day | ~5,000 |
| POs per day | ~100–500 |
| Lines per PO | ~5–20 avg |
| Total daily push volume | ~1,000–5,000 line writes |
| Peak burst | TBD — depends on ERP's posting cadence |

This is well within what a single SQL Server + the existing in-process
Hangfire worker can handle. The upsert path is a small `MERGE` per PO
plus N `MERGE`s per line, all inside one transaction; ~milliseconds at
this scale.

Load-test as part of Phase 10.6 with 10× the expected daily volume
(50K line writes) to confirm.

---

## 6. Implementation sub-phases (proposed)

| Sub-phase | Scope | Est |
|---|---|---|
| 10.1 | API-key authentication + middleware + key validation | 1 hr |
| 10.2 | `POST /api/erp/pos` endpoint + payload DTOs + validation | 2 hr |
| 10.3 | Upsert logic in a new `ErpIngestService` (transactional MERGE) | 2 hr |
| 10.4 | Audit integration (payload archived as JSON) | 1 hr |
| 10.5 | Search indexes — chosen after observing actual ERP query patterns | 1 hr |
| 10.6 | Integration smoke + load test + ERP-team coordination | 2 hr |
| 10.7 | Docs for ERP team consumption (`docs/erp-integration.md`) | 1 hr |

Total estimate: **8–12 hours.** Tag **v3.0** on completion.

---

## 7. Phase 9 prep summary

For reference — what shipped in v2.3 to set up this work:

- Migration `db/021` adds 20 nullable columns to
  `PurchaseOrderLines`: `InvoiceNo`, `KanbanNo`, `AsnNo`, `PCCNo`,
  `BatchNo`, `ManufacturingControlNo`, `ManufacturingReferenceNo`,
  `CustomerReferenceNo`, `ExportDeclarationNo`, `VendorItem`,
  `PalletId`, `VmiPalletId`, `Location`, `Building`, `SubInventory`,
  `ToLocation`, `ProductionLine`, `OrderRound`, `DeliveryDate`,
  `Note`.
- `PoLineRow` DTO carries all 20 fields; `GET /api/pos/{id}` surfaces
  them in JSON.
- PO Detail UI displays 5 (`Invoice`, `SubInv`, `ToLoc`, `Pallet`,
  `VMI Pallet`); other 15 are API + Excel-export only.
- `PosExportJob` writes a third "Lines" sheet to the XLSX (33 cols:
  PO context + line basic + all 20 ERP fields).
- No write API for these fields — that's the gap Phase 10 fills.
- No indexes — deferred here so they can be designed against real
  query patterns.

All fields are nullable to support gradual ERP rollout: existing rows
stay un-populated until the ERP push fills them in, and a PO that has
no ERP source can coexist with one that does.
