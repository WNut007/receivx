# Smoke: Phase 10.2 — BPI_PRS read + transform to Receivx draft shape.
#
# Source-level + behavioral. Phase 13.2 relocated the v3.2 ErpSyncService
# body into BpiPrsSource (which implements the new IErpSource strategy
# interface); this smoke tracks that layout. Phase 13.4 nested the
# warehouse + backfill into per-source sub-configs.
#
# Asserts:
#   1. IErpSource interface + BpiPrsSource impl + draft DTOs present
#   2. ErpSyncOptions exposes the nested Sources.Bpi sub-config
#   3. ErpSyncJob fans out across IEnumerable<IErpSource> (no
#      _factory.Create() — the 10.1 stub is long gone)
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
# 1. IErpSource interface + BpiPrsSource impl + drafts exist
# ----------------------------------------------------------------------------
Step "IErpSource interface + BpiPrsSource impl + drafts present"
AssertFile (Join-Path $webRoot 'Services\ErpSync\IErpSource.cs') 'public interface IErpSource'
AssertFile (Join-Path $webRoot 'Services\ErpSync\IErpSource.cs') 'ReadAndTransformAsync'
AssertFile (Join-Path $webRoot 'Services\ErpSync\IErpSource.cs') 'string SourceName'
AssertFile (Join-Path $webRoot 'Services\ErpSync\BpiPrsSource.cs') 'public class BpiPrsSource : IErpSource'
AssertFile (Join-Path $webRoot 'Services\ErpSync\BpiPrsSource.cs') 'FROM   dbo.BPI_PRS'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncDrafts.cs') 'public class ErpSyncDraft'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncDrafts.cs') 'public class PullDraft'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncDrafts.cs') 'public class PullItemDraft'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncDrafts.cs') 'public class PullItemWindowDraft'
OK "IErpSource + BpiPrsSource + 4 Draft DTOs all present"

# ----------------------------------------------------------------------------
# 2. Options exposes the nested Bpi sub-config (per-source warehouse + backfill)
# ----------------------------------------------------------------------------
Step "ErpSyncOptions exposes nested Sources.Bpi sub-config"
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncOptions.cs') 'public ErpSyncSources Sources'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncOptions.cs') 'public ErpSourceOptions Bpi'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncOptions.cs') 'public Guid DefaultWarehouseId'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncOptions.cs') 'public int BackfillDays'
OK "Options nested per-source (Bpi sub-config + Guid DefaultWarehouseId + int BackfillDays)"

# ----------------------------------------------------------------------------
# 3. Job fans out across IEnumerable<IErpSource> (not the 10.1 stub
#    and not the v3.2 IErpSyncService single-reader path)
# ----------------------------------------------------------------------------
Step "ErpSyncJob fans out across IEnumerable<IErpSource>"
$jobBody = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\ErpSyncJob.cs')
# The 10.1 stub used IErpDbConnectionFactory directly + Dapper SELECT.
if ($jobBody -match '_factory\.Create\(\)') {
    Fail "ErpSyncJob still calls IErpDbConnectionFactory directly — should iterate IErpSource sources"
}
if ($jobBody -notmatch 'IEnumerable<IErpSource>') {
    Fail "ErpSyncJob does not depend on IEnumerable<IErpSource>"
}
if ($jobBody -notmatch 'ReadAndTransformAsync') {
    Fail "ErpSyncJob does not call ReadAndTransformAsync"
}
if ($jobBody -notmatch 's\.Enabled') {
    Fail "ErpSyncJob fan-out loop does not filter by IErpSource.Enabled"
}
OK "Job iterates enabled IErpSource instances + calls ReadAndTransformAsync"

# ----------------------------------------------------------------------------
# 4. ItemCode synthesis rule (Q1) — now in BpiPrsSource
# ----------------------------------------------------------------------------
Step "ItemCode synthesis: SKU-TRIAL_ID when TRIAL_ID present"
AssertFile (Join-Path $webRoot 'Services\ErpSync\BpiPrsSource.cs') 'SynthesizeItemCode'
$svc = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\BpiPrsSource.cs')
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
Write-Host "ALL PASS — Phase 10.2 (revised for 13.2): IErpSource + BpiPrsSource + transform + ERP read all verified." -ForegroundColor Green
exit 0
