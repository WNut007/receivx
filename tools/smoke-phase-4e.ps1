# Smoke test: §3.5 Pull admin endpoints — POST /api/pulls + PUT /api/pulls/{id}
#
# Create:
#   (1) POST without lockPoByPull → 201, LockPoByPull=false (default)
#   (2) POST with lockPoByPull=true → 201, LockPoByPull=true
#   (3) POST duplicate PullNumber → 409
#   (4) POST empty PullNumber → 400 ValidationException
#   (5) POST missing WarehouseId → 400
#   (6) POST missing PullDate → 400
#
# Update (immutability):
#   (7) PUT echo same LockPoByPull → 200
#   (8) PUT LockPoByPull false→true → 409
#   (9) PUT LockPoByPull true→false → 409
#  (10) PUT on closed pull (PL-2840) → 409 closed
#  (11) PUT unknown id → 404
#
# Reads:
#  (12) GET /api/pulls/{id} projects LockPoByPull
#  (13) GET /api/pulls list projects LockPoByPull

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$session = $null

$WH_01   = '22222222-2222-2222-2222-000000000001'
$PL_2840 = '33333333-3333-3333-3333-000000002840'    # closed pull
$BOGUS   = '00000000-0000-0000-0000-000000000999'

function Step($name) { Write-Host "`n--- $name ---" -ForegroundColor Cyan }
function OK($msg)    { Write-Host "PASS: $msg" -ForegroundColor Green }
function Fail($msg)  { Write-Host "FAIL: $msg" -ForegroundColor Red; SqlCleanup; exit 1 }

function SqlCleanup {
    # QUOTED_IDENTIFIER ON because Pulls↔PurchaseOrders is referenced by IX_PO_Pull (filtered).
    # No FK cascade from Pulls→Pulls subordinates, so we wipe items+windows for the smoke pulls
    # explicitly (in case of failure mid-test).
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -Q @"
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
DELETE piw FROM dbo.PullItemWindows piw
INNER JOIN dbo.PullItems pi ON pi.Id = piw.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-SMOKE-4E-%';
DELETE pi FROM dbo.PullItems pi
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-SMOKE-4E-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-SMOKE-4E-%';
"@ | Out-Null
}

function Q($sql) {
    (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
}

# Pre-test cleanup (idempotent)
SqlCleanup

# ---------- Login ----------
Step "Login (sadmin / WH-01)"
$loginBody = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
$r = Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable session
if ($r.StatusCode -ne 200) { Fail "Login expected 200, got $($r.StatusCode)" }
OK "Login ok"

function PostPull([hashtable]$body) {
    $json = $body | ConvertTo-Json
    return Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $json -ContentType 'application/json' -WebSession $session
}

function PutPull([string]$id, [hashtable]$body) {
    $json = $body | ConvertTo-Json
    return Invoke-WebRequest -Uri "$base/api/pulls/$id" -Method PUT -Body $json -ContentType 'application/json' -WebSession $session
}

# ============================================================================
# (1) POST without lockPoByPull → LockPoByPull=true (v2.1 strict default).
#     Explicitly send lockPoByPull=false to test the unlocked path; the
#     "omit → defaults to false" semantic was removed in v2.1 (PullCreateRequest
#     default = true; see CLAUDE.md "v2 invariants" + BUILD_PROMPT §4.4).
# ============================================================================
Step "(1) POST /api/pulls with lockPoByPull=false → 201, persisted as false"
$p1 = PostPull @{
    pullNumber   = 'PL-SMOKE-4E-1'
    warehouseId  = $WH_01
    pullDate     = '2026-05-30'
    eta          = '14:00'
    notes        = '4e smoke unlocked'
    lockPoByPull = $false
}
if ($p1.pullNumber -ne 'PL-SMOKE-4E-1') { Fail "Expected pullNumber=PL-SMOKE-4E-1, got '$($p1.pullNumber)'" }
if ($p1.lockPoByPull -ne $false)        { Fail "Expected lockPoByPull=false, got $($p1.lockPoByPull)" }
if ($p1.status -ne 'pending')           { Fail "Expected status=pending, got '$($p1.status)'" }
$p1Id = $p1.id
OK "Created unlocked pull id=$p1Id"

# ============================================================================
# (2) POST with lockPoByPull=true → LockPoByPull=true
# ============================================================================
Step "(2) POST /api/pulls with lockPoByPull=true → 201"
$p2 = PostPull @{
    pullNumber  = 'PL-SMOKE-4E-2'
    warehouseId = $WH_01
    pullDate    = '2026-05-30'
    eta         = '15:00'
    notes       = '4e smoke locked'
    lockPoByPull = $true
}
if ($p2.lockPoByPull -ne $true) { Fail "Expected lockPoByPull=true, got $($p2.lockPoByPull)" }
$p2Id = $p2.id
OK "Created locked pull id=$p2Id"

# ============================================================================
# (3) POST duplicate PullNumber → 409
# ============================================================================
Step "(3) POST duplicate PullNumber → 409"
try {
    PostPull @{ pullNumber='PL-SMOKE-4E-1'; warehouseId=$WH_01; pullDate='2026-05-30' } | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'already taken') { Fail "Title missing 'already taken'. Got: $msg" }
    OK "409 duplicate pull number"
}

