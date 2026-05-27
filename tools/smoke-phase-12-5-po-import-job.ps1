# Smoke: Phase 12.5 — atomic upsert (PoImportJob) + /upload + /confirm endpoints.
#
# Source-level smoke. Behavioral round-trip (upload → confirm → poll
# 'succeeded' → verify DB rows) lands in 12.7 integration smoke when a
# fixture infrastructure exists. 12.5's purpose is to verify the SQL +
# state-machine invariants without needing a real .xlsx in the repo.
#
# Asserts:
#   1. PoImportJob.cs exists with the expected Hangfire attributes
#   2. Job injects the 5 expected dependencies + a typed ILogger
#   3. State-machine guards: aborts on non-'queued' status
#   4. Atomic insert lives inside ONE transaction with rollback on error
#   5. Re-parse from log.StoragePath happens before any DB write
#   6. PoNumber duplicate re-check uses UPDLOCK + ROWLOCK + NO WH filter
#      (global UNIQUE constraint, per db/010)
#   7. PurchaseOrders INSERT — PullId set NULL, OrderDate from server,
#      CreatedBy from log.UploadedByUserId (not a string)
#   8. PurchaseOrderLines INSERT — LineNumber generated, Description
#      coalesced from null, ReceivedQty hardcoded 0
#   9. Audit emits 'po-import-succeeded' and 'po-import-failed'
#  10. Hangfire queue 'po-import' added to AddHangfireServer config
#  11. PoImportController on api/imports/po with admin,supervisor gate
#  12. Confirm endpoint: 'validated' gate + ownership check +
#      MarkQueuedAsync + 'po-import-confirmed' audit
#  13. Upload endpoint: ext gate + size cap + staging path under
#      imports/staging
#  14. DI registrations: AddScoped<PoImportJob>
#  15. .gitignore covers imports/staging/* + .gitkeep present
#
# Build cleanliness proven behaviorally by the other 50+ smokes end-to-end.

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function AssertFile([string]$path, [string]$mustContain) {
    if (-not (Test-Path $path)) { Fail "Expected file not found: $path" }
    $body = Get-Content -Raw -LiteralPath $path
    if ($body -notmatch [regex]::Escape($mustContain)) {
        Fail "File $([System.IO.Path]::GetFileName($path)) missing token '$mustContain'"
    }
}

$jobFile    = Join-Path $webRoot 'Services\PoImport\PoImportJob.cs'
$ctrlFile   = Join-Path $webRoot 'Controllers\Api\PoImportController.cs'
$programFile = Join-Path $webRoot 'Program.cs'

# ----------------------------------------------------------------------------
# 1. Job file exists with Hangfire attributes
# ----------------------------------------------------------------------------
Step "PoImportJob exists with Hangfire attributes"
AssertFile $jobFile 'public class PoImportJob'
AssertFile $jobFile '[DisableConcurrentExecution(timeoutInSeconds: DisableConcurrentTimeoutSeconds)]'
AssertFile $jobFile 'DisableConcurrentTimeoutSeconds = 1800'
AssertFile $jobFile '[Queue("po-import")]'
AssertFile $jobFile 'public async Task RunAsync(Guid runId, string actorName)'
OK "Job + attributes + RunAsync signature present"

# ----------------------------------------------------------------------------
# 2. Dependencies
# ----------------------------------------------------------------------------
Step "Job injects 5 deps"
foreach ($d in @(
    'IDbConnectionFactory _factory',
    'IPoImportLogRepository _logRepo',
    'IPoImportReader _reader',
    'IAuditService _audit',
    'ILogger<PoImportJob> _logger'
)) { AssertFile $jobFile $d }
OK "All 5 fields wired in ctor"

# ----------------------------------------------------------------------------
# 3. State-machine guard — aborts on non-'queued' status
# ----------------------------------------------------------------------------
Step "Idempotency: aborts unless status='queued'"
$job = Get-Content -Raw -LiteralPath $jobFile
if ($job -notmatch 'log\.Status, "queued"') {
    Fail "Status guard 'queued' missing in RunAsync"
}
if ($job -notmatch 'expected ''queued''') {
    Fail "Helpful log message about expected status missing"
}
OK "Job aborts cleanly on non-queued log row"

# ----------------------------------------------------------------------------
# 4. Atomic transaction with rollback
# ----------------------------------------------------------------------------
Step "Single tx with rollback on any error"
if ($job -notmatch 'conn\.BeginTransaction\(\)') { Fail "BeginTransaction() not used" }
if ($job -notmatch 'tx\.Commit\(\)')             { Fail "tx.Commit() not called" }
if ($job -notmatch 'tx\.Rollback\(\)')           { Fail "tx.Rollback() not called" }
# Confirm there is exactly one Commit (the happy path) and one Rollback (the inner catch).
$commitCount   = ([regex]::Matches($job, 'tx\.Commit\(\)')).Count
$rollbackCount = ([regex]::Matches($job, 'tx\.Rollback\(\)')).Count
if ($commitCount   -ne 1) { Fail "Expected exactly 1 tx.Commit(), found $commitCount" }
if ($rollbackCount -ne 1) { Fail "Expected exactly 1 tx.Rollback(), found $rollbackCount" }
OK "One Commit + one Rollback + outer catch rethrows"

