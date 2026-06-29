# Digital Signature (3-party, role-based) for DO reports — Planning Handoff

**Status:** PLANNING ONLY — no code written. This document is the design
brief for a fresh session to build the feature. Verify every "current
state" claim still holds before building (the codebase moves fast).

**Author context:** Drafted 2026-06-29 against branch
`feat/import-source-po-no`. Baseline for the build is whatever is on
`main` at build time — see §5.

---

## 0. Feature ask (from the user, verbatim intent)

- **Both** Delivery reports (Delivery Note + DSV Delivery Order) gain
  **3 signature parties**: **Customer / Warehouse / Production**.
- Signing is **in-system / digital** (not a printed blank box signed by
  hand): a logged-in user **whose role matches the party** clicks "Sign"
  → the system records **signer identity + timestamp**.
- The report renders **per party**:
  - **signed** → signer name + timestamp (and possibly a signature image),
  - **unsigned** → blank box.
- **Anyone with the matching role** can sign that party's box (party is
  role-gated, not assigned to one named person).
- A **new view-only role** is needed (can see reports, cannot sign), plus
  the **sign capability** for the three signer roles.

---

## 1. Current state (verified against code 2026-06-29)

### 1.1 Auth system — custom cookie auth, NOT ASP.NET Identity

- `Services/AuthService.cs` — hand-rolled. PBKDF2 password hashing
  (`IPasswordHasher`), cookie sign-in via
  `CookieAuthenticationDefaults.AuthenticationScheme`
  (`Program.cs:59`). No ASP.NET Identity, no EF — Dapper throughout.
- **Login is warehouse-scoped.** The login form carries a warehouse
  picker; `AuthService.AuthenticateAsync` takes `req.WarehouseId`
  (`AuthService.cs:56`) and writes it into the cookie. The warehouse is
  **chosen at login**, not fixed on the user row.

### 1.2 Two-tier role model (load-bearing — the feature must fit this)

There are **two** role axes, both already in the cookie:

| Axis | Source | Claim | Values seen in DB |
|------|--------|-------|-------------------|
| **Global role** | `dbo.Users.Role` | `ClaimTypes.Role` | `admin`, `supervisor`, `operator`, `viewer` |
| **Per-warehouse role** | `dbo.UserWarehouseAssignments.Role` | `whRole` | `supervisor`, `operator` (admins bypass) |

Claims minted at login (`AuthService.cs:76-87`):
`NameIdentifier` (user GUID), `Name` (username), `displayName`, `email`,
`warehouseId`, `warehouseCode`, `warehouseName`, `whRole`,
`ClaimTypes.Role` (global role).

- **Admins** bypass the assignment check and may log into **any** active
  warehouse (`AuthService.cs:63-66`).
- **Non-admins** must have a row in `dbo.UserWarehouseAssignments`
  `(UserId, WarehouseId, Role, AssignedAt)` for the warehouse they pick,
  or login is refused 403 (`AuthService.cs:69-71`).

**A `viewer` global role already exists** in `dbo.Users` (seed user
`tviewer`, currently `IsActive=0`). It is **not yet wired into any
policy** — effectively it can log in (if a warehouse assignment exists)
but no policy grants it anything. This is a useful hook for the new
view-only requirement (§2.1).

### 1.3 How pages/endpoints are authorized today

Authorization is **policy + role-attribute based** (`Program.cs:94-110`):

```
AdminOnly       → role == admin
CanManagePulls  → admin OR whRole == supervisor
CanReceive      → admin OR whRole in (supervisor, operator)
CanReopenPull   → admin OR whRole == supervisor
```

Plus direct `[Authorize(Roles="admin")]` / `[Authorize(Roles="admin,supervisor")]`
on controllers (e.g. `PoImportController.cs:27`, `ConfigController.cs:17`,
`AdminController.cs:8`).

**Reports are gated by `CanManagePulls`:** `ReportsController` is
`[Authorize(Policy = "CanManagePulls")]` (`ReportsController.cs:18`). So
today only admins and warehouse-supervisors can even view a DO report.
The API report controller is `ReportsApiController`.

### 1.4 Current "signature" in the reports — single, capture-at-close

There is **one** signature today, captured when a **pull is closed**, not
three party signatures:

- `Services/CloseService.cs` persists `Pulls.SignatureSvg` (an SVG string
  **or** a `data:image/png;base64,...` data URL) plus `ClosedByName`,
  `ClosedByRole`, `ClosedAt` (`CloseService.cs:29,90`). It is drawn on a
  signature pad in the close modal (`wwwroot/js/receiving.js`,
  `Views/Receiving/Index.cshtml`).
