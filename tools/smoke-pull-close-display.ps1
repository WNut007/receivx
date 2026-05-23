# Smoke test: GET /api/pulls/{id} exposes SignatureSvg + ClosedByRole.
#
# Contract test for the new PullSummary fields the dashboard drawer's
# close-authorization section depends on (commit 1 of the v2.x close-display
# work). If these stop landing in the API response, the drawer section will
# silently render empty even though the data is in the DB.
#
# 4 cases:
#   1. GET /api/pulls/{open-pull-id} → signatureSvg = null, closedByRole = null
#   2. Close a fresh smoke pull with a tiny SVG signature
#   3. GET /api/pulls/{just-closed-id} → signatureSvg = the SVG, closedByRole
#      matches the sadmin user's global Role (admin)
#   4. Reopen the pull → signatureSvg + closedByRole stay populated (§7.5
#      preserves the close trio)
#
# Assumes ReceivingOps.Web running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$SAMPLE_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 30"><path d="M5 25 Q 25 5 50 15 T 95 10" stroke="black" fill="none"/></svg>'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

function SqlCleanup {
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-CLD-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}
SqlCleanup

# Login
$body = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null

# Create a fresh smoke pull. Loose flags so we don't drag in PO + hour-cap setup;
# the close gate is hour-cap-agnostic but we still need every window filled.
$pullNum = "PL-CLD-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$pullBody = @{
    pullNumber = $pullNum; warehouseId = $WH_01
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null
    lockPoByPull = $false; lockHourCap = $false
} | ConvertTo-Json
$pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv
$pullId = $pull.id

# ----------------------------------------------------------------------------
# 1. Open pull → both fields absent or null. Program.cs sets the JSON
#    serializer to DefaultIgnoreCondition=WhenWritingNull, so null fields are
#    omitted from the response entirely — the dashboard JS reads `pull.signatureSvg`
#    which is `undefined` if absent and falsy either way, so this is the contract.
# ----------------------------------------------------------------------------
Step "GET /api/pulls/{open-id} → signatureSvg + closedByRole absent or null"
$d0 = Invoke-RestMethod -Uri "$base/api/pulls/$pullId" -Method GET -WebSession $sv
if ($d0.signatureSvg) { Fail "Open pull signatureSvg should be falsy, got '$($d0.signatureSvg)'" }
if ($d0.closedByRole) { Fail "Open pull closedByRole should be falsy, got '$($d0.closedByRole)'" }
OK "Open pull: both fields falsy (absent or null)"

# ----------------------------------------------------------------------------
# 2. Add an item with a window then SQL-poke ReceivedQty=ExpectedQty so the
#    close gate's "no outstanding windows" check passes. Cheaper than wiring
#    the full receive flow for a teardown-only setup.
# ----------------------------------------------------------------------------
Step "Set pull up for close (item + filled window via SQL poke)"
$itemBody = @{
    itemCode = 'CLD-A'; description = 'close-display smoke item'
    windows = @(@{ hourOfDay = 10; expectedQty = 50 })
} | ConvertTo-Json -Depth 5
$item = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items" -Method POST -Body $itemBody -ContentType 'application/json' -WebSession $sv

$fillSql = @"
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
UPDATE dbo.PullItemWindows SET ReceivedQty = ExpectedQty WHERE PullItemId = '$($item.id)';
"@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -b -Q $fillSql 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "SQL fill failed" }
OK "Item + filled window in place"

# ----------------------------------------------------------------------------
# 3. Close the pull with a sample SVG signature
# ----------------------------------------------------------------------------
Step "POST /close with sample SVG signature"
$closeBody = @{ signatureSvg = $SAMPLE_SVG } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/pulls/$pullId/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $sv | Out-Null

