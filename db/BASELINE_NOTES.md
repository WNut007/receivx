# Baseline notes — tag `prod-2026-07-30`

## What the tag is

Commit `def8f2e`, tagged `prod-2026-07-30`, records the working-tree state
that was **deployed to production on 2026-07-30** and is still live at
`receivingops.webgeplus.com` as of 2026-08-06.

It was never reviewed or tested as a unit. It is a record of what is running,
not a statement that what is running is correct. Do not read it as intentional
design.

Before this commit existed, that state lived only as uncommitted edits in one
working tree on one laptop — 35 modified tracked files plus 18 untracked ones,
including `Services/Exports/KtfExportJob.cs` (live code that git had never
seen) and three migrations (`db/040_pull_dashboard_index.sql`,
`db/041_vw_transactions_journal_ktf.sql`, `db/046_po_import_log_skipped.sql`).
A single `git clean` would have destroyed all of it.

How the deployed state was identified: six static assets fetched from the live
site hash-identical to the working tree, and the live `/Account/Login` page
renders `asp-append-version` cache-busting markers that exist **only** in the
uncommitted `Views/Account/Login.cshtml` — proving the deployed DLL itself was
built from uncommitted source, not from any committed branch.

## THE TAG IS INCOMPLETE — one file was withheld

**`secrets-backup.txt` (repo root) is NOT in this tag.**

A checkout of `prod-2026-07-30` is therefore **not** a byte-for-byte
reproduction of production, which was the tag's whole purpose. That gap is
recorded here deliberately rather than left silent.

### What the file holds

| Credential | Account | System |
| --- | --- | --- |
| `Smtp:Password` | `geplus1978@gmail.com` | Gmail app password — the live SMTP sender for all export/notification mail |
| `ErpDb:ConnectionString` | SQL login `nut` | ERP source database `CW` on `103.13.229.21` |

Both are live, working credentials in plaintext.

### Why it was withheld

Committing it would write live credentials into git history permanently. History
is not selectively erasable: the values would propagate to every clone, every
fork, every future backup of the repo, and to `origin` on the next push.
Removing them afterwards requires a history rewrite of a repo that is the only
record of production.

It was verified — `git log --all --full-history` plus a blob search plus a
filename sweep of every tree — that this file has **never** been committed in
any branch or any historical commit. Withholding it preserves that clean state
rather than creating a new exposure.

Withholding it also does not damage the reproducibility goal, because
**the file is not deployed state.** Production does not read it. Per
`deploy/deploy.ps1`, the running app gets its secrets from
`ConnectionStrings__Default` and `ErpDb__ConnectionString`, injected into
`web.config` at deploy time from `C:\Programs\ReceivingOps-config\deploy-secrets.json`
on the prod host. `secrets-backup.txt` is a convenience dump of local
`dotnet user-secrets` values on the dev laptop.

`RECEIVINGOPS_HARDENING.md` (2026-07-16) already recommended deleting this file
and gitignoring it. It is now in `.gitignore` so the next `git add -A` cannot
pick it up. It has **not** been deleted — that is the operator's call.

### Where the real values live

| Location | What |
| --- | --- |
| `C:\Programs\ReceivingOps-config\deploy-secrets.json` (prod host, ACL-locked) | authoritative production secrets; `deploy.ps1` injects from here |
| `C:\dev\receivx\secrets-backup.txt` (dev laptop, gitignored, untracked) | the withheld dev-side dump |
| `C:\dev\receivx-backup-2026-08-06-2010.zip` → `receivx/secrets-backup.txt` | full-tree backup taken before the baseline commit; **does** contain the file |

### Restoring from this tag

A checkout of `prod-2026-07-30` will build, but will **not** run correctly
without secrets supplied from the environment. Supply them the way production
does — `deploy-secrets.json` on the target host, or `dotnet user-secrets` for
local work. Do not restore the file into the repo and commit it.

## Related

- `db/probe-migrations.sql` — read-only probe for which migrations are actually
  applied on a given database. There is no migration ledger table in this
  schema; object presence is the only evidence available.
- Two duplicate-number collisions exist in `db/` (`040` and `041` are each used
  by two unrelated migrations). They are deliberately **not** renumbered — they
  may already be applied on production under their current names, and with no
  ledger there is nothing to correct against.
