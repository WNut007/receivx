# Smoke: /Masters + /Config pages render the verbatim mockup port.
# Verifies: auth gate, mockup landmarks present, static files served,
# node syntax check on the JS (no parse errors), and key API hooks present
# in config.js (it's been Stage-B rewired).

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}
function ExpectStatus([int]$expected, [scriptblock]$block) {
    try { & $block | Out-Null } catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -ne $expected) { Fail "Expected $expected, got $sc" }
        return
    }
    Fail "Expected $expected, got success"
}

# Returns a tuple (statusCode, locationHeader) for the *first* response, without
# auto-following redirects. PS 7's Invoke-WebRequest throws on MaximumRedirection
# hits and discards the response, so use HttpClient directly.
function FetchNoFollow($uri, $session) {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    if ($session) { $handler.CookieContainer = $session.Cookies }
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $resp = $client.GetAsync($uri).GetAwaiter().GetResult()
        $loc = ''
        if ($resp.Headers.Location) { $loc = $resp.Headers.Location.ToString() }
        return @{ StatusCode = [int]$resp.StatusCode; Location = $loc }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

# ============================================================================
# 1. Auth gates
# ============================================================================
Step "GET /Masters without auth redirects to login"
$r = FetchNoFollow "$base/Masters" $null
if ($r.StatusCode -ne 302) { Fail "Expected 302, got $($r.StatusCode)" }
if ($r.Location -notmatch 'Account/Login') { Fail "Redirect location=$($r.Location)" }
OK "Anonymous → 302 to /Account/Login"

Step "Login as supervisor; GET /Masters → 302 to AccessDenied"
$sup = Login 'swattana' 'demo1234' $WH01
$r2 = FetchNoFollow "$base/Masters" $sup
if ($r2.StatusCode -ne 302) { Fail "Expected 302 to access-denied, got $($r2.StatusCode)" }
if ($r2.Location -notmatch 'AccessDenied') { Fail "Loc=$($r2.Location)" }
OK "Non-admin masters access blocked"

Step "Anonymous GET /Config → 302 to login"
$r3 = FetchNoFollow "$base/Config" $null
if ($r3.StatusCode -ne 302) { Fail "Config anon: $($r3.StatusCode)" }
OK "Anonymous config access blocked"

# ============================================================================
# 2. Logged-in admin sees /Masters
# ============================================================================
Step "Admin GET /Masters → 200 with mockup landmarks"
$adm = Login 'sadmin' 'admin' $WH01
$page = Invoke-WebRequest -Uri "$base/Masters" -WebSession $adm
if ($page.StatusCode -ne 200) { Fail "GET /Masters: $($page.StatusCode)" }
$html = $page.Content

$landmarks = @(
    'data-app-page="masters"',
    'masters.css',
    'masters.js',
    'data-tab="users"',
    'data-tab="warehouses"',
    'data-tab="audit"',
    'btn-new-user',
    'btn-new-warehouse'
)
foreach ($l in $landmarks) {
    if ($html -notmatch [regex]::Escape($l)) { Fail "Missing landmark '$l' in /Masters HTML" }
}
OK "All $($landmarks.Count) mockup landmarks present"

# ============================================================================
# 3. /Config renders
# ============================================================================
Step "Logged-in user GET /Config → 200 with mockup landmarks"
$cfgPage = Invoke-WebRequest -Uri "$base/Config" -WebSession $sup
if ($cfgPage.StatusCode -ne 200) { Fail "/Config: $($cfgPage.StatusCode)" }
$cfgHtml = $cfgPage.Content
$cfgLand = @(
    'data-app-page="config"',
    'config.css',
    'config.js',
    'nav-position',
    'nav-behavior',
    'theme-card',
    'btn-save',
    'btn-signout'
)
foreach ($l in $cfgLand) {
    if ($cfgHtml -notmatch [regex]::Escape($l)) { Fail "Missing landmark '$l' in /Config HTML" }
}
OK "All $($cfgLand.Count) mockup landmarks present"

# ============================================================================
# 4. Static assets are served (no 404)
# ============================================================================
Step "Static assets served"
foreach ($asset in @('/css/masters.css', '/js/masters.js', '/css/config.css', '/js/config.js')) {
    $a = Invoke-WebRequest -Uri "$base$asset" -SkipHttpErrorCheck
    if ($a.StatusCode -ne 200) { Fail "$asset returned $($a.StatusCode)" }
    if ($a.Content.Length -lt 500) { Fail "$asset suspiciously short: $($a.Content.Length) bytes" }
}
OK "All 4 static assets returned 200 with reasonable size"

# ============================================================================
# 5. JS parses with node (no syntax errors)
# ============================================================================
Step "node --check on masters.js + config.js"
$cfgJs = "C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\config.js"
$masJs = "C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\masters.js"
node --check $cfgJs 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "config.js: node --check failed" }
node --check $masJs 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "masters.js: node --check failed" }
OK "Both JS files parse clean"

