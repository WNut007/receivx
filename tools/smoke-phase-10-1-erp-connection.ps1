# Smoke: Phase 10.1 — ERP SQL connection wiring + Hangfire stub.
#
# This is a SOURCE-LEVEL + CONNECTIVITY smoke. The actual Hangfire-enqueue
# path is exercised by 10.4's smoke (which adds the manual-trigger endpoint).
# At 10.1 we only assert:
#
#   1. New C# types exist with the expected names
#      (IErpDbConnectionFactory, ErpSqlConnectionFactory, ErpSyncOptions,
#       ErpSyncJob)
#   2. Program.cs wires the factory + options + job + erp-sync queue
#   3. Program.cs has the conditional recurring-registration block
#   4. appsettings.json declares the ErpSync section with the documented keys
#   5. The dev server is up (HTTP 401 on /api/auth/me proves it)
#   6. ErpDb connectivity — IF the connection string is set in user-secrets,
#      try a direct sqlcmd SELECT @@VERSION against the ERP host. Skip
#      cleanly if not set (so the smoke passes on a fresh checkout).
#
# Why no Hangfire-enqueue assertion here: the manual-trigger HTTP endpoint
# is 10.4 scope. Source-level + connectivity is enough for 10.1 to prove
# the wiring; behavioral end-to-end runs in 10.4.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Skip($m) { Write-Host "SKIP: $m" -ForegroundColor DarkYellow }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function AssertFile([string]$path, [string]$mustContain) {
    if (-not (Test-Path $path)) { Fail "Expected file not found: $path" }
    $body = Get-Content -Raw -LiteralPath $path
    if ($body -notmatch [regex]::Escape($mustContain)) {
        Fail "File $([System.IO.Path]::GetFileName($path)) missing token '$mustContain'"
    }
}

# ----------------------------------------------------------------------------
# 1. Factory interface + impl exist
# ----------------------------------------------------------------------------
Step "Factory interface + impl exist"
AssertFile (Join-Path $webRoot 'Data\IErpDbConnectionFactory.cs') 'public interface IErpDbConnectionFactory'
AssertFile (Join-Path $webRoot 'Data\IErpDbConnectionFactory.cs') 'IDbConnection Create();'
AssertFile (Join-Path $webRoot 'Data\ErpSqlConnectionFactory.cs') 'public class ErpSqlConnectionFactory : IErpDbConnectionFactory'
AssertFile (Join-Path $webRoot 'Data\ErpSqlConnectionFactory.cs') 'ErpDb:ConnectionString'
OK "IErpDbConnectionFactory + ErpSqlConnectionFactory present"

# ----------------------------------------------------------------------------
# 2. Options + Job stub
# ----------------------------------------------------------------------------
Step "ErpSyncOptions + ErpSyncJob"
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncOptions.cs') 'public bool Enabled'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncOptions.cs') 'public string CronExpression'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncJob.cs') 'public class ErpSyncJob'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncJob.cs') '[DisableConcurrentExecution(timeoutInSeconds: 600)]'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncJob.cs') '[Queue("erp-sync")]'
# (The 10.1 stub body was SELECT @@VERSION; 10.2 replaced it with the
# service call. Assertion deliberately stops at the attributes — the
# behavioral check moved to smoke-phase-10-2/10-3.)
OK "ErpSyncOptions defaults + ErpSyncJob attributes present"

# ----------------------------------------------------------------------------
# 3. Program.cs wires the new components
# ----------------------------------------------------------------------------
Step "Program.cs wiring"
$program = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Program.cs')
$mustHave = @(
    'using ReceivingOps.Web.Services.ErpSync;',
    'AddScoped<IErpDbConnectionFactory, ErpSqlConnectionFactory>()',
    # Phase 11.1 — ErpSyncOptions binding moved from
    # `Configure<ErpSyncOptions>(...)` to `AddOptions<ErpSyncOptions>()`
    # with a two-stage Configure (IConfiguration defaults, then DB overlay
    # via IAppSettingsService). Either pattern is acceptable wiring.
    'AddOptions<ErpSyncOptions>()',
    'AddScoped<ErpSyncJob>',
    '"erp-sync"',
    'RecurringJob.AddOrUpdate<ErpSyncJob>',
    'RecurringJob.RemoveIfExists("erp-sync-hourly")'
)
foreach ($needle in $mustHave) {
    if ($program -notmatch [regex]::Escape($needle)) {
        Fail "Program.cs missing wiring: '$needle'"
    }
}
OK "Factory + options + job + queue + conditional recurring all wired"

# ----------------------------------------------------------------------------
# 4. appsettings.json declares ErpSync section
# ----------------------------------------------------------------------------
Step "appsettings.json declares ErpSync section"
$settings = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'appsettings.json') | ConvertFrom-Json
if (-not $settings.ErpSync) { Fail "appsettings.json missing 'ErpSync' section" }
if ($null -eq $settings.ErpSync.Enabled) { Fail "ErpSync.Enabled key missing" }
if (-not $settings.ErpSync.CronExpression) { Fail "ErpSync.CronExpression key missing" }
if ($settings.ErpSync.Enabled -ne $false) {
    Fail "ErpSync.Enabled must default to false in committed appsettings.json (got: $($settings.ErpSync.Enabled))"
}
OK "ErpSync section present with Enabled=false default"

