# Smoke test: Reports -> Pull Sheets BUILDING (pull-scoped) and VENDOR (historical).
#
# These two columns sit side by side and are resolved from DIFFERENT sets of PO
# lines, on purpose. That is the thing this smoke exists to pin, because both
# wrong answers look entirely plausible on screen:
#
#   * BUILDING is a property of the SHIPMENT. One pull ships to exactly one
#     building (measured 2026-08-25: 1,429 of 1,429 pulls with a linked PO
#     resolve to exactly one distinct value, none to two). It is scoped to the
#     PO linked to the pull -- the same predicate 7.15 FIFO uses -- and carries
#     NO ItemCode filter. Case 4c is the guard on that: an item on the pull but
#     absent from the PO's lines must STILL resolve. Re-adding
#     `pol.ItemCode = pi.ItemCode` to that APPLY turns this smoke red.
#
#   * VENDOR is a property of the PRODUCT -- a code-to-name lookup, where any PO
#     line for that (ItemCode, warehouse, storer) is a valid source and history
#     is not a contaminant. It stays scoped warehouse-wide. Case 6 is the guard:
#     a row whose Building is blank must still carry a Vendor Name. Merging the
#     two APPLYs into one, in either direction, turns this smoke red.
#
#   * The vendor lookup crosses two code FORMATS. PurchaseOrderLines.VendorCode
#     is prefixed (COI-PSBLDV1); PullItems.VendorCode is bare (PSBLDV1). Written
#     as a plain equality it matches NOTHING and the column reads as an
#     honest-looking wall of em-dashes.
#
#   * One pull now reaches EVERY line of its PO, not just its own item's. If
#     Building were joined rather than APPLY'd, every window row would multiply
#     by the PO's line count and inflate ExpectedQty on all four sheets while
#     still producing a plausible file. Case 5b is the guard.
#
# Exercises:
#   1. Fixture: 4 pulls covering both halves of the pull-scope predicate, an
#      unlinked pull, and a PO that violates the one-building rule.
#   2. Preview API carries `building`; the Reports page header has BUILDING
#      immediately after VENDOR.
#   3. Building on Summary / Detail / Grand Total, absent from Header.
#   4. Pull-scoped resolution: via PullExternalRef (4a) and via PullId (4b);
#      and an item ABSENT from the PO's lines still resolves (4c).
#   5. NBSP fold before the collapse; grain guard (no row fan-out).
#   6. Two scopes on ONE row: Building blank, Vendor resolved.
#   7. A pull with no PO -> blank, not '*mixed*', and NOT the unlinked PO's
#      building (the historical scope must not leak back).
#   8. pi.VendorName populated wins over the resolved value.
#   9. Grand Total collapses BOTH columns across the period: same item in two
#      buildings -> '*mixed*'; same item from two storers -> '*mixed*'.
#  10. A PO whose lines disagree -> '*mixed*' survives as the upstream-breakage
#      signal.
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

# Routed through a temp FILE rather than -Q. This fixture is long enough that
# passing it as one command-line argument trips sqlcmd's own re-parse of the
# Windows command line ("'-' or '/' does not have an associated argument"), and
# the failure looks like a SQL error rather than a quoting one.
function RunSql($sql) {
    $f = Join-Path ([IO.Path]::GetTempPath()) "psbld-$([guid]::NewGuid().ToString('N')).sql"
    try {
        [IO.File]::WriteAllText($f, $sql, (New-Object Text.UTF8Encoding $true))
        $out = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -b -i $f 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "SQL FAILED (exit $LASTEXITCODE): $out" -ForegroundColor Red
            exit 2
        }
        return $out
    }
    finally { if (Test-Path $f) { Remove-Item $f -Force } }
}

# Order matters: windows -> items -> pulls, and lines -> orders. PurchaseOrders
# is cleared BEFORE Pulls because a PullId-linked PO is a child of its pull.
# Never piped to Out-Null -- a cleanup that fails silently leaves the next run
# seeding on top of its own residue (docs/smoke-conventions.md).
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
DELETE pol FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'PSBLD-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PSBLD-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PSBLD-%';
PRINT 'cleanup: pulls removed = ' + CONVERT(varchar, @@ROWCOUNT);
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

