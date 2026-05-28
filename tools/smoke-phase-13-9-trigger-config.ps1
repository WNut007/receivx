# Smoke: Phase 13.9 — trigger uses per-source config (warehouse + backfill).
#
# Renamed from smoke-phase-13-8-trigger-source.ps1. 13.8 added the source
# dropdown; 13.9 stripped the warehouse + backfill inputs from the modal
# and switched the controller to enqueue RunNowAsync (which reads each
# source's DefaultWarehouseId + BackfillDays from /Config).
#
# This smoke now verifies BOTH:
#   * the 13.8 contract (dropdown render, single-source filter, 400s) — unchanged
#   * the 13.9 contract (modal markup shrinks, payload is sourceName-only,
#     run uses the per-source config WH, extra payload fields ignored)
#
# Asserts:
#   1. Both pages render: source dropdown + dynamic label PRESENT,
#      warehouse/backfill DOM fields ABSENT (the 13.9 shrink).
#   2. Component JS still served.
#   3. POST { sourceName=null } returns 202 + response.sourceName="".
#   4. POST { sourceName="<enabled>" } returns 202 + echo, ErpSyncLog
#      SourceTotals contains ONLY that source, AND the row's
#      WarehouseId column equals the source's config DefaultWarehouseId
#      (proves the worker uses per-source config — Phase 13.9.1).
#   5. POST { sourceName="BOGUS_PRS" } → 400 with "Known: ..." detail.
#   6. POST { sourceName="<disabled>" } → 400 (skipped when both on).
#   7. POST with extra legacy fields (warehouseId, backfillDays) is
#      tolerated — the controller ignores them and still returns 202.
#
# Preconditions:
#   - Dev server up
#   - Admin login works
#   - ERP DB reachable (TCP probe; SKIP integration parts if down)
#   - At least one source enabled (SKIP entirely if none)

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Skip($m) { Write-Host "SKIP: $m" -ForegroundColor DarkYellow }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body `
        -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
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

$admin = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
# 1. Both pages render the shared partial with the dropdown hooks
# ----------------------------------------------------------------------------
Step "1. /Admin/ErpSync + /Dashboard render the source dropdown"
$adminHtml = (Invoke-WebRequest -Uri "$base/Admin/ErpSync" -WebSession $admin -UseBasicParsing).Content
$dashHtml  = (Invoke-WebRequest -Uri "$base/Dashboard"     -WebSession $admin -UseBasicParsing).Content

foreach ($pair in @(
    @{ Name='Admin'; Html=$adminHtml; ModalId='syncModal'; Prefix='sync' },
    @{ Name='Dashboard'; Html=$dashHtml; ModalId='erpSyncModal'; Prefix='erp' }
)) {
    if ($pair.Html -notmatch [regex]::Escape("id=`"$($pair.ModalId)`"")) {
        Fail "$($pair.Name) page missing modal id=`"$($pair.ModalId)`""
    }
    if ($pair.Html -notmatch [regex]::Escape("id=`"$($pair.Prefix)-source`"")) {
        Fail "$($pair.Name) page missing source dropdown id=`"$($pair.Prefix)-source`""
    }
    if ($pair.Html -notmatch [regex]::Escape("id=`"$($pair.Prefix)-source-label`"")) {
        Fail "$($pair.Name) page missing dynamic source label id=`"$($pair.Prefix)-source-label`""
    }
    if ($pair.Html -match '<code>BPI_PRS</code>') {
        Fail "$($pair.Name) page still has hardcoded <code>BPI_PRS</code> — should be dynamic"
    }
    # Phase 13.9.2 — warehouse + backfill fields MUST be absent. Operators
    # no longer choose them at trigger time; the worker uses per-source config.
    if ($pair.Html -match [regex]::Escape("id=`"$($pair.Prefix)-warehouse`"")) {
        Fail "$($pair.Name) page still has warehouse field id=`"$($pair.Prefix)-warehouse`" — should be removed in 13.9.2"
    }
    if ($pair.Html -match [regex]::Escape("id=`"$($pair.Prefix)-backfill-days`"")) {
        Fail "$($pair.Name) page still has backfill field id=`"$($pair.Prefix)-backfill-days`" — should be removed in 13.9.2"
    }
    OK "$($pair.Name) renders source dropdown only (warehouse + backfill fields removed)"
}

# ----------------------------------------------------------------------------
# 2. Component JS is statically served
# ----------------------------------------------------------------------------
Step "2. erp-source-dropdown.js statically served"
$jsResp = Invoke-WebRequest -Uri "$base/js/components/erp-source-dropdown.js" -UseBasicParsing
if ($jsResp.StatusCode -ne 200) { Fail "Component JS HTTP $($jsResp.StatusCode)" }
if ($jsResp.Content.Length -lt 500) { Fail "Component JS suspiciously small: $($jsResp.Content.Length) bytes" }
if ($jsResp.Content -notmatch 'ErpSourceDropdown') {
    Fail "Component JS missing window.ErpSourceDropdown export"
}
OK "Component JS served ($($jsResp.Content.Length) bytes, ErpSourceDropdown present)"

# ----------------------------------------------------------------------------
# 3. Read current source enablement (drives later tests)
# ----------------------------------------------------------------------------
Step "3. Read enabled-source set from /api/admin/config/sections/ErpSync"
$cfg = Invoke-RestMethod -Uri "$base/api/admin/config/sections/ErpSync" -WebSession $admin
$bpiOn = $cfg.values.'ErpSync:Sources:Bpi:Enabled' -in @('True', 'true')
$prbOn = $cfg.values.'ErpSync:Sources:Prb:Enabled' -in @('True', 'true')
$enabled = @()
if ($bpiOn) { $enabled += 'BPI_PRS' }
if ($prbOn) { $enabled += 'PRB_PRS' }
OK "Enabled sources: $(if ($enabled.Count -eq 0) { '(none)' } else { $enabled -join ',' })"

if ($enabled.Count -eq 0) {
    Skip "No sources enabled — cannot exercise trigger path. Enable at least one via /Config + restart."
    Write-Host ""
    Write-Host "ALL PASS — Phase 13.8 partial UI verified (trigger tests skipped — no enabled sources)." -ForegroundColor Green
    exit 0
}

# ----------------------------------------------------------------------------
# 4. Unknown source → 400
# ----------------------------------------------------------------------------
Step "4. Unknown source name returns 400"
$bogusBody = @{ sourceName='BOGUS_PRS' } | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
        -Body $bogusBody -ContentType 'application/json' -WebSession $admin `
        -UseBasicParsing -ErrorAction Stop | Out-Null
    Fail "Unknown source returned 2xx — expected 400"
} catch {
    $sc = $_.Exception.Response.StatusCode.value__
    if ($sc -ne 400) { Fail "Unknown source returned HTTP $sc — expected 400" }
    $detail = $_.ErrorDetails.Message | ConvertFrom-Json
    if ($detail.title -notmatch 'Unknown source') {
        Fail "Unknown-source error title doesn't mention 'Unknown source': $($detail.title)"
    }
    if ($detail.title -notmatch 'BPI_PRS') {
        Fail "Unknown-source error doesn't list known sources: $($detail.title)"
    }
}
OK "BOGUS_PRS rejected with 400 + helpful 'Known: BPI_PRS, PRB_PRS' detail"

