# Verify Phase 2: snapshot pre-state, apply 007 + 012, assert all invariants.
# Existing smoke battery is re-run at the end for regression.

$ErrorActionPreference = 'Stop'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Q($sql) {
    return (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
}
function Qrows($sql) {
    # Multi-row scalar; returns array of lines
    return ((sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String) -split "`r?`n" | Where-Object { $_ -ne '' })
}

# ============================================================================
# 0. Snapshot pre-state (vw_PullItemReceived NetReceived for PL-2847 items)
# ============================================================================
Step "Snapshot vw_PullItemReceived for PL-2847 items (pre-migration)"
$pl2847Pre = Qrows @"
SELECT CONVERT(VARCHAR(36), v.PullItemId) + '|' + CAST(v.HourOfDay AS VARCHAR) + '|' + CAST(v.NetReceived AS VARCHAR)
FROM dbo.vw_PullItemReceived v
INNER JOIN dbo.PullItems pi ON pi.Id = v.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = 'PL-2847'
ORDER BY v.PullItemId, v.HourOfDay;
"@
Write-Host "  Recorded $($pl2847Pre.Count) rows of (pullItem,hour,net) for PL-2847"

$summaryReceiptsPre = Q "SELECT COUNT(*) FROM dbo.Receipts r INNER JOIN dbo.PullItems pi ON pi.Id=r.PullItemId WHERE pi.ItemCode='SUMMARY';"
Write-Host "  Smoke residue receipts (ItemCode=SUMMARY): $summaryReceiptsPre"

$totalReceiptsPre = Q "SELECT COUNT(*) FROM dbo.Receipts;"
Write-Host "  Total receipts: $totalReceiptsPre"

# ============================================================================
# 1. Apply 007 (seed POs)
# ============================================================================
Step "Apply db/007_seed_purchase_orders.sql"
$out = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\007_seed_purchase_orders.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "007 failed:`n$out" }
Write-Host $out

$poCount  = Q "SELECT COUNT(*) FROM dbo.PurchaseOrders;"
$polCount = Q "SELECT COUNT(*) FROM dbo.PurchaseOrderLines;"
if ($poCount -ne '11')  { Fail "Expected 11 POs, got $poCount" }
# 21 = WH-01 (1+7+2+2) + WH-02 (1+2+1) + WH-03 (1+2+1) + WH-04 (1) — SUMMARY lines removed per design adjustment
if ($polCount -ne '21') { Fail "Expected 21 PO lines, got $polCount" }
OK "Seeded $poCount POs / $polCount PO lines"

# ============================================================================
# 2. Apply 012 (backfill)
# ============================================================================
Step "Apply db/012_backfill_receipts.sql"
$out2 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\012_backfill_receipts.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "012 backfill failed:`n$out2" }
Write-Host $out2

# ============================================================================
# 3. Invariants
# ============================================================================
Step "Invariant (a): zero receipts with NULL PO columns"
$orphan = Q "SELECT COUNT(*) FROM dbo.Receipts WHERE PurchaseOrderId IS NULL OR PurchaseOrderLineId IS NULL;"
if ($orphan -ne '0') { Fail "$orphan receipts still have NULL PO columns" }
OK "No orphan receipts"

Step "Invariant (b): PurchaseOrderLines.ReceivedQty in [0, OrderedQty]"
$oor = Q "SELECT COUNT(*) FROM dbo.PurchaseOrderLines WHERE ReceivedQty < 0 OR ReceivedQty > OrderedQty;"
if ($oor -ne '0') { Fail "$oor PO line(s) have ReceivedQty out of range" }
OK "All PO line caches within bounds"

Step "Invariant (c): per-line cache == SUM(Receipts.QtyReceived) for that line"
$mismatch = Q @"
WITH actual AS (
    SELECT PurchaseOrderLineId, SUM(QtyReceived) AS Net
    FROM dbo.Receipts WHERE PurchaseOrderLineId IS NOT NULL
    GROUP BY PurchaseOrderLineId
)
SELECT COUNT(*) FROM dbo.PurchaseOrderLines pol
LEFT JOIN actual a ON a.PurchaseOrderLineId = pol.Id
WHERE pol.ReceivedQty <> ISNULL(a.Net, 0)
  AND pol.Id <> '77777777-7777-7777-7777-010100000001';
"@
if ($mismatch -ne '0') { Fail "$mismatch PO line(s) have ReceivedQty != SUM(Receipts.QtyReceived)" }
OK "All PO line caches match Receipts truth"

Step "Invariant (d): every reversal has same PurchaseOrderLineId as its original"
$revMismatch = Q @"
SELECT COUNT(*)
FROM   dbo.Receipts rev
INNER JOIN dbo.Receipts orig ON orig.Id = rev.ReversesReceiptId
WHERE  rev.PurchaseOrderLineId <> orig.PurchaseOrderLineId
    OR rev.PurchaseOrderId     <> orig.PurchaseOrderId;
"@
if ($revMismatch -ne '0') { Fail "$revMismatch reversal(s) not aligned with their original's PO line" }
OK "Reversals correctly attached to original's line"