# ============================================================================
# 6. config.js is Stage-B wired (no localStorage prefs reads, uses fetch)
# ============================================================================
Step "config.js: API-wired, no pullController.theme localStorage"
$cfgJsBody = Get-Content -LiteralPath $cfgJs -Raw
if ($cfgJsBody -match "localStorage\.setItem\('pullController\.theme'") {
    Fail "config.js still writes to localStorage 'pullController.theme'"
}
if ($cfgJsBody -notmatch "/api/me/preferences") {
    Fail "config.js missing /api/me/preferences call"
}
if ($cfgJsBody -notmatch "/api/auth/me") {
    Fail "config.js missing /api/auth/me call"
}
if ($cfgJsBody -notmatch "/api/auth/logout") {
    Fail "config.js missing /api/auth/logout call"
}
OK "config.js is Stage B (api-wired, no preferences in localStorage)"

# ============================================================================
# 7. masters.js is Stage B (api-wired, no seed, no STORE wrapper)
# ============================================================================
Step "masters.js: API-wired, no DEFAULT_USERS seed, no localStorage STORE"
$masJsBody = Get-Content -LiteralPath $masJs -Raw
if ($masJsBody -match "DEFAULT_USERS") { Fail "masters.js still contains DEFAULT_USERS seed" }
if ($masJsBody -match "localStorage\.setItem\('masters\.") { Fail "masters.js still writes 'masters.*' to localStorage" }
foreach ($mustHave in @('/api/users', '/api/warehouses', '/api/audit', 'syncUsers', 'syncWarehouses')) {
    if ($masJsBody -notmatch [regex]::Escape($mustHave)) { Fail "masters.js missing '$mustHave'" }
}
OK "masters.js is Stage B (api-wired)"

# ============================================================================
# 8. API list returns assignments[] inline so the table renders no N+1
# ============================================================================
Step "GET /api/users returns each row with assignments[] inline"
$inlineUsers = Invoke-RestMethod -Uri "$base/api/users" -WebSession $adm
$sadminRow = $inlineUsers | Where-Object { $_.username -eq 'sadmin' } | Select-Object -First 1
if (-not $sadminRow) { Fail "sadmin missing" }
if (-not $sadminRow.assignments) { Fail "sadmin.assignments is null — inline join broke" }
if ($sadminRow.assignments.Count -lt 4) { Fail "sadmin.assignments count=$($sadminRow.assignments.Count), expected ≥4" }
$first = $sadminRow.assignments[0]
foreach ($field in @('warehouseId', 'warehouseCode', 'warehouseName', 'role')) {
    if (-not $first.PSObject.Properties[$field]) { Fail "assignment row missing '$field'" }
}
OK "List rows carry assignments inline (sadmin: $($sadminRow.assignments.Count) WHs)"

Write-Host "`nMasters/Config page smoke passed." -ForegroundColor Green
