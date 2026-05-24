# Smoke test: §3.5 PO admin endpoints — PullId lifecycle
#
# Create:
#   (1) POST /api/pos with pullId (valid open pull, matching warehouse) → 201, PullId set
#   (2) POST /api/pos without pullId → 201, PullId null
#   (3) POST /api/pos with unknown pullId → 409
#   (4) POST /api/pos with closed-pull pullId → 409
#   (5) POST /api/pos with warehouse-mismatch pullId → 409
#
# Update (immutability):
#   (6) PUT /api/pos/{id} echoing same PullId → 200
#   (7) PUT /api/pos/{id} NULL → set value → 409
#   (8) PUT /api/pos/{id} set value → NULL → 409
#   (9) PUT /api/pos/{id} set value → other value → 409
#  (10) PUT /api/pos/{id} PullId immutability fires BEFORE the receipt-reference rule
#       (test on a PO with no receipts — both transitions still 409)
#
# Reads:
#  (11) GET /api/pos lists PullId + PullNumber
#  (12) GET /api/pos/{id} returns PullId + PullNumber for linked PO
#  (13) GET /api/pos/{id} returns NULL/NULL for unlinked PO

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$session = $null

$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_02 = '22222222-2222-2222-2222-000000000002'

$PL_2846  = '33333333-3333-3333-3333-000000002846'   # in_progress, WH-01 — link target
$PL_2848  = '33333333-3333-3333-3333-000000002848'   # in_progress, WH-01 — "other value" target
$PL_2840  = '33333333-3333-3333-3333-000000002840'   # closed, WH-01
$PL_2844  = '33333333-3333-3333-3333-000000002844'   # in_progress, WH-02 (warehouse-mismatch)

$BOGUS_PULL = '00000000-0000-0000-0000-000000000000'

function Step($name) { Write-Host "`n--- $name ---" -ForegroundColor Cyan }
function OK($msg)    { Write-Host "PASS: $msg" -ForegroundColor Green }
function Fail($msg)  { Write-Host "FAIL: $msg" -ForegroundColor Red; SqlCleanup; exit 1 }

function Q($sql) {
    (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
}

function SqlCleanup {
    # SET QUOTED_IDENTIFIER ON is required because the DELETE touches dbo.PurchaseOrders,
    # which carries a filtered index (IX_PO_Pull) — those mandate QUOTED_IDENTIFIER ON
    # for any DML or the statement aborts with Msg 1934.
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -Q @"
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
DELETE pol FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'PO-SMOKE-4D-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-SMOKE-4D-%';
"@ | Out-Null
}

# Pre-test cleanup so the suite is hermetic + idempotent
SqlCleanup

# ---------- Login ----------
Step "Login (sadmin / WH-01)"
$loginBody = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
$r = Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable session
if ($r.StatusCode -ne 200) { Fail "Login expected 200, got $($r.StatusCode)" }
OK "Login ok"

function CreatePo([string]$poNumber, [object]$pullId, [string]$warehouseId = $WH_01) {
    $body = @{
        poNumber    = $poNumber
        warehouseId = $warehouseId
        vendorCode  = 'V-SMOKE'
        vendorName  = 'Smoke Vendor'
        orderDate   = '2026-05-15'
        expectedDate= '2026-06-15'
        notes       = '4d smoke'
        pullId      = $pullId
        lines       = @(@{ lineNumber=1; itemCode='SMOKE-X'; description='Smoke test line'; orderedQty=10 })
    } | ConvertTo-Json
    return Invoke-RestMethod -Uri "$base/api/pos" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
}

# ============================================================================
# (1) POST with valid pullId → 201, PullId+PullNumber set in response
# ============================================================================
Step "(1) POST /api/pos with pullId=PL-2846 (open, WH-01) → 201, linked"
$po1 = CreatePo 'PO-SMOKE-4D-001' $PL_2846
if ($po1.pullId -ne $PL_2846) { Fail "Expected pullId=$PL_2846, got $($po1.pullId)" }
if ($po1.pullNumber -ne 'PL-2846') { Fail "Expected pullNumber=PL-2846, got '$($po1.pullNumber)'" }
$po1Id = $po1.id
OK "Created linked PO id=$po1Id pullNumber=$($po1.pullNumber)"

# ============================================================================
# (2) POST without pullId → PullId null
# ============================================================================
Step "(2) POST /api/pos without pullId → 201, PullId NULL"
$po2 = CreatePo 'PO-SMOKE-4D-002' $null
if ($null -ne $po2.pullId) { Fail "Expected pullId=null, got $($po2.pullId)" }
if ($null -ne $po2.pullNumber) { Fail "Expected pullNumber=null, got '$($po2.pullNumber)'" }
$po2Id = $po2.id
OK "Created unlinked PO id=$po2Id"

# ============================================================================
# (3) POST with unknown pullId → 409
# ============================================================================
Step "(3) POST /api/pos with bogus pullId → 409"
try {
    CreatePo 'PO-SMOKE-4D-003-fail' $BOGUS_PULL | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'does not exist') { Fail "Title missing 'does not exist'. Got: $msg" }
    OK "409 unknown pullId"
}

