# Runbook — adding pull items ad-hoc (v2.0)

> **TL;DR**: `pwsh tools\add-pull-item.ps1` — interactive prompts, transactional,
> audit-tagged. Use it instead of hand-writing SQL. UI for this lands in v2.1.

## When to use this tool

v2 treats pulls as **upstream artifacts** (analogous to an ERP-sourced ASN).
Normal operation flow:

1. Planning system creates a pull + its items in bulk via seed migrations
   (`db/006_seed_pulls_and_items.sql`).
2. Purchasing creates POs covering those item codes in the /Pos admin UI.
3. The warehouse team receives against those pulls — no in-app authoring of
   pull items.

Reach for this tool when normal flow breaks down:

- **Vendor over-ships** an item not on the planned pull manifest, and you need
  to receive it against this pull rather than a separate one.
- **Late add** — planning sends a delta after the seed migration is already
  applied to the environment.
- **Demo / staging fixtures** — building a one-off pull for a presentation
  without re-seeding the whole DB.

If you find yourself reaching for this tool more than a few times a month,
that is a signal that the v2.1 in-app UI should be prioritised — flag it.

## What the tool does

- Validates the pull exists and isn't `closed` / `fully_received` (the §7.4
  rule that closes admin writes for closed pulls).
- Looks up the ItemCode in open `PurchaseOrderLines`:
  - **hit**  — uses the PO line's `Description` as the default for the
    `Description` prompt (override allowed).
  - **miss** — warns ("receives will 409 'No PO capacity' until a PO line
    covers it") and asks to add anyway.
- Idempotency check on `(PullId, ItemCode)`:
  - **doesn't exist** → create a new `PullItems` row + 1..N `PullItemWindows`.
  - **exists with `ReceivedQty = 0` on every window** → offers to **replace
    all windows** (delete + re-insert) on the existing item.
  - **exists with `ReceivedQty > 0` on any window** → **refused**. Use raw
    SQL only if you really need it (caveat below).
- Wraps the work in a transaction with `SET XACT_ABORT ON`. Any failure
  rolls back and the tool offers retry.
- Writes a row to `dbo.AuditLog` with
  `ActorName = N'[script: ' + SUSER_SNAME() + ']'` so script mutations stand
  out from real user actions in `/Masters` audit search.

## Prerequisites

- PowerShell 7+ (`pwsh.exe`). Windows PowerShell 5.1 reads .ps1 as the
  system codepage and mangles em-dashes / Unicode in the source.
- `sqlcmd` on PATH.
- SQL access (Windows-auth by default; pass `-Server` / `-Database` to
  override) with INSERT on:
  - `dbo.PullItems`
  - `dbo.PullItemWindows`
  - `dbo.AuditLog`
  …and SELECT on `dbo.Pulls`, `dbo.PurchaseOrders`, `dbo.PurchaseOrderLines`,
  `dbo.Users` (for the audit FK `SET NULL` constraint).

## Walkthrough

```text
PS> pwsh -File tools\add-pull-item.ps1

=== Add PullItem — v2.0 ad-hoc tool (UI deferred to v2.1) ===
Server: LAPTOP-CSB3KO3E / Database: ReceivingOps
Press Ctrl+C at any prompt to abort.

Pull number (e.g. PL-2847): PL-2847
OK: Pull PL-2847 found (status=in_progress, id=33333333…)

Item code: PCBA-AX452-R1
OK: ItemCode found on open PO — defaulting Description to 'PCBA AX452 Rev 1' (override allowed).

Description [PCBA AX452 Rev 1]: <Enter to accept default>
Vendor code (optional): VND-ACME
Vendor name (optional): Acme Components Ltd
Tag (pcba|swap|none) [none]: pcba

=== Hour windows (HourOfDay 0..23, no duplicates) ===
How many hour windows?: 2
  Window 1: hour (0-23): 8
  Window 1: expected qty (>0): 500
  Window 2: hour (0-23): 9
  Window 2: expected qty (>0): 500

=== Summary ===
  Mode:        create
  Pull:        PL-2847  (id=33333333…)
  ItemCode:    PCBA-AX452-R1
  Description: PCBA AX452 Rev 1
  Vendor:      VND-ACME / Acme Components Ltd
  Tag:         pcba
  Windows:
    hour 08:00  qty=500
    hour 09:00  qty=500

Apply now? [Y/n]: <Enter>
Executing transaction…
OK: Committed PullItem 7b3e0a92…  (2 window(s))
Audit row written; OccurredAt = now (UTC).

Add another? [y/N]: N

Done.
```

After it returns you can:

- Open `/Receiving/PL-2847` — the new item appears in the hour grid.
- Search `/Masters` → Audit for `actorName LIKE '[script:%'` to see the row.

## Caveats

- **Receives needs a covering PO line.** If you bypass the no-PO warning,
  the item is in the pull but `POST /api/receipts` will reject with
  HTTP 409 "Insufficient PO capacity" until a PO line is added (via /Pos).
- **Hour windows are `UNIQUE (PullItemId, HourOfDay)`.** Duplicate hours in
  the same prompt batch are caught client-side; cross-batch duplicates on
  an existing item are only reachable via the replace-windows path.
- **Replace-windows is destructive.** All existing windows on that item are
  deleted before the new ones are inserted. Already gated against
  `ReceivedQty > 0` but mind the order if you're scripting multiple runs.
- **Pull statuses `closed` / `fully_received` are refused.** Reopen the
  pull first (`POST /api/pulls/{id}/reopen` with `CanReopenPull`) if you
  truly need to add items to a closed pull — but that's a strong signal
  something is off in the planning flow upstream.
- **Audit rows are tagged `[script: <SQL_LOGIN>]`** so they're easy to
  separate from user-driven mutations. Keep this tag pattern if you fork
  the tool — production audit search relies on it.
- **Not for bulk loads.** If you have more than a handful of items, write
  a SQL migration file in `db/` instead. This tool is for ad-hoc; the seed
  flow is for fleet-scale changes.

## Escape hatch — raw SQL

When the tool refuses (e.g. `ReceivedQty > 0` on the existing item, or
the pull is closed, or you need to edit `Description` / `Tag` / `SortOrder`
of an existing item), the raw SQL pattern is:

```sql
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRAN;

-- Find the IDs you need
DECLARE @PullId UNIQUEIDENTIFIER = (SELECT Id FROM dbo.Pulls WHERE PullNumber = 'PL-XXXX');
DECLARE @PullItemId UNIQUEIDENTIFIER = NEWID();

INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode,
                           VendorName, Tag, Status, SortOrder)
VALUES (@PullItemId, @PullId, 'ITEM-CODE', N'Description', 'VND-XXX',
        N'Vendor Name', NULL, 'normal',
        (SELECT ISNULL(MAX(SortOrder),0)+1 FROM dbo.PullItems WHERE PullId = @PullId));

INSERT INTO dbo.PullItemWindows (PullItemId, HourOfDay, ExpectedQty)
VALUES (@PullItemId, 8, 500),
       (@PullItemId, 9, 500);

INSERT INTO dbo.AuditLog (ActionType, EntityType, EntityId, Message,
                          ActorUserId, ActorName)
VALUES ('create', 'PullItem', @PullItemId,
        N'Manual SQL add — reason: <document here>',
        NULL, N'[manual-sql: ' + SUSER_SNAME() + ']');

COMMIT TRAN;
```

Keep the `Message` body specific. The audit retention window is unbounded
(BUILD_PROMPT.md §14) — six months from now you'll thank yourself.

## What's coming in v2.1

- `POST /api/pulls/{id}/items` + `PUT` / `DELETE` siblings under a
  `CanManagePulls` policy.
- An items grid in the Pull detail drawer with add / edit / remove
  affordances (similar shape to the Lines table in `/Pos`).
- Hour-window management as a separate sub-resource so window edits don't
  rewrite the whole item.

When that ships, this runbook gets promoted to "legacy escape hatch" and the
tool stays for environments without UI access (CI, scripted seed extensions).
