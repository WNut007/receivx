# Smoke test: Reports -> Pull Sheets carries a BUILDING column.
#
# Building is ERP-sourced (dbo.PurchaseOrderLines.Building, db/021) and sits at
# PO-LINE grain, while this report is at (pull, item, window) grain. Everything
# that can go wrong here goes wrong quietly:
#
#   * The join is across two vendor-code FORMATS. PurchaseOrderLines.VendorCode
#     is prefixed (COI-PSBLDV1); PullItems.VendorCode is bare (PSBLDV1). Written
#     as a plain equality the join matches NOTHING and the column reads as an
#     honest-looking wall of em-dashes -- indistinguishable from "the ERP has no
#     building data". Case 3 is the guard: it seeds the two formats deliberately
#     and asserts a marker string survives the trip.
#
#   * One pull item can reach MANY PO lines (measured on 2026-08-20: one item
#     reaches 181). Joining POL into the detail projection would multiply every
#     window row by its line count and inflate ExpectedQty on all four sheets
#     while still producing a plausible file. Case 4b is the guard: the
#     two-line fixture must stay ONE row at its seeded quantity.
#
#   * Disagreeing lines must collapse to a word, not a comma-joined list -- the
#     column is a VLOOKUP key downstream. Case 4 pins the literal.
#
# Exercises:
#   1. Preview API carries a `building` field; the Reports page header row has
#      BUILDING immediately after VENDOR.
#   2. Building appears in the header row of Summary, Detail and Grand Total,
#      and NOT on Header.
#   3. Value round-trip: a distinctive marker on a prefixed-vendor PO line
#      reaches the Detail sheet body verbatim.
#   4. Two PO lines disagreeing -> the Summary cell reads exactly '*mixed*'
#      (4b: and the row is not duplicated, nor its quantity inflated).
#   5. No matching PO line -> an EMPTY xlsx cell (not 'null', not '*mixed*')
#      and an em-dash in the preview.
#   6. NBSP padding is folded BEFORE the collapse, so a padded duplicate of the
#      same building is not read as a disagreement.
#
# Fixture namespace PSBLD-* -- purged on entry, exit, and the failure path.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$D     = '2031-05-11'          # far future: cannot collide with ERP-fed rows
$HOUR  = 9                     # inside Morning (07-10)

$repoRoot = Split-Path -Parent $PSScriptRoot
$tmpXlsx  = Join-Path ([IO.Path]::GetTempPath()) 'smoke-pull-sheets-building.xlsx'

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

# Order matters: windows -> items -> pulls, and lines -> orders. Never piped to
# Out-Null -- a cleanup that fails silently leaves the next run seeding on top
# of its own residue (docs/smoke-conventions.md).
function SqlCleanup {
    RunSql @'
SET NOCOUNT ON;
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PSBLD-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PSBLD-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PSBLD-%';
DELETE pol FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'PSBLD-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PSBLD-%';
PRINT 'cleanup: purchase orders removed = ' + CONVERT(varchar, @@ROWCOUNT);
'@ | Where-Object { $_ -match 'cleanup:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Reads a worksheet's header row and returns the column names in order.
function HeaderRow($ws) {
    $hdr = @(); $c = 1
    while ($true) {
        $v = $ws.Cell(1, $c).GetString()
        if ([string]::IsNullOrWhiteSpace($v)) { break }
        $hdr += $v; $c++
    }
    return $hdr
}

SqlCleanup

# ----------------------------------------------------------------------------
Step '1. Seed three pull items, each exercising a different Building outcome'
# ----------------------------------------------------------------------------
# A -> ONE PO line, Building 'PSBLD-B7X'. The PO line carries the PREFIXED
#      vendor code, the pull item the BARE one -- the format gap the join has
#      to bridge. Quantity 900 so an inflated total is unmistakable.
# B -> TWO PO lines, Buildings 'PSBLD-BM1' / 'PSBLD-BM2'. Disagreement.
# C -> NO PO line at all. Nothing to say.
RunSql @"
SET NOCOUNT ON;
DECLARE @wh UNIQUEIDENTIFIER = '$WH_01';
DECLARE @p UNIQUEIDENTIFIER = NEWID();
DECLARE @iA UNIQUEIDENTIFIER = NEWID(), @iB UNIQUEIDENTIFIER = NEWID(), @iC UNIQUEIDENTIFIER = NEWID(), @iD UNIQUEIDENTIFIER = NEWID();
DECLARE @po UNIQUEIDENTIFIER = NEWID();

INSERT dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status)
VALUES (@p, 'PSBLD-1', @wh, '$D', 'in_progress');

