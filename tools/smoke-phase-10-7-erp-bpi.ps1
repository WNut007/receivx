# Smoke: Phase 10.7 — full-pipeline integration test (BPI_PRS path).
#
# Renamed from smoke-phase-10-7-integration.ps1 in Phase 13.7 to make
# room for the PRB peer (smoke-phase-13-7-erp-prb.ps1). The BPI test
# is the source-of-truth for the receiving end of the fan-out loop
# (13.5) — covered for the BPI path here, mirrored for PRB in the peer.
#
# Covers ground the per-sub-phase smokes (10.4-10.6) leave for the
# integration boundary:
#
#   1. Cross-table consistency: ErpSyncLog summary counters reconcile
#      with per-pull AuditLog rows for the same runId (Created +
#      Updated + SkippedClosed + Errors == #per-pull rows)
#   2. Closed-pull skip BEHAVIOR (10.3 only verified the code shape):
#      flip a pull to Status='closed' via SQL fixture, trigger sync,
#      assert the next ErpSyncLog row has SkippedClosed >= 1 + the
#      pull's planning fields were NOT mutated, then restore
#   3. Mutex contention: trigger #1, wait for worker pickup, trigger
#      #2 → assert 409 (or skip with note if #1 finishes before #2
#      can race in)
#   4. SourceTotals JSON (Phase 13.1): newest ErpSyncLog row has a
#      non-null SourceTotals containing a "BPI_PRS" entry whose
#      counters match the row-level aggregates (single-source run).
#      Proves the 13.5 fan-out loop populates SourceTotals even when
#      only one source is enabled.
#
# Heavy 10x load test (50K writes per spec §6) stays opt-in — see
# end-of-file note. This smoke runs in the standard battery.

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

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

function TriggerSync($session, $backfillDays = 1) {
    $body = @{ warehouseId = $WH_01; backfillDays = $backfillDays } | ConvertTo-Json
    $resp = Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
        -Body $body -ContentType 'application/json' -WebSession $session -UseBasicParsing
    return $resp
}

function WaitForJob($session, $jobId, $timeoutSec = 90) {
    $terminal = @('Succeeded', 'Failed', 'Deleted')
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $state = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try {
            $s = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/jobs/$jobId" `
                -Method GET -WebSession $session -ErrorAction Stop
            $state = $s.state
            if ($state -in $terminal) { return $state }
        } catch { }
    }
    return $state
}

# ----------------------------------------------------------------------------
# Preflight: ERP must be reachable for the behavioral path (everything
# in this smoke is behavioral; no point running the source-level subset).
# ----------------------------------------------------------------------------
Step "Preflight — server + ERP reachability"
try {
    $probe = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $code = $probe.StatusCode
} catch { $code = $_.Exception.Response.StatusCode.value__ }
if ($code -ne 401 -and $code -ne 200) { Fail "Dev server probe got HTTP $code" }
OK "Dev server up"

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
    Skip "ERP DB unreachable — entire 10.7 integration test skipped (firewall/VPN)"
    Write-Host ""
    Write-Host "ALL PASS — Phase 10.7 skipped (ERP unreachable)." -ForegroundColor Green
    exit 0
}
OK "ERP reachable"

$admin = Login 'sadmin' 'admin' $WH_01

# ============================================================================
# SECTION 1 — Cross-table consistency
# ============================================================================
Step "Section 1: trigger sync, then reconcile ErpSyncLog vs AuditLog"
$auditBefore = (Sql "SET NOCOUNT ON; SELECT ISNULL(MAX(Id), 0) FROM dbo.AuditLog;") -join '' -replace '\s', ''
$trig = TriggerSync $admin 1
if ($trig.StatusCode -ne 202) { Fail "Trigger returned $($trig.StatusCode)" }
$trigData = $trig.Content | ConvertFrom-Json
$state = WaitForJob $admin $trigData.jobId
if ($state -ne 'Succeeded') { Fail "Sync did not Succeed — final state: $state" }

# Newest ErpSyncLog row IS this run (recent activity = single-row identity).
$listResp = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/log?page=1&pageSize=1" `
    -Method GET -WebSession $admin
