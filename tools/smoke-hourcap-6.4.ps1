# Smoke test: v2.1 Hour Cap Phase 6.4 — UI surfacing
#
# Source-level only — the UI itself is exercised in a browser. What this
# pins down: every Razor + JS + CSS landmark that 6.4 added is present, and
# the served HTML / served JS carry them after build. Catches stale Razor
# compiles + missed mockup-vs-served drift.
#
# Coverage:
#   1. Dashboard Razor: pm-lock-hour-cap checkbox, pm-hcap-card + help id,
#      d-hcap-mode drawer row, section title updated to "Strict mode".
#   2. dashboard.js: adapt() passes lockHourCap; openCreate/Edit/save wire
#      the checkbox; openDrawer renders the hour-cap pill; default true on
#      create.
#   3. dashboard.css: .lock-mode-pill.hcap-strict + .hcap-loose variants.
#   4. receiving.js: Preview fetch URL gains optional &hour= so the modal's
#      alloc panel surfaces the 6.2 "Insufficient hour capacity" 409 early.
#   5. Live: GET /Dashboard 200 + served HTML carries the new ids; GET
#      /Receiving/PL-TEST 200.
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# ----------------------------------------------------------------------------
# 1. Razor — modal checkbox + drawer row + section title
# ----------------------------------------------------------------------------
Step "Index.cshtml carries 6.4 landmarks"
$razor = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Dashboard\Index.cshtml' -Raw
foreach ($needle in @(
    'id="pm-lock-hour-cap"',
    'id="pm-hcap-card"',
    'id="pm-hcap-help"',
    'id="d-hcap-mode"',
    'Strict per-hour capacity'
)) {
    if ($razor -notmatch [regex]::Escape($needle)) { Fail "Index.cshtml missing $needle" }
}
# Drawer section title renamed from "PO allocation mode" to "Strict mode" so it
# umbrellas both PO lock + hour cap. Match the prefix only (avoid the section
# headline's UTF-8 §/· chars which trip ASCII-mode greps).
if ($razor -notmatch 'Strict mode\b') { Fail "Index.cshtml drawer section not renamed to 'Strict mode'" }
if ($razor -notmatch '>Hour cap<')    { Fail "Index.cshtml drawer missing 'Hour cap' label" }
OK "Razor view has every 6.4 id + renamed drawer section"

# ----------------------------------------------------------------------------
# 2. dashboard.js — adapt + modal open/save + drawer pill
# ----------------------------------------------------------------------------
Step "dashboard.js wires lockHourCap end-to-end"
$js = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\dashboard.js' -Raw
# Literal-substring landmarks (whitespace-insensitive around `:` to tolerate
# column-aligned reformats from later commits — e.g. Phase 7.1 added the
# `referenceNumber:` line and aligned the whole block).
foreach ($needle in @(
    "getElementById('pm-lock-hour-cap')",
    "getElementById('pm-hcap-card')",
    "getElementById('pm-hcap-help')",
    "getElementById('d-hcap-mode')",
    'hcap-strict',
    'hcap-loose'
)) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "dashboard.js missing $needle" }
}
# adapt() forwarding + savePullModal body — match by key:value pair without
# pinning whitespace, so adding sibling fields above/below stays compatible.
if ($js -notmatch 'lockHourCap\s*:\s*s\.lockHourCap')                { Fail "dashboard.js missing adapt() forwarding for lockHourCap" }
if ($js -notmatch 'lockHourCap\s*:\s*document\.getElementById')      { Fail "dashboard.js missing savePullModal body for lockHourCap" }
# Create path defaults to true (checkbox.checked = true)
if ($js -notmatch 'hcapChk\.checked\s*=\s*true') { Fail "dashboard.js openCreate doesn't default hcap checkbox to true" }
# Edit path disables + echoes
if ($js -notmatch 'hcapChk\.disabled\s*=\s*true') { Fail "dashboard.js openEdit doesn't disable hcap checkbox" }
OK "dashboard.js wires adapt + modal open/save + drawer pill"

# ----------------------------------------------------------------------------
# 3. dashboard.css — new pill variants
# ----------------------------------------------------------------------------
Step "dashboard.css carries .lock-mode-pill.hcap-strict + .hcap-loose"
$css = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\dashboard.css' -Raw
foreach ($rule in @('.lock-mode-pill.hcap-strict', '.lock-mode-pill.hcap-loose')) {
    if ($css -notmatch [regex]::Escape($rule)) { Fail "dashboard.css missing rule $rule" }
}
OK "CSS pill variants present"

# ----------------------------------------------------------------------------
# 4. receiving.js — Preview URL passes &hour=
# ----------------------------------------------------------------------------
Step "receiving.js Preview URL passes &hour="
$rjs = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\receiving.js' -Raw
if ($rjs -notmatch [regex]::Escape('window._activeHour')) { Fail "receiving.js not referencing window._activeHour for hour" }
if ($rjs -notmatch [regex]::Escape('&hour=${hour}'))      { Fail "receiving.js Preview URL not appending &hour=" }
OK "receiving.js Preview URL carries optional &hour="

# ----------------------------------------------------------------------------
# 5. Live: /Dashboard 200 + served HTML carries the new ids
# ----------------------------------------------------------------------------
Step "GET /Dashboard 200 + served HTML carries pm-lock-hour-cap + d-hcap-mode"
$body = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null

$page = Invoke-WebRequest -Uri "$base/Dashboard" -Method GET -WebSession $sv -UseBasicParsing
if ($page.StatusCode -ne 200) { Fail "Dashboard returned $($page.StatusCode)" }
foreach ($id in @('id="pm-lock-hour-cap"', 'id="d-hcap-mode"', 'id="pm-hcap-card"')) {
    if ($page.Content -notmatch [regex]::Escape($id)) { Fail "Served Dashboard HTML missing $id (stale Razor compile?)" }
}
OK "Dashboard 200 + new ids in served HTML"

# /Receiving still 200 (no Razor change there, but worth a regression check)
Step "GET /Receiving/PL-TEST 200 (Preview URL change didn't break the view)"
$rcv = Invoke-WebRequest -Uri "$base/Receiving/PL-TEST" -Method GET -WebSession $sv -UseBasicParsing
if ($rcv.StatusCode -ne 200) { Fail "Receiving returned $($rcv.StatusCode)" }
OK "Receiving 200"

Write-Host ""
Write-Host "ALL PASS — Hour Cap Phase 6.4 UI surfacing wired (browser verify next)." -ForegroundColor Green
exit 0