# Indexes a sheet by item code -> list of hashtables of the requested columns,
# for the PSBLD-* rows only.
function IndexSheet($ws, $keyCol, $cols) {
    $hdr = HeaderRow $ws
    $ki = [array]::IndexOf($hdr, $keyCol) + 1
    if ($ki -lt 1) { Fail "sheet has no '$keyCol' column -- [$($hdr -join ' | ')]" }
    $ci = @{}
    foreach ($c in $cols) {
        $i = [array]::IndexOf($hdr, $c) + 1
        if ($i -lt 1) { Fail "sheet has no '$c' column -- [$($hdr -join ' | ')]" }
        $ci[$c] = $i
    }
    $idx = @{}
    $last = $ws.LastRowUsed().RowNumber()
    2..$last | ForEach-Object {
        $r = $_
        $code = $ws.Cell($r, $ki).GetString()
        if ($code -like 'PSBLD-*') {
            $vals = @{}
            foreach ($c in $cols) { $vals[$c] = $ws.Cell($r, $ci[$c]).GetString() }
            if (-not $idx.ContainsKey($code)) { $idx[$code] = @() }
            $idx[$code] += $vals
        }
    }
    return $idx
}

function OnPull($rows, $pull) {
    $hit = @($rows | Where-Object { $_['Pull #'] -eq $pull })
    if ($hit.Count -eq 0) { Fail "no row for pull $pull" }
    return $hit[0]
}

SqlCleanup

# ----------------------------------------------------------------------------
Step '1. Seed four pulls covering every Building outcome the new scope can produce'
# ----------------------------------------------------------------------------
#
#   PSBLD-1  -> PSBLD-PO-1    linked by PullExternalRef (PullId NULL)   B7X
#   PSBLD-2  -> PSBLD-PO-2    linked by PullId (PullExternalRef NULL)   B2Y
#   PSBLD-3  -> no PO at all                                            blank
#   PSBLD-4  -> PSBLD-PO-4    linked, lines DISAGREE                    *mixed*
#   PSBLD-PO-HIST             linked to NOTHING. Supplies vendor names
#                             warehouse-wide and carries PSBLD-BHIST, a
#                             building that must never reach a cell.
#
RunSql @"
SET NOCOUNT ON;
DECLARE @wh UNIQUEIDENTIFIER = '$WH_01';
DECLARE @p1 UNIQUEIDENTIFIER = NEWID(), @p2 UNIQUEIDENTIFIER = NEWID(),
        @p3 UNIQUEIDENTIFIER = NEWID(), @p4 UNIQUEIDENTIFIER = NEWID();
DECLARE @po1 UNIQUEIDENTIFIER = NEWID(), @po2 UNIQUEIDENTIFIER = NEWID(),
        @po4 UNIQUEIDENTIFIER = NEWID(), @poH UNIQUEIDENTIFIER = NEWID();

INSERT dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status)
VALUES (@p1, 'PSBLD-1', @wh, '$D', 'in_progress'),
       (@p2, 'PSBLD-2', @wh, '$D', 'in_progress'),
       (@p3, 'PSBLD-3', @wh, '$D', 'in_progress'),
       (@p4, 'PSBLD-4', @wh, '$D', 'in_progress');

-- Pull items. VendorName NULL everywhere except ITEM-E, which states its own.
DECLARE @iA1 UNIQUEIDENTIFIER = NEWID(), @iB  UNIQUEIDENTIFIER = NEWID(),
        @iF1 UNIQUEIDENTIFIER = NEWID(), @iA2 UNIQUEIDENTIFIER = NEWID(),
        @iF2 UNIQUEIDENTIFIER = NEWID(), @iC  UNIQUEIDENTIFIER = NEWID(),
        @iE  UNIQUEIDENTIFIER = NEWID(), @iG  UNIQUEIDENTIFIER = NEWID();

