# Smoke: Phase 12.3 — IPoImportLogRepository surface + DB-existence check.
#
# Source-level smoke. Behavioral end-to-end (round-trip a real row through
# the state machine) runs in 12.4 when the orchestrating service lands;
# at that point a smoke can drive the upload endpoint and SELECT the
# PoImportLog row at each transition. 12.3's purpose is to verify:
#
#   1. DTO (PoImportLogRow) is present in Models/Dtos with all 20 cols
#   2. IPoImportLogRepository interface has the 8-method surface
#   3. Repository impl has the 7 SQL paths (insert + 6 mark-* updates)
#   4. None of the UPDATEs touch immutable identity columns
#      (RunId, UploadedBy*, WarehouseId, FileName, FileSizeBytes,
#       StoragePath, SubmittedAt)
#   5. ErrorMessage is truncated in C# (NVARCHAR(MAX) is on the column,
#      but we cap at 4000 to keep the list-view payload bounded)
#   6. Program.cs registers IPoImportLogRepository in DI
#   7. Build is clean
#   8. dbo.PoImportLog exists with the 20 expected columns (sqlcmd probe;
#      SKIPs if no Default connection string is configured)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Skip($m) { Write-Host "SKIP: $m" -ForegroundColor DarkYellow }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function AssertFile([string]$path, [string]$mustContain) {
    if (-not (Test-Path $path)) { Fail "Expected file not found: $path" }
    $body = Get-Content -Raw -LiteralPath $path
    if ($body -notmatch [regex]::Escape($mustContain)) {
        Fail "File $([System.IO.Path]::GetFileName($path)) missing token '$mustContain'"
    }
}

$dtoFile   = Join-Path $webRoot 'Models\Dtos\PoImportLogDtos.cs'
$ifaceFile = Join-Path $webRoot 'Data\Repositories\IPoImportLogRepository.cs'
$implFile  = Join-Path $webRoot 'Data\Repositories\PoImportLogRepository.cs'

# ----------------------------------------------------------------------------
# 1. DTO present with all 20 columns
# ----------------------------------------------------------------------------
Step "PoImportLogRow DTO present with all 20 cols"
AssertFile $dtoFile 'public class PoImportLogRow'
$cols = @(
    'public Guid RunId',
    'public string UploadedBy ',
    'public Guid UploadedByUserId',
    'public string UploadedByRole ',
    'public Guid WarehouseId',
    'public string FileName ',
    'public long FileSizeBytes',
    'public string StoragePath ',
    'public string Status ',
    'public DateTime SubmittedAt',
    'public DateTime? StartedAt',
    'public DateTime? CompletedAt',
    'public int? ElapsedMs',
    'public int? TotalRowsRead',
    'public int? ValidationErrorCount',
    'public string? ValidationErrors',
    'public int? PosInserted',
    'public int? LinesInserted',
    'public string? ErrorMessage',
    'public string? HangfireJobId'
)
foreach ($c in $cols) { AssertFile $dtoFile $c }
OK "All 20 properties on PoImportLogRow"

# ----------------------------------------------------------------------------
# 2. Interface has the full 8-method state-machine surface
# ----------------------------------------------------------------------------
Step "IPoImportLogRepository surface complete"
AssertFile $ifaceFile 'public interface IPoImportLogRepository'
foreach ($m in @(
    'Task InsertSubmittedAsync(',
    'Task MarkValidationFailedAsync(',
    'Task MarkValidatedAsync(',
    'Task MarkQueuedAsync(',
    'Task MarkRunningAsync(',
    'Task MarkSucceededAsync(',
    'Task MarkFailedAsync(',
    'Task<(IReadOnlyList<PoImportLogRow> Items, int Total)> QueryPagedAsync(',
    'Task<PoImportLogRow?> GetByRunIdAsync('
)) {
    AssertFile $ifaceFile $m
}
OK "Interface exposes all 7 mutators + 2 reads"

# ----------------------------------------------------------------------------
# 3. Repository impl has the SQL paths
# ----------------------------------------------------------------------------
Step "Repository SQL paths present"
AssertFile $implFile 'public class PoImportLogRepository : IPoImportLogRepository'
# One INSERT, six state-transition UPDATEs, one paged SELECT, one single-row SELECT
$impl = Get-Content -Raw -LiteralPath $implFile
$insertCount = ([regex]::Matches($impl, 'INSERT INTO dbo\.PoImportLog')).Count
if ($insertCount -ne 1) { Fail "Expected exactly 1 INSERT INTO dbo.PoImportLog, found $insertCount" }
$updateCount = ([regex]::Matches($impl, 'UPDATE dbo\.PoImportLog')).Count
if ($updateCount -ne 6) { Fail "Expected exactly 6 UPDATE dbo.PoImportLog, found $updateCount" }
# Two SELECTs are inside one CommandDefinition for QueryPagedAsync (items + count);
# plus one in GetByRunIdAsync. Count occurrences of FROM dbo.PoImportLog.
$selectCount = ([regex]::Matches($impl, 'FROM\s+dbo\.PoImportLog')).Count
if ($selectCount -lt 3) { Fail "Expected >=3 FROM dbo.PoImportLog occurrences (paged x2 + single), found $selectCount" }
OK "1 INSERT + 6 UPDATEs + $selectCount SELECTs present"

# ----------------------------------------------------------------------------
# 4. UPDATEs must NOT touch immutable identity columns
# ----------------------------------------------------------------------------
Step "No UPDATE touches immutable identity columns"
# Walk each UPDATE block (UPDATE...WHERE RunId = @RunId) and scan its SET clause.
$updateBlocks = [regex]::Matches(
    $impl,
    'UPDATE dbo\.PoImportLog\s+SET([\s\S]+?)WHERE\s+RunId\s*=\s*@RunId')
