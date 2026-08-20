# Smoke: Pull drawer — maximize toggle, copy-row, and duplicate-row.
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
#   -- duplicate-row (brief-drawer-duplicate-row.md) --
#  11. The pre-fill mapping carries every field in the brief's carried list
#  12. VendorCode and VendorName come back empty, both asserted
#  13. Status is never carried; a canceled source row duplicates to a live one
#  14. Hours carry and quantities do NOT. A source row with windows at 7 and 19
#      pre-fills two rows at 7 and 19 with EMPTY quantity inputs, and the modal
#      refuses to save until both are filled
#  15. Em-dash placeholders map to empty values, not to a literal dash
#  16. A duplicated-then-completed row receives as an ORDINARY row: no variance,
#      no reason code. This is the defect the zero-quantity design would have
#      caused, so it gets a test that names it
#  17. Source-level: the duplicate trigger carries an aria-label and is
#      focus-reachable, matching its neighbours in the action group
#
# Needs node on PATH. Cases 10-16 need the dev server; they skip cleanly without it.

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
$mDup    = [regex]::Match($js, '(?s)function buildDuplicatePrefill\(it\) \{.*?\n  \}')

if (-not $mDup.Success) {
    Bad "could not extract buildDuplicatePrefill from dashboard.js — was it renamed or moved inside another function?"
}
if (-not ($mClean.Success -and $mVendor.Success -and $mValues.Success -and $mSer.Success)) {
    Bad "could not extract cleanCell/vendorDisplay/itemRowValues/serializeItemRow from dashboard.js — were they renamed or moved inside another function?"
} else {
    $harness = @"
$($mClean.Value)
$($mVendor.Value)
$($mValues.Value)
$($mSer.Value)
$($mDup.Value)

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

// ---------------------------------------------------------------------------
// Duplicate pre-fill (brief-drawer-duplicate-row.md)
// ---------------------------------------------------------------------------
const src = Object.assign({}, full, {
  remark: 'second shift',
  windows: [ { hourOfDay: 7,  expectedQty: 2100, receivedQty: 1500 },
             { hourOfDay: 19, expectedQty: 900,  receivedQty: 0 } ]
});
const pre = buildDuplicatePrefill(src);

// carried
check('dup itemCode',         pre.itemCode,         '2063-778193-000');
check('dup description',      pre.description,      'BRACKET ASSY UPPER');
check('dup tag',              pre.tag,              'pcba');
check('dup remark',           pre.remark,           'second shift');
check('dup productFamily',    pre.productFamily,    'FAM-A');
check('dup fromSubInventory', pre.fromSubInventory, 'SUB-FROM');
check('dup toSubInventory',   pre.toSubInventory,   'SUB-TO');
check('dup trialId',          pre.trialId,          'TRIAL-9');
check('dup location',         pre.location,         'LOC-42');
check('dup phase',            pre.phase,            'P3');
check('dup specialControl',   pre.specialControl,   'SPC-1');

// cleared — both halves asserted explicitly
check('dup vendorCode empty', pre.vendorCode, '');
check('dup vendorName empty', pre.vendorName, '');

// Status is not a pre-fill field at all: the create endpoint hard-codes
// 'normal', so a canceled source row cannot duplicate to a canceled one.
check('dup carries no status', pre.status, undefined);
check('dup canceled source carries no status',
      buildDuplicatePrefill(Object.assign({}, src, { status: 'canceled' })).status, undefined);
check('dup canceled source still maps fields',
      buildDuplicatePrefill(Object.assign({}, src, { status: 'canceled' })).itemCode, '2063-778193-000');

// REPLACED ASSERTION, kept visible so the change is legible rather than silent:
//
//     check('dup window qty is zero', pre.windows[0].expectedQty, 0);
//
// An earlier draft carried the source hours with ExpectedQty = 0. Zero already
// means something in this system and it is not "not yet known": isSettled()
// returns true for e <= 0, the console's period status skips such a window and
// reports 'received', and the close gate and pending badge both test
// ExpectedQty > ReceivedQty. A row duplicated at zero would have looked
// finished the moment it existed. The hours carry; the quantities come back
// blank and required, and the pre-fill therefore emits HOURS ONLY.
check('dup hours carry',        pre.hours, [7, 19]);
check('dup emits no quantities', pre.windows, undefined);
check('dup hours sorted',       buildDuplicatePrefill(Object.assign({}, src, {
  windows: [ { hourOfDay: 19, expectedQty: 5 }, { hourOfDay: 7, expectedQty: 5 } ]
})).hours, [7, 19]);
check('dup no windows -> no hours',
      buildDuplicatePrefill(Object.assign({}, src, { windows: [] })).hours, []);

// Em-dash placeholders must not become literal values, same trap as the copy path.
const dashed = buildDuplicatePrefill(Object.assign({}, src, {
  tag: DASH, trialId: DASH, location: DASH, productFamily: null, phase: '   '
}));
check('dup dash tag empty',      dashed.tag,           '');
check('dup dash trial empty',    dashed.trialId,       '');
check('dup dash loc empty',      dashed.location,      '');
check('dup null family empty',   dashed.productFamily, '');
check('dup blank phase empty',   dashed.phase,         '');
if (JSON.stringify(dashed).indexOf(DASH) !== -1) {
  console.log('MISMATCH em-dash present in duplicate pre-fill'); bad++;
}

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
            OK "60 serialiser + duplicate-prefill cases pass — 15 TSV fields in column order with WINDOWS split to 3 raw ints; duplicate carries 11 fields, blanks both vendor halves, emits hours only (no quantities), and never leaks an em-dash"
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
# Case 17 — the duplicate trigger matches its neighbours
# ============================================================================
Case 'Duplicate trigger'

if ($js -notmatch 'data-act="duplicate"')   { Bad "no per-row duplicate trigger" }
elseif ($js -notmatch 'dup-row-btn')        { Bad "duplicate trigger carries no .dup-row-btn hook for the CSS" }
elseif ($js -notmatch 'aria-label="Duplicate row"') { Bad "duplicate trigger has no aria-label" }
else { OK "per-row duplicate trigger present with an aria-label" }

if ($css -notmatch '\.dup-row-btn:focus') {
    Bad "duplicate trigger is revealed on hover only — unreachable by keyboard"
} else { OK "duplicate trigger revealed on :focus, matching its neighbour" }

if ($css -match '(?s)\.dup-row-btn\s*\{[^}]*(display:\s*none|visibility:\s*hidden)') {
    Bad "duplicate trigger hidden with display/visibility — that removes it from the tab order"
} else { OK "hidden via opacity, so it stays in the tab order" }

# §3.4 — duplicate inherits Add Item's gating exactly, which today is "none on
# the client, refused by the server". A client gate added to ONE of them would
# be the drift this asserts against. See docs/defect-add-item-closed-pull-late-refusal.md
if ($js -match "act === 'duplicate'[^\n]*\n[^\n]*(status|closed|disabled)") {
    Bad "duplicate has acquired a client-side gate that Add Item does not have"
} else { OK "duplicate inherits Add Item's gating (server-side only), no second path" }

# ============================================================================
# Case 14b — hours pre-fill, quantities do NOT, and save still requires them
# ============================================================================
Case 'Pre-fill seeds hours only; quantity stays required'

# The pre-filled hour has to actually be selected in the <select>, or the row
# silently comes back as hour 00 and the duplicate lands in the wrong window.
if ($js -notmatch "h === hourOfDay \? ' selected' : ''") {
    Bad "appendAddWindowRow does not mark the pre-filled hour as selected"
} else { OK "pre-filled hour is marked selected in the hour <select>" }

if ($js -notmatch 'prefill\.hours\.forEach\(h => appendAddWindowRow\(h\)\)') {
    Bad "openAddItemModal does not seed one window row per source hour"
} else { OK "one window row seeded per source hour" }

# The quantity input must come back EMPTY. appendAddWindowRow takes an hour and
# nothing else — if it ever grows a qty argument, a zero could reach the form.
if ($js -match 'function appendAddWindowRow\(hourOfDay, ?[a-zA-Z]') {
    Bad "appendAddWindowRow takes a quantity argument — a pre-filled qty (including 0) could reach the form"
} else { OK "appendAddWindowRow takes an hour only; the qty input is always blank" }

# And the save guard that makes it required must still be there.
if ($js -notmatch 'Number\.isNaN\(q\) \|\| q <= 0') {
    Bad "saveAddItem no longer rejects a missing or non-positive window quantity"
} else { OK "saveAddItem still refuses a blank or non-positive quantity" }

if ($view -notmatch 'min="1"' -and $js -notmatch 'min="1"') {
    Bad "the window quantity input lost its min=1"
} else { OK "window quantity input keeps min=1" }

# The server side of the same rule — create stays > 0 while the brief's earlier
# zero-quantity design would have needed it relaxed.
$svcPath = Join-Path $webRoot 'Services\PullItemAdminService.cs'
$svc = Get-Content -Raw -LiteralPath $svcPath
if ($svc -notmatch 'ExpectedQty for hour \{w\.HourOfDay\} must be positive') {
    Bad "the create-path ExpectedQty > 0 rule is gone — a zero-expected window reads as settled everywhere"
} else { OK "create-path ExpectedQty must still be positive" }

$dtoPath = Join-Path $webRoot 'Models\Dtos\PullItemDtos.cs'
$dto = Get-Content -Raw -LiteralPath $dtoPath
# Scoped to the CREATE class body, not the whole file. PullItemDtos.cs holds
# several DTOs carrying these same field names — the Phase 9.1 extended-fields
# request among them — so a file-wide search still matches after the field is
# deleted from PullItemCreateRequest, which is exactly the regression this is
# supposed to catch.
$createBlock = [regex]::Match($dto, '(?s)public class PullItemCreateRequest\s*\{.*?\n\}')
if (-not $createBlock.Success) {
    Bad "could not locate the PullItemCreateRequest class body"
} else {
    $missing = @()
    foreach ($fld in @('ProductFamily','FromSubInventory','ToSubInventory','SpecialControl','TrialId','Location','Phase')) {
        if ($createBlock.Value -notmatch "public string\? $fld \{ get; set; \}") { $missing += $fld }
    }
    if ($missing.Count -gt 0) {
        Bad "PullItemCreateRequest is missing $($missing -join ', ') — a duplicate would drop those fields silently"
    } else { OK "PullItemCreateRequest carries all seven Phase 9.1 fields" }
}

# The service must actually PERSIST them. A DTO that carries a field the INSERT
# ignores is the same silent loss with an extra step, and it was the shape of
# the v3.2 firstRow.* vendor defect.
foreach ($col in @('ProductFamily','FromSubInventory','ToSubInventory','SpecialControl','TrialId','Location','[Phase]')) {
    if ($svc -notmatch [regex]::Escape($col)) {
        Bad "PullItemAdminService's create INSERT does not name $col"
    }
}
OK "the create INSERT names all seven ERP columns"

# §2.4 — asserted at SOURCE as well as end-to-end. The live check hits a running
# server, which keeps serving the previously-built DLL, so a source-only change
# to this message would pass the behavioural check until the next restart.
if ($svc -notmatch 'Set a storer \(vendor code\) to tell the two rows apart') {
    Bad "the blank-vendor 409 no longer names the storer field as the thing to change"
} else { OK "blank-vendor 409 names the storer field (source)" }
if ($svc -notmatch 'Change the storer to add another row for this item') {
    Bad "the named-vendor 409 no longer says what to change"
} else { OK "named-vendor 409 says what to change (source)" }

# ============================================================================
# Cases 11-16 — end to end through the real create path
# ============================================================================
Case 'Duplicate end-to-end'

$serverUp = $false
try {
    $p0 = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $serverUp = ($p0.StatusCode -in @(200, 401))
} catch {
    $sc = $null
    try { $sc = $_.Exception.Response.StatusCode.value__ } catch { }
    $serverUp = ($sc -in @(200, 401))
}

if (-not $serverUp) {
    Note "dev server not responding — end-to-end duplicate cases skipped"
} else {
    $sv = $null
    $loginBody = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $loginBody `
        -ContentType 'application/json' -SessionVariable sv | Out-Null

    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString().Substring(6)
    $pullNum = "PL-DUP-$stamp"
    $poNum   = "PO-DUP-$stamp"
    $sku     = "DUP-SKU-$stamp"

    function SqlQ($q) { sqlcmd -S 'LAPTOP-CSB3KO3E' -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; $q" 2>&1 }
    function Cleanup {
        SqlQ @"
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId WHERE p.PullNumber LIKE 'PL-DUP-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-DUP-%';
DELETE pol FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId WHERE po.PoNumber LIKE 'PO-DUP-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-DUP-%';
"@ | Out-Null
    }
    Cleanup

    try {
        # PO capacity for the SKU, so the duplicated row can actually be received.
        $poBody = @{
            poNumber=$poNum; warehouseId=$WH_01; orderDate=(Get-Date -Format 'yyyy-MM-dd')
            expectedDate=$null; notes='duplicate-row smoke'; pullId=$null
            lines=@(@{ lineNumber=1; itemCode=$sku; description='dup smoke'; orderedQty=100000; vendorCode='STORER-B' })
        } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri "$base/api/pos" -Method POST -Body $poBody -ContentType 'application/json' -WebSession $sv | Out-Null

        $pullBody = @{
            pullNumber=$pullNum; warehouseId=$WH_01; pullDate=(Get-Date -Format 'yyyy-MM-dd')
            eta=$null; notes=$null; lockPoByPull=$false; lockHourCap=$false
        } | ConvertTo-Json
        $pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv

        # The SOURCE row, carrying all seven ERP fields — the ones a duplicate exists to keep.
        $srcBody = @{
            itemCode=$sku; description='SOURCE ROW'; vendorCode='STORER-A'; vendorName='Storer A'
            tag='pcba'; remark='source remark'
            productFamily='FAM-D'; fromSubInventory='SUB-F'; toSubInventory='SUB-T'
            specialControl='SPC-D'; trialId='TRIAL-D'; location='LOC-D'; phase='P9'
            windows=@(@{ hourOfDay=7; expectedQty=500 }, @{ hourOfDay=19; expectedQty=300 })
        } | ConvertTo-Json -Depth 5
        $srcItem = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST `
            -Body $srcBody -ContentType 'application/json' -WebSession $sv

        # The seven fields must round-trip on CREATE, not via a follow-up call.
        $srcFetched = (Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method GET -WebSession $sv) |
            Where-Object { $_.id -eq $srcItem.id }
        $erpOk = $srcFetched.productFamily -eq 'FAM-D' -and $srcFetched.fromSubInventory -eq 'SUB-F' -and
                 $srcFetched.toSubInventory -eq 'SUB-T' -and $srcFetched.specialControl -eq 'SPC-D' -and
                 $srcFetched.trialId -eq 'TRIAL-D' -and $srcFetched.location -eq 'LOC-D' -and $srcFetched.phase -eq 'P9'
        if (-not $erpOk) { Bad "the seven ERP fields did not round-trip through POST /items" }
        else { OK "all seven ERP fields persist through a single atomic create" }

        $countBefore = (Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method GET -WebSession $sv).Count

        # --- 7. duplicate, change the storer, save -------------------------------
        # Exactly the payload the client builds from buildDuplicatePrefill: carried
        # fields, blank vendor replaced by the operator, hours carried, quantities
        # typed by the operator.
        $dupBody = @{
            itemCode=$sku; description='SOURCE ROW'; vendorCode='STORER-B'; vendorName='Storer B'
            tag='pcba'; remark='source remark'
            productFamily='FAM-D'; fromSubInventory='SUB-F'; toSubInventory='SUB-T'
            specialControl='SPC-D'; trialId='TRIAL-D'; location='LOC-D'; phase='P9'
            windows=@(@{ hourOfDay=7; expectedQty=120 }, @{ hourOfDay=19; expectedQty=80 })
        } | ConvertTo-Json -Depth 5
        $dupItem = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST `
            -Body $dupBody -ContentType 'application/json' -WebSession $sv

        $after = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method GET -WebSession $sv
        if ($after.Count -ne $countBefore + 1) { Bad "item count went $countBefore -> $($after.Count); expected +1" }
        else { OK "duplicate created exactly one new item" }

        $srcAfter = $after | Where-Object { $_.id -eq $srcItem.id }
        $srcUnchanged = $srcAfter.vendorCode -eq 'STORER-A' -and $srcAfter.description -eq 'SOURCE ROW' -and
                        $srcAfter.trialId -eq 'TRIAL-D' -and $srcAfter.status -eq 'normal' -and
                        (($srcAfter.windows | Measure-Object -Property expectedQty -Sum).Sum -eq 800)
        if (-not $srcUnchanged) { Bad "the source row changed when its duplicate was created" }
        else { OK "source row unchanged in every field, including its window quantities" }

        $dupFetched = $after | Where-Object { $_.id -eq $dupItem.id }
        $dupHours = ($dupFetched.windows | ForEach-Object { $_.hourOfDay } | Sort-Object) -join ','
        if ($dupHours -ne '7,19') { Bad "duplicate hours are '$dupHours'; expected '7,19'" }
        else { OK "duplicate carries the source hours (7, 19) with operator-typed quantities" }
        if ($dupFetched.trialId -ne 'TRIAL-D' -or $dupFetched.location -ne 'LOC-D') {
            Bad "duplicate lost the ERP fields that justified making it"
        } else { OK "duplicate carries the ERP fields" }

        # --- 8. blank-vendor duplicate collides, and the 409 says what to change --
        $blankBody = @{
            itemCode="$sku-NOVENDOR"; description='NO VENDOR'; windows=@(@{ hourOfDay=7; expectedQty=10 })
        } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST `
            -Body $blankBody -ContentType 'application/json' -WebSession $sv | Out-Null
        $countPreCollide = (Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method GET -WebSession $sv).Count

        $collided = $false; $msg = ''
        try {
            Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST `
                -Body $blankBody -ContentType 'application/json' -WebSession $sv | Out-Null
        } catch {
            $collided = $true
            $resp = $_.ErrorDetails.Message
            if ($resp) { try { $msg = ($resp | ConvertFrom-Json).title } catch { $msg = $resp } }
        }
        if (-not $collided) { Bad "a blank-vendor duplicate of an existing row was accepted — the guard is gone" }
        else { OK "blank-vendor duplicate refused by the existing guard" }
        if ($msg -notmatch 'storer') {
            Bad "the 409 does not name the storer field as the thing to change: '$msg'"
        } else { OK "409 names the storer field: '$msg'" }
        $countPostCollide = (Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method GET -WebSession $sv).Count
        if ($countPostCollide -ne $countPreCollide) { Bad "the refused duplicate still created a row" }
        else { OK "no row created by the refused duplicate" }

        # --- 16. the defect this design avoids -----------------------------------
        # A duplicated row, completed normally, must receive like any other row: no
        # variance, no reason code. Had the duplicate carried ExpectedQty = 0, this
        # receipt would have been an over-delivery (outstanding = 0), refused with
        # OVER_RECEIPT_NOT_ACCEPTED unless the operator ticked accept-variance, and
        # recorded forever as a variance with a reason code.
        $recvBody = @{
            pullId=$pull.id; pullItemId=$dupItem.id; hourOfDay=7; qty=120
        } | ConvertTo-Json
        $recvOk = $false; $recvErr = ''
        try {
            Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $recvBody `
                -ContentType 'application/json' -WebSession $sv | Out-Null
            $recvOk = $true
        } catch {
            $recvErr = $_.ErrorDetails.Message
        }
        if (-not $recvOk) {
            Bad "receiving the duplicated row's full quantity failed — it should be an ordinary receipt: $recvErr"
        } else { OK "duplicated row receives as an ordinary row (no variance tick needed)" }

        $varCount = (SqlQ @"
SELECT COUNT(*) FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
WHERE pi.Id = '$($dupItem.id)' AND (r.VarianceAccepted = 1 OR r.VarianceQty IS NOT NULL);
"@) -join '' -replace '\s',''
        if ($varCount -ne '0') {
            Bad "the duplicated row's first receipt was recorded as a variance ($varCount row(s)) — this is the zero-quantity defect"
        } else { OK "no variance and no reason code on the duplicated row's first receipt" }
    }
    finally { Cleanup }
}

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
Write-Host "ALL PASS — $($script:pass) checks across maximize, copy-row and duplicate-row." -ForegroundColor Green
exit 0
