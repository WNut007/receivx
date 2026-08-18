# Smoke: WIP pull synthesis from the PO import.
#
# For pull sheets whose STORER CODE contains WIP the ERP never sends the
# Receive feed: the import lands the PO lines but no Pulls / PullItems /
# PullItemWindows rows ever appear, so the goods arrive and the warehouse has
# nothing to receive against. Stage 2 now builds the pull structure from the
# imported rows and creates the purchase-order side to go with it.
#
# Fixtures authored by tools/build-wip-fixture.ps1 (one-shot, not in battery).
# Everything is namespaced WIPTEST- so cleanup is a LIKE and collisions are
# impossible.
#
# Asserts:
#   1. 1 pull / 3 items / 3 windows; the 9-row SKU lands as ONE window
#      carrying the SUMMED quantity, not the last row's
#   2. Synthetic PO: PoNumber = PullExternalRef = pull number, status open,
#      PullId linked, Origin stamped, one line per window with matching qty
#   3. End-to-end receive against a synthesised pull — the test that proves
#      the feature: FIFO finds the synthetic PO line under LockPoByPull,
#      PurchaseOrderLines.ReceivedQty updates, the window fills
#   4. Both variance directions, because both happen on these goods:
#      a short close with a reason code, and an over-receipt with the tick +
#      a reason code allocating 100 pull-linked + 50 into overflow on another
#      open line for the same vendor. Unticked over-receipt still 400s.
#   5. Non-WIP sheets in the same file are unaffected — PO with per-row
#      lines, no pull
#   6. Mixed WIP/non-WIP sheet → validation error, nothing committed
#   7. WIP sheet with two storer codes → validation error
#   8. WIP row with a blank ROUND → validation error
#   9. Re-import → skip, no duplicates, no orphan PO, audit row
#  10. Re-import after receipts exist → pull unmodified, receipts intact
#  11. HourOfDay maps across every observed round (7, 8, 9, 11, 19, 21, 23)
#  12. Vendor code format: PurchaseOrderLines keeps the prefixed STORER CODE,
#      PullItems gets the stripped form — they differ on purpose
#  13. Repair path: PO already imported but no pull → the pull is built and
#      the existing PO is left exactly as it was

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$fixtures = Join-Path $repoRoot 'tools\fixtures'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Sql($q)  { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }
function SqlScalar($q) {
    $out = (Sql $q) | Where-Object { $_ -and $_.Trim() -ne '' } | Select-Object -First 1
    if ($null -eq $out) { return '' }
    return $out.Trim()
}

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body `
        -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Purge every WIPTEST- artefact. FK order: receipts → windows → items → pulls,
# and lines → POs. PoImportLog rows are keyed by the fixture filenames.
function Cleanup {
    Sql @"
SET NOCOUNT ON;
DELETE r FROM dbo.Receipts r
  INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'WIPTEST-%';
DELETE r FROM dbo.Receipts r
  INNER JOIN dbo.PurchaseOrders po ON po.Id = r.PurchaseOrderId
WHERE po.PoNumber LIKE 'WIPTEST-%';
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'WIPTEST-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'WIPTEST-%';
DELETE pol FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'WIPTEST-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'WIPTEST-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'WIPTEST-%';
DELETE FROM dbo.PoImportLog WHERE FileName LIKE 'po-import-wip-%';
DELETE FROM dbo.AuditLog WHERE EntityId LIKE 'WIPTEST-%';
"@ | Out-Null
}

function Upload($session, $fixtureName) {
    $path = Join-Path $fixtures $fixtureName
    if (-not (Test-Path $path)) { Fail "Fixture missing: $path — run tools/build-wip-fixture.ps1" }
    return Invoke-RestMethod -Uri "$base/api/imports/po/upload" -Method POST `
        -WebSession $session -Form @{ file = Get-Item -LiteralPath $path }
}

function ConfirmAndWait($session, $runId, $label) {
    Invoke-RestMethod -Uri "$base/api/imports/po/$runId/confirm" -Method POST -WebSession $session | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $row = Invoke-RestMethod -Uri "$base/api/imports/po/$runId" -WebSession $session
        if ($row.status -eq 'succeeded') { return $row }
        if ($row.status -eq 'failed')    { Fail "$label — import failed: $($row.errorMessage)" }
        Start-Sleep -Milliseconds 800
    }
    Fail "$label — import did not reach a terminal status within 60s"
}

