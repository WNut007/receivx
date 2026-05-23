# Verify Phase 3.5: configurable PO-pull lock
#   - PurchaseOrders.PullId added (nullable) + FK + filtered index
#   - Pulls.LockPoByPull added (NOT NULL, default 0)
#   - vw_PurchaseOrderAvailability projects PullId
#   - Seed: PO-2401-018 linked to PL-2847, PL-2900 + PO-2405-001 with lock=1
#   - FK reject + idempotency of 015/016

$ErrorActionPreference = 'Stop'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Q($sql) {
    $r = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
    return $r
}

# ========================================================================
# 1. PurchaseOrders.PullId — exists + nullable
# ========================================================================
Step "PurchaseOrders.PullId added (nullable)"
$colExists = Q "SELECT COUNT(*) FROM sys.columns WHERE Name='PullId' AND Object_ID=OBJECT_ID('dbo.PurchaseOrders');"
if ($colExists -ne '1') { Fail "PurchaseOrders.PullId missing" }
$nullable = Q "SELECT is_nullable FROM sys.columns WHERE Name='PullId' AND Object_ID=OBJECT_ID('dbo.PurchaseOrders');"
if ($nullable -ne '1') { Fail "PurchaseOrders.PullId is NOT NULL (expected nullable). Value: '$nullable'" }
$dataType = Q "SELECT TYPE_NAME(system_type_id) FROM sys.columns WHERE Name='PullId' AND Object_ID=OBJECT_ID('dbo.PurchaseOrders');"
if ($dataType -ne 'uniqueidentifier') { Fail "PurchaseOrders.PullId is '$dataType', expected uniqueidentifier" }
OK "PullId column present, nullable, uniqueidentifier"

# ========================================================================
# 2. FK_PO_Pull exists and points at Pulls(Id)
# ========================================================================
Step "FK_PO_Pull → dbo.Pulls(Id)"
$fk = Q @"
SELECT COUNT(*) FROM sys.foreign_keys fk
INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
INNER JOIN sys.columns refCol
       ON refCol.object_id = fkc.referenced_object_id
      AND refCol.column_id = fkc.referenced_column_id
WHERE fk.name = 'FK_PO_Pull'
  AND fk.parent_object_id = OBJECT_ID('dbo.PurchaseOrders')
  AND fkc.referenced_object_id = OBJECT_ID('dbo.Pulls')
  AND refCol.name = 'Id';
"@
if ($fk -ne '1') { Fail "FK_PO_Pull missing or wrong target. Count: '$fk'" }
OK "FK_PO_Pull → dbo.Pulls(Id) present"

# ========================================================================
# 3. Filtered IX_PO_Pull
# ========================================================================
Step "Filtered IX_PO_Pull on PurchaseOrders(PullId) WHERE PullId IS NOT NULL"
$idx = Q "SELECT COUNT(*) FROM sys.indexes WHERE name='IX_PO_Pull' AND object_id=OBJECT_ID('dbo.PurchaseOrders') AND has_filter=1;"
if ($idx -ne '1') { Fail "IX_PO_Pull missing or unfiltered. Count: '$idx'" }
OK "Filtered IX_PO_Pull present"

# ========================================================================
# 4. Pulls.LockPoByPull — exists + NOT NULL + default 0
# ========================================================================
Step "Pulls.LockPoByPull (BIT NOT NULL DEFAULT 0)"
$lockCol = Q "SELECT COUNT(*) FROM sys.columns WHERE Name='LockPoByPull' AND Object_ID=OBJECT_ID('dbo.Pulls');"
if ($lockCol -ne '1') { Fail "Pulls.LockPoByPull missing" }
$lockNullable = Q "SELECT is_nullable FROM sys.columns WHERE Name='LockPoByPull' AND Object_ID=OBJECT_ID('dbo.Pulls');"
if ($lockNullable -ne '0') { Fail "Pulls.LockPoByPull is nullable (expected NOT NULL). Value: '$lockNullable'" }
$lockType = Q "SELECT TYPE_NAME(system_type_id) FROM sys.columns WHERE Name='LockPoByPull' AND Object_ID=OBJECT_ID('dbo.Pulls');"
if ($lockType -ne 'bit') { Fail "Pulls.LockPoByPull is '$lockType', expected bit" }
$dfExists = Q "SELECT COUNT(*) FROM sys.default_constraints WHERE name='DF_Pulls_LockPoByPull' AND parent_object_id=OBJECT_ID('dbo.Pulls');"
if ($dfExists -ne '1') { Fail "DF_Pulls_LockPoByPull default constraint missing" }
OK "LockPoByPull BIT NOT NULL with DF_Pulls_LockPoByPull default"

# ========================================================================
# 5. View projects PullId
# ========================================================================
Step "vw_PurchaseOrderAvailability projects PullId"
$vCol = Q @"
SELECT COUNT(*) FROM sys.columns c
INNER JOIN sys.views v ON v.object_id = c.object_id
WHERE v.name = 'vw_PurchaseOrderAvailability' AND c.name = 'PullId';
"@
if ($vCol -ne '1') { Fail "vw_PurchaseOrderAvailability does not project PullId" }
OK "View projects PullId"

