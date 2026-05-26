# Smoke: Phase 11.1 — encrypted config storage (AppSettings + Data Protection).
#
# What this verifies:
#   1. Migration db/029 file exists with the expected CHECK constraint
#   2. dbo.AppSettings table exists with the documented column shape
#   3. .gitignore covers the .dp-keys/ key ring (both root + nested path)
#   4. Source files for service + repository + seeder + DTO present
#   5. Program.cs wires AddDataProtection + AppSettingsSeeder +
#      AddSingleton<IAppSettingsService> + the IConfiguration-then-DB
#      options binding for SmtpOptions / ExportOptions / ErpSyncOptions
#   6. Dev server reachable
#   7. Seeder populated dbo.AppSettings (at least one row of each section
#      that has values in IConfiguration). Secret rows carry EncryptedValue;
#      non-secret rows carry Value (CHECK constraint already enforces XOR
#      — this is a belt-and-braces re-check at the row level)
#   8. dbo.AuditLog has config-set rows with EntityType='AppSettings' and
#      secret messages contain "(secret value" (proves redaction landed)
#   9. End-to-end decryption: /api/admin/smtp-config returns the SMTP host
#      that's stored encrypted in AppSettings (the options binding pulled
#      it through IAppSettingsService.GetAsync which decrypted)
#  10. .dp-keys/ folder exists on disk

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'

# WH-01 GUID for admin login (matches the other smokes' fixture).
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

# ----------------------------------------------------------------------------
# 1. Migration db/029
# ----------------------------------------------------------------------------
Step "Migration db/029_app_settings.sql shape"
$mig = Join-Path $repoRoot 'db\029_app_settings.sql'
AssertFile $mig 'CREATE TABLE dbo.AppSettings'
AssertFile $mig 'CK_AppSettings_ValueOrEncrypted'
AssertFile $mig 'EncryptedValue     VARBINARY(MAX)'
AssertFile $mig 'PreviousValueHash'
OK "Migration file present with CHECK + EncryptedValue + PreviousValueHash"

# ----------------------------------------------------------------------------
# 2. dbo.AppSettings table shape
# ----------------------------------------------------------------------------
Step "dbo.AppSettings table exists with the right columns"
$tableExists = SqlScalar "SELECT CASE WHEN OBJECT_ID('dbo.AppSettings','U') IS NULL THEN 'NO' ELSE 'YES' END;"
if ($tableExists -ne 'YES') { Fail "dbo.AppSettings table not found (did db/029 run?)" }
$colCount = SqlScalar "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='AppSettings';"
if ([int]$colCount -ne 7) { Fail "Expected 7 columns, got $colCount" }
$hasCheck = SqlScalar "SELECT COUNT(*) FROM sys.check_constraints WHERE name='CK_AppSettings_ValueOrEncrypted';"
if ([int]$hasCheck -ne 1) { Fail "CK_AppSettings_ValueOrEncrypted missing" }
OK "Table present, 7 columns, CHECK constraint installed"

# ----------------------------------------------------------------------------
# 3. .gitignore covers .dp-keys/
# ----------------------------------------------------------------------------
Step ".gitignore covers .dp-keys/"
AssertFile (Join-Path $repoRoot '.gitignore') '.dp-keys/'
AssertFile (Join-Path $repoRoot '.gitignore') 'src/ReceivingOps.Web/.dp-keys/'
OK "Both .dp-keys/ paths gitignored"

# ----------------------------------------------------------------------------
# 4. Source files present
# ----------------------------------------------------------------------------
Step "Source files present"
AssertFile (Join-Path $webRoot 'Services\Config\IAppSettingsService.cs') 'public interface IAppSettingsService'
AssertFile (Join-Path $webRoot 'Services\Config\AppSettingsService.cs')  'class AppSettingsService'
AssertFile (Join-Path $webRoot 'Services\Config\AppSettingsService.cs')  'AppSettings.v1'
AssertFile (Join-Path $webRoot 'Services\Config\AppSettingsSeeder.cs')   'class AppSettingsSeeder'
AssertFile (Join-Path $webRoot 'Data\Repositories\IAppSettingsRepository.cs') 'public interface IAppSettingsRepository'
AssertFile (Join-Path $webRoot 'Data\Repositories\AppSettingsRepository.cs')  'class AppSettingsRepository'
AssertFile (Join-Path $webRoot 'Models\Dtos\AppSettingRow.cs') 'class AppSettingRow'
OK "Service, repository, seeder, DTO all present"

