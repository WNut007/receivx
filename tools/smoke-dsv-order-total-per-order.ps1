# Smoke: the DSV Delivery Order's TOTAL QTY belongs to the order it is printed
# under — and every order gets one.
#
# Sibling of smoke-do-note-total-per-note.ps1, which covers the Delivery NOTE.
# Same root cause, opposite symptom: OrderFooterDsv was attached to the MASTER
# band, and a DataFooterBand attached to a data band prints ONCE after all of
# that band's rows. So the total appeared a single time, carrying the last
# order's figure, and every earlier order printed NO TOTAL AT ALL. Measured on
# a two-order fixture before the fix:
#
#     page 1 (order B, 2300)  TotalValue = ""      <- missing
#     page 2 (order B, 2300)  TotalValue = ""      <- missing
#     page 3 (order S, 100)   TotalValue = "100"   <- right, but only by being last
#
# The footer is now attached to the detail band, which restarts per order.
#
# NOTE ON PLACEMENT. Unlike the Delivery Note fix, this band deliberately does
# NOT set PrintOnBottom/RepeatOnEveryPage. It is not bottom-anchored: it prints
# directly under the last detail line (top=234.36 on a page whose page-footer
# sits at ~986) and carries the signature boxes with it. Bottom-anchoring it
# would move the block and repeat it mid-document. So an order's total prints
# once, on the page where that order's lines END — which is exactly what the
# last order always did.
#
# Asserted from FastReport's prepared pages via tools/DumpPreparedPages, not
# from the PDF: PDFSimpleExport rasterises every page, so the exported file has
# no text layer to read.
#
# Fixture namespace PL-DSVTOT-* / PO-DSVTOT-*. Purged on entry, exit, failure.

$ErrorActionPreference = 'Stop'
$base     = 'http://localhost:5213'
$repoRoot = Split-Path -Parent $PSScriptRoot
$WH_01    = '22222222-2222-2222-2222-000000000001'
$sqlSrv   = 'LAPTOP-CSB3KO3E'
$SIG      = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

$SMALL_QTY = 100
$BIG_QTY   = 2300
$PULL_QTY  = $SMALL_QTY + $BIG_QTY     # 2400 — never a single order's total
$BIG_LINES = 16                        # enough that order B spans two pages
$BIG_PER   = [int]($BIG_QTY / $BIG_LINES)
$BIG_LAST  = $BIG_QTY - ($BIG_PER * ($BIG_LINES - 1))

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }

function Sql($q) {
    $out = sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -b -Q $q 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "SQL FAILED: $out" -ForegroundColor Red; exit 2 }
    return $out
}

