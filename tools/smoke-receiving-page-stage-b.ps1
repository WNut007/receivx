# Stage B page-side smoke: receiving.js no longer ships the mockup seed and now
# contains the API-wired startup. Also basic JS sanity via node --check if available.
$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

$body = @{ username = 'sadmin'; password = 'admin'; warehouseId = '22222222-2222-2222-2222-000000000001'; remember = $false } | ConvertTo-Json
$sess = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sess | Out-Null

Step "GET /js/receiving.js — seed data is gone, API wiring is present"
$js = (Invoke-WebRequest -Uri "$base/js/receiving.js" -WebSession $sess).Content

# Negative checks: things that MUST be gone after Stage B
$badNeedles = @(
    "label: 'PL-2847 · Mar 18'",   # mockup pullData seed literal
    "'PL-2846': {",
    "'PL-2845': {",
    "TX_STORE_KEY",                # localStorage key removed
    "ensureSeeded"                 # seed-on-first-run IIFE removed
)
foreach ($needle in $badNeedles) {
    if ($js -match [regex]::Escape($needle)) { Fail "Stage B JS still contains '$needle' — seed not fully removed" }
}
OK "No seed remnants"

# Positive checks: Stage B wiring landmarks
$goodNeedles = @(
    "/api/pulls/by-number/",
    "/api/receipts",
    "/api/receipts/pull/",
    "txEnsureLoaded",
    "ingestPullDetail",
    "currentPullId",
    "async function startup",
    "readPullParamOrRedirect"
)
foreach ($needle in $goodNeedles) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "Stage B JS missing landmark '$needle'" }
}
OK "All Stage B wiring landmarks present"

Step "Optional: node --check syntax pass"
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "receiving-check-$([guid]::NewGuid().ToString('N')).js")
    Set-Content -LiteralPath $tmp -Value $js -Encoding utf8
    $check = & node --check $tmp 2>&1
    Remove-Item $tmp -Force
    if ($LASTEXITCODE -ne 0) {
        Write-Host $check -ForegroundColor Red
        Fail "node --check rejected receiving.js"
    }
    OK "node --check clean"
} else {
    Write-Host "SKIP: node not on PATH" -ForegroundColor Yellow
}

Step "GET /Receiving?pull=PL-2847 → 200 + still serves the mockup markup"
$resp = Invoke-WebRequest -Uri "$base/Receiving?pull=PL-2847" -WebSession $sess
if ($resp.StatusCode -ne 200) { Fail "Expected 200, got $($resp.StatusCode)" }
if ($resp.Content -notmatch 'data-app-page="receiving"') { Fail "View body lost" }
OK "Receiving view still renders (Stage A landmark intact)"

Write-Host "`nStage B page-side smoke passed." -ForegroundColor Green