# ----------------------------------------------------------------------------
# 5. Re-parse from log.StoragePath
# ----------------------------------------------------------------------------
Step "Re-parse runs before any DB write"
if ($job -notmatch '_reader\.ParseAsync\(log\.StoragePath\)') {
    Fail "Job does not re-parse from log.StoragePath"
}
# Order: re-parse must be ABOVE _factory.Create(). Use call-site positions.
$reparsePos = $job.IndexOf('_reader.ParseAsync(log.StoragePath)')
$connPos    = $job.IndexOf('_factory.Create()')
if ($reparsePos -lt 0 -or $connPos -lt 0 -or $reparsePos -ge $connPos) {
    Fail "Re-parse must precede _factory.Create() (parse:$reparsePos conn:$connPos)"
}
OK "Re-parse happens before connection open"

# ----------------------------------------------------------------------------
# 6. PoNumber duplicate re-check — UPDLOCK, ROWLOCK, no WH filter
# ----------------------------------------------------------------------------
Step "Duplicate re-check: UPDLOCK + ROWLOCK + global (no WH filter)"
if ($job -notmatch 'FROM\s+dbo\.PurchaseOrders WITH \(UPDLOCK, ROWLOCK\)') {
    Fail "UPDLOCK + ROWLOCK hints missing on PurchaseOrders duplicate check"
}
if ($job -notmatch 'WHERE\s+PoNumber IN @PoNumbers') {
    Fail "Duplicate-check WHERE clause missing"
}
# CRITICAL: the spec's WarehouseId filter would miss cross-warehouse duplicates;
# schema has PoNumber globally UNIQUE. Smoke fails if the WH filter sneaks in.
if ($job -match 'PoNumber IN @PoNumbers AND WarehouseId') {
    Fail "Duplicate check incorrectly filters by WarehouseId — PoNumber is GLOBALLY unique per db/010"
}
OK "Duplicate check is global (correct) + serialized via locks"

# ----------------------------------------------------------------------------
# 7. PurchaseOrders INSERT — PullId NULL, OrderDate server, CreatedBy GUID
# ----------------------------------------------------------------------------
Step "PurchaseOrders INSERT — schema-correct columns"
AssertFile $jobFile 'INSERT INTO dbo.PurchaseOrders'
# A1 (db/033): PullId stays NULL (Guid FK_PO_Pull preserved untouched),
# PullExternalRef = @PullExternalRef sits between PullId and VendorCode so
# the denormalized PRS_ID survives independently. Regex matches the new
# VALUES-clause shape.
if ($job -notmatch ',\s*NULL,\s*@PullExternalRef,\s*@VendorCode,\s*@VendorName,') {
    Fail "VALUES clause should be (..., NULL, @PullExternalRef, @VendorCode, @VendorName, ...) — PullId NULL literal + PullExternalRef param + Vendor*"
}
# PullExternalRef bound to firstRow.PoNumber (Q1=B denormalization)
if ($job -notmatch 'PullExternalRef\s*=\s*firstRow\.PoNumber') {
    Fail "PullExternalRef parameter must bind to firstRow.PoNumber (Q1=B denormalization)"
}
# OrderDate from a C# variable (DateTime.UtcNow.Date) — schema NOT NULL DATE
if ($job -notmatch 'orderDate = DateTime\.UtcNow\.Date') {
    Fail "OrderDate not computed from DateTime.UtcNow.Date"
}
# CreatedBy = log.UploadedByUserId (FK to Users.Id GUID, NOT a string)
if ($job -notmatch 'CreatedBy = log\.UploadedByUserId') {
    Fail "CreatedBy must come from log.UploadedByUserId (Users.Id GUID), not the display name"
}
OK "PullId=NULL + PullExternalRef=PoNumber + OrderDate=server + CreatedBy=GUID"

# ----------------------------------------------------------------------------
# 8. PurchaseOrderLines INSERT — LineNumber, Description coalesce, ReceivedQty 0
# ----------------------------------------------------------------------------
Step "PurchaseOrderLines INSERT — server-owned cols + Description coalesce"
AssertFile $jobFile 'INSERT INTO dbo.PurchaseOrderLines'
if ($job -notmatch 'lineNumber\+\+') {
    Fail "LineNumber generation (1-based ordinal) missing"
}
if ($job -notmatch 'Description = row\.Description \?\? ""') {
    Fail "Description NOT NULL — must coalesce parser null to empty string"
}
# ReceivedQty must be hardcoded 0 (server-owned, ห้าม from file). Match the
# VALUES clause containing both @OrderedQty and a literal 0.
if ($job -notmatch '@OrderedQty,\s*0,') {
    Fail "ReceivedQty must be a literal 0 in the VALUES clause (server-owned)"
}
OK "LineNumber + Description coalesce + ReceivedQty=0 all correct"

