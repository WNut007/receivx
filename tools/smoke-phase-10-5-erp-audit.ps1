# Smoke: Phase 10.5 — per-pull audit rows for the ERP sync pipeline.
#
# Builds on 10.4's behavioral test by additionally asserting that each run
# leaves a coherent audit trail:
#
#   1 row  etl-start                — EntityId = runId Guid
#   N rows etl-create | etl-update | etl-skip | etl-error
#                                      EntityType='Pull', EntityId=PullNumber
#   1 row  etl-end                  — EntityId = runId, totals in Message
#
# All rows share an actor name (admin display name for manual, "[system]"
# for recurring) and contain "[run {runId}]" in the Message so the 10.6
# status page can group them.
#
# Checks:
#   1. IAuditService gains WriteSystemAsync overloads
#   2. ErpSyncJob writes etl-start + etl-end and uses runId+SystemActor
#   3. ErpUpsertService writes etl-create / etl-update / etl-skip / etl-error
#      and never DELETEs audit rows
#   4. Dev server reachable
#   5. Behavioral (if ERP reachable): trigger sync as admin, poll until
#      Succeeded, then SELECT AuditLog WHERE Message LIKE '%[run <new runId>]%'
#      and assert: 1+ etl-start, >=1 etl-create/update/skip, 1 etl-end

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'
$WH_01 = '22222222-2222-2222-2222-000000000001'
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

# ----------------------------------------------------------------------------
# 1. IAuditService overloads + AuditService impl
# ----------------------------------------------------------------------------
Step "IAuditService.WriteSystemAsync overloads present"
AssertFile (Join-Path $webRoot 'Services\IAuditService.cs') 'Task WriteSystemAsync(IDbConnection conn, IDbTransaction? tx,'
AssertFile (Join-Path $webRoot 'Services\IAuditService.cs') 'Task WriteSystemAsync(string actorName,'
AssertFile (Join-Path $webRoot 'Services\AuditService.cs') 'public async Task WriteSystemAsync(IDbConnection'
AssertFile (Join-Path $webRoot 'Services\AuditService.cs') 'ActorUserId = (Guid?)null'
OK "WriteSystemAsync overloads + impl present"

# ----------------------------------------------------------------------------
# 2. ErpSyncJob audit bracketing
# ----------------------------------------------------------------------------
Step "ErpSyncJob writes etl-start + etl-end + uses runId+SystemActor"
$jobBody = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\ErpSyncJob.cs')
foreach ($needle in @('SystemActor', 'Guid.NewGuid()', '"etl-start"', '"etl-end"', '"etl-error"',
                       '_audit.WriteSystemAsync')) {
    if ($jobBody -notmatch [regex]::Escape($needle)) {
        Fail "ErpSyncJob missing: '$needle'"
    }
}
OK "Job writes start + end + runId + system actor"

# ----------------------------------------------------------------------------
# 3. ErpUpsertService per-pull audit writes
# ----------------------------------------------------------------------------
Step "ErpUpsertService writes per-pull audit rows"
$svc = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Services\ErpSync\ErpUpsertService.cs')
foreach ($needle in @('"etl-create"', '"etl-update"', '"etl-skip"', '"etl-error"',
                       '_audit.WriteSystemAsync', '[run {runId}]')) {
    if ($svc -notmatch [regex]::Escape($needle)) {
        Fail "ErpUpsertService missing: '$needle'"
    }
}
if ($svc -match 'DELETE FROM dbo\.AuditLog') {
    Fail "ErpUpsertService must not DELETE from AuditLog"
}
OK "All 4 per-pull action types written + run correlation present"

# ----------------------------------------------------------------------------
# 4. Dev server reachable
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
# 5. Behavioral (gated on ERP reachability)
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
    Skip "ERP DB unreachable — behavioral audit-trail check skipped"
    Write-Host ""
    Write-Host "ALL PASS — Phase 10.5 surface verified (audit-trail check skipped)." -ForegroundColor Green
    exit 0
}
OK "ERP DB reachable"

Step "Snapshot AuditLog watermark BEFORE trigger"
$beforeId = (Sql "SET NOCOUNT ON; SELECT ISNULL(MAX(Id), 0) FROM dbo.AuditLog;") -join '' -replace '\s', ''
if (-not ($beforeId -match '^\d+$')) { Fail "Couldn't read AuditLog watermark; got '$beforeId'" }
OK "AuditLog max Id before run = $beforeId"

Step "Admin triggers ERP sync with backfillDays=1"
$admin = Login 'sadmin' 'admin' $WH_01
$triggerBody = @{ warehouseId = $WH_01; backfillDays = 1 } | ConvertTo-Json
$resp = Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
    -Body $triggerBody -ContentType 'application/json' -WebSession $admin -UseBasicParsing
