# Smoke test: Reports → Pull Sheets — U+00A0 is scrubbed from written cells.
#
# The ERP feed carries non-breaking spaces inside vendor names ("NHK<NBSP>SPRING")
# and as trailing padding on item descriptions. On screen they are
# indistinguishable from an ordinary space; in a VLOOKUP they never match one,
# so a downstream sheet keyed on these values silently returns #N/A and nobody
# can see why.
#
# Measured on production 2026-08-21: 304 PurchaseOrderLines.VendorName rows and
# 104 PullItems.Description rows carry one.
#
# Trimming is part of the fix, not tidiness — converting the trailing NBSP on
# "ITEM-1<NBSP><NBSP>" to spaces still leaves a value that will not match
# "ITEM-1".
#
# Exercises:
#   1. Fixture: vendor name, description and remark each carrying U+00A0,
#      including trailing padding.
#   2. NO cell anywhere in the workbook contains U+00A0 — all four sheets,
#      every string cell.
#   3. The scrubbed values equal their clean form exactly (VLOOKUP-safe),
#      including no leftover trailing whitespace.
#   4. The interior NBSP became a real space rather than being deleted —
#      "Nichicon Asia" must not collapse to "NichiconAsia".
#
# Fixture namespace PSNBSP-* — purged on entry, exit, and the failure path.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$D     = '2031-05-05'

$NB = [char]0x00A0

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

function RunSql($sql) {
    $out = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -b -Q $sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "SQL FAILED (exit $LASTEXITCODE): $out" -ForegroundColor Red
        exit 2
    }
    return $out
}

function SqlCleanup {
    RunSql @'
SET NOCOUNT ON;
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PSNBSP-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PSNBSP-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PSNBSP-%';
PRINT 'cleanup: pulls removed = ' + CONVERT(varchar, @@ROWCOUNT);
'@ | Where-Object { $_ -match 'cleanup:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

SqlCleanup

# ----------------------------------------------------------------------------
Step '1. Seed rows carrying U+00A0'
# ----------------------------------------------------------------------------
# NCHAR(160) is U+00A0. Three shapes, because they fail differently:
#   VendorName  — interior NBSP  ("NHK<NBSP>SPRING")     → must become a space
#   Description — trailing NBSP  ("PSNBSP-ITEM<NBSP><NBSP>") → must be trimmed away
#   Remark      — both
RunSql @"
SET NOCOUNT ON;
DECLARE @wh UNIQUEIDENTIFIER = '$WH_01';
DECLARE @p UNIQUEIDENTIFIER = NEWID(), @i UNIQUEIDENTIFIER = NEWID();
INSERT dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status)
VALUES (@p, 'PSNBSP-1', @wh, '$D', 'pending');
INSERT dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, Remark, SortOrder)
VALUES (@i, @p, 'PSNBSP-ITEM',
        N'PSNBSP desc' + NCHAR(160) + NCHAR(160),
        'V-NB',
        N'NHK' + NCHAR(160) + N'SPRING',
        N'lot' + NCHAR(160) + N'A9' + NCHAR(160),
        1);
INSERT dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
VALUES (NEWID(), @i, 9, 500, 0);
-- Prove the fixture really landed with NBSP in it; if the INSERT lost them the
-- rest of this smoke would pass while testing nothing.
DECLARE @n INT = (SELECT COUNT(*) FROM dbo.PullItems
                  WHERE ItemCode = 'PSNBSP-ITEM'
                    AND VendorName LIKE N'%' + NCHAR(160) + N'%'
                    AND Description LIKE N'%' + NCHAR(160) + N'%'
                    AND Remark LIKE N'%' + NCHAR(160) + N'%');
IF @n <> 1 RAISERROR('Fixture did not retain U+00A0 - seed is invalid', 16, 1);
PRINT 'seed: nbsp fixture rows = ' + CONVERT(varchar, @n);
"@ | Where-Object { $_ -match 'seed:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
OK 'Seeded PSNBSP-ITEM with U+00A0 in VendorName, Description and Remark'

$sv = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
Step '2. No cell in the workbook contains U+00A0'
# ----------------------------------------------------------------------------
$dll = Get-ChildItem "$PSScriptRoot\..\src\ReceivingOps.Web\bin\Debug\net8.0" -Filter 'ClosedXML.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dll) { Fail 'ClosedXML.dll not found — build the project first' }
Add-Type -Path $dll.FullName

