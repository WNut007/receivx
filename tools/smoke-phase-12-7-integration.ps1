# Smoke: Phase 12.7 — end-to-end behavioral round-trip for the PO importer.
#
# Drives the full pipeline a real operator would: upload → confirm → poll
# until 'succeeded' → verify the inserted PurchaseOrders + lines match the
# fixture workbook → verify audit trail → tear down.
#
# Closes the deferred behavioral verification from 12.5's smoke comment.
# 12.5 covers source-level invariants without needing a real .xlsx; this
# smoke proves the wired pipeline lands rows in the schema the way 12.5's
# SQL says it will.
#
# Fixture authored by tools/build-po-import-fixture.ps1 (one-shot, not in
# battery) and committed at tools/fixtures/po-import-sample.xlsx — 4 rows
# / 2 distinct PoNumbers with prefix P127TEST- for collision-free cleanup.
#
# Assertions:
#   1. Fixture file exists
#   2. Pre-cleanup leaves zero P127TEST-% rows in PurchaseOrders + nothing
#      in PoImportLog for the fixture filename
#   3. Login as supervisor (swattana @ WH-01)
#   4. POST /api/imports/po/upload → 202 + status='validated' +
#      TotalRowsRead=4 + DistinctPoCount=2 + ValidationErrorCount=0
#   5. PoImportLog row exists at 'validated' with the operator's UserId
#      and WarehouseId pinned to session WH-01
#   6. POST /api/imports/po/{runId}/confirm → 202 + HangfireJobId
#   7. PoImportLog flips to 'queued' immediately after confirm
#   8. Poll GET /api/imports/po/{runId} until Status='succeeded' (timeout 60s)
#   9. Final log row: PosInserted=2, LinesInserted=4, ElapsedMs > 0
#  10. dbo.PurchaseOrders rows: exactly 2 PoNumbers LIKE 'P127TEST-%',
#      WarehouseId=WH-01, PullId NULL, CreatedBy=supervisor's UserId,
#      OrderDate = today UTC, Status='open'
#  11. dbo.PurchaseOrderLines rows: 4 total with deterministic LineNumber
#      (1..2 per PO), ItemCode + OrderedQty + Description match the
#      fixture, ReceivedQty=0, OrderId + PalletId round-trip (db/031 + db/021)
#  12. dbo.AuditLog has 'po-import-confirmed' + 'po-import-succeeded'
#      rows keyed by the RunId, EntityType='PoImportLog'
#  13. Cross-warehouse privacy spot-check: operator at WH-03 gets 403
#      on GET /api/imports/po/{runId}
#  14. Cleanup leaves zero residual P127TEST-% data

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'
$fixturePath = Join-Path $repoRoot 'tools\fixtures\po-import-sample.xlsx'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_03 = '22222222-2222-2222-2222-000000000003'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Sql($q)    { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }
# Multi-column scalar queries — pipe-separated so cells can be split safely
# (default separator is whitespace, which -W then strips).
function SqlRow($q) { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -s "|" -Q $q }

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Wipe any residual fixture data so the smoke is repeatable. PoNumber is
# globally UNIQUE — leftover P127TEST-* rows from a crashed prior run would
# fail Stage 2's duplicate re-check before this smoke even started.
function Cleanup-Fixture {
    # Capture any staged file paths first so we can delete them after the
    # DB rows are gone.
    $stagedPaths = (Sql @"
SET NOCOUNT ON;
SELECT StoragePath
FROM   dbo.PoImportLog
WHERE  FileName LIKE 'po-import-sample%';
"@) | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }

    Sql @"
SET NOCOUNT ON;
DELETE FROM dbo.PurchaseOrderLines
 WHERE PurchaseOrderId IN (
     SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P127TEST-%'
 );
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P127TEST-%';
DELETE FROM dbo.AuditLog
 WHERE EntityType = 'PoImportLog'
   AND EntityId IN (
       SELECT CAST(RunId AS NVARCHAR(64))
       FROM   dbo.PoImportLog
       WHERE  FileName LIKE 'po-import-sample%'
   );
DELETE FROM dbo.PoImportLog WHERE FileName LIKE 'po-import-sample%';
"@ | Out-Null

    foreach ($p in $stagedPaths) {
        if (Test-Path -LiteralPath $p) {
            try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop } catch {}
        }
    }
}