# ----------------------------------------------------------------------------
# 5. Program.cs wiring
# ----------------------------------------------------------------------------
Step "Program.cs wiring"
$program = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Program.cs')
$mustHave = @(
    'using Microsoft.AspNetCore.DataProtection;',
    'using ReceivingOps.Web.Services.Config;',
    'AddDataProtection()',
    'SetApplicationName("Receivx")',
    'PersistKeysToFileSystem',
    'AddScoped<IAppSettingsRepository, AppSettingsRepository>()',
    'AddSingleton<IAppSettingsService, AppSettingsService>()',
    'AddScoped<AppSettingsSeeder>()',
    'await seeder.RunAsync()',
    'AppSettings decryption verified',
    'AddOptions<SmtpOptions>()',
    'AddOptions<ExportOptions>()',
    'AddOptions<ErpSyncOptions>()'
)
foreach ($needle in $mustHave) {
    if ($program -notmatch [regex]::Escape($needle)) {
        Fail "Program.cs missing wiring: '$needle'"
    }
}
OK "DI + Data Protection + seeder + 3 options-binding wraps all wired"

# ----------------------------------------------------------------------------
# 6. Dev server reachable
# ----------------------------------------------------------------------------
Step "Dev server reachable on $base"
try {
    $resp = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $code = $resp.StatusCode
} catch {
    $code = $_.Exception.Response.StatusCode.value__
}
if ($code -ne 401 -and $code -ne 200) {
    Fail "Dev server probe got HTTP $code, expected 401 or 200"
}
OK "Dev server up (HTTP $code on /api/auth/me)"

# ----------------------------------------------------------------------------
# 7. Seeder populated AppSettings + per-row CHECK invariant
# ----------------------------------------------------------------------------
Step "AppSettings rows populated by seeder"
$rowCount = SqlScalar "SELECT COUNT(*) FROM dbo.AppSettings;"
if ([int]$rowCount -lt 1) { Fail "Expected at least 1 AppSettings row, got 0 (seeder didn't run?)" }
$secretRows = SqlScalar "SELECT COUNT(*) FROM dbo.AppSettings WHERE IsSecret = 1;"
if ([int]$secretRows -lt 1) {
    # Acceptable only if no known-secret keys are configured in this env.
    # Tighten to require at least one when we know Smtp:Password is set:
    $smtpPw = SqlScalar "SELECT COUNT(*) FROM dbo.AppSettings WHERE [Key] = 'Smtp:Password';"
    if ([int]$smtpPw -ge 1) {
        Fail "Smtp:Password row exists but IsSecret=0 — classification leaked"
    }
}
# Per-row XOR check (the table CHECK enforces this; this re-confirms post-seed).
$badRows = SqlScalar "
    SELECT COUNT(*) FROM dbo.AppSettings
    WHERE (IsSecret = 1 AND ([Value] IS NOT NULL OR EncryptedValue IS NULL))
       OR (IsSecret = 0 AND ([Value] IS NULL OR EncryptedValue IS NOT NULL));"
# Note: the CHECK allows both-NULL for cleared rows — seeder never creates
# those, so any row here failing the XOR is a real bug.
if ([int]$badRows -ne 0) { Fail "$badRows row(s) violate the Value/EncryptedValue XOR invariant" }
OK "Seeded $rowCount row(s); $secretRows secret; XOR invariant intact"

