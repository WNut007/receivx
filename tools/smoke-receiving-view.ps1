# Quick smoke: does /Receiving render the mockup port (HTTP 200, hits the static CSS+JS)?
$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$session = $null

function Step($name) { Write-Host "`n--- $name ---" -ForegroundColor Cyan }
function OK($msg) { Write-Host "PASS: $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }

Step "Unauth /Receiving → 302 Login"
try {
    Invoke-WebRequest -Uri "$base/Receiving" -MaximumRedirection 0 -ErrorAction Stop | Out-Null
    Fail "Expected 302 redirect, got 200"
} catch {
    $sc = $_.Exception.Response.StatusCode.value__
    if ($sc -ne 302) { Fail "Expected 302, got $sc" }
    $loc = $_.Exception.Response.Headers.Location
    if ("$loc" -notmatch '/Account/Login') { Fail "Expected redirect to /Account/Login, got $loc" }
    OK "Unauthenticated → 302 to login"
}

Step "Login (sadmin / WH-01)"
$loginBody = @{ username = 'sadmin'; password = 'admin'; warehouseId = '22222222-2222-2222-2222-000000000001'; remember = $false } | ConvertTo-Json
$null = Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable session
OK "Login ok"

Step "GET /Receiving → 200, expect mockup landmarks"
$resp = Invoke-WebRequest -Uri "$base/Receiving" -WebSession $session
if ($resp.StatusCode -ne 200) { Fail "Expected 200, got $($resp.StatusCode)" }
$html = $resp.Content

$expected = @(
    'data-app-page="receiving"',
    '/css/receiving.css',                 # Razor renders ~/ as /
    '/js/receiving.js',
    'Receiving<span>v3.2</span>',         # topbar brand from mockup
    'Pull Sheet Closed',                  # closed banner element
    'tx-drawer-pull'                      # drawer element id from BODY:tx-drawer
)
foreach ($needle in $expected) {
    if ($html -notmatch [regex]::Escape($needle)) { Fail "Markup missing '$needle'" }
}
OK ("Body contains all {0} landmarks" -f $expected.Count)

Step "Static receiving.css served"
$css = Invoke-WebRequest -Uri "$base/css/receiving.css" -WebSession $session
if ($css.StatusCode -ne 200) { Fail "receiving.css → $($css.StatusCode)" }
if ($css.Content -notmatch '--bg:') { Fail "receiving.css doesn't look like the theme stylesheet" }
OK ("receiving.css OK ({0} bytes)" -f $css.RawContentLength)

Step "Static receiving.js served"
$js = Invoke-WebRequest -Uri "$base/js/receiving.js" -WebSession $session
if ($js.StatusCode -ne 200) { Fail "receiving.js → $($js.StatusCode)" }
if ($js.Content -notmatch 'THEME_KEY') { Fail "receiving.js missing expected theme code" }
OK ("receiving.js OK ({0} bytes)" -f $js.RawContentLength)

Step "GET /Receiving/PL-2847 routes to the same view"
$resp = Invoke-WebRequest -Uri "$base/Receiving/PL-2847" -WebSession $session
if ($resp.StatusCode -ne 200) { Fail "Expected 200, got $($resp.StatusCode)" }
if ($resp.Content -notmatch 'data-app-page="receiving"') { Fail "Route param breaks view" }
OK "ID route serves view"

Write-Host "`nReceiving view Stage A smoke passed." -ForegroundColor Green
