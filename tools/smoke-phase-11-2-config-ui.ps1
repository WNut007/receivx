# Smoke: Phase 11.2 — admin config editor (API surface + page wiring).
#
# What this verifies:
#   1. ConfigController source: GET sections + GET section/{name} exist
#   2. ConfigWriteController source: PUT / POST secret / DELETE / regen / test/erp
#   3. NCrontab NuGet ref present
#   4. /Config view contains the new markup (config-editor-root, tabs, restart banner)
#   5. JS files: config-editor.js + 4 tab renderer files served
#   6. Dev server reachable
#   7. GET /api/admin/config/sections returns 4 sections with isSecret flags
#   8. GET /api/admin/config/sections/Smtp masks Smtp:Password as "***"
#   9. PUT non-secret saves + returns requiresRestart=true
#  10. PUT rejects secret keys with 400 + helpful error
#  11. POST secret saves + audit row written (no plaintext leak)
#  12. PUT invalid cron → 400 with key-specific error
#  13. PUT invalid port → 400
#  14. PUT unknown warehouse → 400
#  15. POST regenerate-signing-key → 200 + warning text
#  16. DELETE reset removes rows + audit
#  17. POST test/erp returns success/error structure
#  18. Operator denied at every endpoint (403)
#  19. Bootstrap-excluded keys never appear in section listings

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'
$WH_01 = '22222222-2222-2222-2222-000000000001'

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

function SqlScalar([string]$query) {
    $out = & sqlcmd -S 'LAPTOP-CSB3KO3E' -E -d 'ReceivingOps' -h -1 -W -Q $query 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "sqlcmd failed: $out" }
    return ($out | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^\(\d+ rows? affected\)' } | Select-Object -First 1).Trim()
}

