# Verify Phase 1b: NOT NULL + FK + CK + new index + that the new constraints
# actually reject bad data + that the existing smoke battery still passes.

$ErrorActionPreference = 'Stop'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Q($sql) {
    # -I enables QUOTED_IDENTIFIER which the filtered IX_Receipts_Reverses index
    # requires for INSERTs into Receipts.
    return (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
}

# ============================================================================
# 0a. Re-run Phase 2 backfill first — idempotent, and cleans up any new smoke
#     residue / orphan receipts that may have accumulated between Phase 2 and
#     Phase 1b. The orphans are usually SUMMARY-item smoke receipts that 2.0
#     deletes.
# ============================================================================
Step "Cleanup pre-step: re-run db/012_backfill_receipts.sql (idempotent)"
$out0 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\012_backfill_receipts.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "012 re-run failed:`n$out0" }
Write-Host $out0

# ============================================================================
# 0b. Apply Phase 1b
# ============================================================================
Step "Apply db/011_schema_v2_strict.sql"
$out = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\011_schema_v2_strict.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "011 failed:`n$out" }
Write-Host $out

# ============================================================================
# 1. NOT NULL
# ============================================================================
Step "Receipts.PurchaseOrderId is NOT NULL"
$n1 = Q "SELECT is_nullable FROM sys.columns WHERE Name='PurchaseOrderId' AND Object_ID=OBJECT_ID('dbo.Receipts');"
if ($n1 -ne '0') { Fail "PurchaseOrderId still nullable: '$n1'" }
OK "PurchaseOrderId is NOT NULL"

Step "Receipts.PurchaseOrderLineId is NOT NULL"
$n2 = Q "SELECT is_nullable FROM sys.columns WHERE Name='PurchaseOrderLineId' AND Object_ID=OBJECT_ID('dbo.Receipts');"
if ($n2 -ne '0') { Fail "PurchaseOrderLineId still nullable: '$n2'" }
OK "PurchaseOrderLineId is NOT NULL"

# ============================================================================
# 2. Foreign keys
# ============================================================================
Step "FK_Receipts_PO + FK_Receipts_POLine exist"
$fkPo = Q "SELECT COUNT(*) FROM sys.foreign_keys WHERE name='FK_Receipts_PO' AND parent_object_id=OBJECT_ID('dbo.Receipts');"
if ($fkPo -ne '1') { Fail "FK_Receipts_PO missing" }
$fkPol = Q "SELECT COUNT(*) FROM sys.foreign_keys WHERE name='FK_Receipts_POLine' AND parent_object_id=OBJECT_ID('dbo.Receipts');"
if ($fkPol -ne '1') { Fail "FK_Receipts_POLine missing" }
OK "Both FKs present"

# ============================================================================
# 3. Check constraint
# ============================================================================
Step "CK_Receipts_ReversalIntegrity exists"
$ck = Q "SELECT COUNT(*) FROM sys.check_constraints WHERE name='CK_Receipts_ReversalIntegrity' AND parent_object_id=OBJECT_ID('dbo.Receipts');"
if ($ck -ne '1') { Fail "CK_Receipts_ReversalIntegrity missing" }
OK "CK_Receipts_ReversalIntegrity present"

# ============================================================================
# 4. New index
# ============================================================================
Step "IX_Receipts_POLine index exists"
$ix = Q "SELECT COUNT(*) FROM sys.indexes WHERE name='IX_Receipts_POLine' AND object_id=OBJECT_ID('dbo.Receipts');"
if ($ix -ne '1') { Fail "IX_Receipts_POLine missing" }
OK "IX_Receipts_POLine present"

# ============================================================================
# 5. Constraints actually reject bad data — manual probes
# ============================================================================
Step "CK rejects: positive qty with ReversesReceiptId set (would be 'partial reversal')"
$probe1 = @"
SET NOCOUNT ON;
DECLARE @pi UNIQUEIDENTIFIER = (SELECT TOP 1 PullItemId FROM dbo.Receipts WHERE PurchaseOrderLineId IS NOT NULL);
DECLARE @po UNIQUEIDENTIFIER = (SELECT TOP 1 PurchaseOrderId FROM dbo.Receipts WHERE PullItemId=@pi);
DECLARE @pol UNIQUEIDENTIFIER = (SELECT TOP 1 PurchaseOrderLineId FROM dbo.Receipts WHERE PullItemId=@pi);
DECLARE @orig UNIQUEIDENTIFIER = (SELECT TOP 1 Id FROM dbo.Receipts WHERE PullItemId=@pi AND QtyReceived > 0);
DECLARE @actor UNIQUEIDENTIFIER = (SELECT TOP 1 Id FROM dbo.Users WHERE Username='sadmin');
BEGIN TRY
    INSERT INTO dbo.Receipts (PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, QcStatus, ReceivedBy, ReversesReceiptId)
    VALUES (@pi, @po, @pol, 12, 50, 'pending', @actor, @orig);   -- positive + ReversesReceiptId → must violate CK
    PRINT 'NO_ERROR';
