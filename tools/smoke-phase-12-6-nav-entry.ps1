# Smoke: Phase 12.6 — /Imports nav entry + page route + permission boundary.
#
# Closes the discoverability-gap pattern that bit Phase 10.6 + Phase 11.2:
# nav-driven features that shipped without programmatic nav verification.
#
# The sidebar is JS-injected by app-nav.js — raw HTML returned by Invoke-
# WebRequest does NOT contain the rendered nav DOM. So nav-presence and
# role-filter assertions are source-level (against app-nav.js MENU), while
# page-route + page-active-marker assertions are behavioral.
#
# Asserts:
#   1. app-nav.js MENU has an 'imports' entry between receiving and transactions
#   2. MENU entry has icon bi-cloud-upload + no `roles` gate (visible to all)
#   3. activePage detection includes '/imports' → 'imports'
#   4. Existing 9 nav entries still present (regression guard)
#   5. ImportsController.cs has [Authorize] + [HttpGet("/Imports")] + PageId=imports
#   6. Views/Imports/Index.cshtml has body data-app-page="imports"
#   7. Dev server reachable on http://localhost:5213
#   8. /Imports renders 200 for admin (sadmin)
#   9. /Imports renders 200 for supervisor (swattana)
#  10. /Imports renders 200 for operator (npatcharin) — per Q4=A all roles
#  11. /Imports redirects unauthenticated → /Account/Login
#  12. Existing /Config admin reveal still works (Phase 11.2 regression guard)

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_03 = '22222222-2222-2222-2222-000000000003'

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

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

$navFile  = Join-Path $webRoot 'wwwroot\js\app-nav.js'
$ctrlFile = Join-Path $webRoot 'Controllers\ImportsController.cs'
$viewFile = Join-Path $webRoot 'Views\Imports\Index.cshtml'

# ----------------------------------------------------------------------------
# 1. MENU positioning: imports between receiving and transactions
# ----------------------------------------------------------------------------
Step "MENU entry sits between receiving and transactions"
$nav = Get-Content -Raw -LiteralPath $navFile
# Multiline regex matching the three consecutive entries.
$navOrder = "id:\s*'receiving'[\s\S]+?id:\s*'imports'[\s\S]+?id:\s*'transactions'"
if ($nav -notmatch $navOrder) {
    Fail "MENU array missing imports entry positioned between receiving and transactions"
}
OK "imports entry sits between receiving and transactions"

# ----------------------------------------------------------------------------
# 2. Icon + no `roles` gate
# ----------------------------------------------------------------------------
Step "Entry uses bi-cloud-upload and is NOT role-gated"
# Capture the imports MENU line and inspect it.
$importsLineRegex = "\{\s*id:\s*'imports'[^}]*\}"
$importsLineMatch = [regex]::Match($nav, $importsLineRegex)
if (-not $importsLineMatch.Success) { Fail "Could not isolate imports MENU entry" }
$importsLine = $importsLineMatch.Value
if ($importsLine -notmatch "icon:\s*'bi-cloud-upload'") {
    Fail "imports entry missing bi-cloud-upload icon"
}
if ($importsLine -match 'roles\s*:') {
    Fail "imports entry must NOT carry a `roles` filter (per Q4=A all roles see it)"
}
if ($importsLine -notmatch "href:\s*'/Imports'") {
    Fail "imports entry must href to /Imports"
}
OK "icon, href and no-roles gate all correct"

# ----------------------------------------------------------------------------
# 3. activePage detection
# ----------------------------------------------------------------------------
Step "activePage detection recognises /imports"
if ($nav -notmatch "p\.includes\('/imports'\)\s*\)\s*return\s+'imports'") {
    Fail "activePage block missing the /imports → 'imports' rule"
}
OK "activePage detection wired"

# ----------------------------------------------------------------------------
# 4. Regression guard: existing 9 nav entries still present
# ----------------------------------------------------------------------------
Step "Existing 9 nav entries still present"
foreach ($id in @('pull','pos','receiving','transactions','reports','exports','masters','admin-erp-sync','config')) {
    if ($nav -notmatch "id:\s*'$id'") {
        Fail "MENU entry id='$id' was removed or renamed — regression"
    }
}
OK "All 9 pre-existing nav entries intact"

