# Smoke: Pull drawer — maximize toggle and copy-row.
#
# NEW FILE rather than an extension of an existing one. There is no smoke named
# "dashboard"; the nearest is smoke-phase-6.3.ps1, which is scoped to the v2.1
# Phase 6.3 items-grid wiring and is only 156 lines. Folding a later feature
# into a phase-named smoke would misname both — 6.3 would start failing for
# reasons that have nothing to do with Phase 6.3, and this feature would have no
# file anyone could find. Wired into tools/run-smokes.ps1 in the same commit.
#
# The clipboard cases EXECUTE the shipped serialiser in node rather than
# grepping for it, following smoke-variance-outstanding-queries' Q6. That smoke
# exists because four copies of an arithmetic rule passed a source-grep and were
# still wrong; the same trap applies here, where the failure mode is a value
# that looks right on screen and pastes wrong.
#
# Cases:
#   1. A fully-populated row serialises to tab-separated values in column order,
#      with the documented field count
#   2. Empty TAG / FAMILY / TRIAL / LOC produce empty strings between tabs, and
#      no em-dash appears anywhere in the output
#   3. Output contains no newline — one row, one line
#   4. Columns behind the horizontal scroll are present, asserted by position
#   5. WINDOWS splits into three RAW integers — no thousands separator
#   6. Source: the maximize control exists, carries aria-label, and both state
#      labels are present
#   7. Source: the copy trigger is reachable on focus, not hover-only
#   8. Source: Esc handling is unchanged — nothing new intercepts it
#   9. Source: the maximize CSS override can actually beat the base width rule
#  10. Live: /Dashboard still returns 200 and serves the changed assets
#
# Needs node on PATH. Case 10 needs the dev server; it skips cleanly without it.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot  = Join-Path $repoRoot 'src\ReceivingOps.Web'
$jsPath   = Join-Path $webRoot 'wwwroot\js\dashboard.js'
$cssPath  = Join-Path $webRoot 'wwwroot\css\dashboard.css'
$viewPath = Join-Path $webRoot 'Views\Dashboard\Index.cshtml'
$WH_01    = '22222222-2222-2222-2222-000000000001'

