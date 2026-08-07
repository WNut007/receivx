# Defect — PUT /api/pulls/{id} reports "LockHourCap is immutable" for a closed pull

**Status:** open, not fixed. Logged 2026-08-07 while verifying the PO-overflow-on-variance
work (`brief-po-overflow-on-variance.md`). **Deliberately out of scope for that change** —
it lives in the pull-admin path and has nothing to do with receipt allocation.

**Severity:** low-moderate. The HTTP status is correct (409 either way); the *reason* the
caller is given is wrong, which sends them to fix the wrong thing.

---

## Symptom

`smoke-phase-4e.ps1` step (10) — "PUT on closed pull (PL-2840) → 409 closed":

```
FAIL: Title missing 'closed pull'. Got:
{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.10",
 "title":"LockHourCap is immutable after pull creation.","status":409}
```

The pull *is* closed and the edit *is* correctly refused. But the operator is told the
request tripped an immutable flag, so the obvious next move — resend with a different
`lockHourCap` — cannot succeed, and the actual blocker (reopen the pull first, §7.5) is
never surfaced.

## Mechanism

Two independent causes compose. Both are needed to produce the symptom.

**1. Check ordering.** `PullAdminService.cs:101-116` runs the two immutability echoes
before the closed-pull gate:

```csharp
if (req.LockPoByPull != pull.LockPoByPull)      // line 102 — §3.5 echo
    throw new BusinessException("LockPoByPull is immutable after pull creation.");

if (req.LockHourCap != pull.LockHourCap)        // line 109 — v2.1 Phase 6 echo
    throw new BusinessException("LockHourCap is immutable after pull creation.");

if (string.Equals(pull.Status, "closed", ...))  // line 114 — §7.12 read-only gate
    throw new BusinessException("Cannot edit a closed pull. Reopen it first ...");
```

A closed pull is read-only *whatever* the payload says, so §7.12 is the more fundamental
refusal and arguably belongs first. As written, any payload mismatch masks it.

**2. A defaulting bool on an echo-required field.** `PullUpdateRequest.LockHourCap`
(`PullDtos.cs:244`) is declared `= true`. A client that omits the field therefore does not
say "unchanged" — it silently asserts *locked*.

Before `db/048` that was harmless: the Phase 6.1 backfill had set every existing pull to
`LockHourCap = 1`, so the default matched almost every row. `db/048` made **unlocked** the
default, so rows created since (and the re-seeded fixtures — `PL-2840` now carries
`LockHourCap = 0`) mismatch the DTO default, and every field-omitting PUT trips line 109.

`smoke-phase-4e` step (10) sends exactly such a payload:

```powershell
PutPull $PL_2840 @{ pullDate='2026-05-31'; lockPoByPull=$false }   # lockHourCap omitted → binds true
```

`LockPoByPull` does not have this problem: it is declared without an initializer, so it
defaults to `false`, which happens to match `PL-2840`. The asymmetry between the two
adjacent flags is itself worth resolving.

## Blast radius beyond the smoke

Any API client that PUTs a partial pull body hits this. The field is an echo-required
flag, so "omit what you are not changing" is the natural client behaviour and it is
precisely what breaks. The failure is loud (409, no data written), not silent.

## Fix sketch — not applied

Three candidates, in rough order of preference:

1. **Move the §7.12 closed gate above both echo checks.** Smallest change; makes the most
   fundamental refusal win. Note this changes which message closed-pull callers see, so
   `smoke-phase-4e` step (10) starts passing and any test asserting the current ordering
   must be checked.
2. **Make `LockHourCap` nullable (`bool?`)** with `null` meaning "unchanged", matching what
   partial-update clients actually intend. Larger surface: DTO, service, UI payloads.
3. **Drop the `= true` initializer** so it defaults `false` like `LockPoByPull`. Cheapest,
   but only moves which pulls mismatch rather than removing the trap.

Whichever is chosen, `smoke-phase-4e` step (10) is the regression guard and should assert
the message, not just the 409.

## Related, do not conflate

- `smoke-hourcap-6.5` test 10 asserts `PL-2900`/`PL-2901` carry `LockHourCap = 1` as a
  property of the `db/017` backfill. `tools/seed-receive-fixtures.ps1` deliberately does
  **not** poke that flag (see its §4b comment) — writing a 1 onto rows the backfill never
  touched would manufacture the evidence the test is checking for. That assertion needs a
  decision of its own after `db/048`.
- The other four `smoke-phase-4x` failures are unrelated to this defect: 4a and 4c are
  stale assertions against the rev-11 over-receipt change (`409` → `400
  OVER_RECEIPT_NOT_ACCEPTED`), 4b needs `PL-2847` hour-07 headroom that `db/038`'s backfill
  legitimately consumes, and 4d needs `PL-2846`, which no seed has restored since `db/035`.
