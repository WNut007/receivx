# Smoke test: Delivery Note — INCLUDE ONLY "Transferred from WDT" lines.
# Whitelist rule (not an exclusion): a DN is issued only for lines whose
# PurchaseOrderLines.Note is exactly 'Transferred from WDT'. Every other line —
# including NULL or empty Note — is excluded. The empty DN is the common case.
# Scope is the Delivery Note tab only; the Delivery Order tab is unchanged.
#
# Covers the 4 brief scenarios:
#   1. 4 lines, 1 marked WDT → DN shows just that 1 line; TOTAL = its qty; DO keeps all 4.
#   3. Note=NULL, Note='', Note='Transferred from WDT2' → all EXCLUDED (no LIKE, no NULL-inclusion).
#   2. No marked lines → DN empty state + 'There is no vendor records';
#      DN export → 409; DO tab still renders + its PDF exports 200.
#   4. Multi-order pull, only one order group has a marked line → only that group's
#      page is emitted; DeliveryNoteNo intact; no blank page.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WDT   = 'Transferred from WDT'
$SAMPLE_SVG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

function SqlCleanup {
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-WDT-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-WDT-%';
DELETE FROM dbo.PurchaseOrderLines
 WHERE PurchaseOrderId IN (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-WDT-%');
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-WDT-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}

# Seed three POs whose lines carry OrderId / SubInventory / ToLocation / Vendor /
# Note at INSERT time. Receiving (unique ItemCodes) FIFO-allocates 1:1 to these
# lines, so the Note stamp is deterministic without post-stamping.
function SqlSeedPos {
    $sql = @"
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @poA UNIQUEIDENTIFIER = NEWID();
DECLARE @poB UNIQUEIDENTIFIER = NEWID();
DECLARE @poC UNIQUEIDENTIFIER = NEWID();

INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, ExpectedDate, Status, Notes, CreatedAt)
VALUES (@poA, 'PO-WDT-A', '$WH_01', '2026-01-01', NULL, 'open', N'WDT-only smoke A', SYSUTCDATETIME()),
       (@poB, 'PO-WDT-B', '$WH_01', '2026-01-01', NULL, 'open', N'WDT-only smoke B', SYSUTCDATETIME()),
       (@poC, 'PO-WDT-C', '$WH_01', '2026-01-01', NULL, 'open', N'WDT-only smoke C', SYSUTCDATETIME());

-- Pull A: 4 lines share OrderId ORD-WDTA (one DN article). Only A1 is marked
-- exactly WDT (kept); A2 NULL, A3 '' , A4 'Transferred from WDT2' → all excluded.
INSERT INTO dbo.PurchaseOrderLines
  (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty,
   OrderId, SubInventory, ToLocation, VendorCode, VendorName, Note)
VALUES
  (NEWID(), @poA, 1, 'ITEM-WDTA1', N'A one',   100, 0, 'ORD-WDTA', 'SUB-A', 'TLOC-A', 'V-A', 'Vendor A', N'$WDT'),
  (NEWID(), @poA, 2, 'ITEM-WDTA2', N'A two',   100, 0, 'ORD-WDTA', 'SUB-A', 'TLOC-A', 'V-A', 'Vendor A', NULL),
  (NEWID(), @poA, 3, 'ITEM-WDTA3', N'A three', 100, 0, 'ORD-WDTA', 'SUB-A', 'TLOC-A', 'V-A', 'Vendor A', N''),
  (NEWID(), @poA, 4, 'ITEM-WDTA4', N'A four',  100, 0, 'ORD-WDTA', 'SUB-A', 'TLOC-A', 'V-A', 'Vendor A', N'${WDT}2');

-- Pull B: no marked lines (NULL / '' / WDT2) → empty DN, DN export 409, DO fine.
INSERT INTO dbo.PurchaseOrderLines
  (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty,
   OrderId, SubInventory, ToLocation, VendorCode, VendorName, Note)
VALUES
  (NEWID(), @poB, 1, 'ITEM-WDTB1', N'B one',   500, 0, 'ORD-WDTB', 'SUB-B', 'TLOC-B', 'V-B', 'Vendor B', NULL),
  (NEWID(), @poB, 2, 'ITEM-WDTB2', N'B two',   500, 0, 'ORD-WDTB', 'SUB-B', 'TLOC-B', 'V-B', 'Vendor B', N''),
  (NEWID(), @poB, 3, 'ITEM-WDTB3', N'B three', 500, 0, 'ORD-WDTB', 'SUB-B', 'TLOC-B', 'V-B', 'Vendor B', N'${WDT}2');

-- Pull C: 3 order groups, distinct vendors; only ORD-WDTC1 has a marked line.
-- C2 (NULL) + C3 (WDT2) groups prune away → exactly one DN article survives.
INSERT INTO dbo.PurchaseOrderLines
  (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty,
   OrderId, SubInventory, ToLocation, VendorCode, VendorName, Note)
VALUES
  (NEWID(), @poC, 1, 'ITEM-WDTC1', N'C one',   500, 0, 'ORD-WDTC1', 'SUB-C', 'TLOC-C', 'V-C1', 'Vendor C1', N'$WDT'),
  (NEWID(), @poC, 2, 'ITEM-WDTC2', N'C two',   500, 0, 'ORD-WDTC2', 'SUB-C', 'TLOC-C', 'V-C2', 'Vendor C2', NULL),
  (NEWID(), @poC, 3, 'ITEM-WDTC3', N'C three', 500, 0, 'ORD-WDTC3', 'SUB-C', 'TLOC-C', 'V-C3', 'Vendor C3', N'${WDT}2');
"@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}

SqlCleanup
SqlSeedPos

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

function InvokeStatus($method, $uri, $session) {
    try {
        $r = Invoke-WebRequest -Uri $uri -Method $method -WebSession $session -UseBasicParsing
        return [int]$r.StatusCode
    }
    catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        return [int]$resp.StatusCode
    }
}