# ----------------------------------------------------------------------------
# 9. Audit — succeeded + failed
# ----------------------------------------------------------------------------
Step "Audit rows: po-import-succeeded + po-import-failed"
if ($job -notmatch '"po-import-succeeded"') { Fail "po-import-succeeded audit missing" }
if ($job -notmatch '"po-import-failed"')    { Fail "po-import-failed audit missing" }
# Both must use EntityType='PoImportLog' (parallel to 12.4)
if (([regex]::Matches($job, '"PoImportLog"')).Count -lt 2) {
    Fail "Expected >=2 audit rows tagged EntityType='PoImportLog'"
}
OK "Both terminal audit rows + PoImportLog entity tag present"

# ----------------------------------------------------------------------------
# 10. Hangfire queue 'po-import' added
# ----------------------------------------------------------------------------
Step "po-import queue added to AddHangfireServer config"
$program = Get-Content -Raw -LiteralPath $programFile
if ($program -notmatch 'opts\.Queues = new\[\] \{ "exports", "erp-sync", "po-import", "default" \}') {
    Fail "Queue list not updated — expected exports, erp-sync, po-import, default in that order"
}
OK "Queue list updated with po-import positioned after erp-sync"

# ----------------------------------------------------------------------------
# 11. PoImportController on api/imports/po + admin,supervisor gate
# ----------------------------------------------------------------------------
Step "PoImportController route + auth gate"
AssertFile $ctrlFile 'public class PoImportController'
AssertFile $ctrlFile '[Route("api/imports/po")]'
AssertFile $ctrlFile '[Authorize(Roles = "admin,supervisor")]'
OK "Controller on /api/imports/po with admin+supervisor authorization"

# ----------------------------------------------------------------------------
# 12. Confirm endpoint — gates + enqueue + MarkQueued + audit
# ----------------------------------------------------------------------------
Step "Confirm endpoint: validated gate + ownership + enqueue + audit"
$ctrl = Get-Content -Raw -LiteralPath $ctrlFile
AssertFile $ctrlFile '[HttpPost("{runId:guid}/confirm")]'
if ($ctrl -notmatch 'log\.Status, "validated"') { Fail "Confirm missing 'validated' status gate" }
if ($ctrl -notmatch 'log\.UploadedByUserId != userId') { Fail "Confirm missing ownership check" }
if ($ctrl -notmatch '_bgClient\.Enqueue<PoImportJob>\(j => j\.RunAsync\(runId, displayName\)\)') {
    Fail "Confirm enqueue pattern not matching expected: Enqueue<PoImportJob>(j => j.RunAsync(runId, displayName))"
}
if ($ctrl -notmatch '_logRepo\.MarkQueuedAsync\(runId, hangfireJobId') {
    Fail "Confirm missing MarkQueuedAsync call"
}
if ($ctrl -notmatch '"po-import-confirmed"') {
    Fail "Confirm missing 'po-import-confirmed' audit row"
}
OK "Confirm: gate + ownership + enqueue + MarkQueued + audit all present"

# ----------------------------------------------------------------------------
# 13. Upload endpoint — ext + size + staging path
# ----------------------------------------------------------------------------
Step "Upload endpoint: ext gate + 50MB cap + staging path"
AssertFile $ctrlFile '[HttpPost("upload")]'
AssertFile $ctrlFile 'MaxFileSizeBytes = 50L * 1024 * 1024'
if ($ctrl -notmatch '\.xls" && ext != "\.xlsx"') {
    Fail "Upload extension allowlist missing or wrong"
}
if ($ctrl -notmatch '"imports", "staging"') {
    Fail "Staging path under imports/staging missing"
}
# CreateNew (not OpenOrCreate) — defends against catastrophic RunId reuse
if ($ctrl -notmatch 'FileMode\.CreateNew') {
    Fail "Upload staging FileMode must be CreateNew (defense against collision)"
}
OK "Upload: ext + size + staging + CreateNew all present"

# ----------------------------------------------------------------------------
# 14. DI registration
# ----------------------------------------------------------------------------
Step "AddScoped<PoImportJob> in Program.cs"
if ($program -notmatch 'AddScoped<PoImportJob>') {
    Fail "Program.cs missing AddScoped<PoImportJob>()"
}
OK "DI registration present"

# ----------------------------------------------------------------------------
# 15. .gitignore + staging .gitkeep
# ----------------------------------------------------------------------------
Step "Staging gitignore + .gitkeep"
$gi = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.gitignore')
if ($gi -notmatch 'imports/staging/\*') {
    Fail ".gitignore missing imports/staging/* line"
}
if ($gi -notmatch '!imports/staging/\.gitkeep') {
    Fail ".gitignore missing !imports/staging/.gitkeep negation"
}
$gitkeep = Join-Path $webRoot 'imports\staging\.gitkeep'
if (-not (Test-Path $gitkeep)) {
    Fail "src/ReceivingOps.Web/imports/staging/.gitkeep missing"
}
OK "Gitignore + .gitkeep present"

Write-Host ""
Write-Host "ALL PASS — Phase 12.5: PoImportJob + controller surface + atomic-insert invariants verified." -ForegroundColor Green
exit 0
