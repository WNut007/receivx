# Smoke test: Reports → Pull Sheets — Summary aggregates WITHIN the period only.
#
# This is the way this report goes silently wrong. Summary is one row per
# (pull, item), and the tempting implementation sums the item's whole pull.
# It must sum only the windows inside the selected period: an item with
# windows at 09:00 and 15:00 belongs to Morning with its 09:00 quantity and to
# Afternoon with its 15:00 quantity — never to either with the total.
#
# A wrong implementation still produces a plausible-looking file. Nothing about
# it looks broken; the numbers are just the wrong numbers. Hence a dedicated
# smoke.
#
# Exercises:
#   1. Fixture: ONE item with windows at 09:00 (900) and 15:00 (1500).
#   2. Morning Summary shows 900 — not 2400.
#   3. Afternoon Summary shows 1500 — not 2400.
#   4. Detail stays window-grained: one row per window, not one per item.
#   5. Grand Total is period-scoped too (cross-pull, still not cross-period).
#   6. The per-pull export DOES span the whole day (3400) — the same generator
#      with different criteria, so this proves the scoping comes from the
#      criteria and not from a hardcoded filter.
#   7. A closed-short window reports 0 outstanding, not its written-off
#      shortfall, on all three of Detail / Summary / Grand Total.
#
# Fixture namespace PSSCOPE-* — purged on entry, exit, and the failure path.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$D     = '2031-04-20'

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
WHERE p.PullNumber LIKE 'PSSCOPE-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PSSCOPE-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PSSCOPE-%';
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
Step '1. Seed one item with windows at 09:00 and 15:00'
# ----------------------------------------------------------------------------
# Distinct quantities so a cross-period sum (2400) is unmistakable against
# either single-period figure (900 / 1500).
RunSql @"
SET NOCOUNT ON;
DECLARE @wh UNIQUEIDENTIFIER = '$WH_01';
DECLARE @p UNIQUEIDENTIFIER = NEWID(), @i UNIQUEIDENTIFIER = NEWID();
INSERT dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status)
VALUES (@p, 'PSSCOPE-1', @wh, '$D', 'in_progress');
INSERT dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, SortOrder)
VALUES (@i, @p, 'PSSCOPE-ITEM', N'scoping fixture item', 'V-SC', N'Scope Vendor', 1);
INSERT dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty, IsClosed, ClosedAt, ClosedReason)
VALUES (NEWID(), @i,  9,  900, 100, 0, NULL, NULL),   -- Morning
       (NEWID(), @i, 15, 1500, 200, 0, NULL, NULL),   -- Afternoon
       -- Evening: closed SHORT. 700 of 1000 arrived and the remaining 300 were
       -- written off, so the sheet must report 0 outstanding on it, not 300.
       (NEWID(), @i, 20, 1000, 700, 1, SYSUTCDATETIME(), 'smoke: closed short');
"@ | Out-Null
OK 'Seeded PSSCOPE-1 / PSSCOPE-ITEM with 09:00=900, 15:00=1500 and a closed-short 20:00=1000/700'

$sv = Login 'sadmin' 'admin' $WH_01

function PreviewRow($period) {
    $r = Invoke-RestMethod -Uri "$base/api/reports/pull-sheets/preview?warehouseId=$WH_01&date=$D&period=$period" -WebSession $sv
    $rows = @($r.summaryPreview | Where-Object { $_.itemCode -eq 'PSSCOPE-ITEM' })
    if ($rows.Count -ne 1) { Fail "$period Summary has $($rows.Count) rows for PSSCOPE-ITEM, expected exactly 1" }
    return $rows[0]
}

# ----------------------------------------------------------------------------
Step '2. Morning Summary carries the 09:00 quantity only'
# ----------------------------------------------------------------------------
$m = PreviewRow 'morning'
if ($m.expectedQty -eq 2400) { Fail 'Morning Summary shows 2400 — it summed the whole pull instead of the period' }
if ($m.expectedQty -ne 900)  { Fail "Morning Summary expected qty is $($m.expectedQty), expected 900" }
if ($m.receivedQty -ne 100)  { Fail "Morning Summary received qty is $($m.receivedQty), expected 100" }
OK 'Morning = 900 expected / 100 received (the 09:00 window alone)'

# ----------------------------------------------------------------------------
Step '3. Afternoon Summary carries the 15:00 quantity only'
# ----------------------------------------------------------------------------
$a = PreviewRow 'afternoon'
if ($a.expectedQty -eq 2400) { Fail 'Afternoon Summary shows 2400 — it summed the whole pull instead of the period' }
if ($a.expectedQty -ne 1500) { Fail "Afternoon Summary expected qty is $($a.expectedQty), expected 1500" }
if ($a.receivedQty -ne 200)  { Fail "Afternoon Summary received qty is $($a.receivedQty), expected 200" }
OK 'Afternoon = 1500 expected / 200 received (the 15:00 window alone)'

