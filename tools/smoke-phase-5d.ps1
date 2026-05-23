# Smoke test: §3.5 / §7.15 Phase 5d — Pull admin LockPoByPull UI
#
# Source-level + live HTTP checks for the Pull Controller dashboard:
#   - dashboard.js / dashboard.css / Views/Dashboard/Index.cshtml carry the
#     §5d wiring (badge, filter, modal markup, lock-toggle card)
#   - /api/pulls rows expose lockPoByPull
#   - POST /api/pulls without lockPoByPull → persisted as false (default)
#   - POST /api/pulls with lockPoByPull=true → persisted as true
#   - PUT /api/pulls/{id} flipping lockPoByPull → 409 (§7.15 / §3.5 immutability)
#   - PUT echoing lockPoByPull → 200
#   - The dashboard page is served 200 to a CanManagePulls user with both the
#     lock-filter <select> and the pullModal markup present
#
# Each run creates two uniquely-named pulls (one locked, one unlocked) so
# re-runs don't collide on PullNumber uniqueness.
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

# Smoke pulls are prefixed PL-SMOKE-5D- so they survive in audit but get wiped
# before/after each run. verify-phase-3.5 asserts all non-PL-2900/PL-2901 pulls
# have LockPoByPull = 0 — leaving locked smoke pulls behind would break it.
function SqlCleanup {
    $sql = @'
SET NOCOUNT ON;
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-SMOKE-5D-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}

# Pre-test cleanup (idempotent)
SqlCleanup

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# ----------------------------------------------------------------------------
# 1. Source-level — dashboard files carry §5d wiring
# ----------------------------------------------------------------------------
Step "dashboard.js carries §5d hooks (lock filter + adapt + badge + modal)"
$js = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\dashboard.js' -Raw
foreach ($needle in @(
    'currentLockFilter',
    'lock-filter',
    'lockPoByPull:  !!s.lockPoByPull',
    'lock-badge',
    'lock-mode-pill',
    'openCreatePullModal',
    'openEditPullModal',
    'savePullModal',
    'pm-lock-po-by-pull',
    '/api/pulls',
    '§7.15'
)) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "dashboard.js missing '$needle'" }
}
# Edit mode must keep the checkbox disabled (UI mirror of §7.15 server enforcement)
if ($js -notmatch 'lockChk\.disabled\s*=\s*true') { Fail "dashboard.js doesn't disable lock checkbox in edit mode" }
OK "dashboard.js Stage B 5d wiring intact"

Step "dashboard.css carries §5d rules (.lock-badge / .lock-mode-pill / .lock-toggle-card)"
$css = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\dashboard.css' -Raw
foreach ($cls in @('.lock-badge', '.lock-mode-pill', '.lock-toggle-card', '.lock-mode-pill.locked', '.lock-mode-pill.unlocked')) {
    if ($css -notmatch [regex]::Escape($cls)) { Fail "dashboard.css missing rule for $cls" }
}
OK "dashboard.css §5d rules present"

Step "Razor view carries lock-filter dropdown + pullModal + lock-toggle-card markup"
$razor = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Dashboard\Index.cshtml' -Raw
foreach ($needle in @(
    'id="lock-filter"',
    'id="pullModal"',
    'id="pm-lock-po-by-pull"',
    'id="pm-pull-number"',
    'id="pm-warehouse"',
    'id="pm-pull-date"',
    'id="btn-new-pull"',
    'id="d-edit"',
    'id="d-lock-mode"',
    'id="d-linked-pos"'
)) {
    if ($razor -notmatch [regex]::Escape($needle)) { Fail "Razor view missing '$needle'" }
}
OK "Razor view carries the §5d landmarks"

# ----------------------------------------------------------------------------
# 2. Live HTTP — login + dashboard page
# ----------------------------------------------------------------------------
Step "Login (sadmin / WH-01)"
$adm = Login 'sadmin' 'admin' $WH_01
OK "Login ok"

Step "GET /Dashboard renders with lock-filter + pullModal markup"
$page = Invoke-WebRequest -Uri "$base/Dashboard" -WebSession $adm
if ($page.StatusCode -ne 200) { Fail "Expected 200, got $($page.StatusCode)" }
foreach ($needle in @('id="lock-filter"', 'id="pullModal"', 'id="pm-lock-po-by-pull"')) {
    if ($page.Content -notmatch [regex]::Escape($needle)) { Fail "Live page missing '$needle'" }
}
OK "/Dashboard live page carries the §5d landmarks"

