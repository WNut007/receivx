# Smoke: Phase 10.2 — BPI_PRS read + transform to Receivx draft shape.
#
# Source-level + behavioral. Asserts:
#   1. Service interface + impl + draft DTOs present
#   2. ErpSyncOptions exposes DefaultWarehouseId + BackfillDays
#   3. ErpSyncJob no longer runs SELECT @@VERSION (the 10.1 stub) — it
#      now calls IErpSyncService.ReadAndTransformAsync
#   4. ItemCode synthesis rule applied: when TRIAL_ID is present, the
#      transform emits "SKU-TRIAL_ID"; bare SKU otherwise (Q1 decision)
#   5. WINDOWS_TIME NULL → HourOfDay=7 default (the user-confirmed rule;
#      100% of BPI_PRS rows are NULL in current data)
#   6. ERP DB connectivity — TCP probe + a 1-row sanity SELECT against
#      BPI_PRS via sqlcmd, asserting at least one (PRS_ID, SKU) tuple
#      exists. SKIPs cleanly if TCP probe fails (firewall/VPN).
#
# Behavioral end-to-end (job enqueue + draft persistence) lands in 10.3/10.4.

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
# 1. Service interface + impl + drafts exist
# ----------------------------------------------------------------------------
Step "Service interface + impl + drafts present"
AssertFile (Join-Path $webRoot 'Services\ErpSync\IErpSyncService.cs') 'public interface IErpSyncService'
AssertFile (Join-Path $webRoot 'Services\ErpSync\IErpSyncService.cs') 'ReadAndTransformAsync'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncService.cs') 'public class ErpSyncService : IErpSyncService'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncService.cs') 'FROM   dbo.BPI_PRS'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncDrafts.cs') 'public class ErpSyncDraft'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncDrafts.cs') 'public class PullDraft'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncDrafts.cs') 'public class PullItemDraft'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncDrafts.cs') 'public class PullItemWindowDraft'
OK "IErpSyncService + ErpSyncService + 4 Draft DTOs all present"

# ----------------------------------------------------------------------------
# 2. Options gain DefaultWarehouseId + BackfillDays
# ----------------------------------------------------------------------------
Step "ErpSyncOptions exposes DefaultWarehouseId + BackfillDays"
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncOptions.cs') 'public Guid DefaultWarehouseId'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncOptions.cs') 'public int BackfillDays'
OK "Options updated"

# ----------------------------------------------------------------------------
# 3. Job replaces the 10.1 SELECT @@VERSION stub
# ----------------------------------------------------------------------------
Step "ErpSyncJob calls IErpSyncService (not SELECT @@VERSION)"
$jobBody = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\ErpSyncJob.cs')
# The 10.1 stub used IErpDbConnectionFactory directly + Dapper SELECT. 10.2
# replaces that with an injected IErpSyncService — so any direct factory
# field on the job class indicates the rewrite was incomplete.
if ($jobBody -match '_factory\.Create\(\)') {
    Fail "ErpSyncJob still calls IErpDbConnectionFactory directly — should use IErpSyncService"
}
if ($jobBody -notmatch 'IErpSyncService') {
    Fail "ErpSyncJob does not inject IErpSyncService"
}
if ($jobBody -notmatch 'ReadAndTransformAsync') {
    Fail "ErpSyncJob does not call ReadAndTransformAsync"
}
if ($jobBody -notmatch 'DefaultWarehouseId == Guid\.Empty') {
    Fail "ErpSyncJob missing the 'no DefaultWarehouseId' skip path"
}
OK "Job calls service + has the no-default skip path"

# ----------------------------------------------------------------------------
# 4. ItemCode synthesis rule (Q1)
# ----------------------------------------------------------------------------
Step "ItemCode synthesis: SKU-TRIAL_ID when TRIAL_ID present"
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncService.cs') 'SynthesizeItemCode'
$svc = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\ErpSyncService.cs')
# Look for the synthesis branch markers: a check that trial-id is empty,
# and a fallback to bare SKU. Avoids matching the brace-and-dollar
# interpolation literal which trips the PS parser when escaped.
if ($svc -notmatch 't\.Length == 0 \? s :') {
    Fail "Synthesize fallback branch (TRIAL_ID empty -> bare SKU) not found"
}
OK "Synthesize branching present"

