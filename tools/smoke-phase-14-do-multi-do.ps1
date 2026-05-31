# Smoke: Phase 14 — one pull spawns multiple DOs when its receipts span
# more than one (Vendor × FromSubInv × ToLoc) triple.
#
# Pre-Phase-14 the DO report grouped by PO alone, so a pull that touched
# two POs got two DOs (one per PO). Phase 14 makes the DO identity the
# shipment triple — a single pull can now spawn 2+ DOs if its receipts
# physically came from different vendors or move between different
# locations.
#
# Setup:
#   1. Create a fresh pull PL-PH14MULTI-* on WH-01.
#   2. Add two pull items, each backed by a dedicated test PO/line so
#      FIFO is unambiguous. Stamp distinct (VendorCode, SubInventory,
#      ToLocation) triples on the two POL rows so the receipts split.
#   3. Receive once per item, close the pull.
#
# Assertions (Path B Stage 7 — DSV class shape):
#   1. /api/reports/do/{id}/preview returns 200.
#   2. The preview contains exactly TWO <article class="dsv-do"> blocks —
#      one per grouping triple.
#   3. Each DO's info grid carries one of the two seeded vendor names as
#      a <dd> following the <dt>VENDOR</dt> label. (Pre-Stage-7 the
#      vendor lived in a top-level .do-number element; the DSV layout
#      moved it to the structured info grid.)
#   4. The two DOs show distinct From sub-inventory + To location values
#      matching the seeded stamps.
#
# Self-cleaning. Test data prefix PH14MULTI-* (collision-free).

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'

# 1x1 white PNG dataURL — DO close requires a signature.
$SAMPLE_SIG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }
function Sql($q)  { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }

function Cleanup {
    Sql @"
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-PH14MULTI-%';
DELETE FROM dbo.PullItems WHERE PullId IN (SELECT Id FROM dbo.Pulls WHERE PullNumber LIKE 'PL-PH14MULTI-%');
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-PH14MULTI-%';
DELETE FROM dbo.PurchaseOrderLines
 WHERE PurchaseOrderId IN (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-PH14MULTI-%');
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-PH14MULTI-%';
"@ | Out-Null
}

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

Cleanup

$admin = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
# 1. Seed two test POs (one per vendor), each with a single line
# ----------------------------------------------------------------------------
Step "Seed PO-PH14MULTI-A + PO-PH14MULTI-B with distinct vendor + location stamps"
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$poA = [Guid]::NewGuid().ToString()
$poB = [Guid]::NewGuid().ToString()
$lineA = [Guid]::NewGuid().ToString()
$lineB = [Guid]::NewGuid().ToString()
$poAnum = "PO-PH14MULTI-A-$ts"
$poBnum = "PO-PH14MULTI-B-$ts"

Sql @"
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, ExpectedDate, Status, Notes, CreatedAt)
VALUES ('$poA', '$poAnum', '$WH_01', '2026-01-01', NULL, 'open', N'Phase 14 multi-DO smoke vendor A', SYSUTCDATETIME());
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, ExpectedDate, Status, Notes, CreatedAt)
VALUES ('$poB', '$poBnum', '$WH_01', '2026-01-02', NULL, 'open', N'Phase 14 multi-DO smoke vendor B', SYSUTCDATETIME());

-- Stage 8 wide-content coverage: vendor names + ERP fields are stamped at
-- ERP-typical lengths (~30 chars / ~14 chars) instead of the original
-- ~18 chars. Older Stage 8 fixtures only triggered ≤2-line wrap, which
-- is why the master-band CanGrow strikethrough trigger (VendorName ≥30
-- chars wrapping in the info grid's right-value cell) slipped past the
-- battery. These widths still wrap on detail cells but stay ≤2 lines,
-- so the regression case is exercised end-to-end.
INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName, SubInventory, ToLocation, PalletId, KanbanNo, AsnNo, OrderRound, InvoiceNo)
VALUES ('$lineA', '$poA', 1, 'PH14MULTI-ITEM-A', N'Multi-DO smoke item A', 100, 0,
        'V-MULTI-A', N'Multi Vendor Alpha (BRANCH OFFICE)', 'SUBINV-AAA', 'LOC-ALPHA',
        'PALLET-MULTI-A-001', '0000099001', 'ASN-MULTI-A-001', '07:00', 'INV-MULTI-A');
INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName, SubInventory, ToLocation, PalletId, KanbanNo, AsnNo, OrderRound, InvoiceNo)
VALUES ('$lineB', '$poB', 1, 'PH14MULTI-ITEM-B', N'Multi-DO smoke item B', 100, 0,
        'V-MULTI-B', N'Multi Vendor Beta Industries Ltd.', 'SUBINV-BBB', 'LOC-BETA',
        'PALLET-MULTI-B-001', '0000099002', 'ASN-MULTI-B-001', '07:00', 'INV-MULTI-B');
"@ | Out-Null
OK "Two POs seeded with distinct (Vendor × SubInv × ToLoc) triples + wide ERP stamps"

# ----------------------------------------------------------------------------
# 2. Create the pull + 2 items + receive against each + close
# ----------------------------------------------------------------------------
Step "Create pull + 2 items + 1 receipt each + close"
$pullNum = "PL-PH14MULTI-$ts"
$pullBody = @{
    pullNumber = $pullNum; warehouseId = $WH_01
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null
    lockPoByPull = $false; lockHourCap = $false
    referenceNumber = 'INV-PH14MULTI'
} | ConvertTo-Json
$pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $admin

# Item A: targets the PO-PH14MULTI-A line
$itemABody = @{
    itemCode = 'PH14MULTI-ITEM-A'; description = 'Multi-DO smoke item A'
    windows = @(@{ hourOfDay = 10; expectedQty = 40 })
} | ConvertTo-Json -Depth 5
$itemA = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -Body $itemABody -ContentType 'application/json' -WebSession $admin

# Item B: targets the PO-PH14MULTI-B line
$itemBBody = @{
    itemCode = 'PH14MULTI-ITEM-B'; description = 'Multi-DO smoke item B'
    windows = @(@{ hourOfDay = 11; expectedQty = 50 })
} | ConvertTo-Json -Depth 5
$itemB = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -Body $itemBBody -ContentType 'application/json' -WebSession $admin