$newest = $listResp.items[0]
if (-not $newest) { Fail "ErpSyncLog has no rows post-trigger" }
$runId = $newest.runId
OK "Run captured: runId=$runId, created=$($newest.created), updated=$($newest.updated), skipped=$($newest.skippedClosed), errors=$($newest.errors)"

# Per-pull audit rows for the run. The etl-create/etl-update/etl-skip/
# etl-error count should equal Created+Updated+SkippedClosed+Errors from
# the summary row. That proves the two write paths (AuditLog + ErpSyncLog)
# agree on what happened.
$perPullCount = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.AuditLog WHERE Id > $auditBefore AND ActionType IN ('etl-create','etl-update','etl-skip','etl-error') AND EntityType = 'Pull';") -join '' -replace '\s', ''
$expectedPerPull = ($newest.created + $newest.updated + $newest.skippedClosed + $newest.errors)
if ([int]$perPullCount -ne $expectedPerPull) {
    Fail "Per-pull AuditLog row count = $perPullCount; ErpSyncLog summary expects $expectedPerPull"
}
OK "AuditLog per-pull rows ($perPullCount) reconcile with ErpSyncLog counters"

# Start + end audit rows for the run (1 each on a successful run).
$bracketCount = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.AuditLog WHERE Id > $auditBefore AND ActionType IN ('etl-start','etl-end') AND EntityId = '$runId';") -join '' -replace '\s', ''
if ([int]$bracketCount -ne 2) {
    Fail "Expected 1 etl-start + 1 etl-end keyed on runId=$runId; got $bracketCount"
}
OK "etl-start + etl-end rows present and keyed on runId"

# Total run-related rows in this audit window should match perPull + 2.
$totalRunRows = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.AuditLog WHERE Id > $auditBefore AND ActionType LIKE 'etl-%';") -join '' -replace '\s', ''
$expectedTotal = $expectedPerPull + 2
if ([int]$totalRunRows -ne $expectedTotal) {
    Fail "Total ETL audit rows = $totalRunRows; expected $expectedTotal (perPull=$perPull + bracket=2)"
}
OK "No stray ETL audit rows (total = perPull + 2)"

# ============================================================================
# SECTION 2 — Closed-pull skip behavior
# ============================================================================
Step "Section 2: closed-pull skip test (SQL fixture for Status='closed')"

