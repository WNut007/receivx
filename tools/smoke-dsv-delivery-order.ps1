# Smoke test: DSV Delivery Order (2nd report).
#
# Exercises the SubInventory x ToLocation grouping + per-line vendor /
# Locator / DN-INV mapping + the new delivery-order-dsv.frx PDF path,
# WITHOUT touching the existing Delivery Note report.
#
#   1. Seed a pull whose two received lines sit in DIFFERENT
#      (SubInventory x ToLocation) movements -> the DSV report must split
#      them into TWO Delivery Orders (two <article class="...dord"> pages).
#   2. GET /api/reports/do/{id}/preview?type=order:
#        - 2 DOs, "DELIVERY ORDER" title, DO# = PullNumber.
#        - per-line Locator = SubInventory.DeliveryDate.OrderId.
#        - per-line DN/INV  = OrderId +InvoiceNo.
#        - header Round = bracketed union of the line hours.
#   3. GET /api/reports/do/{id}/export.pdf?type=order -> %PDF + size floor,
#      and the bootstrapped Reports/delivery-order-dsv.frx exists on disk.
#   4. Regression: ?type=note still renders the Delivery Note (.dsv-do).
#
# Idempotent: PO-DSV-* / PL-DSV-* prefixes match the cleanup wipe.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
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
WHERE p.PullNumber LIKE 'PL-DSV-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-DSV-%';
DELETE FROM dbo.PurchaseOrderLines
 WHERE PurchaseOrderId IN (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-DSV-%');
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-DSV-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}

function SqlSeedDsvPo {
    # One PO, two lines with distinct item codes — each item receives onto
    # its own line so the post-receive ERP stamp can put them in different
    # (SubInventory x ToLocation) movements.
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DECLARE @poId UNIQUEIDENTIFIER = NEWID();
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, ExpectedDate, Status, Notes, CreatedAt)
VALUES (@poId, 'PO-DSV-001',
        '22222222-2222-2222-2222-000000000001',
        '2026-01-01', NULL, 'open',
        N'DSV order smoke dedicated PO', SYSUTCDATETIME());
INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
VALUES (NEWID(), @poId, 1, 'DSVITEM-A', N'DSV smoke item A', 500, 0),
       (NEWID(), @poId, 2, 'DSVITEM-B', N'DSV smoke item B', 500, 0);
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}

SqlCleanup
SqlSeedDsvPo

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

$sv = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
# Setup — pull with two items, each received once, then stamped into two
# different (SubInventory x ToLocation) movements + closed.
# ----------------------------------------------------------------------------
Step "Setup: PL-DSV pull + 2 items + 2 receipts + ERP stamp (2 movements) + close"
$pullNum = "PL-DSV-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$pullBody = @{
    pullNumber = $pullNum; warehouseId = $WH_01
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null
    lockPoByPull = $false; lockHourCap = $false
    referenceNumber = 'INV-DSV-REF'
} | ConvertTo-Json
$pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv

foreach ($it in @(@{ code = 'DSVITEM-A'; h = 7 }, @{ code = 'DSVITEM-B'; h = 9 })) {
    $itemBody = @{
        itemCode = $it.code; description = "DSV smoke $($it.code)"
        windows = @(@{ hourOfDay = $it.h; expectedQty = 50 })
    } | ConvertTo-Json -Depth 5
    $item = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -Body $itemBody -ContentType 'application/json' -WebSession $sv
    $recvBody = @{
        pullItemId = $item.id; hourOfDay = $it.h; qty = 50
        lotBatch = $null; palletId = $null; binLocation = $null; qcStatus = 'pending'; note = $null
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $recvBody -ContentType 'application/json' -WebSession $sv | Out-Null
}

# Stamp the two received lines into two distinct movements. DeliveryDate
# fixed so the Locator middle segment + Order Time are deterministic.
$stampSql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
UPDATE pol
SET SubInventory = 'SUBDSV-A', ToLocation = 'TODSV-A',
    OrderId = 'ORD-DSV-A', InvoiceNo = 'INV-DSV-A',
    VendorCode = 'VA', VendorName = 'Vendor Alpha',
    OrderRound = '07:00|08:00', ProductionLine = '2304',
    DeliveryDate = '2026-05-28'
FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.Receipts r ON r.PurchaseOrderLineId = pol.Id
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = N'__PULLNUM__' AND pol.ItemCode = 'DSVITEM-A';

UPDATE pol
SET SubInventory = 'SUBDSV-B', ToLocation = 'TODSV-B',
    OrderId = 'ORD-DSV-B', InvoiceNo = 'INV-DSV-B',
    VendorCode = 'VB', VendorName = 'Vendor Beta',
    OrderRound = '09:00|10:00', ProductionLine = '2304',
    DeliveryDate = '2026-05-28'
FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.Receipts r ON r.PurchaseOrderLineId = pol.Id
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = N'__PULLNUM__' AND pol.ItemCode = 'DSVITEM-B';
'@.Replace('__PULLNUM__', $pullNum)
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $stampSql 2>&1 | Out-Null

$closeBody = @{ signatureSvg = $SAMPLE_SVG } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $sv | Out-Null
OK "PL-DSV pull set up + closed (2 movements: SUBDSV-A->TODSV-A, SUBDSV-B->TODSV-B)"

# ----------------------------------------------------------------------------
# 1. DSV preview — 2 DOs, title, DO#, per-line Locator / DN-INV, Round union
# ----------------------------------------------------------------------------
Step "GET /preview?type=order -> 2 DSV Delivery Orders + field mapping"
$prev = Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/preview?type=order" -Method GET -WebSession $sv -UseBasicParsing
if ($prev.StatusCode -ne 200) { Fail "Preview returned $($prev.StatusCode)" }
$c = $prev.Content

$articles = ([regex]::Matches($c, '<article class="do-document dord">')).Count
if ($articles -ne 2) { Fail "Expected 2 DSV Delivery Orders (one per movement), got $articles" }

if ($c -notmatch '>DELIVERY ORDER<')            { Fail "Missing 'DELIVERY ORDER' title" }
if ($c -notmatch [regex]::Escape($pullNum))     { Fail "DO# (PullNumber $pullNum) not rendered" }
foreach ($hdr in 'LOCATOR','VENDOR','DN/INV NUMBER','QTY ISSUE','PART NUMBER') {
    if ($c -notmatch ">$([regex]::Escape($hdr))<") { Fail "Line table missing column '$hdr'" }
}
foreach ($hdr in 'ORDER TIME','PRODUCTION LINE','ROUND','FROM SUB','TO SUB') {
    if ($c -notmatch ">$([regex]::Escape($hdr))<") { Fail "DSV header grid missing '$hdr'" }
}
OK "2 DOs render with DELIVERY ORDER title, DO# = PullNumber, all columns + header labels"

# Locator composite (note: + is HTML-encoded; compare on the locator only).
Step "Per-line Locator / DN-INV / Round mapping"
if ($c -notmatch [regex]::Escape('SUBDSV-A.28-MAY-2026.ORD-DSV-A')) { Fail "Locator A wrong/missing (SUBDSV-A.28-MAY-2026.ORD-DSV-A)" }
if ($c -notmatch [regex]::Escape('SUBDSV-B.28-MAY-2026.ORD-DSV-B')) { Fail "Locator B wrong/missing" }
# DN/INV: "ORD-DSV-A +INV-DSV-A" — the '+' renders as &#x2B; (Razor encode).
if ($c -notmatch ('ORD-DSV-A\s*(?:\+|&#x2B;)INV-DSV-A')) { Fail "DN/INV A wrong/missing (ORD-DSV-A +INV-DSV-A)" }
if ($c -notmatch ('ORD-DSV-B\s*(?:\+|&#x2B;)INV-DSV-B')) { Fail "DN/INV B wrong/missing" }
# Round union, bracketed
if ($c -notmatch [regex]::Escape('[07:00],[08:00]')) { Fail "Round A union not bracketed ([07:00],[08:00])" }
if ($c -notmatch [regex]::Escape('[09:00],[10:00]')) { Fail "Round B union not bracketed" }
# Vendor per line
if ($c -notmatch 'Vendor Alpha') { Fail "Vendor Alpha missing" }
if ($c -notmatch 'Vendor Beta')  { Fail "Vendor Beta missing" }
# Order Time (DeliveryDate)
if ($c -notmatch '28-May-2026') { Fail "Order Time (28-May-2026) missing" }
OK "Locator composite + DN/INV (OrderId +Invoice) + bracketed Round union + per-line vendor + Order Time"

# ----------------------------------------------------------------------------
# 2. DSV PDF export — %PDF + size floor + bootstrapped .frx on disk
# ----------------------------------------------------------------------------
Step "GET /export.pdf?type=order -> %PDF + size floor + delivery-order-dsv.frx exists"
$pdf = Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/export.pdf?type=order" -Method GET -WebSession $sv -UseBasicParsing
if ($pdf.StatusCode -ne 200) { Fail "PDF returned $($pdf.StatusCode)" }
if ($pdf.Headers['Content-Type'] -notmatch 'application/pdf') { Fail "Wrong Content-Type" }
$head4 = [System.Text.Encoding]::ASCII.GetString($pdf.Content[0..3])
if ($head4 -ne '%PDF') { Fail "PDF magic bytes wrong: '$head4'" }
# PDFSimpleExport rasterizes each page to JPEG; with logo + barcodes +
# signature the DSV order clears 100KB easily.
if ($pdf.RawContentLength -lt 100000) { Fail "PDF $($pdf.RawContentLength) bytes < 100KB — band probably not emitting" }
$frx = Join-Path $PSScriptRoot '..\src\ReceivingOps.Web\Reports\delivery-order-dsv.frx'
if (-not (Test-Path $frx)) { Fail "delivery-order-dsv.frx was not bootstrapped to disk" }
OK "DSV PDF streams ($($pdf.RawContentLength) bytes) with %PDF + delivery-order-dsv.frx present"

# ----------------------------------------------------------------------------
# 3. Regression — Delivery Note (?type=note) still renders unchanged.
# ----------------------------------------------------------------------------
Step "Regression: ?type=note still renders the Delivery Note (.dsv-do)"
$note = Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/preview?type=note" -Method GET -WebSession $sv -UseBasicParsing
if ($note.StatusCode -ne 200) { Fail "Note preview returned $($note.StatusCode)" }
if ($note.Content -notmatch '<article class="dsv-do"') { Fail "Note preview lost its .dsv-do article" }
if ($note.Content -notmatch '>DELIVERY NOTE<')         { Fail "Note preview lost 'DELIVERY NOTE' title" }
if ($note.Content -match '>DELIVERY ORDER<')           { Fail "Note preview leaked the DSV 'DELIVERY ORDER' title" }
OK "Delivery Note report unaffected by the DSV Delivery Order addition"

SqlCleanup
Write-Host ""
Write-Host "ALL PASS — DSV Delivery Order (grouping + Locator/DN-INV/Round mapping + PDF + Note regression)." -ForegroundColor Green
exit 0