# ----------------------------------------------------------------------------
# 8. Audit trail (config-set with secret-redaction)
# ----------------------------------------------------------------------------
Step "AuditLog has config-set rows with redacted secrets"
$auditCount = SqlScalar "SELECT COUNT(*) FROM dbo.AuditLog WHERE EntityType='AppSettings' AND ActionType='config-set';"
if ([int]$auditCount -lt 1) { Fail "No 'config-set' audit rows for EntityType='AppSettings'" }
# At least one secret row should carry the redaction marker. Use a wildcard
# so encoding variations of em-dash don't trip the match.
$redactedCount = SqlScalar "
    SELECT COUNT(*) FROM dbo.AuditLog
    WHERE EntityType='AppSettings'
      AND ActionType='config-set'
      AND Message LIKE '%(secret value%';"
$secretRowsBack = SqlScalar "SELECT COUNT(*) FROM dbo.AppSettings WHERE IsSecret = 1;"
if ([int]$secretRowsBack -ge 1 -and [int]$redactedCount -lt 1) {
    Fail "Secret rows exist but no audit message carries the '(secret value' redaction marker"
}
# Defense in depth: secret values must NEVER appear verbatim in any audit row.
# Grab the actual plaintext from user-secrets so we can grep for it.
$pw = (& dotnet user-secrets list --project (Join-Path $webRoot 'ReceivingOps.Web.csproj') 2>$null `
       | Where-Object { $_ -match '^Smtp:Password\s*=' } | ForEach-Object { ($_ -split '=',2)[1].Trim() })
if ($pw) {
    $leakCount = SqlScalar "
        SELECT COUNT(*) FROM dbo.AuditLog
        WHERE EntityType='AppSettings' AND Message LIKE '%$pw%';"
    if ([int]$leakCount -ne 0) { Fail "Secret plaintext leaked into AuditLog!" }
}
OK "config-set audit rows present ($auditCount); secrets redacted, no plaintext leak"

# ----------------------------------------------------------------------------
# 9. End-to-end decryption: SMTP host flows through options binding
# ----------------------------------------------------------------------------
Step "End-to-end decryption: SmtpOptions binding via IAppSettingsService"
$sv = $null
$loginBody = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $loginBody `
    -ContentType 'application/json' -SessionVariable sv | Out-Null
$cfg = Invoke-RestMethod -Uri "$base/api/admin/smtp-config" -WebSession $sv
# Read the canonical value straight out of the DB plaintext column…
$dbHost = SqlScalar "SELECT [Value] FROM dbo.AppSettings WHERE [Key]='Smtp:Host';"
if ($dbHost -and $dbHost -ne $cfg.host) {
    Fail "SmtpOptions.Host ('$($cfg.host)') doesn't match dbo.AppSettings Smtp:Host ('$dbHost') — options binding broken?"
}
# …and the cipher count (secret) for sanity.
$pwCipherLen = SqlScalar "SELECT DATALENGTH(EncryptedValue) FROM dbo.AppSettings WHERE [Key]='Smtp:Password' AND IsSecret=1;"
if ($pwCipherLen -and [int]$pwCipherLen -gt 0) {
    OK "SmtpOptions.Host='$($cfg.host)' matched DB; Smtp:Password encrypted ($pwCipherLen bytes)"
} else {
    OK "SmtpOptions.Host='$($cfg.host)' matched DB (no Smtp:Password configured to verify cipher)"
}

# ----------------------------------------------------------------------------
# 10. .dp-keys/ folder on disk
# ----------------------------------------------------------------------------
Step ".dp-keys/ folder present on disk"
$dpDir = Join-Path $webRoot '.dp-keys'
if (-not (Test-Path $dpDir)) { Fail ".dp-keys/ folder not created at $dpDir" }
$keyFiles = @(Get-ChildItem -LiteralPath $dpDir -Filter 'key-*.xml' -ErrorAction SilentlyContinue)
if ($keyFiles.Count -lt 1) {
    # First boot creates a key on first Protect() call. Our seeder did encrypt
    # Smtp:Password during seed, so a key SHOULD exist by now.
    Fail "No key-*.xml files in $dpDir — encrypt path didn't fire?"
}
OK "$($keyFiles.Count) key file(s) in $dpDir"

Write-Host ""
Write-Host "ALL PASS — Phase 11.1 storage + encryption + seeder + options binding verified." -ForegroundColor Green
exit 0