END TRY
BEGIN CATCH
    PRINT CONCAT('CAUGHT:', ERROR_NUMBER(), ':', ERROR_MESSAGE());
END CATCH
"@
$r1 = Q $probe1
if ($r1 -notmatch '^CAUGHT:547:') { Fail "Expected error 547 (constraint), got: $r1" }
OK "Positive + ReversesReceiptId rejected by CK"

Step "CK rejects: negative qty without ReversesReceiptId (orphan reversal)"
$probe2 = @"
SET NOCOUNT ON;
DECLARE @pi UNIQUEIDENTIFIER = (SELECT TOP 1 PullItemId FROM dbo.Receipts WHERE PurchaseOrderLineId IS NOT NULL);
DECLARE @po UNIQUEIDENTIFIER = (SELECT TOP 1 PurchaseOrderId FROM dbo.Receipts WHERE PullItemId=@pi);
DECLARE @pol UNIQUEIDENTIFIER = (SELECT TOP 1 PurchaseOrderLineId FROM dbo.Receipts WHERE PullItemId=@pi);
DECLARE @actor UNIQUEIDENTIFIER = (SELECT TOP 1 Id FROM dbo.Users WHERE Username='sadmin');
BEGIN TRY
    INSERT INTO dbo.Receipts (PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, QcStatus, ReceivedBy)
    VALUES (@pi, @po, @pol, 12, -50, 'pending', @actor);   -- negative without ReversesReceiptId
    PRINT 'NO_ERROR';
END TRY
BEGIN CATCH
    PRINT CONCAT('CAUGHT:', ERROR_NUMBER(), ':', ERROR_MESSAGE());
END CATCH
"@
$r2 = Q $probe2
if ($r2 -notmatch '^CAUGHT:547:') { Fail "Expected 547, got: $r2" }
OK "Negative qty without ReversesReceiptId rejected by CK"

Step "FK rejects: PurchaseOrderId pointing at a non-existent PO"
$probe3 = @"
SET NOCOUNT ON;
DECLARE @pi UNIQUEIDENTIFIER = (SELECT TOP 1 PullItemId FROM dbo.Receipts WHERE PurchaseOrderLineId IS NOT NULL);
DECLARE @pol UNIQUEIDENTIFIER = (SELECT TOP 1 PurchaseOrderLineId FROM dbo.Receipts WHERE PullItemId=@pi);
DECLARE @actor UNIQUEIDENTIFIER = (SELECT TOP 1 Id FROM dbo.Users WHERE Username='sadmin');
BEGIN TRY
    INSERT INTO dbo.Receipts (PullItemId, PurchaseOrderId, PurchaseOrderLineId, HourOfDay, QtyReceived, QcStatus, ReceivedBy)
    VALUES (@pi, '00000000-0000-0000-0000-000000000000', @pol, 12, 50, 'pending', @actor);
    PRINT 'NO_ERROR';
END TRY
BEGIN CATCH
    PRINT CONCAT('CAUGHT:', ERROR_NUMBER(), ':', LEFT(ERROR_MESSAGE(),60));
END CATCH
"@
$r3 = Q $probe3
if ($r3 -notmatch '^CAUGHT:547:') { Fail "Expected 547 FK violation, got: $r3" }
OK "Dangling PurchaseOrderId rejected by FK"

Step "NOT NULL rejects: INSERT without PurchaseOrderId"
$probe4 = @"
SET NOCOUNT ON;
DECLARE @pi UNIQUEIDENTIFIER = (SELECT TOP 1 PullItemId FROM dbo.Receipts WHERE PurchaseOrderLineId IS NOT NULL);
DECLARE @actor UNIQUEIDENTIFIER = (SELECT TOP 1 Id FROM dbo.Users WHERE Username='sadmin');
BEGIN TRY
    INSERT INTO dbo.Receipts (PullItemId, HourOfDay, QtyReceived, QcStatus, ReceivedBy)
    VALUES (@pi, 12, 50, 'pending', @actor);
    PRINT 'NO_ERROR';
