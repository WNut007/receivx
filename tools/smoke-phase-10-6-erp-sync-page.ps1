# Smoke: Phase 10.6 — sync history page + ErpSyncLog table.
#
# Covers schema (db/028), repository wiring, API endpoints, page chrome,
# and behavioral end-to-end (trigger -> row appears in /log with correct
# Status + totals).
#
# Checks:
#   1. db/028 — dbo.ErpSyncLog table exists with expected columns + index
#   2. DTO + repository + interface source files present
#   3. ErpSyncJob writes log rows (InsertStartAsync + Mark* calls)
#   4. ErpSyncAdminController exposes GET /log, /log/{runId}, /state
#   5. AdminController routes /Admin/ErpSync
#   6. Razor view + JS shipped under wwwroot
#   7. Dev server reachable
#   8. Authn — anon → 401, operator → 403, admin → 200
#   9. Page returns HTML with required DOM hooks (#btn-sync-now, #rows table)
#   10. Behavioral (if ERP reachable): trigger sync, poll until Succeeded,
#       then GET /log and assert the new row exists with Status=succeeded
#       and a sensible total set.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_03 = '22222222-2222-2222-2222-000000000003'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Skip($m) { Write-Host "SKIP: $m" -ForegroundColor DarkYellow }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Sql($q)  { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }

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
# 1. Schema — db/028 ErpSyncLog
# ----------------------------------------------------------------------------
Step "dbo.ErpSyncLog table + index exist"
$tableExists = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE name = 'ErpSyncLog';") -join '' -replace '\s',''
if ($tableExists -ne '1') { Fail "dbo.ErpSyncLog not present — run db/028" }
$colCount = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'ErpSyncLog' AND COLUMN_NAME IN ('RunId','TriggeredBy','ActorName','WarehouseId','BackfillDays','Status','StartedAt','CompletedAt','ElapsedMs','SourceRowCount','DraftPullCount','Created','Updated','SkippedClosed','Errors','ItemsAdded','ItemsCanceled','ErrorMessage');") -join '' -replace '\s',''
if ($colCount -ne '18') { Fail "Expected 18 ErpSyncLog columns, got '$colCount'" }
$indexExists = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.indexes WHERE name = 'IX_ErpSyncLog_StartedAt';") -join '' -replace '\s',''
if ($indexExists -ne '1') { Fail "IX_ErpSyncLog_StartedAt not present" }
OK "Table + 18 cols + index all present"

# ----------------------------------------------------------------------------
# 2. DTO + repository
# ----------------------------------------------------------------------------
Step "ErpSyncLog DTO + repository present"
AssertFile (Join-Path $webRoot 'Models\Dtos\ErpSyncLogDtos.cs') 'public class ErpSyncLogRow'
AssertFile (Join-Path $webRoot 'Models\Dtos\ErpSyncLogDtos.cs') 'public class ErpSyncLogTotals'
AssertFile (Join-Path $webRoot 'Data\Repositories\IErpSyncLogRepository.cs') 'InsertStartAsync'
AssertFile (Join-Path $webRoot 'Data\Repositories\IErpSyncLogRepository.cs') 'MarkSucceededAsync'
AssertFile (Join-Path $webRoot 'Data\Repositories\IErpSyncLogRepository.cs') 'MarkFailedAsync'
AssertFile (Join-Path $webRoot 'Data\Repositories\IErpSyncLogRepository.cs') 'QueryPagedAsync'
AssertFile (Join-Path $webRoot 'Data\Repositories\ErpSyncLogRepository.cs') 'INSERT INTO dbo.ErpSyncLog'
OK "Repo interface + impl present"

# ----------------------------------------------------------------------------
# 3. Job writes log rows
# ----------------------------------------------------------------------------
Step "ErpSyncJob writes log rows"
$jobBody = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\ErpSyncJob.cs')
foreach ($needle in @('IErpSyncLogRepository', '_logRepo.InsertStartAsync', '_logRepo.MarkSucceededAsync', '_logRepo.MarkFailedAsync')) {
    if ($jobBody -notmatch [regex]::Escape($needle)) {
        Fail "ErpSyncJob missing: '$needle'"
    }
}
OK "Job injects + calls all 3 log lifecycle methods"

# ----------------------------------------------------------------------------
# 4. Controller endpoints
# ----------------------------------------------------------------------------
Step "ErpSyncAdminController exposes /log, /log/{runId}, /state"
$ctrl = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Controllers\Api\ErpSyncAdminController.cs')
foreach ($needle in @('HttpGet("log")', 'HttpGet("log/{runId:guid}")', 'HttpGet("state")')) {
    if ($ctrl -notmatch [regex]::Escape($needle)) {
        Fail "Controller missing: '$needle'"
    }
}
OK "All 3 GET endpoints declared"

# ----------------------------------------------------------------------------
# 5. AdminController + Razor view
# ----------------------------------------------------------------------------
Step "/Admin/ErpSync route + Razor view + JS file"
AssertFile (Join-Path $webRoot 'Controllers\AdminController.cs') 'HttpGet("/Admin/ErpSync")'
AssertFile (Join-Path $webRoot 'Controllers\AdminController.cs') '[Authorize(Roles = "admin")]'
$viewPath = Join-Path $webRoot 'Views\Admin\ErpSync.cshtml'
if (-not (Test-Path $viewPath)) { Fail "View not found: $viewPath" }
AssertFile $viewPath 'id="btn-sync-now"'
AssertFile $viewPath 'id="rows"'
AssertFile $viewPath 'admin-erp-sync.js'
$jsPath = Join-Path $webRoot 'wwwroot\js\admin-erp-sync.js'
if (-not (Test-Path $jsPath)) { Fail "JS not found: $jsPath" }
OK "Controller + view + JS all present"