- The signature is **immutable after close** (§7.5 preserve rule —
  `CloseService.cs:146`).

**Reports render two boxes**, one always blank + one bound to the close
signature:

- **Report 1 — Delivery Note** (the DSV-redesigned primary report):
  - View: `Views/Reports/_DoPreview.cshtml` — boxes `DELIVERED BY`
    (blank, lines 173-176) and `APPROVED FOR DELIVERY BY` (filled from
    `Model.Pull.SignatureSvg`, lines 178-190).
  - PDF template: `Reports/delivery-order.frx` (designer-authoritative
    since v3.5) + bootstrap builder `Services/DeliveryOrderTemplateBuilder.cs`.
- **Report 2 — DSV Delivery Order** (the on-screen 2nd report, commits
  `2458f53`/`36d53ac`):
  - View: `Views/Reports/_DsvOrderPreview.cshtml` — boxes
    `ISSUED / PICKED BY` (blank, lines 94-98) and `APPROVED FOR DELIVERY
    BY` (filled from `Model.Pull.SignatureSvg`, lines 99-124).
  - PDF template: `Reports/delivery-order-dsv.frx` + builder
    `Services/DsvDeliveryOrderTemplateBuilder.cs`.

**Shared data path:** `Services/DoReportDataSetBuilder.cs` builds the
FastReport `DataSet` (master `Orders` PK=`DeliveryNoteNo` + detail
`Lines` + `OrdersLines` relation). Pull-level fields — including the
signature — are **denormalized onto every `Orders` row**; there is an
`Orders.SignatureBytes byte[]` column already (v3.5 Stage 6). Both the
HTML preview and the FastReport PDF consume the **same** `DoReportData`
so screen and paper never drift — any new signature data must flow
through this builder to reach both.

### 1.5 Report grain (critical for the signature grain decision)

A single **pull** explodes into **multiple DO documents**:

- Report 1 master key = `DeliveryNoteNo`; a pull spawns multiple DOs
  split by **(Vendor × FromSubInventory × ToLocation)** (Phase 14).
- Report 2 = "**One Delivery Order per (Pull × From Sub × To Sub)**"
  (`_DsvOrderPreview.cshtml:88-89`).

Today's single close-signature is **per-pull** and is stamped onto
**every** DO that the pull spawns. The new 3-party model has to decide
whether signatures stay per-pull (cheap, but one Customer can't sign
just their own DO) or move to per-DO grain (§2.2 / §3).

### 1.6 Migrations

- Plain SQL files in `db/` (NOT EF migrations). Latest on disk:
  `db/041_backfill_composite_itemcode.sql`. **Next free slot = `db/042`.**
- Convention: idempotent (`COL_LENGTH` / `NOT EXISTS` / `IF OBJECT_ID`
  guards), PascalCase columns matching POCO props, every write audited
  via `IAuditService`.

---

## 2. Proposed design (document — DO NOT BUILD)

### 2.1 Roles & permissions

**Recommendation: reuse the existing global-role axis; add 3 signer roles
+ formalize the view-only role.** Do **not** invent a parallel permission
system — bolt onto `dbo.Users.Role` + the policy table in `Program.cs`.

Proposed global roles after this feature:

| Role | Can view reports | Can sign | Party it signs |
|------|:---:|:---:|---|
| `admin` | ✅ | ✅ (any party — see open Q) | all / override |
| `sign_customer` | ✅ | ✅ | **Customer** |
| `sign_warehouse` | ✅ | ✅ | **Warehouse** |
| `sign_production` | ✅ | ✅ | **Production** |
| `viewer` (exists) | ✅ | ❌ | — |
| existing `supervisor`/`operator` | per policy | TBD (open Q) | TBD |

Open question (resolve with user, §3): are the 3 signer capabilities a
**4th independent claim/role axis** (so an existing supervisor can *also*
be a Warehouse signer) or a **replacement** of the global role? The
existing two-tier model (global + whRole) suggests the cleanest fit is a
**third axis**: a `signParties` claim (multi-value: `customer`,
`warehouse`, `production`) sourced from a new
`UserSignPartyAssignments` table or from per-warehouse assignment rows.
That keeps "anyone with the matching role can sign" without overloading
the single `Role` column. **This is the single most important decision —
flag it first in the fresh session.**

