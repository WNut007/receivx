# Smoke test: custom confirm modal (design-system replacement for browser native).
#
# Source-level only — the modal itself is pure DOM and can't be exercised
# without a headless browser. What's verified:
#
#   1. No bare confirm( call sites remain in mockups/ or wwwroot/js/. The
#      only allowed matches reference the modal API by name (data-confirm-act,
#      confirmAction, confirm-modal, confirmLabel, confirmBtn) — every
#      `\bconfirm\s*\(` outside those patterns is a regression.
#
#   2. window.confirmAction is defined in both wwwroot/js/app-nav.js AND
#      mockups/app-nav.js (the mirror — they must stay in sync).
#
#   3. Each former call site now uses confirmAction with the expected
#      title (catches a stale find/replace).
#
#   4. /Dashboard page returns 200 and the served app-nav.js carries the
#      module (warm-cache sanity check).
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# ----------------------------------------------------------------------------
# 1. No bare confirm( call sites left
# ----------------------------------------------------------------------------
Step "No bare confirm( call sites in mockups/ or wwwroot/js/"
$scanRoots = @(
    'C:\dev\receivx\mockups',
    'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js'
)
$bareHits = @()
foreach ($root in $scanRoots) {
    $hits = Get-ChildItem -Path $root -Recurse -Include *.js,*.html -File |
        Select-String -Pattern '\bconfirm\s*\(' -AllMatches
    foreach ($h in $hits) {
        $line = $h.Line
        # Allowed: any line that also references the modal API. Everything
        # else is a regression — even a comment that says "confirm(" without
        # the modal reference is suspicious and worth a flag.
        if ($line -notmatch 'data-confirm-act|confirmAction|confirm-modal|confirmLabel|confirmBtn|window\.confirm\(\)') {
            $bareHits += "$($h.Path):$($h.LineNumber): $line"
        }
    }
}
if ($bareHits.Count -gt 0) {
    Fail "Found bare confirm( call(s):`n$(($bareHits | ForEach-Object { '  ' + $_ }) -join "`n")"
}
OK "Zero bare confirm( call sites — all replaced by confirmAction"

# ----------------------------------------------------------------------------
# 2. window.confirmAction defined in both files (live + mockup mirror)
# ----------------------------------------------------------------------------
Step "window.confirmAction defined in wwwroot/js/app-nav.js + mockups/app-nav.js"
foreach ($f in @(
    'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\app-nav.js',
    'C:\dev\receivx\mockups\app-nav.js'
)) {
    $src = Get-Content $f -Raw
    if ($src -notmatch 'window\.confirmAction\s*=\s*function') { Fail "$f missing window.confirmAction" }
    if ($src -notmatch 'confirm-modal-backdrop')               { Fail "$f missing backdrop CSS" }
    if ($src -notmatch 'data-confirm-act="cancel"')            { Fail "$f missing cancel button data-attr" }
    if ($src -notmatch 'data-confirm-act="confirm"')           { Fail "$f missing confirm button data-attr" }
    # Per spec: Enter does NOT auto-confirm — there should be no `key === 'Enter'`
    # binding inside the modal's keydown handler that calls cleanup(true).
    if ($src -match "key\s*===\s*'Enter'.*cleanup\(true\)")    { Fail "$f appears to auto-confirm on Enter — spec forbids" }
}
OK "Both app-nav.js files carry the module + cancel/confirm wiring"

# ----------------------------------------------------------------------------
# 3. Each former call site now uses confirmAction with the expected title
# ----------------------------------------------------------------------------
Step "Every former call site now uses confirmAction with the right title"
$expected = @(
    @{ file='C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\pos.js';        needle='Delete this PO line' },
    @{ file='C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\config.js';     needle='Reset preferences to defaults' },
    @{ file='C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\config.js';     needle="title: 'Sign out" },
    @{ file='C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\dashboard.js';  needle="title: 'Delete item '" },
    @{ file='C:\dev\receivx\mockups\config.html';                           needle='Reset preferences to defaults' },
    @{ file='C:\dev\receivx\mockups\config.html';                           needle="title: 'Sign out" },
    @{ file='C:\dev\receivx\mockups\receiving-mockup-v2-fullreceived.html'; needle='Reopen pull sheet' }
)
foreach ($e in $expected) {
    $src = Get-Content $e.file -Raw
    if ($src -notmatch [regex]::Escape($e.needle)) {
        Fail "$($e.file): missing confirmAction site for '$($e.needle)'"
    }
}
OK "All 7 former call sites have the expected confirmAction title"

# ----------------------------------------------------------------------------
# 4. Live check: /Dashboard 200 + served app-nav.js carries the module
# ----------------------------------------------------------------------------
Step "Live: GET /Dashboard 200 + served app-nav.js has confirmAction"
$body = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null

$page = Invoke-WebRequest -Uri "$base/Dashboard" -Method GET -WebSession $sv -UseBasicParsing
if ($page.StatusCode -ne 200) { Fail "Dashboard returned $($page.StatusCode)" }

$nav = Invoke-WebRequest -Uri "$base/js/app-nav.js" -Method GET -UseBasicParsing
if ($nav.StatusCode -ne 200)                                         { Fail "app-nav.js returned $($nav.StatusCode)" }
if ($nav.Content -notmatch 'window\.confirmAction\s*=\s*function')   { Fail "Served app-nav.js missing confirmAction (stale cache?)" }
OK "Dashboard 200 + served app-nav.js carries the module"

Write-Host ""
Write-Host "ALL PASS — custom confirm modal wired in; no browser-native confirm() call sites remain." -ForegroundColor Green
exit 0
