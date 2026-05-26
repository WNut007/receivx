# Configuration

Last updated: Phase 11.1 (admin-edited config storage).

Audience: anyone deploying Receivx or wondering "why does the SMTP host
keep reverting to the one in appsettings.json after I set it in user-secrets?"

---

## 1. Precedence

Every config value resolves through this chain (highest wins):

```
1.  Environment variables             ──► always win
2.  dbo.AppSettings (Phase 11.1)      ──► admin-edited via Phase 11.2 UI
3.  dotnet user-secrets               ──► dev convenience, not in prod
4.  appsettings.{Environment}.json    ──► environment overlay
5.  appsettings.json                  ──► defaults
```

`IAppSettingsService.GetAsync(key)` is the single implementation point.
Both direct service callers (admin UI, diagnostics) and the options
binding (commit 5 of Phase 11.1) go through it.

### Why env vars win

Operational override. A misbehaving production deploy needs to be able
to force a value WITHOUT a database round-trip or migration. Setting
`Smtp__Host=relay.backup.com` and restarting always works, even if the
DB row is wrong or the encryption key ring is missing.

### Why DB beats user-secrets

Admins editing values via the Phase 11.2 UI need their changes to be
authoritative immediately on restart. A leftover user-secret from
local-dev shouldn't shadow what was just saved in production.

---

## 2. Bootstrap exclusions

Three keys NEVER live in `dbo.AppSettings` — they must be readable
BEFORE any DB query or decryption can run:

| Key | Where it lives | Why |
|---|---|---|
| `ConnectionStrings:Default` | user-secrets (dev) / env var / vault (prod) | Opens the DB that stores AppSettings |
| `DataProtection:KeyDirectory` | env var (or default `.dp-keys/` under content root) | Decrypts every encrypted setting |
| `ASPNETCORE_ENVIRONMENT` | env var | Selects which `appsettings.{Env}.json` overlay applies |

`IAppSettingsService.SetAsync()` throws `InvalidOperationException` if
called with any of these keys. The Phase 11.2 UI hides them from the
editable list.

---

## 3. Known secrets

Stored as ciphertext in `dbo.AppSettings.EncryptedValue` via ASP.NET
Data Protection (purpose `AppSettings.v1`):

- `Smtp:Password`
- `ErpDb:ConnectionString`
- `Exports:SigningKey`

Section reads (`GetSectionAsync`) mask these as `"***"` for any caller —
the admin UI uses an explicit "Change" workflow with an empty-input
field, never displays the prior plaintext.

---

## 4. Reload model

**Restart-required.** No live reload. Options classes bind once at
`IOptions<T>` first resolution and stay cached for the process
lifetime. After editing a value via the Phase 11.2 UI, the operator
must restart the app for the change to take effect.

Why no live reload:
- Simpler implementation (no `IOptionsMonitor` change-tracking, no
  cache invalidation across the Hangfire workers).
- Restart is the existing operational cadence for any non-trivial
  config change (firewall, SMTP, etc.).
- Lower bug surface for the encryption layer — one decrypt at startup
  is easier to reason about than rolling decryption across the process.

Phase 11.2 UI surfaces this with a "Save and restart required" banner.

---

## 5. First-run seeding

When `dbo.AppSettings` is empty at startup, `AppSettingsSeeder` copies
every non-empty value from the four owned sections
(`Smtp`, `ErpDb`, `Exports`, `ErpSync`) into the DB. After that point,
the DB is authoritative; further changes to appsettings.json /
user-secrets are ignored (precedence rule #2 above).

To force a re-seed (e.g. after restoring a fresh DB):
```sql
DELETE FROM dbo.AppSettings;  -- triggers re-seed on next start
```
Phase 11.2 will add an admin "re-import from config files" button.

---

## 6. Operator quick reference

| I want to… | Where to look |
|---|---|
| Change the SMTP password permanently | Phase 11.2 UI → `/Config` → Email tab |
| Emergency-override a value for one boot | `Set` an env var, e.g. `Smtp__Host=...`, then restart |
| See what's stored | Phase 11.2 UI shows all rows; secrets masked |
| Audit who changed what | `SELECT * FROM dbo.AuditLog WHERE EntityType='AppSettings' ORDER BY OccurredAt DESC` |
| Reset to defaults | `DELETE FROM dbo.AppSettings; restart` (re-seeds from appsettings.json) |
| Confirm decryption is working | App startup logs include `AppSettings decryption verified` |
