# Exports — feature documentation

Last updated: v2.2 (Phase 8 close).
Audience: operators, integrators, and anyone debugging an export that
never arrived.

The export pipeline turns operator-filtered list views into emailed
XLSX files. Three list surfaces produce exports today: **Transactions**,
**Purchase Orders**, and the **Audit Log**. The underlying machinery is
identical for all three.

---

## 1. Lifecycle

```
[Operator clicks Export]
        │
        ▼
POST /api/exports/{transactions|pos|audit-log}    (202 Accepted)
        │
        │   ExportService.Enqueue*Async():
        │     1. INSERT ExportJobsLog row with Status='queued'
        │     2. Hand the request to Hangfire on queue 'exports'
        ▼
[Hangfire picks the job up]    (usually <15s)
        │
        │   *ExportJob.RunAsync():
        │     1. UPDATE ExportJobsLog SET Status='running', StartedAt=now
        │     2. Query the filtered result set (cap = MaxRows)
        │     3. Stream into ClosedXML workbook → write to exports/{prefix}-{jobId}.xlsx
        │     4. Issue HMAC-signed download URL (24h expiry)
        │     5. Send email via MailKit (SMTP STARTTLS:587)
        │     6. UPDATE ExportJobsLog SET Status='succeeded', CompletedAt=now,
        │            FileName=..., RowsExported=...
        ▼
[Operator receives email]
        │
        ├─→ Click link in email → /api/exports/{id}/download?token=<HMAC>
        │   (works from any browser — the HMAC is the authn)
        │
        └─→ OR visit /Exports → row appears in Pending tab
            Click Download → POST /api/exports/{id}/mark-downloaded
            → row drifts to Downloaded tab on next refresh
```

If any step fails, the job re-throws and Hangfire retries per the
attribute: `[AutomaticRetry(Attempts = 3, DelaysInSeconds = new[] { 30, 120, 600 })]`.
After exhaustion the row stays `Status='failed'` with `ErrorMessage`
populated; the operator sees it in the Pending tab with the error pill.

---

## 2. Job types + permissions

| Type | Endpoint | Permission | Filter source |
|---|---|---|---|
| Transactions | `POST /api/exports/transactions` | Any authenticated user. Non-admins are pinned to their session warehouse server-side. | `/Transactions` page filter |
| Purchase Orders | `POST /api/exports/pos` | `admin` OR `supervisor`. Supervisors pinned to session warehouse. | `/Pos` page filter |
| Audit Log | `POST /api/exports/audit-log` | `admin` only — audit data is sensitive. | `/Masters → Audit Log` filter |

All three return `202 Accepted` with the queued `jobId`, the requester's
email, and a friendly message:

```json
{
  "jobId": "9d2b4f3a-...",
  "email": "supervisor@org.example",
  "message": "Export queued. You'll receive an email at supervisor@org.example when it's ready (usually under a minute)."
}
```

### Row caps

Each request DTO carries a `MaxRows` field (default 100,000, server-
clamped). Operators don't see this — it's the safety ceiling that
prevents a "select everything since 2020" export from melting the
worker.

---

## 3. HMAC-signed download URLs

Format: `/api/exports/{jobId:guid}/download?token=<base64url(payload)>.<base64url(HMAC)>`

The token payload is `{jobId:N}|{expiresAtUtcTicks}` signed with
`Exports:SigningKey` (HMAC-SHA256). The download endpoint validates:

1. Signature matches.
2. `jobId` in the token matches the URL.
3. `expiresAtUtc` is in the future.

If any check fails → `401 Unauthorized`. If the file is gone from disk
→ `410 Gone`.

The download endpoint is intentionally **not** `[Authorize]`. The HMAC
*is* the authn — the email recipient may open the link from a
different browser session, mobile device, or after their cookie has
expired. Cookie auth on this surface would defeat the email-delivery
model.

### Token TTL vs file lifetime

