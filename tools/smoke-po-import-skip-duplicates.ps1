# Smoke: PO import skips duplicate PoNumbers instead of failing the file.
#
# Behavioral. Stage 2 used to wrap the whole file in ONE transaction and roll
# everything back if any single PoNumber already existed — a workbook carrying
# one already-imported PO imported NOTHING. This smoke is the regression guard
# for that: new POs must land, duplicates must skip, run must still succeed.
#
# Fixture: REUSES tools/fixtures/po-import-sample.xlsx (the 12.7 fixture —
# 4 rows / 2 PoNumbers, P127TEST-001 and P127TEST-002, 2 lines each). No
# dedicated fixture is needed: the contract only requires >=1 duplicate and
# >=1 new PoNumber, and a file must exist on disk only because
# PoImportJob.RunAsync re-parses from log.StoragePath.
#
# The duplicate is P127TEST-001, which sits FIRST in file order — deliberately
# the worst case, since under the old behavior a leading duplicate rolled back
# the POs that came after it.
#
# COUPLING: shares the 12.7 fixture and its P127TEST-% namespace. Both smokes
# purge that prefix on entry AND exit, and 12.7 asserts zero residual after its
# own pre-cleanup, so a crash here cannot leak a seeded duplicate into 12.7.
# This holds because the battery runs sequentially; these two must never run
# concurrently against the same database.
#
# ACCEPTED COVERAGE GAP: this proves skip and insert coexist in one run and
# that the run succeeds. It does NOT prove insert→skip→insert mid-loop
# ordering (would need >=3 PoNumbers). That's acceptable: each PO commits in
# its own transaction, so a group's outcome cannot depend on its position
# relative to a skipped group. The loop-position risk the old code had —
# one rollback discarding everything — is structurally gone.
#
# Asserts:
#   1. Fixture present
#   2. Pre-cleanup leaves zero P127TEST-% rows
#   3. Seed P127TEST-001 as a pre-existing PurchaseOrder (the duplicate)
#   4. Login as supervisor @ WH-01
#   5. Upload → 'validated', 4 rows / 2 POs
#   6. Confirm → enqueued
#   7. Poll to terminal → 'succeeded' (NOT 'failed' — the old behavior)
#   8. PosInserted=1, PosSkipped=1, SkippedPoNumbers contains P127TEST-001
#   9. The NEW PoNumber (P127TEST-002) exists with its 2 lines
#  10. The DUPLICATE PO is untouched — still 0 lines (no upsert-into-existing)
#  11. Audit row is 'po-import-partial' (skips > 0), not 'po-import-succeeded'
#  12. Teardown leaves zero P127TEST-% residue

$ErrorActionPreference = 'Stop'

$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$fixturePath = Join-Path $repoRoot 'tools\fixtures\po-import-sample.xlsx'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'

