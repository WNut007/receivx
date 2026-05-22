# Smoke test: §3.5 Phase 5a — Receive Goods modal UI wiring
#
# This is a landmark/source-level smoke (no headless browser). It verifies:
#   1. receiving.js carries the new wiring strings
#        - scope badge labels ("Warehouse-wide", "Pull-locked")
#        - reads `p.scope` and stores `item.scopeHint`
#        - parses 409 ProblemDetails (title) into the warning slot
#        - per-allocation line uses `a.poLineNumber` and renders alloc-line spans
#        - 200-success path no longer keys off `p.shortage > 0`
#   2. receiving.css carries .alloc-scope + .alloc-scope.warehouse-wide
#        + .alloc-scope.pull-locked + .alloc-line rules
#   3. Razor view still has #m-alloc-list + #m-alloc-warning slots
#   4. Receiving page returns 200 for an authenticated user
#   5. Live /api/receipts/preview round-trips against the three §3.5 fixtures:
#        (a) PL-2847 lock=0 → 200 + scope=warehouse-wide + allocations[0].poLineNumber present
#        (b) PL-2900 lock=1 → 200 + scope=pull-locked  + 1 allocation, PO-2405-001
#        (c) PL-2901 lock=1 + no PO → 409 ProblemDetails with title 'No PO linked...'
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$session = $null

$WH_01 = '22222222-2222-2222-2222-000000000001'
$PI_2847_PCBA = '44444444-4444-4444-2847-000000000001'  # PL-2847 lock=0
$PI_2900_PCBA = '44444444-4444-4444-2900-000000000001'  # PL-2900 lock=1, linked
$PI_2901_PCBA = '44444444-4444-4444-2901-000000000001'  # PL-2901 lock=1, no PO

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# ----------------------------------------------------------------------------
# 1. receiving.js carries the new Stage B 5a wiring
# ----------------------------------------------------------------------------
Step "receiving.js carries scope badge + 409 parse + alloc-line rendering"
$js = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\receiving.js' -Raw
foreach ($needle in @(
    'scopeBadgeHtml',
    'Warehouse-wide',
    'Pull-locked',
    'alloc-scope',
    'alloc-line',
    'scopeHint',
    'r.status === 409',
    'a.poLineNumber',
    'p.scope'
)) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "receiving.js missing '$needle'" }
}
# The pre-Phase-5a path used to gate the "warn" branch on `p.shortage > 0`,
# which can never fire now because Preview throws 409 on shortage. Make sure
# that branch is gone so we don't silently hide a real capacity error.
if ($js -match 'p\.shortage\s*>\s*0') { Fail "receiving.js still keys off p.shortage > 0 (pre-Phase-5a behavior)" }
OK "receiving.js Stage B 5a wiring intact"

# ----------------------------------------------------------------------------
# 2. receiving.css carries the new scope badge rules
# ----------------------------------------------------------------------------
Step "receiving.css carries .alloc-scope + .alloc-scope.warehouse-wide + .alloc-scope.pull-locked + .alloc-line"
$css = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\receiving.css' -Raw
foreach ($cls in @('.alloc-scope', '.alloc-scope.warehouse-wide', '.alloc-scope.pull-locked', '.alloc-line')) {
    if ($css -notmatch [regex]::Escape($cls)) { Fail "receiving.css missing rule for $cls" }
}
OK "All 4 Phase 5a CSS rules present"

# ----------------------------------------------------------------------------
# 3. Razor view still carries the slot ids (slicer ran)
# ----------------------------------------------------------------------------
Step "Receiving Razor view carries #m-alloc-list + #m-alloc-warning"
$razor = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Receiving\Index.cshtml' -Raw
foreach ($id in @('m-alloc-list', 'm-alloc-warning')) {
    if ($razor -notmatch [regex]::Escape("id=`"$id`"")) { Fail "Razor view missing #$id" }
}
OK "Razor view has both alloc slots"

# ----------------------------------------------------------------------------
# 4. Live login + Receiving page returns 200
# ----------------------------------------------------------------------------
Step "Login (sadmin / WH-01)"
$loginBody = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$null = Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable session
OK "Login ok"

Step "GET /Receiving/PL-2847 returns 200 with both alloc slots in markup"
$page = Invoke-WebRequest -Uri "$base/Receiving/PL-2847" -WebSession $session
if ($page.StatusCode -ne 200) { Fail "Expected 200, got $($page.StatusCode)" }
$html = $page.Content
foreach ($id in @('m-alloc-list', 'm-alloc-warning')) {
    if ($html -notmatch [regex]::Escape("id=`"$id`"")) { Fail "Receiving page missing #$id" }
}
OK "Receiving page renders with both alloc slots"

# ----------------------------------------------------------------------------
# 5. Live preview against the three §3.5 fixtures
# ----------------------------------------------------------------------------
Step "Preview PL-2847 lock=0 (warehouse-wide) → scope=warehouse-wide + poLineNumber set"
$p = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$PI_2847_PCBA&qty=100" -WebSession $session
if ($p.scope -ne 'warehouse-wide') { Fail "Expected scope='warehouse-wide', got '$($p.scope)'" }
if ($p.allocations.Count -lt 1) { Fail "No allocations returned" }
$a0 = $p.allocations[0]
if (-not $a0.PSObject.Properties['poLineNumber']) { Fail "Allocation missing poLineNumber field" }
if ($a0.poLineNumber -lt 1) { Fail "poLineNumber expected >=1, got $($a0.poLineNumber)" }
OK "warehouse-wide: $($a0.qty)@$($a0.poNumber)·L$($a0.poLineNumber)"

Step "Preview PL-2900 lock=1 → scope=pull-locked, single PO-2405-001"
$p = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$PI_2900_PCBA&qty=100" -WebSession $session
if ($p.scope -ne 'pull-locked') { Fail "Expected scope='pull-locked', got '$($p.scope)'" }
if ($p.allocations.Count -ne 1) { Fail "Expected 1 allocation, got $($p.allocations.Count)" }
if ($p.allocations[0].poNumber -ne 'PO-2405-001') {
    Fail "Expected PO-2405-001, got $($p.allocations[0].poNumber)"
}
OK "pull-locked: 100@PO-2405-001·L$($p.allocations[0].poLineNumber)"

Step "Preview PL-2901 lock=1 + no PO → 409 ProblemDetails title='No PO linked...'"
try {
    Invoke-WebRequest -Uri "$base/api/receipts/preview?pullItemId=$PI_2901_PCBA&qty=10" -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $body = $_.ErrorDetails.Message
    if ($body -notmatch 'No PO linked') { Fail "Expected 'No PO linked' in body, got: $body" }
    OK "409 surfaced with title containing 'No PO linked'"
}

Step "Preview PL-2900 lock=1 qty=10000 (over PO-2405-001 cap=500) → 409 'Insufficient PO capacity'"
try {
    Invoke-WebRequest -Uri "$base/api/receipts/preview?pullItemId=$PI_2900_PCBA&qty=10000" -WebSession $session | Out-Null
    Fail "Expected 409, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $body = $_.ErrorDetails.Message
    if ($body -notmatch 'Insufficient PO capacity') { Fail "Expected 'Insufficient PO capacity' in body, got: $body" }
    OK "409 surfaced with title containing 'Insufficient PO capacity'"
}

Write-Host "`nPhase 5a smoke PASSED." -ForegroundColor Green
exit 0
