# Defect — a numeric-typed `PULL SHEET ID / PRS NO` cell silently loses its leading zeros

**Status:** open, not fixed. Logged 2026-08-18 while building the Imports download-template
action (`brief-import-template.md`). **Deliberately out of scope for that change** — the brief
permitted exactly one touch to `PoImportReader` (widening `RequiredHeaders` visibility) and
nothing in the import pipeline.

**Severity:** high if it fires, and it fires silently. No exception, no validation error, no
audit anomaly — the import reports `succeeded` and the resulting POs are simply invisible to
the receive path they were imported for.

**Why it has never fired:** the production ERP export happens to emit that column as text.
That is luck, not a guarantee. One Excel round-trip or one ERP report change flips it.

---

## Symptom (predicted — not yet observed in production)

An import succeeds. `PoImportLog` shows `PosInserted` / `LinesInserted` as expected and the
audit trail is clean. Later, an operator receiving against the matching pull is told there is
no capacity, or FIFO quietly draws on a different PO, depending on the pull's `LockPoByPull`
setting. Nothing anywhere names the import as the cause.

In the DB the tell is a `dbo.PurchaseOrders` row whose `PoNumber` and `PullExternalRef` read
`28048` where the pull reads `0000028048`.

## Mechanism

Three links, each individually reasonable.

**1. `GetString` stringifies numeric cells after Excel has already dropped the zeros.**
`PoImportReader.cs:278`:

```csharp
CellType.Numeric => NullIfBlank(cell.NumericCellValue.ToString(CultureInfo.InvariantCulture)),
```

The padding is gone before this line runs — a numeric cell physically stores the double
`28048`; `0000028048` was never in the file. The InvariantCulture guard (correct, and there for
a good reason) protects against a German Excel smuggling `1.234,5` into an identifier; it does
nothing about zero-padding, because by then there is nothing to protect.

**2. `PoNumber` is that string, unvalidated.** `MapRow` (`PoImportReader.cs:186`) takes it as
`PoNumber`; `ValidateRow` (`:229`) only checks non-blank. There is no shape, length, or
zero-padding assertion anywhere in the reader, the service, or the Stage 2 job.

**3. The receive path matches `PullExternalRef` by string equality.** `PoImportJob.cs:334`
denormalizes the parsed value:

```csharp
PullExternalRef = firstRow.PoNumber,   // db/033 — Q1=B denormalized
```

and `ReceiptService.cs:395` resolves the §7.15 lock-by-pull FIFO scope with:

```csharp
const string pullMatch = "(po.PullId = @PullId OR po.PullExternalRef = @PullNumberStr)";
```

`@PullNumberStr` is the pull's `PullNumber` — `0000028048`. `'28048' = '0000028048'` is false,
so in lock-by-pull mode the imported PO is not a FIFO candidate at all. Imported POs carry
`PullId = NULL` by design, so `PullExternalRef` is the *only* link; when it mismatches there is
no fallback. The entire A1 mechanism (v3.3) rests on the two strings being byte-identical, and
nothing validates that they are.

## Blast radius

- **Receive, lock-by-pull mode (`LockPoByPull = true`, the strict-by-default setting):** the
  imported PO is excluded from the FIFO walk. The operator sees an out-of-capacity refusal
  with no indication that a PO for exactly this pull exists.
- **Receive, warehouse-wide mode:** the PO *is* a candidate, so the receive may succeed —
  against a PO whose number no longer matches its pull sheet. Reconciliation breaks later and
  further from the cause.
- **Duplicate detection.** `PoNumber` is globally `UNIQUE` (db/010) and Stage 2 re-checks the
  range under `UPDLOCK + ROWLOCK`. A pull sheet `0000028048` collapsing to `28048` will collide
  with a genuine `28048` from another sheet, or fail to collide with its own re-import,
  depending on which typing each file happened to carry. Both outcomes are wrong and neither
  is reported as a formatting problem.
- **Every other identifier read through `GetString`** has the same exposure at lower stakes:
  `SKU` (13 rows of the sample export start with a zero), `KANBAN NO` (2,909 zero-padded rows),
  `ASN NO`, `PALLET ID`, `VMI PALLET ID`.
- **Related, same line:** identifiers at or above 10^16 stringify through `double`, so a
  17-digit numeric id round-trips as `12345678901234568` — off by one in the last place. Not
  observed in the sample export (longest numeric identifier is 10 digits) but it is the same
  root cause: the value passes through a `double` before anyone looks at it.

## What the export actually looks like today

Measured on `Stock Ship 16-Aug-2026.xls`, 4,401 rows, sheet `xxwdt0061_stock_shipped`:

| Column | Cell type | Zero-padded rows |
|---|---|---|
| `PULL SHEET ID / PRS NO` | String, 4,401/4,401 | 2,909 |
| `KANBAN NO` | String, 3,909 non-blank | 2,909 |
| `SKU` | String, 4,401/4,401 | 13 |

Every at-risk column is currently text. The defect is entirely latent — which is precisely why
it deserves a guard rather than a note.

## Fix sketch — not applied

1. **Validate the shape at parse time.** Cheapest real protection: in `ValidateRow`, reject a
   `PoNumber` sourced from a numeric cell (or, more simply, one that does not match the
   expected identifier shape) with a message naming the *format*, not the value. Turns a silent
   mismatch into a rejected file at Stage 1, which is where the operator can still fix it by
   re-exporting.
2. **Read the raw cell text instead of the typed value** for identifier columns —
   `DataFormatter.FormatCellValue` returns what Excel displays, which preserves padding when a
   Text format is applied and still gives a sane string otherwise. Wider change: it alters the
   string every numeric-typed cell produces, so every mapped column needs re-checking.
3. **Assert the link rather than the source.** At Stage 2, warn (or fail) when
   `PullExternalRef` matches no `Pulls.PullNumber` in the target warehouse. Catches this defect
   and any other cause of a broken link, but only after the rows are written, and legitimately
   unlinked imports exist — so it cannot simply be a hard failure.

Whichever is chosen, the regression guard is a fixture workbook with `PULL SHEET ID / PRS NO`
written as a **numeric** cell. No current fixture does that:
`tools/build-po-import-fixture.ps1` writes it as a string, and
`tools/smoke-import-template.ps1` §7 asserts the generated template keeps it Text — both
exercise the safe path only.

## Related, do not conflate

- The `Text` number formats applied by `PoImportTemplateBuilder` reduce the chance an operator
  *creates* a numeric-typed cell by editing the template. They do nothing about an ERP export
  that arrives numeric-typed, which is the case that matters here.
- `GetInt`'s format handling has its own logged defect — see
  `defect-po-import-qty-format-misattribution.md`. Same helper family, unrelated mechanism.
