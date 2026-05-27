# Smoke: Phase 12.2 — PO Excel import parser (IPoImportReader).
#
# Source-level + structural. Asserts:
#   1. Parser interface + impl + DTOs are present in Services/PoImport
#   2. NPOI 2.7.2 NuGet reference is wired in the .csproj
#   3. IPoImportReader is registered in Program.cs (DI)
#   4. Migrations 030 (PoImportLog) + 031 (OrderId column) are present
#   5. PoImportRow fields match the spec — covers the four header-conflict
#      decisions (C1=A PoNumber, C2=C OrderId+AsnNo both, C3=A PALLET ID
#      uppercase, C4=A DELIVERY DATE wins)
#   6. PoImportReader uses both HSSF (xls) + XSSF (xlsx) workbook types
#   7. Required-header gate covers PoNumber/SKU/OPEN QTY/DELIVERY DATE
#   8. Per-row validation rejects qty<=0 and missing required fields
#   9. Project compiles cleanly with NPOI referenced
#
# Behavioral end-to-end (parse a real .xlsx, persist via repository, run job)
# lands in 12.3+ when the repository + controller exist.

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

# ----------------------------------------------------------------------------
# 1. Parser surface present
# ----------------------------------------------------------------------------
Step "Parser interface + impl + DTOs present"
$ifaceFile = Join-Path $webRoot 'Services\PoImport\IPoImportReader.cs'
$implFile  = Join-Path $webRoot 'Services\PoImport\PoImportReader.cs'
$dtoFile   = Join-Path $webRoot 'Services\PoImport\PoImportDtos.cs'
AssertFile $ifaceFile 'public interface IPoImportReader'
AssertFile $ifaceFile 'Task<PoImportParseResult> ParseAsync'
AssertFile $implFile  'public class PoImportReader : IPoImportReader'
AssertFile $dtoFile   'public class PoImportParseResult'
AssertFile $dtoFile   'public class PoImportRow'
AssertFile $dtoFile   'public class PoImportValidationError'
OK "IPoImportReader + PoImportReader + 3 DTOs all present"

# ----------------------------------------------------------------------------
# 2. NPOI NuGet reference wired
# ----------------------------------------------------------------------------
Step "NPOI 2.7.2 referenced in .csproj"
$csproj = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'ReceivingOps.Web.csproj')
if ($csproj -notmatch 'PackageReference Include="NPOI" Version="2\.7\.2"') {
    Fail "NPOI 2.7.2 PackageReference missing from ReceivingOps.Web.csproj"
}
OK "NPOI 2.7.2 reference present"

# ----------------------------------------------------------------------------
# 3. DI registration in Program.cs
# ----------------------------------------------------------------------------
Step "PoImportReader registered in DI"
$program = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Program.cs')
if ($program -notmatch 'using ReceivingOps\.Web\.Services\.PoImport;') {
    Fail "Program.cs missing 'using ReceivingOps.Web.Services.PoImport;'"
}
if ($program -notmatch 'AddScoped<IPoImportReader, PoImportReader>') {
    Fail "Program.cs missing AddScoped<IPoImportReader, PoImportReader>()"
}
OK "DI registration present"

# ----------------------------------------------------------------------------
# 4. Phase 12.1 migrations present
# ----------------------------------------------------------------------------
Step "Migrations db/030 (PoImportLog) + db/031 (OrderId) present"
$mig030 = Join-Path $repoRoot 'db\030_po_import_log.sql'
$mig031 = Join-Path $repoRoot 'db\031_purchase_order_lines_order_id.sql'
AssertFile $mig030 'CREATE TABLE dbo.PoImportLog'
AssertFile $mig030 'IX_PoImportLog_SubmittedAt'
AssertFile $mig031 'PurchaseOrderLines'
AssertFile $mig031 'OrderId'
OK "Both migrations on disk with expected DDL"

# ----------------------------------------------------------------------------
# 5. PoImportRow fields match the spec — covers the four conflict decisions
# ----------------------------------------------------------------------------
Step "PoImportRow fields cover C1..C4 conflict resolutions"
# C1=A — PoNumber sourced from "PULL SHEET ID / PRS NO" (NOT a generic "PO" column).
AssertFile $implFile '"PULL SHEET ID / PRS NO"'
# C2=C — OrderId AND AsnNo both kept on the row + read from sheet
AssertFile $dtoFile 'public string? OrderId'
AssertFile $dtoFile 'public string? AsnNo'
AssertFile $implFile '"ORDER ID"'
AssertFile $implFile '"ASN NO"'
# C3=A — PALLET ID (uppercase wins). Header normalization upper-cases both
# variants so they collide on the same key; later-wins semantics in the
# header-map loop ensures the rightmost (uppercase) column wins.
AssertFile $implFile '"PALLET ID"'
AssertFile $implFile 'ToUpperInvariant'
# C4=A — DELIVERY DATE wins for the date field (ORDER DATE is ignored)
AssertFile $implFile '"DELIVERY DATE"'
# Check call-site usage (mapper-cell readers take the header as 3rd arg);
# doc-comment references to "ORDER DATE" are fine.
$implBody = Get-Content -Raw -LiteralPath $implFile
if ($implBody -match 'Get\w+\(row, map, "ORDER DATE"\)') {
    Fail "PoImportReader call-site reads 'ORDER DATE' — per C4=A only DELIVERY DATE should be read"
}
OK "C1..C4 conflict resolutions encoded in mapper"