function ItemId($pullNumber, $sku) {
    return SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pi.Id AS VARCHAR(36)) FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$pullNumber' AND pi.ItemCode = '$sku';
"@
}

function Receive($session, $pullItemId, $hour, $qty, $variance, $reason, $note) {
    $b = @{ pullItemId=$pullItemId; hourOfDay=$hour; qty=$qty; varianceAccepted=$variance }
    if ($null -ne $reason) { $b.varianceReasonCode = $reason }
    if ($null -ne $note)   { $b.note = $note }
    return Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body ($b | ConvertTo-Json) `
        -ContentType 'application/json' -WebSession $session
}

function ExpectValidationFailure($session, $fixtureName, $mustContain, $label) {
    $resp = Upload $session $fixtureName
    if ($resp.status -ne 'validation_failed') {
        Fail "$label — expected validation_failed, got '$($resp.status)'"
    }
    $messages = ($resp.validationErrorsPreview | ForEach-Object { $_.message }) -join ' | '
    if ($messages -notmatch [regex]::Escape($mustContain)) {
        Fail "$label — error text did not mention '$mustContain'. Got: $messages"
    }
    return $resp
}

try {
    # ------------------------------------------------------------------
    Step "0. Preconditions — server up, db/050 applied, fixtures present, clean slate"
    try { Invoke-WebRequest -Uri "$base/Account/Login" -UseBasicParsing -TimeoutSec 10 | Out-Null }
    catch { Fail "Dev server not reachable at $base — start it with: dotnet run --launch-profile http" }

    $originCol = SqlScalar "SET NOCOUNT ON; SELECT CAST(COL_LENGTH('dbo.Pulls','Origin') AS VARCHAR);"
    if ($originCol -ne '16') { Fail "dbo.Pulls.Origin missing — run db/050_pulls_and_pos_origin.sql first" }
    $originPoCol = SqlScalar "SET NOCOUNT ON; SELECT CAST(COL_LENGTH('dbo.PurchaseOrders','Origin') AS VARCHAR);"
    if ($originPoCol -ne '16') { Fail "dbo.PurchaseOrders.Origin missing — run db/050_pulls_and_pos_origin.sql first" }

    Cleanup
    $leftovers = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Pulls WHERE PullNumber LIKE 'WIPTEST-%';")
    if ($leftovers -ne 0) { Fail "Cleanup left $leftovers WIPTEST pull(s) behind" }
    $sup = Login 'swattana' 'demo1234' $WH_01
    OK "db/050 applied, fixtures namespace clear, supervisor session at WH-01"

    # ------------------------------------------------------------------
    Step "1. Upload the happy fixture — preview reports the synthesis before anything commits"
    $up = Upload $sup 'po-import-wip-sample.xlsx'
    if ($up.status -ne 'validated') { Fail "status='$($up.status)', expected 'validated'" }
    if (-not $up.wip)               { Fail "response carries no wip summary" }
    if ($up.wip.pullCount -ne 1)    { Fail "wip.pullCount=$($up.wip.pullCount), expected 1 (only the WIP sheet)" }
    if ($up.wip.createCount -ne 1)  { Fail "wip.createCount=$($up.wip.createCount), expected 1" }
    if ($up.wip.skipCount -ne 0)    { Fail "wip.skipCount=$($up.wip.skipCount), expected 0 on a clean slate" }
    if ($up.wip.itemCount -ne 3)    { Fail "wip.itemCount=$($up.wip.itemCount), expected 3" }
    if ($up.wip.windowCount -ne 3)  { Fail "wip.windowCount=$($up.wip.windowCount), expected 3" }
    if ($up.wip.totalQty -ne 1190)  { Fail "wip.totalQty=$($up.wip.totalQty), expected 1190 (900+250+40)" }
    $wipRow = $up.wip.pulls | Where-Object { $_.pullNumber -eq 'WIPTEST-0001' }
    if (-not $wipRow)                 { Fail "preview does not list WIPTEST-0001" }
    if ($wipRow.action -ne 'create')  { Fail "preview action='$($wipRow.action)', expected 'create'" }
    OK "preview: 1 sheet · create · 3 items · 3 windows · 1,190 units"

    ConfirmAndWait $sup $up.runId 'happy path' | Out-Null

    # ------------------------------------------------------------------
    Step "2. Assertion 1 — pull, items, and SUMMED windows"
    $pullRow = (Sql @"
SET NOCOUNT ON;
SELECT CAST(p.Id AS VARCHAR(36)) + '|' + p.Status + '|' + CAST(p.LockPoByPull AS VARCHAR)
     + '|' + CAST(p.LockHourCap AS VARCHAR) + '|' + ISNULL(p.Origin,'(null)')
FROM dbo.Pulls p WHERE p.PullNumber = 'WIPTEST-0001';
"@) | Where-Object { $_ -match '\|' } | Select-Object -First 1
    if (-not $pullRow) { Fail "No pull created for WIPTEST-0001" }
    $parts = $pullRow.Trim() -split '\|'
    $pullId = $parts[0]
    if ($parts[1] -ne 'pending')     { Fail "pull status='$($parts[1])', expected 'pending' (ErpUpsertService's default)" }
    # LockPoByPull = 1 keeps FIFO scoped to this pull's PO — and keeps variance
    # overflow meaningful, since overflow only widens inside lock-by-pull mode.
    if ($parts[2] -ne '1')           { Fail "LockPoByPull=$($parts[2]), expected 1" }
    # LockHourCap = 0 on purpose, and NOT copied from the ETL's blanket true.
    # A synthesised window's ExpectedQty is a summed OPEN QTY out of a planning
    # file, not a counted quantity; with the cap strict an over-receipt is
    # refused outright and the accept-variance tick cannot override it (§7.1),
    # which would leave WIP goods receivable short but never over. If this ever
    # flips back to 1, the two over-receive cases below start failing — that is
    # the intended alarm, not incidental coupling.
    if ($parts[3] -ne '0')           { Fail "LockHourCap=$($parts[3]), expected 0 — WIP pulls must be able to take an over-receipt" }
    if ($parts[4] -ne 'po-import')   { Fail "Origin='$($parts[4])', expected 'po-import'" }

    $itemCount = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PullItems WHERE PullId='$pullId';")
    if ($itemCount -ne 3) { Fail "PullItems=$itemCount, expected 3" }

    $winA = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(w.HourOfDay AS VARCHAR) + '/' + CAST(w.ExpectedQty AS VARCHAR)
FROM dbo.PullItemWindows w INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
WHERE pi.PullId = '$pullId' AND pi.ItemCode = 'WIPSKU-A';
"@
    # 9 rows x 100 at 07:00 — one window, summed. The whole reason grouping
    # exists: PullItemWindows is unique on (PullItemId, HourOfDay).
    if ($winA -ne '7/900') { Fail "WIPSKU-A window='$winA', expected '7/900' (9 rows x 100 summed into one window)" }

    $winCount = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId WHERE pi.PullId = '$pullId';
"@)
    if ($winCount -ne 3) { Fail "windows=$winCount, expected 3" }
    OK "pull pending · LockPoByPull=1 · LockHourCap=0 · Origin=po-import · 3 items · 3 windows · 9-row SKU summed to 900"

    # ------------------------------------------------------------------
    Step "3. Assertion 2 + 12 — synthetic PO, grouped lines, vendor format on both sides"
    $poRow = (Sql @"
SET NOCOUNT ON;
SELECT CAST(po.Id AS VARCHAR(36)) + '|' + po.Status + '|' + ISNULL(po.PullExternalRef,'(null)')
     + '|' + ISNULL(CAST(po.PullId AS VARCHAR(36)),'(null)') + '|' + ISNULL(po.Origin,'(null)')
FROM dbo.PurchaseOrders po WHERE po.PoNumber = 'WIPTEST-0001';
"@) | Where-Object { $_ -match '\|' } | Select-Object -First 1
    if (-not $poRow) { Fail "No PurchaseOrder created for WIPTEST-0001" }
    $pp = $poRow.Trim() -split '\|'
    if ($pp[1] -ne 'open')            { Fail "PO status='$($pp[1])', expected 'open'" }
    if ($pp[2] -ne 'WIPTEST-0001')    { Fail "PullExternalRef='$($pp[2])', expected the pull number" }
    if ($pp[3] -ne $pullId)           { Fail "PO.PullId='$($pp[3])', expected the synthesised pull id '$pullId'" }
    if ($pp[4] -ne 'po-import')       { Fail "PO.Origin='$($pp[4])', expected 'po-import'" }

    $lineCount = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PurchaseOrderLines WHERE PurchaseOrderId='$($pp[0])';")
    if ($lineCount -ne 3) { Fail "PO lines=$lineCount, expected 3 (one per window, NOT one per source row)" }

    $lineA = SqlScalar "SET NOCOUNT ON; SELECT CAST(OrderedQty AS VARCHAR) FROM dbo.PurchaseOrderLines WHERE PurchaseOrderId='$($pp[0])' AND ItemCode='WIPSKU-A';"
    if ($lineA -ne '900') { Fail "WIPSKU-A PO line OrderedQty=$lineA, expected 900 to match the window" }

    # The trap: PurchaseOrderLines holds the prefixed STORER CODE, PullItems
    # holds the ERP's stripped form. Writing the same string to both looks
    # right and matches nothing.
    $polVendor = SqlScalar "SET NOCOUNT ON; SELECT TOP 1 VendorCode FROM dbo.PurchaseOrderLines WHERE PurchaseOrderId='$($pp[0])';"
    $piVendor  = SqlScalar "SET NOCOUNT ON; SELECT TOP 1 VendorCode FROM dbo.PullItems WHERE PullId='$pullId';"
    if ($polVendor -ne 'COI-WIPTEST1') { Fail "PurchaseOrderLines.VendorCode='$polVendor', expected the raw 'COI-WIPTEST1'" }
    if ($piVendor  -ne 'WIPTEST1')     { Fail "PullItems.VendorCode='$piVendor', expected the stripped 'WIPTEST1'" }
    OK "PO open · PullId + PullExternalRef both set · 3 grouped lines · vendor raw='$polVendor' stripped='$piVendor'"

    # ------------------------------------------------------------------
    Step "4. Assertion 5 — the non-WIP sheet in the same file is untouched"
    $plainPull = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Pulls WHERE PullNumber='WIPTEST-9001';")
    if ($plainPull -ne 0) { Fail "A pull was created for the non-WIP sheet WIPTEST-9001" }
    $plainLines = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = 'WIPTEST-9001';
"@)
    if ($plainLines -ne 2) { Fail "non-WIP PO has $plainLines line(s), expected 2 (one per source row)" }
    $plainOrigin = SqlScalar "SET NOCOUNT ON; SELECT ISNULL(Origin,'(null)') FROM dbo.PurchaseOrders WHERE PoNumber='WIPTEST-9001';"
    if ($plainOrigin -ne '(null)') { Fail "non-WIP PO Origin='$plainOrigin', expected NULL" }
    OK "ordinary sheet: PO with 2 per-row lines, Origin NULL, no pull"

    # ------------------------------------------------------------------
    Step "5. Assertion 3 — end-to-end receive against the synthesised pull"
    $itemB = ItemId 'WIPTEST-0001' 'WIPSKU-B'
    if (-not $itemB) { Fail "WIPSKU-B pull item not found" }
    $rec = Receive $sup $itemB 8 250 $false $null 'smoke: full receive on synthesised pull'
    if ($rec.totalQty -ne 250) { Fail "receive totalQty=$($rec.totalQty), expected 250" }
    if (-not $rec.allocations -or $rec.allocations.Count -lt 1) { Fail "receive returned no allocations" }

    $polB = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR) FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = 'WIPTEST-0001' AND pol.ItemCode = 'WIPSKU-B';
"@
    if ($polB -ne '250') { Fail "PO line ReceivedQty=$polB, expected 250 — FIFO did not consume the synthetic line" }

    $winB = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(w.ReceivedQty AS VARCHAR) FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
WHERE pi.Id = '$itemB' AND w.HourOfDay = 8;
"@
    if ($winB -ne '250') { Fail "window ReceivedQty=$winB, expected 250" }
    OK "received 250/250 — FIFO found the synthetic PO line under LockPoByPull, both caches updated"

    # ------------------------------------------------------------------
    Step "6. Assertion 4a — short close with a reason code"
    $itemC = ItemId 'WIPTEST-0001' 'WIPSKU-C'

    # A short close is unaffected by the hour-cap setting either way: a cap
    # constrains how much may arrive, not how little.
    $short = Receive $sup $itemC 19 30 $true 'SHORT_DELIVERY' 'smoke: short close on synthesised pull'
    if ($short.totalQty -ne 30) { Fail "short close totalQty=$($short.totalQty), expected 30" }

    $winC = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(w.ReceivedQty AS VARCHAR) + '/' + CAST(w.IsClosed AS VARCHAR)
     + '/' + ISNULL(w.VarianceReasonCode,'(null)')
FROM dbo.PullItemWindows w WHERE w.PullItemId = '$itemC' AND w.HourOfDay = 19;
"@
    if ($winC -ne '30/1/SHORT_DELIVERY') {
        Fail "window after short close = '$winC', expected '30/1/SHORT_DELIVERY'"
    }
    OK "short close 30/40 recorded with SHORT_DELIVERY, line closed"

    # ------------------------------------------------------------------
    Step "6b. Assertion 4b — over-receipt with variance ticked, allocating into overflow"
    # The case the feature exists for: over-delivery is the norm on these
    # goods. Two WIP sheets share a storer code and a SKU, so each gets its own
    # synthesised pull + PO with an open line for the same (vendor, item,
    # warehouse) — the shape variance overflow widens into.
    $ov = Upload $sup 'po-import-wip-overflow.xlsx'
    if ($ov.status -ne 'validated')   { Fail "overflow fixture status='$($ov.status)'" }
    if ($ov.wip.pullCount -ne 2)      { Fail "overflow fixture wip.pullCount=$($ov.wip.pullCount), expected 2" }
    ConfirmAndWait $sup $ov.runId 'overflow' | Out-Null

    $itemOf = ItemId 'WIPTEST-0006' 'WIPSKU-OF'
    if (-not $itemOf) { Fail "WIPSKU-OF pull item not found on WIPTEST-0006" }

    # Loose does NOT mean unchecked. Per the db/047 amendment an over-receipt
    # on a loose pull still requires the operator's explicit tick; without it
    # the server refuses with 400 OVER_RECEIPT_NOT_ACCEPTED rather than
    # silently recording the larger figure.
    $unticked = 0
    $untickedCode = ''
    try {
        Receive $sup $itemOf 7 150 $false $null 'smoke: over-receive without the tick' | Out-Null
    } catch {
        $unticked = [int]$_.Exception.Response.StatusCode
        # PowerShell 7 surfaces the body on ErrorDetails, not through the
        # response stream (which is already consumed by then).
        if ($_.ErrorDetails.Message -match 'OVER_RECEIPT_NOT_ACCEPTED') {
            $untickedCode = 'OVER_RECEIPT_NOT_ACCEPTED'
        }
    }
    if ($unticked -ne 400) { Fail "unticked over-receipt returned $unticked, expected 400 (loose pull still needs the tick)" }
    if ($untickedCode -ne 'OVER_RECEIPT_NOT_ACCEPTED') { Fail "unticked over-receipt did not carry OVER_RECEIPT_NOT_ACCEPTED" }

    # Ticked + reason code: 150 against a window of 100. 100 comes off this
    # pull's own PO line, 50 overflows onto WIPTEST-0007's line for the same
    # vendor + item. Every unit still lands on a real PO line.
    $over = Receive $sup $itemOf 7 150 $true 'OVER_DELIVERY' 'smoke: over-receive with the tick'
    if ($over.totalQty -ne 150) { Fail "over-receive totalQty=$($over.totalQty), expected 150" }

    $linked   = @($over.allocations | Where-Object { $_.isPullLinked -eq $true })
    $overflow = @($over.allocations | Where-Object { $_.isPullLinked -eq $false })
    if ($linked.Count -lt 1)   { Fail "no pull-linked allocation — FIFO did not consume the synthetic PO line first" }
    if ($overflow.Count -lt 1) { Fail "no overflow allocation — the extra 50 did not reach the other open PO line" }
    $linkedQty   = ($linked   | Measure-Object -Property qty -Sum).Sum
    $overflowQty = ($overflow | Measure-Object -Property qty -Sum).Sum
    if ($linkedQty -ne 100)   { Fail "pull-linked allocation=$linkedQty, expected 100 (the line's full OrderedQty)" }
    if ($overflowQty -ne 50)  { Fail "overflow allocation=$overflowQty, expected 50" }

    $polOwn = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR) FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = 'WIPTEST-0006' AND pol.ItemCode = 'WIPSKU-OF';
"@
    $polOther = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pol.ReceivedQty AS VARCHAR) FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = 'WIPTEST-0007' AND pol.ItemCode = 'WIPSKU-OF';
"@
    if ($polOwn -ne '100')  { Fail "WIPTEST-0006 PO line ReceivedQty=$polOwn, expected 100" }
    if ($polOther -ne '50') { Fail "WIPTEST-0007 PO line ReceivedQty=$polOther, expected 50 — overflow did not land" }

    $winOf = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(w.ExpectedQty AS VARCHAR) + '/' + CAST(w.ReceivedQty AS VARCHAR)
     + '/' + CAST(w.IsClosed AS VARCHAR) + '/' + ISNULL(w.VarianceReasonCode,'(null)')
FROM dbo.PullItemWindows w WHERE w.PullItemId = '$itemOf' AND w.HourOfDay = 7;
"@
    if ($winOf -ne '100/150/1/OVER_DELIVERY') {
        Fail "window after over-receive = '$winOf', expected '100/150/1/OVER_DELIVERY'"
    }
    OK "over-receive 150/100 accepted on the tick: 100 pull-linked + 50 overflow, both PO lines updated, line closed with OVER_DELIVERY"

    # ------------------------------------------------------------------
    Step "7. Assertions 6-8 — guard rails reject the file and commit nothing"
    ExpectValidationFailure $sup 'po-import-wip-mixed.xlsx' 'mixes WIP and non-WIP rows' 'mixed sheet' | Out-Null
    ExpectValidationFailure $sup 'po-import-wip-two-storers.xlsx' 'storer codes' 'two storer codes' | Out-Null
    ExpectValidationFailure $sup 'po-import-wip-blank-round.xlsx' 'blank ROUND' 'blank round' | Out-Null

    $guardRows = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(
    (SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber IN ('WIPTEST-0003','WIPTEST-0004','WIPTEST-0005')) +
    (SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber IN ('WIPTEST-0003','WIPTEST-0004','WIPTEST-0005'))
AS VARCHAR);
"@)
    if ($guardRows -ne 0) { Fail "guard-rail files committed $guardRows row(s) — validation must reject before Stage 2" }
    OK "3 guard rails each rejected at Stage 1, zero rows committed"

    # ------------------------------------------------------------------
    Step "8. Assertions 9-10 — re-import skips, receipts survive"
    $re = Upload $sup 'po-import-wip-sample.xlsx'
    if ($re.status -ne 'validated')  { Fail "re-import status='$($re.status)', expected 'validated'" }
    if ($re.wip.skipCount -ne 1)     { Fail "re-import wip.skipCount=$($re.wip.skipCount), expected 1" }
    if ($re.wip.createCount -ne 0)   { Fail "re-import wip.createCount=$($re.wip.createCount), expected 0" }
    if ($re.wip.totalQty -ne 0)      { Fail "re-import wip.totalQty=$($re.wip.totalQty), expected 0 — a skipped sheet creates nothing" }
    ConfirmAndWait $sup $re.runId 're-import' | Out-Null

    $afterPulls = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Pulls WHERE PullNumber='WIPTEST-0001';")
    $afterPos   = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PurchaseOrders WHERE PoNumber='WIPTEST-0001';")
    $afterItems = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PullItems WHERE PullId='$pullId';")
    if ($afterPulls -ne 1) { Fail "after re-import: $afterPulls pull(s) named WIPTEST-0001, expected 1" }
    if ($afterPos -ne 1)   { Fail "after re-import: $afterPos PO(s) named WIPTEST-0001, expected 1" }
    if ($afterItems -ne 3) { Fail "after re-import: $afterItems pull item(s), expected 3 — the pull must not be rebuilt" }

    $receiptsLeft = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Receipts r
  INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
WHERE pi.PullId = '$pullId';
"@)
    if ($receiptsLeft -lt 2) { Fail "receipts after re-import = $receiptsLeft, expected the 2 booked earlier to survive" }

    $winBAfter = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(w.ExpectedQty AS VARCHAR) + '/' + CAST(w.ReceivedQty AS VARCHAR)
FROM dbo.PullItemWindows w WHERE w.PullItemId = '$itemB' AND w.HourOfDay = 8;
"@
    if ($winBAfter -ne '250/250') { Fail "window after re-import = '$winBAfter', expected '250/250' — re-import must not rewrite it" }

    $skipAudit = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.AuditLog
WHERE ActionType = 'pull-synth-skip' AND EntityId = 'WIPTEST-0001';
"@)
    if ($skipAudit -lt 1) { Fail "no pull-synth-skip audit row for the re-import" }
    OK "re-import skipped: 1 pull / 1 PO / 3 items unchanged, receipts + window intact, audit row written"

    # ------------------------------------------------------------------
    Step "9. Assertion 11 — HourOfDay across every observed round"
    $rup = Upload $sup 'po-import-wip-rounds.xlsx'
    if ($rup.status -ne 'validated') { Fail "rounds fixture status='$($rup.status)'" }
    ConfirmAndWait $sup $rup.runId 'rounds' | Out-Null

    $hours = (Sql @"
SET NOCOUNT ON;
SELECT CAST(w.HourOfDay AS VARCHAR) FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = 'WIPTEST-0002' ORDER BY w.HourOfDay;
"@) | Where-Object { $_ -match '^\d+$' } | ForEach-Object { $_.Trim() }
    $got = ($hours -join ',')
    if ($got -ne '7,8,9,11,19,21,23') { Fail "HourOfDay set = '$got', expected '7,8,9,11,19,21,23'" }
    OK "07:00 08:00 09:00 11:00 19:00 21:00 23:00 → 7 8 9 11 19 21 23"

    # ------------------------------------------------------------------
    Step "10. Assertion 13 — repair: PO already imported, pull missing"
    # Reproduce the pre-feature state exactly: keep the PO and its lines,
    # delete the pull side. This is every WIP sheet imported before today.
    Sql @"
SET NOCOUNT ON;
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = 'WIPTEST-0002';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = 'WIPTEST-0002';
UPDATE dbo.PurchaseOrders SET PullId = NULL WHERE PoNumber = 'WIPTEST-0002';
DELETE FROM dbo.Pulls WHERE PullNumber = 'WIPTEST-0002';
"@ | Out-Null

    $poLinesBefore = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) + '/' + CAST(SUM(pol.OrderedQty) AS VARCHAR)
FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = 'WIPTEST-0002';
"@

    $rep = Upload $sup 'po-import-wip-rounds.xlsx'
    if ($rep.wip.repairCount -ne 1) { Fail "repair preview: repairCount=$($rep.wip.repairCount), expected 1" }
    if ($rep.wip.createCount -ne 0) { Fail "repair preview: createCount=$($rep.wip.createCount), expected 0" }
    $repRow = $rep.wip.pulls | Where-Object { $_.pullNumber -eq 'WIPTEST-0002' }
    if ($repRow.action -ne 'repair') { Fail "repair preview action='$($repRow.action)', expected 'repair'" }
    ConfirmAndWait $sup $rep.runId 'repair' | Out-Null

    $repairedItems = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId WHERE p.PullNumber = 'WIPTEST-0002';
"@)
    if ($repairedItems -ne 7) { Fail "repaired pull has $repairedItems item(s), expected 7" }

    $poLinesAfter = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) + '/' + CAST(SUM(pol.OrderedQty) AS VARCHAR)
FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = 'WIPTEST-0002';
"@
    if ($poLinesAfter -ne $poLinesBefore) {
        Fail "repair modified the existing PO: lines/qty were '$poLinesBefore', now '$poLinesAfter'"
    }
    $poCountAfter = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PurchaseOrders WHERE PoNumber='WIPTEST-0002';")
    if ($poCountAfter -ne 1) { Fail "repair created a second PO ($poCountAfter total)" }

    $repairAudit = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.AuditLog
WHERE ActionType = 'pull-synth-repair' AND EntityId = 'WIPTEST-0002';
"@)
    if ($repairAudit -lt 1) { Fail "no pull-synth-repair audit row" }
    OK "repair built the pull only ($repairedItems items); PO untouched at $poLinesAfter lines/qty; audit row written"

    # ------------------------------------------------------------------
    Step "11. Provenance is findable — audit trail + Origin on both tables"
    $createAudit = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.AuditLog
WHERE ActionType = 'pull-synthesized' AND EntityId = 'WIPTEST-0001';
"@)
    if ($createAudit -lt 1) { Fail "no pull-synthesized audit row for WIPTEST-0001" }

    $api = Invoke-RestMethod -Uri "$base/api/pulls/$pullId" -WebSession $sup
    if ($api.origin -ne 'po-import') { Fail "GET /api/pulls/{id} origin='$($api.origin)', expected 'po-import'" }
    OK "audit rows present and GET /api/pulls/{id} surfaces origin=po-import for the drawer badge"

    # ------------------------------------------------------------------
    Step "11b. The preview and the drawer actually render it"
    # A summary the server computes and nothing displays is the same as no
    # summary: the confirm modal is the only checkpoint before these rows
    # commit.
    $importsJs = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\wwwroot\js\imports.js')
    foreach ($token in 'renderWipSummary', 'imports-wip-summary', 'data.wip') {
        if ($importsJs -notmatch [regex]::Escape($token)) { Fail "imports.js is missing '$token'" }
    }
    $dashJs = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\wwwroot\js\dashboard.js')
    foreach ($token in 'd-origin-row', "p.origin === 'po-import'") {
        if ($dashJs -notmatch [regex]::Escape($token)) { Fail "dashboard.js is missing '$token'" }
    }
    $importsPage = (Invoke-WebRequest -Uri "$base/Imports" -WebSession $sup -UseBasicParsing).Content
    if ($importsPage -notmatch 'imports-wip-summary') { Fail "/Imports does not render the WIP summary host element" }
    $dashPage = (Invoke-WebRequest -Uri "$base/Dashboard" -WebSession $sup -UseBasicParsing).Content
    if ($dashPage -notmatch 'd-origin-row') { Fail "/Dashboard drawer has no origin row" }
    OK "preview host + renderer wired on /Imports; origin row wired in the /Dashboard drawer"

    # ------------------------------------------------------------------
    Step "12. ERP-takeover detection — the cancel path on a synthesised pull"
    # If the ERP ever starts feeding a pull this import created, ErpUpsertService
    # takes it over and cancels any item the feed omits — leaving that item's PO
    # line carrying live ReceivedQty behind it, silently. The takeover is
    # deliberately NOT blocked; what was missing was the trail.
    #
    # UNVERIFIED END-TO-END, ON PURPOSE. The live path needs an ETL run
    # against the ERP host at 103.13.229.21, which is unreachable without VPN
    # — smoke-phase-10-7 skips for the same reason. What is covered here is
    # the source wiring plus, the part a compile cannot prove, that the
    # ReceivedQty lookup is valid SQL against the real schema.
    #
    # What would actually verify it, from a machine that can reach the ERP:
    #   1. Synthesise a WIP pull from a fixture import (steps 1-3 above).
    #   2. Point a sync at a source whose feed carries that PullNumber but
    #      OMITS one of its SKUs — the omission is what triggers the cancel.
    #   3. Trigger the sync (POST /api/admin/erp-sync/trigger).
    #   4. Expect: the item flips to Status='canceled', its PO line keeps its
    #      ReceivedQty, and dbo.AuditLog carries one 'etl-cancel-synth' row
    #      naming the pull, the item, and that surviving quantity.
    $upsertSrc = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\Services\ErpSync\ErpUpsertService.cs')
    foreach ($token in 'SELECT Id, Status, WarehouseId, Origin', 'etl-cancel-synth', 'OriginPoImport') {
        if ($upsertSrc -notmatch [regex]::Escape($token)) {
            Fail "ErpUpsertService no longer contains '$token' — takeover detection lost"
        }
    }
    if ($upsertSrc -notmatch 'UPDATE dbo\.PullItems SET Status = ''canceled''') {
        Fail "ErpUpsertService cancel path changed shape — re-check the detection hook"
    }

    $probe = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(ISNULL(SUM(pol.ReceivedQty), -1) AS VARCHAR)
FROM   dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE  (po.PullId = '$pullId' OR po.PullExternalRef = 'WIPTEST-0001')
  AND  pol.ItemCode = 'WIPSKU-B';
"@
    if ($probe -ne '250') { Fail "takeover ReceivedQty lookup returned '$probe', expected 250" }
    OK "cancel path reads Origin, writes etl-cancel-synth, and its ReceivedQty lookup returns 250 against the real schema"
}
finally {
    Cleanup
}

Write-Host "`nAll WIP pull-synthesis assertions passed." -ForegroundColor Green
exit 0