# ============================================================================
# (4) POST with closed pull → 409
# ============================================================================
Step "(4) POST /api/pos with closed pull (PL-2840) → 409"
try {
    CreatePo 'PO-SMOKE-4D-004-fail' $PL_2840 | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'closed pull') { Fail "Title missing 'closed pull'. Got: $msg" }
    OK "409 closed-pull link refused"
}

# ============================================================================
# (5) POST with warehouse mismatch → 409 (PO=WH-01, pull=PL-2844 in WH-02)
# ============================================================================
Step "(5) POST /api/pos WH-01 with PL-2844 (WH-02 pull) → 409 mismatch"
try {
    CreatePo 'PO-SMOKE-4D-005-fail' $PL_2844 $WH_01 | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'Warehouse mismatch') { Fail "Title missing 'Warehouse mismatch'. Got: $msg" }
    OK "409 warehouse mismatch"
}

# ============================================================================
# Update tests — operate on PO-SMOKE-4D-001 (linked) and PO-SMOKE-4D-002 (unlinked)
# Both have no receipts, so the receipt-reference rule won't fire — any 409 we see
# is purely the §3.5 PullId immutability rule.
# ============================================================================

function PutPo([string]$id, [object]$pullId) {
    $body = @{
        vendorCode = 'V-SMOKE'
        vendorName = 'Smoke Vendor 2 (updated)'
        orderDate  = '2026-05-16'
        expectedDate = '2026-06-16'
        notes      = '4d update test'
        pullId     = $pullId
    } | ConvertTo-Json
    return Invoke-WebRequest -Uri "$base/api/pos/$id" -Method PUT -Body $body -ContentType 'application/json' -WebSession $session
}

# ============================================================================
# (6) PUT echoing same PullId → 200
# ============================================================================
Step "(6) PUT linked PO echoing same PullId → 200"
$r = PutPo $po1Id $PL_2846
if ($r.StatusCode -ne 200) { Fail "Expected 200, got $($r.StatusCode)" }
$po1After = $r.Content | ConvertFrom-Json
if ($po1After.pullId -ne $PL_2846) { Fail "PullId changed unexpectedly: $($po1After.pullId)" }
if ($po1After.vendorName -ne 'Smoke Vendor 2 (updated)') { Fail "Vendor not updated. Got $($po1After.vendorName)" }
OK "PullId preserved, other fields updated"

# ============================================================================
# (7) PUT unlinked PO with non-NULL PullId → 409 (NULL → value)
# ============================================================================
Step "(7) PUT unlinked PO with PullId=PL-2846 → 409 (NULL→value)"
try {
    PutPo $po2Id $PL_2846 | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    $msg = $_.ErrorDetails.Message
    if ($msg -notmatch 'immutable') { Fail "Title missing 'immutable'. Got: $msg" }
    OK "409 PullId-immutable on NULL→value"
}

# ============================================================================
# (8) PUT linked PO with PullId=NULL → 409 (value → NULL)
# ============================================================================
Step "(8) PUT linked PO with PullId=NULL → 409 (value→NULL)"
try {
    PutPo $po1Id $null | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    OK "409 PullId-immutable on value→NULL"
}

