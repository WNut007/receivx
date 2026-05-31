# Stage 7 visual-parity capture — Path B / DSV redesign.
# Mirrors smoke-do-report.ps1 setup to seed PL-DOR-* + PO-DOR-SUMMARY,
# closes the pull with a sample PNG signature, then captures both the
# DSV HTML preview and the FastReport PDF export to C:\dev\receivx\tools\parity-out\
# for side-by-side visual inspection in a browser / PDF viewer.
#
# Leaves the pull + PO + receipts in place — re-run wipes prior PL-DOR-* state
# so the script is idempotent.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$SAMPLE_SVG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

$outDir = Join-Path $PSScriptRoot 'parity-out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# Cleanup any PL-DOR-* / PO-DOR-* residue + reseed SUMMARY PO.
$sqlCleanup = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-DOR-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-DOR-%';
DELETE FROM dbo.PurchaseOrderLines
 WHERE PurchaseOrderId IN (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-DOR-%');
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-DOR-%';

DECLARE @poId UNIQUEIDENTIFIER = NEWID();
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, ExpectedDate, Status, Notes, CreatedAt)
VALUES (@poId, 'PO-DOR-SUMMARY',
        '22222222-2222-2222-2222-000000000001',
        '2026-01-01', NULL, 'open',
        N'Stage 7 parity capture — SUMMARY backfill target', SYSUTCDATETIME());
INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty)
VALUES (NEWID(), @poId, 1, 'SUMMARY', N'Stage 7 SUMMARY', 1000, 0);
'@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sqlCleanup 2>&1 | Out-Null

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

$sv = Login 'sadmin' 'admin' $WH_01

Step "Setup: create PL-DOR pull + dual-window item + 2 receipts + close"
$pullNum = "PL-DOR-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$pullBody = @{
    pullNumber = $pullNum; warehouseId = $WH_01
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null
    lockPoByPull = $false; lockHourCap = $false
    referenceNumber = 'INV-DOR-001'
} | ConvertTo-Json
$pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv

$itemBody = @{
    itemCode = 'SUMMARY'; description = 'Stage 7 SUMMARY'
    windows = @(
        @{ hourOfDay = 10; expectedQty = 50 },
        @{ hourOfDay = 14; expectedQty = 30 }
    )
} | ConvertTo-Json -Depth 5
$item = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -Body $itemBody -ContentType 'application/json' -WebSession $sv

foreach ($w in @(@{ h = 10; q = 50 }, @{ h = 14; q = 30 })) {
    $recvBody = @{
        pullItemId = $item.id; hourOfDay = $w.h; qty = $w.q
        lotBatch = $null; palletId = $null; binLocation = $null; qcStatus = 'pending'; note = $null
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $recvBody -ContentType 'application/json' -WebSession $sv | Out-Null
}

# Stamp the 8 ERP fields + Phase 14 vendor on the PoLine the receipts hit.
$stampSql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
UPDATE pol
SET VendorCode   = 'V-DOR',
    VendorName   = 'Vendor DOR Inc',
    PalletId     = 'PALLET-DOR-001',
    OrderId      = 'ORD-DOR-001',
    InvoiceNo    = 'INV-DOR-001',
    KanbanNo     = 'KBN-DOR-001',
    SubInventory = 'SUB-DOR',
    ToLocation   = 'TLOC-DOR',
    AsnNo        = 'ASN-DOR-001',
    OrderRound   = 'R1'
FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.Receipts r ON r.PurchaseOrderLineId = pol.Id
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = N'__PULLNUM__';
'@.Replace('__PULLNUM__', $pullNum)
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $stampSql 2>&1 | Out-Null

$closeBody = @{ signatureSvg = $SAMPLE_SVG } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $sv | Out-Null
OK "PL-DOR pull set up + closed (id=$($pull.id))"

Step "Capture HTML preview"
$htmlPath = Join-Path $outDir 'dsv-preview.html'
$prev = Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/preview" -Method GET -WebSession $sv -UseBasicParsing
if ($prev.StatusCode -ne 200) { Fail "Preview returned $($prev.StatusCode)" }

# Wrap the partial in a minimal full HTML doc so it opens nicely in a browser.
# Load reports.css from the live dev server so the page styles correctly.
$htmlDoc = @"
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="UTF-8">
  <title>DSV Preview — Stage 7 parity capture</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Roboto:wght@300;400;500;600;700;900&family=Roboto+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="$base/css/reports.css">
  <style>
    body { background: var(--paper-bg); margin: 0; padding: 32px; }
    .preview-frame {
      max-width: 760px; margin: 0 auto;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 16px;
    }
    .frame-banner {
      font-family: 'Roboto Mono', monospace;
      font-size: 11px; color: var(--text-dim);
      text-align: center; margin-bottom: 12px;
      padding: 6px; background: var(--surface-2);
      border-radius: 4px;
    }
  </style>
</head>
<body>
  <div class="preview-frame">
    <div class="frame-banner">Stage 7 parity capture — Pull: $pullNum</div>
$($prev.Content)
  </div>
</body>
</html>
"@
[System.IO.File]::WriteAllText($htmlPath, $htmlDoc, [System.Text.UTF8Encoding]::new($false))
OK "HTML preview saved to $htmlPath ($($prev.Content.Length) bytes)"

Step "Capture PDF export"
$pdfPath = Join-Path $outDir 'dsv-preview.pdf'
$pdfResp = Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/export.pdf" -Method GET -WebSession $sv -UseBasicParsing
if ($pdfResp.StatusCode -ne 200) { Fail "PDF returned $($pdfResp.StatusCode)" }
[System.IO.File]::WriteAllBytes($pdfPath, $pdfResp.Content)
OK "PDF saved to $pdfPath ($($pdfResp.RawContentLength) bytes)"

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Yellow
Write-Host "VISUAL PARITY CAPTURE COMPLETE" -ForegroundColor Yellow
Write-Host "===============================================================" -ForegroundColor Yellow
Write-Host "HTML preview : $htmlPath"
Write-Host "PDF export   : $pdfPath"
Write-Host ""
Write-Host "Open both side-by-side and verify alignment of:"
Write-Host "  - Top strip: warehouse logo + DELIVERY NOTE title + DN# (right)"
Write-Host "  - Address strip: warehouse · DELIVERY TO"
Write-Host "  - Info grid: 5 rows × 2 cols (P/O · PRS · ORDER TYPE · DROP ID · DATE / VENDOR ID · VENDOR · FROM · TO · VENDOR INVOICE)"
Write-Host "  - 4 barcode placeholders: PO · PRS · DN · INVOICE"
Write-Host "  - Item table: 7 cols (PART NUMBER · DESCRIPTION · PALLET · KANBAN · ASN · ROUND · QTY)"
Write-Host "  - TOTAL QTY + barcode placeholder"
Write-Host "  - STORING NOTE: Date Received + Delivery Note No + Inv"
Write-Host "  - Signature footer: DELIVERED BY (empty) + APPROVED FOR DELIVERY BY (1×1 PNG sample)"
Write-Host ""
exit 0
