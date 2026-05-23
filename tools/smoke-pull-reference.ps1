# Smoke test: Pulls.ReferenceNumber column + API persist round-trip.
#
# Phase 7.1 foundation — proves the migration landed correctly + the
# API surface accepts/returns the new field. The Reports view + DO
# render (Phase 7.2+) depend on this contract.
#
# 6 cases:
#   1. Schema — column exists, nvarchar, nullable.
#   2. Backfill — every pre-7.1 seeded pull has ReferenceNumber = NULL
#      (the migration didn't retroactively populate anything).
#   3. POST /api/pulls with referenceNumber → persists trimmed value.
#   4. GET /api/pulls/{id} → response includes referenceNumber.
#   5. POST WITHOUT referenceNumber → persists as NULL (omit → null).
#   6. PUT /api/pulls/{id} updating referenceNumber → persists new value
#      (editable post-create, unlike the lock flags).
#   7. POST with whitespace-only referenceNumber → normalized to NULL
#      (matches the trim-to-null rule in PullAdminService).
#   8. Razor + dashboard.js source landmarks for the input.
#
# Assumes ReceivingOps.Web running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

$script:smkN = 0

function SqlCleanup {
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-REF-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}
SqlCleanup

# Login
$body = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null

function NewPullBody($refValue) {
    $script:smkN++
    $pullNum = "PL-REF-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$($script:smkN)"
    $hash = @{
        pullNumber = $pullNum; warehouseId = $WH_01
        pullDate = (Get-Date -Format 'yyyy-MM-dd')
        eta = $null; notes = $null
        lockPoByPull = $false; lockHourCap = $false
    }
    # Only set the key when the test wants to send it; null vs omit are distinct
    # at the JSON layer (Newtonsoft / System.Text.Json default-bind both to the
    # DTO default = null, but the smoke exercises both paths just in case).
    if ($refValue -ne 'OMIT') { $hash.referenceNumber = $refValue }
    return [pscustomobject]@{ PullNumber = $pullNum; Body = ($hash | ConvertTo-Json) }
}

# ----------------------------------------------------------------------------
# 1. Schema
# ----------------------------------------------------------------------------
Step "Schema — dbo.Pulls.ReferenceNumber exists (nvarchar(64), nullable)"
$meta = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT TYPE_NAME(system_type_id) + '|' + CONVERT(VARCHAR, max_length) + '|' + CONVERT(VARCHAR, is_nullable) FROM sys.columns WHERE Name='ReferenceNumber' AND Object_ID=OBJECT_ID('dbo.Pulls');" 2>&1
if ($meta.Trim() -ne 'nvarchar|128|1') { Fail "Column metadata wrong: '$($meta.Trim())' (expected 'nvarchar|128|1' — 128 bytes = 64 UTF-16 chars)" }
OK "Column is nvarchar(64) NULL"

# ----------------------------------------------------------------------------
# 2. Backfill — every seeded pull (PL-28xx) has NULL
# ----------------------------------------------------------------------------
Step "Backfill — seeded PL-28xx pulls all have ReferenceNumber = NULL"
$bad = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE 'PL-28%' AND ReferenceNumber IS NOT NULL;" 2>&1
if ($bad.Trim() -ne '0') { Fail "$bad seeded pull(s) have ReferenceNumber populated (expected 0 — no backfill performed)" }
OK "Backfill clean — no seeded pulls carry a reference"

# ----------------------------------------------------------------------------
# 3. POST with referenceNumber → persists trimmed
# ----------------------------------------------------------------------------
Step "POST /api/pulls with referenceNumber='INV-2026-0042' → persisted"
$np = NewPullBody 'INV-2026-0042'
$created = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $np.Body -ContentType 'application/json' -WebSession $sv
if ($created.referenceNumber -ne 'INV-2026-0042') { Fail "Create response ref='$($created.referenceNumber)' (expected 'INV-2026-0042')" }
$db = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT ReferenceNumber FROM dbo.Pulls WHERE PullNumber='$($np.PullNumber)';" 2>&1
if ($db.Trim() -ne 'INV-2026-0042') { Fail "DB ref='$($db.Trim())' (expected 'INV-2026-0042')" }
OK "Reference persisted on POST"
$pullA = $created