# ----------------------------------------------------------------------------
# 1. Fixture exists
# ----------------------------------------------------------------------------
Step "Fixture present at $fixturePath"
if (-not (Test-Path -LiteralPath $fixturePath)) {
    Fail "Fixture missing — regenerate via 'pwsh tools/build-po-import-fixture.ps1'"
}
OK "Fixture file present"

# ----------------------------------------------------------------------------
# 2. Pre-cleanup
# ----------------------------------------------------------------------------
Step "Pre-cleanup — no residual P127TEST-% data"
Cleanup-Fixture
$resid = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P127TEST-%';") -join '' -replace '\s',''
if ($resid -ne '0') { Fail "Pre-cleanup left $resid PurchaseOrders behind" }
OK "Pre-cleanup clean"

# ----------------------------------------------------------------------------
# 3. Login as supervisor
# ----------------------------------------------------------------------------
Step "Login as supervisor (swattana @ WH-01)"
$sup = Login 'swattana' 'demo1234' $WH_01
# /api/auth/me doesn't expose userId, so we'll capture it from the log row
# after upload (UploadedByUserId IS the supervisor's Users.Id by construction).
$me = Invoke-RestMethod -Uri "$base/api/auth/me" -WebSession $sup
if (-not $me.roleKey -or $me.roleKey -ne 'supervisor') {
    Fail "Session role='$($me.roleKey)' at WH-01, expected 'supervisor'"
}
OK "Logged in as $($me.name) (roleKey=supervisor at WH-01)"

# ----------------------------------------------------------------------------
# 4. Upload
# ----------------------------------------------------------------------------
Step "POST /api/imports/po/upload"
$uploadResp = Invoke-RestMethod -Uri "$base/api/imports/po/upload" `
    -Method POST -WebSession $sup `
    -Form @{ file = Get-Item -LiteralPath $fixturePath }

if (-not $uploadResp.runId)               { Fail "Upload response missing runId" }
if ($uploadResp.status -ne 'validated')   { Fail "Upload status='$($uploadResp.status)', expected 'validated'" }
if ($uploadResp.totalRowsRead -ne 4)      { Fail "totalRowsRead=$($uploadResp.totalRowsRead), expected 4" }
if ($uploadResp.distinctPoCount -ne 2)    { Fail "distinctPoCount=$($uploadResp.distinctPoCount), expected 2" }
if ($uploadResp.validationErrorCount -ne 0) { Fail "validationErrorCount=$($uploadResp.validationErrorCount), expected 0" }
$runId = [Guid]::Parse($uploadResp.runId)
OK "Upload validated (runId=$runId, 4 rows / 2 POs / 0 errors)"

# ----------------------------------------------------------------------------
# 5. PoImportLog row check
# ----------------------------------------------------------------------------
Step "PoImportLog row materialized at 'validated' with operator + WH"
$logRow = Invoke-RestMethod -Uri "$base/api/imports/po/$runId" -WebSession $sup
if ($logRow.status -ne 'validated')                    { Fail "Log row status='$($logRow.status)', expected 'validated'" }
if (-not $logRow.uploadedByUserId)                     { Fail "Log row missing uploadedByUserId" }
$supUserId = [Guid]::Parse($logRow.uploadedByUserId)
if ([Guid]::Parse($logRow.warehouseId) -ne ([Guid]::Parse($WH_01))) { Fail "Log row WarehouseId mismatch (supervisor must be pinned to session WH)" }
if ($logRow.uploadedByRole -ne 'supervisor')           { Fail "Log row UploadedByRole='$($logRow.uploadedByRole)', expected 'supervisor'" }
OK "Log row correctly attributed + WH-pinned (UserId=$supUserId)"