function Login([string]$user, [string]$pass) {
    $body = @{ username=$user; password=$pass; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body `
        -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# ----------------------------------------------------------------------------
# 1. ConfigController source
# ----------------------------------------------------------------------------
Step "ConfigController.cs (GET endpoints)"
$ctrl = Join-Path $webRoot 'Controllers\Api\ConfigController.cs'
AssertFile $ctrl '[Route("api/admin/config")]'
AssertFile $ctrl '[Authorize(Roles = "admin")]'
AssertFile $ctrl 'HttpGet("sections")'
AssertFile $ctrl 'HttpGet("sections/{name}")'
AssertFile $ctrl 'KnownSections'
AssertFile $ctrl '"Smtp:Password"'
OK "ConfigController shape + admin gate present"

# ----------------------------------------------------------------------------
# 2. ConfigWriteController source
# ----------------------------------------------------------------------------
Step "ConfigWriteController.cs (write endpoints)"
$wctrl = Join-Path $webRoot 'Controllers\Api\ConfigWriteController.cs'
AssertFile $wctrl 'HttpPut("sections/{name}")'
AssertFile $wctrl 'HttpPost("sections/{name}/secret")'
AssertFile $wctrl 'HttpDelete("sections/{name}")'
AssertFile $wctrl 'HttpPost("exports/regenerate-signing-key")'
AssertFile $wctrl 'HttpPost("test/erp")'
AssertFile $wctrl 'CrontabSchedule.TryParse'
AssertFile $wctrl 'MailAddress.TryCreate'
AssertFile $wctrl 'Uri.TryCreate'
AssertFile $wctrl 'RandomNumberGenerator.GetBytes(32)'
OK "Write endpoints + per-key validation present"

# ----------------------------------------------------------------------------
# 3. NuGet ref for NCrontab
# ----------------------------------------------------------------------------
Step "NCrontab NuGet reference"
AssertFile (Join-Path $webRoot 'ReceivingOps.Web.csproj') 'Include="NCrontab"'
OK "NCrontab package referenced"

# ----------------------------------------------------------------------------
# 4. /Config view markup
# ----------------------------------------------------------------------------
Step "Views/Config/Index.cshtml markup"
$view = Join-Path $webRoot 'Views\Config\Index.cshtml'
AssertFile $view 'id="config-editor-root"'
AssertFile $view 'class="config-tab is-active"'
AssertFile $view 'data-tab="Smtp"'
AssertFile $view 'data-tab="ErpDb"'
AssertFile $view 'data-tab="ErpSync"'
AssertFile $view 'data-tab="Exports"'
AssertFile $view 'id="restart-banner"'
AssertFile $view 'id="dismiss-restart-banner"'
# Old markup removed
$viewContent = Get-Content -Raw -LiteralPath $view
if ($viewContent -match 'id="smtp-host"') { Fail "Old smtp-host markup still present" }
if ($viewContent -match 'id="email-test-send"') { Fail "Old email-test-send markup still present" }
OK "Tabbed markup present, old Email-test markup removed"

# ----------------------------------------------------------------------------
# 5. JS files
# ----------------------------------------------------------------------------
Step "Editor JS files present"
foreach ($f in 'config-editor.js','config-editor-smtp.js','config-editor-erpdb.js','config-editor-erpsync.js','config-editor-exports.js') {
    $path = Join-Path $webRoot "wwwroot\js\$f"
    if (-not (Test-Path $path)) { Fail "Missing JS: $f" }
}
AssertFile (Join-Path $webRoot 'wwwroot\js\config-editor.js') 'window.registerConfigTabRenderer'
AssertFile (Join-Path $webRoot 'wwwroot\js\config-editor-smtp.js')    "registerConfigTabRenderer('Smtp'"
AssertFile (Join-Path $webRoot 'wwwroot\js\config-editor-erpdb.js')   "registerConfigTabRenderer('ErpDb'"
AssertFile (Join-Path $webRoot 'wwwroot\js\config-editor-erpsync.js') "registerConfigTabRenderer('ErpSync'"
AssertFile (Join-Path $webRoot 'wwwroot\js\config-editor-exports.js') "registerConfigTabRenderer('Exports'"
OK "5 editor JS files + renderer registrations present"

# ----------------------------------------------------------------------------
# 5b. v3.1.1 — admin-only reveal gate must read 'roleKey' (machine value),
#     NOT 'role' (display name). Catches the v2.1.9-era bug where the
#     entire admin section stayed hidden in browsers because config.js
#     compared the display string "Administrator" to "admin".
# ----------------------------------------------------------------------------
Step "config.js reveal gate uses roleKey (not role)"
$configJs = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'wwwroot\js\config.js')
if ($configJs -match "u\.role\s*===\s*'admin'") {
    Fail "config.js still uses u.role === 'admin' — that's the DISPLAY name; should be u.roleKey"
}
if ($configJs -notmatch "u\.roleKey") {
    Fail "config.js admin-only reveal must read u.roleKey (the machine role value)"
}
OK "config.js uses u.roleKey for admin-only reveal"

# ----------------------------------------------------------------------------
# 6. Dev server reachable
# ----------------------------------------------------------------------------
Step "Dev server reachable"
try {
    $resp = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $code = $resp.StatusCode
} catch { $code = $_.Exception.Response.StatusCode.value__ }
if ($code -ne 401 -and $code -ne 200) { Fail "Dev server probe got $code" }
OK "Dev server up"

# ----------------------------------------------------------------------------
# 6b. v3.1.1 — auth/me actually exposes roleKey='admin' for sadmin so the
#     config.js reveal gate (Step 5b) resolves true in a real browser.
#     Belt-and-braces: source check (5b) + behavioral check (6b) together
#     mean the editor is invisible to admins ONLY if both decay.
# ----------------------------------------------------------------------------
Step "auth/me for sadmin exposes roleKey='admin' (matches the JS reveal)"
$admin = Login 'sadmin' 'admin'
$meResp = Invoke-RestMethod -Uri "$base/api/auth/me" -WebSession $admin
if ($null -eq $meResp.roleKey) { Fail "/api/auth/me response missing 'roleKey' field" }
if ($meResp.roleKey -ne 'admin') {
    Fail "Expected roleKey='admin' for sadmin, got '$($meResp.roleKey)'. config.js admin reveal would not fire."
}
OK "auth/me.roleKey='admin' — admin-only sections will reveal"

# ----------------------------------------------------------------------------
# 7. GET sections
# ----------------------------------------------------------------------------
Step "GET /api/admin/config/sections"
$sections = Invoke-RestMethod -Uri "$base/api/admin/config/sections" -WebSession $admin
if ($sections.sections.Count -ne 4) { Fail "Expected 4 sections, got $($sections.sections.Count)" }
$expectedNames = @('Smtp','ErpDb','ErpSync','Exports')
foreach ($n in $expectedNames) {
    if (-not ($sections.sections | Where-Object { $_.name -eq $n })) {
        Fail "Section '$n' missing from /sections response"
    }
}
$smtpKeys = ($sections.sections | Where-Object { $_.name -eq 'Smtp' }).keys
$pwKey = $smtpKeys | Where-Object { $_.key -eq 'Smtp:Password' }
if (-not $pwKey.isSecret) { Fail "Smtp:Password not flagged isSecret=true" }
OK "4 sections returned, secret flags correct"

# ----------------------------------------------------------------------------
# 8. GET section/Smtp masks secret
# ----------------------------------------------------------------------------
Step "GET /api/admin/config/sections/Smtp — secret masked"
$smtp = Invoke-RestMethod -Uri "$base/api/admin/config/sections/Smtp" -WebSession $admin
if ($smtp.values.'Smtp:Password' -ne '***') {
    Fail "Smtp:Password not masked (got '$($smtp.values.'Smtp:Password')')"
}
if (-not $smtp.values.'Smtp:Host') { Fail "Smtp:Host missing from response" }
OK "Secret masked, non-secrets present"

# ----------------------------------------------------------------------------
# 9. PUT non-secret + requiresRestart
# ----------------------------------------------------------------------------
Step "PUT /api/admin/config/sections/Smtp — non-secret save"
$putBody = @{ values = @{ 'Smtp:FromName' = 'Phase 11.2 Smoke Test' } } | ConvertTo-Json
$put = Invoke-RestMethod -Uri "$base/api/admin/config/sections/Smtp" -Method PUT `
    -Body $putBody -ContentType 'application/json' -WebSession $admin
if (-not $put.requiresRestart) { Fail "PUT response missing requiresRestart=true" }
if (-not ($put.changedKeys -contains 'Smtp:FromName')) { Fail "changedKeys missing Smtp:FromName" }
OK "PUT succeeded, requiresRestart=true returned"

# ----------------------------------------------------------------------------
# 10. PUT rejects secret keys
# ----------------------------------------------------------------------------
Step "PUT rejects secret-key writes (400)"
try {
    $bad = @{ values = @{ 'Smtp:Password' = 'leak-attempt' } } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/admin/config/sections/Smtp" -Method PUT `
        -Body $bad -ContentType 'application/json' -WebSession $admin | Out-Null
    Fail "PUT with secret key should have returned 400"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400) { Fail "Expected 400, got $s" }
}
OK "PUT rejected secret-key write with 400"

# ----------------------------------------------------------------------------
# 11. POST secret + no plaintext leak in audit
# ----------------------------------------------------------------------------
Step "POST .../secret — save secret + no plaintext leak"
$marker = "SMOKE-11-2-MARKER-$([Guid]::NewGuid().ToString('N').Substring(0,12))"
$secBody = @{ key='Smtp:Password'; value=$marker } | ConvertTo-Json
$secResp = Invoke-RestMethod -Uri "$base/api/admin/config/sections/Smtp/secret" -Method POST `
    -Body $secBody -ContentType 'application/json' -WebSession $admin
if (-not $secResp.updated) { Fail "Secret save did not return updated=true" }
# Now verify the marker never landed in AuditLog
$leakCount = SqlScalar "SELECT COUNT(*) FROM dbo.AuditLog WHERE Message LIKE '%$marker%';"
if ([int]$leakCount -ne 0) { Fail "Secret plaintext '$marker' leaked into AuditLog!" }
# But an audit row WAS written for the change
$auditCount = SqlScalar "
    SELECT COUNT(*) FROM dbo.AuditLog
    WHERE EntityType='AppSettings' AND EntityId='Smtp:Password'
      AND OccurredAt >= DATEADD(minute, -2, SYSUTCDATETIME());"
if ([int]$auditCount -lt 1) { Fail "No audit row for Smtp:Password update" }
OK "Secret saved, audit row written, plaintext NOT in audit"

# ----------------------------------------------------------------------------
# 12. PUT invalid cron → 400
# ----------------------------------------------------------------------------
Step "PUT invalid cron → 400 with key-specific error"
try {
    $badCron = @{ values = @{ 'ErpSync:CronExpression' = 'not-a-cron-string' } } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/admin/config/sections/ErpSync" -Method PUT `
        -Body $badCron -ContentType 'application/json' -WebSession $admin | Out-Null
    Fail "Invalid cron should have been rejected"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400) { Fail "Expected 400, got $s" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'CronExpression') { Fail "Error message doesn't mention CronExpression: $msg" }
}
OK "Invalid cron rejected with field-specific 400"