# ----------------------------------------------------------------------------
Step '4. Detail stays window-grained inside the period'
# ----------------------------------------------------------------------------
$dll = Get-ChildItem "$PSScriptRoot\..\src\ReceivingOps.Web\bin\Debug\net8.0" -Filter 'ClosedXML.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dll) { Fail 'ClosedXML.dll not found — build the project first' }
Add-Type -Path $dll.FullName

function GetWorkbook($url, $tag) {
    $tmp = Join-Path $env:TEMP "psscope-$tag-$([guid]::NewGuid().ToString('N')).xlsx"
    try { $resp = Invoke-WebRequest -Uri $url -WebSession $sv -UseBasicParsing }
    catch { Fail "Export request failed ($tag): $($_.Exception.Message)" }
    [IO.File]::WriteAllBytes($tmp, $resp.Content)
    return @{ Path = $tmp; Book = (New-Object ClosedXML.Excel.XLWorkbook($tmp)) }
}

# Column lookup by header name — a column insertion must not shift assertions.
function HeaderMap($ws) {
    $h = @{}
    foreach ($c in 1..($ws.LastColumnUsed().ColumnNumber())) { $h[$ws.Cell(1,$c).GetString()] = $c }
    return $h
}

$mw = GetWorkbook "$base/api/reports/pull-sheets/export.xlsx?warehouseId=$WH_01&date=$D&period=morning" 'morning'
$det = $mw.Book.Worksheet('Detail')
$dh  = HeaderMap $det
$detRows = @()
foreach ($r in 2..($det.LastRowUsed().RowNumber())) {
    if ($det.Cell($r, $dh['Item Code']).GetString() -eq 'PSSCOPE-ITEM') {
        $detRows += $det.Cell($r, $dh['Hour']).GetString()
    }
}
if ($detRows.Count -ne 1)     { $mw.Book.Dispose(); Fail "Morning Detail has $($detRows.Count) rows for the fixture item, expected 1" }
if ($detRows[0] -ne '09:00')  { $mw.Book.Dispose(); Fail "Morning Detail hour is $($detRows[0]), expected 09:00" }
OK 'Morning Detail = exactly one row, at 09:00'

