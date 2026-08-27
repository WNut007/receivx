# Smoke test: Reports → Pull Sheets — Night rollover across midnight.
#
# Pulls.PullDate is DATE and PullItemWindows.HourOfDay is TINYINT 0-23, so
# there is no datetime on a window and "the night of date D" has to be
# constructed:
#
#     hour 23 of pulls where PullDate = D
#   + hours 0,1,2 of pulls where PullDate = D + 1
#
# Every other period reads one PullDate. Only Night spans two. Measured on
# production 2026-08-21, hours 0-2 carry 261 windows all-time (64 in the last
# 30 days), so this is a live path, not a theoretical one.
#
# Exercises:
#   1. Fixture: pull on D with windows at hours 22 and 23; pull on D+1 with
#      windows at hours 0, 1, 2 and 3.
#   2. Night export for D contains exactly the four rollover windows
#      (23 on D; 0,1,2 on D+1).
#   3. It contains NOTHING from hour 22 (Evening) or hour 3 (Pre-dawn) —
#      the boundary hours on either side.
#   4. The Header sheet states both dates it read.
#   5. Evening for D picks up hour 22 and NOT hour 23 — the other side of the
#      same boundary.
#
# Fixture namespace PSNIGHT-* — purged on entry, on exit, and on the failure
# path. No receipts are written, so the pulls delete cleanly.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

# Far-future dates so the fixture cannot collide with real or seeded data.
$D  = '2031-03-10'
$D1 = '2031-03-11'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

function RunSql($sql) {
    # -b so sqlcmd exits non-zero on a SQL error, and output is kept so a
    # refusal is printed rather than discarded (docs/smoke-conventions.md §2).
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
WHERE p.PullNumber LIKE 'PSNIGHT-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PSNIGHT-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PSNIGHT-%';
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
Step '1. Seed the rollover fixture'
# ----------------------------------------------------------------------------
# PSNIGHT-D  on D    : hour 22 (Evening) + hour 23 (Night, day side)
# PSNIGHT-D1 on D+1  : hours 0,1,2 (Night, rollover side) + hour 3 (Pre-dawn)
# The 22 and 3 windows are the boundary guards: if the query widened by one
# hour in either direction they would appear in the Night export.
RunSql @"
SET NOCOUNT ON;
DECLARE @wh UNIQUEIDENTIFIER = '$WH_01';
DECLARE @pD UNIQUEIDENTIFIER = NEWID(), @pD1 UNIQUEIDENTIFIER = NEWID();
DECLARE @iD UNIQUEIDENTIFIER = NEWID(), @iD1 UNIQUEIDENTIFIER = NEWID();

INSERT dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status)
VALUES (@pD,  'PSNIGHT-D',  @wh, '$D',  'pending'),
       (@pD1, 'PSNIGHT-D1', @wh, '$D1', 'pending');

INSERT dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, SortOrder)
VALUES (@iD,  @pD,  'PSNIGHT-ITEM-A', N'night day-side item',  'V-N1', N'Night Vendor One', 1),
       (@iD1, @pD1, 'PSNIGHT-ITEM-B', N'night rollover item',  'V-N2', N'Night Vendor Two', 1);

INSERT dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
VALUES (NEWID(), @iD,  22, 2200, 0),   -- Evening  — must NOT appear in Night
       (NEWID(), @iD,  23, 2300, 0),   -- Night, day side
       (NEWID(), @iD1,  0, 1000, 0),   -- Night, rollover side
       (NEWID(), @iD1,  1, 1100, 0),
       (NEWID(), @iD1,  2, 1200, 0),
       (NEWID(), @iD1,  3, 3300, 0);   -- Pre-dawn — must NOT appear in Night
"@ | Out-Null
OK "Seeded PSNIGHT-D on $D (h22,h23) and PSNIGHT-D1 on $D1 (h0,h1,h2,h3)"

$sv = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
Step '2. Night export for D carries all four rollover windows'
# ----------------------------------------------------------------------------
$dll = Get-ChildItem "$PSScriptRoot\..\src\ReceivingOps.Web\bin\Debug\net8.0" -Filter 'ClosedXML.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dll) { Fail 'ClosedXML.dll not found — build the project first' }
Add-Type -Path $dll.FullName

