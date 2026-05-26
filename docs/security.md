# Security model

Last updated: Phase 11.1 (config UI storage groundwork).

Scope: encryption-at-rest for admin-edited settings, key-ring custody,
and the bootstrap exclusions that keep the system bootable when the
encryption layer can't initialize.

---

## 1. Data Protection key ring

Receivx uses the standard ASP.NET Core Data Protection API to encrypt
`dbo.AppSettings.EncryptedValue` (the column that stores secrets edited
via the Phase 11 config UI, e.g. SMTP password, ERP connection string,
export signing key).

### Layout

| Item | Value |
|---|---|
| Application name | `Receivx` |
| Default key directory | `.dp-keys/` under `ContentRootPath` |
| Override | `DataProtection:KeyDirectory` (env var or appsettings) |
| Default key lifetime | 90 days (auto-rotated by the framework) |
| Purpose string | `AppSettings.v1` |
| .gitignore | `.dp-keys/`, `src/ReceivingOps.Web/.dp-keys/` |

The framework writes one XML file per key (`key-{guid}.xml`). New keys
generate automatically as old ones approach expiry. Old keys remain in
the ring so already-encrypted data still decrypts.

### Custody rules

- **NEVER commit `.dp-keys/`.** A leaked key compromises every secret
  ever written to `EncryptedValue`. The .gitignore is the first line of
  defense; back it up with a pre-commit hook in any deployment that
  generates production keys.
- **The key ring and the database are joined at the hip.** Migrating
  the DB without migrating `.dp-keys/` produces unrecoverable secrets:
  a `CryptographicException` on every read. Always back up both
  together. The deployment runbook (`docs/deployment.md §X`) lists this
  as a blocker.
- **Restoring a backup**: copy `.dp-keys/` first, then restore the DB.
  Order matters because the startup health check probes a known
  encrypted value; if it fails, the app logs `Critical` and continues
  (it does not crash so the UI can show a re-enter-secrets prompt).
- **Key rotation**: handled automatically by the framework on the
  90-day lifetime. Manual rotation (e.g. after a suspected leak) =
  delete the old key file from `.dp-keys/`, restart, and re-save every
  secret via the config UI. Old `EncryptedValue` rows become
  undecryptable and are surfaced as missing in the admin diagnostic
  panel.

---

## 2. Bootstrap exclusions

Some config values can't be stored in `dbo.AppSettings` because doing
so would create a chicken-and-egg problem at startup. These keys
remain in `appsettings.json` / `user-secrets` / environment variables
permanently:

| Key | Reason |
|---|---|
| `ConnectionStrings:Default` | Needed to open the DB that holds AppSettings |
| `DataProtection:KeyDirectory` | Needed to decrypt anything from AppSettings |
| `ASPNETCORE_ENVIRONMENT` | Process-level env, selects which appsettings.*.json loads |

The AppSettings seeder (Phase 11.1) and the config UI (Phase 11.2)
both refuse to write these keys. The known-secrets allowlist in
`AppSettingsService` is the enforcement point.

---

## 3. Audit trail

Every config write produces a row in `dbo.AuditLog`:

- `ActionType` = `config-set` or `config-delete`
- `EntityType` = `AppSettings`
- `EntityId` = the setting key (e.g. `Smtp:Password`)
- `Message`:
  - Non-secret: `Set Smtp:Host = 'smtp.gmail.com'` (value included)
  - Secret:    `Set Smtp:Password (secret value — not logged)` (value omitted)
  - Delete:    `Deleted Smtp:Host (prior: 'smtp.old.host')` or
               `Deleted Smtp:Password (prior: [secret])`

`PreviousValueHash` (SHA-256 of the prior stored bytes, hex-encoded) is
written to the AppSettings row for tamper-evident audit chaining
without exposing the prior plaintext.

---

## 4. Threat model summary

| Threat | Mitigation |
|---|---|
| Casual DB dump leaks secrets | EncryptedValue is unintelligible without `.dp-keys/` |
| `.dp-keys/` checked into git | gitignored; pre-commit hook recommended |
| Backup restore misses keys | Startup health check logs Critical; UI prompts re-enter |
| Curious admin reads UI | Secrets always render as `***` until "Change" + re-enter |
| Audit log exposure | Audit messages never contain secret plaintext |
| Compromised DB connection | Connection string lives in user-secrets / vault, never in DB |