New authorization policies to add in `Program.cs`:

```
CanViewReports   → admin OR viewer OR any signer role OR (existing CanManagePulls holders)
CanSignCustomer  → admin OR has sign-party 'customer'
CanSignWarehouse → admin OR has sign-party 'warehouse'
CanSignProduction→ admin OR has sign-party 'production'
```

⚠️ **Report view gate must loosen.** Today `ReportsController` requires
`CanManagePulls` (admin/supervisor only). View-only signers/viewers need
read access → switch the report view+preview endpoints to a new
`CanViewReports` policy. Keep **export/PDF** on the same view policy;
keep any pull-mutating endpoints on their current stricter policies.

### 2.2 DB schema

New table (proposed name `dbo.DeliveryOrderSignatures`):

| Column | Type | Notes |
|--------|------|-------|
| `Id` | `uniqueidentifier` PK | `NEWID()` |
| `PullId` | `uniqueidentifier` NOT NULL | FK → `dbo.Pulls` |
| `ReportType` | `varchar(16)` NOT NULL | `'Note'` \| `'Order'` (or `'both'` — open Q) |
| `DeliveryNoteNo` | `nvarchar(50)` NULL | the per-DO grain key (Report 1 master PK); NULL if grain = pull |
| `Party` | `varchar(16)` NOT NULL | `'customer'` \| `'warehouse'` \| `'production'` |
| `SignerUserId` | `uniqueidentifier` NOT NULL | FK → `dbo.Users` |
| `SignerName` | `nvarchar(120)` NOT NULL | denormalized display name at sign time |
| `SignerRole` | `varchar(32)` NOT NULL | role/claim used to authorize the sign |
| `WarehouseId` | `uniqueidentifier` NOT NULL | scope guard (mirror the WH-pin convention) |
| `SignatureImage` | `varbinary(max)` NULL | only if drawn/image signatures are chosen (open Q) |
| `SignedAt` | `datetime2` NOT NULL | UTC |

**Uniqueness / grain (DESIGN DECISION — see §3):**
- If grain = **per pull**: `UNIQUE (PullId, ReportType, Party)`.
- If grain = **per DO**: `UNIQUE (PullId, DeliveryNoteNo, ReportType, Party)`.

Index for the report read: `IX_DOSig_Pull (PullId)` INCLUDE the display
columns; the report build does one fetch per pull and fans out.

Migration: **`db/042_delivery_order_signatures.sql`** (idempotent
`IF OBJECT_ID(...) IS NULL CREATE TABLE`). Note the schema-wipe history:
`db/035` wiped transactional data for Phase 14 — the new table holds no
historical data so no backfill is needed.

**Reconcile with the existing close-signature.** `Pulls.SignatureSvg`
(the close "APPROVED FOR DELIVERY BY") overlaps conceptually with the
**Warehouse** party. Decide (open Q): (a) leave close-signature as-is and
add 3 new parties beside it (4 marks total), (b) map the close-signature
onto the Warehouse party, or (c) deprecate the close-signature in favour
of the new 3-party flow. Recommendation: **(a)** for the first cut — keep
close-signature working, add the 3 parties as a new band — lowest risk.

### 2.3 Sign workflow

**Where:** on the report **preview page** (`/Reports` two-pane: closed-pull
list left, HTML preview right). Each party box renders either the signed
caption or — when the current user holds the matching sign capability and
the party is unsigned — a **"Sign as {Party}"** button.

**Flow:**
1. User opens `/Reports`, selects a closed pull → HTML preview loads via
   `ReportsApiController` preview endpoint.
2. Preview computes per-party `{signed?, canSign?}` from the signature
   rows + the current user's claims.
3. Unsigned + canSign → button. Click → `confirmAction({...})` modal
   (existing convention) → POST sign endpoint.
4. New API: `POST /api/reports/{pullId}/sign` body
   `{ party, reportType, deliveryNoteNo? }`. Server **re-checks** the
   role/claim (never trust the UI), re-checks not-already-signed under a
   transaction, inserts the signature row, writes an `IAuditService` row
   (`ActionType` e.g. `do-sign`), returns the new state.
5. Preview re-fetches → box flips to signed.

**Validation / invariants:**
- Role match enforced **server-side** by policy (`CanSign{Party}`).
- Warehouse scope: signer's session `warehouseId` must match the pull's
  warehouse (mirror the import/export WH-pin pattern); admins bypass.