# ============================================================================
# (4) POST empty PullNumber → 400
# ============================================================================
Step "(4) POST empty PullNumber → 400 ValidationException"
try {
    PostPull @{ pullNumber=''; warehouseId=$WH_01; pullDate='2026-05-30' } | Out-Null
    Fail "Expected 400, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 400) { Fail "Expected 400, got $($_.Exception.Response.StatusCode.value__)" }
    OK "400 empty PullNumber"
}

# ============================================================================
# (5) POST missing WarehouseId → 400
# ============================================================================
Step "(5) POST without warehouseId → 400"
try {
    PostPull @{ pullNumber='PL-SMOKE-4E-5'; pullDate='2026-05-30' } | Out-Null
    Fail "Expected 400, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 400) { Fail "Expected 400, got $($_.Exception.Response.StatusCode.value__)" }
    OK "400 missing WarehouseId"
}

# ============================================================================
# (6) POST missing PullDate → 400
# ============================================================================
Step "(6) POST without pullDate → 400"
try {
    PostPull @{ pullNumber='PL-SMOKE-4E-6'; warehouseId=$WH_01 } | Out-Null
    Fail "Expected 400, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 400) { Fail "Expected 400, got $($_.Exception.Response.StatusCode.value__)" }
    OK "400 missing PullDate"
}

# ============================================================================
# (7) PUT echo same LockPoByPull → 200
# ============================================================================
Step "(7) PUT echoing same LockPoByPull → 200"
$r = PutPull $p1Id @{
    pullDate     = '2026-05-31'
    eta          = '16:00'
    notes        = '4e smoke updated'
    lockPoByPull = $false
}
if ($r.StatusCode -ne 200) { Fail "Expected 200, got $($r.StatusCode)" }
$p1After = $r.Content | ConvertFrom-Json
if ($p1After.lockPoByPull -ne $false) { Fail "LockPoByPull changed unexpectedly: $($p1After.lockPoByPull)" }
if ($p1After.eta -ne '16:00')         { Fail "Eta not updated. Got '$($p1After.eta)'" }
if ($p1After.notes -ne '4e smoke updated') { Fail "Notes not updated. Got '$($p1After.notes)'" }
OK "echo-OK: lockPoByPull preserved, eta/notes updated"

# ============================================================================
# (8) PUT LockPoByPull false→true → 409
# ============================================================================
Step "(8) PUT LockPoByPull false→true → 409 immutable"
try {
    PutPull $p1Id @{ pullDate='2026-05-31'; lockPoByPull=$true } | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'LockPoByPull is immutable') { Fail "Title missing 'LockPoByPull is immutable'. Got: $msg" }
    OK "409 false→true rejected"
}

