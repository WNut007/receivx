# Smoke test: Phase 7.2 — FastReport.OpenSource bootstrap.
#
# Bootstrap-only — confirms the packages, config, and DI/middleware all
# wire without breaking existing surfaces. No report rendering yet —
# that lands with the DO controller + .frx template in Phase 7.3+.
#
# 6 checks:
#   1. .csproj has FastReport.OpenSource + FastReport.OpenSource.Web pinned.
#   2. CompanyInfo.cs POCO exists with the expected 5 fields.
#   3. appsettings.json has the "CompanyInfo" section with placeholders.
#   4. Program.cs registers Configure<CompanyInfo> + AddFastReport() + UseFastReport().
#   5. Server starts cleanly (no startup exception) — proves the DI graph + binding both resolve.
#   6. GET /Dashboard still 200 — regression check that adding the middleware didn't break routing.
#
# Assumes ReceivingOps.Web running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# ----------------------------------------------------------------------------
# 1. .csproj — both packages pinned
# ----------------------------------------------------------------------------
Step "ReceivingOps.Web.csproj has both FastReport.OpenSource packages"
$csproj = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\ReceivingOps.Web.csproj' -Raw
if ($csproj -notmatch 'FastReport\.OpenSource"\s+Version=') { Fail ".csproj missing FastReport.OpenSource PackageReference" }
if ($csproj -notmatch 'FastReport\.OpenSource\.Web"\s+Version=') { Fail ".csproj missing FastReport.OpenSource.Web PackageReference" }
# Guard against the demo/trial package sneaking in
if ($csproj -match 'FastReport\.Core3\.Web\.Demo|FastReport\.Net\.Demo|FastReport\.Web"\s') {
    Fail ".csproj references a non-OpenSource FastReport package — license risk (see Phase 7.0 investigation)"
}
OK "Both OS packages present + no demo/trial package reference"

# ----------------------------------------------------------------------------
# 2. CompanyInfo POCO
# ----------------------------------------------------------------------------
Step "CompanyInfo.cs exists with Name / Address / Phone / TaxId / LogoPath"
$pocoPath = 'C:\dev\receivx\src\ReceivingOps.Web\Models\CompanyInfo.cs'
if (-not (Test-Path $pocoPath)) { Fail "Models/CompanyInfo.cs missing" }
$poco = Get-Content $pocoPath -Raw
foreach ($prop in @('Name', 'Address', 'Phone', 'TaxId', 'LogoPath')) {
    if ($poco -notmatch "public string $prop") { Fail "CompanyInfo POCO missing $prop property" }
}
OK "POCO has all 5 properties"

# ----------------------------------------------------------------------------
# 3. appsettings.json — CompanyInfo section
# ----------------------------------------------------------------------------
Step "appsettings.json carries CompanyInfo section"
$settings = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\appsettings.json' -Raw | ConvertFrom-Json
if (-not $settings.CompanyInfo)              { Fail "appsettings.json missing CompanyInfo section" }
if (-not $settings.CompanyInfo.Name)         { Fail "CompanyInfo.Name not set" }
if (-not $settings.CompanyInfo.LogoPath)     { Fail "CompanyInfo.LogoPath not set" }
OK "CompanyInfo section bound (Name='$($settings.CompanyInfo.Name)', LogoPath='$($settings.CompanyInfo.LogoPath)')"

# ----------------------------------------------------------------------------
# 4. Program.cs — DI + middleware
# ----------------------------------------------------------------------------
Step "Program.cs registers Configure<CompanyInfo> + AddFastReport() + UseFastReport()"
$prog = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Program.cs' -Raw
if ($prog -notmatch 'Configure<CompanyInfo>')  { Fail "Program.cs missing Configure<CompanyInfo> binding" }
if ($prog -notmatch 'AddFastReport\(\)')       { Fail "Program.cs missing builder.Services.AddFastReport()" }
if ($prog -notmatch 'UseFastReport\(\)')       { Fail "Program.cs missing app.UseFastReport() middleware" }
if ($prog -notmatch 'using FastReport\.Web;')  { Fail "Program.cs missing using FastReport.Web" }
OK "DI + middleware + using all in place"

# ----------------------------------------------------------------------------
# 5. Server is running (startup didn't crash)
# ----------------------------------------------------------------------------
Step "Dev server is up at $base (startup didn't throw)"
$health = $null
try {
    $health = Invoke-WebRequest -Uri "$base/Account/Login" -Method GET -UseBasicParsing -TimeoutSec 10
} catch {
    Fail "Server not reachable at $base — check dev-server.log for startup exception"
}
if ($health.StatusCode -ne 200) { Fail "Login page returned $($health.StatusCode)" }
OK "Server up, Login page 200"

# ----------------------------------------------------------------------------
# 6. Regression — /Dashboard still 200 after middleware change
# ----------------------------------------------------------------------------
Step "GET /Dashboard 200 (regression check)"
$body = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
$page = Invoke-WebRequest -Uri "$base/Dashboard" -Method GET -WebSession $sv -UseBasicParsing
if ($page.StatusCode -ne 200) { Fail "Dashboard returned $($page.StatusCode) — FastReport middleware may have broken routing" }
OK "Dashboard 200 — middleware didn't break routing"

Write-Host ""
Write-Host "ALL PASS — FastReport.OpenSource bootstrap wired (no reports yet — that's Phase 7.3)." -ForegroundColor Green
exit 0