INSERT dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, VendorName, SortOrder)
VALUES (@iA1, @p1, 'PSBLD-ITEM-A', N'on PO-1, resolves both columns',  'PSBLDV1', NULL, 1),
       (@iB,  @p1, 'PSBLD-ITEM-B', N'on the pull, NOT a PO-1 line',    'PSBLDV2', NULL, 2),
       (@iF1, @p1, 'PSBLD-ITEM-F', N'storer one of two',               'PSBLDV6', NULL, 3),
       (@iA2, @p2, 'PSBLD-ITEM-A', N'same item, second building',      'PSBLDV1', NULL, 1),
       (@iF2, @p2, 'PSBLD-ITEM-F', N'storer two of two',               'PSBLDV7', NULL, 2),
       (@iC,  @p3, 'PSBLD-ITEM-C', N'no PO on this pull',              'PSBLDV3', NULL, 1),
       (@iE,  @p3, 'PSBLD-ITEM-E', N'states its own vendor name',      'PSBLDV5', N'PSBLD Seeded Vendor', 2),
       (@iG,  @p4, 'PSBLD-ITEM-G', N'its PO disagrees with itself',    'PSBLDV8', NULL, 1);

INSERT dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty, IsClosed)
VALUES (NEWID(), @iA1, $HOUR, 900, 100, 0),
       (NEWID(), @iB,  $HOUR, 500, 0,   0),
       (NEWID(), @iF1, $HOUR, 400, 0,   0),
       (NEWID(), @iA2, $HOUR, 300, 0,   0),
       (NEWID(), @iF2, $HOUR, 200, 0,   0),
       (NEWID(), @iC,  $HOUR, 250, 0,   0),
       (NEWID(), @iE,  $HOUR, 150, 0,   0),
       (NEWID(), @iG,  $HOUR, 100, 0,   0);

-- PO-1 reaches its pull through PullExternalRef ONLY. PullId stays NULL, which
-- is the shape every Phase 12 import lands in (27 of 1,761 POs carry the FK;
-- 1,742 carry the ref). A predicate that only checked the FK misses these.
INSERT dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, Status, PullId, PullExternalRef)
VALUES (@po1, 'PSBLD-PO-1', @wh, '$D', 'open', NULL, 'PSBLD-1'),
-- PO-2 reaches its pull through the FK ONLY -- the other half of the predicate.
       (@po2, 'PSBLD-PO-2', @wh, '$D', 'open', @p2,  NULL),
       (@po4, 'PSBLD-PO-4', @wh, '$D', 'open', NULL, 'PSBLD-4'),
-- Linked to NOTHING. Its Building must never surface; its vendor names must.
       (@poH, 'PSBLD-PO-HIST', @wh, '$D', 'open', NULL, NULL);

-- VendorCode is written PREFIXED on every PO line, on purpose. A vendor lookup
-- that compares it to the pull item's bare 'PSBLDV1' with plain equality
-- matches zero rows and reports it as "no data".
--
-- Every line of PO-1 carries the SAME building, including one padded with a
-- non-breaking space: SQL Server LTRIM/RTRIM leave U+00A0 alone, so without the
-- fold those two read as a disagreement and the pull invents a *mixed*.
-- Note there is NO PSBLD-ITEM-B line here -- that item resolves anyway.
INSERT dbo.PurchaseOrderLines
      (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName, Building)