# Create a closed pull that receives one qty against each (ItemCode -> qty) pair.
function SeedPull($pullNum, $itemsQty) {
    $pullBody = @{
        pullNumber = $pullNum; warehouseId = $WH_01
        pullDate = (Get-Date -Format 'yyyy-MM-dd')
        eta = $null; notes = $null
        lockPoByPull = $false; lockHourCap = $false
        referenceNumber = $null
    } | ConvertTo-Json
    $pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv

    foreach ($code in $itemsQty.Keys) {
        $qty = [int]$itemsQty[$code]
        $itemBody = @{
            itemCode = $code; description = $code
            windows = @( @{ hourOfDay = 8; expectedQty = $qty } )
        } | ConvertTo-Json -Depth 5
        $item = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -Body $itemBody -ContentType 'application/json' -WebSession $sv
        $recvBody = @{
            pullItemId = $item.id; hourOfDay = 8; qty = $qty
            lotBatch = $null; palletId = $null; binLocation = $null; qcStatus = 'pending'; note = $null
        } | ConvertTo-Json
        Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $recvBody -ContentType 'application/json' -WebSession $sv | Out-Null
    }

    $closeBody = @{ signatureSvg = $SAMPLE_SVG } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $sv | Out-Null
    return $pull
}

$sv = Login 'sadmin' 'admin' $WH_01

$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Step "Setup: seed 3 closed pulls (A/B/C)"
$pullA = SeedPull "PL-WDT-A-$stamp" ([ordered]@{ 'ITEM-WDTA1'=40; 'ITEM-WDTA2'=10; 'ITEM-WDTA3'=20; 'ITEM-WDTA4'=30 })
$pullB = SeedPull "PL-WDT-B-$stamp" ([ordered]@{ 'ITEM-WDTB1'=10; 'ITEM-WDTB2'=20; 'ITEM-WDTB3'=30 })
$pullC = SeedPull "PL-WDT-C-$stamp" ([ordered]@{ 'ITEM-WDTC1'=100; 'ITEM-WDTC2'=200; 'ITEM-WDTC3'=300 })
OK "Pulls A/B/C created + closed"