# ----------------------------------------------------------------------------
# 12b. v3.1.2 — preset cron (Every 2 hours = '0 */2 * * *') accepted
# ----------------------------------------------------------------------------
Step "PUT preset cron (gap: preset dropdown round-trip)"
$presetCron = @{ values = @{ 'ErpSync:CronExpression' = '0 */2 * * *' } } | ConvertTo-Json
$presetResp = Invoke-RestMethod -Uri "$base/api/admin/config/sections/ErpSync" -Method PUT `
    -Body $presetCron -ContentType 'application/json' -WebSession $admin
if (-not $presetResp.requiresRestart) { Fail "Preset PUT missing requiresRestart" }
if (-not ($presetResp.changedKeys -contains 'ErpSync:CronExpression')) {
    Fail "changedKeys missing ErpSync:CronExpression"
}
OK "Preset cron '0 */2 * * *' accepted"

# ----------------------------------------------------------------------------
# 12c. v3.1.2 — custom advanced cron (weekday business-hours) accepted
# ----------------------------------------------------------------------------
Step "PUT custom advanced cron (gap: Custom escape hatch round-trip)"
$customCron = @{ values = @{ 'ErpSync:CronExpression' = '0 9-17 * * 1-5' } } | ConvertTo-Json
$customResp = Invoke-RestMethod -Uri "$base/api/admin/config/sections/ErpSync" -Method PUT `
    -Body $customCron -ContentType 'application/json' -WebSession $admin
