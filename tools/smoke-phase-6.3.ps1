# Smoke test: v2.1 Phase 6.3 — Items grid in Pull drawer (UI)
#
# 6.1 + 6.2 cover the API surface. 6.3 verifies the served files carry the
# new UI wiring + that the /Dashboard page loads cleanly for a manager
# (warm cache check that nothing else regressed).
#
# Source landmarks checked here:
#   - Index.cshtml has the items section + 3 modals (itemAddModal, itemEditModal,
#     windowsModal) + the relevant input ids each modal needs
#   - dashboard.css has the .items-table / .items-empty / wm-add-windows-table /
#     windows-list-table rules
#   - dashboard.js has loadItemsForDrawer + renderItemsTable + the modal
#     open/save handlers + delegated row actions
#   - The drawer's openDrawer fires loadItemsForDrawer so the grid actually
#     populates (catch-all that the wire-up edit landed)
#
# Live: GET /Dashboard returns 200 for a CanManagePulls user (sadmin / WH-01).
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# ----------------------------------------------------------------------------
# 1. Razor view: items section + 3 modals
# ----------------------------------------------------------------------------
Step "Index.cshtml carries items section + 3 modals + every input id"
$razor = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Dashboard\Index.cshtml' -Raw
foreach ($needle in @(
    # items grid landmarks
    'id="d-add-item"',
    'id="d-items-tbody"',
    'id="d-items-empty"',
    'id="d-items-table"',
    'id="d-items-count"',
    # add-item modal
    'id="itemAddModal"',
    'id="iam-item-code"',
    'id="iam-description"',
    'id="iam-vendor-code"',
    'id="iam-vendor-name"',
    'id="iam-tag"',
    'id="iam-remark"',
    'id="iam-windows-tbody"',
    'id="iam-add-window"',
    'id="iam-save"',
    # edit-item modal
    'id="itemEditModal"',
    'id="iem-code-label"',
    'id="iem-description"',
    'id="iem-vendor-code"',
    'id="iem-vendor-name"',
    'id="iem-tag"',
    'id="iem-status"',
    'id="iem-remark"',
    'id="iem-save"',
    # windows modal
    'id="windowsModal"',
    'id="wm-code-label"',
    'id="wm-tbody"',
    'id="wm-new-hour"',
    'id="wm-new-qty"',
    'id="wm-add"'
)) {
    if ($razor -notmatch [regex]::Escape($needle)) { Fail "Index.cshtml missing $needle" }
}
OK "Razor view carries every 6.3 landmark"

# ----------------------------------------------------------------------------
# 2. CSS: items-table + windows tables + tag badges + empty state
# ----------------------------------------------------------------------------
Step "dashboard.css carries 6.3 rules"
$css = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\dashboard.css' -Raw
foreach ($rule in @(
    '.items-table',
    '.items-table-wrap',
    '.items-table .actions-col',
    '.items-table .badge.tag-pcba',
    '.items-table .badge.tag-swap',
    '.items-empty',
    '.wm-add-windows-table',
    '.windows-list-table'
)) {
    if ($css -notmatch [regex]::Escape($rule)) { Fail "dashboard.css missing $rule" }
}
OK "dashboard.css has every 6.3 rule"

# ----------------------------------------------------------------------------
# 3. JS: data path + render + 3 modal flows + drawer-open wire-up
# ----------------------------------------------------------------------------
Step "dashboard.js carries the wire-up + render + 4 CRUD flows"
$js = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\dashboard.js' -Raw
# All patterns are literal substrings — regex-escape each one so JS parens,
# brackets, and quotes don't get interpreted as regex syntax.
foreach ($needle in @(
    # drawer-open lazy load
    'loadItemsForDrawer(pullGuid)',
    'function loadItemsForDrawer',
    'function renderItemsTable',
    # 3 modal handles
    "getElementById('itemAddModal')",
    "getElementById('itemEditModal')",
    "getElementById('windowsModal')",
    # delegated row actions (rendered HTML uses double-quoted attrs)
    'data-act="windows"',
    'data-act="edit"',
    'data-act="delete"',
    # delegated handler dispatch
    "act === 'edit'",
    "act === 'delete'",
    "act === 'windows'",
    # CRUD functions
    'function openAddItemModal',
    'function saveAddItem',
    'function openEditItemModal',
    'function saveEditItem',
    'function deleteItem',
    'function openWindowsModal',
    'function renderWindowsTable',
    'function refreshWindowsModal',
    # HTTP verbs hit by each flow
    "method: 'POST'",
    "method: 'PUT'",
    "method: 'DELETE'",
    # Endpoint shapes
    "'/items/'",
    '/windows/'
)) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "dashboard.js missing pattern: $needle" }
}
OK "dashboard.js has every wire-up landmark"

# ----------------------------------------------------------------------------
# 4. Live: login + GET /Dashboard returns 200 (smoke for regressions)
# ----------------------------------------------------------------------------
Step "Login sadmin / WH-01 + GET /Dashboard → 200"
$body = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null

$page = Invoke-WebRequest -Uri "$base/Dashboard" -Method GET -WebSession $sv -UseBasicParsing
if ($page.StatusCode -ne 200) { Fail "Dashboard returned $($page.StatusCode)" }
$html = $page.Content
foreach ($mustExist in @('id="d-items-tbody"', 'id="itemAddModal"', 'id="iem-save"', 'id="windowsModal"')) {
    if ($html -notmatch [regex]::Escape($mustExist)) { Fail "Rendered Dashboard missing $mustExist (Razor compile fell behind?)" }
}
OK "Dashboard 200 + every modal id present in served HTML"

Write-Host ""
Write-Host "ALL PASS — Phase 6.3 items-grid UI wired into the Pull drawer." -ForegroundColor Green
exit 0