# ============================================================================
# 4. Smoke residue cleaned
# ============================================================================
Step "Phase 2.0 cleanup: SUMMARY-item receipts purged"
$residueAfter = Q "SELECT COUNT(*) FROM dbo.Receipts r INNER JOIN dbo.PullItems pi ON pi.Id=r.PullItemId WHERE pi.ItemCode='SUMMARY';"
if ($residueAfter -ne '0') { Fail "$residueAfter SUMMARY-item receipt(s) remain — cleanup failed" }
OK "All SUMMARY-item receipts removed"

# ============================================================================
# 5. vw_PullItemReceived unchanged for PL-2847 (the primary invariant)
# ============================================================================
Step "vw_PullItemReceived NetReceived for PL-2847 — bit-for-bit unchanged"
$pl2847Post = Qrows @"
SELECT CONVERT(VARCHAR(36), v.PullItemId) + '|' + CAST(v.HourOfDay AS VARCHAR) + '|' + CAST(v.NetReceived AS VARCHAR)
FROM dbo.vw_PullItemReceived v
INNER JOIN dbo.PullItems pi ON pi.Id = v.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = 'PL-2847'
ORDER BY v.PullItemId, v.HourOfDay;
"@
if ($pl2847Pre.Count -ne $pl2847Post.Count) {
    Fail "Row count changed: pre=$($pl2847Pre.Count), post=$($pl2847Post.Count)"
}
for ($i = 0; $i -lt $pl2847Pre.Count; $i++) {
    if ($pl2847Pre[$i] -ne $pl2847Post[$i]) {
        Fail "PL-2847 row $i changed: pre='$($pl2847Pre[$i])' post='$($pl2847Post[$i])'"
    }
}
OK "All $($pl2847Pre.Count) PL-2847 (pullItem,hour,net) entries identical to pre-state"

# ============================================================================
# 6. Spot-check ReceivedQty cache against design expectations
# ============================================================================
Step "Cache spot-checks (expected backfill totals on PO-2401-018)"
$expected = @{
    'PCBA-AX450-R2' = 2100
    'PCBA-AX451-R2' = 1300
    'CAP-470UF-25V' = 3500
    'RES-10K-1%'    = 8200  # net after reversals
    'CONN-USB-C-16' = 200
    'LCD-3.5-IPS'   = 50
    'SHIELD-RF-A1'  = 300
}
foreach ($item in $expected.Keys) {
    $actual = Q @"
SELECT TOP 1 ReceivedQty FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = 'PO-2401-018' AND pol.ItemCode = '$item';
"@
    $want = $expected[$item]
    if ([int]$actual -ne $want) {
        Fail "PO-2401-018 / $item : got ReceivedQty=$actual, expected $want"
    }
    Write-Host "  PO-2401-018 / $item : $actual (expected $want)"
}
OK "All 7 PL-2847 items backfilled to PO-2401-018 with correct net qty"

Step "Other POs untouched (RemainingQty == OrderedQty)"
$untouched = Q @"
SELECT COUNT(*) FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber IN ('PO-2401-019','PO-2403-044','PO-2402-022','PO-2402-023','PO-2403-051',
                      'PO-2402-031','PO-2402-032','PO-2403-061','PO-2401-010')
  AND pol.ReceivedQty <> 0;
"@
if ($untouched -ne '0') { Fail "$untouched PO line(s) on non-target POs have non-zero ReceivedQty" }
OK "All non-backfill-target PO lines untouched (cache=0)"

# ============================================================================
# 7. Idempotency: re-run both scripts → no-op
# ============================================================================
Step "Idempotency: re-running 007 + 012 is safe"
$out7 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\007_seed_purchase_orders.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "007 re-run failed:`n$out7" }
if ($out7 -match 'INSERT') { Fail "007 re-run tried to INSERT — guards aren't idempotent" }

$out12 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\012_backfill_receipts.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "012 re-run failed:`n$out12" }
if ($out12 -notmatch '2\.0\s+Smoke residue.*0 receipt') { Fail "012 re-run not idempotent: $out12" }
if ($out12 -notmatch '2\.1\s+Walked \+ assigned 0') { Fail "012 re-run walked non-zero receipts: $out12" }
OK "Both scripts idempotent on re-run"

# ============================================================================
# 8. Regression: existing smoke battery must still pass
# ============================================================================
Step "Run existing smoke suite (regression check)"
$smokes = @(
    'smoke-receive.ps1',
    'smoke-stage-b.ps1',
    'smoke-transactions.ps1',
    'smoke-masters.ps1',
    'smoke-masters-config-pages.ps1',
    'smoke-polish.ps1',
    'smoke-receiving-view.ps1',
    'smoke-receiving-page-stage-b.ps1',
    'smoke-transactions-page.ps1'
)
$ErrorActionPreference = 'Continue'
$failed = @()
foreach ($s in $smokes) {
    $smokeOut = & "C:\dev\receivx\tools\$s" 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $smokeOut -notmatch '(?im)^FAIL') {
        Write-Host "  [PASS] $s" -ForegroundColor Green
    } else {
        $failed += $s
        Write-Host "  [FAIL] $s" -ForegroundColor Red
        $smokeOut | Select-Object -Last 4 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkRed }
    }
}
$ErrorActionPreference = 'Stop'
if ($failed.Count -gt 0) { Fail "Smoke regression: $($failed.Count) suite(s) failed: $($failed -join ', ')" }
OK "All 9 existing smoke suites still pass"

Write-Host "`nPhase 2 verification PASSED." -ForegroundColor Green
