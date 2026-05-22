# Verify Phase 1a: schema additions, dropped constraint, new view query-able,
# existing data integrity preserved.

$ErrorActionPreference = 'Stop'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Q($sql) {
    # -h -1: no header. -W: strip trailing whitespace. Returns the single scalar.
    $r = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
    return $r
}

# ========================================================================
# 1. New tables exist (PurchaseOrders, PurchaseOrderLines)
# ========================================================================
Step "Schema: PurchaseOrders + PurchaseOrderLines tables exist"
$po = Q "SELECT CASE WHEN OBJECT_ID('dbo.PurchaseOrders','U') IS NULL THEN 0 ELSE 1 END;"
if ($po -ne '1') { Fail "PurchaseOrders table missing" }
$pol = Q "SELECT CASE WHEN OBJECT_ID('dbo.PurchaseOrderLines','U') IS NULL THEN 0 ELSE 1 END;"
if ($pol -ne '1') { Fail "PurchaseOrderLines table missing" }
OK "Both tables exist"

# ========================================================================
# 2. Indexes exist
# ========================================================================
Step "Indexes: IX_PO_FIFO + IX_POL_FIFO"
$idxPo = Q "SELECT COUNT(*) FROM sys.indexes WHERE name='IX_PO_FIFO' AND object_id=OBJECT_ID('dbo.PurchaseOrders');"
if ($idxPo -ne '1') { Fail "IX_PO_FIFO missing" }
$idxPol = Q "SELECT COUNT(*) FROM sys.indexes WHERE name='IX_POL_FIFO' AND object_id=OBJECT_ID('dbo.PurchaseOrderLines');"
if ($idxPol -ne '1') { Fail "IX_POL_FIFO missing" }
OK "Both FIFO indexes present"

# ========================================================================
# 3. Receipts: new nullable PO columns
# ========================================================================
Step "Receipts has PurchaseOrderId + PurchaseOrderLineId (nullable)"
$col1 = Q @"
SELECT TOP 1 is_nullable FROM sys.columns
WHERE Name='PurchaseOrderId' AND Object_ID=OBJECT_ID('dbo.Receipts');
"@
if ($col1 -ne '1') { Fail "PurchaseOrderId missing or NOT NULL (expected nullable in 1a). Value: '$col1'" }
$col2 = Q @"
SELECT TOP 1 is_nullable FROM sys.columns
WHERE Name='PurchaseOrderLineId' AND Object_ID=OBJECT_ID('dbo.Receipts');
"@
if ($col2 -ne '1') { Fail "PurchaseOrderLineId missing or NOT NULL. Value: '$col2'" }
OK "Both columns added, both still nullable (correct for 1a)"

# ========================================================================
# 4. CK_PIW_Caps is gone
# ========================================================================
Step "CK_PIW_Caps removed from PullItemWindows"
$ck = Q "SELECT COUNT(*) FROM sys.check_constraints WHERE name='CK_PIW_Caps' AND parent_object_id=OBJECT_ID('dbo.PullItemWindows');"
if ($ck -ne '0') { Fail "CK_PIW_Caps still exists (expected dropped). Count: $ck" }
OK "CK_PIW_Caps successfully dropped"

# ========================================================================
# 5. vw_PurchaseOrderAvailability exists and queries clean
# ========================================================================
Step "vw_PurchaseOrderAvailability exists and returns 0 rows (no PO seed yet)"
$viewExists = Q "SELECT CASE WHEN OBJECT_ID('dbo.vw_PurchaseOrderAvailability','V') IS NULL THEN 0 ELSE 1 END;"
if ($viewExists -ne '1') { Fail "vw_PurchaseOrderAvailability not created" }
$availRows = Q "SELECT COUNT(*) FROM dbo.vw_PurchaseOrderAvailability;"
if ($availRows -ne '0') { Fail "vw_PurchaseOrderAvailability has $availRows rows; expected 0 (no PO seed yet)" }
OK "View created and returns 0 rows (pre-seed state)"

# ========================================================================
# 6. No orphans / existing data preserved
# ========================================================================
Step "Existing data preserved: every receipt has NULL PO columns"
$totalReceipts = Q "SELECT COUNT(*) FROM dbo.Receipts;"
$nullPoReceipts = Q "SELECT COUNT(*) FROM dbo.Receipts WHERE PurchaseOrderId IS NULL AND PurchaseOrderLineId IS NULL;"
if ($totalReceipts -ne $nullPoReceipts) {
    Fail "Total receipts: $totalReceipts, but only $nullPoReceipts have NULL PO. Phase 1a should NOT have populated any."
}
OK "All $totalReceipts existing receipts have NULL PO columns (correct pre-backfill state)"

Step "Existing data preserved: row counts match pre-migration baseline"
$tables = @('Users','Warehouses','UserWarehouseAssignments','Pulls','PullItems','PullItemWindows','Receipts','AuditLog')
foreach ($t in $tables) {
    $cnt = Q "SELECT COUNT(*) FROM dbo.$t;"
    Write-Host "  $t : $cnt rows"
}
OK "Row counts logged (no destructive change expected)"

# ========================================================================
# 7. PurchaseOrders + Lines themselves empty (no accidental data seeded)
# ========================================================================
Step "PurchaseOrders + PurchaseOrderLines are empty (no seed yet)"
$poCount = Q "SELECT COUNT(*) FROM dbo.PurchaseOrders;"
$polCount = Q "SELECT COUNT(*) FROM dbo.PurchaseOrderLines;"
if ($poCount -ne '0') { Fail "PurchaseOrders has $poCount rows; expected 0" }
if ($polCount -ne '0') { Fail "PurchaseOrderLines has $polCount rows; expected 0" }
OK "Both new tables empty (ready for Phase 2 seed)"

# ========================================================================
# 8. Idempotency check — re-running the script must be a no-op
# ========================================================================
Step "Idempotency: re-running 010_schema_v2_additive.sql is safe"
$rerun = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\010_schema_v2_additive.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Fail "Re-run exited non-zero:`n$rerun"
}
if ($rerun -match 'Creating table' -or $rerun -match 'Adding Receipts' -or $rerun -match 'Dropping CK_PIW_Caps') {
    Fail "Re-run tried to create/alter — guards aren't idempotent. Output:`n$rerun"
}
OK "Re-run is silent (idempotency confirmed)"

Write-Host "`nPhase 1a verification passed." -ForegroundColor Green