END TRY
BEGIN CATCH
    PRINT CONCAT('CAUGHT:', ERROR_NUMBER());
END CATCH
"@
$r4 = Q $probe4
if ($r4 -notmatch '^CAUGHT:515') { Fail "Expected 515 (Cannot insert NULL), got: $r4" }
OK "Missing PurchaseOrderId rejected by NOT NULL (error 515)"

# ============================================================================
# 6. Idempotency
# ============================================================================
Step "Idempotency: re-run 011 is silent"
$rerun = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -i C:\dev\receivx\db\011_schema_v2_strict.sql 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "Re-run failed:`n$rerun" }
if ($rerun -match 'Tightening|Adding|Creating index') {
    Fail "Re-run did work; not idempotent. Output:`n$rerun"
}
OK "Re-run produced no schema changes"

# ============================================================================
# 7. Regression: existing smoke battery (note: smoke-receive expects to be
#    able to create receipts; since /api/receipts in v1 doesn't supply PO
#    columns, this is the moment that goes RED until v2 receive service ships)
# ============================================================================
Step "Existing smoke suites — EXPECTED to fail on receive paths (v1 service can't write the new NOT NULL columns)"
$ErrorActionPreference = 'Continue'
$smokes = @(
    @{ name='smoke-receive.ps1';                  mustPass=$false; reason='POST /api/receipts now requires PO columns' },
    @{ name='smoke-stage-b.ps1';                  mustPass=$false; reason='same' },
    @{ name='smoke-transactions.ps1';             mustPass=$false; reason='seeds new receipts in setUp' },
    @{ name='smoke-close-reopen.ps1';             mustPass=$false; reason='resets a pull then receives' },
    @{ name='smoke-polish.ps1';                   mustPass=$true;  reason='no new receipts in this suite' },
    @{ name='smoke-masters.ps1';                  mustPass=$true;  reason='no receipts' },
    @{ name='smoke-masters-config-pages.ps1';     mustPass=$true;  reason='no receipts' },
    @{ name='smoke-receiving-view.ps1';           mustPass=$true;  reason='page-only check' },
    @{ name='smoke-receiving-page-stage-b.ps1';   mustPass=$true;  reason='page-only' },
    @{ name='smoke-transactions-page.ps1';        mustPass=$true;  reason='page-only' }
)
$unexpectedFail = @()
$expectedFail   = @()
$pass           = @()
foreach ($s in $smokes) {
    # Run the smoke in a child pwsh so its noisy stack traces don't bleed
    # into this verifier's output. Capture exit code + tail only.
    $logPath = "C:\dev\receivx\tools\.smoke-$($s.name).log"
    pwsh -NoProfile -File "C:\dev\receivx\tools\$($s.name)" *> $logPath 2>&1
    $code = $LASTEXITCODE
    $tail = (Get-Content $logPath -Tail 6 | Out-String).Trim()
    Remove-Item $logPath -Force
    $ok = ($code -eq 0 -and $tail -notmatch '(?im)^FAIL')
    if ($ok) {
        Write-Host "  [PASS] $($s.name)" -ForegroundColor Green
        $pass += $s.name
    } elseif (-not $s.mustPass) {
        Write-Host "  [SKIP] $($s.name) — expected to fail until Phase 4 ($($s.reason))" -ForegroundColor DarkYellow
        $expectedFail += $s.name
    } else {
        Write-Host "  [FAIL] $($s.name) (exit=$code)" -ForegroundColor Red
        $tail -split "`n" | Select-Object -Last 4 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkRed }
        $unexpectedFail += $s.name
    }
}
$ErrorActionPreference = 'Stop'
Write-Host ""
Write-Host ("Pass: {0} / Expected-fail: {1} / Unexpected-fail: {2}" -f $pass.Count, $expectedFail.Count, $unexpectedFail.Count)
if ($unexpectedFail.Count -gt 0) {
    Fail "Unexpected smoke regression: $($unexpectedFail -join ', ')"
}
OK "Smoke suite behaves as expected — receive paths gated until Phase 4"

Write-Host "`nPhase 1b verification PASSED." -ForegroundColor Green
Write-Host "Phase 1b is the deliberate cutover point: /api/receipts will 515-error" -ForegroundColor Yellow
Write-Host "until Phase 4 ships the FIFO-allocating ReceiveAsync that writes PO columns." -ForegroundColor Yellow
