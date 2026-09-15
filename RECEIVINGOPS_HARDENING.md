# ReceivingOps — Hardening Log

Standing security/operational risks found during other work, captured here
rather than fixed inline. Each entry records what was found, how it surfaced,
and the recommended fix. Entries were originally findings only; where one has
since been acted on, the entry says so under **Control** and names the code and
the test that hold it. An entry with no **Control** heading has not been acted
on.

Newest first.

---

## 2026-09-15 — A machine environment variable outranks user-secrets and redirects a Development run

**Severity:** High — a routine `dotnet run` in the dev repo drives a database
that is not the dev database.

**What was found**

The dev machine carries a **User-level environment variable named
`ConnectionStrings__Default`, belonging to a different application** installed
on the same machine. It cannot simply be deleted; that other application needs
it.

Per this project's documented precedence chain — env vars > DB > user-secrets >
appsettings.json (`docs/configuration.md`) — that variable **outranks the
user-secret**, which is where every developer here believes the dev connection
string lives and is the only place they think to look. Nothing in the repo
masked it: before this change, `Properties/launchSettings.json` set only
`ASPNETCORE_ENVIRONMENT` in its three profiles and no profile pinned a
connection string, so the machine variable was the effective value for a plain
`dotnet run`.

**Why it matters**

This is the **same class of hazard as the 2026-07-16 user-secrets entry below**
— a Development run silently operating against a database that is not the dev
database — arriving through a different configuration provider. The earlier
entry was found by inspecting user-secrets. Anyone repeating that inspection
after this variable appeared would have found the user-secret correct and
concluded the machine was safe, because the provider that actually wins is not
the one being inspected.

**Control** (unlike the entries below, this one has been acted on)

The local database is pinned in the three places that between them cover every
way the app starts, plus a backstop for the case the first two miss:

- `Properties/launchSettings.json` — all three Development profiles. Covers F5
  and `dotnet run` with a profile. Integrated auth only; the file is tracked in
  git and must never carry a credential.
- `tools/run-smokes.ps1` — process-scoped `$env:` pin, set before the first
  child process is spawned. Scripted runs never read `launchSettings.json`, so
  the pin is repeated there rather than inherited. Neither User nor Machine
  scope is written.
- `src/ReceivingOps.Web/Data/DevDatabaseGuard.cs` — invoked from `Program.cs`
  ahead of any service registration (`AddHangfire` reads the connection string
  directly, so that is the deadline). Refuses to start when the server is not
  this machine or the database is not the expected one, and **names the
  configuration provider that supplied the value**, which is the fact that makes
  this failure mode legible rather than baffling. Development-only.

Held by `tools/smoke-dev-db-guard.ps1` (in the default battery). Its case 4 is
behavioural: it starts the app in a child process with a fake remote value in
the environment and `--no-launch-profile`, so only the guard stands between the
app and the wrong database, and asserts both a non-zero exit and the guard's own
message — a non-zero exit alone would also be produced by an ordinary
connection timeout, which is a different failure.

**Residual risk**

The guard recognises "this machine" by hostname and the usual local aliases. A
developer whose dev database legitimately lives on another host would be refused
and would need the guard adjusted. It is Development-only by design; nothing
here constrains a production deployment, which is supposed to point elsewhere.

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
