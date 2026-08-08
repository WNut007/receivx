# Brief — Structured reason code for accepted variance (replaces free-text-only note)

Target: `ReceivingOps` v3.2, `C:\dev\receivx`, project `src/ReceivingOps.Web`.
Type: **one additive migration (`db/049`) + code.** Read §7 on deploy order before starting.
Base branch: `feat/digital-signature` (production builds from this branch, not `main`).

---

## 1. Why

The PO-overflow work shipped and is live. The Receive Goods modal now requires a
free-text note whenever accept-variance is ticked — the note is the audit reason.

Observed in production on the first real use: the operator typed `.` to satisfy the
validator. That is not operator error, it is the predictable outcome of requiring
prose on a path that fires constantly. Over-delivery happens on **nearly every pull**
at this site, so a required free-text field converts into a required keystroke, and
the audit trail fills with characters that record nothing.

The goal is not to make the operator write more. It is to capture the same reason as
**data** — fast to enter, and aggregable afterwards ("which vendors over-deliver, and
why") which free text can never support.

---

## 2. The reason set — fixed, decided, do not extend

| Code | Label (display verbatim) | Applies to |
|---|---|---|
| `OVER_DELIVERY` | ส่งเกิน | over only |
| `SHORT_DELIVERY` | ส่งขาด | short only |
| `COUNT_MISMATCH` | นับได้ต่างจากเอกสาร | both |
| `DAMAGED_PARTIAL_RETURN` | ของเสียหาย/ตีกลับบางส่วน | short only |
| `PO_SPLIT_MISMATCH` | PO แตกไม่ตรงกับการส่ง | both |
| `OTHER` | อื่นๆ (ต้องระบุ) | both |

Direction is computed from the quantity already known at that point in the modal:
over when `qty > outstanding`, short when `qty < outstanding` (including `qty = 0`).
Show only the codes valid for the current direction — offering "ส่งเกิน" on a short
close is noise that invites a wrong click.

The codes are the stable identifier and never change. Labels are display only.

**Labels are Thai and render exactly as written above**, even though the surrounding
modal is in English. This is deliberate: the operators using this dropdown work in
Thai, and a reason picked from a list they read fluently is the difference between a
real answer and a reflex click — which is the entire defect being fixed here. Do not
translate them, do not append an English gloss.

Keep every label in one map (code → label) so a future language decision is a
one-line change rather than a hunt through markup. Never render a raw code in the UI,
and never key any logic off a label.

---

## 3. Storage — `db/049`, additive only

Add one column next to the existing close-audit columns:

```
dbo.PullItemWindows.VarianceReasonCode  NVARCHAR(32) NULL
```

Rationale for the column rather than prefixing into `ClosedReason`: a code that has
to be parsed back out of a sentence is not structured data, and the whole point of
this change is to be able to group by it. `NVARCHAR(32)` is deliberately wider than
the longest current code so a future addition needs no schema change.

Window level, not receipt level — this sits beside `ClosedBy` / `ClosedAt` /
`ClosedReason`, which are already the window's close-audit record, and a variance
acceptance always closes the line. Do not add a parallel column on `Receipts`.

Requirements for the migration file:

- Guard every statement with `IF COL_LENGTH('dbo.PullItemWindows','VarianceReasonCode') IS NULL`,
  matching the idempotent pattern in `db/021` / `db/024`.
- Nullable, no default. Existing closed windows genuinely have no code and must not
  be back-filled with a guess — `NULL` means "closed before reason codes existed"
  and every report must treat it as its own bucket, not fold it into `OTHER`.
- No `CHECK` constraint pinning the allowed values. Adding a code later would then
  require a migration to change a constraint, and the application already validates
  the set. State this choice in the file header so a later reader does not "fix" it.
- No index in this migration. Add one when a report actually groups on it and the
  row count justifies it.

**`db/047` was checked and needs no correction.** An earlier revision of this brief
expected it to declare `ClosedBy` as `NVARCHAR(100)` and `ClosedReason` as
`NVARCHAR(500)`, diverging from production. It does not: as committed it declares
`ClosedBy UNIQUEIDENTIFIER NULL` (line 223) and `ClosedReason NVARCHAR(1000) NULL`
(line 236), matching production exactly, with the header block and the `@missing`
post-check in agreement. A fresh install already lands on the production shape. No
corrective statement appears in `db/049`. Verified 2026-08-08.

---

## 4. Behaviour

### 4.1 When the dropdown appears

Only when accept-variance is in play — i.e. the final-receipt box is ticked **and**
the quantity differs from outstanding. An exact-quantity final receipt is not a
variance and must not ask for a reason.

### 4.2 Validation — this is the part that fixes the `.` problem

- **Reason code: required** whenever a variance is being accepted. No default
  selection, no pre-selected first item; the operator must make a positive choice.
  A pre-selected value would reproduce the current defect in a new shape.
- **Free-text note: required only when the code is `OTHER`.** For every other code
  the note becomes optional and its placeholder should invite detail rather than
  demand it.
- When the note is required, reject whitespace-only and single-punctuation input
  (trimmed length below a small floor — 3 characters is enough to stop `.` and `-`
  without frustrating a terse but real answer). Say what is wrong in the message.

Server-side validation is authoritative. The client check is advisory, per
`BUILD_PROMPT` §7 — a request carrying a variance with no code, or `OTHER` with an
empty note, must be refused by the API even if the UI would not have sent it.

Reject a code that is not in the set, and reject a code that is not valid for the
direction (e.g. `OVER_DELIVERY` on a short close). Both are `400` with a message
naming the problem.

### 4.3 What the reason does and does not affect

The reason code is **audit metadata only**. It must not influence allocation, the
overflow decision, `VarianceQty`, `IsClosed`, or PO consumption. Nothing in
`ReadOpenPoLinesAsync` or the FIFO walk reads it. If you find yourself branching on
the code inside allocation logic, stop — that is out of scope and changes the shape
of the feature.

### 4.4 Interaction with cancel

`CancelAsync` step 8c already clears the four `Closed*` columns when a variance
receive is reversed and the window reopens. `VarianceReasonCode` must be cleared in
exactly the same place, under the same lock, in the same statement. A reopened window
carrying a stale reason code is the same defect class as the orphaned `VarianceQty`
that was just fixed — the whole point of that work was that a reopened window must
not still claim a decision that no longer holds.

---

## 5. Audit

The audit row written at `ReceiptService.cs` step 8 currently records quantity, item,
hour, scope label and allocation summary. Add the reason code to it. The audit
message is read by humans, so write the code and, if a note was supplied, that the
note exists — do not paste a long note into the audit summary; it is already stored
on the window.

`ClosedReason` continues to store the free text exactly as today. The code does not
replace it; it makes it optional.

---

## 6. Tests

Add to the variance smoke suite (`smoke-po-overflow-variance.ps1`, or a new
`smoke-variance-reason.ps1` if that file is already long — say which you chose):

1. Over-receipt with a valid over-direction code and no note → succeeds; window
   carries the code; `ClosedReason` is NULL or empty.
2. Over-receipt with `OTHER` and no note → `400`; nothing written.
3. Over-receipt with `OTHER` and note `"."` → `400`; nothing written.
4. Over-receipt with `OTHER` and a real note → succeeds; both stored.
5. Variance accepted with **no** code → `400`, server-side, even when the request is
   otherwise well-formed.
6. `OVER_DELIVERY` submitted on a short close → `400`, direction validation.
7. `SHORT_DELIVERY` submitted on an over-receipt → `400`.
8. Unknown code (`"FOO"`) → `400`.
9. Zero-quantity short close with a valid short code → succeeds; no `Receipts` row
   written (§2d holds); code stored on the window.
10. Multi-slice over-receipt (the 33,001 shape) with a code → code stored once on the
    window; both receipt rows unaffected by the code.
11. Cancel a slice of a variance receive → `VarianceReasonCode` cleared alongside
    `ClosedBy` / `ClosedAt` / `ClosedReason`; window reopens with no residue.
12. Exact-quantity final receipt → no code required, none stored, request succeeds.
13. Legacy row: a window closed before this change (code `NULL`) is untouched by any
    new query and still renders correctly in the Receiving view.

Wire the smoke into `tools/run-smokes.ps1` in the same commit. A smoke that is not
in the battery is not coverage — that gap was just found and logged for five other
db/047 smokes; do not add a sixth.

**Chosen: a new `smoke-variance-reason.ps1`.** `smoke-po-overflow-variance.ps1` was
already 836 lines carrying 13 cases of its own. Wired into the battery in the same
commit. It carries the 13 cases above plus a case 0 covering
`GET /api/receipts/variance-reasons` — the code set, its order, the direction flags,
and an assertion that every label is non-ASCII, which is what catches a well-meaning
future translation to English.

---

## 7. Deploy order — non-negotiable

This brief adds a migration, so the failure mode that took production down on
2026-08-07 is back in play. That outage was a new DLL deployed against a schema that
had not been migrated; `/api/pulls` returned 500 on `Invalid column name 'IsClosed'`
until the migration was run by hand.

1. Run `db/049` on production **first**.
2. Verify: `SELECT COL_LENGTH('dbo.PullItemWindows','VarianceReasonCode');` returns
   non-NULL. It returns **64** — `COL_LENGTH` reports bytes, and `NVARCHAR(32)` is 32
   characters at 2 bytes each. Non-NULL is the pass condition; do not halt on seeing
   64 rather than 32.
3. Then `deploy.ps1`.

`deploy.ps1` does not run migrations. Do not rely on it to.

The migration is additive and nullable, so it is backward compatible with the
currently deployed DLL — running it early is safe and carries no rollback risk.

**Status: `db/049` was applied to production 2026-08-08 17:01 ICT**, ahead of the
DLL, per the order above. Recorded in the migration ledger in `db/047_STATUS.md`,
which is the only place production migration state is tracked.

---

## 8. Out of scope

- Making the reason list editable from a Settings screen. Six fixed codes do not
  justify a configuration surface; revisit if the list starts changing.
- Any report, export or dashboard grouping by reason code. This brief captures the
  data; consuming it is separate work, and doing both at once makes the capture
  design chase a report layout.
- Back-filling reason codes onto historical closed windows.
- `CK_POL_Caps`, `LockPoByPull` defaults, `vw_PurchaseOrderAvailability`, the
  `deploy.ps1` pre-flight schema guard, and the pull-status demotion defect logged in
  **`db/047_STATUS.md`**. All separate items.

  *(Pointer corrected: an earlier revision of this brief cited
  `docs/defect-pull-update-check-precedence.md` for the demotion defect. That file
  documents a different one — `PUT /api/pulls/{id}` reporting "LockHourCap is
  immutable" for a closed pull. The demotion defect — cancel step 9 demoting on
  status alone instead of recomputing from outstanding windows — is logged in
  `db/047_STATUS.md` as of `7c15ef9`.)*
