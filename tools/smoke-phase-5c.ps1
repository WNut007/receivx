# Smoke test: §3.5 Phase 5c — Purchase Order admin UI
#
# Source-level + live HTTP checks for the new /Pos surface:
#   - PosController exists, Razor view + pos.js have the right structure
#   - GET /Pos: 200 to admin, 200 to supervisor (CanManagePulls);
#     403 when the same user is logged into a warehouse where they are an operator
#   - Create PO via /api/pos (round-trip: name appears in list)
#   - PUT with a *different* PullId → 409 (§3.5 immutability)
#   - PUT with the same PullId → 200 (idempotent echo)
#   - AddLine → 200; DeleteLine on a brand-new line → 204
#   - DeleteLine on a line that has receipts → 409 (§7.13)
#   - Close PO with reason → 204; subsequent PUT → 409 ("PO is closed")
#
# Each run creates a uniquely-named PO (suffix = Get-Date Ticks) so re-runs
# don't collide on PoNumber uniqueness.
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_02 = '22222222-2222-2222-2222-000000000002'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# ----------------------------------------------------------------------------
# 1. Source-level — controller + view + JS handlers
# ----------------------------------------------------------------------------
Step "PosController.cs exists with /Pos route + CanManagePulls policy"
$ctrl = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Controllers\PosController.cs' -Raw
foreach ($needle in @('PosController', '"/Pos"', 'CanManagePulls')) {
    if ($ctrl -notmatch [regex]::Escape($needle)) { Fail "PosController missing '$needle'" }
}
OK "PosController wires the route + policy"

Step "Pos Razor view + pos.js + pos.css present"
foreach ($p in @(
    'C:\dev\receivx\src\ReceivingOps.Web\Views\Pos\Index.cshtml',
    'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\pos.js',
    'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\pos.css'
)) {
    if (-not (Test-Path $p)) { Fail "Missing $p" }
}
OK "View + JS + CSS files present"

Step "pos.js has the §5c handlers (saveNewPo, saveHeader, deleteLine, openCloseModal, confirmClose)"
$js = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\pos.js' -Raw
foreach ($needle in @(
    'saveNewPo',
    'saveHeader',
    'saveAddLine',
    'deleteLine',
    'openCloseModal',
    'confirmClose',
    'refreshPullPicker',
    '§3.5',                # comment marker (Thai-aware)
    'pullSel.disabled = true',
    "currentRole !== 'admin'"
)) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "pos.js missing '$needle'" }
}
OK "pos.js carries the Stage B handlers + immutability gates"

Step "Razor view has list + detail sections + 3 modals + correct IDs"
$razor = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Pos\Index.cshtml' -Raw
foreach ($needle in @(
    'id="view-list"', 'id="view-detail"',
    'id="newPoModal"', 'id="addLineModal"', 'id="closePoModal"',
    'id="po-tbody"', 'id="po-lines-tbody"',
    'id="d-pull-id"', 'id="n-pull-id"', 'id="cp-reason"',
    'id="btn-new-po"', 'id="btn-close-po"', 'id="btn-add-line"'
)) {
    if ($razor -notmatch [regex]::Escape($needle)) { Fail "View missing '$needle'" }
}
OK "Razor view carries list/detail + 3 modals + load-bearing IDs"

# ----------------------------------------------------------------------------
# 2. Live HTTP
# ----------------------------------------------------------------------------
Step "GET /Pos = 200 to admin (sadmin)"
$adm = Login 'sadmin' 'admin' $WH_01
$resp = Invoke-WebRequest -Uri "$base/Pos" -WebSession $adm
if ($resp.StatusCode -ne 200) { Fail "Expected 200, got $($resp.StatusCode)" }
if ($resp.Content -notmatch 'id="view-list"')   { Fail "Live page missing list view" }
if ($resp.Content -notmatch 'id="view-detail"') { Fail "Live page missing detail view" }
OK "admin sees the page; both views present in HTML"

Step "GET /Pos = 200 to supervisor (swattana@WH-01)"
$sup = Login 'swattana' 'demo1234' $WH_01
$respS = Invoke-WebRequest -Uri "$base/Pos" -WebSession $sup
if ($respS.StatusCode -ne 200) { Fail "Expected 200 for supervisor, got $($respS.StatusCode)" }
OK "supervisor (WH-01) sees the page"