if ($updateBlocks.Count -ne 6) {
    Fail "Expected 6 UPDATE blocks for immutability check, matched $($updateBlocks.Count)"
}
$forbidden = @(
    'UploadedBy', 'UploadedByUserId', 'UploadedByRole', 'WarehouseId',
    'FileName', 'FileSizeBytes', 'StoragePath', 'SubmittedAt'
)
foreach ($m in $updateBlocks) {
    $setClause = $m.Groups[1].Value
    foreach ($f in $forbidden) {
        # Word-boundary so `Status` doesn't false-positive a hypothetical
        # column whose name embeds these substrings.
        if ($setClause -match "\b$f\s*=") {
            Fail "UPDATE block writes immutable column '$f' in SET clause: $($setClause.Substring(0, [Math]::Min(120, $setClause.Length)))..."
        }
    }
}
OK "No UPDATE writes UploadedBy*/WarehouseId/FileName/FileSizeBytes/StoragePath/SubmittedAt"

# ----------------------------------------------------------------------------
# 5. ErrorMessage truncation
# ----------------------------------------------------------------------------
Step "ErrorMessage truncated in C# (4000-char cap)"
if ($impl -notmatch 'ErrorMessageMaxLength\s*=\s*4000') {
    Fail "ErrorMessageMaxLength constant not set to 4000"
}
if ($impl -notmatch 'errorMessage\.Length\s*>\s*ErrorMessageMaxLength') {
    Fail "Truncation guard not found in MarkFailedAsync"
}
OK "Truncation guard present (4000-char cap)"

# ----------------------------------------------------------------------------
# 6. DI registration in Program.cs
# ----------------------------------------------------------------------------
Step "IPoImportLogRepository registered in DI"
$program = Get-Content -Raw -LiteralPath (Join-Path $webRoot 'Program.cs')
if ($program -notmatch 'AddScoped<IPoImportLogRepository, PoImportLogRepository>') {
    Fail "Program.cs missing AddScoped<IPoImportLogRepository, PoImportLogRepository>()"
}
OK "DI registration present"

# ----------------------------------------------------------------------------
# 7. Build clean
# ----------------------------------------------------------------------------
Step "dotnet build succeeds"
$buildOut = & dotnet build $webRoot --nologo -v quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail "dotnet build failed (exit $LASTEXITCODE). Output: $($buildOut -join "`n")"
}
OK "Build clean (0 errors)"

# ----------------------------------------------------------------------------
# 8. dbo.PoImportLog exists with the 20 columns + 3 indexes
# ----------------------------------------------------------------------------
Step "dbo.PoImportLog exists with 20 cols + 3 indexes"
$secretsList = & dotnet user-secrets list --project (Join-Path $webRoot 'ReceivingOps.Web.csproj') 2>$null
$hasDefault = $secretsList | Where-Object { $_ -match '^ConnectionStrings:Default' }
if (-not $hasDefault) {
    Skip "ConnectionStrings:Default not in user-secrets — DB existence check skipped"
    Write-Host ""
    Write-Host "ALL PASS — Phase 12.3 repo surface verified (DB check skipped — see SKIP above)." -ForegroundColor Green
    exit 0
}
$cs = ($hasDefault -split '=', 2)[1].Trim()
$kv = @{}
foreach ($pair in $cs -split ';') {
    if ($pair -match '^\s*([^=]+)=(.*)$') { $kv[$matches[1].Trim()] = $matches[2].Trim() }
}
$server = $kv['Server']; $db = $kv['Database']
if (-not $server -or -not $db) {
    Skip "Could not parse Server/Database from ConnectionStrings:Default"
    Write-Host ""
    Write-Host "ALL PASS — Phase 12.3 repo surface verified (DB check skipped)." -ForegroundColor Green
    exit 0
}

# Use Integrated Security if no User Id (matches local-dev convention)
$user = $kv['User Id']; $pass = $kv['Password']
$probeQuery = "SET NOCOUNT ON; " +
              "SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PoImportLog'); " +
              "SELECT COUNT(*) FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.PoImportLog') AND name LIKE 'IX_PoImportLog%';"
$sqlArgs = @('-S', $server, '-d', $db, '-C', '-l', '5', '-Q', $probeQuery, '-W', '-h', '-1')
if ($user) { $sqlArgs += @('-U', $user, '-P', $pass) } else { $sqlArgs += @('-E') }
$probeRaw = & sqlcmd @sqlArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail "sqlcmd against dbo.PoImportLog failed (exit $LASTEXITCODE). Output: $($probeRaw -join ' ')"
}
$nums = ($probeRaw | Where-Object { $_ -match '^\s*\d+\s*$' } | ForEach-Object { [int]($_.Trim()) })
if ($nums.Count -lt 2) {
    Fail "sqlcmd response did not return two counts. Raw: $($probeRaw -join ' / ')"
}
if ($nums[0] -ne 20) { Fail "dbo.PoImportLog has $($nums[0]) columns, expected 20" }
if ($nums[1] -ne 3)  { Fail "dbo.PoImportLog has $($nums[1]) IX_PoImportLog* indexes, expected 3" }
OK "dbo.PoImportLog: 20 columns + 3 IX_PoImportLog* indexes confirmed"

Write-Host ""
Write-Host "ALL PASS — Phase 12.3: repo surface + DI + build + DB schema verified." -ForegroundColor Green
exit 0