# ----------------------------------------------------------------------------
# 4. Closed pull → both fields populated with expected values
# ----------------------------------------------------------------------------
Step "GET /api/pulls/{closed-id} → signatureSvg + closedByRole match"
$d1 = Invoke-RestMethod -Uri "$base/api/pulls/$pullId" -Method GET -WebSession $sv
if ($d1.status -ne 'closed')        { Fail "Pull status not closed: $($d1.status)" }
if ($d1.signatureSvg -ne $SAMPLE_SVG) { Fail "signatureSvg mismatch: got '$($d1.signatureSvg)'" }
if ($d1.closedByRole -ne 'admin')   { Fail "closedByRole expected 'admin', got '$($d1.closedByRole)'" }
if ([string]::IsNullOrWhiteSpace($d1.closedByName)) { Fail "closedByName should be populated post-close" }
OK "signatureSvg + closedByRole present on closed pull"

# ----------------------------------------------------------------------------
# 5. Reopen → fields stay populated (§7.5 preserves close trio)
# ----------------------------------------------------------------------------
Step "POST /reopen → signatureSvg + closedByRole preserved"
$reopenBody = @{ reason = 'close-display smoke verify' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/pulls/$pullId/reopen" -Method POST -Body $reopenBody -ContentType 'application/json' -WebSession $sv | Out-Null
$d2 = Invoke-RestMethod -Uri "$base/api/pulls/$pullId" -Method GET -WebSession $sv
if ($d2.status -ne 'in_progress')   { Fail "Pull status after reopen: $($d2.status), expected in_progress" }
if ($d2.signatureSvg -ne $SAMPLE_SVG) { Fail "Signature dropped on reopen (should be preserved)" }
if ($d2.closedByRole -ne 'admin')   { Fail "closedByRole dropped on reopen (should be preserved)" }
OK "Reopen preserves close trio (signature + closer name + role)"

SqlCleanup

# ----------------------------------------------------------------------------
# 6. UI source-level — Razor + CSS + JS carry the close-auth wiring.
#    Catches stale Razor compiles + missed mockup-vs-served drift.
# ----------------------------------------------------------------------------
Step "Razor view carries close-auth section + every id"
$razor = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Dashboard\Index.cshtml' -Raw
foreach ($id in @(
    'id="d-close-auth"',
    'id="d-closer-name"',
    'id="d-closer-role"',
    'id="d-close-time"',
    'id="d-signature-canvas"',
    'id="d-download-sig"'
)) {
    if ($razor -notmatch [regex]::Escape($id)) { Fail "Index.cshtml missing $id" }
}
if ($razor -notmatch 'Close authorization') { Fail "Index.cshtml missing 'Close authorization' label" }
OK "Razor view has every close-auth id"

Step "dashboard.js carries renderCloseAuth + downloadSignaturePng + adapt() forwarding"
$js = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\dashboard.js' -Raw
foreach ($needle in @(
    'function renderCloseAuth',
    'function downloadSignaturePng',
    'renderCloseAuth(p)',
    'signatureSvg:  s.signatureSvg',
    'closedByRole:  s.closedByRole'
)) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "dashboard.js missing $needle" }
}
OK "dashboard.js carries render + download + adapt() forwarding"

Step "dashboard.css carries close-auth rules"
$css = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\dashboard.css' -Raw
foreach ($rule in @('.close-auth-grid', '.signature-card', '.signature-canvas', '.download-sig')) {
    if ($css -notmatch [regex]::Escape($rule)) { Fail "dashboard.css missing $rule" }
}
OK "dashboard.css has every close-auth rule"

Step "Served /Dashboard HTML carries the new ids (Razor compile fresh)"
$bodyLog = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$sv2 = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $bodyLog -ContentType 'application/json' -SessionVariable sv2 | Out-Null
$page = Invoke-WebRequest -Uri "$base/Dashboard" -Method GET -WebSession $sv2 -UseBasicParsing
foreach ($id in @('id="d-close-auth"', 'id="d-signature-canvas"', 'id="d-download-sig"')) {
    if ($page.Content -notmatch [regex]::Escape($id)) { Fail "Served Dashboard HTML missing $id" }
}
OK "Served Dashboard HTML carries close-auth section"

Write-Host ""
Write-Host "ALL PASS — backend exposes the fields + UI source carries the wiring." -ForegroundColor Green
exit 0