# One receive per item — FIFO picks the only candidate line each time.
foreach ($recv in @(
    @{ id = $itemA.id; hour = 10; qty = 40 },
    @{ id = $itemB.id; hour = 11; qty = 50 }
)) {
    $body = @{
        pullItemId = $recv.id; hourOfDay = $recv.hour; qty = $recv.qty
        lotBatch = $null; palletId = $null; binLocation = $null; qcStatus = 'pending'; note = $null
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin | Out-Null
}

$closeBody = @{ signatureSvg = $SAMPLE_SIG } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $admin | Out-Null
OK "Pull closed with 2 receipts spanning 2 vendor/location triples"

# ----------------------------------------------------------------------------
# 3. DO preview should return TWO articles (Stage 7 DSV class: .dsv-do)
# ----------------------------------------------------------------------------
Step "GET /api/reports/do/{id}/preview → expect 2 .dsv-do blocks"
$prev = Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/preview" -Method GET -WebSession $admin -UseBasicParsing
if ($prev.StatusCode -ne 200) { Fail "Preview returned $($prev.StatusCode)" }

$articleCount = ([regex]::Matches($prev.Content, '<article class="dsv-do"')).Count
if ($articleCount -ne 2) {
    Fail "Expected 2 .dsv-do blocks (one per Vendor x SubInv x ToLoc triple), got $articleCount"
}
OK "Preview rendered 2 separate DOs"

# ----------------------------------------------------------------------------
# 4. Each DO's info grid carries a vendor name + From/To sentinels present
#    DSV info grid pattern: <dt>VENDOR</dt><dd>Vendor Name</dd>. The closing
#    </dt> is the boundary so VENDOR doesn't bleed into VENDOR ID / INVOICE.
# ----------------------------------------------------------------------------
Step "Each DO info grid carries one vendor + matching From/To"
$vendorNames = @(
    [regex]::Matches($prev.Content, '<dt>VENDOR</dt>\s*<dd[^>]*>([^<]*)</dd>') |
        ForEach-Object { $_.Groups[1].Value.Trim() }
)
if ($vendorNames.Count -ne 2) {
    Fail "Expected 2 VENDOR dd values in info grid, got $($vendorNames.Count) — multi-DO split missing"
}

# Order may be vendor-code-alphabetical; both names must be present regardless.
# Stage 8 — names lengthened to ~33 chars to exercise the master info grid's
# right-value cell (which used to wrap and trigger the strikethrough bug).
$expectedNames = @('Multi Vendor Alpha (BRANCH OFFICE)', 'Multi Vendor Beta Industries Ltd.')
foreach ($want in $expectedNames) {
    if ($vendorNames -notcontains $want) {
        Fail "Expected vendor name '$want' as a VENDOR dd, got: $($vendorNames -join ' | ')"
    }
}

# From + To sentinel values from the seed should both be present somewhere
# in the preview (one in each DO's info grid FROM / TO row).
foreach ($val in 'SUBINV-AAA','SUBINV-BBB','LOC-ALPHA','LOC-BETA') {
    if ($prev.Content -notmatch [regex]::Escape($val)) {
        Fail "Expected stamped value '$val' missing from preview — DO grouping triple not surfacing"
    }
}
OK "Both vendor names in VENDOR dd cells; SUBINV-AAA/BBB + LOC-ALPHA/BETA all present"

# ----------------------------------------------------------------------------
# 5. Path B Stage 8 regression guard — master-detail relation must reach the
#    .frx Dictionary as a <Relation> element. FastReport's
#    RegisterData(DataSet) silently drops System.Data.DataRelations on Save;
#    the template builder has to construct a native FastReport.Data.Relation
#    and Add it to report.Dictionary.Relations directly. Without that, the
#    detail band's Relation="OrdersLines" attribute is a dangling string
#    reference on Load → Prepare iterates EVERY Lines row per master row →
#    each DO page shows every other DO's lines (cross-product).
#
#    This assertion is the gap-closer for the Stage 8 miss: the original
#    multi-DO smoke verified the HTML preview path only, which doesn't go
#    through FastReport at all. The PDF cross-product bug was invisible to
#    the smoke battery until it hit production data.
# ----------------------------------------------------------------------------
Step ".frx Dictionary carries the OrdersLines <Relation> element"
$frxPath = Join-Path $repoRoot "src\ReceivingOps.Web\Reports\delivery-order.frx"
if (-not (Test-Path $frxPath)) {
    Fail ".frx not auto-generated at $frxPath after PDF export — EnsureFrxExists never ran"
}
$frx = Get-Content -Raw $frxPath
if ($frx -notmatch '<Relation\s+Name="OrdersLines"') {
    Fail @"
Cross-product regression: .frx Dictionary missing <Relation Name="OrdersLines" ...>.
Detail band's Relation attribute will be a dangling reference at Load time;
every DO page will repeat every other DO's lines.
"@
}
OK ".frx Dictionary has OrdersLines master-detail relation"

# ----------------------------------------------------------------------------
# 6. PDF export for the multi-DO pull — basic %PDF + size health.
#    The PDF size delta from the cross-product bug is too small relative to
#    PDFSimpleExport's JPEG-per-page baseline (~600KB) for a tight ceiling
#    to be reliable. The structural .frx check above is the primary catch;
#    this step proves the multi-DO PDF path reaches the export pipeline at
#    all (the Path B pipeline can crash at Prepare on template-compile bugs
#    like the [TotalRows#] regression Stage 7 surfaced).
# ----------------------------------------------------------------------------
Step "GET /api/reports/do/{id}/export.pdf → 200 + %PDF + size floor"
$pdf = Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/export.pdf" -Method GET -WebSession $admin -UseBasicParsing
if ($pdf.StatusCode -ne 200) { Fail "Multi-DO PDF returned $($pdf.StatusCode)" }
$head4 = [System.Text.Encoding]::ASCII.GetString($pdf.Content[0..3])
if ($head4 -ne '%PDF') { Fail "Multi-DO PDF magic bytes wrong: '$head4'" }
if ($pdf.RawContentLength -lt 100000) {
    Fail "Multi-DO PDF $($pdf.RawContentLength) bytes < 100KB — PageFooterBand or core band content missing"
}
OK "Multi-DO PDF streams ($($pdf.RawContentLength) bytes) attachment with %PDF magic"

Cleanup
Write-Host ""
Write-Host "ALL PASS — Phase 14: one pull spawned 2 DOs split by (Vendor × FromSubInv × ToLoc)." -ForegroundColor Green
exit 0
