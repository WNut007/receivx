# Smoke test: the ADD ITEM button is bound through a wrapper, not bare.
#
# The defect this exists to prevent: openAddItemModal was registered as a bare
# listener --
#
#     document.getElementById('d-add-item')?.addEventListener('click', openAddItemModal);
#
# so the DOM passed its PointerEvent in as the 'prefill' argument. An Event is
# truthy, so every "prefill ? prefill.x : ''" read pulled undefined off the event
# and prefill.hours.length threw. By then the modal's inputs had already been
# written with event-derived values and itemAddModal.show() was never reached:
# the button looked completely inert, with no toast and no console line beyond
# the TypeError. Diagnosing that cost a full session.
#
# Source-level by necessity for the binding (a listener registration cannot be
# observed without a browser), but the FUNCTION itself is executed in node per
# docs/smoke-conventions.md section 3 -- the harness calls the shipped
# openAddItemModal with a real Event and asserts the form comes up blank.
#
# What's verified:
#
#   1. openAddItemModal appears nowhere as a bare function reference -- not as an
#      addEventListener argument, not as an .onclick assignment, and not inside
#      an onclick="..." attribute -- in either dashboard.js or
#      Views/Dashboard/Index.cshtml. This is the guard the defect earns.
#   2. The d-add-item listener still EXISTS and goes through an arrow wrapper.
#      Without this half, deleting the binding outright would pass case 1.
#   3. The button that listener targets is still in the markup.
#   4. The Event -> null normalisation sits ahead of the guards, so a future
#      re-binding degrades to the empty form instead of throwing.
#   5. The three preconditions each announce themselves (console.warn), and the
#      two a user can actually reach also raise a toast.
#   6. The hours branch is Array.isArray(prefill?.hours), not prefill.hours.
#   7-11. Executed in node: an Event argument yields a blank form with one empty
#      window row and the modal shown; a real prefill still seeds every field and
#      carries its hours; a prefill missing hours falls through instead of
#      throwing; no-pull-selected and pull-not-found both warn, toast, and leave
#      the modal shut.
#
# Needs node on PATH. Touches no database and no dev server -- nothing to clean up.

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot  = Join-Path $repoRoot 'src\ReceivingOps.Web'
$jsPath   = Join-Path $webRoot 'wwwroot\js\dashboard.js'
$viewPath = Join-Path $webRoot 'Views\Dashboard\Index.cshtml'

$script:pass = 0
$script:fail = 0
function Case($n) { Write-Host "`n=== $n ===" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  PASS: $m" -ForegroundColor Green; $script:pass++ }
function Bad($m)  { Write-Host "  FAIL: $m" -ForegroundColor Red;   $script:fail++ }

foreach ($f in @($jsPath, $viewPath)) {
    if (-not (Test-Path $f)) { Write-Host "FAIL: missing $f" -ForegroundColor Red; exit 1 }
}
$js   = Get-Content -Raw -LiteralPath $jsPath
$view = Get-Content -Raw -LiteralPath $viewPath

# ============================================================================
# Case 1 -- no bare openAddItemModal reference anywhere
# ============================================================================
Case 'openAddItemModal is never handed to the DOM bare'

# Three shapes, all of which make the DOM supply the event as the first argument.
# The addEventListener pattern allows any event name and any trailing options
# argument on purpose, so addEventListener('click', openAddItemModal, {once:true})
# is caught too.
$barePatterns = @(
    @{ name = 'addEventListener listener argument'
       rx   = 'addEventListener\s*\(\s*[''"][^''"]+[''"]\s*,\s*openAddItemModal\s*[,)]' },
    @{ name = 'onclick property assignment'
       rx   = '\.onclick\s*=\s*openAddItemModal\b' },
    @{ name = 'onclick HTML attribute'
       rx   = 'onclick\s*=\s*[''"][^''"]*openAddItemModal' }
)

$bareHits = @()
foreach ($file in @(@{ p = $jsPath; s = $js }, @{ p = $viewPath; s = $view })) {
    $lines = $file.s -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($pat in $barePatterns) {
            if ($lines[$i] -match $pat.rx) {
                $bareHits += "$($file.p):$($i + 1) [$($pat.name)]: $($lines[$i].Trim())"
            }
        }
    }
}
if ($bareHits.Count -gt 0) {
    $detail = ($bareHits | ForEach-Object { '    ' + $_ }) -join [Environment]::NewLine
    Bad ('openAddItemModal is bound bare -- the DOM will pass a PointerEvent in as prefill:' +
         [Environment]::NewLine + $detail + [Environment]::NewLine +
         "    Fix: wrap it -- addEventListener('click', () => openAddItemModal())")
} else {
    OK 'no bare openAddItemModal reference in dashboard.js or Views/Dashboard/Index.cshtml'
}

