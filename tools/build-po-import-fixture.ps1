# Generator for the Phase 12.7 integration smoke fixture.
#
# One-shot — produces tools/fixtures/po-import-sample.xlsx using the
# project's own NPOI dlls so the writer/reader path is byte-identical.
# NOT registered in the smoke battery; re-run only when the fixture
# shape needs to change.
#
# Fixture shape:
#   sheet "data"
#   header row covers the 4 required headers + STORER CODE / STORER NAME
#   for vendor mapping + SKU DESCRIPTION + ORDER ID (db/031) + PALLET ID
#   (db/021, uppercase C3=A wins)
#   4 data rows = 2 PoNumbers × 2 lines each, deterministic prefix
#   "P127TEST-" so cleanup is straightforward and collisions impossible
#
# Cell typing decisions:
#   OPEN QTY → Numeric (matches realistic spreadsheets; exercises
#     GetInt's Numeric branch including the int-truncation invariant)
#   DELIVERY DATE → ISO yyyy-MM-dd String (exercises GetDate's String
#     branch via DateTime.TryParse with InvariantCulture; date-formatted
#     Numeric cells require explicit CellStyle work that's needless here)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$bin = Join-Path $repoRoot 'src\ReceivingOps.Web\bin\Debug\net8.0'
$out = Join-Path $repoRoot 'tools\fixtures\po-import-sample.xlsx'

if (-not (Test-Path $bin)) {
    Write-Host "FAIL: build output not found at $bin — run dotnet build first" -ForegroundColor Red
    exit 1
}

# Load NPOI from the project's build output. Add-Type pulls transitives
# implicitly via the same directory; explicit ordering matches the
# dependency chain (Core → OpenXml4Net → OpenXmlFormats → OOXML).
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
    "DELIVERY DATE",
    "ORDER ID",
    "PALLET ID"
)

$hr = $sheet.CreateRow(0)
for ($i = 0; $i -lt $headers.Count; $i++) {
    $hr.CreateCell($i).SetCellValue($headers[$i])
}

$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')

$rows = @(
    @{ Po='P127TEST-001'; SC='VEND-A'; SN='Vendor Alpha'; SKU='TST-WIDGET-001'; Desc='Widget X — phase-12-7 fixture'; Qty=12; OrderId='ORD-A-1'; Pallet='PAL-A-1' },
    @{ Po='P127TEST-001'; SC='VEND-A'; SN='Vendor Alpha'; SKU='TST-WIDGET-002'; Desc='Widget Y';                       Qty=24; OrderId='ORD-A-2'; Pallet='PAL-A-2' },
    @{ Po='P127TEST-002'; SC='VEND-B'; SN='Vendor Beta';  SKU='TST-GIZMO-001';  Desc='Gizmo 1';                        Qty=6;  OrderId='ORD-B-1'; Pallet='PAL-B-1' },
    @{ Po='P127TEST-002'; SC='VEND-B'; SN='Vendor Beta';  SKU='TST-GIZMO-002';  Desc='Gizmo 2';                        Qty=18; OrderId='ORD-B-2'; Pallet='PAL-B-2' }
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
    $row.CreateCell(7).SetCellValue([string]$r.OrderId)
    $row.CreateCell(8).SetCellValue([string]$r.Pallet)
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