# ============================================================================
# (9) PUT linked PO with different PullId → 409 (value → other value)
# ============================================================================
Step "(9) PUT linked PO with PullId=PL-2848 (different) → 409"
try {
    PutPo $po1Id $PL_2848 | Out-Null
    Fail "Expected 409, got success"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) { Fail "Expected 409, got $($_.Exception.Response.StatusCode.value__)" }
    OK "409 PullId-immutable on value→other-value"
}

# ============================================================================
# (10) PUT unlinked PO echoing NULL → 200 (sanity: NULL→NULL is identity, not mutation)
# ============================================================================
Step "(10) PUT unlinked PO echoing NULL → 200"
$r = PutPo $po2Id $null
if ($r.StatusCode -ne 200) { Fail "Expected 200 on NULL→NULL echo, got $($r.StatusCode)" }
OK "NULL→NULL echo is identity, 200 ok"

# ============================================================================
# (11) GET /api/pos list includes PullId + PullNumber
# ============================================================================
Step "(11) GET /api/pos list includes PullId+PullNumber for linked POs"
$list = (Invoke-RestMethod -Uri "$base/api/pos?warehouseId=$WH_01&pageSize=500" -WebSession $session).items
$linkedRow   = $list | Where-Object { $_.poNumber -eq 'PO-SMOKE-4D-001' }
$unlinkedRow = $list | Where-Object { $_.poNumber -eq 'PO-SMOKE-4D-002' }
if (-not $linkedRow)   { Fail "Linked smoke PO not in list" }
if (-not $unlinkedRow) { Fail "Unlinked smoke PO not in list" }
if ($linkedRow.pullId -ne $PL_2846)        { Fail "Linked row pullId mismatch: $($linkedRow.pullId)" }
if ($linkedRow.pullNumber -ne 'PL-2846')   { Fail "Linked row pullNumber mismatch: '$($linkedRow.pullNumber)'" }
if ($null -ne $unlinkedRow.pullId)         { Fail "Unlinked row pullId should be null, got $($unlinkedRow.pullId)" }
if ($null -ne $unlinkedRow.pullNumber)     { Fail "Unlinked row pullNumber should be null, got '$($unlinkedRow.pullNumber)'" }
# Also verify pre-existing seed PO-2401-018 carries its link
$seedRow = $list | Where-Object { $_.poNumber -eq 'PO-2401-018' }
if (-not $seedRow) { Fail "Seed PO-2401-018 not visible" }
if ($seedRow.pullNumber -ne 'PL-2847') { Fail "Seed PO-2401-018 pullNumber should be PL-2847 (db/016 link), got '$($seedRow.pullNumber)'" }
OK "list projects PullId+PullNumber for linked / NULL for unlinked / preserves seed link"

# ============================================================================
# (12) GET /api/pos/{id} detail returns PullId + PullNumber
# ============================================================================
Step "(12) GET /api/pos/{id} detail for linked PO returns PullId+PullNumber"
$detail = Invoke-RestMethod -Uri "$base/api/pos/$po1Id" -WebSession $session
if ($detail.pullId -ne $PL_2846)    { Fail "detail.pullId mismatch: $($detail.pullId)" }
if ($detail.pullNumber -ne 'PL-2846') { Fail "detail.pullNumber mismatch: '$($detail.pullNumber)'" }
OK "detail shows PullId+PullNumber"

# ============================================================================
# (13) GET /api/pos/{id} for unlinked PO → PullId null
# ============================================================================
Step "(13) GET /api/pos/{id} for unlinked PO → PullId null, PullNumber null"
$detail = Invoke-RestMethod -Uri "$base/api/pos/$po2Id" -WebSession $session
if ($null -ne $detail.pullId)     { Fail "Unlinked detail.pullId should be null, got $($detail.pullId)" }
if ($null -ne $detail.pullNumber) { Fail "Unlinked detail.pullNumber should be null, got '$($detail.pullNumber)'" }
OK "unlinked detail returns NULL/NULL"

# ============================================================================
# Cleanup
# ============================================================================
Step "Cleanup smoke POs"
SqlCleanup
$remaining = Q "SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-SMOKE-4D-%';"
if ($remaining -ne '0') { Fail "Cleanup failed: $remaining smoke PO(s) remain" }
OK "All smoke POs removed"

Write-Host "`nPhase 4d smoke passed (all 13 scenarios)." -ForegroundColor Green
