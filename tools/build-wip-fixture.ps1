# Generator for the WIP pull-synthesis smoke fixtures.
#
# One-shot — produces four .xlsx files under tools/fixtures/ using the
# project's own NPOI dlls so the writer/reader path is byte-identical.
# NOT registered in the smoke battery; re-run only when a fixture's shape
# needs to change.
#
#   po-import-wip-sample.xlsx        the happy path (also carries a NON-WIP
#                                    sheet, so the smoke can prove ordinary
#                                    sheets are untouched)
#   po-import-wip-mixed.xlsx         one sheet with WIP and non-WIP rows
#   po-import-wip-two-storers.xlsx   one WIP sheet with two storer codes
#   po-import-wip-bad-round.xlsx     one WIP row whose ROUND names two hours
#   po-import-wip-round-default.xlsx blank WIP ROUNDs (→ hour 07) alongside a
#                                    populated one and a non-WIP sheet
#   po-import-nonwip-blank-round.xlsx a NON-WIP sheet with a blank ROUND
#
# Shapes mirror the production export measured on Stock_Ship_16-Aug-2026.xls:
# STORER CODE is the prefixed form (COI-…), the WIP sheets leave PO blank on
# every row (647/647 in production), ROUND is HH:00, and one SKU arrives as
# nine rows differing only by pallet — the case that MUST be summed, because
# PullItemWindows is unique on (PullItemId, HourOfDay).
#
# Pull numbers use the WIPTEST- prefix so the smoke can purge by LIKE without
# touching anything real. WIP detection keys off STORER CODE, never the pull
# number, so a synthetic number costs the fixture nothing.

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$bin = Join-Path $repoRoot 'src\ReceivingOps.Web\bin\Debug\net8.0'
$fixtureDir = Join-Path $repoRoot 'tools\fixtures'

if (-not (Test-Path $bin)) {
    Write-Host "FAIL: build output not found at $bin — run dotnet build first" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $fixtureDir)) { New-Item -ItemType Directory -Path $fixtureDir | Out-Null }

Add-Type -Path (Join-Path $bin 'NPOI.Core.dll')
Add-Type -Path (Join-Path $bin 'NPOI.OpenXml4Net.dll')
Add-Type -Path (Join-Path $bin 'NPOI.OpenXmlFormats.dll')
Add-Type -Path (Join-Path $bin 'NPOI.OOXML.dll')

# Column order copied from the real export's first ten mapped columns plus
# ROUND. Header names are the matching keys — the parser is position-blind,
# but keeping them recognisable helps anyone opening a fixture by hand.
$headers = @(
    'PULL SHEET ID / PRS NO',
    'STORER CODE',
    'STORER NAME',
    'SKU',
    'SKU DESCRIPTION',
    'OPEN QTY',
    'DELIVERY DATE',
    'ROUND',
    'PALLET ID',
    'PO'
)

# dd/MM/yyyy, the production format GetDate parses via TryParseExact.
$deliveryDate = (Get-Date).ToUniversalTime().ToString('dd/MM/yyyy')

