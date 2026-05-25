# Smoke: Phase 10.3 — Upsert ErpSyncDraft into Pulls / PullItems / PullItemWindows.
#
# Source-level smoke. Behavioral end-to-end runs in 10.4 when the manual-
# trigger endpoint lands; at that point a smoke can POST the trigger,
# wait, and SELECT the resulting rows. 10.3's purpose is to verify the
# upsert SQL has the right shape — that we never write to Receivx-managed
# columns, never DELETE items, and respect the closed-pull skip.
#
# Checks:
#   1. Result DTO + interface + impl present
#   2. Job now injects IErpUpsertService and invokes UpsertAsync after read
#   3. INSERT statements for Pulls + PullItems + PullItemWindows exist
#   4. Closed-pull skip path present (Status='closed' check + counter)
#   5. Cancelled-item path: UPDATE PullItems SET Status='canceled' on the
#      orphan branch (items in DB not in draft)
#   6. Receivx-managed columns never appear in any UPDATE SET clause:
#      ReceivedQty, LockPoByPull, LockHourCap, ClosedAt, ClosedBy,
#      SignatureSvg, ReopenedAt, ReopenedBy, ReopenReason
#   7. PullItemWindow update guards against dropping ExpectedQty below
#      ReceivedQty (would violate CK_PIW_Caps)
#   8. Program.cs registers IErpUpsertService
#   9. Dev server reachable

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function AssertFile([string]$path, [string]$mustContain) {
    if (-not (Test-Path $path)) { Fail "Expected file not found: $path" }
    $body = Get-Content -Raw -LiteralPath $path
    if ($body -notmatch [regex]::Escape($mustContain)) {
        Fail "File $([System.IO.Path]::GetFileName($path)) missing token '$mustContain'"
    }
}

# ----------------------------------------------------------------------------
# 1. Result DTO + interface + impl
# ----------------------------------------------------------------------------
Step "ErpUpsertResult + IErpUpsertService + ErpUpsertService present"
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpUpsertResult.cs') 'public class ErpUpsertResult'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpUpsertResult.cs') 'public class PullOutcome'
AssertFile (Join-Path $webRoot 'Services\ErpSync\IErpUpsertService.cs') 'public interface IErpUpsertService'
AssertFile (Join-Path $webRoot 'Services\ErpSync\IErpUpsertService.cs') 'Task<ErpUpsertResult> UpsertAsync('
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpUpsertService.cs') 'public class ErpUpsertService : IErpUpsertService'
OK "All three components present"

# ----------------------------------------------------------------------------
# 2. Job wires the upsert
# ----------------------------------------------------------------------------
Step "ErpSyncJob calls UpsertAsync after ReadAndTransformAsync"
$jobBody = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\ErpSyncJob.cs')
if ($jobBody -notmatch 'IErpUpsertService') { Fail "ErpSyncJob does not inject IErpUpsertService" }
if ($jobBody -notmatch 'UpsertAsync\(draft') { Fail "ErpSyncJob does not call UpsertAsync(draft, …)" }
# Order matters — read before upsert. Anchor on the call site
# ("await _read.ReadAndTransformAsync(" / "await _upsert.UpsertAsync(") so
# XML-doc comments mentioning the methods don't false-positive.
$readPos = $jobBody.IndexOf('await _read.ReadAndTransformAsync(')
$upsertPos = $jobBody.IndexOf('await _upsert.UpsertAsync(')
if ($readPos -lt 0 -or $upsertPos -lt 0 -or $readPos -gt $upsertPos) {
    Fail "ErpSyncJob must call ReadAndTransformAsync BEFORE UpsertAsync"
}
OK "Job wires read → upsert in order"

# ----------------------------------------------------------------------------
# 3. INSERT statements for all 3 tables
# ----------------------------------------------------------------------------
Step "INSERT INTO Pulls / PullItems / PullItemWindows all present"
$svc = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\ErpUpsertService.cs')
foreach ($needle in @('INSERT INTO dbo.Pulls', 'INSERT INTO dbo.PullItems', 'INSERT INTO dbo.PullItemWindows')) {
    if ($svc -notmatch [regex]::Escape($needle)) { Fail "Missing $needle" }
}
OK "All 3 INSERT paths present"

