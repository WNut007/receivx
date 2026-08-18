# Defect — a `ROUND` / `WINDOWS_TIME` value naming several hours keeps only the first

**Status:** open, not fixed. Logged 2026-08-19 during the storer-grain work
(`brief-storer-grain.md` §5.1, which explicitly scoped it out: *"this change must not
alter it — but if it silently drops hours, log it as a separate defect"*). It does.

**Severity:** high by volume, invisible by nature. **921 of 4,401 rows** in one day's
export carry a multi-hour value, covering **3,761,646 units across 153 pull sheets**.
Every hour after the first is discarded with no error, no log line, and no trace in the
data that anything was dropped.

---

## Symptom

The ERP emits several receiving hours in one cell:

```
07:00|08:00|09:00|10:00
19:00|20:00|21:00|22:00
00:00|01:00|02:00|23:00
```

Receivx creates **one** window, at the first listed hour, carrying the row's entire
quantity. The other three hours never exist. An operator receiving at 10:00 against a
row planned for `07:00|08:00|09:00|10:00` finds no window at 10:00 — the goods have to
be booked against 07:00, and the hour-cap arithmetic (§7.1) is measured against a
window that claims the whole day's quantity arrives in one hour.

## Mechanism

`BpiPrsSource.ParseHour` (`:201`) splits on the **first** colon and parses the head:

```csharp
var s = windowsTime.Trim();
var hourPart = s.Split(':', 2)[0].Trim();       // "07:00|08:00|09:00|10:00" → "07"
if (byte.TryParse(hourPart, out var h) && h <= 23) return h;
return null;
```

`"07:00|08:00|09:00|10:00".Split(':', 2)` yields `["07", "00|08:00|09:00|10:00"]`. The
head is `"07"`, which parses cleanly, so the method returns **7** and the caller's
fallback never runs. Verified against every multi-hour pattern in the export:

| Value | Returns | Hours lost |
|---|---|---|
| `07:00\|08:00\|09:00\|10:00` | 7 | 8, 9, 10 |
| `19:00\|20:00\|21:00\|22:00` | 19 | 20, 21, 22 |
| `00:00\|01:00\|02:00\|23:00` | 0 | 1, 2, 23 |
| `08:00\|09:00` | 8 | 9 |

### The docstring says the opposite

Directly above that code:

> *Returns null for null/blank/**multi-window-list**/anything weird.*

That clause is false, and it is the most damaging part of the defect. The caller reads

```csharp
var hour = ParseHour(row.WINDOWS_TIME) ?? (byte)7;
```

and a reader checking whether multi-hour values are handled finds a documented
null-return plus a visible fallback, concludes the case is covered, and moves on. It is
not covered: the fallback is dead code for these inputs. Anyone auditing this path is
actively misled, which is why the wrong comment is worth fixing even if the behaviour
is left alone.

### Two parsers, one upstream column, opposite behaviours

| Path | Input `03:00\|04:00` | Result |
|---|---|---|
| ETL — `BpiPrsSource.ParseHour` | accepted | one window at 03:00, 04:00 dropped |
| WIP synthesis — `WipPullSynthesis.TryParseRoundHour` | rejected | validation error, whole file refused |

The WIP rule was written deliberately (an invented `HourOfDay` books stock in the wrong
window, so a human should look), and it has never fired: **zero** of the 921 multi-hour
rows carry a WIP storer code. But the two rules cannot both be right, and whichever way
this is resolved should resolve both.

## Blast radius

- **Hour-cap arithmetic.** With `LockHourCap = true` the single window's `ExpectedQty`
  is the whole multi-hour quantity, so the cap permits at 07:00 what was planned across
  four hours. With `LockHourCap = false` an operator receiving at a later hour has no
  window to receive into at all.
- **The receiving grid** shows work concentrated in one hour of a period that was
  planned across four, which is what the operator schedules staff against.
- **Overlap with the storer-grain defect.** Most of the same-`ROUND` storer collisions
  are multi-hour values — e.g. `0000028079 | 2053-800724-000 | 07:00|08:00|09:00|10:00`
  with `COI-84491` and `COI-5732`. The two defects are independent (one is a grouping
  key, one is a parser) but they land on the same rows, so a test fixture for either
  should carry the other's shape too.

## Fix sketch — not applied

1. **Expand to one window per listed hour**, splitting the quantity — but *how* it
   splits is a business question nobody has answered: evenly, all on the first, or
   proportionally? Guessing here writes fabricated plan data, which is worse than the
   current loss because it looks precise.
2. **Reject like the WIP path does** — surface it as an ETL error per row and let a
   human decide. Consistent with `TryParseRoundHour`, but it would fail ~21% of rows on
   every run, which makes the sync unusable until the ERP changes.
3. **Keep the first hour, but record the drop** — leave behaviour identical and write
   an `etl-window-collapse` audit row naming the pull, item, and discarded hours. The
   cheapest honest option: nothing changes, and the loss stops being invisible.

Whichever is chosen, **fix the docstring first** — it costs nothing and it is the part
actively misleading readers today.

The regression guard is a fixture row with `WINDOWS_TIME = '07:00|08:00'`. None exists:
`ParseHour` has no direct test, and the storer-grain harness
(`tools/ErpUpsertHarness`) builds drafts with single-hour windows.

## Related, do not conflate

- The storer-grain change (grouping key `(ItemCode, VendorCode)`) touches the same rows
  but not this code path. `ParseHour` is unchanged by it.
- `docs/defect-po-import-numeric-cell-leading-zeros.md` and
  `docs/defect-po-import-qty-format-misattribution.md` are the PO-import side's parser
  defects — same family (a cell reader losing information silently), different reader.
