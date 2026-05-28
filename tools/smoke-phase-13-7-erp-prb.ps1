# Smoke: Phase 13.7 — PRB_PRS integration peer.
#
# Mirrors smoke-phase-10-7-erp-bpi.ps1 for the second ERP source.
# Three preconditions, all SKIP-able so the smoke doesn't block dev
# battery on machines where PRB isn't set up yet:
#
#   A. ERP DB reachable (TCP probe to the ErpDb host, 2s timeout)
#   B. dbo.PRB_PRS table exists on the ERP host (sys.tables probe)
#   C. ErpSync:Sources:Prb:Enabled = 'true' (admin opted in via
#      /Config — the gate is restart-required, so we don't try to
#      flip it from this smoke)
#
# When all three preconditions hold, the smoke:
#   1. Triggers a sync (which will fan out across enabled sources —
#      that's at least PRB, possibly also BPI if its toggle is on)
#   2. Verifies the newest ErpSyncLog row's SourceTotals JSON contains
#      a "PRB_PRS" entry with non-null counters
#   3. Verifies aggregate row counters >= per-source PRB counters
#      (i.e. PRB contributed, possibly alongside BPI)
#   4. Cross-checks PRB-tagged audit rows: the [source PRB_PRS] suffix
#      appears on at least one etl-create / etl-update / etl-skip row
#      from this run
#   5. Per-source toggle assertion: when the SourceTotals JSON exists,
#      its keys are exactly the set of sources enabled at run time.
#      A disabled source MUST NOT appear in SourceTotals.

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
    return Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
        -Body $body -ContentType 'application/json' -WebSession $session -UseBasicParsing
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
# Preflight A — server up
# ----------------------------------------------------------------------------
Step "Preflight A — dev server reachable"
try {
    $probe = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $code = $probe.StatusCode
} catch { $code = $_.Exception.Response.StatusCode.value__ }
if ($code -ne 401 -and $code -ne 200) { Fail "Dev server probe got HTTP $code" }
OK "Dev server up"

# ----------------------------------------------------------------------------
# Preflight B — ERP DB reachable (TCP probe)
# ----------------------------------------------------------------------------
Step "Preflight B — ERP DB reachable"
$secretsList = & dotnet user-secrets list --project (Join-Path $webRoot 'ReceivingOps.Web.csproj') 2>$null
$hasErpDb = $secretsList | Where-Object { $_ -match '^ErpDb:ConnectionString' }
$reachable = $false
$erpServer = $null; $erpDb = $null; $erpUser = $null; $erpPass = $null
if ($hasErpDb) {
    $cs = ($hasErpDb -split '=', 2)[1].Trim()
    $kv = @{}
    foreach ($pair in $cs -split ';') {
        if ($pair -match '^\s*([^=]+)=(.*)$') { $kv[$matches[1].Trim()] = $matches[2].Trim() }
    }
    $erpServer = $kv['Server']; $erpDb = $kv['Database']
    $erpUser = $kv['User Id']; $erpPass = $kv['Password']

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
if (-not $reachable) {
    Skip "ERP DB unreachable — Phase 13.7 PRB integration skipped (firewall/VPN/no-secret)"
    Write-Host ""
    Write-Host "ALL PASS — Phase 13.7 PRB skipped (ERP unreachable)." -ForegroundColor Green
    exit 0
}
OK "ERP reachable"

# ----------------------------------------------------------------------------
# Preflight C — PRB_PRS table exists on the ERP host
# ----------------------------------------------------------------------------
Step "Preflight C — dbo.PRB_PRS table exists on ERP host"
$existsQuery = "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE name = 'PRB_PRS' AND schema_id = SCHEMA_ID('dbo');"
$sqlArgs = @('-S', $erpServer, '-d', $erpDb, '-U', $erpUser, '-P', $erpPass,
             '-C', '-l', '5', '-Q', $existsQuery, '-W', '-h', '-1')
$existsRaw = & sqlcmd @sqlArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Skip "sys.tables probe against ERP failed (exit $LASTEXITCODE) — PRB integration skipped"
    Write-Host ""
    Write-Host "ALL PASS — Phase 13.7 PRB skipped (probe failed)." -ForegroundColor Green
    exit 0
}
$existsLine = ($existsRaw | Where-Object { $_ -and $_.Trim() -match '^\d+$' } | Select-Object -First 1)
if (-not $existsLine -or [int]$existsLine.Trim() -lt 1) {
    Skip "dbo.PRB_PRS not present on ERP host — operator hasn't deployed the second source yet"
    Write-Host ""
    Write-Host "ALL PASS — Phase 13.7 PRB skipped (table not deployed)." -ForegroundColor Green
    exit 0
}
OK "dbo.PRB_PRS exists"

# ----------------------------------------------------------------------------
# Preflight D — ErpSync:Sources:Prb:Enabled = true (admin opted in via /Config)
# ----------------------------------------------------------------------------
Step "Preflight D — ErpSync:Sources:Prb:Enabled = true"
$admin = Login 'sadmin' 'admin' $WH_01
$cfg = Invoke-RestMethod -Uri "$base/api/admin/config/sections/ErpSync" -Method GET -WebSession $admin
$prbEnabled = $cfg.values.'ErpSync:Sources:Prb:Enabled'
if ($prbEnabled -ne 'True' -and $prbEnabled -ne 'true') {
    Skip "ErpSync:Sources:Prb:Enabled = '$prbEnabled' — toggle on via /Config + restart to enable PRB sync"
    Write-Host ""
    Write-Host "ALL PASS — Phase 13.7 PRB skipped (toggle off)." -ForegroundColor Green
    exit 0
}
OK "PRB source toggle is on"