# ----------------------------------------------------------------------------
# Scenario 1 + 3 — Pull A. DN keeps ONLY ITEM-WDTA1 (exact WDT); excludes A2
# (NULL), A3 (''), A4 ('WDT2'). TOTAL QTY = A1's 40 alone. DO tab keeps all 4.
# ----------------------------------------------------------------------------
Step "Pull A · DN includes ONLY the exact-WDT line; excludes NULL/''/WDT2"
$dnA = Invoke-WebRequest -Uri "$base/api/reports/do/$($pullA.id)/preview?type=note" -Method GET -WebSession $sv -UseBasicParsing
if ($dnA.StatusCode -ne 200) { Fail "DN A preview returned $($dnA.StatusCode)" }
if ($dnA.Content -notmatch '<td class="mono">ITEM-WDTA1</td>') { Fail "DN A missing the only eligible line ITEM-WDTA1" }
foreach ($drop in 'ITEM-WDTA2','ITEM-WDTA3','ITEM-WDTA4') {
    if ($dnA.Content -match "<td class=`"mono`">$drop</td>") { Fail "DN A wrongly shows non-eligible line $drop" }
}
$articlesA = ([regex]::Matches($dnA.Content, '<article class="dsv-do"')).Count
if ($articlesA -ne 1) { Fail "DN A expected 1 article, got $articlesA" }
$totA = [regex]::Match($dnA.Content, 'class="num dsv-total-value">([0-9,]+)<')
if (-not $totA.Success) { Fail "DN A missing dsv-total-value" }
if ($totA.Groups[1].Value.Replace(',','') -ne '40') { Fail "DN A TOTAL QTY expected 40 (A1 alone), got $($totA.Groups[1].Value)" }
OK "DN A: 1 line (ITEM-WDTA1), NULL/''/WDT2 excluded, TOTAL QTY = 40"

Step "Pull A · DO tab keeps all 4 lines (unaffected by the DN whitelist)"
$doA = Invoke-WebRequest -Uri "$base/api/reports/do/$($pullA.id)/preview?type=order" -Method GET -WebSession $sv -UseBasicParsing
if ($doA.StatusCode -ne 200) { Fail "DO A preview returned $($doA.StatusCode)" }
foreach ($code in 'ITEM-WDTA1','ITEM-WDTA2','ITEM-WDTA3','ITEM-WDTA4') {
    if ($doA.Content -notmatch [regex]::Escape($code)) { Fail "DO A missing line $code — DO tab must be unfiltered" }
}
OK "DO A: all 4 lines present (DO tab unaffected)"

# ----------------------------------------------------------------------------
# Scenario 2 + 3 — Pull B. No line marked exactly WDT → empty DN + 409 export;
# DO tab renders + PDF 200.
# ----------------------------------------------------------------------------
Step "Pull B · no eligible line → DN empty state (no articles)"
$dnB = Invoke-WebRequest -Uri "$base/api/reports/do/$($pullB.id)/preview?type=note" -Method GET -WebSession $sv -UseBasicParsing
if ($dnB.StatusCode -ne 200) { Fail "DN B preview returned $($dnB.StatusCode) (empty is a normal 200, not an error)" }
if ($dnB.Content -notmatch 'There is no vendor records') { Fail "DN B missing empty-state headline 'There is no vendor records'" }
if ($dnB.Content -notmatch 'data-dn-empty') { Fail "DN B missing [data-dn-empty] marker (buttons won't disable)" }
if ($dnB.Content -match '<article class="dsv-do"') { Fail "DN B must render zero articles when no line is eligible" }
OK "DN B: empty state rendered, zero articles"

Step "Pull B · DN export.pdf → 409 (refuses blank PDF)"
$sc = InvokeStatus 'GET' "$base/api/reports/do/$($pullB.id)/export.pdf?type=note" $sv
if ($sc -ne 409) { Fail "DN B export expected 409, got $sc" }
OK "DN B: DN PDF export refused with 409"

Step "Pull B · DO tab still renders + PDF exports 200"
$doB = Invoke-WebRequest -Uri "$base/api/reports/do/$($pullB.id)/preview?type=order" -Method GET -WebSession $sv -UseBasicParsing
if ($doB.StatusCode -ne 200) { Fail "DO B preview returned $($doB.StatusCode)" }
if ($doB.Content -notmatch '<article class="do-document dord"') { Fail "DO B must render a delivery-order article" }
$scPdf = InvokeStatus 'GET' "$base/api/reports/do/$($pullB.id)/export.pdf?type=order" $sv
if ($scPdf -ne 200) { Fail "DO B export.pdf expected 200, got $scPdf" }
OK "DO B: preview + PDF export both fine (DO tab unaffected)"

# ----------------------------------------------------------------------------
# Scenario 4 — Pull C. Only ORD-WDTC1 has a marked line. DN emits exactly that
# one group; ORD-WDTC2 + ORD-WDTC3 prune away; no blank page.
# ----------------------------------------------------------------------------
Step "Pull C · only the group with a marked line is emitted; no blank page"
$dnC = Invoke-WebRequest -Uri "$base/api/reports/do/$($pullC.id)/preview?type=note" -Method GET -WebSession $sv -UseBasicParsing
if ($dnC.StatusCode -ne 200) { Fail "DN C preview returned $($dnC.StatusCode)" }
$articlesC = ([regex]::Matches($dnC.Content, '<article class="dsv-do"')).Count
if ($articlesC -ne 1) { Fail "DN C expected 1 article (only ORD-WDTC1 eligible), got $articlesC" }
if ($dnC.Content -notmatch '<div class="dsv-dn-value">ORD-WDTC1</div>') { Fail "DN C missing DeliveryNoteNo ORD-WDTC1" }
foreach ($gone in 'ORD-WDTC2','ORD-WDTC3','ITEM-WDTC2','ITEM-WDTC3') {
    if ($dnC.Content -match [regex]::Escape($gone)) { Fail "DN C still references pruned group content '$gone'" }
}
if ($dnC.Content -notmatch '<td class="mono">ITEM-WDTC1</td>') { Fail "DN C missing eligible line ITEM-WDTC1" }
$rowCountC = ([regex]::Matches($dnC.Content, '<td class="mono">ITEM-WDTC')).Count
if ($rowCountC -ne 1) { Fail "DN C expected exactly 1 surviving line row, got $rowCountC (blank page risk)" }
OK "DN C: 1 article (ORD-WDTC1), C2/C3 pruned, no blank page"

SqlCleanup
Write-Host ""
Write-Host "ALL PASS — DN 'Transferred from WDT' whitelist (include-only + empty state + 409 + DO untouched)." -ForegroundColor Green
exit 0
