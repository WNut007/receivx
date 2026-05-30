# Smoke: Phase 14 — vendor lives on PurchaseOrderLines, every line keeps its
# own vendor through the importer pipeline.
#
# The v3.2 PoImportJob took firstRow.VendorCode and stamped the whole PO
# (silent data loss on mixed-vendor imports). Phase 14 (db/036) moved
# vendor to POL and rewrote the job to write each line's STORER value
# verbatim. This smoke proves the fix with a deliberately mixed-vendor
# workbook — same PoNumber, two different STORER values across the rows.
#
# Fixture is built one-shot via NPOI (same toolchain as the Phase 12.7
# fixture) and lives at tools/fixtures/po-import-mixed-vendor.xlsx.
# Cleanup prefix: P14MIX- (collision-free against P127TEST-).
#
# Assertions:
#   1. Fixture present (build via tools/build-po-import-mixed-vendor-fixture.ps1
#      if missing — separate one-shot script, NOT in battery).
#   2. Pre-cleanup leaves zero P14MIX-* rows.
#   3. Login as admin (sadmin @ WH-01), upload, confirm, poll to terminal.
#   4. Final log: PosInserted=1, LinesInserted=3 (one PO, three lines with
#      three distinct vendors).
#   5. POL rows: each of the 3 lines has its OWN VendorCode + VendorName
#      matching the row's STORER columns — proves no firstRow.* override.
#   6. /api/pos/{id} response: collapsed header vendorCode = null (mixed),
#      lines[].vendorCode each has its own value.
#   7. Cleanup leaves zero residual P14MIX-* data.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$fixturePath = Join-Path $repoRoot 'tools\fixtures\po-import-mixed-vendor.xlsx'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Sql($q)    { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }
function SqlRow($q) { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -s "|" -Q $q }

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

function Cleanup-Mixed {
    $stagedPaths = (Sql @"
SET NOCOUNT ON;
SELECT StoragePath
FROM   dbo.PoImportLog
WHERE  FileName LIKE 'po-import-mixed-vendor%';
"@) | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }

    Sql @"
SET NOCOUNT ON;
DELETE FROM dbo.PurchaseOrderLines
 WHERE PurchaseOrderId IN (
     SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P14MIX-%'
 );
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P14MIX-%';
DELETE FROM dbo.AuditLog
 WHERE EntityType = 'PoImportLog'
   AND EntityId IN (
       SELECT CAST(RunId AS NVARCHAR(64))
       FROM   dbo.PoImportLog
       WHERE  FileName LIKE 'po-import-mixed-vendor%'
   );
DELETE FROM dbo.PoImportLog WHERE FileName LIKE 'po-import-mixed-vendor%';
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
    Fail "Mixed-vendor fixture missing — generate via 'pwsh tools/build-po-import-mixed-vendor-fixture.ps1'"
}
OK "Fixture file present"

# ----------------------------------------------------------------------------
# 2. Pre-cleanup
# ----------------------------------------------------------------------------
Step "Pre-cleanup — no residual P14MIX-% data"
Cleanup-Mixed
$resid = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P14MIX-%';") -join '' -replace '\s',''
if ($resid -ne '0') { Fail "Pre-cleanup left $resid PurchaseOrders behind" }
OK "Pre-cleanup clean"

# ----------------------------------------------------------------------------
# 3. Login as admin (admin uploads import; admin role suffices)
# ----------------------------------------------------------------------------
Step "Login as admin (sadmin @ WH-01)"
$admin = Login 'sadmin' 'admin' $WH_01
$me = Invoke-RestMethod -Uri "$base/api/auth/me" -WebSession $admin
if ($me.roleKey -ne 'admin') { Fail "Session role='$($me.roleKey)' at WH-01, expected 'admin'" }
OK "Logged in as $($me.name) (admin)"

# ----------------------------------------------------------------------------
# 4. Upload + confirm + poll
# ----------------------------------------------------------------------------
Step "Upload mixed-vendor workbook"
$uploadResp = Invoke-RestMethod -Uri "$base/api/imports/po/upload" `
    -Method POST -WebSession $admin `
    -Form @{ file = Get-Item -LiteralPath $fixturePath }

if (-not $uploadResp.runId)               { Fail "Upload response missing runId" }
if ($uploadResp.status -ne 'validated')   { Fail "Upload status='$($uploadResp.status)', expected 'validated'" }
if ($uploadResp.totalRowsRead -ne 3)      { Fail "totalRowsRead=$($uploadResp.totalRowsRead), expected 3 (mixed-vendor fixture)" }
if ($uploadResp.distinctPoCount -ne 1)    { Fail "distinctPoCount=$($uploadResp.distinctPoCount), expected 1 (single PoNumber, mixed vendors)" }
$runId = [Guid]::Parse($uploadResp.runId)
OK "Upload validated (3 rows / 1 distinct PoNumber / mixed-vendor stress test)"

Step "Confirm + poll to terminal"
$confirmResp = Invoke-RestMethod -Uri "$base/api/imports/po/$runId/confirm" -Method POST -WebSession $admin
if (-not $confirmResp.hangfireJobId) { Fail "Confirm response missing hangfireJobId" }

$final = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $cur = Invoke-RestMethod -Uri "$base/api/imports/po/$runId" -WebSession $admin
    if ($cur.status -in @('succeeded', 'failed')) { $final = $cur; break }
}
if (-not $final)                       { Fail "Run did not reach terminal state within 60s" }
if ($final.status -ne 'succeeded')     { Fail "Run terminated with '$($final.status)' — $($final.errorMessage)" }
if ($final.posInserted -ne 1)          { Fail "PosInserted=$($final.posInserted), expected 1" }
if ($final.linesInserted -ne 3)        { Fail "LinesInserted=$($final.linesInserted), expected 3" }
OK "Run succeeded: 1 PO, 3 lines"