# ========================================================================
# 6. Seeded pulls — LockPoByPull = 0 (backward compat)
#    Phase 3.5 introduces PL-2900 + PL-2901 with LockPoByPull = 1
#    (PL-2900 = linked+locked demo; PL-2901 = lock+no-PO fixture).
#    v2.1 flipped the create-form default to true, so any user-created
#    or smoke pull may legitimately be locked. The invariant tested here
#    is "the column-add migration didn't retroactively flip seeded
#    pulls"; explicitly scope to the seeded PL-28xx fixtures.
# ========================================================================
Step "All pre-3.5 seeded pulls (PL-28xx) have LockPoByPull = 0"
$preLocked = Q "SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE 'PL-28%' AND PullNumber NOT IN ('PL-2900','PL-2901') AND LockPoByPull <> 0;"
if ($preLocked -ne '0') { Fail "Some pre-3.5 seeded pulls have LockPoByPull <> 0. Count: $preLocked" }
$seededUnlocked = Q "SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE 'PL-28%' AND LockPoByPull = 0;"
if ([int]$seededUnlocked -lt 12) { Fail "Expected >= 12 seeded unlocked pulls, got $seededUnlocked" }
OK "All 12 seeded PL-28xx pulls retain LockPoByPull = 0"

# ========================================================================
# 7. Linked PO demo — PO-2401-018 → PL-2847
# ========================================================================
Step "PO-2401-018 linked to PL-2847 (linked, unlocked demo)"
$linkedPull = Q @"
SELECT p.PullNumber
FROM   dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE  po.PoNumber = 'PO-2401-018';
"@
if ($linkedPull -ne 'PL-2847') { Fail "PO-2401-018.PullId does not point at PL-2847. Got: '$linkedPull'" }
$pl2847Lock = Q "SELECT LockPoByPull FROM dbo.Pulls WHERE PullNumber = 'PL-2847';"
if ($pl2847Lock -ne '0') { Fail "PL-2847.LockPoByPull should be 0 (linked-but-unlocked demo). Got: '$pl2847Lock'" }
OK "PO-2401-018 ↔ PL-2847 linked, lock=0"

Step "PO-2401-019 + PO-2403-044 remain unlinked (cross-pull pool)"
$unlinked = Q @"
SELECT COUNT(*) FROM dbo.PurchaseOrders
WHERE PoNumber IN ('PO-2401-019','PO-2403-044') AND PullId IS NULL;
"@
if ($unlinked -ne '2') { Fail "Expected 2 unlinked POs (PO-2401-019 + PO-2403-044). Got: $unlinked" }
OK "Both extra WH-01 POs remain pool-shared (PullId IS NULL)"

# ========================================================================
# 8. Strict-mode demo — PL-2900 (lock=1) + PO-2405-001 dedicated
# ========================================================================
Step "PL-2900 exists with LockPoByPull = 1"
$pl2900 = Q "SELECT LockPoByPull FROM dbo.Pulls WHERE PullNumber = 'PL-2900';"
if ($pl2900 -ne '1') { Fail "PL-2900 missing or LockPoByPull != 1. Got: '$pl2900'" }
$pl2900Status = Q "SELECT Status FROM dbo.Pulls WHERE PullNumber = 'PL-2900';"
# 'pending' is the seed state; 'in_progress' is acceptable post-smoke-run (ReceiveAsync auto-promotes
# pending → in_progress on first receipt and never demotes back, which is correct).
if ($pl2900Status -notin 'pending','in_progress') {
    Fail "PL-2900 status should be 'pending' or 'in_progress'. Got: '$pl2900Status'"
}
OK "PL-2900 present, LockPoByPull=1, status=$pl2900Status"

Step "PL-2900 has a PullItem + window (PCBA-AX450-R2)"
$piCount = Q "SELECT COUNT(*) FROM dbo.PullItems pi INNER JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='PL-2900';"
if ($piCount -ne '1') { Fail "PL-2900 expected 1 PullItem, got $piCount" }
$wCount = Q @"
SELECT COUNT(*) FROM dbo.PullItemWindows w
INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = 'PL-2900';
"@
if ($wCount -ne '1') { Fail "PL-2900 expected 1 PullItemWindow, got $wCount" }
OK "PullItem (PCBA-AX450-R2) + 1 window seeded"