VALUES (NEWID(), @po1, 1, 'PSBLD-ITEM-A', N'po1 line a', 1000, 0, 'COI-PSBLDV1', N'PSBLD Vendor One', 'PSBLD-B7X'),
       (NEWID(), @po1, 2, 'PSBLD-ITEM-F', N'po1 line f', 1000, 0, 'COI-PSBLDV6', N'PSBLD Vendor Six', N'PSBLD-B7X' + NCHAR(160)),
       (NEWID(), @po1, 3, 'PSBLD-ITEM-Z', N'po1 line z', 1000, 0, 'COI-PSBLDV9', N'PSBLD Vendor Nine', 'PSBLD-B7X'),
       (NEWID(), @po2, 1, 'PSBLD-ITEM-A', N'po2 line a', 1000, 0, 'COI-PSBLDV1', N'PSBLD Vendor One', 'PSBLD-B2Y'),
       (NEWID(), @po2, 2, 'PSBLD-ITEM-F', N'po2 line f', 1000, 0, 'COI-PSBLDV7', N'PSBLD Vendor Seven', 'PSBLD-B2Y'),
       -- PO-4 breaks the one-pull-one-building rule. The collapse is what makes
       -- that visible instead of silently picking whichever line sorted first.
       (NEWID(), @po4, 1, 'PSBLD-ITEM-G', N'po4 line g1', 1000, 0, 'COI-PSBLDV8', N'PSBLD Vendor Eight', 'PSBLD-BG1'),
       (NEWID(), @po4, 2, 'PSBLD-ITEM-G', N'po4 line g2', 1000, 0, 'COI-PSBLDV8', N'PSBLD Vendor Eight', 'PSBLD-BG2'),
       -- Unlinked history. PSBLD-BHIST is the tripwire: it can only reach a cell
       -- if Building has been re-scoped to (ItemCode, warehouse, storer).
       (NEWID(), @poH, 1, 'PSBLD-ITEM-B', N'hist line b', 1000, 0, 'COI-PSBLDV2', N'PSBLD Vendor Two',  'PSBLD-BHIST'),
       (NEWID(), @poH, 2, 'PSBLD-ITEM-C', N'hist line c', 1000, 0, 'COI-PSBLDV3', N'PSBLD Vendor Three','PSBLD-BHIST'),
       (NEWID(), @poH, 3, 'PSBLD-ITEM-E', N'hist line e', 1000, 0, 'COI-PSBLDV5', N'PSBLD Overwritten', 'PSBLD-BHIST');

DECLARE @seeded INT = (SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE 'PSBLD-%');
IF @seeded <> 4 RAISERROR('Fixture did not land 4 pulls - seed is invalid', 16, 1);
PRINT 'seeded';
"@ | Out-Null
OK 'Seeded PSBLD-1..4 plus an unlinked history PO'