# ----------------------------------------------------------------------------
# 3. /api/pulls exposes lockPoByPull on every row
# ----------------------------------------------------------------------------
Step "GET /api/pulls — every row carries lockPoByPull"
$rows = Invoke-RestMethod -Uri "$base/api/pulls?warehouseId=$WH_01" -WebSession $adm
if (-not $rows -or $rows.Count -lt 1) { Fail "Expected non-empty pull list, got 0" }
$missing = @($rows | Where-Object { -not ($_.PSObject.Properties.Name -contains 'lockPoByPull') }).Count
if ($missing -gt 0) { Fail "$missing rows missing lockPoByPull field" }
# Memory says PL-2900 + PL-2901 are seeded as locked
$lockedSeen = @($rows | Where-Object { $_.lockPoByPull }).Count
if ($lockedSeen -lt 1) { Fail "Expected at least one locked pull in seed; saw $lockedSeen" }
OK "All $($rows.Count) rows carry lockPoByPull (locked count = $lockedSeen)"

# ----------------------------------------------------------------------------
# 4. POST /api/pulls — explicit-false unlocked + explicit-true locked round-trip.
#    v2.1 flipped the default-on-omit to true (strict-by-default), so the unlocked
#    path now has to send lockPoByPull=false explicitly. The "omit → false" semantic
#    is gone — see CLAUDE.md "v2 invariants" + BUILD_PROMPT §4.4.
# ----------------------------------------------------------------------------
$tick = [DateTime]::UtcNow.Ticks % 1000000
$unlockedNumber = "PL-SMOKE-5D-U$tick"
$lockedNumber   = "PL-SMOKE-5D-L$tick"

Step "POST /api/pulls with lockPoByPull=false → persisted as false"
$bodyU = @{
    pullNumber = $unlockedNumber
    warehouseId = $WH_01
    pullDate = (Get-Date).ToString('yyyy-MM-dd')
    notes = '5d smoke unlocked'
    lockPoByPull = $false
} | ConvertTo-Json
$createdU = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $bodyU -ContentType 'application/json' -WebSession $adm
if ($createdU.lockPoByPull -ne $false) { Fail "Expected lockPoByPull=false, got $($createdU.lockPoByPull)" }
OK "Explicit-false unlocked pull $unlockedNumber created"

Step "POST /api/pulls WITH lockPoByPull=true → persisted as true"
$bodyL = @{
    pullNumber = $lockedNumber
    warehouseId = $WH_01
    pullDate = (Get-Date).ToString('yyyy-MM-dd')
    notes = '5d smoke locked'
    lockPoByPull = $true
} | ConvertTo-Json
$createdL = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $bodyL -ContentType 'application/json' -WebSession $adm
if ($createdL.lockPoByPull -ne $true) { Fail "Expected lockPoByPull=true, got $($createdL.lockPoByPull)" }
OK "Locked pull $lockedNumber created"

# ----------------------------------------------------------------------------
# 5. PUT immutability — change attempt → 409
# ----------------------------------------------------------------------------
Step "PUT /api/pulls/{id} flipping lockPoByPull → expect 409 (§7.15)"
$putBad = @{
    pullDate     = $createdL.pullDate
    eta          = $null
    notes        = 'attempt to unlock'
    lockPoByPull = $false   # was true at create
} | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/pulls/$($createdL.id)" -Method PUT -Body $putBad -ContentType 'application/json' -WebSession $adm | Out-Null
    Fail "Expected 409 on lockPoByPull flip, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $bodyText = $_.ErrorDetails.Message
    if ($bodyText -notmatch 'LockPoByPull|immutable') { Fail "Expected 'LockPoByPull' or 'immutable' in body, got: $bodyText" }
    OK "409 with title mentioning LockPoByPull immutability"
}

Step "PUT /api/pulls/{id} echoing lockPoByPull → 200"
$putOk = @{
    pullDate     = $createdL.pullDate
    eta          = '15:00'
    notes        = 'echo same lock'
    lockPoByPull = $true   # echo current
} | ConvertTo-Json
$putResp = Invoke-WebRequest -Uri "$base/api/pulls/$($createdL.id)" -Method PUT -Body $putOk -ContentType 'application/json' -WebSession $adm
if ($putResp.StatusCode -notin 200,204) { Fail "Expected 200/204, got $($putResp.StatusCode)" }
OK "PUT with echoed lock → $($putResp.StatusCode)"

# Cleanup — must run BEFORE verify-phase-3.5 sees the locked smoke pull
Step "Cleanup smoke pulls"
SqlCleanup
$remaining = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE 'PL-SMOKE-5D-%';" 2>&1 | Out-String).Trim()
if ($remaining -ne '0') { Fail "Cleanup failed: $remaining smoke pull(s) remain" }
OK "Smoke pulls cleaned"

Write-Host "`nPhase 5d smoke PASSED." -ForegroundColor Green
exit 0