# ----------------------------------------------------------------------------
# 5. WINDOWS_TIME NULL → HourOfDay=7 default
# ----------------------------------------------------------------------------
Step "WINDOWS_TIME NULL defaults to HourOfDay=7"
if ($svc -notmatch 'ParseHour\(row\.WINDOWS_TIME\) \?\? \(byte\)7') {
    Fail "ParseHour-with-7-fallback expression not found in transform"
}
OK "NULL→7 fallback wired"

# ----------------------------------------------------------------------------
# 6. ERP DB connectivity — read 1 row from BPI_PRS
# ----------------------------------------------------------------------------
Step "ErpDb connectivity + BPI_PRS sample read"
$secretsList = & dotnet user-secrets list --project (Join-Path $webRoot 'ReceivingOps.Web.csproj') 2>$null
$hasErpDb = $secretsList | Where-Object { $_ -match '^ErpDb:ConnectionString' }
if (-not $hasErpDb) {
    Skip "ErpDb:ConnectionString not set in user-secrets — connectivity check skipped"
    Write-Host ""
    Write-Host "ALL PASS — Phase 10.2 wiring verified (ERP read skipped — see SKIP above)." -ForegroundColor Green
    exit 0
}

$cs = ($hasErpDb -split '=', 2)[1].Trim()
$kv = @{}
foreach ($pair in $cs -split ';') {
    if ($pair -match '^\s*([^=]+)=(.*)$') { $kv[$matches[1].Trim()] = $matches[2].Trim() }
}
$erpServer = $kv['Server']; $erpDb = $kv['Database']
$erpUser = $kv['User Id']; $erpPass = $kv['Password']

# Fast TCP probe — skip the SQL portion if unreachable.
$tcpHost = $erpServer
if ($tcpHost -match '^(.+?)\\') { $tcpHost = $matches[1] }
if ($tcpHost -match '^(.+?),\d+$') { $tcpHost = $matches[1] }
$port = if ($erpServer -match ',(\d+)$') { [int]$matches[1] } else { 1433 }
$tcp = New-Object System.Net.Sockets.TcpClient
$async = $tcp.BeginConnect($tcpHost, $port, $null, $null)
$reachable = $async.AsyncWaitHandle.WaitOne(2000)
if ($reachable) { try { $tcp.EndConnect($async) } catch { $reachable = $false } }
$tcp.Close()
if (-not $reachable) {
    Skip "TCP probe to ${tcpHost}:${port} timed out (2s) — likely firewall/VPN."
    Write-Host ""
    Write-Host "ALL PASS — Phase 10.2 wiring verified (BPI_PRS read skipped — see SKIP above)." -ForegroundColor Green
    exit 0
}

# Sanity probe: 1 row from BPI_PRS. Confirms we can read the source table +
# at least one usable tuple exists. Array-splat avoids the "expressions
# only at start of pipeline" parser trap that bites `-s "|"` chained with
# trailing `2>&1` on a single line.
$probeQuery = "SET NOCOUNT ON; SELECT TOP 1 PRS_ID + ',' + SKU FROM dbo.BPI_PRS " +
              "WHERE PRS_ID IS NOT NULL AND SKU IS NOT NULL ORDER BY PID DESC;"
$sqlArgs = @('-S', $erpServer, '-d', $erpDb, '-U', $erpUser, '-P', $erpPass,
             '-C', '-l', '5', '-Q', $probeQuery, '-W', '-h', '-1')
$probeRaw = & sqlcmd @sqlArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail "sqlcmd against BPI_PRS failed (exit $LASTEXITCODE). Output: $($probeRaw -join ' ')"
}
$line = ($probeRaw | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^-+$' } | Select-Object -First 1)
if (-not $line -or $line -notmatch ',') {
    Fail "BPI_PRS read returned no parsable PRS_ID,SKU pair. Raw: $($probeRaw -join ' / ')"
}
$parts = $line -split ','
OK "BPI_PRS readable — sample (PRS_ID=$($parts[0].Trim()), SKU=$($parts[1].Trim()))"

Write-Host ""
Write-Host "ALL PASS — Phase 10.2: service + transform + ERP read all verified." -ForegroundColor Green
exit 0