function Cleanup {
    $out = Sql @"
SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId WHERE p.PullNumber LIKE 'PL-DSVTOT-%';
DELETE FROM dbo.PullItems WHERE PullId IN (SELECT Id FROM dbo.Pulls WHERE PullNumber LIKE 'PL-DSVTOT-%');
-- FK_PullSig_Pull and FK_PO_Pull do NOT cascade from dbo.Pulls; the delete is
-- set-based, so one signed pull would strand the whole range.
-- See docs/defect-pull-signature-fk-blocks-smoke-cleanup.md
DELETE s FROM dbo.PullSignatures s
INNER JOIN dbo.Pulls p ON p.Id = s.PullId WHERE p.PullNumber LIKE 'PL-DSVTOT-%';
UPDATE po SET PullId = NULL FROM dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId WHERE p.PullNumber LIKE 'PL-DSVTOT-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-DSVTOT-%';
PRINT 'cleanup: pulls removed = ' + CONVERT(varchar, @@ROWCOUNT);
DELETE FROM dbo.PurchaseOrderLines
 WHERE PurchaseOrderId IN (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-DSVTOT-%');
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-DSVTOT-%';
"@
    $out | Where-Object { $_ -match 'cleanup:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

function Login($u, $p, $w) {
    $body = @{ username = $u; password = $p; warehouseId = $w; remember = $false } | ConvertTo-Json
    $s = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable s | Out-Null
    return $s
}

Cleanup
$sv = Login 'sadmin' 'admin' $WH_01

# ---------------------------------------------------------------------------
Step "Setup: one pull, two Delivery Orders ($SMALL_QTY and $BIG_QTY)"
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$po = [Guid]::NewGuid().ToString()

# A DSV Delivery Order is grouped by (Vendor x SubInventory x ToLocation x
# Invoice), so the two stamps below are what split these lines into two orders.
# SubInventory doubles as the per-page identifier in the assertions: MetaRV0
# renders [Orders.SubInventory] and appears on continuation pages too.
$lineSql = New-Object System.Text.StringBuilder
[void]$lineSql.AppendLine("INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, OrderId, InvoiceNo, SubInventory, ToLocation, VendorCode, VendorName, Note) VALUES")
[void]$lineSql.AppendLine("(NEWID(), '$po', 1, 'DSVTOT-SMALL-$ts', N'DSV total smoke small', 9000, 0, 'DSVTOT-S-$ts', 'INV-DSVTOT-S', 'SUBTOT-S', 'LOCTOT-S', 'V-DSVTOT-S', N'Vendor Small', N'Transferred from WDT'),")
for ($i = 1; $i -le $BIG_LINES; $i++) {
    $comma = if ($i -eq $BIG_LINES) { ';' } else { ',' }
    [void]$lineSql.AppendLine("(NEWID(), '$po', $($i+1), 'DSVTOT-BIG$i-$ts', N'DSV total smoke big $i', 9000, 0, 'DSVTOT-B-$ts', 'INV-DSVTOT-B', 'SUBTOT-B', 'LOCTOT-B', 'V-DSVTOT-B', N'Vendor Big', N'Transferred from WDT')$comma")
}

Sql @"
SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, ExpectedDate, Status, Notes, CreatedAt)
VALUES ('$po', 'PO-DSVTOT-$ts', '$WH_01', '2026-01-01', NULL, 'open', N'DSV per-order total smoke', SYSUTCDATETIME());
$($lineSql.ToString())
"@ | Out-Null

$pullNum = "PL-DSVTOT-$ts"
$pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -WebSession $sv -ContentType 'application/json' -Body (@{
    pullNumber = $pullNum; warehouseId = $WH_01; pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null; lockPoByPull = $false; lockHourCap = $false; referenceNumber = $null
} | ConvertTo-Json)

$specs = @(@{ code = "DSVTOT-SMALL-$ts"; hour = 10; qty = $SMALL_QTY })
for ($i = 1; $i -le $BIG_LINES; $i++) {
    $q = if ($i -eq $BIG_LINES) { $BIG_LAST } else { $BIG_PER }
    # Hours cycle inside 0..23; the API rejects anything outside it.
    $specs += @{ code = "DSVTOT-BIG$i-$ts"; hour = (8 + ($i % 12)); qty = $q }
}
foreach ($it in $specs) {
    $item = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -WebSession $sv -ContentType 'application/json' -Body (@{
        itemCode = $it.code; description = $it.code
        windows = @(@{ hourOfDay = $it.hour; expectedQty = $it.qty })
    } | ConvertTo-Json -Depth 5)
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -WebSession $sv -ContentType 'application/json' -Body (@{
        pullItemId = $item.id; hourOfDay = $it.hour; qty = $it.qty
        lotBatch = $null; palletId = $null; binLocation = $null; qcStatus = 'pending'; note = $null
    } | ConvertTo-Json) | Out-Null
}
Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/close" -Method POST -WebSession $sv -ContentType 'application/json' -Body (@{
    signatureSvg = $SIG } | ConvertTo-Json) | Out-Null
OK "pull $pullNum closed: order S = $SMALL_QTY, order B = $BIG_QTY over $BIG_LINES lines"