# ============================================================================
# Live integration — PRB enabled + reachable + table present.
# ============================================================================
Step "Trigger sync, wait for completion"
$auditBefore = (Sql "SET NOCOUNT ON; SELECT ISNULL(MAX(Id), 0) FROM dbo.AuditLog;") -join '' -replace '\s', ''
$trig = TriggerSync $admin 1
if ($trig.StatusCode -ne 202) { Fail "Trigger returned $($trig.StatusCode)" }
$trigData = $trig.Content | ConvertFrom-Json
$state = WaitForJob $admin $trigData.jobId
if ($state -ne 'Succeeded') { Fail "Sync did not Succeed — final state: $state" }
OK "Sync completed"

# ----------------------------------------------------------------------------
# 1. Newest ErpSyncLog row → SourceTotals JSON includes PRB_PRS
# ----------------------------------------------------------------------------
Step "1. SourceTotals JSON includes PRB_PRS"
$listResp = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/log?page=1&pageSize=1" `
    -Method GET -WebSession $admin
$newest = $listResp.items[0]
if (-not $newest) { Fail "ErpSyncLog has no rows post-trigger" }
$runId = $newest.runId
if (-not $newest.sourceTotals) {
    Fail "SourceTotals is null on the newest log row (runId=$runId)"
}
try {
    $perSource = $newest.sourceTotals | ConvertFrom-Json
} catch {
    Fail "SourceTotals not valid JSON: $($newest.sourceTotals)"
}
if (-not $perSource.PRB_PRS) {
    $keys = ($perSource | Get-Member -MemberType NoteProperty).Name -join ','
    Fail "SourceTotals missing PRB_PRS entry. Got keys: $keys"
}
$prb = $perSource.PRB_PRS
OK "PRB_PRS entry present: created=$($prb.created), updated=$($prb.updated), skipped=$($prb.skippedClosed), errors=$($prb.errors)"

# ----------------------------------------------------------------------------
# 2. Aggregate row counters >= PRB per-source counters
# ----------------------------------------------------------------------------
Step "2. Row aggregates >= PRB per-source counters"
if ($newest.created   -lt $prb.created)   { Fail "row.created ($($newest.created)) < PRB.created ($($prb.created))" }
if ($newest.updated   -lt $prb.updated)   { Fail "row.updated ($($newest.updated)) < PRB.updated ($($prb.updated))" }
if ($newest.skippedClosed -lt $prb.skippedClosed) { Fail "row.skippedClosed < PRB.skippedClosed" }
if ($newest.errors    -lt $prb.errors)    { Fail "row.errors < PRB.errors" }
OK "Aggregate counters consistent with PRB contribution"

# ----------------------------------------------------------------------------
# 3. AuditLog [source PRB_PRS]-tagged rows for this run
# ----------------------------------------------------------------------------
Step "3. AuditLog [source PRB_PRS] suffix on per-pull rows"
# At least one of etl-create / etl-update / etl-skip from this run
# should carry the [source PRB_PRS] suffix in its Message column.
$tagQuery = "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.AuditLog " +
            "WHERE Id > $auditBefore AND ActionType IN ('etl-create','etl-update','etl-skip','etl-error') " +
            "AND EntityType = 'Pull' AND Message LIKE '%[source PRB_PRS]%';"
$tagCount = (Sql $tagQuery) -join '' -replace '\s', ''
if ([int]$tagCount -lt 1) {
    # PRB may have produced zero pulls if PRB_PRS is empty on the window — that's
    # a SKIP, not a FAIL. Verify via SourceTotals: if all PRB counters are zero,
    # zero audit rows is consistent.
    $allZero = ($prb.created -eq 0 -and $prb.updated -eq 0 -and $prb.skippedClosed -eq 0 -and $prb.errors -eq 0)
    if ($allZero) {
        Skip "PRB produced zero pulls this run (counters all 0) — no audit rows expected"
    } else {
        Fail "PRB counters non-zero but no [source PRB_PRS]-tagged audit rows for run window"
    }
} else {
    OK "$tagCount AuditLog row(s) carry the [source PRB_PRS] suffix"
}

# ----------------------------------------------------------------------------
# 4. Per-source toggle — disabled source MUST NOT appear in SourceTotals
# ----------------------------------------------------------------------------
Step "4. Per-source toggle: disabled sources absent from SourceTotals"
$bpiEnabled = $cfg.values.'ErpSync:Sources:Bpi:Enabled'
$enabledSources = New-Object System.Collections.Generic.HashSet[string]
if ($bpiEnabled -eq 'True' -or $bpiEnabled -eq 'true') { [void]$enabledSources.Add('BPI_PRS') }
if ($prbEnabled -eq 'True' -or $prbEnabled -eq 'true') { [void]$enabledSources.Add('PRB_PRS') }
$actualKeys = ($perSource | Get-Member -MemberType NoteProperty).Name
foreach ($k in $actualKeys) {
    if (-not $enabledSources.Contains($k)) {
        Fail "SourceTotals contains '$k' but that source is disabled in config"
    }
}
foreach ($k in $enabledSources) {
    if ($actualKeys -notcontains $k) {
        Fail "SourceTotals missing '$k' but that source is enabled in config"
    }
}
OK "SourceTotals keys match enabled-source set exactly ($($enabledSources -join ','))"

Write-Host ""
Write-Host "ALL PASS — Phase 13.7 PRB: per-source fan-out + SourceTotals JSON + source-tagged audit verified." -ForegroundColor Green
exit 0