# ----------------------------------------------------------------------------
# 5. Dev server reachable
# ----------------------------------------------------------------------------
Step "Dev server reachable on $base"
try {
    $resp = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET `
        -UseBasicParsing -ErrorAction Stop
    $code = $resp.StatusCode
} catch {
    $code = $_.Exception.Response.StatusCode.value__
}
if ($code -ne 401 -and $code -ne 200) {
    Fail "Dev server probe got HTTP $code, expected 401 (anonymous) or 200"
}
OK "Dev server is up (HTTP $code on /api/auth/me)"

# ----------------------------------------------------------------------------
# 6. ErpDb connectivity — skip cleanly if not configured
# ----------------------------------------------------------------------------
Step "ErpDb connectivity"
$secretsList = & dotnet user-secrets list --project (Join-Path $webRoot 'ReceivingOps.Web.csproj') 2>$null
$hasErpDb = $secretsList | Where-Object { $_ -match '^ErpDb:ConnectionString' }
if (-not $hasErpDb) {
    Skip "ErpDb:ConnectionString not set in user-secrets — connectivity check skipped (dev-safe)"
} else {
    # Extract Server + creds from the connection string. dotnet user-secrets
    # echoes "Key = Value" — split on the first '=' and trim. The value is
    # a SqlClient-format conn string; parse just enough to feed sqlcmd.
    $cs = ($hasErpDb -split '=', 2)[1].Trim()
    $kv = @{}
    foreach ($pair in $cs -split ';') {
        if ($pair -match '^\s*([^=]+)=(.*)$') { $kv[$matches[1].Trim()] = $matches[2].Trim() }
    }
    $erpServer = $kv['Server']
    $erpDb     = $kv['Database']
    $erpUser   = $kv['User Id']
    $erpPass   = $kv['Password']
    if (-not $erpServer -or -not $erpUser -or -not $erpPass) {
        Fail "Connection string in user-secrets is missing Server / User Id / Password"
    }
    # Fast TCP probe before sqlcmd — Test-NetConnection has a 4s default timeout;
    # a raw TcpClient with 2s wins on dev boxes where the ERP host is behind a
    # corporate VPN that may not be connected right now. Skip the SELECT with a
    # warning (not a failure) when the port is closed — this is the prod-checklist
    # "firewall/VPN to 103.13.229.21" item, not a code defect.
    # $host is reserved (PS automatic var for the runspace host) — use $tcpHost.
    $tcpHost = $erpServer
    if ($tcpHost -match '^(.+?)\\') { $tcpHost = $matches[1] }   # strip "host\instance"
    if ($tcpHost -match '^(.+?),\d+$') { $tcpHost = $matches[1] } # strip explicit ",port"
    $port = if ($erpServer -match ',(\d+)$') { [int]$matches[1] } else { 1433 }
    $tcp = New-Object System.Net.Sockets.TcpClient
    $async = $tcp.BeginConnect($tcpHost, $port, $null, $null)
    $reachable = $async.AsyncWaitHandle.WaitOne(2000)
    if ($reachable) {
        try { $tcp.EndConnect($async) } catch { $reachable = $false }
    }
    $tcp.Close()
    if (-not $reachable) {
        Skip "TCP probe to ${tcpHost}:${port} timed out (2s) — likely firewall/VPN. Code wiring verified; connectivity check skipped."
        Write-Host ""
        Write-Host "ALL PASS — Phase 10.1 wiring verified (ERP connectivity skipped — see SKIP above)." -ForegroundColor Green
        exit 0
    }
    # sqlcmd -C trusts the cert per the conn string's TrustServerCertificate flag;
    # -l 5 caps login wait so a dead host doesn't hang the smoke for 30s.
    $verRaw = & sqlcmd -S $erpServer -d $erpDb -U $erpUser -P $erpPass -C -l 5 `
        -Q "SET NOCOUNT ON; SELECT @@VERSION;" -W -h -1 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "sqlcmd to ERP host $erpServer failed (exit $LASTEXITCODE). Output: $($verRaw -join ' ')"
    }
    # @@VERSION returns a multi-line banner; first non-empty line is the SQL version.
    $banner = ($verRaw | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1).Trim()
    if (-not $banner) {
        Fail "sqlcmd returned no version banner from $erpServer"
    }
    OK "ERP DB reachable at $erpServer — banner: $($banner.Substring(0, [Math]::Min(80, $banner.Length)))..."
}

Write-Host ""
Write-Host "ALL PASS — Phase 10.1 wiring + connectivity verified." -ForegroundColor Green
exit 0