- Idempotency: unique constraint + a pre-insert `NOT EXISTS` check →
  return 409 if the party is already signed.
- **Audit every sign** (project invariant: every write writes an audit
  row).

**Multi-party / re-sign / unsign (open Q, §3):**
- Can one user sign multiple parties? (e.g. admin signing all three.)
  Default proposal: a user signs **only** parties they hold the
  capability for; admin may override.
- Re-sign / unsign: default proposal **no unsign** (append-only, matches
  the Receipts/close immutability philosophy). If a correction is needed,
  an admin-only "void + re-sign" path. Confirm with user.

### 2.4 Report display (both reports)

Replace the current 2-box footer with a **3-party signature band** (or
4-box if keeping close-signature per §2.2 recommendation (a)):

- **Signed:** party label + signer name + timestamp
  (`dd MMM yyyy · HH:mm UTC` to match `_DoPreview.cshtml:118`) + optional
  signature image.
- **Unsigned:** blank box + caption (paper fallback for manual sign).

**Both surfaces must change together** (screen + paper never drift):
1. **HTML previews:** `_DoPreview.cshtml` (Report 1) and
   `_DsvOrderPreview.cshtml` (Report 2) — swap the sig footer markup;
   add CSS in `wwwroot/css/reports.css`.
2. **FastReport PDFs:** `Reports/delivery-order.frx` +
   `Reports/delivery-order-dsv.frx`. The `.frx` files are
   **designer-authoritative** since v3.5 — signature bands should be
   added in **FastReport Designer Community 2023.2.15**, not by
   regenerating from the bootstrap builder. The builders
   (`DeliveryOrderTemplateBuilder.cs`, `DsvDeliveryOrderTemplateBuilder.cs`)
   remain the fresh-environment fallback and should be updated to match.
3. **Data path:** extend `Services/DoReportDataSetBuilder.cs` so the 3
   party signatures (name/timestamp/image) are **denormalized onto every
   `Orders` row** (like the existing `SignatureBytes`). New `Orders`
   columns e.g. `CustomerSignerName/At/Bytes`, `WarehouseSigner...`,
   `ProductionSigner...`. FastReport binds via DataColumn; images decode
   through the existing `DecodeAndFlattenImage` (white 24bpp flatten —
   PDF JPEG rasterization has no alpha).

⚠️ **PDF is a snapshot.** The exported PDF reflects sign state **at
export time** only — it does not live-update. The HTML preview is the
live surface; the PDF freezes whatever was signed when the operator
clicked Export. Document this clearly for operators (a half-signed DO
exported early will show blanks for the not-yet-signed parties). Decide
(open Q) whether export should be **blocked until all 3 parties sign**,
or always allowed with blanks.

### 2.5 Permission enforcement summary

- **View-only role** (`viewer` + any signer who isn't this party): sees
  the report + all boxes; sees signed captions; gets **no Sign button**
  for parties they can't sign.
- **Signer roles:** see a Sign button only for their party while unsigned.
- **Page authorization changes:** loosen report **view** to
  `CanViewReports`; gate each **sign** endpoint with its own
  `CanSign{Party}` policy; keep pull-mutation endpoints stricter.

---

## 3. Open decisions (resolve with user at the start of the build session)

1. **Role axis (TOP PRIORITY).** Are Customer/Warehouse/Production a new
   independent capability axis (a `signParties` multi-claim, so existing
   supervisors/operators can also be signers) or a replacement of the
   global `Role`? → drives the entire schema + claims design.
2. **Sign grain.** Per **pull** (one set of 3 signatures shown on all of
   the pull's DOs) or per **DO / DeliveryNoteNo** (each split DO signed
   independently)? The Customer party especially may differ per DO since
   DOs split by vendor/destination.
3. **Signature representation.** Typed name + timestamp only? Drawn
   signature (reuse the existing signature-pad from the close modal)?
   Uploaded image? → drives `SignatureImage` column + render path.
4. **Re-sign / unsign / void.** Append-only (recommended) vs editable vs
   admin-only void. Does signing **lock** anything?
5. **PDF snapshot policy.** Allow export with unsigned blanks, or block
   export until all parties sign?
6. **Close-signature reconciliation.** Keep the existing pull-close
   "APPROVED FOR DELIVERY BY" as a 4th mark (recommended), map it to the
   Warehouse party, or deprecate it?
7. **Admin override.** Can an admin sign any/all parties (e.g. for
   backfill or absent signer)? Audited as override?
8. **Warehouse scope.** Must a signer's session warehouse match the
   pull's warehouse (recommended), or can any holder of the role sign
   regardless of warehouse?

---

## 4. Phased build plan

Mirror the project's sub-phase rhythm (schema → repo → service →
controller → UI → smoke), one commit per stage, smoke per phase.