Step "GET /Pos blocked when same user is operator in the chosen warehouse (swattana@WH-02)"
# MVC routes use the default cookie redirect flow (302 → /Account/AccessDenied).
# Only /api/* returns real 401/403 status codes (see Program.cs OnRedirectToAccessDenied).
$op = Login 'swattana' 'demo1234' $WH_02
try {
    $r = Invoke-WebRequest -Uri "$base/Pos" -WebSession $op -MaximumRedirection 0 -ErrorAction Stop
    Fail "Expected redirect, got $($r.StatusCode)"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 302) { Fail "Expected 302 redirect, got $code" }
    $loc = $_.Exception.Response.Headers.Location
    if ($loc -notmatch 'AccessDenied') { Fail "Expected redirect to AccessDenied, got: $loc" }
    OK "operator session refused (302 → AccessDenied)"
}

# ----------------------------------------------------------------------------
# 3. CRUD round-trip against /api/pos
# ----------------------------------------------------------------------------
$poNumber = "PO-5C-$([DateTime]::UtcNow.Ticks % 1000000)"

Step "Create PO via POST /api/pos (admin) — unique PoNumber $poNumber"
$createBody = @{
    poNumber    = $poNumber
    warehouseId = $WH_01
    vendorCode  = 'VND-5C'
    vendorName  = 'Smoke Test Vendor'
    orderDate   = (Get-Date).ToString('yyyy-MM-dd')
    notes       = "Phase 5c smoke @ $(Get-Date -Format 'o')"
    pullId      = $null
    lines       = @()
} | ConvertTo-Json
$created = Invoke-RestMethod -Uri "$base/api/pos" -Method POST -Body $createBody -ContentType 'application/json' -WebSession $adm
if (-not $created.id) { Fail "Create returned no id" }
if ($created.poNumber -ne $poNumber) { Fail "Returned PoNumber mismatch" }
$poId = $created.id
OK "Created PO $poNumber (Id $($poId.ToString().Substring(0,8)))"

Step "PUT same PullId echo → 200"
$updBody = @{
    vendorCode   = 'VND-5C'
    vendorName   = 'Smoke Test Vendor (renamed)'
    orderDate    = $created.orderDate
    expectedDate = $null
    notes        = 'Echo same pullId'
    pullId       = $created.pullId     # NULL → NULL, valid echo
} | ConvertTo-Json
$updated = Invoke-RestMethod -Uri "$base/api/pos/$poId" -Method PUT -Body $updBody -ContentType 'application/json' -WebSession $adm
if ($updated.vendorName -ne 'Smoke Test Vendor (renamed)') { Fail "PUT didn't propagate vendorName" }
OK "PUT with echoed pullId returned 200"

Step "PUT with DIFFERENT PullId → 409 (§3.5 immutability)"
# Pick any open pull in WH-01 to attempt the change
$openPulls = Invoke-RestMethod -Uri "$base/api/pulls?warehouseId=$WH_01&status=pending" -WebSession $adm
if (-not $openPulls -or $openPulls.Count -lt 1) {
    Fail "No open pulls in WH-01 — cannot exercise the immutability case"
}
$tryPullId = $openPulls[0].id
$badBody = @{
    vendorCode   = 'VND-5C'
    vendorName   = 'whatever'
    orderDate    = $created.orderDate
    expectedDate = $null
    notes        = $null
    pullId       = $tryPullId       # NULL → value transition is also refused
} | ConvertTo-Json
try {
    Invoke-WebRequest -Uri "$base/api/pos/$poId" -Method PUT -Body $badBody -ContentType 'application/json' -WebSession $adm | Out-Null
    Fail "Expected 409 on PullId change, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $bodyText = $_.ErrorDetails.Message
    if ($bodyText -notmatch 'immutable|PullId') { Fail "Expected 'immutable' or 'PullId' in body, got: $bodyText" }
    OK "409 with title mentioning PullId immutability"
}

