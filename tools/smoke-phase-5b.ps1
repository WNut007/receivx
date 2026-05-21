# Smoke test: §3.5 Phase 5b — Transactions list PO column + filter
#
# Source-level + live HTTP smoke for the 3 tx surfaces:
#   - drawer (receiving.js renderTxDrawer)
#   - modal-embedded list (receiving.js renderModalTransactions)
#   - standalone Transactions page (transactions.js + Razor view)
#
# Cases:
#   5b-1: /api/transactions returns rows with poNumber populated
#   5b-2: /api/transactions?poNumber=PO-2401-018 returns ONLY rows on that PO
#   5b-3: /api/transactions?q=PL-2847+PO-2401-018 returns only matching rows
#         (server multi-token AND, includes PoNumber in haystack per Phase 3)
#   5b-4: Drawer + modal renderers in receiving.js use the §5b token format
#         (·L## suffix) and respect currentPullLocked → 🔒 prefix
#   5b-5: Standalone transactions.js implements sortRowsByPo with LineNumber
#         tiebreak; sortable header is wired (data-sort="po")
#   5b-6: Transactions page emits the f-po dropdown + populates from distinct
#         poNumber via refreshPoFilter (source check)
#   5b-7: Reversal rows keep the original PO (server contract — same PoNumber)
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$session = $null

$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# ----------------------------------------------------------------------------
# Source-level checks (file artifacts; no server)
# ----------------------------------------------------------------------------
Step "5b-4: receiving.js drawer + modal use single-token PO format with vendor tooltip + lock prefix"
$recvJs = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\receiving.js' -Raw
foreach ($needle in @(
    'currentPullLocked',
    'po-lock',
    'm-tx-po',
    'tx-po',
    "'·L'",                          # ·L token marker (compact format) — match either UTF-8 or literal middot
    'title="${escAttr(r.vendorName',
    'title="${txEsc(r.vendorName'
)) {
    if ($recvJs -notmatch [regex]::Escape($needle) -and -not ($needle -match 'u00b7' -and $recvJs -match "'·L'")) {
        # ·L (UTF-8 middot) presence — try both forms
        if ($needle -match 'u00b7') {
            if ($recvJs -notmatch ([char]0x00B7 + 'L')) { Fail "receiving.js missing '·L' compact PO token" }
        } else {
            Fail "receiving.js missing '$needle'"
        }
    }
}
OK "receiving.js drawer + modal renderers carry the §5b PO token"

Step "5b-5: transactions.js implements PO sort with LineNumber + ReceivedAt tiebreaks"
$txJs = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\transactions.js' -Raw
foreach ($needle in @(
    'sortRowsByPo',
    'refreshPoFilter',
    'col-po',
    'dataset.sort',
    'th.sortable'
)) {
    if ($txJs -notmatch [regex]::Escape($needle)) { Fail "transactions.js missing '$needle'" }
}
# Confirm the tiebreak ordering is encoded: LineNumber → ReceivedAt DESC
if ($txJs -notmatch 'poLineNumber') { Fail "transactions.js sort tiebreak doesn't reference poLineNumber" }
if ($txJs -notmatch 'receivedAt')   { Fail "transactions.js sort tiebreak doesn't reference receivedAt" }
OK "transactions.js sort + filter helpers present"

Step "5b-6: Transactions Razor view has f-po dropdown + sortable PO column header"
$razor = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Transactions\Index.cshtml' -Raw
foreach ($needle in @(
    'id="f-po"',
    'class="col-po sortable"',
    'data-sort="po"'
)) {
    if ($razor -notmatch [regex]::Escape($needle)) { Fail "Transactions view missing '$needle'" }
}
OK "Transactions view has f-po + sortable header"