$tmp = Join-Path $env:TEMP "psnight-$([guid]::NewGuid().ToString('N')).xlsx"
try {
    $resp = Invoke-WebRequest -Uri "$base/api/reports/pull-sheets/export.xlsx?warehouseId=$WH_01&date=$D&period=night" `
                              -WebSession $sv -UseBasicParsing
} catch {
    Fail "Night export request failed: $($_.Exception.Message)"
}
[IO.File]::WriteAllBytes($tmp, $resp.Content)

$disp = ($resp.Headers['Content-Disposition'] | Out-String)
if ($disp -notmatch 'WH-01_2031-03-10_Night\.xlsx') {
    Fail "Filename off-contract — expected WH-01_2031-03-10_Night.xlsx, got: $disp"
}

$wb = New-Object ClosedXML.Excel.XLWorkbook($tmp)
$det = $wb.Worksheet('Detail')

# Column indices by header name so a column insertion cannot silently shift the
# assertions onto the wrong data.
# Real foreach, not ForEach-Object: assigning to a variable inside a
# ForEach-Object block writes to a child scope, so `+=` there silently
# discards every append and the collection comes back empty.
$hdr = @{}
foreach ($c in 1..($det.LastColumnUsed().ColumnNumber())) { $hdr[$det.Cell(1,$c).GetString()] = $c }
foreach ($need in 'Pull #','Pull Date','Hour','Expected') {
    if (-not $hdr.ContainsKey($need)) { $wb.Dispose(); Fail "Detail sheet has no '$need' column" }
}

$rows = @()
foreach ($r in 2..($det.LastRowUsed().RowNumber())) {
    $rows += [pscustomobject]@{
        Pull     = $det.Cell($r, $hdr['Pull #']).GetString()
        Date     = $det.Cell($r, $hdr['Pull Date']).GetFormattedString()
        Hour     = $det.Cell($r, $hdr['Hour']).GetString()
        Expected = [int]$det.Cell($r, $hdr['Expected']).GetDouble()
    }
}
$mine = @($rows | Where-Object { $_.Pull -like 'PSNIGHT-*' })

if ($mine.Count -ne 4) {
    $wb.Dispose()
    Fail "Night export has $($mine.Count) fixture rows, expected 4 — got: $(($mine | ForEach-Object { "$($_.Pull)@$($_.Hour)" }) -join ', ')"
}

$got = ($mine | ForEach-Object { $_.Hour } | Sort-Object) -join ','
if ($got -ne '00:00,01:00,02:00,23:00') { $wb.Dispose(); Fail "Night hours are [$got], expected [00:00,01:00,02:00,23:00]" }

$sum = ($mine | Measure-Object -Property Expected -Sum).Sum
if ($sum -ne 5600) { $wb.Dispose(); Fail "Night expected total is $sum, expected 5600 (2300+1000+1100+1200)" }
OK 'Night for D = hour 23 on D plus hours 0,1,2 on D+1 — 4 windows, 5,600 units'

# ----------------------------------------------------------------------------
Step '3. It excludes the boundary hours on either side'
# ----------------------------------------------------------------------------
$h22 = @($mine | Where-Object { $_.Hour -eq '22:00' })
if ($h22.Count -ne 0) { $wb.Dispose(); Fail 'Hour 22 leaked into the Night export — the window widened backwards' }
$h3 = @($mine | Where-Object { $_.Hour -eq '03:00' })
if ($h3.Count -ne 0) { $wb.Dispose(); Fail 'Hour 3 leaked into the Night export — the window widened forwards' }

# And the rollover half really came off the NEXT date, not off D.
$rollover = @($mine | Where-Object { $_.Hour -ne '23:00' })
foreach ($r in $rollover) {
    if ($r.Date -notlike "*$D1*" -and $r.Date -ne '2031-03-11') {
        $wb.Dispose(); Fail "Rollover row at $($r.Hour) carries Pull Date '$($r.Date)', expected $D1"
    }
}
$dayside = @($mine | Where-Object { $_.Hour -eq '23:00' })
if ($dayside[0].Date -ne '2031-03-10') {
    $wb.Dispose(); Fail "Hour-23 row carries Pull Date '$($dayside[0].Date)', expected $D"
}
OK 'No hour 22 or hour 3; rollover rows carry D+1 and the h23 row carries D'

# ----------------------------------------------------------------------------
Step '4. Header sheet names both dates the period read'
# ----------------------------------------------------------------------------
$head = $wb.Worksheet('Header')
$range = ''
foreach ($r in 1..($head.LastRowUsed().RowNumber())) {
    if ($head.Cell($r,1).GetString() -eq 'Period Date Range') { $range = $head.Cell($r,2).GetString() }
}
if ($range -notmatch [regex]::Escape($D))  { $wb.Dispose(); Fail "Header Period Date Range '$range' does not mention $D" }
if ($range -notmatch [regex]::Escape($D1)) { $wb.Dispose(); Fail "Header Period Date Range '$range' does not mention $D1" }
OK "Header states the rollover: '$range'"
$wb.Dispose()
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
Step '5. Evening for D takes hour 22 and leaves hour 23'
# ----------------------------------------------------------------------------
$ev = Invoke-RestMethod -Uri "$base/api/reports/pull-sheets/preview?warehouseId=$WH_01&date=$D&period=evening" -WebSession $sv
$evMine = @($ev.summaryPreview | Where-Object { $_.pullNumber -like 'PSNIGHT-*' })
if ($evMine.Count -ne 1)        { Fail "Evening preview has $($evMine.Count) fixture rows, expected 1" }
if ($evMine[0].expectedQty -ne 2200) { Fail "Evening expected qty is $($evMine[0].expectedQty), expected 2200 (hour 22 only)" }
OK 'Evening for D = hour 22 only (2,200) — the h23 window stays in Night'

SqlCleanup
Write-Host "`nALL PASS — night rollover reads D h23 + D+1 h0,1,2 and nothing else" -ForegroundColor Green
exit 0
