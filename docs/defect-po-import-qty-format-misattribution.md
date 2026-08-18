# Defect — an unparseable `OPEN QTY` is reported as "Must be > 0"

**Status:** open, not fixed. Logged 2026-08-18 while building the Imports download-template
action (`brief-import-template.md`). **Deliberately out of scope for that change** — the brief
permitted no change to `PoImportReader` beyond widening `RequiredHeaders` visibility.

**Severity:** low-moderate. The file is correctly rejected; the *reason* the operator is given
points at the quantity when the problem is the cell's format, so the obvious next move — go
and correct a number that is already correct — cannot succeed.

---

## Symptom

A workbook whose `OPEN QTY` column arrived as text (a common outcome of a CSV round-trip, a
locale-formatted export, or a hand-edited cell) fails Stage 1 validation with, per row:

```
Row 2 · OPEN QTY · Must be > 0
```

The cell visibly reads `1,200`. The operator reads the message as a claim about the value, not
the type. Because the import is atomic (Q3=A), one such row rejects the entire file, so a
4,401-row export produces thousands of identical "Must be > 0" errors for a quantity column
that is, in fact, fully populated with positive numbers.

## Mechanism

**1. `GetInt` returns `null` for anything `NumberStyles.Integer` won't take.**
`PoImportReader.cs:300`:

```csharp
return int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : null;
```

`NumberStyles.Integer` is `AllowLeadingWhite | AllowTrailingWhite | AllowLeadingSign` — no
thousands separator, no decimal point. So `"1,200"` → `null` and `"1200.0"` → `null`. Both are
deliberate: the strictness is what stops a German-locale `"1.234,5"` from being read as 1234.
The strictness is right; the reporting is not.

**2. The null collapses into a zero before anyone can tell them apart.**
`MapRow` (`PoImportReader.cs:192`):

```csharp
OrderedQty = GetInt(row, map, "OPEN QTY") ?? 0,
```

**3. `ValidateRow` then describes the zero, not its cause.** `PoImportReader.cs:235`:

```csharp
if (row.OrderedQty <= 0)
    errors.Add(new() { RowNumber = row.RowNumber, Column = "OPEN QTY", Message = "Must be > 0" });
```

By this point three distinct conditions are indistinguishable: the cell was genuinely `0`, the
cell was blank, or the cell held a value `GetInt` could not parse. All three produce
`OrderedQty = 0` and the same message.

## Blast radius

- Every text-typed or locale-formatted `OPEN QTY` column. The sample export is numeric-typed
  on all 4,401 rows, so this is latent in production today — but unlike the leading-zeros
  defect it fails *loudly* and writes nothing, so the cost is operator time and a support
  round-trip, not corrupt data.
- The same conflation applies to a blank `OPEN QTY`: "Must be > 0" for a cell that is empty.
- `GetInt` is only called for `OPEN QTY`, so the blast radius stops there.

**Not a defect, do not fix:** a *numeric* cell of `1200.5` truncating to `1200`
(`PoImportReader.cs:296`) is the CLAUDE.md whole-units invariant working as designed.

## Fix sketch — not applied

1. **Distinguish the three cases in `ValidateRow`.** Have `MapRow` keep the raw cell text (or
   have `GetInt` report *why* it returned null) so validation can emit "OPEN QTY is not a whole
   number — found '1,200'" separately from "OPEN QTY must be greater than zero" and "OPEN QTY
   is required". Smallest change with the whole benefit; the DTO grows a field.
2. **Widen what `GetInt` accepts** — e.g. `AllowThousands`, and a decimal parse that truncates.
   Tempting and wrong on its own: it silently re-admits exactly the locale ambiguity the
   current strictness exists to reject, and it would still say "Must be > 0" for the cases it
   still refuses.
3. **Report the cell type in the error.** Weakest option, but nearly free: append the source
   cell type to the existing message so "Must be > 0 (cell type: String)" at least points at
   the format.

Regression guard for any of them: a fixture workbook with `OPEN QTY` written as the strings
`1,200` and `1200.0`. No current fixture does — `tools/build-po-import-fixture.ps1` writes
`OPEN QTY` as a numeric cell by design, and `tools/smoke-import-template.ps1` §6 only proves
the happy path parses clean.

## Related, do not conflate

- `GetString`'s handling of numeric identifier cells has its own logged defect with a very
  different profile (silent, data-corrupting) — see
  `defect-po-import-numeric-cell-leading-zeros.md`.
- `GetDate`'s `TryParseExact` format list (`PoImportReader.cs:339`) has the same strict-by-design
  posture and the same reporting shape ("Invalid or missing date" conflates unparseable with
  absent), but its message at least names the format rather than the value. Worth folding into
  fix 1 if that route is taken.