# ============================================================================
# Case 2 -- the binding still exists, through a wrapper
# ============================================================================
Case 'The d-add-item listener exists and wraps the call'
$wrapped = 'getElementById\(\s*[''"]d-add-item[''"]\s*\)\s*\??\.\s*addEventListener\(\s*[''"]click[''"]\s*,\s*\(\s*\)\s*=>\s*openAddItemModal\('
if ($js -match $wrapped) {
    OK 'd-add-item click goes through an arrow wrapper: () => openAddItemModal()'
} else {
    Bad 'no arrow-wrapped d-add-item click listener found in dashboard.js -- case 1 passes vacuously if the binding was simply deleted'
}

# ============================================================================
# Case 3 -- the button is still in the markup
# ============================================================================
Case 'The ADD ITEM button is still rendered'
if ($view -match 'id\s*=\s*"d-add-item"') {
    OK 'Views/Dashboard/Index.cshtml renders #d-add-item'
} else {
    Bad 'Views/Dashboard/Index.cshtml no longer renders #d-add-item -- the listener above has no target'
}

# ============================================================================
# Cases 4-6 -- the function's own defences
# ============================================================================
Case 'openAddItemModal normalises and announces'
$mFn = [regex]::Match($js, '(?s)\n  function openAddItemModal\(prefill\) \{.*?\n  \}')
if (-not $mFn.Success) {
    Bad 'could not extract openAddItemModal from dashboard.js -- was it renamed or moved inside another function?'
} else {
    $fn = $mFn.Value

    # Ordering matters, not mere presence: the normalisation has to run before
    # the first guard, and the assertion is scoped to this function body so a
    # sibling carrying the same line cannot keep it green.
    $mOrder = [regex]::Match($fn, '(?s)function openAddItemModal\(prefill\) \{(.*?)if \(!itemAddModal\)')
    if ($mOrder.Success -and $mOrder.Groups[1].Value -match 'if \(prefill instanceof Event\) prefill = null;') {
        OK 'the Event -> null normalisation runs ahead of the guards'
    } else {
        Bad 'openAddItemModal does not normalise an Event argument to null before its guards'
    }

    $guards = @(
        @{ label = '!itemAddModal';    rx = '(?s)if \(!itemAddModal\) \{.*?console\.warn\(' },
        @{ label = '!selectedPullId';  rx = '(?s)if \(!selectedPullId\) \{.*?console\.warn\(.*?showToast\(' },
        @{ label = '!p (pull lookup)'; rx = '(?s)if \(!p\) \{.*?console\.warn\(.*?showToast\(' }
    )
    foreach ($g in $guards) {
        if ($fn -match $g.rx) { OK "precondition $($g.label) is observable" }
        else { Bad "precondition $($g.label) returns silently -- a dead button with no signal" }
    }

    if ($fn -match 'if \(Array\.isArray\(prefill\?\.hours\) && prefill\.hours\.length\)') {
        OK 'the hours branch tests Array.isArray(prefill?.hours) before reading .length'
    } else {
        Bad 'the hours branch does not guard prefill?.hours with Array.isArray -- a prefill without hours throws'
    }

    # ========================================================================
    # Cases 7-11 -- run the shipped function in node
    # ========================================================================
    Case 'openAddItemModal executed in node against a stub DOM'
    $harness = @"
// Stubs stand in for the closure the function lives in. Everything it touches is
// declared here; if it grows a new dependency this harness fails loudly rather
// than silently testing less.
if (typeof globalThis.Event === 'undefined') {
  globalThis.Event = class Event { constructor(t) { this.type = t; } };
}

let els = {};
function el(id) {
  if (!els[id]) els[id] = { id, value: '', textContent: '', innerHTML: '' };
  return els[id];
}
const document = { getElementById: el };

let shown = 0;
const itemAddModal = { show: () => { shown++; } };
let selectedPullId = 'pull-1';
const pulls = [{ pullId: 'pull-1', id: 'PL-9999' }];
let drawerPullIdForItems = null;
let erpPrefill = null;
let toasts = [];
function showToast(m, s) { toasts.push(m); }
let windowRows = [];
function appendAddWindowRow(h) { windowRows.push(h); }
let warns = [];
console.warn = (...a) => warns.push(a.map(String).join(' '));

function reset() {
  els = {}; shown = 0; toasts = []; windowRows = []; warns = [];
  selectedPullId = 'pull-1'; drawerPullIdForItems = null; erpPrefill = null;
}

$($mFn.Value)

let bad = 0;
function check(label, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) { console.log('MISMATCH ' + label + ': got ' + a + ' want ' + e); bad++; }
}