# ----------------------------------------------------------------------------
Step '5. Grand Total is period-scoped as well'
# ----------------------------------------------------------------------------
$gt = $mw.Book.Worksheet('Grand Total')
$gh = HeaderMap $gt
$gtExpected = $null
foreach ($r in 2..($gt.LastRowUsed().RowNumber())) {
    if ($gt.Cell($r, $gh['Item Code']).GetString() -eq 'PSSCOPE-ITEM') {
        $gtExpected = [int]$gt.Cell($r, $gh['Expected']).GetDouble()
    }
}
if ($null -eq $gtExpected) { $mw.Book.Dispose(); Fail 'Grand Total has no row for PSSCOPE-ITEM' }
if ($gtExpected -eq 2400)  { $mw.Book.Dispose(); Fail 'Grand Total shows 2400 — it crossed the period boundary' }
if ($gtExpected -ne 900)   { $mw.Book.Dispose(); Fail "Grand Total expected is $gtExpected, expected 900" }
OK 'Grand Total = 900 — aggregates across pulls, not across periods'
$mw.Book.Dispose()
Remove-Item $mw.Path -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
Step '6. The per-pull export spans the whole day (same generator, other criteria)'
# ----------------------------------------------------------------------------
# If period scoping were baked into the generator rather than carried by the
# criteria, this would come back 900 too. It must be the whole day:
# 900 (09:00) + 1500 (15:00) + 1000 (20:00, closed short) = 3400.
$pullId = (RunSql "SET NOCOUNT ON; SELECT CONVERT(varchar(36), Id) FROM dbo.Pulls WHERE PullNumber = 'PSSCOPE-1';" |
           Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' } | Select-Object -First 1).Trim()
if (-not $pullId) { Fail 'Could not resolve PSSCOPE-1 pull id' }

$pw = GetWorkbook "$base/api/reports/pull-sheets/pull/$pullId/export.xlsx" 'perpull'
$psum = $pw.Book.Worksheet('Summary')
$sh   = HeaderMap $psum
$pullTotal = $null
foreach ($r in 2..($psum.LastRowUsed().RowNumber())) {
    if ($psum.Cell($r, $sh['Item Code']).GetString() -eq 'PSSCOPE-ITEM') {
        $pullTotal = [int]$psum.Cell($r, $sh['Total Expected']).GetDouble()
    }
}
if ($null -eq $pullTotal) { $pw.Book.Dispose(); Fail 'Per-pull Summary has no row for PSSCOPE-ITEM' }
if ($pullTotal -ne 3400)  { $pw.Book.Dispose(); Fail "Per-pull Summary total is $pullTotal, expected 3400 (all three windows)" }
OK 'Per-pull export = 3400 — the scoping lives in the criteria, not the generator'
$pw.Book.Dispose()
Remove-Item $pw.Path -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
Step '7. A closed-short window reports ZERO outstanding, not its shortfall'
# ----------------------------------------------------------------------------
# "Units still genuinely expected" — a short close writes the shortfall off, it
# does not leave it owed. receiving.js has said so since db/047 (slotOutstanding
# returns 0 for a settled window); the first server-side version of this export
# did not, and reported the written-off 300 as work still coming on every sheet
# containing such a line.
$ev = GetWorkbook "$base/api/reports/pull-sheets/export.xlsx?warehouseId=$WH_01&date=$D&period=evening" 'evening'
$evDet = $ev.Book.Worksheet('Detail')
$eh = HeaderMap $evDet
$evRow = $null
foreach ($r in 2..($evDet.LastRowUsed().RowNumber())) {
    if ($evDet.Cell($r, $eh['Item Code']).GetString() -eq 'PSSCOPE-ITEM') { $evRow = $r }
}
if (-not $evRow) { $ev.Book.Dispose(); Fail 'Evening Detail has no PSSCOPE-ITEM row' }

$evExp  = [int]$evDet.Cell($evRow, $eh['Expected']).GetDouble()
$evRec  = [int]$evDet.Cell($evRow, $eh['Received']).GetDouble()
$evOut  = [int]$evDet.Cell($evRow, $eh['Outstanding']).GetDouble()
$evStat = $evDet.Cell($evRow, $eh['Cell Status']).GetString()

if ($evExp -ne 1000) { $ev.Book.Dispose(); Fail "Evening Expected is $evExp, expected 1000" }
if ($evRec -ne 700)  { $ev.Book.Dispose(); Fail "Evening Received is $evRec, expected 700" }
if ($evOut -eq 300)  { $ev.Book.Dispose(); Fail 'Evening Outstanding is 300 — the write-off was resurrected as work still owed' }
if ($evOut -ne 0)    { $ev.Book.Dispose(); Fail "Evening Outstanding is $evOut, expected 0 on a closed-short window" }
if ($evStat -ne 'Closed short') { $ev.Book.Dispose(); Fail "Evening Cell Status is '$evStat', expected 'Closed short'" }
OK 'Detail: 1000/700 closed short → Outstanding 0, status Closed short'

# Summary must sum the WINDOWS' outstanding, not re-derive it from the totals —
# re-deriving would bring the 300 straight back.
$evSum = $ev.Book.Worksheet('Summary')
$sh2 = HeaderMap $evSum
$sumOut = $null
foreach ($r in 2..($evSum.LastRowUsed().RowNumber())) {
    if ($evSum.Cell($r, $sh2['Item Code']).GetString() -eq 'PSSCOPE-ITEM') {
        $sumOut = [int]$evSum.Cell($r, $sh2['Total Outstanding']).GetDouble()
    }
}
if ($null -eq $sumOut) { $ev.Book.Dispose(); Fail 'Evening Summary has no PSSCOPE-ITEM row' }
if ($sumOut -ne 0)     { $ev.Book.Dispose(); Fail "Evening Summary Total Outstanding is $sumOut, expected 0" }

$evGt = $ev.Book.Worksheet('Grand Total')
$gh2 = HeaderMap $evGt
$gtOut = $null
foreach ($r in 2..($evGt.LastRowUsed().RowNumber())) {
    if ($evGt.Cell($r, $gh2['Item Code']).GetString() -eq 'PSSCOPE-ITEM') {
        $gtOut = [int]$evGt.Cell($r, $gh2['Outstanding']).GetDouble()
    }
}
if ($null -eq $gtOut) { $ev.Book.Dispose(); Fail 'Evening Grand Total has no PSSCOPE-ITEM row' }
if ($gtOut -ne 0)     { $ev.Book.Dispose(); Fail "Evening Grand Total Outstanding is $gtOut, expected 0" }
OK 'Summary and Grand Total carry 0 too — they sum the windows rather than re-deriving'
$ev.Book.Dispose()
Remove-Item $ev.Path -Force -ErrorAction SilentlyContinue

SqlCleanup
Write-Host "`nALL PASS — period-scoped aggregation, and write-offs stay written off" -ForegroundColor Green
exit 0