# Pick an ETL'd pull (CreatedBy IS NULL identifies ETL provenance per the
# 10.3 design) that's currently pending. Need one whose PullNumber will
# also appear in the next ETL run (backfillDays=1 catches today's
# DeliveryDate set — earlier sync proved 449 such pulls exist).
$pickRow = (Sql @"
SET NOCOUNT ON;
SELECT TOP 1 CONVERT(VARCHAR(36), Id) + '|' + PullNumber + '|' + CONVERT(VARCHAR(10), PullDate, 23)
FROM dbo.Pulls
WHERE CreatedBy IS NULL AND Status = 'pending'
ORDER BY CreatedAt DESC;
"@) -join '' -replace '\s', ''
if (-not ($pickRow -match '^[a-f0-9-]{36}\|')) {
    Fail "Could not find an ETL'd pending pull to use as the closed-skip fixture"
}
$parts = $pickRow -split '\|'
$fixturePullId = $parts[0]; $fixturePullNumber = $parts[1]; $fixtureOriginalDate = $parts[2]
OK "Fixture pull: $fixturePullNumber (id=$fixturePullId, originalPullDate=$fixtureOriginalDate)"

# Setup: flip Status to 'closed' + move PullDate to a far-past sentinel
# so we can prove the UPDATE branch was NOT taken (real ETL UPDATE would
# overwrite PullDate to today). 1990-01-01 is conservative — predates any
# realistic BPI_PRS.DeliveryDate.
Sql @"
UPDATE dbo.Pulls SET Status = 'closed', PullDate = '1990-01-01'
WHERE Id = '$fixturePullId';
"@ | Out-Null
OK "Pull flipped to closed + PullDate sentinel set"

try {
    $auditBefore2 = (Sql "SET NOCOUNT ON; SELECT ISNULL(MAX(Id), 0) FROM dbo.AuditLog;") -join '' -replace '\s', ''
    $trig2 = TriggerSync $admin 1
    if ($trig2.StatusCode -ne 202) { Fail "Skip-test trigger returned $($trig2.StatusCode)" }
    $trigData2 = $trig2.Content | ConvertFrom-Json
    $state2 = WaitForJob $admin $trigData2.jobId
    if ($state2 -ne 'Succeeded') { Fail "Skip-test sync did not Succeed — final state: $state2" }

    # ErpSyncLog newest row should reflect the new run + SkippedClosed >= 1.
    $log2 = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/log?page=1&pageSize=1" `
        -Method GET -WebSession $admin
    $newest2 = $log2.items[0]
    if (($newest2.skippedClosed ?? 0) -lt 1) {
        Fail "ErpSyncLog.SkippedClosed = $($newest2.skippedClosed); expected >= 1 (the fixture pull)"
    }
    OK "ErpSyncLog reports SkippedClosed=$($newest2.skippedClosed) (incl. fixture)"

    # AuditLog should have an etl-skip row for the fixture pull.
    $skipRow = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.AuditLog WHERE Id > $auditBefore2 AND ActionType = 'etl-skip' AND EntityType = 'Pull' AND EntityId = '$fixturePullNumber';") -join '' -replace '\s', ''
    if ([int]$skipRow -ne 1) {
        Fail "Expected 1 etl-skip audit row for PullNumber=$fixturePullNumber; got $skipRow"
    }
    OK "etl-skip audit row written for the fixture pull"

    # Critical assertion: PullDate must STILL be the sentinel — proving the
    # ETL UPDATE branch was not taken. If the skip failed, PullDate would
    # be the real BPI_PRS.DeliveryDate (some recent date).
    $stillSentinel = (Sql "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(10), PullDate, 23) FROM dbo.Pulls WHERE Id = '$fixturePullId';") -join '' -replace '\s', ''
    if ($stillSentinel -ne '1990-01-01') {
        Fail "PullDate = $stillSentinel; expected '1990-01-01' (skip should have left it untouched)"
    }
    OK "PullDate untouched — closed-pull was genuinely skipped (data preserved)"
}
finally {
    # Always restore the fixture so reruns are idempotent + the dev DB
    # doesn't carry an artificially-closed pull around.
    Sql @"
UPDATE dbo.Pulls SET Status = 'pending', PullDate = '$fixtureOriginalDate'
WHERE Id = '$fixturePullId';
"@ | Out-Null
    OK "Fixture restored (Status=pending, PullDate=$fixtureOriginalDate)"
}

# ============================================================================
# SECTION 3 — Mutex contention (best-effort)
# ============================================================================
Step "Section 3: mutex 409 under contention (best-effort timing)"

# Trigger #1; immediately poll /state until isRunning becomes true (the
# worker has picked it up). At that point a second trigger should hit the
# 409 fast-path. If trigger #1 finishes before we observe isRunning, skip
# the contention assertion — a too-fast sync isn't a regression.
$trig3 = TriggerSync $admin 1
if ($trig3.StatusCode -ne 202) { Fail "Contention trigger #1 returned $($trig3.StatusCode)" }
$trigData3 = $trig3.Content | ConvertFrom-Json
OK "Contention trigger #1 enqueued: jobId=$($trigData3.jobId)"

$observedRunning = $false
$pollDeadline = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $pollDeadline) {
    $s = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/state" -Method GET -WebSession $admin
    if ($s.isRunning) { $observedRunning = $true; break }
    Start-Sleep -Milliseconds 100
}