| Concept | Default | Source |
|---|---|---|
| Token TTL | 24 hours | `Exports:FileLifetime` |
| File lifetime on disk | **Indefinite** — no janitor exists | (operational gap) |

So: the email link works for 24h, then expires even if the file is
still on disk. The `/Exports` UI sidesteps this by reissuing a fresh
24h token every time the page loads, for any row whose file is still
present. See `deployment.md §5` for the recommended host-level cron
janitor.

---

## 4. UI surfaces

### 4.1 `/Exports` — My Exports page

Two-tab layout:

- **Pending** (default) — actionable backlog. Counts
  queued + running + failed + succeeded-undownloaded rows whose files
  are still on disk. Expired rows show in the list with an "Expired"
  pill but don't inflate the badge.
- **Downloaded** — archive of rows the operator has clicked Download
  on. Re-clicking still grabs the file (token reissued) but skips the
  mark-downloaded call.

Auto-refresh every 5s while any row is `queued` or `running`; goes
quiet once the list settles. Tab counts poll every 10s.

Admin gets a "See everyone's exports" toggle that widens the list to
all users (the toggle itself is hidden until `/api/auth/me` confirms
admin role).

### 4.2 Nav-bar badge

The Exports entry in the side nav carries a pill badge showing the
operator's unread succeeded count. Auto-injected by `app-nav.js`;
polls `/api/exports/unread-count` every 10s. Visiting `/Exports` fires
`POST /api/exports/mark-all-read`, which clears the badge instantly
without waiting for the next poll.

The badge counts the on-disk file set — expired files don't inflate
it. The per-user scope is hard-coded (admin's see-all toggle on the
page itself does **not** widen the badge).

### 4.3 Export buttons (entry points)

| Page | Button location | Visibility gate |
|---|---|---|
| `/Transactions` | Header toolbar | All authenticated |
| `/Pos` | Header, next to Refresh | Admin OR supervisor (revealed by JS via `/api/auth/me`) |
| `/Masters → Audit Log` | Tab toolbar | Admin only |

---

## 5. Database: `dbo.ExportJobsLog`

Migration: `db/020_export_jobs_log.sql` (+ `022` for `ReadAt`, `023`
for `DownloadedAt`).

```
Id               UNIQUEIDENTIFIER  PK
RequesterUserId  UNIQUEIDENTIFIER
RequesterEmail   NVARCHAR(256)
RequesterName    NVARCHAR(256)
JobType          NVARCHAR(50)      -- 'transactions' | 'pos' | 'audit-log'
FilterJson       NVARCHAR(MAX)     -- snapshot of the request DTO
Status           NVARCHAR(20)      -- 'queued' | 'running' | 'succeeded' | 'failed'
EnqueuedAt       DATETIME2
StartedAt        DATETIME2 NULL
CompletedAt      DATETIME2 NULL
FileName         NVARCHAR(256) NULL
RowsExported     INT NULL
ErrorMessage     NVARCHAR(MAX) NULL
ReadAt           DATETIME2 NULL    -- db/022 (nav-bar badge clear)
DownloadedAt     DATETIME2 NULL    -- db/023 (Pending/Downloaded split)
```

Plus the filtered index from `db/023`:

```sql
CREATE INDEX IX_ExportJobsLog_UserPending
ON dbo.ExportJobsLog (RequesterUserId)
WHERE Status = 'succeeded' AND DownloadedAt IS NULL;
```

Rows graduate out of this index as soon as they're downloaded, keeping
the index narrow even with years of history.

### Why `FilterJson`

Operators looking at a 3-day-old export row need to know what they
were filtering for. The snapshot is JSON-serialized at enqueue time
and rendered (informally) on the row tooltip.

---

## 6. Status states

The DB column `Status` carries one of four lifecycle states; the API
exposes a derived `EffectiveStatus` that adds a fifth.

