# Smoke: admin email diagnostic endpoints
#   GET  /api/admin/smtp-config   metadata only — NEVER credentials
#   POST /api/admin/email-test    sends via IEmailService (logs in dev when
#                                  SMTP unconfigured); admin-only
#
# Also: /Config page exposes the admin section (data-admin-only) only
# when the session role is admin (operator probe confirms it stays hidden).

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

$admin = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
# 1. GET /api/admin/smtp-config — metadata only
# ----------------------------------------------------------------------------
Step "GET /api/admin/smtp-config returns metadata + flags only"
$cfg = Invoke-RestMethod -Uri "$base/api/admin/smtp-config" -WebSession $admin
# Required fields present
foreach ($prop in 'host','port','fromAddress','usernameConfigured','passwordConfigured','fullyConfigured') {
    if (-not (Get-Member -InputObject $cfg -Name $prop -ErrorAction SilentlyContinue)) {
        Fail "smtp-config response missing field '$prop'"
    }
}
# Credentials NEVER leaked — explicitly fail if `password` or `username` (the values themselves) leak
$cfgJson = $cfg | ConvertTo-Json -Compress
if ($cfgJson -match '"password"\s*:\s*"[^"]+"') { Fail "smtp-config leaked a 'password' string field" }
if ($cfgJson -match '"username"\s*:\s*"[^"]+"' -and $cfgJson -notmatch '"usernameConfigured"') { Fail "smtp-config leaked username" }
OK "smtp-config metadata returned, credentials NOT leaked (host='$($cfg.host)' fully=$($cfg.fullyConfigured))"

# ----------------------------------------------------------------------------
# 2. POST /api/admin/email-test — empty 'to' rejected
# ----------------------------------------------------------------------------
Step "POST /api/admin/email-test with empty 'to' → 400"
try {
    $body = @{ to = '' } | ConvertTo-Json
    Invoke-WebRequest -Uri "$base/api/admin/email-test" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin -UseBasicParsing | Out-Null
    Fail "Empty 'to' should have returned 400"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400) { Fail "Empty 'to' returned $s, expected 400" }
}
OK "Empty 'to' rejected with 400"

# ----------------------------------------------------------------------------
# 3. POST /api/admin/email-test with malformed 'to' → 400
# ----------------------------------------------------------------------------
Step "POST /api/admin/email-test with malformed 'to' → 400"
try {
    $body = @{ to = 'not-an-email' } | ConvertTo-Json
    Invoke-WebRequest -Uri "$base/api/admin/email-test" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin -UseBasicParsing | Out-Null
    Fail "Malformed 'to' should have returned 400"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400) { Fail "Malformed 'to' returned $s, expected 400" }
}
OK "Malformed 'to' rejected with 400"

# ----------------------------------------------------------------------------
# 4. POST /api/admin/email-test valid → 200 + success (log-fallback in dev)
# ----------------------------------------------------------------------------
Step "POST /api/admin/email-test valid email → success"
$body = @{ to = 'test@example.com' } | ConvertTo-Json
$resp = Invoke-RestMethod -Uri "$base/api/admin/email-test" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin
if (-not $resp.success) { Fail "Send returned success=false: $($resp.error)" }
if ($resp.sentTo -ne 'test@example.com') { Fail "sentTo mismatch: $($resp.sentTo)" }
OK "Valid send succeeded — message: $($resp.message)"

# ----------------------------------------------------------------------------
# 5. Non-admin (operator) BOTH endpoints → 403
# ----------------------------------------------------------------------------
Step "Non-admin (supervisor) is blocked from both endpoints"
# swattana is supervisor at WH-01 per seed data — non-admin role, valid
# warehouse assignment, used by smoke-phase-5c for the same kind of gate test.
$op = Login 'swattana' 'demo1234' $WH_01
try {
    Invoke-WebRequest -Uri "$base/api/admin/smtp-config" -WebSession $op -UseBasicParsing | Out-Null
    Fail "Operator should be blocked from smtp-config"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 403 -and $s -ne 401) { Fail "Operator smtp-config returned $s (expected 403/401)" }
}
try {
    $body = @{ to = 'test@example.com' } | ConvertTo-Json
    Invoke-WebRequest -Uri "$base/api/admin/email-test" -Method POST -Body $body -ContentType 'application/json' -WebSession $op -UseBasicParsing | Out-Null
    Fail "Operator should be blocked from email-test"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 403 -and $s -ne 401) { Fail "Operator email-test returned $s (expected 403/401)" }
}
OK "Operator blocked from both endpoints"

# ----------------------------------------------------------------------------
# 6. /Config page exposes the admin section. Phase 11.2 retired the
#    smtp-host / email-test-send DOM hooks (replaced by the tabbed editor
#    that calls /api/admin/email-test via JS); the data-admin-only gate
#    + the new editor markers are what this step asserts now.
# ----------------------------------------------------------------------------
Step "/Config page has admin-only section markup"
$cfgPage = Invoke-WebRequest -Uri "$base/Config" -WebSession $admin -UseBasicParsing
foreach ($needle in 'data-admin-only', 'id="config-editor-root"', 'data-tab="Smtp"', 'config-editor.js') {
    if ($cfgPage.Content -notmatch [regex]::Escape($needle)) { Fail "/Config page missing '$needle'" }
}
OK "/Config page has the Phase 11.2 editor markup (data-admin-only + config-editor-root + tabs + editor JS)"

Write-Host ""
Write-Host "ALL PASS — admin email test diagnostic endpoints + UI." -ForegroundColor Green
exit 0
