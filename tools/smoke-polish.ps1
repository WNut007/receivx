# Smoke: §15 #12 polish — dashboard dropdown wired to API, reset-password
# endpoint round-trips, and appsettings.Development.json contains no Password=.
#
# This file is independent of smoke-masters.ps1 so it can be re-run quickly
# while iterating on UI polish without re-running the full CRUD pass.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH01 = '22222222-2222-2222-2222-000000000001'
$DEV_SETTINGS = 'C:\dev\receivx\src\ReceivingOps.Web\appsettings.Development.json'

$TAG = "polish$([guid]::NewGuid().ToString('N').Substring(0,5))"

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }
function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}
function Cleanup {
    $sql = "DELETE FROM dbo.Users WHERE Username LIKE '$TAG%'; DELETE FROM dbo.AuditLog WHERE Message LIKE '%$TAG%';"
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -Q $sql 2>&1 | Out-Null
}

try {

# ============================================================================
# 1. dashboard.js calls /api/warehouses and dropdown wiring is gone
# ============================================================================
Step "dashboard.js: populateWhFilter() exists and fetches /api/warehouses"
$dashJs = Get-Content -LiteralPath 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\dashboard.js' -Raw
if ($dashJs -notmatch 'populateWhFilter') { Fail "populateWhFilter() not found in dashboard.js" }
if ($dashJs -notmatch '/api/warehouses\?status=active') { Fail "dashboard.js doesn't call /api/warehouses?status=active" }
OK "dashboard.js dynamically populates the WH dropdown"

# ============================================================================
# 2. /api/warehouses returns shape the dropdown needs
# ============================================================================
Step "GET /api/warehouses?status=active returns rows usable for the dropdown"
$sup = Login 'swattana' 'demo1234' $WH01
$whs = Invoke-RestMethod -Uri "$base/api/warehouses?status=active" -WebSession $sup
if ($whs.Count -lt 3) { Fail "Active warehouse count=$($whs.Count), expected ≥3 (WH-01,02,03)" }
# Use a distinct name — PS variables are case-insensitive, so a $wh01 below
# would otherwise clobber the $WH01 GUID constant declared at the top.
$wh01row = $whs | Where-Object { $_.code -eq 'WH-01' }
if (-not $wh01row) { Fail "WH-01 missing from active list" }
foreach ($field in @('code', 'name', 'isActive')) {
    if (-not $wh01row.PSObject.Properties[$field]) { Fail "warehouse row missing '$field'" }
}
$inactive = $whs | Where-Object { -not $_.isActive }
if ($inactive) { Fail "Inactive warehouse leaked: $($inactive.code)" }
OK "Dropdown shape correct; $($whs.Count) active warehouses"

# ============================================================================
# 3. Reset-password round-trip: create user, reset, login with new pw, cleanup
# ============================================================================
Step "Admin → create user, reset password, login as the user"
try { $adm = Login 'sadmin' 'admin' $WH01 } catch {
    $sc = $_.Exception.Response.StatusCode.value__
    $errBody = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Fail "sadmin login failed [$sc]: $errBody"
}

$createBody = @{
    username = "${TAG}u1"
    name = "Polish $TAG"
    role = 'operator'
    password = 'orig1234'
    isActive = $true
    assignments = @(@{ warehouseId = $WH01; role = 'operator' })
} | ConvertTo-Json -Depth 4

try {
    $created = Invoke-RestMethod -Uri "$base/api/users" -Method POST -Body $createBody -ContentType 'application/json' -WebSession $adm
} catch {
    $sc = $_.Exception.Response.StatusCode.value__
    $errBody = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Fail "User create [$sc]: $errBody`nBody: $createBody"
}
$userId = $created.id
if (-not $userId) { Fail "User create returned no id" }

# Confirm original password works
$origSess = $null
$origLogin = @{ username = "${TAG}u1"; password = 'orig1234'; warehouseId = $WH01; remember = $false } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $origLogin -ContentType 'application/json' -SessionVariable origSess | Out-Null
OK "Original password works"

# Reset
$resetBody = @{ newPassword = 'reset9999' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/users/$userId/reset-password" -Method POST -Body $resetBody -ContentType 'application/json' -WebSession $adm | Out-Null
OK "Reset password endpoint accepted"

# Old password no longer works
try {
    $bad = @{ username = "${TAG}u1"; password = 'orig1234'; warehouseId = $WH01; remember = $false } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $bad -ContentType 'application/json' | Out-Null
    Fail "Old password still accepted after reset"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 401) {
        Fail "Old password rejected with wrong status: $($_.Exception.Response.StatusCode.value__)"
    }
}
OK "Old password rejected after reset"

# New password works
$newSess = $null
$newLogin = @{ username = "${TAG}u1"; password = 'reset9999'; warehouseId = $WH01; remember = $false } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $newLogin -ContentType 'application/json' -SessionVariable newSess | Out-Null
$me = Invoke-RestMethod -Uri "$base/api/auth/me" -WebSession $newSess
if ($me.username -ne "${TAG}u1") { Fail "auth/me username=$($me.username)" }
OK "Login with new password works"

# Audit captured the reset
$au = Invoke-RestMethod -Uri "$base/api/audit?q=$TAG&take=20" -WebSession $adm
$resetRow = $au | Where-Object { $_.message -match 'Reset password' } | Select-Object -First 1
if (-not $resetRow) { Fail "No 'Reset password' audit row found" }
if ($resetRow.actionType -ne 'update') { Fail "Reset audit actionType=$($resetRow.actionType)" }
OK "Audit recorded the password reset"

# Reset for non-existent user → 404
try {
    Invoke-RestMethod -Uri "$base/api/users/00000000-0000-0000-0000-000000000000/reset-password" -Method POST -Body $resetBody -ContentType 'application/json' -WebSession $adm | Out-Null
    Fail "Reset on missing user should have 404'd"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) {
        Fail "Bad user reset returned $($_.Exception.Response.StatusCode.value__), expected 404"
    }
}
OK "Reset on missing user → 404"