# ----------------------------------------------------------------------------
# 5. ImportsController.cs shape
# ----------------------------------------------------------------------------
Step "ImportsController.cs is [Authorize] (not role-gated) + HttpGet /Imports + PageId"
AssertFile $ctrlFile 'public class ImportsController : Controller'
# [Authorize] only — no Roles= restriction. Operators are allowed to land on
# the page; the API surface enforces admin,supervisor separately.
$ctrl = Get-Content -Raw -LiteralPath $ctrlFile
if ($ctrl -notmatch '\[Authorize\]') { Fail "Missing bare [Authorize] attribute" }
if ($ctrl -match '\[Authorize\(Roles\s*=') { Fail "Controller must NOT carry [Authorize(Roles=...)] per Q4=A" }
AssertFile $ctrlFile '[HttpGet("/Imports")]'
AssertFile $ctrlFile 'ViewData["PageId"] = "imports"'
OK "Controller shape correct"

# ----------------------------------------------------------------------------
# 6. View body marker
# ----------------------------------------------------------------------------
Step "Views/Imports/Index.cshtml has data-app-page=imports"
AssertFile $viewFile 'data-app-page="imports"'
OK "View marker present"

# ----------------------------------------------------------------------------
# 7. Dev server reachable
# ----------------------------------------------------------------------------
Step "Dev server reachable on $base"
try {
    $probe = Invoke-WebRequest -Uri "$base/Account/Login" -Method GET -MaximumRedirection 0 -ErrorAction Stop
    if ($probe.StatusCode -ne 200) { Fail "Dev server probe got HTTP $($probe.StatusCode), expected 200" }
} catch {
    $sc = $_.Exception.Response.StatusCode.value__
    if ($sc -ne 200) { Fail "Dev server probe got HTTP $sc, expected 200" }
}
OK "Dev server reachable"

# ----------------------------------------------------------------------------
# 8-10. /Imports renders 200 for admin, supervisor, operator
# ----------------------------------------------------------------------------
Step "/Imports renders 200 for admin (sadmin)"
$adminSv = Login 'sadmin' 'admin' $WH_01
$adminPage = Invoke-WebRequest -Uri "$base/Imports" -WebSession $adminSv -MaximumRedirection 0
if ($adminPage.StatusCode -ne 200) { Fail "admin GET /Imports → $($adminPage.StatusCode), expected 200" }
if ($adminPage.Content -notmatch 'data-app-page="imports"') {
    Fail "admin /Imports response missing data-app-page=imports body marker"
}
OK "admin lands on /Imports with imports active marker"

Step "/Imports renders 200 for supervisor (swattana @ WH-01)"
$supSv = Login 'swattana' 'demo1234' $WH_01
$supPage = Invoke-WebRequest -Uri "$base/Imports" -WebSession $supSv -MaximumRedirection 0
if ($supPage.StatusCode -ne 200) { Fail "supervisor GET /Imports → $($supPage.StatusCode), expected 200" }
OK "supervisor lands on /Imports"

Step "/Imports renders 200 for operator (npatcharin @ WH-03) per Q4=A"
$opSv = Login 'npatcharin' 'demo1234' $WH_03
$opPage = Invoke-WebRequest -Uri "$base/Imports" -WebSession $opSv -MaximumRedirection 0
if ($opPage.StatusCode -ne 200) { Fail "operator GET /Imports → $($opPage.StatusCode), expected 200" }
OK "operator lands on /Imports — discoverable per Q4=A"

# ----------------------------------------------------------------------------
# 11. Anonymous → redirect to login
# ----------------------------------------------------------------------------
Step "/Imports redirects unauthenticated → /Account/Login"
try {
    $anon = Invoke-WebRequest -Uri "$base/Imports" -Method GET -MaximumRedirection 0 -ErrorAction Stop
    Fail "Anonymous GET /Imports unexpectedly returned $($anon.StatusCode) with no redirect"
} catch {
    $sc = $_.Exception.Response.StatusCode.value__
    if ($sc -ne 302) { Fail "Anonymous GET /Imports → HTTP $sc, expected 302 redirect" }
    $loc = $_.Exception.Response.Headers.Location
    if ($loc -notmatch '/Account/Login') {
        Fail "Anonymous /Imports redirect target '$loc' did not point at /Account/Login"
    }
}
OK "Anonymous bounces to /Account/Login"

# ----------------------------------------------------------------------------
# 12. Phase 11.2 regression — /Config still reachable for admin
# ----------------------------------------------------------------------------
Step "Phase 11.2 regression — /Config still 200 for admin"
$cfgPage = Invoke-WebRequest -Uri "$base/Config" -WebSession $adminSv -MaximumRedirection 0
if ($cfgPage.StatusCode -ne 200) { Fail "admin GET /Config → $($cfgPage.StatusCode), expected 200" }
OK "/Config admin route still works"

Write-Host ""
Write-Host "ALL PASS — Phase 12.6: /Imports nav entry + page route + permission boundary verified." -ForegroundColor Green
exit 0