$tmp = Join-Path $env:TEMP "psnbsp-$([guid]::NewGuid().ToString('N')).xlsx"
try {
    $resp = Invoke-WebRequest -Uri "$base/api/reports/pull-sheets/export.xlsx?warehouseId=$WH_01&date=$D&period=morning" `
                              -WebSession $sv -UseBasicParsing
} catch { Fail "Export request failed: $($_.Exception.Message)" }
[IO.File]::WriteAllBytes($tmp, $resp.Content)

$wb = New-Object ClosedXML.Excel.XLWorkbook($tmp)

# Every sheet, every used cell — not just the columns this fixture touches. The
# normaliser is meant to sit on the one path all string cells go through, so
# scanning the whole workbook is what proves that rather than assuming it.
$scanned = 0
$offenders = @()
foreach ($ws in $wb.Worksheets) {
    foreach ($cell in $ws.CellsUsed()) {
        if ($cell.DataType -eq [ClosedXML.Excel.XLDataType]::Text) {
            $scanned++
            $v = $cell.GetString()
            if ($v.Contains($NB)) { $offenders += "$($ws.Name)!$($cell.Address.ToString()) = '$v'" }
        }
    }
}
if ($scanned -lt 10) { $wb.Dispose(); Fail "Only $scanned text cells scanned — the export looks empty, assertions would be vacuous" }
if ($offenders.Count -gt 0) {
    $wb.Dispose()
    Fail "U+00A0 survived into $($offenders.Count) cell(s): $($offenders -join '; ')"
}
OK "$scanned text cells scanned across $($wb.Worksheets.Count) sheets — zero contain U+00A0"

# ----------------------------------------------------------------------------
Step '3. Scrubbed values match their clean form exactly'
# ----------------------------------------------------------------------------
$det = $wb.Worksheet('Detail')
$hdr = @{}
foreach ($c in 1..($det.LastColumnUsed().ColumnNumber())) { $hdr[$det.Cell(1,$c).GetString()] = $c }

$row = $null
foreach ($r in 2..($det.LastRowUsed().RowNumber())) {
    if ($det.Cell($r, $hdr['Item Code']).GetString() -eq 'PSNBSP-ITEM') { $row = $r }
}
if (-not $row) { $wb.Dispose(); Fail 'Detail sheet has no PSNBSP-ITEM row' }

$vendor = $det.Cell($row, $hdr['Vendor Name']).GetString()
$desc   = $det.Cell($row, $hdr['Description']).GetString()
$remark = $det.Cell($row, $hdr['Remark']).GetString()

if ($vendor -cne 'NHK SPRING')  { $wb.Dispose(); Fail "Vendor Name is '$vendor' (len $($vendor.Length)), expected 'NHK SPRING'" }
if ($desc   -cne 'PSNBSP desc') { $wb.Dispose(); Fail "Description is '$desc' (len $($desc.Length)), expected 'PSNBSP desc' with the trailing padding trimmed" }
if ($remark -cne 'lot A9')      { $wb.Dispose(); Fail "Remark is '$remark' (len $($remark.Length)), expected 'lot A9'" }
OK "Values are VLOOKUP-clean: 'NHK SPRING', 'PSNBSP desc', 'lot A9' — no trailing whitespace"

# ----------------------------------------------------------------------------
Step '4. The interior NBSP became a space, it was not deleted'
# ----------------------------------------------------------------------------
# Replacing U+00A0 with "" instead of " " would also pass step 2, and would
# corrupt every multi-word vendor name in the file.
if ($vendor -notmatch '\s') { $wb.Dispose(); Fail "Vendor Name '$vendor' lost its word break — NBSP was deleted rather than replaced" }
if ($vendor.Split(' ').Count -ne 2) { $wb.Dispose(); Fail "Vendor Name '$vendor' did not split into 2 words" }
OK 'NHK SPRING kept its word break — U+00A0 was replaced by a space, not removed'

$wb.Dispose()
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

SqlCleanup
Write-Host "`nALL PASS — U+00A0 never reaches a written cell" -ForegroundColor Green
exit 0