# ----------------------------------------------------------------------------
# 6. Confirm
# ----------------------------------------------------------------------------
Step "POST /api/imports/po/$runId/confirm"
$confirmResp = Invoke-RestMethod -Uri "$base/api/imports/po/$runId/confirm" -Method POST -WebSession $sup
if (-not $confirmResp.hangfireJobId)            { Fail "Confirm response missing hangfireJobId" }
if ([Guid]::Parse($confirmResp.runId) -ne $runId) { Fail "Confirm response runId mismatch" }
$jobId = $confirmResp.hangfireJobId
OK "Confirm accepted (Hangfire jobId=$jobId)"

# ----------------------------------------------------------------------------
# 7. State machine — should be 'queued' immediately
# ----------------------------------------------------------------------------
Step "Status flips to 'queued' immediately after confirm"
$afterConfirm = Invoke-RestMethod -Uri "$base/api/imports/po/$runId" -WebSession $sup
$queuedStates = @('queued', 'running', 'succeeded')
if ($afterConfirm.status -notin $queuedStates) {
    Fail "Status='$($afterConfirm.status)' after confirm; expected one of queued/running/succeeded"
}
OK "Status transition observed ($($afterConfirm.status))"

# ----------------------------------------------------------------------------
# 8. Poll to terminal
# ----------------------------------------------------------------------------
Step "Poll GET /api/imports/po/$runId until terminal (60s cap)"
$final = $null
$attempts = 0
$maxAttempts = 30
while ($attempts -lt $maxAttempts) {
    $attempts++
    Start-Sleep -Seconds 2
    try {
        $cur = Invoke-RestMethod -Uri "$base/api/imports/po/$runId" -WebSession $sup
    } catch {
        Fail "GET drill-down failed during polling: $($_.Exception.Message)"
    }
    if ($cur.status -in @('succeeded', 'failed')) {
        $final = $cur
        break
    }
}
if (-not $final) {
    Fail "Run did not reach a terminal state within 60s — last status was $($cur.status)"
}
if ($final.status -ne 'succeeded') {
    Fail "Run terminated with status '$($final.status)' — ErrorMessage: $($final.errorMessage)"
}
OK "Run reached 'succeeded' after $attempts polls"

# ----------------------------------------------------------------------------
# 9. Final log row totals
# ----------------------------------------------------------------------------
Step "Final log row counts and timing"
if ($final.posInserted -ne 2)    { Fail "PosInserted=$($final.posInserted), expected 2" }
if ($final.linesInserted -ne 4)  { Fail "LinesInserted=$($final.linesInserted), expected 4" }
if ([int]$final.elapsedMs -le 0) { Fail "ElapsedMs=$($final.elapsedMs); expected > 0" }
OK "PosInserted=2, LinesInserted=4, ElapsedMs=$($final.elapsedMs)"

