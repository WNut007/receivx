# ReceivingOps — Hardening Log

Standing security/operational risks found during other work, captured here
rather than fixed inline. Each entry records what was found, how it surfaced,
and the recommended fix. **Nothing in this file has been acted on** — these
are findings, not changes.

Newest first.

---

## 2026-07-16 — Dev user-secrets `ConnectionStrings:Default` points at the production host

**Severity:** High — a routine `dotnet run` in the dev repo drives production.

**What was found**

`dotnet user-secrets list --project src/ReceivingOps.Web` returns:

```
ConnectionStrings:Default = Server=103.13.229.21;Database=ReceivingOps;User Id=nut;Password=<Pocket placeholder>;...
```

`103.13.229.21` is the remote host CLAUDE.md documents as the ERP source
(`ErpDb:ConnectionString` → `Database=CW` on the same host) and is almost
certainly the database behind the live site `receivingops.webgeplus.com`.
CLAUDE.md states the dev SQL Server is **`LAPTOP-CSB3KO3E`** and that the
connection string is "local dev only".

Nothing masks the secret. `Properties/launchSettings.json` sets only
`ASPNETCORE_ENVIRONMENT=Development` across all three profiles — there is no
`ConnectionStrings__Default` env override in any of them. Per the documented
precedence chain (env vars > DB > user-secrets > appsettings.json), the
user-secret is therefore the effective value.

**How it surfaced**

While preparing to restart the dev server to run a behavioral smoke for the
PO-import skip-duplicates change. The dev server (PID 36992,
`C:\dev\receivx\src\ReceivingOps.Web\bin\Debug\net8.0\ReceivingOps.Web.exe`,
started via `dotnet run --project src/ReceivingOps.Web`, listening on :5213)
was inspected under a pre-restart safety gate. The gate required proving the
process was not running against the production DB — it was.

**Why it matters (the concrete near-miss)**

The smoke drives `POST /api/imports/po/upload` + `/confirm` against the app on
:5213, then asserts via `sqlcmd -S LAPTOP-CSB3KO3E`. With the app on
`103.13.229.21`, that run would have:

1. inserted `P127TEST-*` PurchaseOrders + PoImportLog rows into **production**;
2. asserted against the **local** DB and failed confusingly;
3. "cleaned up" the local DB, leaving the production test rows behind.

The smoke was never run — the gate stopped it. Migration `db/046` was applied
only to `LAPTOP-CSB3KO3E`; no connection to `103.13.229.21` was ever made.

This footgun is not specific to smokes: any `dotnet run` in this repo, any
Hangfire recurring job that fires on startup (ERP sync, exports), and any
destructive dev migration would hit production. Note `db/035_wipe_for_phase_14.sql`
is a destructive wipe guarded only by an `@@SERVERNAME` check — that guard is
the single thing standing between a dev-intent script and production data.

**Recommended fix**

- Point dev user-secrets at the local server:
  `dotnet user-secrets set "ConnectionStrings:Default" "Server=LAPTOP-CSB3KO3E;Database=ReceivingOps;Integrated Security=true;..."`
- Never carry a production connection string in dev user-secrets. Production
  config belongs in the deployment environment (env vars / vault / Managed
  Identity), which CLAUDE.md already states: *"Production must use Managed
  Identity or a vault — never a hardcoded SQL login."*
- Consider a startup guard that refuses to boot in `Development` against a
  non-local `Data Source`, so this cannot silently recur.

**Status:** Documented only. Secret not modified.

---

## 2026-07-16 — Production SQL login `nut` may still use the "Pocket" placeholder password, which is committed to git

**Severity:** High — a placeholder credential appears to be live on production
and is readable in every clone of this repository.

**What was found**

The connection string above authenticates the prod host as
`User Id=nut` with the **"Pocket" placeholder password**. This is the exact
credential the Phase 10 deploy-blocker checklist in `docs/deployment.md` says
must be rotated before deployment ("rotate the 'Pocket' placeholder password").
Its presence in a working connection string suggests the rotation never
happened and the placeholder is the live production credential.

The password string is **committed to the repository** and present in history:

| Location | Tracked? |
|---|---|
| `BUILD_PROMPT.md` | tracked (committed) |
| `BUILD_PROMPT.v1.md` | tracked (committed) |
| `docs/deployment.md` | tracked (committed) |
| `secrets-backup.txt` | untracked, present in working tree |

`git log -S` finds it in `4dccdd3` (initial commit), `6bb0516`, and `a16a79e`.
Because it is in history from the initial commit, **it exists in every clone
and every fork; deleting it from the working tree does not remove it.**

The same host also appears in `CLAUDE.md`, `docs/phase-10-erp-integration.md`,
and `tools/smoke-phase-10-1-erp-connection.ps1`.

**How it surfaced**

Same inspection as the entry above.

**Recommended fix (in order)**

1. **Rotate the `nut` login's password on the production server.** This is the
   only step that actually closes the exposure — the credential must be assumed
   compromised, since it has been in git since the initial commit.
2. Move the new credential out of the repo entirely: env vars / vault / Managed
   Identity per CLAUDE.md. Do not re-commit it anywhere.
3. Lock the ERP user to read-only with explicit DENY and firewall/VPN
   `103.13.229.21:1433` — both are already open items on the Phase 10
   deploy-blocker checklist in `docs/deployment.md`.
4. Scrub the placeholder from `BUILD_PROMPT.md`, `BUILD_PROMPT.v1.md`, and
   `docs/deployment.md`; replace with an obvious non-credential token such as
   `<set-in-deployment-env>`. History rewriting (filter-repo/BFG) is a separate
   decision — rotation (step 1) makes the historical value worthless and is the
   priority.
5. Delete `secrets-backup.txt` from the working tree and confirm it is
   gitignored so it cannot be committed.

**Status:** Flagged only. **No rotation performed, no production system
touched, no files modified.**