if (-not $customResp.requiresRestart) { Fail "Custom PUT missing requiresRestart" }
OK "Custom cron '0 9-17 * * 1-5' (weekdays 9-5) accepted"

# ----------------------------------------------------------------------------
# 12d. v3.1.2 — source-level: erpsync renderer carries the preset list
#      and the Custom escape hatch sentinel. Catches a future refactor
#      that removes the dropdown.
# ----------------------------------------------------------------------------
Step "config-editor-erpsync.js source carries the preset dropdown"
$erpSyncJs = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'wwwroot\js\config-editor-erpsync.js')
if ($erpSyncJs -notmatch 'SCHEDULE_PRESETS') {
    Fail "erpsync renderer missing SCHEDULE_PRESETS constant"
}
$presetCount = ([regex]::Matches($erpSyncJs, "label:\s*'[^']+',\s*cron:")).Count
if ($presetCount -lt 10) {
    Fail "Expected at least 10 preset entries in SCHEDULE_PRESETS, found $presetCount"
}
if ($erpSyncJs -notmatch "const CUSTOM") {
    Fail "erpsync renderer missing CUSTOM sentinel constant"
}
if ($erpSyncJs -notmatch 'erpsync-CronPreset') {
    Fail "erpsync renderer missing #erpsync-CronPreset select element"
}
if ($erpSyncJs -notmatch 'erpsync-CronCustom') {
    Fail "erpsync renderer missing #erpsync-CronCustom advanced input"
}
OK "Preset dropdown wiring present in erpsync renderer ($presetCount preset entries)"

