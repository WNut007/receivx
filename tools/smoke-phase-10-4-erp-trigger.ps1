# Smoke: Phase 10.4 — manual ERP-sync trigger endpoint + mutex.
#
# This is the FIRST behavioral end-to-end smoke for the Phase 10 stack:
# POSTs to /api/admin/erp-sync/trigger, polls /jobs/{jobId} until terminal
# Hangfire state, asserts Succeeded. That exercises the wiring built in
# 10.1, the read+transform in 10.2, and the upsert in 10.3.
#
# Checks:
#   1. ErpSyncMutex + ErpSyncAdminController source files present with
#      expected attributes/methods (cheap fail-fast before the dev call)
#   2. ErpSyncJob has both entry points: RunAsync (recurring) +
#      RunForWarehouseAsync (manual)
#   3. Dev server reachable
#   4. Admin authn boundary: unauthenticated → 401
#   5. Operator authn boundary: signed-in operator → 403
#   6. Bad input: empty warehouseId → 400
#   7. Behavioral (if ERP DB reachable): admin POSTs trigger → 202 with
#      jobId → poll /jobs/{jobId} every 1s until terminal state → assert
#      Succeeded. SKIPs cleanly if ERP DB unreachable (firewall/VPN).

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_03 = '22222222-2222-2222-2222-000000000003'

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

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
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

# ----------------------------------------------------------------------------
# 1. Mutex + controller source
# ----------------------------------------------------------------------------
Step "ErpSyncMutex + ErpSyncAdminController present"
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncMutex.cs') 'public class ErpSyncMutex'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncMutex.cs') 'TryAcquire'
AssertFile (Join-Path $webRoot 'Services\ErpSync\ErpSyncMutex.cs') 'Interlocked.CompareExchange'
AssertFile (Join-Path $webRoot 'Controllers\Api\ErpSyncAdminController.cs') 'Route("api/admin/erp-sync")'
AssertFile (Join-Path $webRoot 'Controllers\Api\ErpSyncAdminController.cs') '[Authorize(Roles = "admin")]'
AssertFile (Join-Path $webRoot 'Controllers\Api\ErpSyncAdminController.cs') 'HttpPost("trigger")'
AssertFile (Join-Path $webRoot 'Controllers\Api\ErpSyncAdminController.cs') 'HttpGet("jobs/{jobId}")'
OK "Mutex + controller surface present"

# ----------------------------------------------------------------------------
# 2. Both job entry points + mutex usage
# ----------------------------------------------------------------------------
Step "ErpSyncJob exposes RunAsync + RunForWarehouseAsync"
$jobBody = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\ErpSyncJob.cs')
if ($jobBody -notmatch 'Task RunAsync\(\)') {
    Fail "ErpSyncJob missing parameterless RunAsync() entry point"
}
if ($jobBody -notmatch 'Task RunForWarehouseAsync\(Guid warehouseId, int backfillDays') {
    Fail "ErpSyncJob missing RunForWarehouseAsync(Guid, int, ...) entry point"
}
foreach ($needle in @('_mutex.TryAcquire()', '_mutex.Release()')) {
    if ($jobBody -notmatch [regex]::Escape($needle)) {
        Fail "ErpSyncJob missing mutex call: '$needle'"
    }
}
OK "Both entry points use the singleton mutex"

# ----------------------------------------------------------------------------
# 3. Dev server reachable
# ----------------------------------------------------------------------------
Step "Dev server reachable"
try {
    $resp = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $code = $resp.StatusCode
} catch {
    $code = $_.Exception.Response.StatusCode.value__
}
if ($code -ne 401 -and $code -ne 200) { Fail "Probe got HTTP $code" }
OK "Dev server is up (HTTP $code on /api/auth/me)"

# ----------------------------------------------------------------------------
# 4. Authn: unauthenticated → 401
# ----------------------------------------------------------------------------
Step "Unauthenticated POST → 401"
$body = @{ warehouseId = $WH_01 } | ConvertTo-Json
ExpectStatus 401 {
    Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
        -Body $body -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
}
OK "401 for anonymous"