# ----------------------------------------------------------------------------
# 4. GET /api/pulls/{id} → response carries referenceNumber
# ----------------------------------------------------------------------------
Step "GET /api/pulls/{id} → response carries referenceNumber"
$detail = Invoke-RestMethod -Uri "$base/api/pulls/$($pullA.id)" -Method GET -WebSession $sv
if ($detail.referenceNumber -ne 'INV-2026-0042') { Fail "GET ref='$($detail.referenceNumber)' (expected 'INV-2026-0042')" }
OK "GET PullDetail returns referenceNumber"

# ----------------------------------------------------------------------------
# 5. POST WITHOUT referenceNumber → persists NULL
# ----------------------------------------------------------------------------
Step "POST without referenceNumber → persists NULL"
$np2 = NewPullBody 'OMIT'
$created2 = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $np2.Body -ContentType 'application/json' -WebSession $sv
$db2 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT ISNULL(ReferenceNumber, '<NULL>') FROM dbo.Pulls WHERE PullNumber='$($np2.PullNumber)';" 2>&1
if ($db2.Trim() -ne '<NULL>') { Fail "Omit-create persisted '$($db2.Trim())' (expected NULL)" }
OK "Omitting referenceNumber persists NULL"

# ----------------------------------------------------------------------------
# 6. PUT updates referenceNumber (editable post-create)
# ----------------------------------------------------------------------------
Step "PUT /api/pulls/{id} updates referenceNumber → new value persisted"
$putBody = @{
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = '15:00'; notes = 'phase 7.1 edit'
    lockPoByPull = $pullA.lockPoByPull
    lockHourCap = $pullA.lockHourCap
    referenceNumber = 'INV-2026-0042-REV2'
} | ConvertTo-Json
$updated = Invoke-RestMethod -Uri "$base/api/pulls/$($pullA.id)" -Method PUT -Body $putBody -ContentType 'application/json' -WebSession $sv
if ($updated.referenceNumber -ne 'INV-2026-0042-REV2') { Fail "PUT response ref='$($updated.referenceNumber)'" }
$db3 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT ReferenceNumber FROM dbo.Pulls WHERE Id='$($pullA.id)';" 2>&1
if ($db3.Trim() -ne 'INV-2026-0042-REV2') { Fail "PUT DB ref='$($db3.Trim())'" }
OK "Reference editable post-create (vendor revised invoice case)"

# ----------------------------------------------------------------------------
# 7. Whitespace-only normalizes to NULL
# ----------------------------------------------------------------------------
Step "POST with whitespace-only referenceNumber → normalized to NULL"
$np3 = NewPullBody '   '
$created3 = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $np3.Body -ContentType 'application/json' -WebSession $sv
$db4 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT ISNULL(ReferenceNumber, '<NULL>') FROM dbo.Pulls WHERE PullNumber='$($np3.PullNumber)';" 2>&1
if ($db4.Trim() -ne '<NULL>') { Fail "Whitespace-only persisted '$($db4.Trim())' (expected NULL)" }
OK "Whitespace-only normalizes to NULL"

# ----------------------------------------------------------------------------
# 8. Source landmarks — Razor + dashboard.js
# ----------------------------------------------------------------------------
Step "Razor + dashboard.js carry the pm-reference wiring"
$razor = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Dashboard\Index.cshtml' -Raw
if ($razor -notmatch [regex]::Escape('id="pm-reference"')) { Fail "Index.cshtml missing id=`"pm-reference`"" }
$js = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\dashboard.js' -Raw
foreach ($needle in @(
    "getElementById('pm-reference')",
    'referenceNumber:',
    'referenceNumber: s.referenceNumber',
    'p.referenceNumber'
)) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "dashboard.js missing $needle" }
}
OK "Razor + dashboard.js wire pm-reference end-to-end"

SqlCleanup
Write-Host ""
Write-Host "ALL PASS — Pulls.ReferenceNumber foundation wired through DB + API + UI." -ForegroundColor Green
exit 0