# ----------------------------------------------------------------------------
# 6. Both .xls (HSSF) + .xlsx (XSSF) workbooks supported
# ----------------------------------------------------------------------------
Step "Both .xls + .xlsx workbook types supported"
AssertFile $implFile 'HSSFWorkbook'
AssertFile $implFile 'XSSFWorkbook'
AssertFile $implFile '.xls'
AssertFile $implFile '.xlsx'
OK "HSSF + XSSF workbook constructors both present"

# ----------------------------------------------------------------------------
# 7. Required-header gate covers the four spec-required columns
# ----------------------------------------------------------------------------
Step "Required-header gate covers PoNumber / SKU / OPEN QTY / DELIVERY DATE"
$impl = Get-Content -Raw -LiteralPath $implFile
foreach ($h in @('"PULL SHEET ID / PRS NO"','"SKU"','"OPEN QTY"','"DELIVERY DATE"')) {
    if ($impl -notmatch [regex]::Escape($h)) {
        Fail "Required header literal $h missing from PoImportReader"
    }
}
# The RequiredHeaders array (not just the mapper call sites) is the gate.
if ($impl -notmatch 'RequiredHeaders') {
    Fail "PoImportReader has no RequiredHeaders constant"
}
if ($impl -notmatch 'Required column missing') {
    Fail "Required-header validator error message not found"
}
OK "All four required-header literals + the gate logic present"

# ----------------------------------------------------------------------------
# 8. Per-row validation rejects qty<=0 + missing required fields
# ----------------------------------------------------------------------------
Step "Per-row validation: qty<=0 + missing-required guards"
# OrderedQty > 0 enforcement
if ($impl -notmatch 'OrderedQty <= 0') {
    Fail "OrderedQty <= 0 guard not found"
}
# Missing-required generates a 'Required' message
if ($impl -notmatch '"Required"') {
    Fail "Missing-required field message not found"
}
# DeliveryDate must parse
if ($impl -notmatch 'Invalid or missing date') {
    Fail "DeliveryDate validation message not found"
}
OK "Row-level validation present (qty + required + date)"

# ----------------------------------------------------------------------------
# 8b. DELIVERY DATE format list — dd/MM/yyyy is the production source format
# ----------------------------------------------------------------------------
# A regression here would mean someone "simplified" the GetDate String branch
# back to liberal DateTime.TryParse(InvariantCulture), which mis-reads
# dd/MM/yyyy as either MM/dd/yyyy (silent corruption) or refuses 25/05/2026
# outright (silent data loss). The format list is the single most load-bearing
# string in the parser for source-data correctness — guard it here.
Step "GetDate parses dd/MM/yyyy + d/M/yyyy (production format) + yyyy-MM-dd"
if ($impl -notmatch 'TryParseExact') {
    Fail "GetDate must use TryParseExact with an explicit format list (TryParse is ambiguous on dd/MM/yyyy)"
}
foreach ($fmt in @('"dd/MM/yyyy"', '"d/M/yyyy"', '"yyyy-MM-dd"')) {
    if ($impl -notmatch [regex]::Escape($fmt)) {
        Fail "Date format slot missing from GetDate: $fmt"
    }
}
OK "TryParseExact + dd/MM/yyyy + d/M/yyyy + yyyy-MM-dd all present"

# ----------------------------------------------------------------------------
# 9. Project compiles cleanly with NPOI referenced
# ----------------------------------------------------------------------------
Step "dotnet build succeeds"
$buildOut = & dotnet build $webRoot --nologo -v quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail "dotnet build failed (exit $LASTEXITCODE). Output: $($buildOut -join "`n")"
}
$errLines = $buildOut | Where-Object { $_ -match 'error\s+CS\d+:' }
if ($errLines) {
    Fail "Compiler errors: $($errLines -join "; ")"
}
OK "Build clean (0 errors)"

Write-Host ""
Write-Host "ALL PASS — Phase 12.2: parser surface + DI + migrations + build verified." -ForegroundColor Green
exit 0