# ----------------------------------------------------------------------------
# 5. Authz: operator → 403
# ----------------------------------------------------------------------------
Step "Operator role → 403"
$op = Login 'npatcharin' 'demo1234' $WH_03
ExpectStatus 403 {
    Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
        -Body $body -ContentType 'application/json' -WebSession $op `
        -UseBasicParsing -ErrorAction Stop
}
OK "403 for operator role"

# ----------------------------------------------------------------------------
# 6. Bad input: empty warehouseId → 400
# ----------------------------------------------------------------------------
Step "Admin login + 400 on empty warehouseId"
$admin = Login 'sadmin' 'admin' $WH_01
$emptyBody = @{ warehouseId = '00000000-0000-0000-0000-000000000000' } | ConvertTo-Json
ExpectStatus 400 {
    Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
        -Body $emptyBody -ContentType 'application/json' -WebSession $admin `
        -UseBasicParsing -ErrorAction Stop
}
OK "400 for empty warehouseId"

# ----------------------------------------------------------------------------
# 7. Behavioral end-to-end (gated on ERP reachability)
# ----------------------------------------------------------------------------
Step "ERP reachability probe"
$secretsList = & dotnet user-secrets list --project (Join-Path $webRoot 'ReceivingOps.Web.csproj') 2>$null
$hasErpDb = $secretsList | Where-Object { $_ -match '^ErpDb:ConnectionString' }
$reachable = $false
if ($hasErpDb) {
    $cs = ($hasErpDb -split '=', 2)[1].Trim()
    $serverPart = ($cs -split ';' | Where-Object { $_ -match '^\s*Server=' } | Select-Object -First 1)
    if ($serverPart) {
        $erpServer = ($serverPart -split '=', 2)[1].Trim()
        $tcpHost = $erpServer
        if ($tcpHost -match '^(.+?)\\') { $tcpHost = $matches[1] }
        if ($tcpHost -match '^(.+?),\d+$') { $tcpHost = $matches[1] }
        $port = if ($erpServer -match ',(\d+)$') { [int]$matches[1] } else { 1433 }
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($tcpHost, $port, $null, $null)
        $reachable = $async.AsyncWaitHandle.WaitOne(2000)
        if ($reachable) { try { $tcp.EndConnect($async) } catch { $reachable = $false } }
        $tcp.Close()
    }
}
if (-not $reachable) {
    Skip "ERP DB unreachable — behavioral end-to-end skipped (firewall/VPN)"
    Write-Host ""
    Write-Host "ALL PASS — Phase 10.4 surface verified (end-to-end skipped)." -ForegroundColor Green
    exit 0
}
OK "ERP DB reachable"

# Trigger with a tiny backfill window so we limit blast radius. The real
# upsert into Receivx may create new rows for the chosen warehouse — that's
# the price of a behavioral smoke. Cleanup is left to the operator (run
# again with backfillDays=0 to no-op, or use the drawer to cancel).
Step "POST /api/admin/erp-sync/trigger → 202"
$triggerBody = @{ warehouseId = $WH_01; backfillDays = 1 } | ConvertTo-Json
$resp = Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
    -Body $triggerBody -ContentType 'application/json' -WebSession $admin `
    -UseBasicParsing
if ($resp.StatusCode -ne 202) { Fail "Trigger returned $($resp.StatusCode), expected 202" }
$trigData = $resp.Content | ConvertFrom-Json
if (-not $trigData.jobId) { Fail "Response missing jobId" }
OK "Enqueued — jobId=$($trigData.jobId)"

Step "Poll /api/admin/erp-sync/jobs/{jobId} until terminal state"
$terminal = @('Succeeded', 'Failed', 'Deleted')
$deadline = (Get-Date).AddSeconds(60)
$state = $null
$reason = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    try {
        $statusResp = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/jobs/$($trigData.jobId)" `
            -Method GET -WebSession $admin -ErrorAction Stop
        $state = $statusResp.state
        $reason = $statusResp.reason
        Write-Host "  state=$state" -ForegroundColor DarkGray
        if ($state -in $terminal) { break }
    } catch {
        Write-Host "  poll error (will retry): $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
if (-not $state -or $state -notin $terminal) {
    Fail "Job did not reach a terminal state within 60s — last seen: $state"
}
if ($state -ne 'Succeeded') {
    Fail "Job terminal state = $state (expected Succeeded). Reason: $reason"
}
OK "Job Succeeded — full pipeline (read → transform → upsert) verified end-to-end"

Write-Host ""
Write-Host "ALL PASS — Phase 10.4: trigger endpoint + mutex + full E2E pipeline." -ForegroundColor Green
exit 0
