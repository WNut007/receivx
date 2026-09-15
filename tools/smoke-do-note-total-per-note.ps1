# Smoke: the Delivery Note footer total is PER DELIVERY NOTE, never per pull.
#
# Reported against production pull 0000032973, Delivery Note 1724870B1: page 1
# carried a single line of QTY 100 while the footer printed 2400.
#
# The rule: footer total = SUM(qty) of the lines belonging to THAT Delivery Note
# number only. If one note spans several pages, every page of that note shows
# the same per-note figure. The footer barcode carries the same value.
#
# Fixture: one pull, TWO delivery notes (OrderId is the DN number), qty 100 and
# qty 2300. The pull total is 2400 and must appear NOWHERE as a note total.
# The numbers are the reported ones on purpose.
#
# WHAT THIS CAN AND CANNOT SEE. FastReport's PDFSimpleExport RASTERISES each
# page — a rendered Delivery Note PDF contains DCTDecode (JPEG) page images and
# no text layer at all, so no assertion here can read the number printed on the
# paper. Verified while writing this: an 840KB two-note PDF holds 4 streams, 2
# JPEG + 2 tiny Flate, and zero text-showing operands. So the rule is guarded on
# the two surfaces that ARE readable, which between them cover the two ways it
# can break:
#
#   §1-3  the DATA — the HTML preview renders from the same DoReportData the
#         .frx binds to, so a grouping or summing fault shows up here.
#   §4    the TEMPLATE — the .frx objects that draw the total and its barcode
#         must bind to the per-note column and to nothing pull-level or
#         aggregate. This is the half a Designer edit can silently break, and
#         the .frx is loaded at runtime and editable in Designer by design.
#
# Neither half alone is sufficient; §4 exists because §1-3 stayed green while
# the reported bug was on the paper.

$ErrorActionPreference = 'Stop'
$base     = 'http://localhost:5213'
$repoRoot = Split-Path -Parent $PSScriptRoot
$WH_01    = '22222222-2222-2222-2222-000000000001'
$sqlSrv   = 'LAPTOP-CSB3KO3E'
$SIG      = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

$SMALL_QTY = 100
$BIG_QTY   = 2300
$PULL_QTY  = $SMALL_QTY + $BIG_QTY      # 2400 — the number that must never be a note total

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }

function Sql($q) {
    $out = sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -b -Q $q 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "SQL FAILED: $out" -ForegroundColor Red; exit 2 }
    return $out
}

