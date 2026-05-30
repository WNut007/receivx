# Generator for the Phase 14 mixed-vendor smoke fixture.
#
# One-shot — produces tools/fixtures/po-import-mixed-vendor.xlsx using the
# project's own NPOI dlls so the writer/reader path is byte-identical.
# NOT registered in the smoke battery; re-run only when the fixture
# shape needs to change.
#
# Fixture shape:
#   sheet "data"
#   header row covers the 4 required headers + STORER CODE / STORER NAME
#   for vendor mapping + SKU DESCRIPTION
#   3 data rows = 1 PoNumber, 3 lines with 3 DIFFERENT vendors (V14-ALPHA,
#   V14-BETA, V14-GAMMA) — proves Phase 14's per-line vendor write closes
#   the v3.2 firstRow.VendorCode silent-loss defect. Deterministic prefix
#   "P14MIX-" so cleanup is straightforward and collisions impossible.

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$bin = Join-Path $repoRoot 'src\ReceivingOps.Web\bin\Debug\net8.0'
$out = Join-Path $repoRoot 'tools\fixtures\po-import-mixed-vendor.xlsx'

if (-not (Test-Path $bin)) {
    Write-Host "FAIL: build output not found at $bin — run dotnet build first" -ForegroundColor Red
    exit 1
}

# Load NPOI from the project's build output. Same order as the Phase 12.7
# fixture builder for the dependency chain (Core → OpenXml4Net →
# OpenXmlFormats → OOXML).
Add-Type -Path (Join-Path $bin 'NPOI.Core.dll')
Add-Type -Path (Join-Path $bin 'NPOI.OpenXml4Net.dll')
Add-Type -Path (Join-Path $bin 'NPOI.OpenXmlFormats.dll')
Add-Type -Path (Join-Path $bin 'NPOI.OOXML.dll')

$wb = New-Object NPOI.XSSF.UserModel.XSSFWorkbook
$sheet = $wb.CreateSheet("data")

$headers = @(
    "PULL SHEET ID / PRS NO",
    "STORER CODE",
    "STORER NAME",
    "SKU",
    "SKU DESCRIPTION",
    "OPEN QTY",
    "DELIVERY DATE"
)

$hr = $sheet.CreateRow(0)
for ($i = 0; $i -lt $headers.Count; $i++) {
    $hr.CreateCell($i).SetCellValue($headers[$i])
}

$today = (Get-Date).ToUniversalTime().ToString('dd/MM/yyyy')

# Single PoNumber, three distinct vendors per line. This is the production
# case Phase 14 unlocked: a single PRS_ID receiving across multiple vendors.
$rows = @(
    @{ Po='P14MIX-001'; SC='V14-ALPHA'; SN='Vendor Alpha Mix'; SKU='TST-MIX-A1'; Desc='Mixed-vendor line 1'; Qty=10 },
    @{ Po='P14MIX-001'; SC='V14-BETA';  SN='Vendor Beta Mix';  SKU='TST-MIX-B2'; Desc='Mixed-vendor line 2'; Qty=20 },
    @{ Po='P14MIX-001'; SC='V14-GAMMA'; SN='Vendor Gamma Mix'; SKU='TST-MIX-C3'; Desc='Mixed-vendor line 3'; Qty=30 }
)

for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    $row = $sheet.CreateRow($i + 1)
    $row.CreateCell(0).SetCellValue([string]$r.Po)
    $row.CreateCell(1).SetCellValue([string]$r.SC)
    $row.CreateCell(2).SetCellValue([string]$r.SN)
    $row.CreateCell(3).SetCellValue([string]$r.SKU)
    $row.CreateCell(4).SetCellValue([string]$r.Desc)
    $row.CreateCell(5).SetCellValue([double]$r.Qty)
    $row.CreateCell(6).SetCellValue([string]$today)
}

$fixtureDir = Split-Path $out -Parent
if (-not (Test-Path $fixtureDir)) {
    New-Item -ItemType Directory -Path $fixtureDir | Out-Null
}

$fs = New-Object System.IO.FileStream(
    $out, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
try { $wb.Write($fs, $false) } finally { $fs.Dispose() }

$size = (Get-Item $out).Length
Write-Host "Wrote $out ($size bytes)" -ForegroundColor Green