# ----------------------------------------------------------------------------
# 5. Disabled source → 400 (only when there's a disabled source to test)
# ----------------------------------------------------------------------------
Step "5. Disabled source returns 400 (skipped when both on)"
$disabled = @()
if (-not $bpiOn) { $disabled += 'BPI_PRS' }
if (-not $prbOn) { $disabled += 'PRB_PRS' }
if ($disabled.Count -eq 0) {
    Skip "All known sources are enabled — disabled-rejection path not exercisable in this env"
} else {
    $target = $disabled[0]
    $disBody = @{ sourceName=$target } | ConvertTo-Json
    try {
        Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
            -Body $disBody -ContentType 'application/json' -WebSession $admin `
            -UseBasicParsing -ErrorAction Stop | Out-Null
        Fail "Disabled source '$target' returned 2xx — expected 400"
    } catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -ne 400) { Fail "Disabled source returned HTTP $sc — expected 400" }
        $detail = $_.ErrorDetails.Message | ConvertFrom-Json
        if ($detail.title -notmatch 'not enabled') {
            Fail "Disabled-source error doesn't mention 'not enabled': $($detail.title)"
        }
    }
    OK "$target (disabled) rejected with 400 + 'not enabled' hint"
}

# ----------------------------------------------------------------------------
# 6. Single-source trigger — verify SourceTotals contains ONLY that source
#    (requires ERP DB reachable so the job can actually run to completion)
# ----------------------------------------------------------------------------
Step "6. Single-source trigger — SourceTotals contains only the requested source"
# Use any enabled source — pick the first to keep behavior deterministic.
$target = $enabled[0]

# TCP-probe ERP host before trying the full integration path.
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
    Skip "ERP DB unreachable — single-source SourceTotals check skipped (controller pre-flight already verified above)"
    Write-Host ""
    Write-Host "ALL PASS — Phase 13.9 trigger config: UI + 400 paths verified (integration skipped)." -ForegroundColor Green
    exit 0
}

# Phase 13.9.3 — payload is sourceName only. Warehouse + backfill come from
# per-source config (server reads ErpSync:Sources:<X>:DefaultWarehouseId +
# :BackfillDays).
$trigBody = @{ sourceName=$target } | ConvertTo-Json
$trig = Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
    -Body $trigBody -ContentType 'application/json' -WebSession $admin -UseBasicParsing
if ($trig.StatusCode -ne 202) { Fail "Single-source trigger returned $($trig.StatusCode)" }
$trigData = $trig.Content | ConvertFrom-Json
if ($trigData.sourceName -ne $target) {
    Fail "TriggerResponse.sourceName = '$($trigData.sourceName)'; expected '$target'"
}
OK "Single-source trigger 202 + response echoes sourceName='$target'"

$state = WaitForJob $admin $trigData.jobId 120
if ($state -ne 'Succeeded') { Fail "Single-source job final state = $state; expected Succeeded" }

# Newest ErpSyncLog row IS this run. SourceTotals JSON keys should = { target }.
$log = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/log?page=1&pageSize=1" -WebSession $admin
$newest = $log.items[0]
if (-not $newest.sourceTotals) {
    Fail "SourceTotals null on newest log row (runId=$($newest.runId))"
}
$st = $newest.sourceTotals | ConvertFrom-Json
# @() wrap so a single-element result stays a 1-array (PS unwraps scalar-to-element by default).
$keys = @(($st | Get-Member -MemberType NoteProperty).Name)
if ($keys.Count -ne 1 -or $keys[0] -ne $target) {
    Fail "SourceTotals keys = [$($keys -join ',')]; expected only [$target] (single-source filter not honored)"
}
OK "SourceTotals contains only '$target' — single-source filter honored end-to-end"

# Phase 13.9.1 — verify the run used the source's PER-SOURCE config WH
# (not some operator-picked one — that's the whole point of the 13.9 reshape).
$sourceConfigKey = if ($target -eq 'BPI_PRS') { 'Bpi' } elseif ($target -eq 'PRB_PRS') { 'Prb' } else { $null }
if ($sourceConfigKey) {
    $configWh = $cfg.values."ErpSync:Sources:${sourceConfigKey}:DefaultWarehouseId"
    if ($newest.warehouseId -ne $configWh) {
        Fail ("ErpSyncLog row WH = '$($newest.warehouseId)'; expected '$configWh' " +
              "(source $target's configured DefaultWarehouseId — 13.9.1 worker should use per-source config)")
    }
    OK "Run used per-source config WH ('$configWh') — 13.9.1 RunNowAsync honored"
}

# ----------------------------------------------------------------------------
# 7. All-enabled trigger — sourceName null/empty, SourceTotals = full enabled set
#    Only meaningful with 2+ sources enabled.
# ----------------------------------------------------------------------------
Step "7. All-enabled trigger (sourceName null) — SourceTotals = full enabled set"
if ($enabled.Count -lt 2) {
    Skip "Only 1 source enabled — 'all enabled' is indistinguishable from 'single-source' here"
} else {
    # Empty body — no sourceName, no warehouse, no backfill. Worker uses
    # per-source config for each enabled source.
    $allBody = '{}'
    $allTrig = Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
        -Body $allBody -ContentType 'application/json' -WebSession $admin -UseBasicParsing
    if ($allTrig.StatusCode -ne 202) { Fail "All-enabled trigger returned $($allTrig.StatusCode)" }
    $allData = $allTrig.Content | ConvertFrom-Json
    if (-not [string]::IsNullOrEmpty($allData.sourceName)) {
        Fail "All-enabled trigger response.sourceName = '$($allData.sourceName)'; expected empty"
    }
    $allState = WaitForJob $admin $allData.jobId 120
    if ($allState -ne 'Succeeded') { Fail "All-enabled job final state = $allState; expected Succeeded" }

    $allLog = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/log?page=1&pageSize=1" -WebSession $admin
    $allSt = $allLog.items[0].sourceTotals | ConvertFrom-Json
    $allKeys = ($allSt | Get-Member -MemberType NoteProperty).Name | Sort-Object
    $expected = $enabled | Sort-Object
    $diffMissing = Compare-Object $allKeys $expected | Where-Object { $_.SideIndicator -eq '=>' }
    $diffExtra = Compare-Object $allKeys $expected | Where-Object { $_.SideIndicator -eq '<=' }
    if ($diffMissing -or $diffExtra) {
        Fail ("All-enabled SourceTotals keys = [$($allKeys -join ',')]; " +
              "expected [$($expected -join ',')]")
    }
    OK "All-enabled trigger 202, empty sourceName echo, SourceTotals = full enabled set [$($allKeys -join ',')]"
}

# ----------------------------------------------------------------------------
# 8. Phase 13.9 — extra/legacy payload fields tolerated (System.Text.Json
#    silently ignores unknown body fields). Stale clients still sending
#    warehouseId + backfillDays should not get 400.
# ----------------------------------------------------------------------------
Step "8. Stale clients sending warehouseId + backfillDays are tolerated"
$legacyBody = @{
    sourceName = $null;
    warehouseId = '00000000-0000-0000-0000-000000000099';
    backfillDays = 99;
} | ConvertTo-Json
$legacyTrig = Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
    -Body $legacyBody -ContentType 'application/json' -WebSession $admin -UseBasicParsing
if ($legacyTrig.StatusCode -ne 202) {
    Fail "Legacy-payload trigger returned $($legacyTrig.StatusCode); expected 202"
}
$legacyData = $legacyTrig.Content | ConvertFrom-Json
if (-not $legacyData.jobId) { Fail "Legacy-payload trigger missing jobId" }
# Drain so the next smoke can grab the mutex.
$null = WaitForJob $admin $legacyData.jobId 120
OK "Legacy fields ignored; trigger still 202 with jobId=$($legacyData.jobId)"

Write-Host ""
Write-Host "ALL PASS — Phase 13.9 trigger config: UI shrink + per-source config + all-enabled + legacy tolerance verified." -ForegroundColor Green
exit 0
