# Smoke test: v2.x Phase 7.4 — Reports DO end-to-end (two-pane layout +
# aggregated HTML preview + canonicalized PDF export).
#
# Exercises:
#   1. /Reports list page renders + carries the smoke pull row with the
#      two-pane DOM shell.
#   2. /api/reports/do/{id}/preview returns HTML with one .do-document
#      per PO and aggregated lines (no duplicate (Item × PoLine), no
#      HOUR column).
#   3. /api/reports/do/{id}/export.pdf returns a non-empty
#      attachment-disposition application/pdf with %PDF magic bytes.
#   4. Eligibility gate: open pull → preview returns 400.
#   5. Old /Reports/Do/{id}/pdf URL is gone (returns 404).
#
# Aggregation test specifically writes TWO receipts at DIFFERENT hours
# against the same (Item × PoLine) and asserts the preview collapses
# them to one row with SUM(qty). This is the user's original bug
# (WIDGET-1000-05 showing twice at 1:00 and 6:00).

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$SAMPLE_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 30"><path d="M5 25 Q 50 5 95 25" stroke="black" fill="none"/></svg>'

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
WHERE p.PullNumber LIKE 'PL-DOR-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-DOR-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}
SqlCleanup

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

function InvokeExpectStatus($method, $uri, $session, $expected) {
    try {
        Invoke-WebRequest -Uri $uri -Method $method -WebSession $session -UseBasicParsing | Out-Null
        return 200
    }
    catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        return [int]$resp.StatusCode
    }
}

$sv = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
# Setup — create a fresh pull, add item with 2 windows + receive twice at
# different hours against the SAME (Item × PoLine). Close the pull.
# ----------------------------------------------------------------------------
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