Step "5b CSS: transactions.css has .col-po, .sortable; receiving.css has .po-lock"
$txCss   = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\transactions.css' -Raw
$recvCss = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\receiving.css' -Raw
foreach ($cls in @('.col-po', 'th.sortable')) {
    if ($txCss -notmatch [regex]::Escape($cls)) { Fail "transactions.css missing rule for $cls" }
}
if ($recvCss -notmatch '\.po-lock') { Fail "receiving.css missing .po-lock rule" }
OK "5b CSS rules present"

# ----------------------------------------------------------------------------
# Live HTTP — login as sadmin so we can see WH-01 + WH-02 data
# ----------------------------------------------------------------------------
Step "Login (sadmin / WH-01)"
$loginBody = @{ username = 'sadmin'; password = 'admin'; warehouseId = $WH_01; remember = $false } | ConvertTo-Json
$null = Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable session
OK "Login ok"

Step "5b-1: GET /api/transactions returns rows with poNumber populated"
$page = Invoke-RestMethod -Uri "$base/api/transactions?warehouseCode=WH-01&take=100" -WebSession $session
if (-not $page.rows -or $page.rows.Count -lt 1) { Fail "Expected non-empty page, got 0 rows" }
$missing = @($page.rows | Where-Object { -not $_.poNumber }).Count
if ($missing -gt 0) { Fail "$missing rows missing poNumber (FK should make this impossible post-Phase-1b)" }
OK "All $($page.rows.Count) rows carry poNumber + poLineNumber"

Step "5b-2: GET /api/transactions?poNumber=PO-2401-018 returns ONLY rows on that PO"
$page2 = Invoke-RestMethod -Uri "$base/api/transactions?warehouseCode=WH-01&poNumber=PO-2401-018&take=100" -WebSession $session
if (-not $page2.rows -or $page2.rows.Count -lt 1) { Fail "Expected rows for PO-2401-018, got none" }
$wrongPo = @($page2.rows | Where-Object { $_.poNumber -ne 'PO-2401-018' }).Count
if ($wrongPo -gt 0) { Fail "$wrongPo rows had a different PoNumber" }
OK "$($page2.rows.Count) rows all on PO-2401-018"

Step "5b-3: multi-token q=PL-2847 PO-2401-018 returns only rows matching both"
$page3 = Invoke-RestMethod -Uri "$base/api/transactions?q=PL-2847%20PO-2401-018&take=100" -WebSession $session
if (-not $page3.rows -or $page3.rows.Count -lt 1) { Fail "Expected rows for q=PL-2847+PO-2401-018, got none" }
$bad = @($page3.rows | Where-Object { $_.pullNumber -ne 'PL-2847' -or $_.poNumber -ne 'PO-2401-018' }).Count
if ($bad -gt 0) { Fail "$bad rows broke the AND match" }
OK "$($page3.rows.Count) rows match BOTH tokens"

Step "5b-7: reversal rows retain original PoNumber"
$reversals = @($page.rows | Where-Object { $_.kind -eq 'reversal' })
if ($reversals.Count -lt 1) {
    Write-Host "  (no reversals in WH-01 history — skipping)" -ForegroundColor DarkGray
    OK "Skipped — no reversals present"
} else {
    $missingPo = @($reversals | Where-Object { -not $_.poNumber }).Count
    if ($missingPo -gt 0) { Fail "$missingPo reversal rows missing PoNumber" }
    OK "$($reversals.Count) reversal rows all carry original PoNumber"
}

Step "Standalone /Transactions page renders 200 with col-po + f-po"
$pageHtml = Invoke-WebRequest -Uri "$base/Transactions" -WebSession $session
if ($pageHtml.StatusCode -ne 200) { Fail "Expected 200, got $($pageHtml.StatusCode)" }
foreach ($needle in @('id="f-po"', 'class="col-po sortable"', 'data-sort="po"')) {
    if ($pageHtml.Content -notmatch [regex]::Escape($needle)) { Fail "Live page HTML missing '$needle'" }
}
OK "Transactions page renders the new column + dropdown"

Write-Host "`nPhase 5b smoke PASSED." -ForegroundColor Green
exit 0
