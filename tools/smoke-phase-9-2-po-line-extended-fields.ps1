# Smoke: Phase 9.2 — PO line extended-fields edit (PUT endpoint + UI markup).
#
# Mirror of smoke-phase-9-1-pull-extended-fields.ps1 on the PO side. 12.7's
# integration smoke proved the importer pipeline lands rows; this proves the
# operator can edit those rows' metadata via the §9.2 UI without a redeploy.
#
# Asserts:
#   1. Find an open PO line for the test target
#   2. Admin PUT /api/pos/{id}/lines/{lineId}/extended-fields → 200
#      + refreshed PoDetail returned + 20 fields persist
#   3. GET /api/pos/{id} round-trips orderId + note + remaining fields
#   4. Supervisor (same WH) PUT → 200 (CanManagePulls covers supervisor)
#   5. Operator PUT → 403 (CanManagePulls policy rejects)
#   6. Closed PO PUT → 409 (BusinessException → friendly title)
#   7. AuditLog row: ActionType='update', EntityType='PurchaseOrderLine',
#      EntityId=lineId, message includes PoNumber + ItemCode
#   8. /Pos page markup includes the "Order ID" column header AND the
#      poLineExtendedFieldsModal block (12 marker greps)
#   9. Cleanup — NULL out the 20 fields so the line returns to clean state

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_03 = '22222222-2222-2222-2222-000000000003'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Skip($m) { Write-Host "SKIP: $m" -ForegroundColor DarkYellow }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Sql($q)  { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }
function SqlRow($q) { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -s "|" -Q $q }

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# ----------------------------------------------------------------------------
# 1. Find an open PO line
# ----------------------------------------------------------------------------
Step "Locate an open PO line at WH-01 for the test target"
$probe = (SqlRow @"
SET NOCOUNT ON;
SELECT TOP 1 po.Id AS PoId, pol.Id AS LineId, po.PoNumber, pol.ItemCode
FROM   dbo.PurchaseOrders po
JOIN   dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.Id
WHERE  po.Status = 'open' AND po.WarehouseId = '$WH_01'
ORDER BY po.CreatedAt;
"@) -join '' -replace '\s',''
$parts = $probe -split '\|'
if ($parts.Count -lt 4) { Fail "No open PO line found at WH-01 — cannot test (got '$probe')" }
$poId    = $parts[0]
$lineId  = $parts[1]
$poNum   = $parts[2]
$itemCode = $parts[3]
OK "Using $poNum line $itemCode (poId=$poId, lineId=$lineId)"

# Save current state so cleanup can restore it.
# Phase 14: VendorCode + VendorName captured first (DB column order matches
# the modal's Tracking section, where vendor sits at the top).
$preState = (SqlRow @"
SET NOCOUNT ON;
SELECT ISNULL(VendorCode,''),      ISNULL(VendorName,''),
       ISNULL(OrderId,''),         ISNULL(AsnNo,''),
       ISNULL(KanbanNo,''),        ISNULL(VendorItem,''),
       ISNULL(Location,''),        ISNULL(SubInventory,''),
       ISNULL(ToLocation,''),      ISNULL(Building,''),
       ISNULL(ProductionLine,''),  ISNULL(PalletId,''),
       ISNULL(VmiPalletId,''),     ISNULL(BatchNo,''),
       ISNULL(InvoiceNo,''),       ISNULL(PCCNo,''),
       ISNULL(ManufacturingControlNo,''),  ISNULL(OrderRound,''),
       ISNULL(ExportDeclarationNo,''),     ISNULL(CustomerReferenceNo,''),
       ISNULL(ManufacturingReferenceNo,''),ISNULL(Note,'')
FROM   dbo.PurchaseOrderLines WHERE Id = '$lineId';
"@) -join '|'

# ----------------------------------------------------------------------------
# 2. Admin update — happy path
# ----------------------------------------------------------------------------
Step "Admin PUT extended-fields → 200 with refreshed PoDetail"
$admin = Login 'sadmin' 'admin' $WH_01
# Phase 14: vendor at line grain (db/036) — VendorCode (≤64) + VendorName
# (≤160) sit at the top of the modal's Tracking section. The payload below
# exercises the round-trip + validator widths.
$payload = @{
    vendorCode               = 'V-SMK-92'
    vendorName               = 'Smoke Vendor 92 Inc'
    orderId                  = 'SMOKE-92-ORD'
    asnNo                    = 'SMOKE-92-ASN'
    kanbanNo                 = 'SMOKE-92-KBN'
    vendorItem               = 'SMOKE-92-VND'
    location                 = 'SMOKE-LOC'
    subInventory             = 'SMOKE-SUB'
    toLocation               = 'SMOKE-TO'
    building                 = 'B1'
    productionLine           = 'PL1'
    palletId                 = 'PALLET-92'
    vmiPalletId              = 'VMI-92'
    batchNo                  = 'BATCH-92'
    invoiceNo                = 'INV-92'
    pccNo                    = 'PCC-92'
    manufacturingControlNo   = 'MCN-92'
    orderRound               = 'R1'
    exportDeclarationNo      = 'EXP-92'
    customerReferenceNo      = 'CR-92'
    manufacturingReferenceNo = 'MR-92'
    note                     = 'Phase 9.2 smoke test note'
} | ConvertTo-Json

$resp = Invoke-RestMethod -Uri "$base/api/pos/$poId/lines/$lineId/extended-fields" `
    -Method PUT -Body $payload -ContentType 'application/json' -WebSession $admin
if (-not $resp.lines)        { Fail "PUT response missing 'lines' array" }
$saved = $resp.lines | Where-Object { $_.id -eq $lineId }
if (-not $saved)              { Fail "Updated line not present in refreshed PoDetail" }
if ($saved.orderId  -ne 'SMOKE-92-ORD')  { Fail "orderId not persisted (got '$($saved.orderId)')" }
if ($saved.note     -ne 'Phase 9.2 smoke test note') { Fail "note not persisted (got '$($saved.note)')" }
if ($saved.palletId -ne 'PALLET-92')     { Fail "palletId not persisted" }
OK "Admin update accepted; orderId/note/palletId all persisted on the refreshed payload"

# ----------------------------------------------------------------------------
# 3. GET /api/pos/{id} round-trips the fields
# ----------------------------------------------------------------------------
Step "GET /api/pos/{id} surfaces the 20 fields cleanly"
$detail = Invoke-RestMethod -Uri "$base/api/pos/$poId" -WebSession $admin
$line = $detail.lines | Where-Object { $_.id -eq $lineId }
if (-not $line)                              { Fail "Updated line missing from GET PoDetail" }
foreach ($pair in @(
    @{Key='vendorCode';               Want='V-SMK-92'},
    @{Key='vendorName';               Want='Smoke Vendor 92 Inc'},
    @{Key='orderId';                  Want='SMOKE-92-ORD'},
    @{Key='asnNo';                    Want='SMOKE-92-ASN'},
    @{Key='subInventory';             Want='SMOKE-SUB'},
    @{Key='palletId';                 Want='PALLET-92'},
    @{Key='invoiceNo';                Want='INV-92'},
    @{Key='manufacturingReferenceNo'; Want='MR-92'},
    @{Key='note';                     Want='Phase 9.2 smoke test note'}
)) {
    if ($line.($pair.Key) -ne $pair.Want) {
        Fail "GET roundtrip mismatch on $($pair.Key): got '$($line.($pair.Key))', expected '$($pair.Want)'"
    }
}
OK "9 sampled fields round-trip cleanly via GET (Phase 14 vendor at line + 6 modal sections)"

# ----------------------------------------------------------------------------
# 4. Supervisor (same WH) — 200
# ----------------------------------------------------------------------------
Step "Supervisor PUT (swattana @ WH-01) → 200"
$sup = Login 'swattana' 'demo1234' $WH_01
$supPayload = ($payload | ConvertFrom-Json)
$supPayload.note = 'Phase 9.2 supervisor update'
$supBody = $supPayload | ConvertTo-Json
$resp2 = Invoke-RestMethod -Uri "$base/api/pos/$poId/lines/$lineId/extended-fields" `
    -Method PUT -Body $supBody -ContentType 'application/json' -WebSession $sup
$saved2 = $resp2.lines | Where-Object { $_.id -eq $lineId }
if ($saved2.note -ne 'Phase 9.2 supervisor update') {
    Fail "Supervisor update did not persist (got '$($saved2.note)')"
}
OK "Supervisor at session-WH can edit (CanManagePulls policy)"

# ----------------------------------------------------------------------------
# 5. Operator (any WH) — 403
# ----------------------------------------------------------------------------
Step "Operator PUT (npatcharin @ WH-03) → 403"
$op = Login 'npatcharin' 'demo1234' $WH_03
$opStatus = 0
try {
    Invoke-WebRequest -Uri "$base/api/pos/$poId/lines/$lineId/extended-fields" `
        -Method PUT -Body $payload -ContentType 'application/json' `
        -WebSession $op -MaximumRedirection 0 | Out-Null
} catch {
    $opStatus = $_.Exception.Response.StatusCode.value__
}
if ($opStatus -ne 403) { Fail "Operator PUT → HTTP $opStatus, expected 403" }
OK "Operator blocked at CanManagePulls policy gate (403)"

# ----------------------------------------------------------------------------
# 6. Closed PO PUT → 409
# ----------------------------------------------------------------------------
Step "Closed PO PUT → 409"
$closedProbe = (SqlRow @"
SET NOCOUNT ON;
SELECT TOP 1 po.Id, pol.Id
FROM   dbo.PurchaseOrders po
JOIN   dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.Id
WHERE  po.Status = 'closed';
"@) -join '' -replace '\s',''
$closedParts = $closedProbe -split '\|'
if ($closedParts.Count -ge 2 -and $closedParts[0]) {
    $closedPoId   = $closedParts[0]
    $closedLineId = $closedParts[1]
    $closedStatus = 0
    $closedBody = $null
    try {
        Invoke-WebRequest -Uri "$base/api/pos/$closedPoId/lines/$closedLineId/extended-fields" `
            -Method PUT -Body $payload -ContentType 'application/json' `
            -WebSession $admin -MaximumRedirection 0 | Out-Null
    } catch {
        $closedStatus = $_.Exception.Response.StatusCode.value__
        $closedBody = $_.ErrorDetails.Message
    }
    if ($closedStatus -ne 409) { Fail "Closed PO PUT → HTTP $closedStatus, expected 409" }
    if ($closedBody -notmatch 'closed|canceled') {
        Fail "Closed PO 409 body missing 'closed' or 'canceled' hint: $closedBody"
    }
    OK "Closed PO refused with 409 + friendly title"
} else {
    Skip "No closed PO with lines found in dev seed — 409 path covered by service unit logic"
}

# ----------------------------------------------------------------------------
# 7. Audit log
# ----------------------------------------------------------------------------
Step "AuditLog has an 'update' row for the line"
$auditCount = (Sql @"
SET NOCOUNT ON;
SELECT COUNT(*)
FROM   dbo.AuditLog
WHERE  ActionType = 'update'
   AND EntityType = 'PurchaseOrderLine'
   AND EntityId   = '$lineId'
   AND OccurredAt >= DATEADD(minute, -5, SYSUTCDATETIME());
"@) -join '' -replace '\s',''
if ([int]$auditCount -lt 2) {
    # Two updates ran (admin + supervisor); each writes one audit row.
    Fail "Expected >=2 recent 'update' audit rows for line $lineId, got $auditCount"
}
$auditMsg = (Sql @"
SET NOCOUNT ON;
SELECT TOP 1 Message
FROM   dbo.AuditLog
WHERE  ActionType = 'update' AND EntityType = 'PurchaseOrderLine' AND EntityId = '$lineId'
ORDER BY OccurredAt DESC;
"@) -join '' -replace '^\s+|\s+$',''
if ($auditMsg -notmatch [regex]::Escape($poNum)) {
    Fail "Audit message missing PoNumber '$poNum': $auditMsg"
}
if ($auditMsg -notmatch [regex]::Escape($itemCode)) {
    Fail "Audit message missing ItemCode '$itemCode': $auditMsg"
}
OK "$auditCount recent audit rows; latest message contains PoNumber + ItemCode"

# ----------------------------------------------------------------------------
# 8. UI markup — Order ID header + modal block present in /Pos page
# ----------------------------------------------------------------------------
Step "/Pos page contains Vendor + Order ID columns + extended-fields modal markup"
$pos = Invoke-WebRequest -Uri "$base/Pos" -WebSession $admin -MaximumRedirection 0
if ($pos.StatusCode -ne 200) { Fail "GET /Pos → $($pos.StatusCode), expected 200" }
$body = $pos.Content
foreach ($marker in @(
    '>Vendor<',                       # Phase 14 — new leftmost ERP column header
    '>Order ID<',                     # Phase 9.2 column header
    'erp-col-first',                  # column class (Phase 14 moved to Vendor)
    'poLineExtendedFieldsModal',      # modal container
    'ef-vendorCode',                  # Phase 14 — Tracking section input
    'ef-vendorName',                  # Phase 14 — Tracking section input
    'ef-orderId',                     # Phase 9.2 input id
    'ef-note',                        # textarea id
    'ef-section-label'                # section divider class
)) {
    if ($body -notmatch [regex]::Escape($marker)) {
        Fail "Required /Pos markup missing: $marker"
    }
}
OK "All 9 UI markers present in /Pos page source (incl. Phase 14 vendor surface)"

# ----------------------------------------------------------------------------
# 9. Cleanup — restore the line to its pre-smoke state
# ----------------------------------------------------------------------------
Step "Restore line to pre-smoke state"
$preFields = $preState -split '\|'
# Build a payload that mirrors the original — null where the field was empty,
# string otherwise. SQL NULL ↔ JSON null ↔ '' from the ISNULL above.
function NullIfEmpty([string]$s) { if ([string]::IsNullOrEmpty($s)) { return $null } else { return $s } }
# Phase 14: VendorCode + VendorName at indices 0 + 1 (DB SELECT order),
# remaining 20 fields shift to indices 2..21.
$cleanupPayload = @{
    vendorCode               = NullIfEmpty $preFields[0]
    vendorName               = NullIfEmpty $preFields[1]
    orderId                  = NullIfEmpty $preFields[2]
    asnNo                    = NullIfEmpty $preFields[3]
    kanbanNo                 = NullIfEmpty $preFields[4]
    vendorItem               = NullIfEmpty $preFields[5]
    location                 = NullIfEmpty $preFields[6]
    subInventory             = NullIfEmpty $preFields[7]
    toLocation               = NullIfEmpty $preFields[8]
    building                 = NullIfEmpty $preFields[9]
    productionLine           = NullIfEmpty $preFields[10]
    palletId                 = NullIfEmpty $preFields[11]
    vmiPalletId              = NullIfEmpty $preFields[12]
    batchNo                  = NullIfEmpty $preFields[13]
    invoiceNo                = NullIfEmpty $preFields[14]
    pccNo                    = NullIfEmpty $preFields[15]
    manufacturingControlNo   = NullIfEmpty $preFields[16]
    orderRound               = NullIfEmpty $preFields[17]
    exportDeclarationNo      = NullIfEmpty $preFields[18]
    customerReferenceNo      = NullIfEmpty $preFields[19]
    manufacturingReferenceNo = NullIfEmpty $preFields[20]
    note                     = NullIfEmpty $preFields[21]
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/pos/$poId/lines/$lineId/extended-fields" `
    -Method PUT -Body $cleanupPayload -ContentType 'application/json' -WebSession $admin | Out-Null
OK "Line restored to pre-smoke state"

Write-Host ""
Write-Host "ALL PASS — Phase 9.2: PO line extended-fields edit + UI markup verified." -ForegroundColor Green
exit 0