- **Phase 1 — Role + permission model.** Resolve §3.1. Add the 3 signer
  capabilities + formalize `viewer`. Mint the new claim(s) in
  `AuthService`. Add `CanViewReports` + `CanSign{Party}` policies in
  `Program.cs`. Seed/assign test users. Smoke: each role's claims +
  policy outcomes (incl. negative cases).
- **Phase 2 — Schema + migration.** `db/042_delivery_order_signatures.sql`
  (grain per §3.2). Entity + DTO + `IDeliveryOrderSignatureRepository`
  (insert + read-by-pull + not-already-signed check). Smoke: schema
  shape, unique constraint, idempotent re-run.
- **Phase 3 — Sign workflow + UI.** `POST /api/reports/{pullId}/sign`
  with server-side policy re-check + WH-pin + audit row. `/Reports`
  preview renders per-party `{signed, canSign}` + Sign buttons via
  `confirmAction`. Smoke: sign happy path, wrong-role 403, double-sign
  409, audit row present, cross-warehouse block.
- **Phase 4 — Report display (both reports).** Extend
  `DoReportDataSetBuilder` (denormalized per-party columns). Update both
  HTML previews + both `.frx` (in Designer) + both builders + CSS.
  Smoke: signed/unsigned render in both HTML previews; PDF text-layer +
  size floor for both reports (extend `smoke-do-report` +
  `smoke-phase-14-do-multi-do`).
- **Phase 5 — Permission enforcement.** Wire `CanViewReports` onto the
  report view/preview/export endpoints; verify view-only sees no Sign
  buttons + sign endpoints 403 them. Resolve §3.5 export policy. Smoke:
  full permission matrix (viewer / each signer / admin / supervisor /
  operator / anonymous) across view + sign + export.

---

## 5. Branch / baseline

- **Drafted on:** `feat/import-source-po-no` (current working branch;
  unrelated in-flight work — DSV report tweaks + import source PO no).
- **Build baseline:** branch from **`main`** at build time (don't build
  on the import branch). Latest shipped tag is **`v3.5`** (DSV redesign +
  designer-authoritative `.frx`). Latest migration on disk is
  **`db/041`** → new work takes **`db/042`**.
- **Pre-flight before building:** re-run the §1 verification greps —
  especially confirm (a) the policy list in `Program.cs`, (b) the report
  view gate on `ReportsController`, (c) the two preview view filenames,
  (d) the `.frx` filenames, and (e) that `viewer` is still an unwired
  role.

---

## 6. Files this feature will touch (map for the build session)

| Concern | File(s) |
|---|---|
| Claims at login | `Services/AuthService.cs` |
| Policies | `Program.cs` (`AddAuthorization`) |
| Report view gate | `Controllers/ReportsController.cs`, `Controllers/Api/ReportsApiController.cs` |
| New sign endpoint | `Controllers/Api/ReportsApiController.cs` (or new controller) |
| Schema | `db/042_delivery_order_signatures.sql` |
| Entity/DTO/repo | `Models/Entities/*`, `Models/Dtos/DoReportDtos.cs`, new `Data/Repositories/DeliveryOrderSignatureRepository.cs` |
| Report data path | `Services/DoReportDataSetBuilder.cs`, `Models/Dtos/DoReportDtos.cs` |
| HTML previews | `Views/Reports/_DoPreview.cshtml`, `Views/Reports/_DsvOrderPreview.cshtml` |
| PDF templates | `Reports/delivery-order.frx`, `Reports/delivery-order-dsv.frx` (+ builders `Services/DeliveryOrderTemplateBuilder.cs`, `Services/DsvDeliveryOrderTemplateBuilder.cs`) |
| Styles | `wwwroot/css/reports.css` |
| Sign UI | `/Reports` page JS (locate current report JS in the build session) |
| Audit | `IAuditService` (every sign writes a row) |
| Smokes | extend `smoke-do-report`, `smoke-phase-14-do-multi-do`; new `smoke-do-signatures` |

---

**Reminder for the fresh session: resolve §3 with the user BEFORE writing
any code. The role-axis decision (§3.1) and the sign-grain decision
(§3.2) cascade through the schema, claims, and both report surfaces.**