function Cleanup {
    # -b above makes a cleanup failure loud rather than silent; a cleanup that
    # cannot report its own failure is how 148 fixture pulls once accumulated.
    $out = Sql @"
SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId WHERE p.PullNumber LIKE 'PL-DNTOT-%';
DELETE FROM dbo.PullItems WHERE PullId IN (SELECT Id FROM dbo.Pulls WHERE PullNumber LIKE 'PL-DNTOT-%');
-- FK_PullSig_Pull and FK_PO_Pull do NOT cascade from dbo.Pulls; the DELETE
-- below is set-based, so one signed pull would strand the whole range.
-- See docs/defect-pull-signature-fk-blocks-smoke-cleanup.md
DELETE s FROM dbo.PullSignatures s
INNER JOIN dbo.Pulls p ON p.Id = s.PullId WHERE p.PullNumber LIKE 'PL-DNTOT-%';
UPDATE po SET PullId = NULL FROM dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId WHERE p.PullNumber LIKE 'PL-DNTOT-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-DNTOT-%';
PRINT 'cleanup: pulls removed = ' + CONVERT(varchar, @@ROWCOUNT);
DELETE FROM dbo.PurchaseOrderLines
 WHERE PurchaseOrderId IN (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-DNTOT-%');
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-DNTOT-%';
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
Step "Setup: one pull, two Delivery Notes ($SMALL_QTY and $BIG_QTY)"
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$po = [Guid]::NewGuid().ToString()

# Two lines with DISTINCT OrderId values. OrderId IS the Delivery Note number
# (DeliveryNoteNo = g.Key, grouped on OrderId), so two OrderIds = two notes.
# Both carry the WDT sentinel or the DN whitelist drops them and every
# assertion below would run against the empty state.
Sql @"
SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, ExpectedDate, Status, Notes, CreatedAt)
VALUES ('$po', 'PO-DNTOT-$ts', '$WH_01', '2026-01-01', NULL, 'open', N'DN per-note total smoke', SYSUTCDATETIME());
INSERT INTO dbo.PurchaseOrderLines
  (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty,
   OrderId, InvoiceNo, SubInventory, ToLocation, VendorCode, VendorName, Note)
VALUES
  (NEWID(), '$po', 1, 'DNTOT-SMALL-$ts', N'DN total smoke small', 9000, 0,
   'DNTOT-S-$ts', 'INV-DNTOT-S', 'SUB-S', 'LOC-S', 'V-DNTOT-S', N'Vendor Small', N'Transferred from WDT'),
  (NEWID(), '$po', 2, 'DNTOT-BIG-$ts',   N'DN total smoke big',   9000, 0,
   'DNTOT-B-$ts', 'INV-DNTOT-B', 'SUB-B', 'LOC-B', 'V-DNTOT-B', N'Vendor Big',   N'Transferred from WDT');
"@ | Out-Null

$pullNum = "PL-DNTOT-$ts"
$pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -WebSession $sv -ContentType 'application/json' -Body (@{
    pullNumber = $pullNum; warehouseId = $WH_01; pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null; lockPoByPull = $false; lockHourCap = $false; referenceNumber = $null
} | ConvertTo-Json)

foreach ($it in @(
    @{ code = "DNTOT-SMALL-$ts"; hour = 10; qty = $SMALL_QTY },
    @{ code = "DNTOT-BIG-$ts";   hour = 11; qty = $BIG_QTY }
)) {
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
OK "pull $pullNum closed with 2 delivery notes ($SMALL_QTY + $BIG_QTY = $PULL_QTY)"

# ---------------------------------------------------------------------------
Step "1. Two notes render, each carrying its OWN total"
$html = (Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/preview?type=note" -WebSession $sv -UseBasicParsing).Content
$articles = ([regex]::Matches($html, '<article class="dsv-do"')).Count
if ($articles -ne 2) { Fail "expected 2 .dsv-do articles (one per Delivery Note), got $articles" }

$totals = [regex]::Matches($html, 'class="num dsv-total-value">([0-9,]+)<') |
          ForEach-Object { [int]($_.Groups[1].Value -replace ',', '') }
if ($totals.Count -ne 2) { Fail "expected 2 TOTAL QTY values, got $($totals.Count): $($totals -join ', ')" }
$sorted = $totals | Sort-Object
if ($sorted[0] -ne $SMALL_QTY -or $sorted[1] -ne $BIG_QTY) {
    Fail "note totals should be $SMALL_QTY and $BIG_QTY, got $($totals -join ', ')"
}
OK "two notes, totals $($totals -join ' and ') — each its own"

# ---------------------------------------------------------------------------
Step "2. The PULL total ($PULL_QTY) never appears as a note total"
foreach ($t in $totals) {
    if ($t -eq $PULL_QTY) { Fail "a note total printed $PULL_QTY — that is the whole-pull sum, not this note's" }
}
# Belt and braces: the rendered figure must not appear anywhere a total is shown,
# in either the bare or the thousands-separated form.
foreach ($form in "$PULL_QTY", '{0:N0}' -f $PULL_QTY) {
    if ($html -match ('class="num dsv-total-value">' + [regex]::Escape($form) + '<')) {
        Fail "the whole-pull total '$form' is rendered as a note total"
    }
}
OK "$PULL_QTY appears in no note total"

# ---------------------------------------------------------------------------
Step "3. Each note's total equals the sum of the lines shown on that note"
# Split the HTML per article and re-add the per-line quantities, so the total is
# checked against the lines beside it rather than against a constant.
$blocks = [regex]::Split($html, '(?=<article class="dsv-do")') | Where-Object { $_ -match 'dsv-total-value' }
if ($blocks.Count -ne 2) { Fail "could not split the preview into 2 note blocks, got $($blocks.Count)" }
foreach ($b in $blocks) {
    $shown = [int](([regex]::Match($b, 'class="num dsv-total-value">([0-9,]+)<')).Groups[1].Value -replace ',', '')
    # Per-line quantity cell is `<td class="num"><b>1,234</b></td>`; the total
    # cell carries the extra dsv-total-value class and is excluded by the <b>.
    $lineQtys = [regex]::Matches($b, '<td class="num"><b>([0-9,]+)</b></td>') |
                ForEach-Object { [int]($_.Groups[1].Value -replace ',', '') }
    if ($lineQtys.Count -eq 0) { Fail "a note block rendered no line quantities — cannot verify its total" }
    $sum = ($lineQtys | Measure-Object -Sum).Sum
    if ($sum -ne $shown) { Fail "note total $shown does not equal the sum of its own lines ($sum)" }
}
OK "each note's total reconciles with the lines printed on it"

# ---------------------------------------------------------------------------
Step "4. The .frx binds the total and its barcode to the PER-NOTE column"
# This is the half the HTML cannot see. The Delivery Note template is loaded at
# runtime and is edited in FastReport Designer by design, so a change here can
# reach production without touching C#. Orders is the master table, one row per
# Delivery Note (PK = DeliveryNoteNo), so Orders.TotalQty IS the per-note sum;
# anything aggregate or pull-level would be the reported bug.
$frxPath = Join-Path $repoRoot 'src/ReceivingOps.Web/Reports/delivery-order.frx'
if (-not (Test-Path $frxPath)) { Fail "delivery-order.frx not found at $frxPath" }
$frx = Get-Content $frxPath -Raw

foreach ($obj in 'TotalValue', 'BcTotal') {
    $m = [regex]::Match($frx, 'Name="' + $obj + '"[^>]*?Text="(?<expr>\[[^"]*\])"')
    if (-not $m.Success) { Fail "$obj is missing from delivery-order.frx, or no longer carries a Text expression" }
    $expr = $m.Groups['expr'].Value
    if ($expr -ne '[Orders.TotalQty]') {
        Fail "$obj binds '$expr'; the per-note total is [Orders.TotalQty]"
    }
}
# An aggregate would re-introduce the bug even while still naming TotalQty.
foreach ($obj in 'TotalValue', 'BcTotal') {
    $m = [regex]::Match($frx, 'Name="' + $obj + '"[^>]*?Text="(?<expr>[^"]*)"')
    if ($m.Groups['expr'].Value -match '(?i)\b(Sum|Avg|Count|Total)\s*\(') {
        Fail "$obj uses an aggregate function — the total must be the per-note column, not a report-wide sum"
    }
}
# Lines.TotalQty is the per-LINE column; using it for the footer would print one
# line's quantity as the note total.
if ($frx -match 'Name="(TotalValue|BcTotal)"[^>]*Text="\[Lines\.TotalQty\]"') {
    Fail "the footer total binds the per-line column [Lines.TotalQty]"
}
OK "TotalValue + BcTotal both bind [Orders.TotalQty], no aggregate"

# ---------------------------------------------------------------------------
Step "5. The Delivery Note PDF still renders"
$pdfPath = Join-Path $env:TEMP ("dn-total-" + [guid]::NewGuid().ToString('N') + ".pdf")
Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/export.pdf?type=note" -WebSession $sv -OutFile $pdfPath | Out-Null
$bytes = [System.IO.File]::ReadAllBytes($pdfPath)
$magic = [System.Text.Encoding]::ASCII.GetString($bytes[0..4])
if ($magic -ne '%PDF-') { Fail "export is not a PDF (magic '$magic')" }
if ($bytes.Length -lt 50000) { Fail "PDF suspiciously small: $($bytes.Length) bytes" }
# Two notes, and the master band starts a new page per note.
$raw = [System.Text.Encoding]::Latin1.GetString($bytes)
$pageCount = ([regex]::Matches($raw, '/Type\s*/Page[^s]')).Count
if ($pageCount -lt 2) { Fail "expected at least 2 pages (one per note), found $pageCount" }
Remove-Item $pdfPath -ErrorAction SilentlyContinue
OK "PDF renders, $([int]($bytes.Length/1024)) KB, $pageCount pages"

Cleanup
Write-Host "`nALL PASS - the Delivery Note footer total is per Delivery Note." -ForegroundColor Green
exit 0