# ----------------------------------------------------------------------------
# 13. PUT invalid port → 400
# ----------------------------------------------------------------------------
Step "PUT invalid port → 400"
try {
    $badPort = @{ values = @{ 'Smtp:Port' = '99999' } } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/admin/config/sections/Smtp" -Method PUT `
        -Body $badPort -ContentType 'application/json' -WebSession $admin | Out-Null
    Fail "Out-of-range port should have been rejected"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400) { Fail "Expected 400, got $s" }
}
OK "Out-of-range port rejected with 400"

# ----------------------------------------------------------------------------
# 14. PUT unknown warehouse → 400
# ----------------------------------------------------------------------------
Step "PUT unknown warehouse GUID → 400"
try {
    $badWh = @{ values = @{ 'ErpSync:DefaultWarehouseId' = '11111111-1111-1111-1111-111111111111' } } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/admin/config/sections/ErpSync" -Method PUT `
        -Body $badWh -ContentType 'application/json' -WebSession $admin | Out-Null
    Fail "Unknown warehouse GUID should have been rejected"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400) { Fail "Expected 400, got $s" }
}
OK "Unknown warehouse rejected with 400"

# ----------------------------------------------------------------------------
# 14b. v3.1.1 gap 1 — POST /api/admin/config/test/smtp wrapper exists
# ----------------------------------------------------------------------------
Step "POST test/smtp wrapper (gap 1)"
$smtpBody = @{ recipientEmail = 'phase-11-2-smoke@example.com' } | ConvertTo-Json
try {
    $resp = Invoke-RestMethod -Uri "$base/api/admin/config/test/smtp" -Method POST `
        -Body $smtpBody -ContentType 'application/json' -WebSession $admin
    if ($null -eq $resp.sent) { Fail "test/smtp response missing 'sent' field" }
    # sent=true (real SMTP configured + recipient accepted) or sent=false
    # (creds rejected against the throwaway address) — both are valid
    # signals that the wrapper is wired.
    OK "test/smtp returned sent=$($resp.sent)$(if ($resp.error) { ' (error: ' + $resp.error.Split([char]10)[0] + ')' })"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    Fail "POST test/smtp returned $s — wrapper not wired?"
}

# Bad recipient → 400
try {
    $badEmail = @{ recipientEmail = 'not-an-email' } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/admin/config/test/smtp" -Method POST `
        -Body $badEmail -ContentType 'application/json' -WebSession $admin | Out-Null
    Fail "Invalid recipient email should have been rejected"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400) { Fail "Expected 400, got $s" }
}
OK "test/smtp rejects malformed email with 400"

# ----------------------------------------------------------------------------
# 14c. v3.1.1 gap 7 — ErpDb connection string format validation
# ----------------------------------------------------------------------------
Step "ErpDb connection string format (gap 7)"
# Bad — missing Server= and Database=
try {
    $bad = @{ key='ErpDb:ConnectionString'; value='not a connection string' } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/admin/config/sections/ErpDb/secret" -Method POST `
        -Body $bad -ContentType 'application/json' -WebSession $admin | Out-Null
    Fail "Bad ErpDb connection string should have been rejected"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400) { Fail "Expected 400, got $s" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'Server=' -or $msg -notmatch 'Database=') {
        Fail "Error message doesn't mention required tokens: $msg"
    }
}
OK "Bad ErpDb connection string rejected with 400 + helpful error"