$script:pass = 0
$script:fail = 0
function Case($n) { Write-Host "`n=== $n ===" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  PASS: $m" -ForegroundColor Green; $script:pass++ }
function Bad($m)  { Write-Host "  FAIL: $m" -ForegroundColor Red;   $script:fail++ }
function Note($m) { Write-Host "  SKIP: $m" -ForegroundColor DarkYellow }

foreach ($f in @($jsPath, $cssPath, $viewPath)) {
    if (-not (Test-Path $f)) { Write-Host "FAIL: missing $f" -ForegroundColor Red; exit 1 }
}
$js   = Get-Content -Raw -LiteralPath $jsPath
$css  = Get-Content -Raw -LiteralPath $cssPath
$view = Get-Content -Raw -LiteralPath $viewPath

# ============================================================================
# Cases 1-5 — the shipped serialiser, executed
# ============================================================================
Case 'Serialiser (lifted from dashboard.js and run in node)'

# Lift the four functions out of the shipped file. They are written to be free
# of the DOM and of esc() precisely so this can work; if that ever stops being
# true, node throws here rather than the paste being wrong in production.
$mClean  = [regex]::Match($js, '(?s)function cleanCell\(v\) \{.*?\n  \}')
$mVendor = [regex]::Match($js, '(?s)function vendorDisplay\(it\) \{.*?\n  \}')
$mValues = [regex]::Match($js, '(?s)function itemRowValues\(it\) \{.*?\n  \}')
$mSer    = [regex]::Match($js, '(?s)function serializeItemRow\(it\) \{.*?\n  \}')

if (-not ($mClean.Success -and $mVendor.Success -and $mValues.Success -and $mSer.Success)) {
    Bad "could not extract cleanCell/vendorDisplay/itemRowValues/serializeItemRow from dashboard.js — were they renamed or moved inside another function?"
} else {
    $harness = @"
$($mClean.Value)
$($mVendor.Value)
$($mValues.Value)
$($mSer.Value)

const DASH = '—';
const FIELDS = 15;   // 13 header columns, WINDOWS contributing three

// A row as the API actually returns it, every field populated. Quantities are
// deliberately over 999 so a thousands separator would show up if one crept in.
const full = {
  id: 'item-1',
  itemCode: '2063-778193-000',
  description: 'BRACKET ASSY UPPER',
  vendorCode: 'WIPBP1',
  vendorName: 'WIP Buffer Plant 1',
  tag: 'pcba',
  status: 'normal',
  windows: [ { hourOfDay: 7, expectedQty: 2100, receivedQty: 1500 },
             { hourOfDay: 9, expectedQty: 900,  receivedQty: 0 } ],
  productFamily: 'FAM-A',
  fromSubInventory: 'SUB-FROM',
  toSubInventory: 'SUB-TO',
  trialId: 'TRIAL-9',
  location: 'LOC-42',
  phase: 'P3',
  specialControl: 'SPC-1'
};

// The sparse case: the fields an operator most often leaves unset. On screen
// each of these renders as an em-dash.
const sparse = {
  id: 'item-2',
  itemCode: 'SKU-EMPTY',
  description: 'NO ERP DATA',
  vendorCode: null,
  vendorName: null,
  tag: null,
  status: 'normal',
  windows: [],
  productFamily: null,
  fromSubInventory: '',
  toSubInventory: null,
  trialId: '   ',
  location: null,
  phase: null,
  specialControl: null
};

// Free text carrying a newline and a tab. Description comes straight from the
// ERP, and either character would break "one row, one line" on the clipboard.
const dirty = Object.assign({}, full, {
  description: 'LINE ONE\nLINE TWO\tTABBED',
  itemCode: 'SKU-DIRTY'
});

let bad = 0;
function check(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) { console.log('MISMATCH ' + name + ': got ' + g + ', want ' + w); bad++; }
}

// --- 1. column order + field count
const f = serializeItemRow(full).split('\t');
check('full field count', f.length, FIELDS);
check('col 1 code',        f[0],  '2063-778193-000');
check('col 2 description', f[1],  'BRACKET ASSY UPPER');
check('col 3 vendor',      f[2],  'WIPBP1 · WIP Buffer Plant 1');
check('col 4 tag',         f[3],  'pcba');
check('col 5 status',      f[4],  'normal');

// --- 5. WINDOWS split into three raw integers
check('col 6 window count', f[5], '2');
check('col 7 expected',     f[6], '3000');
check('col 8 received',     f[7], '1500');
if (/[0-9],[0-9]/.test(serializeItemRow(full))) {
  console.log('MISMATCH thousands separator present in output'); bad++;
}

// --- 4. the columns behind the horizontal scroll, by position
check('col 9 family',    f[8],  'FAM-A');
check('col 10 from sub', f[9],  'SUB-FROM');
check('col 11 to sub',   f[10], 'SUB-TO');
check('col 12 trial',    f[11], 'TRIAL-9');
check('col 13 loc',      f[12], 'LOC-42');
check('col 14 phase',    f[13], 'P3');
check('col 15 special',  f[14], 'SPC-1');

// --- 2. empties are empty, never an em-dash
const line = serializeItemRow(sparse);
const s = line.split('\t');
check('sparse field count', s.length, FIELDS);
check('sparse tag empty',     s[3],  '');
check('sparse vendor empty',  s[2],  '');
check('sparse family empty',  s[8],  '');
check('sparse trial empty',   s[11], '');   // '   ' trims to empty
check('sparse loc empty',     s[12], '');
check('sparse windows count', s[5],  '0');
check('sparse expected',      s[6],  '0');
if (line.indexOf(DASH) !== -1) { console.log('MISMATCH em-dash present in sparse output'); bad++; }
if (serializeItemRow(full).indexOf(DASH) !== -1) { console.log('MISMATCH em-dash in full output'); bad++; }

// A placeholder arriving as a literal em-dash must still clear.
check('literal em-dash clears', serializeItemRow(Object.assign({}, sparse, { tag: DASH })).split('\t')[3], '');

// --- 3. one row, one line
for (const [n, obj] of [['full', full], ['sparse', sparse], ['dirty', dirty]]) {
  const out = serializeItemRow(obj);
  if (/[\r\n]/.test(out)) { console.log('MISMATCH ' + n + ' output contains a newline'); bad++; }
}
check('dirty description flattened', serializeItemRow(dirty).split('\t')[1], 'LINE ONE LINE TWO TABBED');
check('dirty field count', serializeItemRow(dirty).split('\t').length, FIELDS);

// Vendor falls back to whichever half exists, and never emits a bare separator.
check('vendor code only', serializeItemRow(Object.assign({}, full, { vendorName: null })).split('\t')[2], 'WIPBP1');
check('vendor name only', serializeItemRow(Object.assign({}, full, { vendorCode: null })).split('\t')[2], 'WIP Buffer Plant 1');

console.log(bad === 0 ? 'SERIALISER_OK' : 'SERIALISER_FAIL');
"@

    $tmpJs = Join-Path $env:TEMP "drawer-copy-$([guid]::NewGuid().ToString('N')).js"
    try {
        Set-Content -LiteralPath $tmpJs -Value $harness -Encoding UTF8
        $nodeOut = & node $tmpJs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Bad "node failed to run the serialiser harness: $nodeOut"
        } elseif ($nodeOut -match 'MISMATCH') {
            Bad "serialiser mismatch: $(($nodeOut | Where-Object { $_ -match 'MISMATCH' }) -join ' | ')"
        } elseif ($nodeOut -match 'SERIALISER_OK') {
            OK "33 serialiser cases pass — 15 fields in column order, WINDOWS split to 3 raw ints, empties empty (no em-dash), no newline, scrolled-off columns present"
        } else {
            Bad "unexpected harness output: $nodeOut"
        }
    } finally {
        Remove-Item -LiteralPath $tmpJs -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# Case 6 — maximize control
# ============================================================================
Case 'Maximize control'

if ($view -notmatch 'id="d-maximize"')            { Bad "no #d-maximize control in the drawer header" }
elseif ($view -notmatch '(?s)id="d-maximize"[^>]*aria-label=') { Bad "#d-maximize carries no aria-label" }
else { OK "#d-maximize exists in the drawer header with an aria-label" }

# Both state labels must exist in the shipped JS — a control whose label never
# changes tells a screen-reader user nothing about what state they are in.
if ($js -notmatch 'ขยายเต็มจอ')  { Bad "expand label (ขยายเต็มจอ) missing from dashboard.js" }
elseif ($js -notmatch 'ย่อกลับ') { Bad "restore label (ย่อกลับ) missing from dashboard.js" }
else { OK "both state labels present and swapped from JS" }

if ($js -notmatch "aria-pressed") { Bad "#d-maximize state is not exposed via aria-pressed" }
else { OK "state exposed via aria-pressed" }

# Not persisted across opens.
if ($js -notmatch '(?s)hidden\.bs\.offcanvas.*?setMaximized\(false\)') {
    Bad "maximize is not reset on hidden.bs.offcanvas — the state would persist into the next pull"
} else { OK "maximize resets when the drawer closes, so the next open starts restored" }

# ============================================================================
# Case 7 — copy trigger reachable on focus, not hover-only
# ============================================================================
Case 'Copy trigger reachable by keyboard'

if ($js -notmatch 'data-act="copy"')    { Bad "no per-row copy trigger" }
elseif ($js -notmatch 'copy-row-btn')   { Bad "copy trigger carries no .copy-row-btn hook for the CSS" }
else { OK "per-row copy trigger present" }

if ($css -notmatch '\.copy-row-btn:focus') {
    Bad "copy trigger is revealed on hover only — unreachable by keyboard"
} else { OK "copy trigger revealed on :focus, not hover-only" }

# display:none / visibility:hidden would take it out of the tab order, which is
# the failure this case exists to catch.
if ($css -match '(?s)\.copy-row-btn\s*\{[^}]*(display:\s*none|visibility:\s*hidden)') {
    Bad "copy trigger is hidden with display/visibility — that removes it from the tab order"
} else { OK "hidden via opacity, so it stays in the tab order" }

if ($css -notmatch '\.copy-row-btn\.is-done' -or $css -notmatch '\.copy-row-btn\.is-failed') {
    Bad "no success/failure state styling — a silent copy is indistinguishable from a failed one"
} else { OK "success and failure states both styled" }

if ($js -notmatch 'navigator\.clipboard') { Bad "no clipboard write" }
elseif ($js -notmatch "flashCopyState\(btn, 'is-failed'") { Bad "clipboard failure is not surfaced" }
else { OK "clipboard failure surfaces a failed state rather than a silent no-op" }

# ============================================================================
# Case 8 — Esc unchanged
# ============================================================================
Case 'Esc handling is unchanged'

# Bootstrap's offcanvas owns Esc. dashboard.js has exactly one keydown listener
# and it handles Enter. If a second appears, or the existing one starts reading
# e.key === 'Escape', the brief's "Esc gets you out" contract is broken.
$keydownCount = ([regex]::Matches($js, "addEventListener\('keydown'")).Count
if ($keydownCount -ne 1) {
    Bad "dashboard.js has $keydownCount keydown listeners; expected exactly 1 (the Enter/launch binding)"
} else { OK "exactly one keydown listener, unchanged" }

if ($js -match "Escape") {
    Bad "dashboard.js now references Escape — Bootstrap owns Esc and it must keep closing the drawer, not restoring it"
} else { OK "nothing in dashboard.js intercepts Escape" }

if ($view -notmatch 'data-bs-dismiss="offcanvas"') {
    Bad "the drawer's Bootstrap dismiss binding is gone"
} else { OK "Bootstrap dismiss binding intact" }

# ============================================================================
# Case 9 — the CSS override can actually win
# ============================================================================
Case 'Maximize CSS beats the base width rule'

# The base rule is #detailDrawer.offcanvas — (id + class). A bare .is-maximized
# would lose the cascade and the toggle would look wired up while nothing moved.
if ($css -notmatch '#detailDrawer\.offcanvas\.is-maximized') {
    Bad "no #detailDrawer.offcanvas.is-maximized rule — a lower-specificity selector cannot beat the base width"
} else { OK "override is id-qualified, so it outranks the base width rule" }

# 100vw includes the scrollbar gutter and pushes a fixed panel past the right
# edge; that is how the page behind starts panning sideways.
if ($css -match '#detailDrawer\.offcanvas\.is-maximized\s*\{[^}]*100vw') {
    Bad "maximized width uses 100vw — that includes the scrollbar gutter and can make the page pan sideways"
} else { OK "maximized width avoids 100vw" }

# ============================================================================
# Case 10 — live page
# ============================================================================
Case 'Dashboard still serves'

$serverUp = $false
try {
    $p = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $serverUp = ($p.StatusCode -in @(200, 401))
} catch {
    $sc = $null
    try { $sc = $_.Exception.Response.StatusCode.value__ } catch { }
    $serverUp = ($sc -in @(200, 401))
}

if (-not $serverUp) {
    Note "dev server not responding — live check skipped"
} else {
    $sv = $null
    $body = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body `
        -ContentType 'application/json' -SessionVariable sv | Out-Null

    $page = Invoke-WebRequest -Uri "$base/Dashboard" -Method GET -WebSession $sv -UseBasicParsing
    if ($page.StatusCode -ne 200)            { Bad "/Dashboard returned $($page.StatusCode)" }
    elseif ($page.Content -notmatch 'd-maximize') { Bad "/Dashboard does not render the maximize control" }
    else { OK "/Dashboard renders 200 with the maximize control" }

    $servedJs = Invoke-WebRequest -Uri "$base/js/dashboard.js" -UseBasicParsing
    if ($servedJs.Content -notmatch 'serializeItemRow') { Bad "served dashboard.js has no serializeItemRow" }
    else { OK "served dashboard.js carries the serialiser" }

    $servedCss = Invoke-WebRequest -Uri "$base/css/dashboard.css" -UseBasicParsing
    if ($servedCss.Content -notmatch 'is-maximized') { Bad "served dashboard.css has no .is-maximized rule" }
    else { OK "served dashboard.css carries the maximize rule" }
}

# ============================================================================
Write-Host ""
if ($script:fail -gt 0) {
    Write-Host "FAILED — $($script:pass) passed, $($script:fail) failed." -ForegroundColor Red
    exit 1
}
Write-Host "ALL PASS — $($script:pass) checks across maximize + copy-row." -ForegroundColor Green
exit 0