Step "PO-2405-001 dedicated to PL-2900 (PullId set + matching warehouse)"
$po501Pull = Q @"
SELECT p.PullNumber
FROM   dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE  po.PoNumber = 'PO-2405-001';
"@
if ($po501Pull -ne 'PL-2900') { Fail "PO-2405-001.PullId does not point at PL-2900. Got: '$po501Pull'" }
$po501Wh = Q @"
SELECT CASE WHEN po.WarehouseId = p.WarehouseId THEN 'match' ELSE 'mismatch' END
FROM   dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE  po.PoNumber = 'PO-2405-001';
"@
if ($po501Wh -ne 'match') { Fail "PO-2405-001.WarehouseId != PL-2900.WarehouseId" }
$po501Line = Q "SELECT COUNT(*) FROM dbo.PurchaseOrderLines WHERE PurchaseOrderId='66666666-6666-6666-6666-000000000012';"
if ($po501Line -ne '1') { Fail "PO-2405-001 expected 1 line, got $po501Line" }
OK "PO-2405-001 linked to PL-2900, same warehouse, 1 PO line"

# ========================================================================
# 9. View read path — strict-mode pull sees only its dedicated PO
# ========================================================================
Step "vw_PurchaseOrderAvailability filtered by PullId (strict-mode query path)"
$strictView = Q @"
SELECT COUNT(*) FROM dbo.vw_PurchaseOrderAvailability v
INNER JOIN dbo.Pulls p ON p.Id = v.PullId
WHERE p.PullNumber = 'PL-2900' AND v.ItemCode = 'PCBA-AX450-R2';
"@
if ($strictView -ne '1') { Fail "Expected exactly 1 view row for PL-2900 + PCBA-AX450-R2. Got $strictView" }
OK "Strict-mode query returns exactly 1 row (PO-2405-001 only)"

# ========================================================================
# 10. FK reject — invalid PullId on PurchaseOrders fails
# ========================================================================
Step "FK_PO_Pull rejects bogus PullId"
$bogus = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -b -Q @"
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
BEGIN TRY
    INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, PullId, OrderDate, Status)
    VALUES (NEWID(), 'PO-FK-REJECT-TEST', '22222222-2222-2222-2222-000000000001',
            '00000000-0000-0000-0000-000000000000', '2026-05-01', 'open');
    PRINT 'INSERT_SUCCEEDED';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() IN (547, 1934)
        PRINT 'FK_REJECTED';
    ELSE
        PRINT CONCAT('OTHER_ERR_', ERROR_NUMBER());
END CATCH
"@ 2>&1 | Out-String
if ($bogus -notmatch 'FK_REJECTED') { Fail "FK did not reject bogus PullId. Output: $bogus" }
# Make sure the test row didn't sneak in
$leaked = Q "SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber='PO-FK-REJECT-TEST';"
if ($leaked -ne '0') { Fail "Test PO leaked despite catch — actual row count: $leaked" }
OK "FK_PO_Pull correctly rejects orphan PullId"

# ========================================================================
# 11. Idempotency — 015 + 016 silent on re-run
# ========================================================================
Step "Re-run 015 is silent (no schema mutation)"
$r15 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\015_schema_po_pull_link.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "015 re-run exited non-zero:`n$r15" }
if ($r15 -match 'Adding PurchaseOrders.PullId' -or $r15 -match 'Adding FK_PO_Pull' -or
    $r15 -match 'Creating filtered index' -or $r15 -match 'Adding Pulls.LockPoByPull') {
    Fail "015 re-run mutated schema (idempotency broken):`n$r15"
}
OK "015 re-run silent"

Step "Re-run 016 is silent (no duplicate seed)"
$r16 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\016_seed_po_pull_link.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "016 re-run exited non-zero:`n$r16" }
if ($r16 -match 'Linking PO-2401-018' -or $r16 -match 'Creating PL-2900' -or
    $r16 -match 'Creating PO-2405-001' -or $r16 -match 'Creating PL-2900 PullItem' -or
    $r16 -match 'Creating PL-2900 PullItemWindow' -or $r16 -match 'Creating PO-2405-001 line') {
    Fail "016 re-run wrote rows (idempotency broken):`n$r16"
}
OK "016 re-run silent"

# ========================================================================
# 12. Counts summary
# ========================================================================
Step "Summary counts"
$totalPulls    = Q "SELECT COUNT(*) FROM dbo.Pulls;"
$lockedPulls   = Q "SELECT COUNT(*) FROM dbo.Pulls WHERE LockPoByPull = 1;"
$linkedPOs     = Q "SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PullId IS NOT NULL;"
$totalPOs      = Q "SELECT COUNT(*) FROM dbo.PurchaseOrders;"
Write-Host "  Pulls: $totalPulls total, $lockedPulls locked"
Write-Host "  PurchaseOrders: $totalPOs total, $linkedPOs linked-to-pull"
if ([int]$lockedPulls -lt 2) { Fail "Expected >= 2 locked pulls (PL-2900 + PL-2901). Got: $lockedPulls" }
if ([int]$linkedPOs -lt 2) { Fail "Expected >= 2 linked POs (PO-2401-018 + PO-2405-001). Got: $linkedPOs" }
OK "Counts in expected range"

Write-Host "`nPhase 3.5 verification passed." -ForegroundColor Green
