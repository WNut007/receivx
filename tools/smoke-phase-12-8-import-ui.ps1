# Smoke: Phase 12.8 — /Imports upload UI (dropzone + preview + status).
#
# 12.6 wired the nav + a placeholder page. 12.7 wired the integration smoke
# that proves the API pipeline end-to-end. 12.8 replaces the placeholder
# view with a real uploader and verifies the role-gated render + JS hooks
# survive a refactor.
#
# Architecture: server-side gate (ViewData["CanUpload"] = User.IsInRole
# admin OR supervisor). When CanUpload is true the view renders dropzone
# + preview/status panels + a <script src="/js/imports.js"> tag.
# Otherwise it renders an operator notice and OMITS the script.
# This is the cleanest test surface — no JS reveal logic to chase, and
# the HTML returned to each role is unambiguously different.
#
# Asserts:
#   1. imports.js exists with dropzone + confirm + polling hooks
#   2. imports.css exists with .imports-dropzone style
#   3. ImportsController sets ViewData["CanUpload"] from role check
#   4. Index.cshtml has both branches (@if (canUpload) gate)
#   5. Dev server reachable
#   6. Admin (sadmin) GET /Imports → 200, contains dropzone DOM hooks,
#      script tag for /js/imports.js, NO operator-notice block
#   7. Supervisor (swattana @ WH-01) GET /Imports → 200, same shape as admin
#   8. Operator (npatcharin @ WH-03) GET /Imports → 200, contains
#      operator-notice block, NO dropzone hooks, NO imports.js script
#   9. /api/imports/po/upload still rejects operator with 403
#      (regression guard — the UI gate is convenience; API is authoritative)
#  10. imports.js is statically served (HEAD /js/imports.js → 200)
#  11. imports.css is statically served (HEAD /css/imports.css → 200)

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

$jsFile    = Join-Path $webRoot 'wwwroot\js\imports.js'
$cssFile   = Join-Path $webRoot 'wwwroot\css\imports.css'
$ctrlFile  = Join-Path $webRoot 'Controllers\ImportsController.cs'
$viewFile  = Join-Path $webRoot 'Views\Imports\Index.cshtml'

# ----------------------------------------------------------------------------
# 1. imports.js exists with key handlers
# ----------------------------------------------------------------------------
Step "imports.js exists with dropzone + confirm + polling hooks"
AssertFile $jsFile "getElementById('imports-dropzone')"
AssertFile $jsFile "getElementById('imports-confirm-btn')"
AssertFile $jsFile "fetch('/api/imports/po/upload'"
AssertFile $jsFile "'/api/imports/po/' + currentRunId + '/confirm'"
AssertFile $jsFile "'/api/imports/po/' + runId"
AssertFile $jsFile "pollUntilTerminal"
AssertFile $jsFile "MAX_SIZE_BYTES  = 50 * 1024 * 1024"
OK "JS file has all required hooks"

# ----------------------------------------------------------------------------
# 2. imports.css exists with dropzone style
# ----------------------------------------------------------------------------
Step "imports.css exists with .imports-dropzone"
AssertFile $cssFile ".imports-dropzone"
AssertFile $cssFile ".imports-dropzone.drag-over"
AssertFile $cssFile ".imports-status-final.succeeded"
OK "CSS file has dropzone + drag-over + terminal status styles"

# ----------------------------------------------------------------------------
# 3. ImportsController gates via ViewData["CanUpload"]
# ----------------------------------------------------------------------------
Step "ImportsController.cs computes CanUpload from role"
AssertFile $ctrlFile 'ViewData["CanUpload"]'
AssertFile $ctrlFile 'User.IsInRole("admin") || User.IsInRole("supervisor")'
OK "Controller role check present"

# ----------------------------------------------------------------------------
# 4. Index.cshtml has both branches
# ----------------------------------------------------------------------------
Step "Views/Imports/Index.cshtml has @if (canUpload) ... else block"
$view = Get-Content -Raw -LiteralPath $viewFile
if ($view -notmatch '@if \(canUpload\)')           { Fail "View missing @if (canUpload) gate" }
if ($view -notmatch 'imports-dropzone')            { Fail "View missing dropzone block" }
if ($view -notmatch 'imports-operator-notice')     { Fail "View missing operator-notice block" }
if ($view -notmatch 'data-app-page="imports"')     { Fail "View missing body marker" }
OK "View has both branches + body marker"

# ----------------------------------------------------------------------------
# 5. Dev server reachable
# ----------------------------------------------------------------------------
Step "Dev server reachable on $base"
try {
    $probe = Invoke-WebRequest -Uri "$base/Account/Login" -Method GET -MaximumRedirection 0 -ErrorAction Stop
    if ($probe.StatusCode -ne 200) { Fail "Dev server probe got HTTP $($probe.StatusCode)" }
} catch {
    Fail "Dev server probe failed: $($_.Exception.Message)"
}
OK "Dev server reachable"