# ----------------------------------------------------------------------------
# 4. Lines: add → delete (no receipts → 204)
# ----------------------------------------------------------------------------
Step "Add a line to the new PO (POST /api/pos/{id}/lines)"
$lineBody = @{ lineNumber = 1; itemCode = 'SMOKE-5C'; description = 'Smoke test line'; orderedQty = 100 } | ConvertTo-Json
$lineResp = Invoke-RestMethod -Uri "$base/api/pos/$poId/lines" -Method POST -Body $lineBody -ContentType 'application/json' -WebSession $adm
if (-not $lineResp.id) { Fail "AddLine returned no id" }
$lineId = $lineResp.id
OK "Added line $($lineId.ToString().Substring(0,8))"

Step "Delete the brand-new line → 204"
$delResp = Invoke-WebRequest -Uri "$base/api/pos/$poId/lines/$lineId" -Method DELETE -WebSession $adm
if ($delResp.StatusCode -ne 204) { Fail "Expected 204, got $($delResp.StatusCode)" }
OK "Line deleted (no receipts referenced)"

# ----------------------------------------------------------------------------
# 5. Delete a line WITH receipts → 409 (§7.13)
# ----------------------------------------------------------------------------
Step "Find a line on PO-2401-018 with ReceivedQty > 0"
$po018 = (Invoke-RestMethod -Uri "$base/api/pos?warehouseId=$WH_01" -WebSession $adm) | Where-Object { $_.poNumber -eq 'PO-2401-018' } | Select-Object -First 1
if (-not $po018) { Fail "Could not find PO-2401-018 in WH-01 list" }
$detail018 = Invoke-RestMethod -Uri "$base/api/pos/$($po018.id)" -WebSession $adm
$lineWithReceipts = $detail018.lines | Where-Object { $_.receivedQty -gt 0 } | Select-Object -First 1
if (-not $lineWithReceipts) { Fail "No line on PO-2401-018 has ReceivedQty > 0" }
OK "Will attempt to delete line $($lineWithReceipts.lineNumber) (received=$($lineWithReceipts.receivedQty))"

Step "DELETE that line → expect 409"
try {
    Invoke-WebRequest -Uri "$base/api/pos/$($po018.id)/lines/$($lineWithReceipts.id)" -Method DELETE -WebSession $adm | Out-Null
    Fail "Expected 409, got success — §7.13 invariant broken?"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    OK "Line delete refused with 409 (§7.13)"
}

# ----------------------------------------------------------------------------
# 6. Close PO with reason → 204; subsequent PUT → 409
# ----------------------------------------------------------------------------
Step "Close the smoke PO via POST /api/pos/{id}/close"
$closeBody = @{ reason = 'Phase 5c smoke — close path' } | ConvertTo-Json
$closeResp = Invoke-WebRequest -Uri "$base/api/pos/$poId/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $adm
if ($closeResp.StatusCode -ne 204) { Fail "Expected 204, got $($closeResp.StatusCode)" }
OK "PO closed (204)"

Step "GET /api/pos/{id} on closed PO returns status='closed' + ClosedAt populated"
$closed = Invoke-RestMethod -Uri "$base/api/pos/$poId" -WebSession $adm
if ($closed.status -ne 'closed') { Fail "Expected status='closed', got '$($closed.status)'" }
if (-not $closed.closedAt)       { Fail "Expected closedAt populated, got null" }
OK "PO is closed and ClosedAt is set"

Step "PUT on closed PO → expect 409 'Cannot edit a closed PO' (defense-in-depth)"
# Defense-in-depth check added on top of §3.5 + §7.13. Fires BEFORE the PullId
# / receipt-reference rules so the operator sees the real reason.
try {
    Invoke-WebRequest -Uri "$base/api/pos/$poId" -Method PUT -Body $updBody -ContentType 'application/json' -WebSession $adm | Out-Null
    Fail "Expected 409 on closed-PO PUT, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    $bodyText = $_.ErrorDetails.Message
    if ($bodyText -notmatch 'Cannot edit a closed PO') { Fail "Expected 'Cannot edit a closed PO' in body, got: $bodyText" }
    OK "409 with 'Cannot edit a closed PO' title"
}

Step "Closing an already-closed PO → expect 409 (idempotency guard)"
try {
    Invoke-WebRequest -Uri "$base/api/pos/$poId/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $adm | Out-Null
    Fail "Expected 409 on double-close, got success"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 409) { Fail "Expected 409, got $code" }
    OK "Double-close refused (409)"
}

Write-Host "`nPhase 5c smoke PASSED." -ForegroundColor Green
exit 0