$DUP_PO = 'P127TEST-001'   # seeded as pre-existing → must SKIP
$NEW_PO = 'P127TEST-002'   # not seeded            → must IMPORT

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Sql($q)  { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }
function Scalar($q) { return ((Sql $q) -join '' -replace '\s','') }

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Mirrors smoke-phase-12-7's Cleanup-Fixture. Must stay in sync with it —
# both smokes own the P127TEST-% + po-import-sample% namespace.
function Cleanup-Fixture {
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
OK "Fixture file present (shared with smoke-phase-12-7)"

# ----------------------------------------------------------------------------
# 2. Pre-cleanup
# ----------------------------------------------------------------------------
Step "Pre-cleanup — no residual P127TEST-% data"
Cleanup-Fixture
$resid = Scalar "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P127TEST-%';"
if ($resid -ne '0') { Fail "Pre-cleanup left $resid PurchaseOrders behind" }
OK "Pre-cleanup clean"

# ----------------------------------------------------------------------------
# 3. Seed the duplicate
# ----------------------------------------------------------------------------
# Minimal PurchaseOrder — no lines. Lines would only obscure assertion 10
# (the duplicate must be left untouched); zero lines makes "still 0 lines"
# an unambiguous proof that Stage 2 didn't upsert into it.
# CreatedBy is FK → Users.Id, so borrow any existing user.
Step "Seed $DUP_PO as a pre-existing PurchaseOrder"
Sql @"
SET NOCOUNT ON;
INSERT INTO dbo.PurchaseOrders
    (Id, PoNumber, WarehouseId, PullId, PullExternalRef,
     OrderDate, ExpectedDate, Status, Notes, CreatedBy, CreatedAt)
VALUES
    (NEWID(), '$DUP_PO', '$WH_01', NULL, NULL,
     CAST(SYSUTCDATETIME() AS DATE), NULL, 'open', 'seeded by smoke-po-import-skip-duplicates',
     (SELECT TOP 1 Id FROM dbo.Users ORDER BY Id), SYSUTCDATETIME());
"@ | Out-Null

$seeded = Scalar "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber = '$DUP_PO';"
if ($seeded -ne '1') { Fail "Seed failed — expected 1 row for $DUP_PO, found $seeded" }
OK "$DUP_PO seeded (the file's FIRST PoNumber — worst case for the old all-or-nothing bug)"

# ----------------------------------------------------------------------------
# 4. Login
# ----------------------------------------------------------------------------
# psomchai, not swattana. Both are seeded as WH-01 supervisors by db/005, but
# psomchai's assignment is the one that survives on drifted dev databases —
# swattana's WH-01 row has been reassigned to WH-BPI on at least one dev box,
# which 403s the login. psomchai works on a freshly-seeded DB and a drifted one.
Step "Login as supervisor (psomchai @ WH-01)"
$sup = Login 'psomchai' 'demo1234' $WH_01
$me = Invoke-RestMethod -Uri "$base/api/auth/me" -WebSession $sup
if ($me.roleKey -ne 'supervisor') { Fail "Session role='$($me.roleKey)', expected 'supervisor'" }
OK "Logged in as $($me.name)"

# ----------------------------------------------------------------------------
# 5. Upload
# ----------------------------------------------------------------------------
# Stage 1 does not consult the DB for duplicates in this commit, so the file
# still validates cleanly — the duplicate is Stage 2's business.
Step "POST /api/imports/po/upload"
$uploadResp = Invoke-RestMethod -Uri "$base/api/imports/po/upload" `
    -Method POST -WebSession $sup `
    -Form @{ file = Get-Item -LiteralPath $fixturePath }

if ($uploadResp.status -ne 'validated') { Fail "Upload status='$($uploadResp.status)', expected 'validated'" }
if ($uploadResp.distinctPoCount -ne 2)  { Fail "distinctPoCount=$($uploadResp.distinctPoCount), expected 2" }
$runId = [Guid]::Parse($uploadResp.runId)
OK "Upload validated (runId=$runId, 4 rows / 2 POs)"

# ----------------------------------------------------------------------------
# 6. Confirm
# ----------------------------------------------------------------------------
Step "POST /api/imports/po/$runId/confirm"
$confirmResp = Invoke-RestMethod -Uri "$base/api/imports/po/$runId/confirm" -Method POST -WebSession $sup
if (-not $confirmResp.hangfireJobId) { Fail "Confirm response missing hangfireJobId" }
OK "Confirm accepted (Hangfire jobId=$($confirmResp.hangfireJobId))"

# ----------------------------------------------------------------------------
# 7. Poll to terminal — MUST be 'succeeded'
# ----------------------------------------------------------------------------
# This is the headline regression assertion. The old all-or-nothing job threw
# on the duplicate and marked the run 'failed'.
Step "Poll until terminal (60s cap) — expect 'succeeded', not 'failed'"
$final = $null
$attempts = 0
while ($attempts -lt 30) {
    $attempts++
    Start-Sleep -Seconds 2
    try { $cur = Invoke-RestMethod -Uri "$base/api/imports/po/$runId" -WebSession $sup }
    catch { Fail "GET drill-down failed during polling: $($_.Exception.Message)" }
    if ($cur.status -in @('succeeded', 'failed')) { $final = $cur; break }
}
if (-not $final) { Fail "Run did not reach a terminal state within 60s — last status was $($cur.status)" }
if ($final.status -ne 'succeeded') {
    Fail "Run status='$($final.status)', expected 'succeeded' — a duplicate PoNumber must NOT fail the run. ErrorMessage: $($final.errorMessage)"
}
OK "Run reached 'succeeded' after $attempts polls despite the duplicate"

# ----------------------------------------------------------------------------
# 8. Counts + skipped list
# ----------------------------------------------------------------------------
Step "PosInserted=1, PosSkipped=1, SkippedPoNumbers names $DUP_PO"
if ($final.posInserted -ne 1)   { Fail "PosInserted=$($final.posInserted), expected 1 (only $NEW_PO is new)" }
if ($final.linesInserted -ne 2) { Fail "LinesInserted=$($final.linesInserted), expected 2 (the new PO's lines only)" }
if ($final.posSkipped -ne 1)    { Fail "PosSkipped=$($final.posSkipped), expected 1" }
if (-not $final.skippedPoNumbers) { Fail "SkippedPoNumbers is null/empty — expected a JSON array naming $DUP_PO" }

$skippedList = $final.skippedPoNumbers | ConvertFrom-Json
if ($skippedList -notcontains $DUP_PO) {
    Fail "SkippedPoNumbers=$($final.skippedPoNumbers) does not contain $DUP_PO"
}
if ($skippedList -contains $NEW_PO) {
    Fail "SkippedPoNumbers wrongly contains $NEW_PO — that PO was new and must have imported"
}
OK "Counts correct + SkippedPoNumbers=$($final.skippedPoNumbers)"

# ----------------------------------------------------------------------------
# 9. The new PO actually landed
# ----------------------------------------------------------------------------
# Counts on the log row could be right while the rows never committed —
# assert against the real tables, not the job's own bookkeeping.
Step "$NEW_PO exists in dbo.PurchaseOrders with its 2 lines"
$newPoCount = Scalar "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber = '$NEW_PO';"
if ($newPoCount -ne '1') { Fail "$NEW_PO count=$newPoCount, expected 1 — the new PO did not import" }

$newLineCount = Scalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.PurchaseOrderLines
WHERE  PurchaseOrderId = (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber = '$NEW_PO');
"@
if ($newLineCount -ne '2') { Fail "$NEW_PO line count=$newLineCount, expected 2" }
OK "$NEW_PO imported with 2 lines — a leading duplicate did not block it"

# ----------------------------------------------------------------------------
# 10. The duplicate PO is untouched
# ----------------------------------------------------------------------------
# Duplicate grain is the PoNumber GROUP: a skipped PO must be left completely
# alone. If Stage 2 ever gained an upsert path, the seeded PO would sprout the
# fixture's 2 lines and this assertion would catch it.
Step "$DUP_PO left untouched — still 0 lines, still the seeded row"
$dupPoCount = Scalar "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber = '$DUP_PO';"
if ($dupPoCount -ne '1') { Fail "$DUP_PO count=$dupPoCount, expected exactly 1 (no duplicate row inserted)" }

$dupLineCount = Scalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.PurchaseOrderLines
WHERE  PurchaseOrderId = (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber = '$DUP_PO');
"@
if ($dupLineCount -ne '0') {
    Fail "$DUP_PO has $dupLineCount lines, expected 0 — a skipped PO must not be upserted into"
}

$dupNotes = Scalar "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber = '$DUP_PO' AND Notes LIKE 'seeded by smoke%';"
if ($dupNotes -ne '1') { Fail "$DUP_PO no longer carries the seeded Notes — the skipped PO was modified" }
OK "$DUP_PO untouched (0 lines, original row intact)"

# ----------------------------------------------------------------------------
# 11. Audit — po-import-partial
# ----------------------------------------------------------------------------
Step "AuditLog carries 'po-import-partial' for the run"
$partialCount = Scalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.AuditLog
WHERE  EntityType = 'PoImportLog'
  AND  EntityId = '$runId'
  AND  ActionType = 'po-import-partial';
"@
if ($partialCount -ne '1') {
    Fail "Expected exactly 1 'po-import-partial' audit row for RunId=$runId, found $partialCount"
}
# A run WITH skips must not also claim a clean success.
$succeededCount = Scalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.AuditLog
WHERE  EntityType = 'PoImportLog'
  AND  EntityId = '$runId'
  AND  ActionType = 'po-import-succeeded';
"@
if ($succeededCount -ne '0') {
    Fail "Run with skips wrote 'po-import-succeeded' ($succeededCount rows) — expected 'po-import-partial' only"
}
# ActionType is VARCHAR(32) since db/032; verify the full string survived the
# INSERT rather than truncating (the exact defect db/032 was written to fix).
$notTruncated = Scalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.AuditLog
WHERE  EntityType = 'PoImportLog' AND EntityId = '$runId'
  AND  ActionType = 'po-import-partial' AND LEN(ActionType) = 17;
"@
if ($notTruncated -ne '1') { Fail "'po-import-partial' did not survive the INSERT intact (LEN != 17)" }
OK "Audit: exactly 1 'po-import-partial', no 'po-import-succeeded', not truncated"

# ----------------------------------------------------------------------------
# 12. Teardown
# ----------------------------------------------------------------------------
Step "Teardown — remove all P127TEST-% rows this smoke seeded or created"
Cleanup-Fixture
$after = Scalar "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P127TEST-%';"
if ($after -ne '0') { Fail "Teardown left $after PurchaseOrders behind — smoke-phase-12-7 shares this prefix" }
OK "Teardown clean — no residue for smoke-phase-12-7"

Write-Host ""
Write-Host "ALL PASS — PO import skips duplicates: new POs land, duplicates skip, run succeeds." -ForegroundColor Green
exit 0
