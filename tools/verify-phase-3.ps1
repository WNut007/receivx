# Verify Phase 3: PO read access works end-to-end (view + repos + journal
# columns), and the 6 non-receive smoke suites still pass after the journal
# view + DTO shape changes.

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

# ============================================================================
# 1. View modification holds — journal returns PO columns for all 18 receipts
# ============================================================================
Step "vw_TransactionsJournal now exposes PO columns on every row"
$missingPo = Q "SELECT COUNT(*) FROM dbo.vw_TransactionsJournal WHERE PoNumber IS NULL OR PoLineNumber IS NULL OR PurchaseOrderId IS NULL OR PurchaseOrderLineId IS NULL;"
if ($missingPo -ne '0') { Fail "$missingPo rows have NULL PO context in the journal view" }
$total = Q "SELECT COUNT(*) FROM dbo.vw_TransactionsJournal;"
OK "All $total journal rows carry PO context"

# ============================================================================
# 2. vw_PurchaseOrderAvailability is FIFO-ordered (from Phase 1a) — sanity recheck
# ============================================================================
Step "vw_PurchaseOrderAvailability returns the seeded open lines in FIFO order"
# WH-01 / RES-10K-1% should have 3 lines (PO-2401-018, PO-2401-019, PO-2403-044) in date order.
$resOrder = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q @"
SET NOCOUNT ON;
SELECT PoNumber FROM dbo.vw_PurchaseOrderAvailability
WHERE WarehouseId='$WH01' AND ItemCode='RES-10K-1%'
ORDER BY OrderDate ASC, PoNumber ASC;
"@ 2>&1 | Out-String) -split "`r?`n" | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim() }
$expected = @('PO-2401-018', 'PO-2401-019', 'PO-2403-044')
if (($resOrder | Measure-Object).Count -ne 3) { Fail "Expected 3 FIFO lines, got: $($resOrder -join ',')" }
for ($i = 0; $i -lt 3; $i++) {
    if ($resOrder[$i] -ne $expected[$i]) { Fail "FIFO order wrong at [$i]: got $($resOrder[$i]), expected $($expected[$i])" }
}
OK "FIFO order WH-01/RES-10K-1%: $($resOrder -join ' → ')"

# ============================================================================
# 3. Existing journal API now returns PO context fields
# ============================================================================
Step "GET /api/receipts/pull/{id} surfaces PO context on each row"
$adm = Login 'sadmin' 'admin' $WH01
# PL-2847 is the seeded pull with 18 backfilled receipts.
$pl2847Id = Q "SELECT Id FROM dbo.Pulls WHERE PullNumber='PL-2847';"
$journal = Invoke-RestMethod -Uri "$base/api/receipts/pull/$pl2847Id" -WebSession $adm
if (-not $journal -or $journal.Count -lt 18) { Fail "Expected ≥18 journal rows for PL-2847, got $($journal.Count)" }
$first = $journal[0]
foreach ($field in @('poNumber','vendorCode','vendorName','purchaseOrderId','purchaseOrderLineId','poLineNumber')) {
    if (-not $first.PSObject.Properties[$field]) { Fail "Journal row missing '$field'" }
}
if (-not $first.poNumber) { Fail "poNumber empty on first journal row" }
OK "Journal rows include PO context (first row: $($first.poNumber) line $($first.poLineNumber))"

# ============================================================================
# 4. Transactions cross-pull journal still works + supports new PoNumber filter
# ============================================================================
Step "GET /api/transactions returns rows with PO context"
$txAll = Invoke-RestMethod -Uri "$base/api/transactions?take=10" -WebSession $adm
if ($txAll.rows.Count -lt 1) { Fail "Transactions returned no rows" }
$txFirst = $txAll.rows[0]
if (-not $txFirst.poNumber) { Fail "Transactions row missing PoNumber" }
OK "Transactions rows include PO context"

Step "GET /api/transactions?poNumber=PO-2401-018 filters to that PO only"
$txByPo = Invoke-RestMethod -Uri "$base/api/transactions?poNumber=PO-2401-018&take=200" -WebSession $adm
if ($txByPo.rows.Count -lt 1) { Fail "PoNumber filter returned 0 rows" }
$bad = $txByPo.rows | Where-Object { $_.poNumber -ne 'PO-2401-018' }
if ($bad) { Fail "PoNumber filter leaked $($bad.Count) row(s) with other PO numbers" }
OK "PoNumber filter clean ($($txByPo.rows.Count) rows)"

Step "Multi-token q now matches against PoNumber too"
$txQ = Invoke-RestMethod -Uri "$base/api/transactions?q=PL-2847+PO-2401-018&take=200" -WebSession $adm
if ($txQ.rows.Count -lt 1) { Fail "q='PL-2847 PO-2401-018' returned 0 rows" }
$bad2 = $txQ.rows | Where-Object { $_.poNumber -ne 'PO-2401-018' -or $_.pullNumber -ne 'PL-2847' }
if ($bad2) { Fail "Multi-token AND leaked rows that don't match both tokens" }
OK "Multi-token AND search includes PO context"

# ============================================================================
# 5. Existing 6 page-only / non-receive smokes still pass
# ============================================================================
Step "Existing non-receive smokes still pass (regression check)"
$smokes = @(
    'smoke-polish.ps1',
    'smoke-masters.ps1',
    'smoke-masters-config-pages.ps1',
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
OK "All 6 non-receive smoke suites pass"

# ============================================================================
# 6. View migration is idempotent — re-running 013 must succeed (CREATE OR ALTER)
# ============================================================================
Step "Idempotency: re-run 013_views_v2.sql is safe"
$rerun = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\013_views_v2.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "Re-run failed:`n$rerun" }
OK "Re-run produced no error"

Write-Host "`nPhase 3 verification PASSED." -ForegroundColor Green
Write-Host "Read paths are PO-aware. Receive/cancel write paths still 500 — Phase 4 work." -ForegroundColor Yellow