# ----------------------------------------------------------------------------
# 6. Admin GET /Imports — dropzone + script tag, no operator notice
# ----------------------------------------------------------------------------
Step "Admin (sadmin) GET /Imports renders uploader UI"
$adminSv = Login 'sadmin' 'admin' $WH_01
$adminResp = Invoke-WebRequest -Uri "$base/Imports" -WebSession $adminSv -MaximumRedirection 0
if ($adminResp.StatusCode -ne 200) { Fail "admin GET /Imports → $($adminResp.StatusCode)" }
$ah = $adminResp.Content
if ($ah -notmatch 'id="imports-dropzone"')        { Fail "admin render missing dropzone DOM" }
if ($ah -notmatch 'id="imports-confirm-btn"')     { Fail "admin render missing confirm button" }
if ($ah -notmatch '/js/imports\.js')              { Fail "admin render missing imports.js script tag" }
if ($ah -match    'imports-operator-notice')      { Fail "admin render leaks operator-notice block" }
OK "Admin sees dropzone + script + no operator notice"

# ----------------------------------------------------------------------------
# 7. Supervisor GET /Imports — same shape as admin
# ----------------------------------------------------------------------------
Step "Supervisor (swattana @ WH-01) GET /Imports renders uploader UI"
$supSv = Login 'swattana' 'demo1234' $WH_01
$supResp = Invoke-WebRequest -Uri "$base/Imports" -WebSession $supSv -MaximumRedirection 0
if ($supResp.StatusCode -ne 200) { Fail "supervisor GET /Imports → $($supResp.StatusCode)" }
$sh = $supResp.Content
if ($sh -notmatch 'id="imports-dropzone"')        { Fail "supervisor render missing dropzone DOM" }
if ($sh -notmatch '/js/imports\.js')              { Fail "supervisor render missing imports.js script tag" }
if ($sh -match    'imports-operator-notice')      { Fail "supervisor render leaks operator-notice block" }
OK "Supervisor sees same uploader shape as admin"

# ----------------------------------------------------------------------------
# 8. Operator GET /Imports — notice only, no dropzone, no script
# ----------------------------------------------------------------------------
Step "Operator (npatcharin @ WH-03) GET /Imports renders operator notice"
$opSv = Login 'npatcharin' 'demo1234' $WH_03
$opResp = Invoke-WebRequest -Uri "$base/Imports" -WebSession $opSv -MaximumRedirection 0
if ($opResp.StatusCode -ne 200) { Fail "operator GET /Imports → $($opResp.StatusCode)" }
$oh = $opResp.Content
if ($oh -notmatch 'imports-operator-notice')      { Fail "operator render missing notice block" }
if ($oh -match    'id="imports-dropzone"')        { Fail "operator render leaks dropzone DOM" }
if ($oh -match    '/js/imports\.js')              { Fail "operator render leaks imports.js script tag" }
OK "Operator sees notice; no dropzone or script tag exposed"

# ----------------------------------------------------------------------------
# 9. API still gates operator at 403 (UI gate is convenience; API is truth)
# ----------------------------------------------------------------------------
Step "API /api/imports/po/upload still rejects operator with 403"
$opStatus = 0
try {
    Invoke-WebRequest -Uri "$base/api/imports/po/upload" -Method POST -WebSession $opSv `
        -Form @{ file = Get-Item -LiteralPath (Join-Path $repoRoot 'tools\fixtures\po-import-sample.xlsx') } `
        -MaximumRedirection 0 -ErrorAction Stop | Out-Null
} catch {
    $opStatus = $_.Exception.Response.StatusCode.value__
}
if ($opStatus -ne 403) { Fail "operator POST upload → HTTP $opStatus, expected 403" }
OK "Operator blocked at API regardless of UI shape (403)"

# ----------------------------------------------------------------------------
# 10. imports.js statically served
# ----------------------------------------------------------------------------
Step "GET /js/imports.js → 200"
$jsResp = Invoke-WebRequest -Uri "$base/js/imports.js" -WebSession $adminSv -Method GET -MaximumRedirection 0
if ($jsResp.StatusCode -ne 200) { Fail "GET /js/imports.js → $($jsResp.StatusCode)" }
if ($jsResp.Content.Length -lt 1000) { Fail "imports.js response too short: $($jsResp.Content.Length) bytes" }
OK "imports.js served ($($jsResp.Content.Length) bytes)"

# ----------------------------------------------------------------------------
# 11. imports.css statically served
# ----------------------------------------------------------------------------
Step "GET /css/imports.css → 200"
$cssResp = Invoke-WebRequest -Uri "$base/css/imports.css" -WebSession $adminSv -Method GET -MaximumRedirection 0
if ($cssResp.StatusCode -ne 200) { Fail "GET /css/imports.css → $($cssResp.StatusCode)" }
if ($cssResp.Content.Length -lt 500) { Fail "imports.css response too short: $($cssResp.Content.Length) bytes" }
OK "imports.css served ($($cssResp.Content.Length) bytes)"

Write-Host ""
Write-Host "ALL PASS — Phase 12.8: /Imports upload UI role-gated render + static assets verified." -ForegroundColor Green
exit 0
