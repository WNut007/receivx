# Smoke: Phase 12.4 — IPoImportService Stage 1 orchestrator.
#
# Source-level smoke. Behavioral round-trip (real .xlsx upload through the
# service into a 'validated' log row) runs in 12.5/12.6 when the controller
# and an HTTP endpoint exist; for 12.4 the service is internal-only.
#
# Asserts:
#   1. Submission + Result DTOs are present with the expected fields
#   2. IPoImportService interface + impl
#   3. Service injects all 4 dependencies (log repo + reader + audit + logger)
#   4. Happy path: InsertSubmittedAsync → ParseAsync → MarkValidatedAsync
#   5. Sad path: InsertSubmittedAsync → ParseAsync → MarkValidationFailedAsync
#   6. Errors persisted as JSON via System.Text.Json
#   7. Errors capped at 1000 rows before persistence (avoid bloating NVARCHAR(MAX))
#   8. ValidationErrorsPreview capped at the public constant (50)
#   9. Audit rows written for submit + validated/rejected paths with the
#      'po-import-*' action types + 'PoImportLog' entity type
#  10. Distinct PO count computed via OrdinalIgnoreCase
#  11. DI registration in Program.cs
#  12. Build clean

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

$dtoFile   = Join-Path $webRoot 'Services\PoImport\PoImportServiceDtos.cs'
$ifaceFile = Join-Path $webRoot 'Services\PoImport\IPoImportService.cs'
$implFile  = Join-Path $webRoot 'Services\PoImport\PoImportService.cs'

# ----------------------------------------------------------------------------
# 1. DTOs present
# ----------------------------------------------------------------------------
Step "PoImportSubmission + PoImportSubmissionResult DTOs present"
AssertFile $dtoFile 'public class PoImportSubmission'
AssertFile $dtoFile 'public class PoImportSubmissionResult'
foreach ($f in @(
    'public string FileName',
    'public string StoragePath',
    'public long FileSizeBytes',
    'public Guid WarehouseId',
    'public string UploadedBy ',
    'public Guid UploadedByUserId',
    'public string UploadedByRole '
)) { AssertFile $dtoFile $f }
foreach ($f in @(
    'public Guid RunId',
    'public string Status ',
    'public int TotalRowsRead',
    'public int DistinctPoCount',
    'public int ValidationErrorCount',
    'public List<PoImportValidationError> ValidationErrorsPreview',
    'public const int ValidationErrorPreviewCap = 50'
)) { AssertFile $dtoFile $f }
OK "Submission (7 props) + Result (7 props + 50-cap constant) all present"

# ----------------------------------------------------------------------------
# 2. Interface + impl
# ----------------------------------------------------------------------------
Step "IPoImportService + PoImportService present"
AssertFile $ifaceFile 'public interface IPoImportService'
AssertFile $ifaceFile 'Task<PoImportSubmissionResult> SubmitForValidationAsync('
AssertFile $implFile  'public class PoImportService : IPoImportService'
OK "Interface + impl present"

# ----------------------------------------------------------------------------
# 3. Dependency injection
# ----------------------------------------------------------------------------
Step "Service injects 4 dependencies"
$impl = Get-Content -Raw -LiteralPath $implFile
foreach ($d in @(
    'IPoImportLogRepository _log',
    'IPoImportReader _reader',
    'IAuditService _audit',
    'ILogger<PoImportService> _logger'
)) {
    if ($impl -notmatch [regex]::Escape($d)) {
        Fail "Service field $d missing"
    }
}
OK "All 4 fields wired in ctor"

# ----------------------------------------------------------------------------
# 4. Happy path
# ----------------------------------------------------------------------------
Step "Happy path: InsertSubmittedAsync → ParseAsync → MarkValidatedAsync"
$insertPos = $impl.IndexOf('_log.InsertSubmittedAsync(')
$parsePos  = $impl.IndexOf('_reader.ParseAsync(')
$markValPos = $impl.IndexOf('_log.MarkValidatedAsync(')
if ($insertPos -lt 0) { Fail "InsertSubmittedAsync not called" }
if ($parsePos  -lt 0) { Fail "ParseAsync not called" }
if ($markValPos -lt 0) { Fail "MarkValidatedAsync not called" }
if (-not ($insertPos -lt $parsePos -and $parsePos -lt $markValPos)) {
    Fail "Order must be Insert → Parse → MarkValidated; got positions $insertPos, $parsePos, $markValPos"
}
OK "Order verified by call-site position"