if ($resp.StatusCode -ne 202) { Fail "Trigger returned $($resp.StatusCode), expected 202" }
$trigData = $resp.Content | ConvertFrom-Json
OK "Enqueued — jobId=$($trigData.jobId)"

Step "Poll until terminal"
$terminal = @('Succeeded', 'Failed', 'Deleted')
$deadline = (Get-Date).AddSeconds(60)
$state = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    try {
        $statusResp = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/jobs/$($trigData.jobId)" `
            -Method GET -WebSession $admin -ErrorAction Stop
        $state = $statusResp.state
        if ($state -in $terminal) { break }
    } catch { }
}
if ($state -ne 'Succeeded') { Fail "Job did not Succeed within 60s — last state: $state" }
OK "Job Succeeded"

Step "AuditLog contains the run's start + per-pull + end rows"
# Pull the new rows by Id > watermark. Then we extract the runId from the
# etl-start row and verify the per-pull + etl-end rows share it.
$newRows = (Sql @"
SET NOCOUNT ON;
SELECT ActionType + '|' + ISNULL(EntityType,'') + '|' + ISNULL(EntityId,'') + '|' + Message
FROM dbo.AuditLog
WHERE Id > $beforeId AND ActionType LIKE 'etl-%'
ORDER BY Id;
"@)
$lines = @($newRows | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^-+\|' })
if ($lines.Count -lt 2) {
    Fail "Expected at least 2 ETL audit rows (start + end); got $($lines.Count). Sample: $($lines -join ' / ')"
}

# Find the etl-start row's EntityId — that's our run correlation.
$startLine = $lines | Where-Object { $_ -match '^etl-start\|ErpSync\|([0-9a-f-]{36})\|' } | Select-Object -First 1
if (-not $startLine) { Fail "No etl-start row found in audit batch" }
$runId = $matches[1]
OK "Found etl-start runId=$runId"

# Count per-action.
$counts = @{ 'etl-start' = 0; 'etl-create' = 0; 'etl-update' = 0; 'etl-skip' = 0; 'etl-error' = 0; 'etl-end' = 0 }
foreach ($l in $lines) {
    $act = ($l -split '\|', 2)[0]
    if ($counts.ContainsKey($act)) { $counts[$act]++ }
}
if ($counts['etl-start'] -lt 1) { Fail "Missing etl-start row" }
if ($counts['etl-end']   -lt 1) { Fail "Missing etl-end row" }
$perPull = $counts['etl-create'] + $counts['etl-update'] + $counts['etl-skip'] + $counts['etl-error']
if ($perPull -lt 1) {
    Fail "No per-pull rows (etl-create/update/skip/error) — expected at least 1 if BPI_PRS had any rows for backfillDays=1"
}
OK "Counts — start=$($counts['etl-start']), create=$($counts['etl-create']), update=$($counts['etl-update']), skip=$($counts['etl-skip']), error=$($counts['etl-error']), end=$($counts['etl-end'])"

# Verify the per-pull + end rows reference the same runId in their Message
# (start row uses runId as EntityId; per-pull/end rows embed it in Message).
$mismatched = $lines | Where-Object {
    $line = $_
    $act = ($line -split '\|', 2)[0]
    # Skip the etl-start (we already keyed off it); for the rest, runId must appear in Message.
    if ($act -eq 'etl-start') { return $false }
    return $line -notmatch [regex]::Escape("[run $runId]")
}
if ($mismatched.Count -gt 0) {
    Fail "Some non-start audit rows don't reference the run's runId ($runId). First: $($mismatched[0])"
}
OK "All non-start rows correlate via [run $runId] tag"

# Actor name on every row is the operator's displayName claim (matches the
# existing AuditService convention — login/logout/etc. already use displayName).
# For the manual-trigger path, this must NOT be the recurring SystemActor
# placeholder "[system]", and must be a single distinct non-empty value
# (one operator per run).
$actorRows = (Sql @"
SET NOCOUNT ON;
SELECT DISTINCT ActorName
FROM dbo.AuditLog
WHERE Id > $beforeId AND ActionType LIKE 'etl-%';
"@) | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^-+$' }
$actors = @($actorRows | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($actors.Count -ne 1) {
    Fail "Expected one distinct ActorName across the run; saw $($actors.Count): $($actors -join ', ')"
}
if ($actors[0] -eq '[system]') {
    Fail "Manual-trigger run recorded SystemActor — should be the operator's displayName"
}
OK "Actor name on all audit rows = '$($actors[0])' (single operator)"

Write-Host ""
Write-Host "ALL PASS — Phase 10.5: per-pull audit trail verified end-to-end." -ForegroundColor Green
exit 0