# ---------------------------------------------------------------------------
Step "1. HTML preview renders both orders with their own totals"
$html = (Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/preview?type=order" -WebSession $sv -UseBasicParsing).Content
$totals = [regex]::Matches($html, 'class="num dord-total-value mono">([0-9,]+)<') |
          ForEach-Object { [int]($_.Groups[1].Value -replace ',', '') }
if ($totals.Count -ne 2) { Fail "expected 2 order totals in the preview, got $($totals.Count): $($totals -join ', ')" }
$sorted = $totals | Sort-Object
if ($sorted[0] -ne $SMALL_QTY -or $sorted[1] -ne $BIG_QTY) {
    Fail "order totals should be $SMALL_QTY and $BIG_QTY, got $($totals -join ', ')"
}
if ($totals -contains $PULL_QTY) { Fail "an order total printed the whole-pull sum $PULL_QTY" }
OK "preview totals $($totals -join ' and ') — neither is the pull total $PULL_QTY"

# ---------------------------------------------------------------------------
Step "2. PREPARED PAGES: every printed total belongs to the order on its page"
# BuildProjectReferences=false compiles the tool against the already-built web
# assembly; the dev server holds that DLL and rebuilding it here fails MSB3027.
$toolProj = Join-Path $repoRoot 'tools/DumpPreparedPages/DumpPreparedPages.csproj'
& dotnet build $toolProj -p:BuildProjectReferences=false -v q --nologo 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "could not build tools/DumpPreparedPages (exit $LASTEXITCODE)" }

$dumpPath = Join-Path $env:TEMP ("dsv-pages-" + [guid]::NewGuid().ToString('N') + ".json")
& dotnet run --project $toolProj --no-build -- --pull $pullNum --type order --out $dumpPath 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dumpPath)) { Fail "DumpPreparedPages failed for $pullNum" }
$dump = Get-Content $dumpPath -Raw | ConvertFrom-Json
Remove-Item $dumpPath -ErrorAction SilentlyContinue

if ($dump.pageCount -lt 3) {
    Fail "expected at least 3 pages (order B over 2+, order S on its own), got $($dump.pageCount) — the multi-page case is not exercised"
}

$expected = @{ "SUBTOT-S" = $SMALL_QTY; "SUBTOT-B" = $BIG_QTY }
$totalsByOrder = @{}
foreach ($pg in $dump.pages) {
    $sub = ($pg.objects | Where-Object { $_.name -eq 'MetaRV0' -and $_.value } | Select-Object -First 1).value
    if (-not $sub) { Fail "page $($pg.page) carries no sub-inventory — cannot attribute it to an order" }
    if (-not $expected.ContainsKey($sub)) { Fail "page $($pg.page) carries an unknown sub-inventory '$sub'" }

    $tv = ($pg.objects | Where-Object { $_.name -eq 'TotalValue' } | Select-Object -First 1).value
    if ([string]::IsNullOrWhiteSpace($tv)) { continue }   # order continues overleaf

    $printed = [int]($tv -replace '[^0-9]', '')
    if ($printed -eq $PULL_QTY) { Fail "page $($pg.page) printed the whole-pull total $PULL_QTY" }
    if ($printed -ne $expected[$sub]) {
        Fail "page $($pg.page) belongs to order $sub (total $($expected[$sub])) but printed '$tv'"
    }
    $totalsByOrder[$sub] = ($totalsByOrder[$sub] + 1)
}

# Every order must have got its total exactly once. Before the fix the first
# order got none at all, which is the defect this asserts against.
foreach ($sub in $expected.Keys) {
    if (-not $totalsByOrder.ContainsKey($sub)) {
        Fail "order $sub printed NO total on any page — the footer band ran once for the whole report"
    }
    if ($totalsByOrder[$sub] -ne 1) {
        Fail "order $sub printed its total on $($totalsByOrder[$sub]) pages, expected exactly 1"
    }
}
# And the multi-page order must really have spanned pages, or the case is moot.
$bigPages = ($dump.pages | Where-Object {
    ($_.objects | Where-Object { $_.name -eq 'MetaRV0' -and $_.value -eq 'SUBTOT-B' })
}).Count
if ($bigPages -lt 2) { Fail "order SUBTOT-B occupied $bigPages page(s); the multi-page case is untested" }
OK "$($dump.pageCount) pages; each order printed its own total exactly once; SUBTOT-B spanned $bigPages pages"

Cleanup
Write-Host "`nALL PASS - the DSV Delivery Order total is per order." -ForegroundColor Green
exit 0
