# Smoke conventions

Rules the smoke battery is written to. Both of these were learned from smokes that were
green, or that reported success, while proving nothing — so they are stated as rules rather
than as suggestions.

`tools/run-smokes.ps1` is the battery. A smoke that is not in it is a smoke nobody runs.

---

## 1. When a check's subject is source text, prove it fails

A test that greps source is testing a string, not a behaviour. The string can drift from the
thing it stands for, and when it does the test keeps passing. Three instances in two
sessions, each looking different from the last:

| What was asserted | Why it never failed |
|---|---|
| `$dto -match "public string\? TrialId"` over the whole file | Sibling DTOs in the same file carry the same field names, so deleting it from `PullItemCreateRequest` still matched |
| The blank-vendor 409 message, end-to-end only | A running dev server answers from the already-built DLL, so a source-only edit passed until the next restart |
| `$css -match '\.copy-row-btn:focus'` | `:focus-visible` starts with `:focus`, so removing the `:focus` selector still matched |

None of these would ever have gone red on its own. They read as coverage indefinitely.

**The rule, in two halves:**

1. **Prove the assertion fails when its subject changes.** Make the change — delete the
   field, narrow the guard, remove the selector — run the smoke, and confirm it goes red.
   Restore from a file copy, never by reversing the edit in place.
2. **Prove the detector watches the same signal the battery does.** The battery keys on
   **exit code**. A harness that greps stdout for `FAIL:` will miss a smoke that dies on an
   unhandled exception, and will report NOT CAUGHT for a mutation the smoke actually caught.
   That happened too.

Scope the assertion as narrowly as the claim. `[regex]::Match` the class body, not the file.
Assert the INSERT names the column, not only that the DTO declares it — a DTO carrying a
field the INSERT drops is a silent loss wearing a disguise.

Where a behavioural check is possible, prefer it, and keep the source-level one as well when
the behavioural path can be answered by stale state (a built DLL, a cached asset, a warm
Hangfire worker).

### Restoring after a mutation

Copy the file aside first and copy it back. Do **not** restore by reversing the edit:

```python
s.replace(old, "")          # apply: deletes the line
s.replace("", old)          # restore: PREPENDS it to the top of the file
```

Replacing an empty string inserts at position 0. That silently moved a `:focus` selector to
line 1 of `dashboard.css`, where it was still found by a `grep -c` integrity check — and the
corruption then survived into a later backup. The count-based check was not an integrity
check.

---

## 2. A smoke leaves the database as it found it

A smoke that strands its fixture breaks the environment it runs in, and the damage surfaces
somewhere unrelated — a later count assertion, a capacity exhaustion, a duplicate-key
collision in a smoke that has nothing to do with it.

- **Namespace every fixture** with a prefix nothing else uses (`PL-VQ-`, `WIPTEST-`,
  `P127TEST-`, `PL-DUP-`) and purge that prefix on entry *and* on exit.
- **Clean up on the failure path too.** `Fail` should call the cleanup. An uncaught
  `Invoke-RestMethod` aborts the script and skips it, so any request that could legitimately
  return 4xx when the code under test regresses needs an explicit `try`/`catch` that fails
  with a message naming the cause.
- **A case that adds a row the cases below it do not expect should remove it itself.** Added
  in the case, removed in the case — not left for the final cleanup, which runs too late to
  keep the intervening assertions honest.
- **Do not swallow cleanup errors.** `2>&1 | Out-Null` is how a cleanup can fail on every run
  for months while the smoke reports ALL PASS. See
  `docs/defect-pull-signature-fk-blocks-smoke-cleanup.md`: 148 stranded pulls, two smoke
  families, cleanup code present and never once working.
- **Seed your own capacity.** The newer `smoke-variance-*` smokes create a PO per case rather
  than drawing on shared seeded capacity. Deleting a receipt does not decrement
  `PurchaseOrderLines.ReceivedQty`, so every smoke that leans on shared capacity spends a
  slice of it permanently — see `db/047_STATUS.md` § "Capacity drain".

### Things that cannot be cleaned up, and what to do instead

`dbo.Receipts` is append-only by design (§7.10) — no DELETE. A smoke that receives against a
**seeded** pull therefore cannot undo it. Seed your own pull and PO instead, so the rows it
leaves are inside your own namespace and the sweeper can reach them.

`FK_PullSig_Pull` and `FK_PO_Pull` do **not** cascade from `dbo.Pulls`. Delete signature rows
(and unlink or delete POs) before deleting the pull, or the delete is refused — and a
set-based `DELETE ... WHERE PullNumber LIKE` is all-or-nothing, so one signed pull blocks the
whole range.

---

## 3. Executing shipped code beats grepping for it

Where a pure function drives the behaviour, lift it out of the shipped file and run it in
node against fixture inputs. `smoke-variance-outstanding-queries.ps1` Q6 established the
technique; `smoke-pull-drawer-actions.ps1` follows it for the row serialiser and the
duplicate pre-fill.

This only works if the function stays free of the DOM and of page helpers, so say so in a
comment where it is defined. The regex that lifts it (`(?s)function name\(args\) \{.*?\n  \}`)
depends on the closing brace sitting at the function's own indentation — keep nested blocks
indented deeper.

If extraction fails, that is a test failure, not a reason to fall back to grepping.