| Status | Meaning | When set |
|---|---|---|
| `queued` | Waiting for a Hangfire worker | INSERT at enqueue |
| `running` | Worker is generating the file | UPDATE on `RunAsync` entry |
| `succeeded` | File written, email sent | UPDATE on `RunAsync` exit (happy path) |
| `failed` | All retries exhausted | UPDATE on `RunAsync` exit (exception) |
| `expired` *(derived)* | `succeeded` but file no longer on disk | Computed at GET time by `ExportsApiController.DeriveEffectiveStatus` |

`expired` is never persisted. It's a UI-layer signal that the row is
no longer actionable — the operator can re-run the export with the
same filter (the JSON snapshot is on the row for reference).

---

## 7. Email delivery

Uses `MailKitEmailService` (`Services/Email/MailKitEmailService.cs`).
SMTP details bind from the `Smtp` configuration section — Host, Port,
UseStartTls, Username, Password, FromAddress.

If `Smtp:Host` is empty (typical in fresh dev environments), the
service no-ops gracefully: the would-be email body is written to the
log instead of sent. The Hangfire job still marks itself succeeded
and writes the file to disk. **In production, leaving SMTP
unconfigured means operators get no notification** — they have to
visit `/Exports` to know their job is done.

For Gmail SMTP, the password must be an **app password**, not the
account password (Gmail rejects basic auth from app passwords' parent
account when 2FA is on). See `/Config → Email test` for an in-app
diagnostic.

---

## 8. Hangfire integration

- **Queue:** `exports` (named explicitly so a future split into a
  worker process is a one-line change).
- **Worker count:** 2 (in-process). Plenty for current volume; bump
  in `Program.cs` if exports start backing up.
- **Dashboard:** `/hangfire` — admin only via `HangfireDashboardAuth`.
  Useful for inspecting retry counts and re-enqueuing failed jobs.
- **Storage:** SQL Server, schema `[HangFire]`. Auto-bootstrapped on
  first start.

---

## 9. API reference

| Method | Path | Auth | Description |
|---|---|---|---|
| POST | `/api/exports/transactions` | Authenticated | Enqueue transactions export |
| POST | `/api/exports/pos` | admin OR supervisor | Enqueue POs export |
| POST | `/api/exports/audit-log` | admin | Enqueue audit-log export |
| GET | `/api/exports/{id}/download?token=...` | **HMAC** (not cookie) | Download the file |
| GET | `/api/exports/jobs?tab=&page=&pageSize=&all=` | Authenticated (admin for `all=true`) | Paginated list for the My Exports page |
| GET | `/api/exports/tab-counts?all=` | Authenticated (admin for `all=true`) | Pending/Downloaded badge counts |
| POST | `/api/exports/{id}/mark-downloaded` | Authenticated | Stamp `DownloadedAt` (own rows only) |
| GET | `/api/exports/unread-count` | Authenticated | Nav-bar badge count (per-user, not widenable) |
| POST | `/api/exports/mark-all-read` | Authenticated | Clear nav-bar badge on `/Exports` visit |

All JSON responses use camelCase. All `DateTime` fields are emitted in
UTC with the `Z` marker (`UtcDateTimeConverter`).

---

## 10. Troubleshooting

| Symptom | First check |
|---|---|
| Export queued but never runs | Visit `/hangfire` → Failed queue. If the job exhausted retries, the error message is there. Common cause: SQL connection drop mid-query. |
| File generated but email never arrived | `/Config → Email test`. If the test succeeds but real exports don't deliver, check the Hangfire dashboard for the actual `Send` exception — often a transient relay timeout. |
| `/Exports` shows "Expired" immediately | The file isn't on disk. Either the host janitor swept it (check the cron), or `StorageRoot` resolved to a different path than the job wrote to (rare; check `Path.IsPathRooted` semantics in `ResolveExportDir`). |
| `401 Unauthorized` on download link | Token expired (>24h old) or the signing key was rotated. Re-export. |
| Admin's exports leak into supervisor's list | Regression — `smoke-my-exports.ps1` covers this; run it. |