# Two windows on the same item → forces 2 receipts that must collapse to
# a single line in the DO preview (aggregation test).
$itemBody = @{
    itemCode = 'SUMMARY'; description = 'DO smoke SUMMARY'
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

$closeBody = @{ signatureSvg = $SAMPLE_SVG } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $sv | Out-Null
OK "PL-DOR pull set up + closed (2 receipts at hours 10 + 14, total 80)"

# ----------------------------------------------------------------------------
# 1. /Reports list page — 200 + two-pane DOM + smoke pull row present
# ----------------------------------------------------------------------------
Step "GET /Reports → 200 + two-pane DOM + smoke pull row"
$page = Invoke-WebRequest -Uri "$base/Reports" -Method GET -WebSession $sv -UseBasicParsing
if ($page.StatusCode -ne 200) { Fail "GET /Reports returned $($page.StatusCode)" }
foreach ($needle in 'reports-filter-bar','reports-split','reports-list-pane','reports-preview-pane','preview-toolbar') {
    if ($page.Content -notmatch [regex]::Escape($needle)) { Fail "Two-pane DOM missing: $needle" }
}
if ($page.Content -notmatch [regex]::Escape($pullNum)) { Fail "Reports list missing $pullNum" }
if ($page.Content -notmatch 'data-pull-id=') { Fail "List rows missing data-pull-id attribute" }
OK "List page renders with two-pane DOM + smoke pull present"

# ----------------------------------------------------------------------------
# 2. /api/reports/do/{id}/preview — HTML fragment + aggregated lines
# ----------------------------------------------------------------------------
Step "GET /api/reports/do/{id}/preview → aggregated HTML fragment"
$prev = Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/preview" -Method GET -WebSession $sv -UseBasicParsing
if ($prev.StatusCode -ne 200) { Fail "Preview returned $($prev.StatusCode)" }
if ($prev.Content -notmatch '<article class="do-document"') { Fail "Preview missing .do-document element" }
if ($prev.Content -notmatch 'DELIVERY ORDER') { Fail "Preview missing DELIVERY ORDER label" }
if ($prev.Content -notmatch 'Total delivered') { Fail "Preview missing total row" }
# AGGREGATION ASSERTION: SUMMARY item appears in exactly ONE row, not two,
# and the qty reflects SUM(50, 30) = 80 (not the hour-split 50 / 30).
$tbody = [regex]::Match($prev.Content, '<tbody>(?s)(.*?)</tbody>').Groups[1].Value
$summaryRows = ([regex]::Matches($tbody, '<td class="mono">SUMMARY</td>')).Count
if ($summaryRows -ne 1) { Fail "Expected 1 SUMMARY row after aggregation, got $summaryRows" }
if ($tbody -notmatch '>80<') { Fail "Aggregated qty 80 not present — hours not summing" }
# No hour column in the new layout
$thead = [regex]::Match($prev.Content, '<thead>(?s)(.*?)</thead>').Groups[1].Value
if ($thead -match '>HOUR<') { Fail "Preview still has HOUR column header — aggregation incomplete" }
OK "Preview renders 1 aggregated row (qty=80) and no HOUR column"

# ----------------------------------------------------------------------------
# 2b. Footer — aligned RECEIVED BY (text-only) + AUTHORIZED BY (signature)
# ----------------------------------------------------------------------------
Step "Footer aligned: spacer left + signature right, both with divider + labels"
$footer = [regex]::Match($prev.Content, '(?s)<footer class="do-footer">(.*?)</footer>').Value
if (-not $footer)                          { Fail "Footer element missing from DO preview" }
if ($footer -notmatch 'RECEIVED BY')       { Fail "Footer missing 'RECEIVED BY' label (left block)" }
if ($footer -notmatch 'AUTHORIZED BY')     { Fail "Footer missing 'AUTHORIZED BY' label (right block)" }
if ($footer -match 'Vendor signature')     { Fail "Footer still has the old 'Vendor signature' label" }
# Alignment requires: signature-spacer on left, signature-image on right,
# sig-divider on both sides (NOT the old sig-line / sig-signature classes).
if ($footer -notmatch 'class="signature-spacer"') { Fail "LEFT block missing .signature-spacer (alignment relies on it)" }
if ($footer -notmatch 'class="signature-image"')  { Fail "RIGHT block missing .signature-image" }
$dividerCount = ([regex]::Matches($footer, 'class="sig-divider"')).Count
if ($dividerCount -ne 2) { Fail "Expected 2 sig-divider elements (one per block), got $dividerCount" }
if ($footer -match 'class="sig-line"')      { Fail "Old .sig-line class still present — alignment refactor incomplete" }
if ($footer -match 'class="sig-signature"') { Fail "Old .sig-signature class still present — alignment refactor incomplete" }
if ($footer -notmatch [regex]::Escape($SAMPLE_SVG.Substring(0, 40))) {
    Fail "AUTHORIZED BY signature-image missing the inline SVG"
}
OK "Footer aligned: spacer/image (80px) + 2 dividers + RECEIVED BY/AUTHORIZED BY"

# ----------------------------------------------------------------------------
# 3. /api/reports/do/{id}/export.pdf — attachment + %PDF
# ----------------------------------------------------------------------------
Step "GET /api/reports/do/{id}/export.pdf → attachment %PDF"
$pdf = Invoke-WebRequest -Uri "$base/api/reports/do/$($pull.id)/export.pdf" -Method GET -WebSession $sv -UseBasicParsing
if ($pdf.StatusCode -ne 200) { Fail "PDF returned $($pdf.StatusCode)" }
if ($pdf.Headers['Content-Type'] -notmatch 'application/pdf') { Fail "Wrong Content-Type: $($pdf.Headers['Content-Type'])" }
$cd = $pdf.Headers['Content-Disposition']
if ($cd -notmatch '^attachment') { Fail "PDF must be attachment, got: $cd" }
if ($cd -notmatch [regex]::Escape("$pullNum-DO.pdf")) { Fail "PDF filename should be $pullNum-DO.pdf, got: $cd" }
if ($pdf.RawContentLength -lt 1000) { Fail "PDF suspiciously small ($($pdf.RawContentLength) bytes)" }
$head4 = [System.Text.Encoding]::ASCII.GetString($pdf.Content[0..3])
if ($head4 -ne '%PDF') { Fail "PDF magic bytes wrong: '$head4'" }
OK "PDF streams ($($pdf.RawContentLength) bytes) attachment with %PDF magic"

# ----------------------------------------------------------------------------
# 4. Eligibility — open pull → 400 from preview
# ----------------------------------------------------------------------------
Step "Open pull → /api/reports/do/{id}/preview returns 400"
$openBody = @{
    pullNumber = "PL-DOR-OPEN-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    warehouseId = $WH_01; pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null; lockPoByPull = $false; lockHourCap = $false
} | ConvertTo-Json
$openPull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $openBody -ContentType 'application/json' -WebSession $sv
$status = InvokeExpectStatus 'GET' "$base/api/reports/do/$($openPull.id)/preview" $sv 400
if ($status -ne 400) { Fail "Open pull preview expected 400, got $status" }
OK "Open pull preview rejected with 400"

# ----------------------------------------------------------------------------
# 5. Old URL gone — /Reports/Do/{id}/pdf must be 404
# ----------------------------------------------------------------------------
Step "Legacy /Reports/Do/{id}/pdf URL is gone (404)"
$legacy = InvokeExpectStatus 'GET' "$base/Reports/Do/$($pull.id)/pdf" $sv 404
if ($legacy -ne 404) { Fail "Legacy URL expected 404, got $legacy" }
OK "Legacy PDF URL retired"

SqlCleanup
Write-Host ""
Write-Host "ALL PASS — Reports DO refactor (two-pane + aggregated HTML + PDF export)." -ForegroundColor Green
exit 0