function Write-Fixture([string]$fileName, [array]$rows) {
    $wb = New-Object NPOI.XSSF.UserModel.XSSFWorkbook
    $sheet = $wb.CreateSheet('data')

    $hr = $sheet.CreateRow(0)
    for ($i = 0; $i -lt $headers.Count; $i++) { $hr.CreateCell($i).SetCellValue($headers[$i]) }

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $row = $sheet.CreateRow($i + 1)
        $row.CreateCell(0).SetCellValue([string]$r.Pull)
        $row.CreateCell(1).SetCellValue([string]$r.Storer)
        $row.CreateCell(2).SetCellValue([string]$r.StorerName)
        $row.CreateCell(3).SetCellValue([string]$r.Sku)
        $row.CreateCell(4).SetCellValue([string]$r.Desc)
        $row.CreateCell(5).SetCellValue([double]$r.Qty)
        # A per-row date override lets the two-delivery-date guard rail be tested.
        $rowDate = if ($r.ContainsKey('Date')) { $r.Date } else { $deliveryDate }
        $row.CreateCell(6).SetCellValue([string]$rowDate)
        $row.CreateCell(7).SetCellValue([string]$r.Round)
        $row.CreateCell(8).SetCellValue([string]$r.Pallet)
        # PO blank on WIP rows, matching production (647/647).
        $row.CreateCell(9).SetCellValue([string]$r.SrcPo)
    }

    $out = Join-Path $fixtureDir $fileName
    $fs = New-Object System.IO.FileStream($out, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try { $wb.Write($fs, $false) } finally { $fs.Dispose() }
    Write-Host ("Wrote {0} ({1} rows, {2} bytes)" -f $out, $rows.Count, (Get-Item $out).Length) -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 1. Happy path.
#
#    WIPTEST-0001 (WIP): 3 SKUs / 3 windows.
#      SKU-A  9 rows, all 07:00, qty 100 each   → ONE window of 900
#      SKU-B  1 row,  08:00, qty 250            → ONE window of 250
#      SKU-C  1 row,  19:00, qty 40             → ONE window of 40
#    WIPTEST-9001 (NOT WIP): 2 rows, ordinary storer code — must produce a
#    PO with per-row lines and NO pull at all.
# ---------------------------------------------------------------------------
$happy = @()
for ($i = 1; $i -le 9; $i++) {
    $happy += @{ Pull='WIPTEST-0001'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE (BPI)';
                 Sku='WIPSKU-A'; Desc='WIP part A'; Qty=100; Round='07:00';
                 Pallet=('B000000000{0:d2}' -f $i); SrcPo='' }
}
$happy += @{ Pull='WIPTEST-0001'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE (BPI)';
             Sku='WIPSKU-B'; Desc='WIP part B'; Qty=250; Round='08:00'; Pallet='B00000000021'; SrcPo='' }
$happy += @{ Pull='WIPTEST-0001'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE (BPI)';
             Sku='WIPSKU-C'; Desc='WIP part C'; Qty=40;  Round='19:00'; Pallet='B00000000031'; SrcPo='' }
$happy += @{ Pull='WIPTEST-9001'; Storer='COI-PLAIN1'; StorerName='ORDINARY VENDOR';
             Sku='PLAINSKU-A'; Desc='Ordinary part A'; Qty=15; Round='07:00'; Pallet='P0001'; SrcPo='TH-PLAIN-1' }
$happy += @{ Pull='WIPTEST-9001'; Storer='COI-PLAIN1'; StorerName='ORDINARY VENDOR';
             Sku='PLAINSKU-B'; Desc='Ordinary part B'; Qty=25; Round='07:00'; Pallet='P0002'; SrcPo='TH-PLAIN-2' }
Write-Fixture 'po-import-wip-sample.xlsx' $happy

# ---------------------------------------------------------------------------
# 2. Every observed production ROUND value, one SKU each: 7, 8, 9, 11, 19,
#    21, 23. Proves the HH:00 → HourOfDay mapping across the full set rather
#    than the three the happy-path fixture happens to use.
# ---------------------------------------------------------------------------
$rounds = @('07:00','08:00','09:00','11:00','19:00','21:00','23:00')
$roundRows = @()
foreach ($r in $rounds) {
    $h = [int]$r.Substring(0, 2)
    $roundRows += @{ Pull='WIPTEST-0002'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE (BPI)';
                     Sku=("WIPSKU-R{0:d2}" -f $h); Desc="WIP round $r"; Qty=(10 * $h); Round=$r;
                     Pallet=("B0000000R{0:d2}" -f $h); SrcPo='' }
}
Write-Fixture 'po-import-wip-rounds.xlsx' $roundRows

# ---------------------------------------------------------------------------
# 3. Overflow pair. Two WIP sheets sharing a storer code AND a SKU, so each
#    gets its own synthesised pull + PO carrying an open line for the same
#    (vendor, item, warehouse).
#
#    That is precisely what variance overflow needs: ReadOpenPoLinesAsync
#    anchors on the pull-linked PO line's VendorCode (the prefixed form — it
#    deliberately does NOT fall back to PullItems.VendorCode) and then widens
#    to other open lines matching that vendor + item, pull-linked first. So an
#    over-receipt of 150 against WIPTEST-0006's window of 100 takes 100 from
#    its own PO and spills 50 onto WIPTEST-0007's line.
#
#    Quantities are deliberately unequal (100 vs 500) so the allocation split
#    can only come out one way.
# ---------------------------------------------------------------------------
Write-Fixture 'po-import-wip-overflow.xlsx' @(
    @{ Pull='WIPTEST-0006'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE (BPI)';
       Sku='WIPSKU-OF'; Desc='overflow target'; Qty=100; Round='07:00'; Pallet='B0000000OF1'; SrcPo='' },
    @{ Pull='WIPTEST-0007'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE (BPI)';
       Sku='WIPSKU-OF'; Desc='overflow source'; Qty=500; Round='07:00'; Pallet='B0000000OF2'; SrcPo='' }
)

# ---------------------------------------------------------------------------
# 4-6. Guard rails (§4.1). Each has ZERO occurrences in production; the point
#      is that if one ever appears a human looks at it instead of the importer
#      guessing a merge rule.
# ---------------------------------------------------------------------------
Write-Fixture 'po-import-wip-mixed.xlsx' @(
    @{ Pull='WIPTEST-0003'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE (BPI)';
       Sku='WIPSKU-M1'; Desc='WIP row'; Qty=10; Round='07:00'; Pallet='B1'; SrcPo='' },
    @{ Pull='WIPTEST-0003'; Storer='COI-PLAIN1'; StorerName='ORDINARY VENDOR';
       Sku='WIPSKU-M2'; Desc='non-WIP row on the same sheet'; Qty=20; Round='07:00'; Pallet='B2'; SrcPo='' }
)

Write-Fixture 'po-import-wip-two-storers.xlsx' @(
    @{ Pull='WIPTEST-0004'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE ONE';
       Sku='WIPSKU-S1'; Desc='storer one'; Qty=10; Round='07:00'; Pallet='B1'; SrcPo='' },
    @{ Pull='WIPTEST-0004'; Storer='COI-WIPTEST2'; StorerName='WIP EXAMPLE TWO';
       Sku='WIPSKU-S2'; Desc='storer two'; Qty=20; Round='07:00'; Pallet='B2'; SrcPo='' }
)

# A WIP ROUND that is PRESENT but unusable. "03:00|04:00" is a real value in
# the production export's non-WIP rows: it names two windows, and picking one
# would put stock in the wrong hour.
#
# This replaced a blank-ROUND fixture. A blank WIP ROUND is no longer an
# error — it defaults to hour 07 (WipPullSynthesis.WipBlankRoundHour), covered
# by smoke-wip-round-default.ps1. The guard rail that survives is this one:
# absence is defaulted, a wrong value never is.
Write-Fixture 'po-import-wip-bad-round.xlsx' @(
    @{ Pull='WIPTEST-0008'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE (BPI)';
       Sku='WIPSKU-BR1'; Desc='has a round'; Qty=10; Round='07:00'; Pallet='B1'; SrcPo='' },
    @{ Pull='WIPTEST-0008'; Storer='COI-WIPTEST1'; StorerName='WIP EXAMPLE (BPI)';
       Sku='WIPSKU-BR2'; Desc='two rounds in one cell'; Qty=20; Round='03:00|04:00'; Pallet='B2'; SrcPo='' }
)

# ---------------------------------------------------------------------------
# 7-8. Blank-ROUND default (hour 07). Namespaced WIPRND- rather than WIPTEST-
#      so smoke-wip-round-default.ps1 owns a range no other smoke purges.
#
#      WIPRND-0001 (WIP) is one workbook covering four claims at once:
#        D1  two rows, both blank      → ONE hour-07 window of 25, not two
#        D2  one row,  11:00           → hour 11; a present value always wins
#        D3  one row,  blank           → hour 07 on its own item
#      WIPRND-0002 (NOT WIP, populated ROUND) rides along so the same file
#      proves an ordinary sheet is untouched by any of it.
# ---------------------------------------------------------------------------
Write-Fixture 'po-import-wip-round-default.xlsx' @(
    @{ Pull='WIPRND-0001'; Storer='COI-WIPRND1'; StorerName='WIP ROUND DEFAULT';
       Sku='WIPRNDSKU-D1'; Desc='blank round, first row'; Qty=10; Round=''; Pallet='R1'; SrcPo='' },
    @{ Pull='WIPRND-0001'; Storer='COI-WIPRND1'; StorerName='WIP ROUND DEFAULT';
       Sku='WIPRNDSKU-D1'; Desc='blank round, second row'; Qty=15; Round='   '; Pallet='R2'; SrcPo='' },
    @{ Pull='WIPRND-0001'; Storer='COI-WIPRND1'; StorerName='WIP ROUND DEFAULT';
       Sku='WIPRNDSKU-D2'; Desc='populated round'; Qty=30; Round='11:00'; Pallet='R3'; SrcPo='' },
    @{ Pull='WIPRND-0001'; Storer='COI-WIPRND1'; StorerName='WIP ROUND DEFAULT';
       Sku='WIPRNDSKU-D3'; Desc='blank round, own item'; Qty=40; Round=''; Pallet='R4'; SrcPo='' },
    @{ Pull='WIPRND-0002'; Storer='COI-PLAINRND'; StorerName='ORDINARY VENDOR';
       Sku='WIPRNDSKU-P1'; Desc='ordinary row, populated round'; Qty=50; Round='11:00'; Pallet='R5'; SrcPo='TH-RND-1' }
)

# A NON-WIP sheet with a blank ROUND. The default must not reach it: WIP is
# half the condition, not decoration. Note this shape does not fail today
# either — ROUND is not a required header and PoImportReader.ValidateRow never
# inspects it, so the only blank-ROUND rejection that has ever existed was the
# WIP one. The smoke asserts the sheet is unchanged by this feature, which is
# the claim that can actually be made.
Write-Fixture 'po-import-nonwip-blank-round.xlsx' @(
    @{ Pull='WIPRND-0004'; Storer='COI-PLAINRND'; StorerName='ORDINARY VENDOR';
       Sku='WIPRNDSKU-N1'; Desc='non-WIP, blank round'; Qty=60; Round=''; Pallet='R6'; SrcPo='TH-RND-2' }
)

Write-Host "`nAll WIP fixtures written to $fixtureDir" -ForegroundColor Green