if ($observedRunning) {
    # Mutex is held — second trigger should 409.
    $got409 = $false
    try {
        $trig4 = TriggerSync $admin 1
        Fail "Contention trigger #2 returned $($trig4.StatusCode), expected 409"
    } catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -eq 409) { $got409 = $true } else { Fail "Contention trigger #2 returned $sc, expected 409" }
    }
    if ($got409) { OK "Second trigger correctly rejected with 409 while sync in flight" }

    # Drain #1 before exit so subsequent battery smokes start idle.
    $finalState = WaitForJob $admin $trigData3.jobId
    if ($finalState -ne 'Succeeded') { Fail "Trigger #1 final state = $finalState; expected Succeeded" }
    OK "Trigger #1 drained to Succeeded"
} else {
    Skip "Sync completed too fast (< 5s) to observe in-flight state — contention 409 path not tested in this run"
    $finalState = WaitForJob $admin $trigData3.jobId 30
    if ($finalState -ne 'Succeeded' -and $finalState -ne $null) {
        Fail "Trigger #1 final state = $finalState; expected Succeeded"
    }
}

# ============================================================================
# SECTION 4 — SourceTotals JSON (Phase 13.1 / 13.5)
# ============================================================================
Step "Section 4: SourceTotals JSON populated with BPI_PRS entry"

# Newest log row again — at this point the trigger #1 in Section 3
# has finished, so its row is now the newest. The /log paginated
# response carries the SourceTotals field on every row.
$drill = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/log?page=1&pageSize=1" `
    -Method GET -WebSession $admin
$latestRow = $drill.items[0]
if (-not $latestRow.sourceTotals) {
    Fail "SourceTotals is null on the newest log row — 13.5 fan-out should populate it"
}
try {
    $perSource = $latestRow.sourceTotals | ConvertFrom-Json
} catch {
    Fail "SourceTotals not valid JSON: $($latestRow.sourceTotals)"
}
if (-not $perSource.BPI_PRS) {
    $keys = ($perSource | Get-Member -MemberType NoteProperty).Name -join ','
    Fail "SourceTotals missing BPI_PRS entry. Got keys: $keys"
}
$bpi = $perSource.BPI_PRS
# Sum-across-sources invariant — works whether the dev DB has just BPI
# enabled (Phase 13 default) or BPI+PRB both enabled (operator opted in).
# The row aggregate must equal the SUM of every per-source entry.
$sumC=0; $sumU=0; $sumS=0; $sumE=0
foreach ($k in ($perSource | Get-Member -MemberType NoteProperty).Name) {
    $sumC += $perSource.$k.created
    $sumU += $perSource.$k.updated
    $sumS += $perSource.$k.skippedClosed
    $sumE += $perSource.$k.errors
}
if ($sumC -ne $latestRow.created -or $sumU -ne $latestRow.updated -or
    $sumS -ne $latestRow.skippedClosed -or $sumE -ne $latestRow.errors) {
    Fail ("Per-source sum disagrees with row aggregates: " +
          "sum(c=$sumC,u=$sumU,s=$sumS,e=$sumE) vs " +
          "row(c=$($latestRow.created),u=$($latestRow.updated),s=$($latestRow.skippedClosed),e=$($latestRow.errors))")
}
# And BPI must specifically be present + non-negative (sanity).
if ($bpi.created -lt 0 -or $bpi.updated -lt 0) {
    Fail "BPI_PRS counters are negative: $($bpi | ConvertTo-Json)"
}
OK "SourceTotals sum matches row aggregates; BPI_PRS present with counters c=$($bpi.created),u=$($bpi.updated)"

Write-Host ""
Write-Host "ALL PASS — Phase 10.7 BPI: integration consistency + closed-skip + mutex + SourceTotals verified." -ForegroundColor Green
Write-Host ""
Write-Host "NOTE: 10x load test (~50K row writes per spec §6) is intentionally NOT" -ForegroundColor DarkGray
Write-Host "      battery-runnable — too DB-intensive for CI. Run it once as a" -ForegroundColor DarkGray
Write-Host "      pre-deploy verification by triggering a sync with a wide" -ForegroundColor DarkGray
Write-Host "      backfillDays window (e.g. 365 — catches most of BPI_PRS's 100k+" -ForegroundColor DarkGray
Write-Host "      rows) and measuring wall-clock + responsiveness during the run." -ForegroundColor DarkGray
exit 0