# ============================================================================
# (9) PUT LockPoByPull true→false → 409
# ============================================================================
Step "(9) PUT LockPoByPull true→false → 409 immutable"
try {
    PutPull $p2Id @{ pullDate='2026-05-31'; lockPoByPull=$false } | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    OK "409 true→false rejected"
}

# ============================================================================
# (10) PUT on closed pull (PL-2840) → 409 closed
# ============================================================================
Step "(10) PUT on closed pull (PL-2840) → 409 closed"
try {
    PutPull $PL_2840 @{ pullDate='2026-05-31'; lockPoByPull=$false } | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'closed pull') { Fail "Title missing 'closed pull'. Got: $msg" }
    OK "409 closed-pull edit refused"
}

# ============================================================================
# (11) PUT unknown id → 404
# ============================================================================
Step "(11) PUT unknown id → 404"
try {
    PutPull $BOGUS @{ pullDate='2026-05-31'; lockPoByPull=$false } | Out-Null
    Fail "Expected 404, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) { Fail "Expected 404, got $($_.Exception.Response.StatusCode.value__)" }
    OK "404 unknown pull id"
}

# ============================================================================
# (12) GET /api/pulls/{id} projects LockPoByPull
# ============================================================================
Step "(12) GET /api/pulls/{id} returns LockPoByPull"
$d1 = Invoke-RestMethod -Uri "$base/api/pulls/$p1Id" -WebSession $session
$d2 = Invoke-RestMethod -Uri "$base/api/pulls/$p2Id" -WebSession $session
if ($d1.lockPoByPull -ne $false) { Fail "detail(unlocked).lockPoByPull should be false. Got $($d1.lockPoByPull)" }
if ($d2.lockPoByPull -ne $true)  { Fail "detail(locked).lockPoByPull should be true. Got $($d2.lockPoByPull)" }
OK "detail projects lockPoByPull correctly"

# Bonus: existing seed PL-2900 should also expose lockPoByPull=true via the same endpoint
$pl2900 = Invoke-RestMethod -Uri "$base/api/pulls/by-number/PL-2900" -WebSession $session
if ($pl2900.lockPoByPull -ne $true) { Fail "PL-2900 (seed) should expose lockPoByPull=true, got $($pl2900.lockPoByPull)" }
OK "by-number endpoint also exposes lockPoByPull (PL-2900=true)"

# ============================================================================
# (13) GET /api/pulls list projects LockPoByPull
# ============================================================================
Step "(13) GET /api/pulls list projects LockPoByPull"
$list = Invoke-RestMethod -Uri "$base/api/pulls?warehouseId=$WH_01" -WebSession $session
$rowUnlocked = $list | Where-Object { $_.pullNumber -eq 'PL-SMOKE-4E-1' }
$rowLocked   = $list | Where-Object { $_.pullNumber -eq 'PL-SMOKE-4E-2' }
$rowSeed2900 = $list | Where-Object { $_.pullNumber -eq 'PL-2900' }
if (-not $rowUnlocked) { Fail "Smoke unlocked pull missing from list" }
if (-not $rowLocked)   { Fail "Smoke locked pull missing from list" }
if (-not $rowSeed2900) { Fail "Seed PL-2900 missing from list" }
if ($rowUnlocked.lockPoByPull -ne $false) { Fail "list row unlocked.lockPoByPull mismatch" }
if ($rowLocked.lockPoByPull   -ne $true)  { Fail "list row locked.lockPoByPull mismatch" }
if ($rowSeed2900.lockPoByPull -ne $true)  { Fail "list row PL-2900.lockPoByPull mismatch" }
OK "list rows carry lockPoByPull (unlocked=false, locked=true, seed PL-2900=true)"

# ============================================================================
# Cleanup
# ============================================================================
Step "Cleanup smoke pulls"
SqlCleanup
$remaining = Q "SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE 'PL-SMOKE-4E-%';"
if ($remaining -ne '0') { Fail "Cleanup failed: $remaining smoke pull(s) remain" }
OK "All smoke pulls removed"

Write-Host "`nPhase 4e smoke passed (all 13 scenarios)." -ForegroundColor Green
