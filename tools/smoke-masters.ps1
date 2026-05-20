# Smoke: §15 #11 — Masters (Users + Warehouses) + Audit + Preferences
# Covers: admin gate, CRUD users, self-delete guard (§7.8), assignment replace,
# password reset+login, warehouse CRUD + cascade audit (§7.7),
# preferences round-trip with defaults, audit endpoint filter+search.
#
# Resets created rows on completion so the seed stays clean.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH01 = '22222222-2222-2222-2222-000000000001'
$WH03 = '22222222-2222-2222-2222-000000000003'

# sadmin row (from seed 003)
$SADMIN_ID = '11111111-1111-1111-1111-000000000001'

# Marker prefix so the cleanup query finds only rows we created
$TAG = "smoke$([guid]::NewGuid().ToString('N').Substring(0, 6))"

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }
function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}
function ExpectStatus([int]$expected, [scriptblock]$block) {
    try { & $block | Out-Null } catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -ne $expected) { Fail "Expected $expected, got $sc" }
        return
    }
    Fail "Expected $expected, got success"
}

function Cleanup {
    Write-Host "Cleaning up smoke users/warehouses..." -ForegroundColor DarkGray
    $sql = @"
SET QUOTED_IDENTIFIER ON;
DELETE FROM dbo.Users WHERE Username LIKE '$TAG%';
DELETE FROM dbo.Warehouses WHERE Code LIKE 'Z$($TAG.Substring(0,4).ToUpper())%';
DELETE FROM dbo.AuditLog WHERE Message LIKE '%$TAG%';
"@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -Q $sql 2>&1 | Out-Null
}