INSERT dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, SortOrder)
VALUES (@iA, @p, 'PSBLD-ITEM-A', N'building round-trip fixture', 'PSBLDV1', NULL, 1),
       (@iB, @p, 'PSBLD-ITEM-B', N'building mixed-collapse fixture', 'PSBLDV2', NULL, 2),
       (@iC, @p, 'PSBLD-ITEM-C', N'building unmatched fixture', 'PSBLDV3', NULL, 3),
       (@iD, @p, 'PSBLD-ITEM-D', N'building nbsp fixture', 'PSBLDV4', NULL, 4);

INSERT dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty, IsClosed)
VALUES (NEWID(), @iA, $HOUR, 900, 100, 0),
       (NEWID(), @iB, $HOUR, 500, 0,   0),
       (NEWID(), @iC, $HOUR, 300, 0,   0),
       (NEWID(), @iD, $HOUR, 200, 0,   0);

INSERT dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, Status)
VALUES (@po, 'PSBLD-PO-1', @wh, '$D', 'open');

-- VendorCode is written PREFIXED here on purpose. A join that compares it to
-- the pull item's bare 'PSBLDV1' with plain equality matches zero rows.
INSERT dbo.PurchaseOrderLines
      (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName, Building)
VALUES (NEWID(), @po, 1, 'PSBLD-ITEM-A', N'line a',   1000, 0, 'COI-PSBLDV1', N'PSBLD Vendor One', 'PSBLD-B7X'),
       (NEWID(), @po, 2, 'PSBLD-ITEM-B', N'line b1',  1000, 0, 'COI-PSBLDV2', N'PSBLD Vendor Two', 'PSBLD-BM1'),
       (NEWID(), @po, 3, 'PSBLD-ITEM-B', N'line b2',  1000, 0, 'COI-PSBLDV2', N'PSBLD Vendor Two', 'PSBLD-BM2'),
       -- Item D: the SAME building on both lines, but one copy padded with a
       -- non-breaking space. LTRIM/RTRIM in SQL Server does not treat U+00A0 as
       -- whitespace, so without the NBSP fold these two read as a disagreement
       -- and the cell would invent a *mixed*.
       (NEWID(), @po, 4, 'PSBLD-ITEM-D', N'line d1',  1000, 0, 'COI-PSBLDV4', N'PSBLD Vendor Four', 'PSBLD-BN1'),
       (NEWID(), @po, 5, 'PSBLD-ITEM-D', N'line d2',  1000, 0, 'COI-PSBLDV4', N'PSBLD Vendor Four', N'PSBLD-BN1' + NCHAR(160));
PRINT 'seeded';
"@ | Out-Null
OK 'Seeded PSBLD-1: A=one line, B=two disagreeing lines, C=no line, D=two lines differing only by an NBSP'