$sv = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
Step '2. Preview API carries a building field, and the page header shows it after VENDOR'
# ----------------------------------------------------------------------------
$preview = Invoke-RestMethod -WebSession $sv `
    -Uri "$base/api/reports/pull-sheets/preview?warehouseId=$WH_01&date=$D&period=morning"

if ($preview.summaryPreview.Count -lt 8) {
    Fail "preview returned $($preview.summaryPreview.Count) rows, expected the 8 seeded (pull, item) rows"
}
$rowA1 = $preview.summaryPreview | Where-Object { $_.pullNumber -eq 'PSBLD-1' -and $_.itemCode -eq 'PSBLD-ITEM-A' }
if (-not $rowA1) { Fail 'PSBLD-1 / PSBLD-ITEM-A missing from the preview' }
# Asserted on a row that HAS a value, deliberately. The API serializes with
# JsonIgnoreCondition.WhenWritingNull, so a null building is omitted from the
# JSON entirely -- a bare property-exists check would be indistinguishable from
# case 7, where absence is the correct answer.
if ($rowA1.building -ne 'PSBLD-B7X') {
    Fail "preview building for PSBLD-1/PSBLD-ITEM-A is '$($rowA1.building)', expected 'PSBLD-B7X' from its PullExternalRef-linked PO"
}
OK "preview response carries building='PSBLD-B7X'"

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

$viewSrc = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\Views\Reports\Index.cshtml')
$jsSrc   = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\wwwroot\js\pull-sheets.js')
if ($viewSrc -match 'colspan="9"[^>]*class="ps-empty"' -or $jsSrc -match 'colspan=\\?"9\\?"[^>]*ps-empty') {
    Fail 'a ps-empty placeholder still spans 9 columns -- the table now has 10'
}
OK 'empty-state colspan tracks the column count'

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
    $hs = $wb.Worksheet('Header')
    $hlast = $hs.LastRowUsed().RowNumber()
    $keys = 1..$hlast | ForEach-Object { $hs.Cell($_, 1).GetString() }
    if ($keys -contains 'Building') { Fail "'Header' sheet gained a Building criteria row" }
    OK "'Header' sheet is unchanged -- no Building column or row"

    $detail  = IndexSheet $wb.Worksheet('Detail')      'Item Code' @('Building','Vendor Name','Vendor Code','Expected','Pull #')
    $summary = IndexSheet $wb.Worksheet('Summary')     'Item Code' @('Building','Vendor Name','Total Expected','Pull #')
    $gt      = IndexSheet $wb.Worksheet('Grand Total') 'Item Code' @('Building','Vendor')

    # ------------------------------------------------------------------------
    Step '4. Pull-scoped resolution: PullExternalRef, PullId, and an item absent from the PO'
    # ------------------------------------------------------------------------
    $a1 = OnPull $detail['PSBLD-ITEM-A'] 'PSBLD-1'
    if ($a1['Building'] -ne 'PSBLD-B7X') {
        Fail "PSBLD-1/ITEM-A Building is '$($a1['Building'])', expected 'PSBLD-B7X'. Its PO carries PullExternalRef='PSBLD-1' and PullId=NULL -- an empty value means the scope predicate is only checking the FK."
    }
    OK '4a. resolved through PullExternalRef (PullId NULL)'

    $a2 = OnPull $detail['PSBLD-ITEM-A'] 'PSBLD-2'
    if ($a2['Building'] -ne 'PSBLD-B2Y') {
        Fail "PSBLD-2/ITEM-A Building is '$($a2['Building'])', expected 'PSBLD-B2Y'. Its PO carries PullId and PullExternalRef=NULL -- an empty value means the scope predicate is only checking the ref."
    }
    OK '4b. resolved through PullId (PullExternalRef NULL)'

    # THE ItemCode GUARD. PSBLD-ITEM-B is on pull PSBLD-1 but is NOT a line of
    # PSBLD-PO-1. Building belongs to the shipment, so it resolves anyway.
    # Re-adding `pol.ItemCode = pi.ItemCode` to the Building APPLY blanks this.
    $b = OnPull $detail['PSBLD-ITEM-B'] 'PSBLD-1'
    if ($b['Building'] -eq 'PSBLD-BHIST') {
        Fail 'PSBLD-ITEM-B picked up PSBLD-BHIST from the unlinked PO -- Building has been re-scoped to the item history'
    }
    if ($b['Building'] -ne 'PSBLD-B7X') {
        Fail "PSBLD-ITEM-B Building is '$($b['Building'])', expected 'PSBLD-B7X'. This item is on the pull but absent from its PO's lines: an empty value here means an ItemCode predicate has been re-added to the Building APPLY, which is exactly the 617-pull-items-of-nothing this scope exists to avoid."
    }
    OK '4c. an item absent from the PO lines still resolves from the pull'

    # ------------------------------------------------------------------------
    Step '5. NBSP fold before the collapse, and no row fan-out'
    # ------------------------------------------------------------------------
    # PO-1 has three lines, all saying PSBLD-B7X, one of them NBSP-padded. An
    # unnormalised collapse sees two values and reports *mixed*.
    if ($a1['Building'] -eq '*mixed*') {
        Fail 'PSBLD-1 collapsed to *mixed*, but all three PO-1 lines say PSBLD-B7X -- one is NBSP-padded and the fold is missing'
    }
    if ($a1['Building'] -match [char]0x00A0) {
        Fail 'the Building cell carries a non-breaking space -- it will not match a plain-space VLOOKUP key downstream'
    }
    OK '5a. an NBSP-padded line is not a disagreement, and no NBSP reaches the cell'

    # Grain guard: ITEM-A reaches all THREE lines of PO-1 now that the APPLY has
    # no ItemCode filter. Joined rather than APPLY'd, this row would triple and
    # its 900 would read as 2700 on a file that otherwise looks normal.
    if ($detail['PSBLD-ITEM-A'].Count -ne 2) {
        Fail "PSBLD-ITEM-A produced $($detail['PSBLD-ITEM-A'].Count) Detail rows, expected 2 (one per pull) -- the PO-line join is fanning rows out"
    }
    $sa1 = OnPull $summary['PSBLD-ITEM-A'] 'PSBLD-1'
    if ([double]$sa1['Total Expected'] -ne 900) {
        Fail "PSBLD-1/ITEM-A Total Expected is $($sa1['Total Expected']), expected 900 -- reaching 3 PO lines has inflated the quantity"
    }
    OK '5b. reaching three PO lines still yields one row per pull at the seeded quantity'

    # ------------------------------------------------------------------------
    Step '6. Two scopes on one row: Building blank, Vendor resolved'
    # ------------------------------------------------------------------------
    # This is the assertion that catches a future re-merge into a single APPLY,
    # in EITHER direction. PSBLD-3 has no PO, so Building must be blank; its
    # vendor still resolves warehouse-wide from the unlinked history PO.
    $c = OnPull $detail['PSBLD-ITEM-C'] 'PSBLD-3'
    if ($c['Building'] -ne '') {
        Fail "PSBLD-ITEM-C Building is '$($c['Building'])', expected an empty cell -- pull PSBLD-3 has no PO"
    }
    if ($c['Vendor Name'] -ne 'PSBLD Vendor Three') {
        Fail "PSBLD-ITEM-C Vendor Name is '$($c['Vendor Name'])', expected 'PSBLD Vendor Three'. Building is correctly blank on this row; if Vendor is blank too, the two APPLYs have been merged onto the pull scope and a column with data has been emptied."
    }
    OK '6a. Building blank and Vendor resolved on the SAME row -- the two scopes are distinct'

    # And the mirror: ITEM-A resolves its vendor across the COI- prefix gap.
    if ($a1['Vendor Name'] -ne 'PSBLD Vendor One') {
        Fail "PSBLD-1/ITEM-A Vendor Name is '$($a1['Vendor Name'])', expected 'PSBLD Vendor One'. The PO line holds 'COI-PSBLDV1' against the pull item's bare 'PSBLDV1' -- an empty value means the prefix is not being bridged."
    }
    if ($a1['Vendor Code'] -ne 'PSBLDV1') {
        Fail "PSBLD-1/ITEM-A Vendor Code is '$($a1['Vendor Code'])', expected the pull item's own bare 'PSBLDV1'"
    }
    OK "6b. vendor name resolved across the COI- prefix; vendor code stays the pull item's own"

    # ------------------------------------------------------------------------
    Step '7. A pull with no PO writes a blank -- not *mixed*, not a stale value'
    # ------------------------------------------------------------------------
    if ($c['Building'] -eq '*mixed*') { Fail 'unmatched pull produced *mixed* rather than a blank' }
    $sc = OnPull $summary['PSBLD-ITEM-C'] 'PSBLD-3'
    if ($sc['Building'] -ne '') { Fail "Summary Building for PSBLD-ITEM-C is '$($sc['Building'])', expected an empty cell" }

    $rowC = $preview.summaryPreview | Where-Object { $_.itemCode -eq 'PSBLD-ITEM-C' }
    if (-not [string]::IsNullOrEmpty($rowC.building)) {
        Fail "preview building for PSBLD-ITEM-C is '$($rowC.building)', expected null so the table renders an em-dash"
    }
    if ($jsSrc -notmatch 'r\.building \|\|') {
        Fail 'pull-sheets.js no longer falls back for a null building -- the cell would render "undefined"'
    }
    OK '7. no linked PO -> empty cell on Detail and Summary, null in the preview'

    # ------------------------------------------------------------------------
    Step '8. A pull item that states its own vendor name keeps it'
    # ------------------------------------------------------------------------
    # PSBLD-ITEM-E carries VendorName='PSBLD Seeded Vendor'; its history line
    # says 'PSBLD Overwritten'. The COALESCE must prefer the pull item.
    $e = OnPull $detail['PSBLD-ITEM-E'] 'PSBLD-3'
    if ($e['Vendor Name'] -ne 'PSBLD Seeded Vendor') {
        Fail "PSBLD-ITEM-E Vendor Name is '$($e['Vendor Name'])', expected the pull item's own 'PSBLD Seeded Vendor'. Reading 'PSBLD Overwritten' means the resolved value is winning over a stated one."
    }
    OK '8. pi.VendorName wins over the resolved value'

    # ------------------------------------------------------------------------
    Step '9. Grand Total collapses BOTH columns across the period'
    # ------------------------------------------------------------------------
    # ITEM-A ships to B7X on one pull and B2Y on the other. Each Summary row
    # keeps its own; Grand Total, which spans both, must say *mixed*.
    if ($gt['PSBLD-ITEM-A'][0]['Building'] -ne '*mixed*') {
        Fail "Grand Total Building for PSBLD-ITEM-A is '$($gt['PSBLD-ITEM-A'][0]['Building'])', expected '*mixed*' (PSBLD-B7X on one pull, PSBLD-B2Y on the other)"
    }
    $sa2 = OnPull $summary['PSBLD-ITEM-A'] 'PSBLD-2'
    if ($sa1['Building'] -ne 'PSBLD-B7X' -or $sa2['Building'] -ne 'PSBLD-B2Y') {
        Fail "Summary rows lost their own building values ('$($sa1['Building'])' / '$($sa2['Building'])') -- Summary must stay traceable while Grand Total collapses"
    }
    OK '9a. Building: *mixed* on Grand Total, own value on each Summary row'

    # ITEM-F comes from storer PSBLDV6 on one pull and PSBLDV7 on the other --
    # dual sourcing, which is normal. Taking the first non-blank would name one
    # supplier as though it were the only one.
    if ($gt['PSBLD-ITEM-F'][0]['Vendor'] -ne '*mixed*') {
        Fail "Grand Total Vendor for PSBLD-ITEM-F is '$($gt['PSBLD-ITEM-F'][0]['Vendor'])', expected '*mixed*'. It is sourced from two storers across the period; a single name here means the collapse is still FirstOrDefault."
    }
    if ($gt['PSBLD-ITEM-F'][0]['Vendor'] -match ',') {
        Fail 'disagreeing vendors were comma-joined -- the collapse must produce a word'
    }
    $sf1 = OnPull $summary['PSBLD-ITEM-F'] 'PSBLD-1'
    $sf2 = OnPull $summary['PSBLD-ITEM-F'] 'PSBLD-2'
    if ($sf1['Vendor Name'] -ne 'PSBLD Vendor Six' -or $sf2['Vendor Name'] -ne 'PSBLD Vendor Seven') {
        Fail "Summary vendor rows are '$($sf1['Vendor Name'])' / '$($sf2['Vendor Name'])', expected Six / Seven -- Summary must stay traceable"
    }
    OK '9b. Vendor: *mixed* on Grand Total, own storer on each Summary row'

    if ($gt['PSBLD-ITEM-C'][0]['Building'] -ne '') {
        Fail "Grand Total Building for PSBLD-ITEM-C is '$($gt['PSBLD-ITEM-C'][0]['Building'])', expected an empty cell"
    }
    OK '9c. Grand Total writes a blank for the item with no linked PO'

    # ------------------------------------------------------------------------
    Step '10. A PO whose own lines disagree still reports *mixed*'
    # ------------------------------------------------------------------------
    # This should be unreachable in production -- 1,429 of 1,429 pulls resolve to
    # one building. The collapse stays as the signal that says so out loud if the
    # rule ever breaks upstream, instead of picking whichever line sorted first.
    $g = OnPull $detail['PSBLD-ITEM-G'] 'PSBLD-4'
    if ($g['Building'] -ne '*mixed*') {
        Fail "PSBLD-ITEM-G Building is '$($g['Building'])', expected '*mixed*' -- PSBLD-PO-4 says PSBLD-BG1 on one line and PSBLD-BG2 on another, and that disagreement must stay visible"
    }
    if ($g['Building'] -match ',') {
        Fail 'disagreeing buildings were comma-joined -- the column is a VLOOKUP key downstream and must collapse to a word'
    }
    OK '10. a self-disagreeing PO surfaces *mixed* rather than a silent pick'
}
finally {
    if ($wb) { $wb.Dispose() }
}

if (Test-Path $tmpXlsx) { Remove-Item $tmpXlsx -Force }

Step 'Cleanup'
SqlCleanup

Write-Host "`nsmoke-pull-sheets-building: ALL PASS" -ForegroundColor Green
exit 0