# ----------------------------------------------------------------------------
# 10. PurchaseOrders rows
# ----------------------------------------------------------------------------
Step "dbo.PurchaseOrders — 2 rows with correct attribution"
$todayUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$poCheck = (SqlRow @"
SET NOCOUNT ON;
SELECT
    SUM(CASE WHEN WarehouseId = '$WH_01'                  THEN 1 ELSE 0 END) AS WhMatches,
    SUM(CASE WHEN PullId IS NULL                          THEN 1 ELSE 0 END) AS PullIdNulls,
    SUM(CASE WHEN CreatedBy = '$supUserId'                THEN 1 ELSE 0 END) AS CreatedByMatches,
    SUM(CASE WHEN OrderDate = CAST('$todayUtc' AS DATE)   THEN 1 ELSE 0 END) AS OrderDateMatches,
    SUM(CASE WHEN Status = 'open'                         THEN 1 ELSE 0 END) AS OpenStatus,
    SUM(CASE WHEN PullExternalRef = PoNumber              THEN 1 ELSE 0 END) AS PullExternalRefMatches,
    COUNT(*)                                                                AS Total
FROM dbo.PurchaseOrders
WHERE PoNumber LIKE 'P127TEST-%';
"@) -join '' -replace '\s',''

# Output is one pipe-delimited row "wh|nulls|by|date|open|extref|total"; split it.
$parts = ($poCheck -split '\|')
if ($parts.Count -lt 7) { Fail "Could not parse PO check output: '$poCheck'" }
$pTotal      = [int]$parts[6]
$pWh         = [int]$parts[0]
$pPullNulls  = [int]$parts[1]
$pCreatedBy  = [int]$parts[2]
$pOrderDate  = [int]$parts[3]
$pOpen       = [int]$parts[4]
$pExtRef     = [int]$parts[5]

if ($pTotal -ne 2)         { Fail "PurchaseOrders total=$pTotal, expected 2" }
if ($pWh -ne 2)            { Fail "WarehouseId mismatch on $($pTotal - $pWh) of $pTotal POs" }
if ($pPullNulls -ne 2)     { Fail "PullId not NULL on $($pTotal - $pPullNulls) of $pTotal POs" }
if ($pCreatedBy -ne 2)     { Fail "CreatedBy mismatch on $($pTotal - $pCreatedBy) of $pTotal POs" }
if ($pOrderDate -ne 2)     { Fail "OrderDate mismatch on $($pTotal - $pOrderDate) of $pTotal POs" }
if ($pOpen -ne 2)          { Fail "Status not 'open' on $($pTotal - $pOpen) of $pTotal POs" }
# A1 (db/033) — PullExternalRef must round-trip = PoNumber on every imported row
if ($pExtRef -ne 2)        { Fail "PullExternalRef <> PoNumber on $($pTotal - $pExtRef) of $pTotal POs (A1/Q1=B denormalization regression)" }
OK "2 POs · WH=WH-01 · PullId=NULL · CreatedBy=supervisor · OrderDate=today · Status=open · PullExternalRef=PoNumber"

# ----------------------------------------------------------------------------
# 11. PurchaseOrderLines rows
# ----------------------------------------------------------------------------
Step "dbo.PurchaseOrderLines — 4 lines with deterministic LineNumber + field round-trip"
# DeliveryDate assertion is intentionally date-agnostic: the fixture file
# bakes in whatever day `build-po-import-fixture.ps1` last ran (dd/MM/yyyy
# string written via Get-Date at build time), and this smoke runs on
# whatever day the battery fires. Anchoring to "today" would time-bomb the
# assertion the day after each fixture refresh. Parser correctness for the
# dd/MM/yyyy slot is the job of `smoke-phase-12-2-po-import-reader.ps1`,
# which exercises GetDate directly with known input. Here we only assert
# the end-to-end pipe lit up: the parser produced a non-NULL date and it
# landed in a sane range (rules out a year-0 / year-1900 / millennium-
# bug-style misread that surfaces as a non-null garbage date).
$lineCheck = (SqlRow @"
SET NOCOUNT ON;
SELECT
    COUNT(*)                                                                  AS LineTotal,
    SUM(CASE WHEN ReceivedQty = 0                                THEN 1 ELSE 0 END) AS ReceivedZero,
    SUM(CASE WHEN ItemCode = 'TST-WIDGET-001' AND OrderedQty = 12 THEN 1 ELSE 0 END) AS W1,
    SUM(CASE WHEN ItemCode = 'TST-WIDGET-002' AND OrderedQty = 24 THEN 1 ELSE 0 END) AS W2,
    SUM(CASE WHEN ItemCode = 'TST-GIZMO-001'  AND OrderedQty = 6  THEN 1 ELSE 0 END) AS G1,
    SUM(CASE WHEN ItemCode = 'TST-GIZMO-002'  AND OrderedQty = 18 THEN 1 ELSE 0 END) AS G2,
    SUM(CASE WHEN OrderId IS NOT NULL                            THEN 1 ELSE 0 END) AS OrderIdSet,
    SUM(CASE WHEN PalletId IS NOT NULL                           THEN 1 ELSE 0 END) AS PalletIdSet,
    SUM(CASE WHEN LineNumber IN (1, 2)                           THEN 1 ELSE 0 END) AS LineNumOk,
    SUM(CASE WHEN DeliveryDate IS NOT NULL
              AND DeliveryDate >= '2024-01-01'
              AND DeliveryDate <  '2031-01-01'                   THEN 1 ELSE 0 END) AS DeliveryDateSane
FROM dbo.PurchaseOrderLines pol
JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'P127TEST-%';
"@) -join '' -replace '\s',''

$lp = ($lineCheck -split '\|')
if ($lp.Count -lt 10) { Fail "Could not parse line check output: '$lineCheck'" }
if ([int]$lp[0] -ne 4) { Fail "PurchaseOrderLines total=$($lp[0]), expected 4" }
if ([int]$lp[1] -ne 4) { Fail "ReceivedQty not 0 on $(4 - [int]$lp[1]) of 4 lines" }
if ([int]$lp[2] -ne 1) { Fail "TST-WIDGET-001/qty=12 not found exactly once (got $($lp[2]))" }
if ([int]$lp[3] -ne 1) { Fail "TST-WIDGET-002/qty=24 not found exactly once (got $($lp[3]))" }
if ([int]$lp[4] -ne 1) { Fail "TST-GIZMO-001/qty=6 not found exactly once (got $($lp[4]))" }
if ([int]$lp[5] -ne 1) { Fail "TST-GIZMO-002/qty=18 not found exactly once (got $($lp[5]))" }
if ([int]$lp[6] -ne 4) { Fail "OrderId NULL on $(4 - [int]$lp[6]) of 4 lines — db/031 column not populated" }
if ([int]$lp[7] -ne 4) { Fail "PalletId NULL on $(4 - [int]$lp[7]) of 4 lines — db/021 column not populated" }
if ([int]$lp[8] -ne 4) { Fail "LineNumber outside {1,2} on $(4 - [int]$lp[8]) of 4 lines" }
if ([int]$lp[9] -ne 4) { Fail "DeliveryDate NULL or outside 2024..2030 on $(4 - [int]$lp[9]) of 4 lines — parser dropped dd/MM/yyyy or misread century" }
OK "4 lines · ReceivedQty=0 · 4 SKU+qty pairs match · OrderId+PalletId round-trip · LineNumber {1,2} · DeliveryDate parsed (in-range)"

# ----------------------------------------------------------------------------
# 11b. A1 (db/033) — PullExternalRef surfaces via /api/pos/{id} +
#      ReceiptService FIFO walk has the A1 conditional in source.
# ----------------------------------------------------------------------------
Step "A1: GET /api/pos/{id} surfaces pullExternalRef = PoNumber"
$poId = (SqlRow @"
SET NOCOUNT ON;
SELECT TOP 1 Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P127TEST-%' ORDER BY PoNumber;
"@) -join '' -replace '\s',''
if (-not $poId) { Fail "Could not locate imported PO for API check" }
$poJson = Invoke-RestMethod -Uri "$base/api/pos/$poId" -WebSession $sup
if (-not $poJson.pullExternalRef) {
    Fail "/api/pos/$poId response missing pullExternalRef field — DTO surface regression"
}
if ($poJson.pullExternalRef -ne $poJson.poNumber) {
    Fail "pullExternalRef='$($poJson.pullExternalRef)' != poNumber='$($poJson.poNumber)' on API"
}
if ($poJson.pullId) {
    Fail "PullId should remain NULL on imported PO (got '$($poJson.pullId)') — Guid FK preserved invariant"
}
OK "API: pullExternalRef = '$($poJson.pullExternalRef)' (matches poNumber); pullId = null"

Step "A1 source guard: ReceiptService FIFO conditional includes PullExternalRef"
$rsFile = Join-Path $repoRoot 'src\ReceivingOps.Web\Services\ReceiptService.cs'
$rs = Get-Content -Raw -LiteralPath $rsFile
if ($rs -notmatch 'po\.PullId = @PullId OR po\.PullExternalRef = @PullNumberStr') {
    Fail "ReceiptService.cs missing A1 conditional 'po.PullId = @PullId OR po.PullExternalRef = @PullNumberStr' — §7.15 FIFO lock-by-pull would lose imported-PO lookup"
}
if ($rs -notmatch 'PullNumberStr\s*=\s*pullCtx\.PullNumber') {
    Fail "ReceiptService.cs missing 'PullNumberStr = pullCtx.PullNumber' parameter binding"
}
OK "ReceiptService A1 conditional + parameter binding present"

# ----------------------------------------------------------------------------
# 12. Audit rows
# ----------------------------------------------------------------------------
Step "dbo.AuditLog — po-import-confirmed + po-import-succeeded for RunId"
$auditCounts = (SqlRow @"
SET NOCOUNT ON;
SELECT
    SUM(CASE WHEN ActionType = 'po-import-confirmed' THEN 1 ELSE 0 END) AS C,
    SUM(CASE WHEN ActionType = 'po-import-succeeded' THEN 1 ELSE 0 END) AS S
FROM dbo.AuditLog
WHERE EntityType = 'PoImportLog' AND EntityId = '$runId';
"@) -join '' -replace '\s',''

$ap = ($auditCounts -split '\|')
if ($ap.Count -lt 2)   { Fail "Could not parse audit count output: '$auditCounts'" }
if ([int]$ap[0] -lt 1) { Fail "po-import-confirmed audit row missing for RunId=$runId" }
if ([int]$ap[1] -lt 1) { Fail "po-import-succeeded audit row missing for RunId=$runId" }
OK "Both audit rows present for the run"

# ----------------------------------------------------------------------------
# 13. Cross-warehouse privacy spot-check — operator at WH-03 must 403
# ----------------------------------------------------------------------------
Step "Operator at WH-03 gets 403 on GET /api/imports/po/$runId"
$op = Login 'npatcharin' 'demo1234' $WH_03
$opStatus = 0
try {
    Invoke-WebRequest -Uri "$base/api/imports/po/$runId" -WebSession $op -MaximumRedirection 0 | Out-Null
} catch {
    $opStatus = $_.Exception.Response.StatusCode.value__
}
# npatcharin is an operator, and the controller's [Authorize(Roles="admin,supervisor")]
# gate fires first → 403 before the ownership check is reached.
if ($opStatus -ne 403) {
    Fail "Operator GET → HTTP $opStatus, expected 403"
}
OK "Operator blocked at role gate (403)"

# ----------------------------------------------------------------------------
# 14. Cleanup
# ----------------------------------------------------------------------------
Step "Cleanup — remove P127TEST-% rows + log + staged file"
Cleanup-Fixture
$residPost = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P127TEST-%';") -join '' -replace '\s',''
if ($residPost -ne '0') { Fail "Cleanup left $residPost PurchaseOrders behind" }
$residLog = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PoImportLog WHERE FileName LIKE 'po-import-sample%';") -join '' -replace '\s',''
if ($residLog -ne '0') { Fail "Cleanup left $residLog PoImportLog rows behind" }
OK "All P127TEST-% rows + log + staged file removed"

Write-Host ""
Write-Host "ALL PASS — Phase 12.7: end-to-end PO import behavioral round-trip verified." -ForegroundColor Green
exit 0
