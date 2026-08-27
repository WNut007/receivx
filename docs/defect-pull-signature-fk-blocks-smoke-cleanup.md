# Defect — `FK_PullSig_Pull` has no cascade, so every smoke cleanup that deletes a closed pull silently fails

**Status:** open, not fixed. Logged 2026-08-20 while auditing smoke fixture hygiene after the
drawer duplicate-row work.

**Severity:** medium, and it has been firing continuously since db/042 shipped. Nothing is
corrupted — the DELETE is refused, not half-applied — but the fixtures accumulate, the
cleanup reports success, and the growth surfaces later as unrelated-looking failures.

**Measured 2026-08-20 on the dev database:** 148 stranded fixture pulls — 130 `PL-VQ-%`
(dating back to 2026-08-06) and 18 `PL-DOR-%` (back to 2026-07-16) — carrying 226 items and
244 windows. Both families have cleanup code whose pull-level DELETE has never worked. The
receipt DELETE that runs before it does work, so the receipts are gone and the windows that
recorded them are not.

---

## Mechanism

Three links, each individually reasonable.

**1. `db/042` added `dbo.PullSignatures` with a non-cascading FK.**

```
FK_PullItems_Pull    -> PullItems        ON DELETE CASCADE
FK_PullSig_Pull      -> PullSignatures   ON DELETE NO_ACTION     <-- this one
FK_PO_Pull           -> PurchaseOrders   ON DELETE NO_ACTION
```

`FK_PullItems_Pull` cascades, which is why smoke cleanups written before db/042 could delete
a pull and have its items and windows go with it. `FK_PullSig_Pull` does not, so any pull
that was **closed with a signature** cannot be deleted until its signature row is removed
first. No cleanup script does that, because none of them existed when signatures did not.

**2. The cleanups delete by `LIKE` pattern in one statement.**

```sql
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-VQ-%';
```

A set-based DELETE is all-or-nothing. One signed pull in the range refuses the statement and
takes every other row in it down too. Of the 130 stranded `PL-VQ` pulls only **26** are
signed; the other 104 are collateral, deletable in principle and never deleted in practice.
All 18 `PL-DOR` pulls are signed, so that family never had a chance.

**3. The failure is swallowed.**

Every cleanup follows the same shape:

```powershell
sqlcmd ... -Q $sql 2>&1 | Out-Null
```

`2>&1 | Out-Null` sends the SQL error to the same place as the success output. The smoke
prints its cleanup step, continues, and reports ALL PASS. Nothing anywhere says the delete
was refused.

## Why it looks like it works

The cleanup runs on entry as well as exit, so a developer watching one run sees the smoke
pass and the pull count stay flat within that run. The accumulation is only visible by
querying for the fixture prefix across dates, which nothing does.

## Consequences

- **Fixture accumulation.** 148 pulls and their items, windows and receipts, growing by five
  or so per battery run.
- **Orphaned `ReceivedQty` caches.** The receipt DELETE that runs before the pull DELETE has
  no FK blocker, so the receipts DO go. The windows they filled do not. Measured before the
  purge: 218 stranded windows holding `ReceivedQty > 0` totalling 67,740 units, with no
  ledger rows behind them at all. This is the drain `db/047_STATUS.md` describes, left in
  place and made permanent.
- **A cleanup that cannot be trusted.** The next person to add a smoke will copy this shape,
  because it is what every existing smoke does.

## What a fix would look like

Three parts, in order of how much they buy:

1. **Delete the signature rows first**, in the cleanup, before the pull:
   ```sql
   DELETE s FROM dbo.PullSignatures s
   INNER JOIN dbo.Pulls p ON p.Id = s.PullId
   WHERE p.PullNumber LIKE '<prefix>%';
   ```
   This is the smallest change and fixes every existing cleanup.

2. **Stop swallowing the error.** `2>&1 | Out-Null` is the reason this survived. A cleanup
   that fails should say so, even if the smoke's assertions passed.

3. **Consider `ON DELETE CASCADE` on `FK_PullSig_Pull`** to match `FK_PullItems_Pull`. This
   is a schema change and needs its own thought: a signature is an audit artefact, and
   cascading it away with the pull may be exactly what is NOT wanted in production. The
   safer reading is that production should never delete a signed pull at all, and the smoke
   cleanups are the only legitimate caller — which argues for fix 1, not fix 3.

### `FK_PO_Pull` is the same trap, and is clean only by luck

`FK_PO_Pull` (`dbo.PurchaseOrders.PullId` -> `dbo.Pulls`) is also `NO_ACTION`. Nothing is
stranded by it today, and that is not because anything prevents it — it is because no smoke
has yet happened to close a pull that has a PO attached to it. The moment one does, the same
`DELETE ... WHERE PullNumber LIKE` is refused the same way, silently, for the same reason.

Any cleanup written against fix 1 above should unlink or delete the pull's POs as well as
its signatures, whether or not that smoke currently creates one. A cleanup that works only
because of what its smoke happens not to do is a cleanup waiting to stop working.

## Do not "fix" this by widening the LIKE

Deleting `PL-%` or similar would reach seeded demo pulls (`PL-2847`, `PL-2844`, `PL-2848`)
that other smokes assert against. The prefixes are narrow on purpose.

## Related

- `docs/smoke-conventions.md` — the fixture-hygiene rule this violates.
- `db/047_STATUS.md` § "Capacity drain — the suite has a finite number of runs".
- `tools/clear-variance-dev-fixtures.ps1` — the manual sweeper, which does handle this.
