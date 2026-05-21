# Phase 5 verifier — Stage B frontend wiring per v2 §9.3.
# Confirms:
#   1. receive-mockup markup has new alloc-preview slots
#   2. receiving.css carries the new .alloc-preview / .cap-hint.warn / .m-tx-po / .tx-po styles
#   3. receiving.js exposes refreshAllocationPreview + hideAllocPanel + handles allocations[]
#      + maps poNumber/poLineNumber/vendorName into txCache
#   4. transactions.js renders the .po-badge sub-line; transactions.css carries .po-badge
#   5. GET /api/receipts/preview HTTP endpoint round-trips (single-line + split + shortage)
#   6. End-to-end receive → embedded journal shows PO column data
#   7. Existing 10-suite smoke battery still passes

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Q($sql) {
    return (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
}
function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Pre-cleanup
$cleanupSql = @"
SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r INNER JOIN dbo.PullItems pi ON pi.Id=r.PullItemId WHERE pi.ItemCode='SUMMARY';
UPDATE piw SET ReceivedQty=0 FROM dbo.PullItemWindows piw INNER JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId WHERE pi.ItemCode='SUMMARY';
;WITH t AS (SELECT PurchaseOrderLineId, SUM(QtyReceived) AS Net FROM dbo.Receipts GROUP BY PurchaseOrderLineId)
UPDATE pol SET ReceivedQty = ISNULL(t.Net,0) FROM dbo.PurchaseOrderLines pol LEFT JOIN t ON t.PurchaseOrderLineId = pol.Id
WHERE pol.Id <> '77777777-7777-7777-7777-010100000001' AND pol.ReceivedQty <> ISNULL(t.Net,0);
UPDATE po SET Status='open', ClosedAt=NULL FROM dbo.PurchaseOrders po
WHERE po.Status='closed' AND po.PoNumber <> 'PO-2312-091'
  AND EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol WHERE pol.PurchaseOrderId=po.Id AND pol.OrderedQty > pol.ReceivedQty);
"@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $cleanupSql 2>&1 | Out-Null
Write-Host "Pre-cleanup applied" -ForegroundColor DarkGray

$adm = Login 'sadmin' 'admin' $WH01

# ============================================================================
# 1. receive-mockup markup has new alloc-preview slots
# ============================================================================
Step "receive-mockup-v2 carries #m-alloc-list + #m-alloc-warning"
$body = Get-Content 'C:\dev\receivx\mockups\receiving-mockup-v2-fullreceived.html' -Raw
foreach ($id in @('m-alloc-list', 'm-alloc-warning')) {
    if ($body -notmatch [regex]::Escape("id=`"$id`"")) { Fail "Mockup missing #$id" }
}
OK "Mockup contains both alloc-preview slots"

Step "Receiving view (Razor) carries the slots after slicer/builder ran"
$razor = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Receiving\Index.cshtml' -Raw
foreach ($id in @('m-alloc-list', 'm-alloc-warning')) {
    if ($razor -notmatch [regex]::Escape("id=`"$id`"")) { Fail "Razor view missing #$id" }
}
OK "Razor view carries both slots"

# ============================================================================
# 2. receiving.css carries the new styles
# ============================================================================
Step "receiving.css carries .alloc-preview / .cap-hint.warn / .m-tx-po / .tx-po"
$css = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\receiving.css' -Raw
foreach ($cls in @('.alloc-preview', '.cap-hint.warn', '.m-tx-po', '.tx-po')) {
    if ($css -notmatch [regex]::Escape($cls)) { Fail "receiving.css missing rule for $cls" }
}
OK "All 4 Phase 5 CSS rules present"

# ============================================================================
# 3. receiving.js exposes the new wiring
# ============================================================================
Step "receiving.js wires refreshAllocationPreview + hideAllocPanel + allocations[] + PO mapping"
$js = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\receiving.js' -Raw
foreach ($needle in @(
    'refreshAllocationPreview',
    'hideAllocPanel',
    '/api/receipts/preview',
    'result.allocations',
    'result.totalQty',
    'poNumber:    s.poNumber',
    "poLineNumber: s.poLineNumber",
    'splitCount > 1'
)) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "receiving.js missing '$needle'" }
}
# The old "Capped at activeMax" v1 behavior should be gone
if ($js -match "e\.target\.value\s*=\s*activeMax") { Fail "receiving.js still force-caps to activeMax (v1 behavior)" }
OK "receiving.js Stage B wiring intact"

# ============================================================================
# 4. transactions.js + transactions.css carry PO column
# ============================================================================
Step "transactions.js + transactions.css carry the PO column (post-5b: .col-po)"
$txJs = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\transactions.js' -Raw
# §5b moved the rendering from an inline .po-badge inside the Item cell to a
# dedicated `.col-po` column. Both classes are valid markers — we accept either.
if ($txJs -notmatch 'col-po|po-badge') { Fail "transactions.js missing PO column markup (col-po / po-badge)" }
if ($txJs -notmatch 'r\.poNumber') { Fail "transactions.js missing r.poNumber reference" }
$txCss = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\css\transactions.css' -Raw
if ($txCss -notmatch '\.po-badge|\.col-po') { Fail "transactions.css missing .po-badge / .col-po rule" }
OK "transactions.js renders + transactions.css styles the PO column"