# ----------------------------------------------------------------------------
# 4. Closed-pull skip
# ----------------------------------------------------------------------------
Step "Closed-pull skip path present"
if ($svc -notmatch [regex]::Escape('"closed", StringComparison.Ordinal')) {
    Fail "No Status='closed' equality check in upsert service"
}
if ($svc -notmatch 'SkippedClosed\+\+') {
    Fail "SkippedClosed counter not incremented"
}
OK "Closed-pull skip wired"

# ----------------------------------------------------------------------------
# 5. Cancelled-item path (UPDATE Status='canceled' for orphan items)
# ----------------------------------------------------------------------------
Step "Orphan-item cancellation path"
if ($svc -notmatch "Status = 'canceled'") {
    Fail "No 'canceled' UPDATE in upsert service"
}
if ($svc -notmatch 'ItemsCanceled\+\+') {
    Fail "ItemsCanceled counter not incremented"
}
# Spec §2.5: never DELETE items. The service must not DELETE PullItems.
if ($svc -match 'DELETE FROM dbo\.PullItems') {
    Fail "Spec violation — DELETE FROM dbo.PullItems found in upsert service"
}
OK "Orphan items get status='canceled', never DELETE"

# ----------------------------------------------------------------------------
# 6. Receivx-managed fields excluded from any UPDATE SET
# ----------------------------------------------------------------------------
Step "Receivx-managed columns must NOT appear in UPDATE SET clauses"
# Heuristic: scan for 'SET ... <col> ='.  We look at UPDATE blocks and assert
# none of the protected fields appear. Each below MUST NOT appear in the
# service source as part of an UPDATE column-set.
$forbidden = @('LockPoByPull', 'LockHourCap', 'ClosedAt', 'ClosedBy',
               'SignatureSvg', 'ReopenedAt', 'ReopenedBy', 'ReopenReason',
               'ReceivedQty')
foreach ($col in $forbidden) {
    # Match 'SET ... \b<col>\b\s*=' (multiline) — UPDATE syntax. Anchored
    # to SET so the READ-side SELECTs of those columns (legitimate) don't
    # trip the check.
    if ($svc -match "(?ms)\bSET\b[^;]{0,2000}\b$([regex]::Escape($col))\s*=") {
        Fail "Receivx-managed column '$col' appears in an UPDATE SET — must be ETL-immutable"
    }
}
OK "All 9 Receivx-managed columns protected from ETL writes"

# ----------------------------------------------------------------------------
# 7. ExpectedQty downward-clamp against ReceivedQty
# ----------------------------------------------------------------------------
Step "ExpectedQty update guards against CK_PIW_Caps violation"
if ($svc -notmatch 'Math\.Max\(win\.ExpectedQty, ex\.ReceivedQty\)') {
    Fail "No Math.Max(win.ExpectedQty, ex.ReceivedQty) clamp in SyncWindowsAsync"
}
OK "Window ExpectedQty clamped to >= ReceivedQty"

# ----------------------------------------------------------------------------
# 8. Program.cs registration
# ----------------------------------------------------------------------------
Step "Program.cs registers IErpUpsertService"
AssertFile (Join-Path $webRoot 'Program.cs') 'AddScoped<IErpUpsertService, ErpUpsertService>'
OK "Service registered in DI"

# ----------------------------------------------------------------------------
# 9. Dev server reachable
# ----------------------------------------------------------------------------
Step "Dev server reachable on $base"
try {
    $resp = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $code = $resp.StatusCode
} catch {
    $code = $_.Exception.Response.StatusCode.value__
}
if ($code -ne 401 -and $code -ne 200) {
    Fail "Dev server probe got HTTP $code, expected 401 (anonymous) or 200"
}
OK "Dev server is up (HTTP $code on /api/auth/me)"

Write-Host ""
Write-Host "ALL PASS — Phase 10.3: upsert service shape verified (behavioral end-to-end in 10.4)." -ForegroundColor Green
exit 0