$sv = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
Step '2. Preview API carries a building field, and the page header shows it after VENDOR'
# ----------------------------------------------------------------------------
$preview = Invoke-RestMethod -WebSession $sv `
    -Uri "$base/api/reports/pull-sheets/preview?warehouseId=$WH_01&date=$D&period=morning"

if ($preview.summaryPreview.Count -lt 3) {
    Fail "preview returned $($preview.summaryPreview.Count) rows, expected the 3 seeded items"
}
$rowA = $preview.summaryPreview | Where-Object { $_.itemCode -eq 'PSBLD-ITEM-A' }
if (-not $rowA) { Fail 'PSBLD-ITEM-A missing from the preview' }
# Asserted on the row that HAS a value, deliberately. The API serializes with
# JsonIgnoreCondition.WhenWritingNull, so a null building is omitted from the
# JSON entirely -- a bare property-exists check would be indistinguishable from
# case 6, where absence is the correct answer, and would report a missing
# implementation as a missing value or vice versa.
if ($rowA.building -ne 'PSBLD-B7X') {
    Fail "preview building for PSBLD-ITEM-A is '$($rowA.building)', expected 'PSBLD-B7X'. Absent means either PullSheetPreviewRow was not extended or the PO line did not resolve -- the PO line holds 'COI-PSBLDV1' against the pull item's bare 'PSBLDV1'."
}
OK "preview response carries building='PSBLD-B7X' for the seeded item"

$page = (Invoke-WebRequest -WebSession $sv -Uri "$base/Reports").Content
$m = [regex]::Match($page, '(?is)<table[^>]*id="ps-table".*?</thead>')
if (-not $m.Success) { Fail 'could not find the #ps-table header on /Reports' }
$headers = [regex]::Matches($m.Value, '(?is)<th[^>]*>(.*?)</th>') | ForEach-Object { $_.Groups[1].Value.Trim() }
$iVendor   = [array]::IndexOf($headers, 'Vendor')
$iBuilding = [array]::IndexOf($headers, 'Building')
if ($iVendor   -lt 0) { Fail "no VENDOR header in [$($headers -join ' | ')]" }
if ($iBuilding -lt 0) { Fail "no BUILDING header in [$($headers -join ' | ')]" }
if ($iBuilding -ne $iVendor + 1) {
    Fail "BUILDING is at position $iBuilding, expected $($iVendor + 1) (immediately after VENDOR) -- [$($headers -join ' | ')]"
}
OK "preview table header reads ... $($headers[$iVendor]) | $($headers[$iBuilding]) ..."

# The empty-state colspan has to track the column count or the placeholder row
# stops spanning the table.
$viewSrc = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\Views\Reports\Index.cshtml')
$jsSrc   = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\wwwroot\js\pull-sheets.js')
if ($viewSrc -match 'colspan="9"[^>]*class="ps-empty"' -or $jsSrc -match 'colspan=\\?"9\\?"[^>]*ps-empty') {
    Fail 'a ps-empty placeholder still spans 9 columns -- the table now has 10'
}
OK 'empty-state colspan tracks the new column count'

# ----------------------------------------------------------------------------
Step '3. Workbook: Building on Summary / Detail / Grand Total, absent from Header'
# ----------------------------------------------------------------------------
if (Test-Path $tmpXlsx) { Remove-Item $tmpXlsx -Force }
Invoke-WebRequest -WebSession $sv -OutFile $tmpXlsx `
    -Uri "$base/api/reports/pull-sheets/export.xlsx?warehouseId=$WH_01&date=$D&period=morning"
if (-not (Test-Path $tmpXlsx)) { Fail 'export.xlsx produced no file' }

$closedXml = Join-Path $repoRoot 'src\ReceivingOps.Web\bin\Debug\net8.0\ClosedXML.dll'
if (-not (Test-Path $closedXml)) { Fail "ClosedXML.dll not found at $closedXml -- build the project first" }
Add-Type -Path $closedXml
$wb = New-Object ClosedXML.Excel.XLWorkbook $tmpXlsx