# ----------------------------------------------------------------------------
# 6. Dev server reachable
# ----------------------------------------------------------------------------
Step "Dev server reachable"
try {
    $resp = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $code = $resp.StatusCode
} catch {
    $code = $_.Exception.Response.StatusCode.value__
}
if ($code -ne 401 -and $code -ne 200) { Fail "Probe got HTTP $code" }
OK "Dev server is up (HTTP $code)"

# ----------------------------------------------------------------------------
# 7. Authn: anon → 401 on /log, operator → 403, admin → 200
# ----------------------------------------------------------------------------
Step "Authn boundary on /api/admin/erp-sync/log"
ExpectStatus 401 {
    Invoke-WebRequest -Uri "$base/api/admin/erp-sync/log" -Method GET -UseBasicParsing -ErrorAction Stop
}
OK "401 for anonymous"

$op = Login 'npatcharin' 'demo1234' $WH_03
ExpectStatus 403 {
    Invoke-WebRequest -Uri "$base/api/admin/erp-sync/log" -Method GET -WebSession $op -UseBasicParsing -ErrorAction Stop
}
OK "403 for operator role"

$admin = Login 'sadmin' 'admin' $WH_01
$resp = Invoke-WebRequest -Uri "$base/api/admin/erp-sync/log?page=1&pageSize=10" -Method GET -WebSession $admin -UseBasicParsing
if ($resp.StatusCode -ne 200) { Fail "Admin GET returned $($resp.StatusCode)" }
$listBefore = $resp.Content | ConvertFrom-Json
if ($null -eq $listBefore.total) { Fail "Response missing 'total'" }
OK "200 for admin — $($listBefore.total) total rows"

# ----------------------------------------------------------------------------
# 8. Page HTML reachable to admin
# ----------------------------------------------------------------------------
Step "/Admin/ErpSync page returns HTML"
$pageResp = Invoke-WebRequest -Uri "$base/Admin/ErpSync" -Method GET -WebSession $admin -UseBasicParsing
if ($pageResp.StatusCode -ne 200) { Fail "Page returned $($pageResp.StatusCode)" }
if ($pageResp.Content -notmatch 'btn-sync-now') { Fail "Page HTML missing Sync now button" }
if ($pageResp.Content -notmatch 'admin-erp-sync\.js') { Fail "Page HTML missing JS bundle reference" }
OK "Page rendered with required DOM hooks"

# ----------------------------------------------------------------------------
# 9. Behavioral end-to-end (gated on ERP reachability)
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
    Skip "ERP DB unreachable — behavioral check skipped"
    Write-Host ""
    Write-Host "ALL PASS — Phase 10.6 surface verified (E2E skipped)." -ForegroundColor Green
    exit 0
}
OK "ERP DB reachable"

Step "Trigger sync as admin, poll, then assert ErpSyncLog row"
$totalBefore = $listBefore.total
$triggerBody = @{ warehouseId = $WH_01; backfillDays = 1 } | ConvertTo-Json
$trigResp = Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
    -Body $triggerBody -ContentType 'application/json' -WebSession $admin -UseBasicParsing
if ($trigResp.StatusCode -ne 202) { Fail "Trigger returned $($trigResp.StatusCode)" }
$trigData = $trigResp.Content | ConvertFrom-Json
OK "Enqueued — jobId=$($trigData.jobId)"

# Wait for terminal Hangfire state
$terminal = @('Succeeded', 'Failed', 'Deleted')
$deadline = (Get-Date).AddSeconds(60)
$state = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    try {
        $s = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/jobs/$($trigData.jobId)" `
            -Method GET -WebSession $admin -ErrorAction Stop
        $state = $s.state
        if ($state -in $terminal) { break }
    } catch { }
}
if ($state -ne 'Succeeded') { Fail "Job did not Succeed within 60s — last state: $state" }
OK "Job Succeeded"

# Re-fetch /log and assert a new row was added with Status=succeeded
$listAfter = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/log?page=1&pageSize=10" `
    -Method GET -WebSession $admin
if ($listAfter.total -le $totalBefore) {
    Fail "Expected new ErpSyncLog row — before=$totalBefore, after=$($listAfter.total)"
}
$newest = $listAfter.items[0]
if ($newest.status -ne 'succeeded') {
    Fail "Newest row status='$($newest.status)', expected 'succeeded'"
}
if ($newest.elapsedMs -eq $null -or $newest.elapsedMs -lt 0) {
    Fail "Newest row missing/negative elapsedMs"
}
if ($newest.completedAt -eq $null) {
    Fail "Newest row missing CompletedAt"
}
OK "New row visible — runId=$($newest.runId), status=succeeded, elapsed=$($newest.elapsedMs)ms, updated=$($newest.updated)"

# /state should be idle now
$stateNow = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/state" -Method GET -WebSession $admin
if ($stateNow.isRunning) { Fail "/state reports isRunning=true after job completion" }
OK "/state reports idle post-completion"

Write-Host ""
Write-Host "ALL PASS — Phase 10.6: sync history page + ErpSyncLog verified end-to-end." -ForegroundColor Green
exit 0