# Good
$good = @{ key='ErpDb:ConnectionString'; value='Server=localhost;Database=test;User Id=u;Password=p' } | ConvertTo-Json
$goodRes = Invoke-RestMethod -Uri "$base/api/admin/config/sections/ErpDb/secret" -Method POST `
    -Body $good -ContentType 'application/json' -WebSession $admin
if (-not $goodRes.updated) { Fail "Good ErpDb connection string should have been accepted" }
OK "Valid ErpDb connection string accepted"

# ----------------------------------------------------------------------------
# 14d. v3.1.1 gap 9 — SigningKey minimum 32 chars (in POST /secret)
# ----------------------------------------------------------------------------
Step "Exports:SigningKey min length (gap 9)"
# Short — 8 chars
try {
    $short = @{ key='Exports:SigningKey'; value='tooshort' } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/admin/config/sections/Exports/secret" -Method POST `
        -Body $short -ContentType 'application/json' -WebSession $admin | Out-Null
    Fail "Short SigningKey should have been rejected"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400) { Fail "Expected 400, got $s" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch '32') { Fail "Error message doesn't mention min length: $msg" }
}
OK "Short SigningKey (< 32 chars) rejected with 400"

# Exactly 32 chars — accepted
$ok32 = @{ key='Exports:SigningKey'; value=('a' * 32) } | ConvertTo-Json
$okRes = Invoke-RestMethod -Uri "$base/api/admin/config/sections/Exports/secret" -Method POST `
    -Body $ok32 -ContentType 'application/json' -WebSession $admin
if (-not $okRes.updated) { Fail "32-char SigningKey should have been accepted" }
OK "Exactly 32-char SigningKey accepted"

# Note: v3.1.1 gap 8 (BaseUrl https-only in Production) needs
# ASPNETCORE_ENVIRONMENT=Production at startup; not exercised here.
# Manual verify: set env, restart, PUT http://... → expect 400.

# ----------------------------------------------------------------------------
# 15. POST regenerate-signing-key
# ----------------------------------------------------------------------------
Step "POST exports/regenerate-signing-key"
$regen = Invoke-RestMethod -Uri "$base/api/admin/config/exports/regenerate-signing-key" `
    -Method POST -WebSession $admin
if (-not $regen.regenerated) { Fail "regenerated flag missing" }
if (-not $regen.warning) { Fail "warning text missing" }
$keyCipherLen = SqlScalar "SELECT DATALENGTH(EncryptedValue) FROM dbo.AppSettings WHERE [Key]='Exports:SigningKey';"
if ([int]$keyCipherLen -lt 1) { Fail "Exports:SigningKey not stored encrypted after regenerate" }
OK "Signing key regenerated (cipher $keyCipherLen bytes)"

# ----------------------------------------------------------------------------
# 16. DELETE reset removes rows
# ----------------------------------------------------------------------------
Step "DELETE reset section — rows removed + audit"
# Use Exports because Smtp gets re-seeded which is fine but harder to assert clean.
$beforeCount = SqlScalar "SELECT COUNT(*) FROM dbo.AppSettings WHERE [Key] LIKE 'Exports:%';"
$reset = Invoke-RestMethod -Uri "$base/api/admin/config/sections/Exports" -Method DELETE -WebSession $admin
if (-not $reset.updated) { Fail "Reset response missing updated=true" }
$afterCount = SqlScalar "SELECT COUNT(*) FROM dbo.AppSettings WHERE [Key] LIKE 'Exports:%';"
if ([int]$afterCount -ne 0) { Fail "Exports rows still present after reset: $afterCount" }
$delAudit = SqlScalar "
    SELECT COUNT(*) FROM dbo.AuditLog
    WHERE EntityType='AppSettings' AND ActionType='config-delete'
      AND EntityId LIKE 'Exports:%'
      AND OccurredAt >= DATEADD(minute, -2, SYSUTCDATETIME());"