try {

# ============================================================================
# 1. Auth gate — anonymous + non-admin both rejected
# ============================================================================
Step "Anonymous GET /api/users → 401"
ExpectStatus 401 { Invoke-WebRequest -Uri "$base/api/users" -ErrorAction Stop }
OK "Anonymous blocked"

Step "Non-admin (supervisor) GET /api/users → 403"
$sess_sup = Login 'swattana' 'demo1234' $WH01
ExpectStatus 403 { Invoke-WebRequest -Uri "$base/api/users" -WebSession $sess_sup -ErrorAction Stop }
OK "Supervisor blocked from masters"

Step "Login sadmin / WH-01"
$adm = Login 'sadmin' 'admin' $WH01
OK "Admin logged in"

# ============================================================================
# 2. Users — List + Filter
# ============================================================================
Step "GET /api/users returns at least 6 rows (seed) with assignment counts"
$users = Invoke-RestMethod -Uri "$base/api/users" -WebSession $adm
if ($users.Count -lt 6) { Fail "Expected ≥6 users, got $($users.Count)" }
$sadmin = $users | Where-Object { $_.username -eq 'sadmin' } | Select-Object -First 1
if (-not $sadmin) { Fail "sadmin not in list" }
if ($sadmin.assignmentCount -lt 1) { Fail "sadmin assignmentCount=$($sadmin.assignmentCount), expected ≥1" }
OK "List returns $($users.Count) users; sadmin has $($sadmin.assignmentCount) assignment(s)"

Step "GET /api/users?role=operator filters"
$ops = Invoke-RestMethod -Uri "$base/api/users?role=operator" -WebSession $adm
$bad = $ops | Where-Object { $_.role -ne 'operator' }
if ($bad) { Fail "Filter leaked non-operator: $($bad.username)" }
OK "Operator filter clean ($($ops.Count) row(s))"

Step "GET /api/users?status=inactive returns tviewer"
$inactive = Invoke-RestMethod -Uri "$base/api/users?status=inactive" -WebSession $adm
if (-not ($inactive | Where-Object { $_.username -eq 'tviewer' })) {
    Fail "tviewer (inactive seed) missing from inactive list"
}
OK "Inactive filter works"

# ============================================================================
# 3. Users — CRUD round-trip
# ============================================================================
Step "POST /api/users creates a user with initial assignments"
$createBody = @{
    username    = "${TAG}user1"
    name        = "Smoke User $TAG"
    email       = "smoke@example.com"
    phone       = "0812345678"
    role        = "operator"
    password    = "test1234"
    isActive    = $true
    assignments = @(
        @{ warehouseId = $WH01; role = 'operator' },
        @{ warehouseId = $WH03; role = 'viewer' }
    )
} | ConvertTo-Json -Depth 5
$created = Invoke-RestMethod -Uri "$base/api/users" -Method POST -Body $createBody -ContentType 'application/json' -WebSession $adm
$newId = $created.id
if (-not $newId) { Fail "No id returned from create" }
if ($created.assignments.Count -ne 2) { Fail "Assignments count=$($created.assignments.Count), expected 2" }
OK "Created user $newId with 2 assignments"

Step "POST /api/users with duplicate username → 409"
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/users" -Method POST -Body $createBody -ContentType 'application/json' -WebSession $adm -ErrorAction Stop }
OK "Duplicate username refused"

Step "GET /api/users/{id} returns detail + 2 assignments"
$det = Invoke-RestMethod -Uri "$base/api/users/$newId" -WebSession $adm
if ($det.assignments.Count -ne 2) { Fail "Detail assignments=$($det.assignments.Count)" }
if ($det.role -ne 'operator') { Fail "role=$($det.role)" }
OK "Detail shape correct"

Step "PUT /api/users/{id} updates name + flips active"
$upd = @{
    name     = "Smoke User Updated $TAG"
    email    = $det.email
    phone    = $det.phone
    role     = 'supervisor'
    isActive = $false
} | ConvertTo-Json
$updResp = Invoke-RestMethod -Uri "$base/api/users/$newId" -Method PUT -Body $upd -ContentType 'application/json' -WebSession $adm
if ($updResp.role -ne 'supervisor') { Fail "After update role=$($updResp.role)" }
if ($updResp.isActive) { Fail "isActive should be false after update" }
OK "Update applied (role=supervisor, isActive=false)"

# ============================================================================
# 4. Users — Replace assignments
# ============================================================================
Step "PUT /api/users/{id}/assignments replaces atomically with 1 row"
$replace = @(
    @{ warehouseId = $WH03; role = 'supervisor' }
) | ConvertTo-Json -AsArray
$ra = Invoke-RestMethod -Uri "$base/api/users/$newId/assignments" -Method PUT -Body $replace -ContentType 'application/json' -WebSession $adm
if ($ra.assignments.Count -ne 1) { Fail "After replace count=$($ra.assignments.Count)" }
if ($ra.assignments[0].warehouseId -ne $WH03) { Fail "Wrong wh after replace" }
if ($ra.assignments[0].role -ne 'supervisor') { Fail "Wrong role after replace" }
OK "Assignments replaced (WH-03/supervisor only)"

Step "PUT /api/users/{id}/assignments with duplicate warehouseId → 409"
$dupe = @(
    @{ warehouseId = $WH01; role = 'operator' },
    @{ warehouseId = $WH01; role = 'supervisor' }
) | ConvertTo-Json -AsArray
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/users/$newId/assignments" -Method PUT -Body $dupe -ContentType 'application/json' -WebSession $adm -ErrorAction Stop }
OK "Duplicate warehouseId rejected"

Step "PUT /api/users/{id}/assignments with bad role → 409"
$badRole = @(
    @{ warehouseId = $WH01; role = 'janitor' }
) | ConvertTo-Json -AsArray
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/users/$newId/assignments" -Method PUT -Body $badRole -ContentType 'application/json' -WebSession $adm -ErrorAction Stop }
OK "Bad role rejected"

# ============================================================================
# 5. Users — Reset password + login round-trip
# ============================================================================
Step "POST /api/users/{id}/reset-password sets new password"
# Re-activate first so we can log in.
$reactivate = @{ name="Smoke User $TAG"; email=$det.email; phone=$det.phone; role='operator'; isActive=$true } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/users/$newId" -Method PUT -Body $reactivate -ContentType 'application/json' -WebSession $adm | Out-Null

$pwBody = @{ newPassword = "newpwd9999" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/users/$newId/reset-password" -Method POST -Body $pwBody -ContentType 'application/json' -WebSession $adm | Out-Null
OK "Password reset accepted"

Step "Login with new password works"
$sess_new = Login "${TAG}user1" "newpwd9999" $WH03
$me = Invoke-RestMethod -Uri "$base/api/auth/me" -WebSession $sess_new
if ($me.name -notmatch [regex]::Escape($TAG)) { Fail "auth/me name=$($me.name)" }
OK "Authenticated as the new user via reset password"

Step "POST /api/users/{id}/reset-password with too-short pw → 409"
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/users/$newId/reset-password" -Method POST -Body (@{ newPassword = "ab" } | ConvertTo-Json) -ContentType 'application/json' -WebSession $adm -ErrorAction Stop }
OK "Short password rejected"

# ============================================================================
# 6. Users — Self-delete guard (§7.8) and successful delete
# ============================================================================
Step "DELETE /api/users/{sadminId} as sadmin → 409 (cannot delete self)"
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/users/$SADMIN_ID" -Method DELETE -WebSession $adm -ErrorAction Stop }
OK "Self-delete blocked"

Step "DELETE /api/users/{newId} succeeds → 204"
Invoke-WebRequest -Uri "$base/api/users/$newId" -Method DELETE -WebSession $adm | Out-Null
ExpectStatus 404 { Invoke-WebRequest -Uri "$base/api/users/$newId" -WebSession $adm -ErrorAction Stop }
OK "User deleted; subsequent GET → 404"

# ============================================================================
# 7. Warehouses — List (authenticated) + write (admin only)
# ============================================================================
Step "GET /api/warehouses authenticated returns 4 rows from seed"
$whs = Invoke-RestMethod -Uri "$base/api/warehouses" -WebSession $adm
if ($whs.Count -lt 4) { Fail "Expected ≥4 warehouses, got $($whs.Count)" }
$wh01row = $whs | Where-Object { $_.code -eq 'WH-01' } | Select-Object -First 1
if (-not $wh01row) { Fail "WH-01 missing" }
if ($wh01row.userCount -lt 1) { Fail "WH-01 userCount=$($wh01row.userCount), expected ≥1" }
OK "Warehouses listed; WH-01 has $($wh01row.userCount) user(s)"

Step "Supervisor (non-admin) can read /api/warehouses"
$sess_sup2 = Login 'swattana' 'demo1234' $WH01
$whs2 = Invoke-RestMethod -Uri "$base/api/warehouses" -WebSession $sess_sup2
if ($whs2.Count -lt 4) { Fail "Supervisor list count=$($whs2.Count)" }
OK "Supervisor list read works"

Step "Supervisor POST /api/warehouses → 403"
$whBody = @{ code="Z${TAG}A"; name="Smoke WH $TAG"; capacity=100; timezone='Asia/Bangkok'; isActive=$true } | ConvertTo-Json
ExpectStatus 403 { Invoke-WebRequest -Uri "$base/api/warehouses" -Method POST -Body $whBody -ContentType 'application/json' -WebSession $sess_sup2 -ErrorAction Stop }
OK "Supervisor write blocked"

Step "Admin POST /api/warehouses creates"
$whBodyA = @{ code="Z${TAG}A".ToUpper().Substring(0,8); name="Smoke WH $TAG"; capacity=500; timezone='Asia/Bangkok'; isActive=$true } | ConvertTo-Json
$whNew = Invoke-RestMethod -Uri "$base/api/warehouses" -Method POST -Body $whBodyA -ContentType 'application/json' -WebSession $adm
$whNewId = $whNew.id
if (-not $whNewId) { Fail "No id returned for warehouse create" }
OK "Created warehouse $whNewId"

Step "Admin POST duplicate code → 409"
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/warehouses" -Method POST -Body $whBodyA -ContentType 'application/json' -WebSession $adm -ErrorAction Stop }
OK "Duplicate code refused"

Step "Admin PUT /api/warehouses/{id} updates"
$whUpd = @{ name="Smoke WH UPDATED $TAG"; capacity=999; timezone='Asia/Bangkok'; isActive=$false } | ConvertTo-Json
$updR = Invoke-RestMethod -Uri "$base/api/warehouses/$whNewId" -Method PUT -Body $whUpd -ContentType 'application/json' -WebSession $adm
if ($updR.capacity -ne 999) { Fail "After update capacity=$($updR.capacity)" }
if ($updR.isActive) { Fail "isActive should be false" }
OK "Warehouse updated"

Step "Admin DELETE /api/warehouses/{id} → 204"
Invoke-WebRequest -Uri "$base/api/warehouses/$whNewId" -Method DELETE -WebSession $adm | Out-Null
ExpectStatus 404 { Invoke-WebRequest -Uri "$base/api/warehouses/$whNewId" -WebSession $adm -ErrorAction Stop }
OK "Warehouse deleted"

# ============================================================================
# 8. Audit — endpoint & cascade rows
# ============================================================================
Step "GET /api/audit?take=20 returns recent rows (DESC)"
$au = Invoke-RestMethod -Uri "$base/api/audit?take=20" -WebSession $adm
if ($au.Count -lt 5) { Fail "Audit list count=$($au.Count)" }
$prev = $null
foreach ($r in $au) {
    if ($prev -and ([datetime]$r.occurredAt) -gt ([datetime]$prev.occurredAt)) {
        Fail "Audit not DESC sorted"
    }
    $prev = $r
}
OK "Audit ordered DESC; $($au.Count) rows"

Step "GET /api/audit?q=$TAG finds recent smoke writes"
$auS = Invoke-RestMethod -Uri "$base/api/audit?q=$TAG&take=50" -WebSession $adm
if ($auS.Count -lt 2) { Fail "Audit search for $TAG returned $($auS.Count) row(s); expected ≥2 (create+delete user)" }
$kinds = ($auS | ForEach-Object { $_.actionType }) | Sort-Object -Unique
if (-not ($kinds -contains 'create')) { Fail "Missing 'create' audit for smoke user" }
if (-not ($kinds -contains 'delete')) { Fail "Missing 'delete' audit for smoke user" }
OK "Audit captured create + delete; kinds: $($kinds -join ',')"

Step "Supervisor GET /api/audit → 403"
ExpectStatus 403 { Invoke-WebRequest -Uri "$base/api/audit" -WebSession $sess_sup2 -ErrorAction Stop }
OK "Audit endpoint admin-gated"

# ============================================================================
# 9. Preferences — defaults + round-trip
# ============================================================================
Step "GET /api/me/preferences returns defaults for fresh user"
# Re-create a fresh user for this test
$prefUserBody = @{ username = "${TAG}pref"; name = "Smoke Pref $TAG"; role = "viewer"; password = "test1234"; isActive = $true; assignments = @(@{ warehouseId=$WH01; role='viewer' }) } | ConvertTo-Json -Depth 5
$prefUser = Invoke-RestMethod -Uri "$base/api/users" -Method POST -Body $prefUserBody -ContentType 'application/json' -WebSession $adm
$sess_pref = Login "${TAG}pref" "test1234" $WH01
$prefs = Invoke-RestMethod -Uri "$base/api/me/preferences" -WebSession $sess_pref
if ($prefs.theme -ne 'light') { Fail "Default theme=$($prefs.theme)" }
if ($prefs.navPosition -ne 'horizontal') { Fail "Default navPosition=$($prefs.navPosition)" }
if ($prefs.navBehavior -ne 'sticky') { Fail "Default navBehavior=$($prefs.navBehavior)" }
OK "Defaults served when no row exists"

Step "PUT /api/me/preferences round-trips"
$putBody = @{ theme='midnight'; navPosition='vertical'; navBehavior='auto-hide'; navCollapsed=$true } | ConvertTo-Json
$putResp = Invoke-RestMethod -Uri "$base/api/me/preferences" -Method PUT -Body $putBody -ContentType 'application/json' -WebSession $sess_pref
if ($putResp.theme -ne 'midnight') { Fail "After PUT theme=$($putResp.theme)" }
if (-not $putResp.navCollapsed) { Fail "navCollapsed should be true" }

$getBack = Invoke-RestMethod -Uri "$base/api/me/preferences" -WebSession $sess_pref
if ($getBack.theme -ne 'midnight' -or $getBack.navBehavior -ne 'auto-hide') {
    Fail "Round-trip mismatch: theme=$($getBack.theme), navBehavior=$($getBack.navBehavior)"
}
OK "Preferences round-tripped"

Step "PUT /api/me/preferences with bad theme → 400"
$bad = @{ theme='neon'; navPosition='horizontal'; navBehavior='sticky'; navCollapsed=$false } | ConvertTo-Json
ExpectStatus 400 { Invoke-WebRequest -Uri "$base/api/me/preferences" -Method PUT -Body $bad -ContentType 'application/json' -WebSession $sess_pref -ErrorAction Stop }
OK "Invalid theme rejected"

# Cleanup the pref user
Invoke-WebRequest -Uri "$base/api/users/$($prefUser.id)" -Method DELETE -WebSession $adm | Out-Null

Cleanup
Write-Host "`nMasters/Audit/Preferences smoke passed." -ForegroundColor Green

} catch {
    Write-Host "UNCAUGHT: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Response) {
        $sc = $_.Exception.Response.StatusCode.value__
        Write-Host "Status: $sc" -ForegroundColor Red
    }
    Cleanup
    exit 1
}