# ----------------------------------------------------------------------------
# 5. Per-line vendor — each line has its OWN vendor (no firstRow override)
# ----------------------------------------------------------------------------
Step "Each line carries its own VendorCode/Name from the workbook STORER columns"
$vendorCheck = (SqlRow @"
SET NOCOUNT ON;
SELECT
    pol.LineNumber, ISNULL(pol.VendorCode, '<null>'), ISNULL(pol.VendorName, '<null>')
FROM   dbo.PurchaseOrderLines pol
JOIN   dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE  po.PoNumber LIKE 'P14MIX-%'
ORDER BY pol.LineNumber;
"@) | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }

if ($vendorCheck.Count -ne 3) { Fail "Expected 3 line vendor rows, got $($vendorCheck.Count)" }

# Fixture vendors (deterministic, set in build-po-import-mixed-vendor-fixture.ps1):
#   Line 1: V14-ALPHA   / Vendor Alpha Mix
#   Line 2: V14-BETA    / Vendor Beta Mix
#   Line 3: V14-GAMMA   / Vendor Gamma Mix
$expected = @(
    @{ Line=1; Code='V14-ALPHA'; Name='Vendor Alpha Mix' },
    @{ Line=2; Code='V14-BETA';  Name='Vendor Beta Mix'  },
    @{ Line=3; Code='V14-GAMMA'; Name='Vendor Gamma Mix' }
)
for ($i = 0; $i -lt 3; $i++) {
    $parts = $vendorCheck[$i] -split '\|'
    if ($parts.Count -lt 3) { Fail "Unexpected vendor row shape at index $i : '$($vendorCheck[$i])'" }
    $lineNum = [int]$parts[0]
    $code    = $parts[1]
    $name    = $parts[2]
    $exp     = $expected[$i]
    if ($lineNum -ne $exp.Line) { Fail "Line $($i + 1) — LineNumber=$lineNum, expected $($exp.Line)" }
    if ($code    -ne $exp.Code) { Fail "Line $lineNum — VendorCode='$code', expected '$($exp.Code)' (firstRow override regression?)" }
    if ($name    -ne $exp.Name) { Fail "Line $lineNum — VendorName='$name', expected '$($exp.Name)'" }
}
OK "All 3 lines carry distinct vendors (V14-ALPHA / V14-BETA / V14-GAMMA) — firstRow.* override defect closed"

# ----------------------------------------------------------------------------
# 6. /api/pos/{id} surface — collapsed header vendor must be null (mixed),
#    line entries must each carry their own vendor
# ----------------------------------------------------------------------------
Step "/api/pos/{id} — header vendor collapses to null on mixed lines"
$poId = (SqlRow @"
SET NOCOUNT ON;
SELECT TOP 1 Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P14MIX-%';
"@) -join '' -replace '\s',''
if (-not $poId) { Fail "Could not locate the imported P14MIX PO" }

$detail = Invoke-RestMethod -Uri "$base/api/pos/$poId" -WebSession $admin
if ($detail.vendorCode -ne $null) {
    Fail "PoDetail.vendorCode='$($detail.vendorCode)' on mixed-vendor PO — MIN=MAX collapse expected null"
}
if ($detail.vendorName -ne $null) {
    Fail "PoDetail.vendorName='$($detail.vendorName)' on mixed-vendor PO — MIN=MAX collapse expected null"
}
if ($detail.lines.Count -ne 3) {
    Fail "PoDetail.lines count=$($detail.lines.Count), expected 3"
}
foreach ($lineDto in $detail.lines) {
    if ([string]::IsNullOrEmpty($lineDto.vendorCode)) {
        Fail "Line $($lineDto.lineNumber) vendorCode is empty in API response — DTO not surfacing POL.VendorCode"
    }
}
$apiVendors = @($detail.lines | Sort-Object lineNumber | ForEach-Object { $_.vendorCode })
if (($apiVendors -join ',') -ne 'V14-ALPHA,V14-BETA,V14-GAMMA') {
    Fail "API line vendors='$($apiVendors -join ',')', expected 'V14-ALPHA,V14-BETA,V14-GAMMA'"
}
OK "Header vendor=null (mixed) + 3 lines surface their distinct vendor codes via API"

# ----------------------------------------------------------------------------
# 7. Cleanup
# ----------------------------------------------------------------------------
Step "Cleanup — remove P14MIX-% rows + log + staged file"
Cleanup-Mixed
$residPost = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'P14MIX-%';") -join '' -replace '\s',''
if ($residPost -ne '0') { Fail "Cleanup left $residPost PurchaseOrders behind" }
OK "All P14MIX-% rows removed"

Write-Host ""
Write-Host "ALL PASS — Phase 14 vendor-at-line: per-line vendors round-trip cleanly (no firstRow override)." -ForegroundColor Green
exit 0