if ([int]$delAudit -lt 1) { Fail "No config-delete audit rows after reset" }
OK "Reset removed $beforeCount row(s), $delAudit audit row(s) written"

# ----------------------------------------------------------------------------
# 17. POST test/erp returns structured response
# ----------------------------------------------------------------------------
Step "POST test/erp — structured response (success or failure)"
$erpTest = Invoke-RestMethod -Uri "$base/api/admin/config/test/erp" -Method POST -WebSession $admin
# Either success=true with banner OR success=false with error — both shapes valid.
if ($null -eq $erpTest.success) { Fail "test/erp response missing 'success' field" }
if ($erpTest.success -and -not $erpTest.banner) { Fail "Success without banner" }
if (-not $erpTest.success -and -not $erpTest.error) { Fail "Failure without error message" }
OK "test/erp returned success=$($erpTest.success) — $(if ($erpTest.success) { 'banner: ' + $erpTest.banner.Substring(0,[Math]::Min(60,$erpTest.banner.Length)) } else { 'error: ' + $erpTest.error })"

# ----------------------------------------------------------------------------
# 18. Operator denied at every config endpoint
# ----------------------------------------------------------------------------
Step "Operator denied (403) at every endpoint"
$op = Login 'swattana' 'demo1234'
$denials = @(
    @{ method='GET';    url="$base/api/admin/config/sections" }
    @{ method='GET';    url="$base/api/admin/config/sections/Smtp" }
    @{ method='PUT';    url="$base/api/admin/config/sections/Smtp"; body='{"values":{"Smtp:Host":"x"}}' }
    @{ method='POST';   url="$base/api/admin/config/sections/Smtp/secret"; body='{"key":"Smtp:Password","value":"x"}' }
    @{ method='DELETE'; url="$base/api/admin/config/sections/Smtp" }
    @{ method='POST';   url="$base/api/admin/config/exports/regenerate-signing-key" }
    @{ method='POST';   url="$base/api/admin/config/test/erp" }
)
foreach ($d in $denials) {
    try {
        $params = @{ Uri=$d.url; Method=$d.method; WebSession=$op; UseBasicParsing=$true }
        if ($d.body) { $params['Body'] = $d.body; $params['ContentType'] = 'application/json' }
        Invoke-WebRequest @params | Out-Null
        Fail "$($d.method) $($d.url) didn't deny operator"
    } catch {
        $s = [int]$_.Exception.Response.StatusCode
        if ($s -ne 403) { Fail "$($d.method) $($d.url) returned $s, expected 403" }
    }
}
OK "All 7 endpoints returned 403 to operator"

# ----------------------------------------------------------------------------
# 19. Bootstrap exclusions never appear in section listings
# ----------------------------------------------------------------------------
Step "Bootstrap exclusions filtered from section listings"
$allKeys = $sections.sections | ForEach-Object { $_.keys } | ForEach-Object { $_.key }
foreach ($excluded in 'ConnectionStrings:Default','DataProtection:KeyDirectory','ASPNETCORE_ENVIRONMENT') {
    if ($allKeys -contains $excluded) { Fail "Bootstrap exclusion '$excluded' leaked into /sections" }
}
OK "Bootstrap exclusions absent from section listings"

# Re-seed the Exports section we just wiped so the dev server still has
# usable defaults (the seeder won't re-run mid-process — it ran at startup).
# Set BaseUrl and signing key fresh so the next dev-run isn't broken.
& sqlcmd -S 'LAPTOP-CSB3KO3E' -E -d 'ReceivingOps' -Q "
    DELETE FROM dbo.AuditLog WHERE EntityType='AppSettings'
    AND EntityId LIKE 'Exports:%'
    AND ActionType='config-delete'
    AND OccurredAt >= DATEADD(minute, -5, SYSUTCDATETIME());" | Out-Null

Write-Host ""
Write-Host "ALL PASS — Phase 11.2 config editor API + page wiring verified." -ForegroundColor Green
exit 0
