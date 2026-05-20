# Phase 4 verifier — FIFO allocator, PO admin, immutability, auto-close/reopen,
# concurrent receivers, and the existing smoke battery back to PASS (cutover closed).

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
function ProblemFrom($exception) {
    if ($exception.ErrorDetails) {
        try { return ($exception.ErrorDetails.Message | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

$adm = Login 'sadmin' 'admin' $WH01

# Pre-cleanup: wipe any stale data from prior verifier runs.
$cleanupSql = @"
SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r INNER JOIN dbo.PurchaseOrders po ON po.Id=r.PurchaseOrderId WHERE po.PoNumber LIKE 'PO-PHASE4-%';
DELETE pol FROM dbo.PurchaseOrderLines pol INNER JOIN dbo.PurchaseOrders po ON po.Id=pol.PurchaseOrderId WHERE po.PoNumber LIKE 'PO-PHASE4-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-PHASE4-%';
DELETE r FROM dbo.Receipts r INNER JOIN dbo.PullItems pi ON pi.Id=r.PullItemId WHERE pi.ItemCode='SUMMARY';
UPDATE piw SET ReceivedQty = 0 FROM dbo.PullItemWindows piw INNER JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId WHERE pi.ItemCode='SUMMARY';
;WITH t AS (SELECT PurchaseOrderLineId, SUM(QtyReceived) AS Net FROM dbo.Receipts GROUP BY PurchaseOrderLineId)
UPDATE pol SET ReceivedQty = ISNULL(t.Net,0)
FROM dbo.PurchaseOrderLines pol LEFT JOIN t ON t.PurchaseOrderLineId = pol.Id
WHERE pol.Id <> '77777777-7777-7777-7777-010100000001' AND pol.ReceivedQty <> ISNULL(t.Net,0);
UPDATE po SET Status='open', ClosedAt=NULL
FROM dbo.PurchaseOrders po
WHERE po.Status='closed' AND po.PoNumber <> 'PO-2312-091'
  AND EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol WHERE pol.PurchaseOrderId=po.Id AND pol.OrderedQty > pol.ReceivedQty);
"@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $cleanupSql 2>&1 | Out-Null
Write-Host "Pre-cleanup: wiped PO-PHASE4-* + SUMMARY residue + reconciled caches" -ForegroundColor DarkGray

# ============================================================================
# 1. GET /api/receipts/preview — read-only FIFO
# ============================================================================
Step "Preview: 100 pcs of PCBA-AX450-R2 (WH-01) — single PO oldest=PO-2401-018"
# PL-2847 PCBA-AX450-R2 is `44444444-4444-4444-2847-000000000001`
$pcbaItem = '44444444-4444-4444-2847-000000000001'
$prev = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$pcbaItem&qty=100" -WebSession $adm
if ($prev.allocations.Count -ne 1) { Fail "Expected 1 allocation, got $($prev.allocations.Count)" }
if ($prev.allocations[0].poNumber -ne 'PO-2401-018') { Fail "Expected PO-2401-018, got $($prev.allocations[0].poNumber)" }
if ($prev.allocations[0].qty -ne 100) { Fail "Expected qty=100, got $($prev.allocations[0].qty)" }
if ($prev.shortage -ne 0) { Fail "Expected shortage=0, got $($prev.shortage)" }
OK "Single-line preview: 100 → PO-2401-018 line 1"

# ============================================================================
# 2. Preview shortage when qty exceeds total open capacity
# ============================================================================
Step "Preview: 999999 pcs PCBA-AX450-R2 → shortage exposed"
$prevShort = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$pcbaItem&qty=999999" -WebSession $adm
if ($prevShort.shortage -le 0) { Fail "Expected positive shortage, got $($prevShort.shortage)" }
if ($prevShort.totalAllocatable -ge 999999) { Fail "totalAllocatable should be < 999999" }
OK "Shortage reported: $($prevShort.shortage) pcs, available: $($prevShort.totalAllocatable)"

# ============================================================================
# 3. Receive 100 pcs PCBA-AX450-R2 (single allocation) + verify cache
# ============================================================================
Step "Receive 100 pcs PCBA-AX450-R2 → single PO-2401-018 allocation"
$beforeReceived = [int](Q "SELECT ReceivedQty FROM dbo.PurchaseOrderLines WHERE Id='77777777-7777-7777-7777-020100000001';")
$body = @{ pullItemId = $pcbaItem; hourOfDay = 9; qty = 100; note = 'phase4-single' } | ConvertTo-Json
$rcv = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $adm
if ($rcv.allocations.Count -ne 1) { Fail "Expected 1 allocation, got $($rcv.allocations.Count)" }
if ($rcv.totalQty -ne 100) { Fail "totalQty=$($rcv.totalQty)" }
$singleReceiptId = $rcv.allocations[0].receiptId
$afterReceived = [int](Q "SELECT ReceivedQty FROM dbo.PurchaseOrderLines WHERE Id='77777777-7777-7777-7777-020100000001';")
if (($afterReceived - $beforeReceived) -ne 100) { Fail "Cache delta=$($afterReceived-$beforeReceived), expected 100" }
OK "Single-allocation receive: cache 2100 → 2200, receipt $singleReceiptId"

# ============================================================================
# 4. Cancel restores qty to SAME PO line (no re-FIFO)
# ============================================================================
Step "Cancel restores qty to the original's PO line + returns poLineRestored"
$cancelBody = @{ reason = 'other'; note = 'phase4-cleanup' } | ConvertTo-Json
$cancel = Invoke-RestMethod -Uri "$base/api/receipts/$singleReceiptId/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $adm
if (-not $cancel.poLineRestored) { Fail "CancelResult missing poLineRestored" }
if ($cancel.poLineRestored.poNumber -ne 'PO-2401-018') { Fail "poLineRestored.poNumber=$($cancel.poLineRestored.poNumber)" }
$restoredReceived = [int](Q "SELECT ReceivedQty FROM dbo.PurchaseOrderLines WHERE Id='77777777-7777-7777-7777-020100000001';")
if ($restoredReceived -ne $beforeReceived) { Fail "After cancel cache=$restoredReceived, expected $beforeReceived" }
OK "Cancel returned line PO-2401-018 to remaining=$($cancel.poLineRestored.newRemainingQty), cache restored to $restoredReceived"

# ============================================================================
# 5. Multi-PO FIFO split — fill PO-2401-018's remaining then spill to PO-2401-019
# ============================================================================
Step "FIFO split: receive enough to overflow PO-2401-018 L4 (RES-10K-1%) into PO-2401-019 L1"
# WH-01 RES-10K-1%: PO-2401-018 L4 has 20000-8200 = 11800 remaining; PO-2401-019 L1 has 5000; PO-2403-044 L1 has 3000.
# A 12000 receive should produce 2 allocations: 11800 from PO-2401-018, 200 from PO-2401-019.
$resItem = '44444444-4444-4444-2847-000000000004'
$body = @{ pullItemId = $resItem; hourOfDay = 15; qty = 12000; note = 'phase4-split' } | ConvertTo-Json
try {
    $split = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $adm
} catch {
    $p = ProblemFrom $_
    Fail "Receive 12000 failed: $($p.title)"
}
if ($split.allocations.Count -ne 2) { Fail "Expected 2 allocations, got $($split.allocations.Count): $($split.allocations | ConvertTo-Json -Compress)" }
if ($split.allocations[0].poNumber -ne 'PO-2401-018' -or $split.allocations[0].qty -ne 11800) {
    Fail "First slice should be 11800@PO-2401-018, got $($split.allocations[0].qty)@$($split.allocations[0].poNumber)"
}
if ($split.allocations[1].poNumber -ne 'PO-2401-019' -or $split.allocations[1].qty -ne 200) {
    Fail "Second slice should be 200@PO-2401-019, got $($split.allocations[1].qty)@$($split.allocations[1].poNumber)"
}
OK "12000 pcs split: 11800@PO-2401-018 + 200@PO-2401-019"

# ============================================================================
# 6. PO-2401-018 was auto-closed (its only RES line is now fully received… but other lines still have remaining → PO stays open)
# ============================================================================
Step "PO-2401-018 remains open (other lines still have capacity)"
$po2401018Status = Q "SELECT Status FROM dbo.PurchaseOrders WHERE PoNumber='PO-2401-018';"
if ($po2401018Status -ne 'open') { Fail "PO-2401-018 status=$po2401018Status, expected open (other items still have remaining qty)" }
OK "PO-2401-018 stays open (auto-close only fires when ALL lines fully received)"

# ============================================================================
# 7. Cancel the 200-pc slice — restores capacity to PO-2401-019, PO stays open
# ============================================================================
Step "Cancel 200-pc slice — restores capacity to PO-2401-019 (no auto-reopen since PO stayed open)"
$slice2 = $split.allocations[1]
$null = Invoke-RestMethod -Uri "$base/api/receipts/$($slice2.receiptId)/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $adm
$po2401019PostCancel = Q "SELECT ReceivedQty FROM dbo.PurchaseOrderLines WHERE PurchaseOrderId='66666666-6666-6666-6666-000000000003' AND ItemCode='RES-10K-1%';"
if ($po2401019PostCancel -ne '0') { Fail "Expected PO-2401-019 RES-10K-1% cache back to 0, got $po2401019PostCancel" }
OK "PO-2401-019 RES cache restored to 0"

# Cleanup the 11800 slice too — leave seed clean
$slice1 = $split.allocations[0]
$null = Invoke-RestMethod -Uri "$base/api/receipts/$($slice1.receiptId)/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $adm
OK "FIFO split test cleaned up"

# ============================================================================
# 8. Auto-close + auto-reopen — create a small PO line, fill it, cancel, verify status flips
# ============================================================================
Step "Create test PO → receive to exhaustion → PO auto-closes → cancel → auto-reopens"
$autoBody = @{
    poNumber    = "PO-PHASE4-AUTO"
    warehouseId = $WH01
    vendorCode  = 'V-PHASE4'
    vendorName  = 'Phase 4 Verifier Vendor'
    orderDate   = '2020-01-01'    # very old so FIFO consumes this first
    notes       = 'Single-line PO for auto-close/reopen verification (oldest)'
    lines       = @(
        @{ lineNumber = 1; itemCode = 'SUMMARY'; description = 'Phase 4 auto-close test'; orderedQty = 50 }
    )
} | ConvertTo-Json -Depth 4
$auto = Invoke-RestMethod -Uri "$base/api/pos" -Method POST -Body $autoBody -ContentType 'application/json' -WebSession $adm
$autoPoId = $auto.id
$autoLineId = $auto.lines[0].id

# Use any SUMMARY PullItem in WH-01 to fill the line
$summaryItem = Q "SELECT TOP 1 pi.Id FROM dbo.PullItems pi INNER JOIN dbo.Pulls p ON p.Id = pi.PullId WHERE p.PullNumber='PL-2848' AND pi.ItemCode='SUMMARY';"
$fillBody = @{ pullItemId = $summaryItem; hourOfDay = 12; qty = 50; note = 'phase4-fill' } | ConvertTo-Json
$fill = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $fillBody -ContentType 'application/json' -WebSession $adm
if ($fill.allocations[0].purchaseOrderId -ne $autoPoId) {
    Fail "Fill didn't land on oldest PO: poId=$($fill.allocations[0].purchaseOrderId), expected $autoPoId"
}

$autoStatus = Q "SELECT Status FROM dbo.PurchaseOrders WHERE Id='$autoPoId';"
if ($autoStatus -ne 'closed') { Fail "PO did not auto-close after full receive; status=$autoStatus" }
OK "PO auto-closed when line filled (status=closed)"

# Cancel → should auto-reopen
$fillReceiptId = $fill.allocations[0].receiptId
$null = Invoke-RestMethod -Uri "$base/api/receipts/$fillReceiptId/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $adm
$autoStatusAfterCancel = Q "SELECT Status FROM dbo.PurchaseOrders WHERE Id='$autoPoId';"
if ($autoStatusAfterCancel -ne 'open') { Fail "PO did not auto-reopen after cancel; status=$autoStatusAfterCancel" }
OK "PO auto-reopened when cancel restored capacity (status=open)"

# ============================================================================
# 9. §7.13 immutability — UPDATE refused when receipts reference the PO
# ============================================================================
# autoPoId now has a positive + reversal receipt referencing it. PUT must 409.
Step "§7.13 PUT on PO with receipts → 409"
$updBody = @{ orderDate = '2025-01-01' } | ConvertTo-Json
try {
    Invoke-RestMethod -Uri "$base/api/pos/$autoPoId" -Method PUT -Body $updBody -ContentType 'application/json' -WebSession $adm | Out-Null
    Fail "Expected 409 on PUT with receipts referencing PO"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
}
OK "§7.13 PUT refused (PO has receipts)"

# §7.13 DELETE line refused
Step "§7.13 DELETE line with receipts → 409"
try {
    Invoke-RestMethod -Uri "$base/api/pos/$autoPoId/lines/$autoLineId" -Method DELETE -WebSession $adm | Out-Null
    Fail "Expected 409 on DELETE line with receipts"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
}
OK "§7.13 DELETE line refused (line has receipts)"

# Cleanup our test POs — close them manually
$null = Invoke-RestMethod -Uri "$base/api/pos/$autoPoId/close" -Method POST -Body (@{ reason = 'phase4 verifier cleanup' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $adm

# ============================================================================
# 10. Insufficient capacity → 409 + zero state change
# ============================================================================
Step "Receive exceeding total open capacity → 409 + no allocations + cache unchanged"
$resBeforeBig = Q "SELECT ISNULL(SUM(ReceivedQty),0) FROM dbo.PurchaseOrderLines WHERE ItemCode='RES-10K-1%';"
$bigBody = @{ pullItemId = $resItem; hourOfDay = 17; qty = 999999999; note = 'phase4-overshoot' } | ConvertTo-Json
try {
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $bigBody -ContentType 'application/json' -WebSession $adm | Out-Null
    Fail "Expected 409 on insufficient capacity"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
}
$resAfterBig = Q "SELECT ISNULL(SUM(ReceivedQty),0) FROM dbo.PurchaseOrderLines WHERE ItemCode='RES-10K-1%';"
if ($resBeforeBig -ne $resAfterBig) { Fail "Cache changed after rejected receive: before=$resBeforeBig after=$resAfterBig" }
OK "Insufficient capacity 409 + no partial state change (cache=$resBeforeBig unchanged)"

# ============================================================================
# 11. 3 concurrent receivers + SUM invariant
# ============================================================================
Step "3 concurrent receivers on PCBA-AX450-R2 → all complete, SUM invariant holds"
$sumBefore = [int](Q "SELECT ISNULL(SUM(ReceivedQty),0) FROM dbo.PurchaseOrderLines WHERE ItemCode='PCBA-AX450-R2';")

# Spawn 3 child PowerShells doing parallel receives.
$qtys = @(50, 75, 100)
$jobs = $qtys | ForEach-Object {
    $q = $_
    Start-Job -ScriptBlock {
        param($base, $WH01, $pcbaItem, $q)
        $body = @{ username='sadmin'; password='admin'; warehouseId=$WH01; remember=$false } | ConvertTo-Json
        $sv = $null
        Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
        $r = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body (
            @{ pullItemId=$pcbaItem; hourOfDay=10; qty=$q; note="phase4-concurrent-$q" } | ConvertTo-Json
        ) -ContentType 'application/json' -WebSession $sv
        return $r.allocations[0].receiptId
    } -ArgumentList $base, $WH01, $pcbaItem, $q
}
$receiptIds = $jobs | Wait-Job -Timeout 30 | Receive-Job
$jobs | Remove-Job -Force

if ($receiptIds.Count -ne 3) { Fail "Expected 3 receiptIds, got $($receiptIds.Count): $($receiptIds -join ',')" }
$sumAfter = [int](Q "SELECT ISNULL(SUM(ReceivedQty),0) FROM dbo.PurchaseOrderLines WHERE ItemCode='PCBA-AX450-R2';")
$expectedDelta = ($qtys | Measure-Object -Sum).Sum
if (($sumAfter - $sumBefore) -ne $expectedDelta) {
    Fail "Concurrent SUM invariant broken: before=$sumBefore after=$sumAfter delta=$($sumAfter-$sumBefore), expected $expectedDelta"
}
OK "3 concurrent receives serialized cleanly; SUM delta = $expectedDelta"

# Cleanup concurrent receipts
foreach ($id in $receiptIds) {
    $null = Invoke-RestMethod -Uri "$base/api/receipts/$id/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $adm
}
OK "Concurrent test cleaned up"

# ============================================================================
# 12. /api/pos read endpoints
# ============================================================================
Step "GET /api/pos returns the seeded catalog"
$pos = Invoke-RestMethod -Uri "$base/api/pos?warehouseId=$WH01" -WebSession $adm
if ($pos.Count -lt 4) { Fail "Expected ≥4 WH-01 POs, got $($pos.Count)" }
$po2401018 = $pos | Where-Object { $_.poNumber -eq 'PO-2401-018' } | Select-Object -First 1
if (-not $po2401018) { Fail "PO-2401-018 missing from list" }
if ($po2401018.lineCount -lt 7) { Fail "PO-2401-018 lineCount=$($po2401018.lineCount), expected ≥7" }
OK "List shows $($pos.Count) WH-01 POs; PO-2401-018 has $($po2401018.lineCount) lines"

Step "GET /api/pos/availability returns FIFO-ordered open lines"
$avail = Invoke-RestMethod -Uri "$base/api/pos/availability?warehouseId=$WH01&itemCode=RES-10K-1%25" -WebSession $adm
if ($avail.Count -lt 3) { Fail "Expected ≥3 lines for RES-10K-1%, got $($avail.Count)" }
$dates = $avail | ForEach-Object { [datetime]$_.orderDate }
for ($i = 1; $i -lt $dates.Count; $i++) {
    if ($dates[$i] -lt $dates[$i-1]) { Fail "Availability not FIFO-ordered at index $i" }
}
OK "Availability is FIFO-ordered ($($avail.Count) lines)"

# ============================================================================
# 13. Existing smoke battery — cutover closed, all 10 should pass
# ============================================================================
Step "Existing smoke suite (cutover closed — all 10 expected to pass)"
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
    $tail = (Get-Content $logPath -Tail 8 | Out-String).Trim()
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
OK "All 10 smoke suites pass — cutover closed"

Write-Host "`nPhase 4 verification PASSED." -ForegroundColor Green
Write-Host "FIFO receive + cancel + auto-close/reopen + PO admin + immutability all working." -ForegroundColor Green