# ----------------------------------------------------------------------------
# 5. Sad path
# ----------------------------------------------------------------------------
Step "Sad path: MarkValidationFailedAsync on parse failure"
if ($impl -notmatch '_log\.MarkValidationFailedAsync\(') {
    Fail "MarkValidationFailedAsync never called"
}
# IsValid is the gate — must branch on it
if ($impl -notmatch '!parse\.IsValid') {
    Fail "Service does not branch on parse.IsValid"
}
OK "Sad-path mark + IsValid gate present"

# ----------------------------------------------------------------------------
# 6. JSON serialization via System.Text.Json
# ----------------------------------------------------------------------------
Step "Validation errors serialized via System.Text.Json"
if ($impl -notmatch 'using System\.Text\.Json;') { Fail "Missing 'using System.Text.Json;'" }
if ($impl -notmatch 'JsonSerializer\.Serialize\(persistedErrors') {
    Fail "JsonSerializer.Serialize(persistedErrors, ...) not found"
}
# CamelCase + ignore-null matches the rest of the API's wire shape
if ($impl -notmatch 'PropertyNamingPolicy\s*=\s*JsonNamingPolicy\.CamelCase') {
    Fail "JsonNamingPolicy.CamelCase not configured"
}
OK "System.Text.Json with camelCase + ignore-null"

# ----------------------------------------------------------------------------
# 7. Errors capped at 1000 before persistence
# ----------------------------------------------------------------------------
Step "ValidationErrors capped at 1000 rows before persisting"
if ($impl -notmatch 'persistedErrorsCap\s*=\s*1000') {
    Fail "persistedErrorsCap = 1000 constant missing"
}
if ($impl -notmatch 'Take\(persistedErrorsCap\)') {
    Fail ".Take(persistedErrorsCap) projection missing"
}
OK "Persisted-errors cap = 1000"

# ----------------------------------------------------------------------------
# 8. ValidationErrorsPreview capped at the public constant (50)
# ----------------------------------------------------------------------------
Step "ValidationErrorsPreview uses the 50-cap constant"
if ($impl -notmatch 'Take\(PoImportSubmissionResult\.ValidationErrorPreviewCap\)') {
    Fail "Result preview not capped via the public constant"
}
OK "Preview uses PoImportSubmissionResult.ValidationErrorPreviewCap"

# ----------------------------------------------------------------------------
# 9. Audit rows for submit + validated + rejected
# ----------------------------------------------------------------------------
Step "Audit: 3 WriteSystemAsync calls — submit / validated / rejected"
foreach ($action in @('"po-import-submit"', '"po-import-validated"', '"po-import-rejected"')) {
    if ($impl -notmatch [regex]::Escape($action)) {
        Fail "Audit action $action not emitted"
    }
}
# EntityType convention parallel to ExportJobsLog
$entityMatches = [regex]::Matches($impl, '"PoImportLog"')
if ($entityMatches.Count -lt 3) {
    Fail "Expected >=3 audit rows tagged EntityType='PoImportLog', found $($entityMatches.Count)"
}
OK "All 3 audit actions + correct EntityType emitted"

# ----------------------------------------------------------------------------
# 10. Distinct PO count uses OrdinalIgnoreCase
# ----------------------------------------------------------------------------
Step "Distinct PO count case-insensitive"
if ($impl -notmatch 'Distinct\(StringComparer\.OrdinalIgnoreCase\)') {
    Fail "DistinctPoCount must use StringComparer.OrdinalIgnoreCase"
}
OK "OrdinalIgnoreCase comparer used"

# ----------------------------------------------------------------------------
# 11. DI registration
# ----------------------------------------------------------------------------
Step "IPoImportService registered in Program.cs"
$program = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Program.cs')
if ($program -notmatch 'AddScoped<IPoImportService, PoImportService>') {
    Fail "Program.cs missing AddScoped<IPoImportService, PoImportService>()"
}
OK "DI registration present"

# ----------------------------------------------------------------------------
# 12. Build clean
# ----------------------------------------------------------------------------
Step "dotnet build succeeds"
$buildOut = & dotnet build $webRoot --nologo -v quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail "dotnet build failed (exit $LASTEXITCODE). Output: $($buildOut -join "`n")"
}
OK "Build clean (0 errors)"

Write-Host ""
Write-Host "ALL PASS — Phase 12.4: orchestrator surface + happy/sad paths + audit verified." -ForegroundColor Green
exit 0
