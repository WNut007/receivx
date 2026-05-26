# Configuration

Last updated: v3.1.1 (Phase 11.2 audit gap closure).

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
| Change the SMTP password permanently | `/Config` → Email tab → Password row → "Change" |
| Emergency-override a value for one boot | `Set` an env var, e.g. `Smtp__Host=...`, then restart |
| See what's stored | `/Config` → admin section → 4 tabs; secrets masked |
| Audit who changed what | `SELECT * FROM dbo.AuditLog WHERE EntityType='AppSettings' ORDER BY OccurredAt DESC` |
| Reset to defaults | `/Config` → tab → "Reset section to defaults"; restart re-seeds from appsettings.json |
| Confirm decryption is working | App startup logs include `AppSettings decryption verified` |
| Regenerate the export signing key | `/Config` → Exports tab → "Regenerate" (invalidates pending download URLs after restart) |
| Test SMTP / ERP without restarting | `/Config` → Email tab → "Send test"; ERP tab → "Test connection" (uses LIVE config including unsaved edits if already POST-ed) |

---

## 7. Phase 11.2 — admin UI

**Path:** `/Config` (existing user-settings page); admin-only section
appears below Theme/Nav, hidden for operator + supervisor.

**Tabs (pill-style, matching Phase 8.4 `/Exports`):**

| Tab | Section | Notable controls |
|---|---|---|
| Email | `Smtp` | Host, Port, UseStartTls, Username, FromAddress, FromName, **Password** (masked + "Change") |
| ERP Connection | `ErpDb` | **Connection string** (masked + "Change", multi-line textarea) |
| Sync Schedule | `ErpSync` | Enabled toggle, CronExpression, TimeoutSeconds, BackfillDays, **DefaultWarehouseId** (`<select>` from `/api/warehouses` — existing endpoint, accessible to all authenticated users; admin-specific surface not needed since the dropdown only reads warehouse list rows that are already visible elsewhere in the app) |
| Exports | `Exports` | BaseUrl, **Signing key** (masked + "Regenerate" only — no operator-entered values) |

**Diagnostics tab:** intentionally NOT shipped. Earlier spec drafts
called for a separate read-only Diagnostics tab/footer. The editor's
4 tabs already render every effective config value (with secrets
masked), so a parallel read-only view is redundant. To see the same
information without edit affordances, an admin opens the relevant tab
and ignores the Save buttons.

**Supervisor + operator access:** `/Config` itself is reachable by any
authenticated user (Account / Theme / Nav prefs live here). The new
Configuration section is hidden via the `data-admin-only` attribute
toggled by `config.js` based on the `/api/auth/me` role response.
Hiding is convenience only — every endpoint under `/api/admin/config/`
returns 403 to operator + supervisor regardless.

**Endpoints (all `[Authorize(Roles = "admin")]`):**

```
GET    /api/admin/config/sections                    -> tab metadata + key list + isSecret per key
GET    /api/admin/config/sections/{name}             -> values for one section; secrets render as "***"
PUT    /api/admin/config/sections/{name}             -> save non-secret values; rejects secret keys (400)
POST   /api/admin/config/sections/{name}/secret      -> save ONE secret; rejects non-secret keys (400)
DELETE /api/admin/config/sections/{name}             -> reset section to appsettings.json defaults
POST   /api/admin/config/exports/regenerate-signing-key
POST   /api/admin/config/test/smtp                   -> live send via IEmailService (v3.1.1)
POST   /api/admin/config/test/erp                    -> live SqlConnection probe → SELECT @@VERSION
```

The existing `POST /api/admin/email-test` (Phase 8.4 diagnostic) is
unchanged and still works. `POST /api/admin/config/test/smtp` (added
v3.1.1) is a parallel wrapper on the Config namespace so a future
hardening pass can deprecate the older endpoint without breaking the
editor.

There is **no** `GET /api/admin/erp/connection-test` endpoint — Phase
10.1's connectivity check was a sqlcmd-based smoke, not an HTTP
endpoint. `POST /api/admin/config/test/erp` (added in Phase 11.2) is
the only HTTP probe for ERP DB connectivity.

**Validation rules (server-side; UI surfaces field-specific errors):**

| Key | Rule |
|---|---|
| `Smtp:Port` | int 1–65535 |
| `Smtp:UseStartTls` | bool |
| `Smtp:FromAddress` | `MailAddress.TryCreate` |
| `ErpDb:ConnectionString` | must contain `Server=` AND `Database=` (v3.1.1) |
| `ErpSync:Enabled` | bool |
| `ErpSync:CronExpression` | `NCrontab.CrontabSchedule.TryParse` (5-field) |
| `ErpSync:TimeoutSeconds` | int 60–3600 |
| `ErpSync:BackfillDays` | int 1–365 |
| `ErpSync:DefaultWarehouseId` | Guid + must exist in `dbo.Warehouses` |
| `Exports:BaseUrl` | `Uri.TryCreate` absolute http(s); **Production** environment requires `https` (v3.1.1) |
| `Exports:SigningKey` | min 32 chars when set via POST `.../secret` (Regenerate always writes 44; v3.1.1) |
| (other strings) | accepted as-is |

**Save → restart workflow:**

Every successful write returns `{ requiresRestart: true, changedKeys: [...] }`
and the UI reveals a sticky **restart banner**:

> ⚠ **Restart required** — Configuration saved. Restart the application
> to apply changes.

The banner persists across tab switches (session-scoped) until the
operator clicks Dismiss or reloads the page. `IOptions<T>` resolves
once at process start; without restart, in-flight code paths still
use the cached old value. The PHP-style "live reload on file change"
was rejected in favor of restart-required because the encryption layer
+ Hangfire worker caching make live reload high-risk for low-reward.