# Reset by non-admin → 403
$opSess = Login "${TAG}u1" 'reset9999' $WH01
try {
    Invoke-RestMethod -Uri "$base/api/users/$userId/reset-password" -Method POST -Body $resetBody -ContentType 'application/json' -WebSession $opSess | Out-Null
    Fail "Non-admin reset should have 403'd"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 403) {
        Fail "Non-admin reset returned $($_.Exception.Response.StatusCode.value__), expected 403"
    }
}
OK "Non-admin cannot reset other users"

# Cleanup
Invoke-WebRequest -Uri "$base/api/users/$userId" -Method DELETE -WebSession $adm | Out-Null

# ============================================================================
# 4. masters.js exposes the Reset Password button hook
# ============================================================================
Step "masters.js: btn-reset-password is created on edit"
$mas = Get-Content -LiteralPath 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\masters.js' -Raw
foreach ($hook in @('btn-reset-password', 'ensureResetPasswordButton', '/reset-password')) {
    if ($mas -notmatch [regex]::Escape($hook)) { Fail "masters.js missing '$hook'" }
}
OK "masters.js has the Reset Password wiring"

# ============================================================================
# 5. Connection string is NOT in appsettings.Development.json
# ============================================================================
Step "appsettings.Development.json contains no Password / Server connection string"
$devText = Get-Content -LiteralPath $DEV_SETTINGS -Raw
if ($devText -match 'Password=' -or $devText -match 'Server=') {
    Fail "appsettings.Development.json still contains a connection string"
}
# Also assert user-secrets has it
$secret = (dotnet user-secrets list --project C:\dev\receivx\src\ReceivingOps.Web 2>&1 | Out-String)
if ($secret -notmatch 'ConnectionStrings:Default') {
    Fail "dotnet user-secrets does not contain ConnectionStrings:Default"
}
OK "Connection string moved to user-secrets; dev settings file is sanitized"

Cleanup
Write-Host "`n§15 #12 polish smoke passed." -ForegroundColor Green

} catch {
    Write-Host "UNCAUGHT: $($_.Exception.Message)" -ForegroundColor Red
    Cleanup
    exit 1
}