# ============================================================================
# 5. GET /api/receipts/preview round-trips
# ============================================================================
Step "Preview endpoint: 100 PCBA-AX450-R2 → single allocation, shortage=0"
$pcbaItem = '44444444-4444-4444-2847-000000000001'
$preview1 = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$pcbaItem&qty=100" -WebSession $adm
if ($preview1.allocations.Count -ne 1) { Fail "Expected 1 allocation, got $($preview1.allocations.Count)" }
if ($preview1.allocations[0].poNumber -ne 'PO-2401-018') { Fail "First slice not PO-2401-018: $($preview1.allocations[0].poNumber)" }
if ($preview1.shortage -ne 0) { Fail "Expected shortage=0, got $($preview1.shortage)" }
OK "Single-line preview: 100 → $($preview1.allocations[0].qty)@$($preview1.allocations[0].poNumber)"

Step "Preview endpoint: 12000 RES-10K-1% → 2-allocation split"
$resItem = '44444444-4444-4444-2847-000000000004'
$preview2 = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$resItem&qty=12000" -WebSession $adm
if ($preview2.allocations.Count -ne 2) { Fail "Expected 2 allocations, got $($preview2.allocations.Count)" }
$summary = ($preview2.allocations | ForEach-Object { "$($_.qty)@$($_.poNumber)" }) -join ' + '
OK "Split preview: $summary"

Step "Preview endpoint: 999999 → shortage > 0, allocations include what fits"
$preview3 = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$pcbaItem&qty=999999" -WebSession $adm
if ($preview3.shortage -le 0) { Fail "Expected positive shortage, got $($preview3.shortage)" }
OK "Shortage preview: requested 999999, allocatable $($preview3.totalAllocatable), shortage $($preview3.shortage)"

# ============================================================================
# 6. End-to-end receive → embedded journal carries PO context for the new row
# ============================================================================
Step "End-to-end: receive 50 PCBA → /api/receipts/pull/{id} returns row with PO context"
$pl2847Id = Q "SELECT Id FROM dbo.Pulls WHERE PullNumber='PL-2847';"
$rcv = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body (@{
    pullItemId = $pcbaItem; hourOfDay = 16; qty = 50; note = 'phase5-e2e'
} | ConvertTo-Json) -ContentType 'application/json' -WebSession $adm
$rcvId = $rcv.allocations[0].receiptId

$journal = Invoke-RestMethod -Uri "$base/api/receipts/pull/$pl2847Id" -WebSession $adm
$row = $journal | Where-Object { $_.id -eq $rcvId } | Select-Object -First 1
if (-not $row) { Fail "Receipt $rcvId missing from journal" }
foreach ($f in @('poNumber','vendorName','poLineNumber','purchaseOrderId','purchaseOrderLineId')) {
    if (-not $row.PSObject.Properties[$f]) { Fail "Journal row missing '$f'" }
}
if ($row.poNumber -ne 'PO-2401-018') { Fail "Expected PO-2401-018, got $($row.poNumber)" }
OK "Journal row carries PO context (PO=$($row.poNumber) line $($row.poLineNumber), vendor=$($row.vendorName))"

# Cleanup
$null = Invoke-RestMethod -Uri "$base/api/receipts/$rcvId/cancel" -Method POST -Body (@{
    reason = 'other'; note = 'phase5-cleanup'
} | ConvertTo-Json) -ContentType 'application/json' -WebSession $adm

# ============================================================================
# 7. Full smoke battery still passes
# ============================================================================
Step "All 10 smoke suites still pass"
$smokes = @(
    'smoke-receive.ps1',
    'smoke-stage-b.ps1',
    'smoke-transactions.ps1',
    'smoke-close-reopen.ps1',
    'smoke-masters.ps1',
    'smoke-masters-config-pages.ps1',
    'smoke-polish.ps1',
    'smoke-receiving-view.ps1',
    'smoke-receiving-page-stage-b.ps1',
    'smoke-transactions-page.ps1'
)
$failed = @()
foreach ($s in $smokes) {
    $logPath = "C:\dev\receivx\tools\.smoke-$s.log"
    pwsh -NoProfile -File "C:\dev\receivx\tools\$s" *> $logPath 2>&1
    $code = $LASTEXITCODE
    $tail = (Get-Content $logPath -Tail 6 | Out-String).Trim()
    Remove-Item $logPath -Force
    if ($code -eq 0 -and $tail -notmatch '(?im)^FAIL') {
        Write-Host "  [PASS] $s" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $s (exit=$code)" -ForegroundColor Red
        $tail -split "`n" | Select-Object -Last 4 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkRed }
        $failed += $s
    }
}
if ($failed.Count -gt 0) { Fail "Smoke regression: $($failed -join ', ')" }
OK "All 10 smoke suites pass"

Write-Host "`nPhase 5 verification PASSED." -ForegroundColor Green
Write-Host "Frontend Stage B wiring complete: FIFO preview pane + PO column in journal." -ForegroundColor Green