try {
    foreach ($sheet in @('Summary', 'Detail', 'Grand Total')) {
        $hdr = HeaderRow $wb.Worksheet($sheet)
        $iB = [array]::IndexOf($hdr, 'Building')
        if ($iB -lt 0) { Fail "'$sheet' has no Building column -- [$($hdr -join ' | ')]" }
        # Right of Vendor: 'Vendor Name' on Summary/Detail, 'Vendor' on Grand Total.
        $iV = [array]::IndexOf($hdr, 'Vendor Name')
        if ($iV -lt 0) { $iV = [array]::IndexOf($hdr, 'Vendor') }
        if ($iV -lt 0) { Fail "'$sheet' has no vendor column to anchor Building against" }
        if ($iB -ne $iV + 1) {
            Fail "'$sheet' Building is at col $($iB+1), expected $($iV+2) (right of vendor) -- [$($hdr -join ' | ')]"
        }
        OK "'$sheet' carries Building at column $($iB+1), right of '$($hdr[$iV])'"
    }

    $headerHdr = HeaderRow $wb.Worksheet('Header')
    if ($headerHdr -contains 'Building') { Fail "'Header' sheet gained a Building column -- it is the criteria block and must not change" }
    # The criteria block is a two-column key/value sheet; a Building row would
    # show up in column 1, not the header row.
    $hs = $wb.Worksheet('Header')
    $hlast = $hs.LastRowUsed().RowNumber()
    $keys = 1..$hlast | ForEach-Object { $hs.Cell($_, 1).GetString() }
    if ($keys -contains 'Building') { Fail "'Header' sheet gained a Building criteria row" }
    OK "'Header' sheet is unchanged -- no Building column or row"

    # ------------------------------------------------------------------------
    Step '4. Value round-trip: the marker reaches the Detail body through the prefixed-vendor join'
    # ------------------------------------------------------------------------
    $ws = $wb.Worksheet('Detail')
    $hdr = HeaderRow $ws
    $cItem = [array]::IndexOf($hdr, 'Item Code') + 1
    $cBld  = [array]::IndexOf($hdr, 'Building') + 1
    $cExp  = [array]::IndexOf($hdr, 'Expected') + 1
    $last  = $ws.LastRowUsed().RowNumber()

    $detail = @{}
    2..$last | ForEach-Object {
        $code = $ws.Cell($_, $cItem).GetString()
        if ($code -like 'PSBLD-*') {
            if (-not $detail.ContainsKey($code)) { $detail[$code] = @() }
            $detail[$code] += ,@($ws.Cell($_, $cBld).GetString(), $ws.Cell($_, $cExp).GetDouble())
        }
    }

    if ($detail['PSBLD-ITEM-A'].Count -ne 1) {
        Fail "PSBLD-ITEM-A produced $($detail['PSBLD-ITEM-A'].Count) Detail rows, expected 1"
    }
    if ($detail['PSBLD-ITEM-A'][0][0] -ne 'PSBLD-B7X') {
        Fail "Detail Building for PSBLD-ITEM-A is '$($detail['PSBLD-ITEM-A'][0][0])', expected 'PSBLD-B7X'. The PO line holds 'COI-PSBLDV1' and the pull item 'PSBLDV1' -- an empty value here means the vendor prefix is not being stripped."
    }
    OK "Detail carries 'PSBLD-B7X' for PSBLD-ITEM-A -- the COI- prefix was bridged"

    # ------------------------------------------------------------------------
    Step '5. Two disagreeing PO lines collapse to *mixed* -- and do not fan the row out'
    # ------------------------------------------------------------------------
    $ws = $wb.Worksheet('Summary')
    $hdr = HeaderRow $ws
    $sItem = [array]::IndexOf($hdr, 'Item Code') + 1
    $sBld  = [array]::IndexOf($hdr, 'Building') + 1
    $sExp  = [array]::IndexOf($hdr, 'Total Expected') + 1
    $slast = $ws.LastRowUsed().RowNumber()

    $summary = @{}
    2..$slast | ForEach-Object {
        $code = $ws.Cell($_, $sItem).GetString()
        if ($code -like 'PSBLD-*') {
            if (-not $summary.ContainsKey($code)) { $summary[$code] = @() }
            $summary[$code] += ,@($ws.Cell($_, $sBld).GetString(), $ws.Cell($_, $sExp).GetDouble())
        }
    }

    if ($summary['PSBLD-ITEM-B'][0][0] -ne '*mixed*') {
        Fail "Summary Building for PSBLD-ITEM-B is '$($summary['PSBLD-ITEM-B'][0][0])', expected the literal '*mixed*' (its two PO lines say PSBLD-BM1 and PSBLD-BM2)"
    }
    if ($summary['PSBLD-ITEM-B'][0][0] -match ',') {
        Fail 'disagreeing buildings were comma-joined -- the column is a VLOOKUP key downstream and must collapse to a word'
    }
    OK "Summary reads '*mixed*' for the two-building item"

    # 5b -- the grain guard. PSBLD-ITEM-B reaches TWO PO lines. If Building were
    # joined rather than APPLY'd, this item would appear twice and its 500 would
    # read as 1000, on a file that otherwise looks entirely normal.
    if ($summary['PSBLD-ITEM-B'].Count -ne 1) {
        Fail "PSBLD-ITEM-B produced $($summary['PSBLD-ITEM-B'].Count) Summary rows, expected 1 -- the PO-line join is fanning rows out"
    }
    if ($summary['PSBLD-ITEM-B'][0][1] -ne 500) {
        Fail "PSBLD-ITEM-B Total Expected is $($summary['PSBLD-ITEM-B'][0][1]), expected 500 -- reaching 2 PO lines has inflated the quantity"
    }
    if ($detail['PSBLD-ITEM-B'].Count -ne 1) {
        Fail "PSBLD-ITEM-B produced $($detail['PSBLD-ITEM-B'].Count) Detail rows, expected 1 -- the PO-line join is fanning rows out"
    }
    if ($summary['PSBLD-ITEM-A'][0][1] -ne 900) {
        Fail "PSBLD-ITEM-A Total Expected is $($summary['PSBLD-ITEM-A'][0][1]), expected 900"
    }
    OK 'reaching two PO lines still yields one row at the seeded quantity on both sheets'

    # ------------------------------------------------------------------------
    Step '6. No matching PO line -> an empty cell, not the text null and not *mixed*'
    # ------------------------------------------------------------------------
    $cellC = $summary['PSBLD-ITEM-C'][0][0]
    if ($cellC -ne '') {
        Fail "Summary Building for the unmatched PSBLD-ITEM-C is '$cellC', expected an empty cell"
    }
    $dCellC = $detail['PSBLD-ITEM-C'][0][0]
    if ($dCellC -ne '') {
        Fail "Detail Building for the unmatched PSBLD-ITEM-C is '$dCellC', expected an empty cell"
    }
    OK 'unmatched item writes an empty cell on Summary and Detail'

    $rowC = $preview.summaryPreview | Where-Object { $_.itemCode -eq 'PSBLD-ITEM-C' }
    if (-not [string]::IsNullOrEmpty($rowC.building)) {
        Fail "preview building for PSBLD-ITEM-C is '$($rowC.building)', expected null so the table renders an em-dash"
    }
    # The em-dash is the renderer's job; assert the fallback is still wired.
    if ($jsSrc -notmatch 'r\.building \|\|') {
        Fail 'pull-sheets.js no longer falls back for a null building -- the cell would render "undefined"'
    }
    OK 'preview sends null and the renderer falls back to an em-dash'

    # ------------------------------------------------------------------------
    Step '7. NBSP padding is not a disagreement, and never reaches a cell'
    # ------------------------------------------------------------------------
    # Item D has one building written twice, the second copy padded with U+00A0.
    # SQL Server LTRIM/RTRIM leave NBSP alone, so an unnormalised collapse sees
    # two values and reports *mixed* -- a disagreement created by padding.
    $nbspCell = $summary['PSBLD-ITEM-D'][0][0]
    if ($nbspCell -eq '*mixed*') {
        Fail 'PSBLD-ITEM-D collapsed to *mixed*, but both its PO lines say PSBLD-BN1 -- one is NBSP-padded and the fold is missing'
    }
    if ($nbspCell -ne 'PSBLD-BN1') {
        Fail "Summary Building for PSBLD-ITEM-D is '$nbspCell', expected 'PSBLD-BN1'"
    }
    if ($nbspCell -match [char]0x00A0) {
        Fail 'the Building cell still carries a non-breaking space -- it will not match a plain-space VLOOKUP key downstream'
    }
    OK 'an NBSP-padded duplicate collapses to the plain value, with no NBSP in the cell'

    # ------------------------------------------------------------------------
    Step '8. Grand Total collapses across the whole period'
    # ------------------------------------------------------------------------
    $ws = $wb.Worksheet('Grand Total')
    $hdr = HeaderRow $ws
    $gItem = [array]::IndexOf($hdr, 'Item Code') + 1
    $gBld  = [array]::IndexOf($hdr, 'Building') + 1
    $glast = $ws.LastRowUsed().RowNumber()
    $gt = @{}
    2..$glast | ForEach-Object {
        $code = $ws.Cell($_, $gItem).GetString()
        if ($code -like 'PSBLD-*') { $gt[$code] = $ws.Cell($_, $gBld).GetString() }
    }
    if ($gt['PSBLD-ITEM-A'] -ne 'PSBLD-B7X') { Fail "Grand Total Building for PSBLD-ITEM-A is '$($gt['PSBLD-ITEM-A'])', expected 'PSBLD-B7X'" }
    if ($gt['PSBLD-ITEM-B'] -ne '*mixed*')   { Fail "Grand Total Building for PSBLD-ITEM-B is '$($gt['PSBLD-ITEM-B'])', expected '*mixed*'" }
    if ($gt['PSBLD-ITEM-C'] -ne '')          { Fail "Grand Total Building for PSBLD-ITEM-C is '$($gt['PSBLD-ITEM-C'])', expected an empty cell" }
    OK 'Grand Total shows the agreed value, *mixed*, and blank respectively'
}
finally {
    if ($wb) { $wb.Dispose() }
}

if (Test-Path $tmpXlsx) { Remove-Item $tmpXlsx -Force }

Step 'Cleanup'
SqlCleanup

Write-Host "`nsmoke-pull-sheets-building: ALL PASS" -ForegroundColor Green
exit 0