// --- 7. the defect itself: a PointerEvent must not become a prefill ---------
reset();
try {
  openAddItemModal(new Event('click'));
} catch (err) {
  console.log('MISMATCH event arg threw: ' + err.message); bad++;
}
check('event: modal shown',       shown,                       1);
check('event: item code blank',   el('iam-item-code').value,   '');
check('event: description blank', el('iam-description').value, '');
check('event: tag blank',         el('iam-tag').value,         '');
check('event: remark blank',      el('iam-remark').value,      '');
check('event: vendor code blank', el('iam-vendor-code').value, '');
// appendAddWindowRow() with no argument -- JSON renders the undefined as null.
check('event: one empty window',  windowRows,                  [null]);
check('event: no erp prefill',    erpPrefill,                  null);
check('event: no warnings',       warns,                       []);

// --- 8. the duplicate path still works -------------------------------------
reset();
openAddItemModal({ itemCode: 'ABC-1', description: 'BRACKET', tag: 'pcba', remark: 'RM', hours: [7, 19] });
check('dup: modal shown',       shown,                       1);
check('dup: item code seeded',  el('iam-item-code').value,   'ABC-1');
check('dup: description',       el('iam-description').value, 'BRACKET');
check('dup: tag',               el('iam-tag').value,         'pcba');
check('dup: remark',            el('iam-remark').value,      'RM');
check('dup: hours carried',     windowRows,                  [7, 19]);
// Both vendor halves stay blank prefill or not -- see buildDuplicatePrefill.
check('dup: vendor code blank', el('iam-vendor-code').value, '');
check('dup: vendor name blank', el('iam-vendor-name').value, '');

// --- 9. a prefill missing hours falls through, it does not throw ------------
reset();
try {
  openAddItemModal({ itemCode: 'ABC-2', description: 'D', tag: '', remark: '' });
} catch (err) {
  console.log('MISMATCH prefill without hours threw: ' + err.message); bad++;
}
check('no-hours: modal shown',       shown,                     1);
check('no-hours: one empty window',  windowRows,                [null]);
check('no-hours: code still seeded', el('iam-item-code').value, 'ABC-2');
// An empty hours array takes the same branch.
reset();
openAddItemModal({ itemCode: 'ABC-3', description: '', tag: '', remark: '', hours: [] });
check('empty-hours: one empty window', windowRows, [null]);

// --- 10. no pull selected: warn + toast, modal stays shut -------------------
reset();
selectedPullId = null;
openAddItemModal();
check('no-pull: modal not shown', shown,         0);
check('no-pull: toasted',         toasts.length, 1);
if (!warns.some(w => w.indexOf('[add-item]') === 0)) {
  console.log('MISMATCH no-pull: no [add-item] console.warn'); bad++;
}

// --- 11. selected pull absent from the loaded list -------------------------
reset();
selectedPullId = 'pull-missing';
openAddItemModal();
check('missing-pull: modal not shown', shown,         0);
check('missing-pull: toasted',         toasts.length, 1);
if (!warns.some(w => w.indexOf('[add-item]') === 0)) {
  console.log('MISMATCH missing-pull: no [add-item] console.warn'); bad++;
}

console.log(bad === 0 ? 'ADDITEM_OK' : 'ADDITEM_FAIL');
"@

    $tmpJs = Join-Path $env:TEMP "add-item-binding-$([guid]::NewGuid().ToString('N')).js"
    try {
        Set-Content -LiteralPath $tmpJs -Value $harness -Encoding UTF8
        $nodeOut = & node $tmpJs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Bad "node failed to run the openAddItemModal harness: $nodeOut"
        } elseif ($nodeOut -match 'MISMATCH') {
            Bad "openAddItemModal behaved unexpectedly: $(($nodeOut | Where-Object { $_ -match 'MISMATCH' }) -join ' | ')"
        } elseif ($nodeOut -match 'ADDITEM_OK') {
            OK 'an Event argument opens a blank form with one empty window row; the duplicate prefill still seeds every field and carries its hours; a prefill without hours falls through; both reachable preconditions warn, toast and leave the modal shut'
        } else {
            Bad "unexpected harness output: $nodeOut"
        }
    } finally {
        Remove-Item -LiteralPath $tmpJs -ErrorAction SilentlyContinue
    }
}

# ============================================================================
Write-Host ""
if ($script:fail -gt 0) {
    Write-Host "FAILED -- $($script:pass) passed, $($script:fail) failed." -ForegroundColor Red
    exit 1
}
Write-Host "ALL PASS -- $($script:pass) checks across the ADD ITEM binding and openAddItemModal's guards." -ForegroundColor Green
exit 0
