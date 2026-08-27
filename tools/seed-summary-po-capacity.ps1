# Restores the SUMMARY purchase-order coverage in WH-01 that db/014 seeded and
# db/035 removed.
#
# WHY THIS EXISTS
# ---------------
# db/014_seed_smoke_po_lines.sql seeded PO capacity for the SUMMARY item code in
# WH-01 so smoke fixtures have something to receive against. Several smokes
# depend on it — smoke-hourcap-6.2.ps1 says so in its own header:
#
#     "attach a SUMMARY item (db/014 already seeded SUMMARY PO coverage at 50k
#      capacity in WH-01)"
#
# db/035_wipe_for_phase_14.sql then wiped every transactional table, including
# dbo.PurchaseOrders and dbo.PurchaseOrderLines, and db/014 was never re-run.
# The assumption in those smoke headers has been false on any database that has
# had db/035 applied. The failure is confusing rather than obvious: the smoke
# gets "Insufficient PO capacity. Need 100, have 0 pcs." from a receive that
# looks like it should work, so the natural first suspicion is the receive code.
#
# This script is idempotent and safe to re-run: it tops the capacity back up to
# the target only if the open capacity has fallen below it.
#
# NOTE ON CAPACITY DRAIN
# ----------------------
# The older smokes delete their pulls and receipts on cleanup but never restore
# PurchaseOrderLines.ReceivedQty, so every run consumes a slice of shared
# capacity permanently. The suite therefore has a finite number of runs before
# it starts failing for reasons unrelated to the code under test. Re-run this
# script when that happens. The newer variance smokes
# (smoke-variance-*.ps1) seed their own PO per case and do not drain anything.
#
#   pwsh -File tools\seed-summary-po-capacity.ps1
#   pwsh -File tools\seed-summary-po-capacity.ps1 -Target 50000 -Server LAPTOP-CSB3KO3E

[CmdletBinding()]
param(
    [string] $Server    = 'LAPTOP-CSB3KO3E',
    [string] $Database  = 'ReceivingOps',
    [string] $ItemCode  = 'SUMMARY',
    [string] $WarehouseId = '22222222-2222-2222-2222-000000000001',
    [int]    $Target    = 50000
)

$ErrorActionPreference = 'Stop'

# Guard: this seeds fixture data and must never be pointed at production.
if ($Server -notmatch '^(LAPTOP-|localhost|\.|\(local\))') {
    throw "Refusing to seed fixture data into '$Server'. This script is for a local dev server only."
}

$openSql = @"
SET NOCOUNT ON;
SELECT ISNULL(SUM(pol.OrderedQty - pol.ReceivedQty), 0)
FROM dbo.PurchaseOrderLines pol
JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.WarehouseId = '$WarehouseId'
  AND pol.ItemCode   = '$ItemCode'
  AND po.Status      = 'open';
"@

$current = [int](sqlcmd -S $Server -E -C -d $Database -I -h -1 -W -Q $openSql).Trim()
Write-Host "Current open $ItemCode capacity in WH-01: $current"

if ($current -ge $Target) {
    Write-Host "Already at or above the $Target target — nothing to do." -ForegroundColor Green
    exit 0
}

$needed  = $Target - $current
$poNum   = "PO-SEED-$ItemCode-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$insert  = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRAN;

DECLARE @PoId UNIQUEIDENTIFIER = NEWID();

INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, Status, Notes, CreatedBy)
SELECT @PoId, '$poNum', '$WarehouseId', CAST(SYSUTCDATETIME() AS date), 'open',
       'Fixture capacity: restores what db/014 seeded and db/035 removed. See tools/seed-summary-po-capacity.ps1',
       (SELECT TOP 1 Id FROM dbo.Users ORDER BY Id);

INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
VALUES (NEWID(), @PoId, 1, '$ItemCode', 'Smoke fixture capacity (db/014 intent)', $needed, 0);

COMMIT;
PRINT 'Seeded $poNum with $needed pcs of $ItemCode.';
"@

sqlcmd -S $Server -E -C -d $Database -I -b -Q $insert
if ($LASTEXITCODE -ne 0) { throw "Seed failed (sqlcmd exit $LASTEXITCODE)." }

$after = [int](sqlcmd -S $Server -E -C -d $Database -I -h -1 -W -Q $openSql).Trim()
Write-Host "Open $ItemCode capacity in WH-01 is now: $after" -ForegroundColor Green
if ($after -lt $Target) { throw "Expected at least $Target after seeding, got $after." }
exit 0
