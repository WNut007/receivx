# Smoke: db/047 brief §8 — the regression cases not already covered elsewhere.
#
# Already covered by their own suites, NOT repeated here:
#   §8.7  §8.14 §8.22  -> smoke-variance-outstanding-queries.ps1
#   §8.8  §8.9  §8.11  -> smoke-hourcap-6.2.ps1 (7a/7b) + preview-confirm-agreement
#   §8.10b §8.17       -> smoke-variance-reopen.ps1
#
# Covered here: 1, 2, 3, 4, 5, 6, 10, 10c, 12, 15, 16, 18, 19, 20, 21, 23.
#
# UI-only cases (13, and the Confirm-disabled halves of 8 and 20) are DOM
# behaviour. There is no browser harness in this repo, so they are asserted at
# source level below and were additionally verified live in the browser against
# the running app — see db/047_STATUS.md.
#
# Assumes ReceivingOps.Web on http://localhost:5213 and db/047 applied.
# Run tools\seed-summary-po-capacity.ps1 first if SUMMARY capacity is exhausted.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WDT   = 'Transferred from WDT'      # DoReportConstants.WdtTransferNote

$script:pass = 0
$script:fail = 0
function Case($n) { Write-Host "`n=== $n ===" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  PASS: $m" -ForegroundColor Green; $script:pass++ }
function Bad($m)  { Write-Host "  FAIL: $m" -ForegroundColor Red;   $script:fail++ }
function Sql($q)  { sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; $q" 2>&1 }

function Cleanup {
    $q = @'
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-S8-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-S8-%';
DELETE pol FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'PO-S8-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-S8-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $q 2>&1 | Out-Null
}

$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -ContentType 'application/json' -SessionVariable sv `
    -Body (@{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json) | Out-Null

# One PO line of $poQty for the item, one pull, one item, one window.
# $poLines > 1 splits capacity across several lines so the FIFO walk must slice.
function NewFixture($tag, $expected, $poQty = 100000, $poLines = 1, $wdtNote = $false) {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString().Substring(7)
    $code  = "S8-$tag-$stamp"
    $lines = @()
    for ($i = 1; $i -le $poLines; $i++) {
        $lines += @{ lineNumber=$i; itemCode=$code; description="s8"; orderedQty=$poQty }
    }
    $po = Invoke-RestMethod -Uri "$base/api/pos" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        poNumber="PO-S8-$tag-$stamp"; warehouseId=$WH_01; orderDate=(Get-Date -Format 'yyyy-MM-dd')
        expectedDate=$null; notes='s8'; pullId=$null; lines=$lines
    } | ConvertTo-Json -Depth 5)

    # §8.16 — the Delivery NOTE whitelist matches on PurchaseOrderLines.Note.
    if ($wdtNote) {
        Sql "UPDATE pol SET Note = '$WDT' FROM dbo.PurchaseOrderLines pol WHERE pol.PurchaseOrderId = '$($po.id)';" | Out-Null
    }

    $pullNum = "PL-S8-$tag-$stamp"
    $p = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        pullNumber=$pullNum; warehouseId=$WH_01; pullDate=(Get-Date -Format 'yyyy-MM-dd')
        eta=$null; notes=$null; lockPoByPull=$false; lockHourCap=$false
    } | ConvertTo-Json)
    $i = Invoke-RestMethod -Uri "$base/api/pulls/$($p.id)/items" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        itemCode=$code; description='s8'; windows=@(@{ hourOfDay=10; expectedQty=$expected })
    } | ConvertTo-Json -Depth 5)

    [pscustomobject]@{ PullId=$p.id; PullNumber=$pullNum; ItemId=$i.id; ItemCode=$code; PoId=$po.id }
}

# $hour defaults to 10 because every fixture this smoke builds uses hour 10;
# it is a parameter so the PL-2847 cases can target their own window.
function Recv($itemId, $qty, $variance = $false, $note = $null, $hour = 10) {
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        pullItemId=$itemId; hourOfDay=$hour; qty=$qty; lotBatch=$null; palletId=$null
        binLocation=$null; qcStatus='pending'; note=$note; varianceAccepted=$variance
    } | ConvertTo-Json)
}
function RecvFail($itemId, $qty, $variance, $note, $expStatus, $expCode) {
    try { Recv $itemId $qty $variance $note | Out-Null
          return [pscustomobject]@{ Ok=$false; Status=200; Code=$null } }
    catch { $s=[int]$_.Exception.Response.StatusCode; $c=$null
            if ($_.ErrorDetails.Message) { try { $c=($_.ErrorDetails.Message|ConvertFrom-Json).code } catch {} }
            return [pscustomobject]@{ Ok=($s -eq $expStatus -and $c -eq $expCode); Status=$s; Code=$c } }
}
function WindowRow($pullNumber) {
    $r = (Sql "SELECT CONCAT(piw.ExpectedQty,'|',piw.ReceivedQty,'|',CAST(piw.IsClosed AS int),'|',ISNULL(piw.ClosedReason,'')) FROM dbo.PullItemWindows piw JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$pullNumber';").Trim() -split '\|'
    [pscustomobject]@{ Expected=[int]$r[0]; Received=[int]$r[1]; IsClosed=($r[2] -eq '1'); ClosedReason=$r[3] }
}
function PendingBadge($pullNumber) {
    ((Invoke-RestMethod -Uri "$base/api/pulls?page=1&pageSize=300" -WebSession $sv).items |
        Where-Object { $_.pullNumber -eq $pullNumber }).windowsPending
}

Cleanup

# ---------------------------------------------------------------------------
Case '§8.2 — qty < outstanding, UNTICKED: partial, line stays open (run first)'
$f = NewFixture 'C2' 1000
$r = Recv $f.ItemId 400
$w = WindowRow $f.PullNumber
if ($r.newOutstanding -eq 600 -and $r.isClosed -eq $false -and $null -eq $r.varianceQty -and
    $w.Received -eq 400 -and -not $w.IsClosed) {
    OK 'partial saved, line open, outstanding 600, no variance recorded'
} else { Bad "unexpected: outstanding=$($r.newOutstanding) closed=$($r.isClosed) variance=$($r.varianceQty) db=$($w.Received)/$($w.IsClosed)" }

# ---------------------------------------------------------------------------
Case '§8.1 — qty == outstanding: completes via the existing full-receipt path'
$f = NewFixture 'C1' 1000
$r = Recv $f.ItemId 1000
$w = WindowRow $f.PullNumber
$varianceRows = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f.PullNumber)' AND r.VarianceAccepted=1;").Trim()
if ($r.newOutstanding -eq 0 -and -not $w.IsClosed -and $varianceRows -eq '0') {
    OK 'outstanding 0, IsClosed untouched (0), no VarianceAccepted row — the variance path was not used'
} else { Bad "outstanding=$($r.newOutstanding) IsClosed=$($w.IsClosed) varianceRows=$varianceRows" }

# ---------------------------------------------------------------------------
Case '§8.3 — two sequential partials summing to expected: IsClosed untouched'
$f = NewFixture 'C3' 1000
Recv $f.ItemId 600 | Out-Null
$r = Recv $f.ItemId 400
$w = WindowRow $f.PullNumber
if ($r.newOutstanding -eq 0 -and $w.Received -eq 1000 -and -not $w.IsClosed) {
    OK 'line completes normally; IsClosed still 0'
} else { Bad "outstanding=$($r.newOutstanding) received=$($w.Received) IsClosed=$($w.IsClosed)" }

# ---------------------------------------------------------------------------
Case '§8.4 — 3,000 -> 1,000 -> 1,500 against expected 5,000 (over close)'
$f = NewFixture 'C4' 5000
Recv $f.ItemId 3000 | Out-Null
Recv $f.ItemId 1000 | Out-Null
$blocked = RecvFail $f.ItemId 1500 $false $null 400 'OVER_RECEIPT_NOT_ACCEPTED'
if ($blocked.Ok) { OK 'third receipt refused while unticked (400 OVER_RECEIPT_NOT_ACCEPTED)' }
else { Bad "expected 400/OVER_RECEIPT_NOT_ACCEPTED, got $($blocked.Status)/$($blocked.Code)" }
$r = Recv $f.ItemId 1500 $true 'over-delivery accepted'
$w = WindowRow $f.PullNumber
if ($r.varianceQty -eq 500 -and $w.Received -eq 5500 -and $w.IsClosed -and $r.newOutstanding -eq 0) {
    OK 'ticked: VarianceQty=+500, total received 5,500, line closed, outstanding 0'
} else { Bad "variance=$($r.varianceQty) received=$($w.Received) closed=$($w.IsClosed) outstanding=$($r.newOutstanding)" }

# ---------------------------------------------------------------------------
Case '§8.5 — 3,000 -> 1,000 ticked (short close), and the unticked re-run'
$f = NewFixture 'C5a' 5000
Recv $f.ItemId 3000 | Out-Null
$r = Recv $f.ItemId 1000 $true 'that is all we are getting'
$w = WindowRow $f.PullNumber
$badge = PendingBadge $f.PullNumber
if ($r.varianceQty -eq -1000 -and $w.Received -eq 4000 -and $w.IsClosed -and $badge -eq 0) {
    OK 'VarianceQty=-1000, total 4,000, line closed, gone from the pending queue (windowsPending 0)'
} else { Bad "variance=$($r.varianceQty) received=$($w.Received) closed=$($w.IsClosed) pending=$badge" }

$f2 = NewFixture 'C5b' 5000
Recv $f2.ItemId 3000 | Out-Null
Recv $f2.ItemId 1000 | Out-Null
$w2 = WindowRow $f2.PullNumber
$badge2 = PendingBadge $f2.PullNumber
if (-not $w2.IsClosed -and ($w2.Expected - $w2.Received) -eq 1000 -and $badge2 -eq 1) {
    OK 'unticked re-run: line stays open at 1,000 outstanding, still in the pending queue'
} else { Bad "closed=$($w2.IsClosed) outstanding=$($w2.Expected - $w2.Received) pending=$badge2" }

# ---------------------------------------------------------------------------
Case '§8.6 + §8.10 — recovery: qty 0 ticked closes via the close-only path'
$zeroBefore = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.Receipts WHERE QtyReceived = 0;").Trim()
$rowsBefore = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f2.PullNumber)';").Trim()
$r = Recv $f2.ItemId 0 $true 'nothing more is coming'
$rowsAfter = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f2.PullNumber)';").Trim()
$zeroAfter = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.Receipts WHERE QtyReceived = 0;").Trim()
$w2 = WindowRow $f2.PullNumber
$closedCols = (Sql "SELECT CONCAT(CASE WHEN piw.ClosedBy IS NULL THEN 'no' ELSE 'yes' END,'|',CASE WHEN piw.ClosedAt IS NULL THEN 'no' ELSE 'yes' END) FROM dbo.PullItemWindows piw JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f2.PullNumber)';").Trim()
if ($rowsAfter -eq $rowsBefore) { OK "no Receipts row created by the zero close (still $rowsAfter)" }
else { Bad "receipt rows went $rowsBefore -> $rowsAfter; the close-only path wrote a row" }
if ($zeroAfter -eq '0' -and $zeroBefore -eq '0') { OK 'COUNT(*) WHERE QtyReceived = 0 is still zero' }
else { Bad "zero-qty receipts before=$zeroBefore after=$zeroAfter" }
if ($w2.IsClosed -and $w2.Received -eq 4000 -and $r.varianceQty -eq -1000 -and $closedCols -eq 'yes|yes' -and $w2.ClosedReason -eq 'nothing more is coming') {
    OK 'window closed, ReceivedQty untouched at 4,000, VarianceQty=-1000, ClosedBy/ClosedAt/ClosedReason all set'
} else { Bad "closed=$($w2.IsClosed) received=$($w2.Received) variance=$($r.varianceQty) cols=$closedCols reason='$($w2.ClosedReason)'" }

# ---------------------------------------------------------------------------
Case '§8.12 — ticked with a blank note is refused'
$f = NewFixture 'C12' 1000
$r = RecvFail $f.ItemId 400 $true '   ' 400 'VARIANCE_REASON_REQUIRED'
if ($r.Ok) { OK '400 VARIANCE_REASON_REQUIRED on a whitespace-only note' }
else { Bad "expected 400/VARIANCE_REASON_REQUIRED, got $($r.Status)/$($r.Code)" }

# ---------------------------------------------------------------------------
Case '§8.21 — FIFO slices: two rows, both flagged, exactly one VarianceQty'
# Two PO lines of 600 each = 1,200 capacity; expected 1,000, receive 1,100 with
# variance, so the walk must split 600 + 500 across the two lines.
$f = NewFixture 'C21' 1000 600 2
$r = Recv $f.ItemId 1100 $true 'over, split across two PO lines'
$slices = (Sql "SELECT CONCAT(COUNT(*),'|',SUM(CAST(r.VarianceAccepted AS int)),'|',COUNT(r.VarianceQty),'|',ISNULL(SUM(r.VarianceQty),0)) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f.PullNumber)';").Trim() -split '\|'
if ($slices[0] -eq '2' -and $slices[1] -eq '2' -and $slices[2] -eq '1' -and $slices[3] -eq '100') {
    OK "2 receipt rows, both VarianceAccepted=1, exactly 1 carries VarianceQty, SUM=+100"
} else { Bad "rows=$($slices[0]) flagged=$($slices[1]) withVarianceQty=$($slices[2]) sum=$($slices[3])" }

# Reversing the slice that does NOT carry VarianceQty must still reopen.
$plainId = (Sql "SELECT TOP 1 CAST(r.Id AS varchar(40)) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f.PullNumber)' AND r.VarianceQty IS NULL;").Trim()
Invoke-RestMethod -Uri "$base/api/receipts/$plainId/cancel" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{reason='miscount';note='reverse the non-carrying slice'}|ConvertTo-Json) | Out-Null
$w = WindowRow $f.PullNumber
if (-not $w.IsClosed) { OK 'reversing the slice WITHOUT VarianceQty still reopened the window' }
else { Bad 'window still closed after reversing the non-carrying slice' }

# ---------------------------------------------------------------------------
Case '§8.16 — a variance-closed line still reaches the Delivery Note, with a non-zero DIFF'
$f = NewFixture 'C16' 1000 100000 1 $true      # PO line carries the WDT sentinel
Recv $f.ItemId 700 $true 'short close for the DN test' | Out-Null
# Close + sign the pull so the DO/DN is renderable.
$closeBody = @{ signatureSvg='<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><path d="M0 0 L10 10"/></svg>' } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/api/pulls/$($f.PullId)/close" -Method POST -ContentType 'application/json' -WebSession $sv -Body $closeBody | Out-Null
$dn = Invoke-WebRequest -Uri "$base/api/reports/do/$($f.PullId)/preview" -WebSession $sv -UseBasicParsing -TimeoutSec 120
$doc = Invoke-WebRequest -Uri "$base/api/reports/do/$($f.PullId)/preview?type=order" -WebSession $sv -UseBasicParsing -TimeoutSec 120
# The two report types render DIFFERENT partials: Delivery Note is
# _DoPreview.cshtml (root class .dsv-do); Delivery Order is
# _DsvOrderPreview.cshtml (root class .dord-*). Asserting .dsv-do against both
# fails on the DO for a reason that has nothing to do with this change.
$dnHasLine = ([regex]::Matches($dn.Content, 'dsv-do').Count -gt 0) -and $dn.Content -match '700'
$doHasLine = ([regex]::Matches($doc.Content,'dord-').Count -gt 0) -and $doc.Content -match '700'
if ($dnHasLine) { OK 'Delivery NOTE renders the variance-closed line at its actual received qty (700)' }
else { Bad 'Delivery Note did not render the closed line' }
if ($doHasLine) { OK 'Delivery ORDER renders it too' }
else { Bad 'Delivery Order did not render the closed line' }
$w = WindowRow $f.PullNumber
if ($w.IsClosed -and ($w.Expected - $w.Received) -eq 300) {
    OK 'and the underlying line is closed with a non-zero DIFF (1,000 expected vs 700 received)'
} else { Bad "closed=$($w.IsClosed) diff=$($w.Expected - $w.Received)" }

# ---------------------------------------------------------------------------
Case '§8.15 — concurrency: two simultaneous ticked submits, one wins'
$f = NewFixture 'C15' 1000
$body = @{ pullItemId=$f.ItemId; hourOfDay=10; qty=400; lotBatch=$null; palletId=$null
           binLocation=$null; qcStatus='pending'; note='concurrent close'; varianceAccepted=$true } | ConvertTo-Json
$job = {
    param($base,$body,$wh)
    $s=$null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -ContentType 'application/json' -SessionVariable s `
        -Body (@{username='sadmin';password='admin';warehouseId=$wh;remember=$false}|ConvertTo-Json) | Out-Null
    try { Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -ContentType 'application/json' -WebSession $s -Body $body | Out-Null; return 200 }
    catch { return [int]$_.Exception.Response.StatusCode }
}
$j1 = Start-Job -ScriptBlock $job -ArgumentList $base,$body,$WH_01
$j2 = Start-Job -ScriptBlock $job -ArgumentList $base,$body,$WH_01
$codes = @(Receive-Job -Job (Wait-Job -Job $j1,$j2 -Timeout 90)) | Sort-Object
Remove-Job -Job $j1,$j2 -Force
$rows = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f.PullNumber)';").Trim()
$w = WindowRow $f.PullNumber
if ($codes.Count -eq 2 -and $codes[0] -eq 200 -and $codes[1] -eq 409) {
    OK "one succeeded, one got 409 (results: $($codes -join ', '))"
} else { Bad "expected 200 + 409, got: $($codes -join ', ')" }
if ($rows -eq '1' -and $w.Received -eq 400) {
    OK 'exactly ONE receipt row exists — the loser rolled back its insert with the close'
} else { Bad "expected 1 receipt row / received 400, got rows=$rows received=$($w.Received)" }

# ---------------------------------------------------------------------------
Case '§8.18 + §8.19 — multi-window SKU: variance refused, partials unaffected'
$mw = (Sql "SELECT TOP 1 CAST(pi.Id AS varchar(40)) FROM dbo.PullItems pi JOIN dbo.PullItemWindows piw ON piw.PullItemId=pi.Id JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='PL-2847' AND pi.ItemCode='LCD-3.5-IPS' GROUP BY pi.Id HAVING COUNT(piw.Id) > 1;").Trim()
if (-not $mw -or $mw -match '^\s*$') {
    Write-Host "  SKIP: PL-2847 / LCD-3.5-IPS not present on this database (db/035 seed gap)" -ForegroundColor Yellow
} else {
    $hour = (Sql "SELECT TOP 1 CAST(piw.HourOfDay AS varchar(4)) FROM dbo.PullItemWindows piw WHERE piw.PullItemId='$mw' AND piw.ExpectedQty > piw.ReceivedQty ORDER BY piw.HourOfDay;").Trim()
    $b = @{ pullItemId=$mw; hourOfDay=[int]$hour; qty=1; lotBatch=$null; palletId=$null
            binLocation=$null; qcStatus='pending'; note='crafted'; varianceAccepted=$true } | ConvertTo-Json
    try { Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -ContentType 'application/json' -WebSession $sv -Body $b | Out-Null
          Bad 'crafted multi-window variance request was ACCEPTED' }
    catch { $s=[int]$_.Exception.Response.StatusCode; $c=$null
            if ($_.ErrorDetails.Message) { try { $c=($_.ErrorDetails.Message|ConvertFrom-Json).code } catch {} }
            if ($s -eq 400 -and $c -eq 'MULTI_WINDOW_NOT_SUPPORTED') { OK '400 MULTI_WINDOW_NOT_SUPPORTED on PL-2847 / LCD-3.5-IPS' }
            else { Bad "expected 400/MULTI_WINDOW_NOT_SUPPORTED, got $s/$c" } }

    # §8.19 proper — test 2 (the must-not-regress partial) run AGAINST the
    # multi-window item, where the checkbox is absent. The guard must refuse
    # variance without touching ordinary partial receiving.
    $beforeQty = [int](Sql "SELECT CAST(piw.ReceivedQty AS varchar(12)) FROM dbo.PullItemWindows piw WHERE piw.PullItemId='$mw' AND piw.HourOfDay=$hour;").Trim()
    try {
        $pr = Recv $mw 1 $false $null ([int]$hour)
        $afterQty = [int](Sql "SELECT CAST(piw.ReceivedQty AS varchar(12)) FROM dbo.PullItemWindows piw WHERE piw.PullItemId='$mw' AND piw.HourOfDay=$hour;").Trim()
        $closedNow = (Sql "SELECT CAST(piw.IsClosed AS int) FROM dbo.PullItemWindows piw WHERE piw.PullItemId='$mw' AND piw.HourOfDay=$hour;").Trim()
        if ($afterQty -eq ($beforeQty + 1) -and $closedNow -eq '0' -and $null -eq $pr.varianceQty) {
            OK 'unticked partial on the multi-window item still saves, line stays open (test 2 holds there)'
        } else { Bad "before=$beforeQty after=$afterQty closed=$closedNow variance=$($pr.varianceQty)" }
    } catch {
        $s2=[int]$_.Exception.Response.StatusCode
        Bad "unticked partial on the multi-window item was refused with $s2 — the guard is over-reaching"
    }
}

# ---------------------------------------------------------------------------
Case '§8.23 — pre-migration rows unchanged'
$legacy = (Sql "SELECT CONCAT(COUNT(*),'|',SUM(CAST(r.VarianceAccepted AS int)),'|',COUNT(r.VarianceQty)) FROM dbo.Receipts r WHERE r.ReceivedAt < '2026-08-06';").Trim() -split '\|'
if ($legacy[1] -eq '0' -and $legacy[2] -eq '0') {
    OK "all $($legacy[0]) pre-migration receipts still VarianceAccepted=0 with VarianceQty NULL"
} else { Bad "rows=$($legacy[0]) flagged=$($legacy[1]) withVariance=$($legacy[2])" }
$openWindows = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.PullItemWindows WHERE IsClosed = 1 AND ClosedBy IS NULL;").Trim()
if ($openWindows -eq '0') { OK 'no window is closed without an attributed closer' }
else { Bad "$openWindows windows have IsClosed=1 but ClosedBy NULL" }

# ---------------------------------------------------------------------------
Case '§8.10c — the two ledger CHECK constraints are unchanged by db/047'
$defs = (Sql "SELECT CONCAT(cc.name,'=',REPLACE(REPLACE(cc.definition,CHAR(13),''),CHAR(10),'')) FROM sys.check_constraints cc WHERE cc.parent_object_id=OBJECT_ID('dbo.Receipts') AND cc.name IN ('CK_Receipts_QtyNonZero','CK_Receipts_ReversalIntegrity') ORDER BY cc.name;")
$joined = ($defs | Out-String)
if ($joined -match 'CK_Receipts_QtyNonZero=\(\[QtyReceived\]<>\(0\)\)' -and
    $joined -match 'CK_Receipts_ReversalIntegrity=.*ReversesReceiptId.*QtyReceived.*>.*\(0\)') {
    OK 'both constraints carry their original predicates'
} else { Bad "unexpected definitions: $joined" }

# ---------------------------------------------------------------------------
Case '§8.13 + §8.20 + §8.8 (UI halves) — source-level assertions'
$jsRaw = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\wwwroot\js\receiving.js' -Raw
# Strip // line comments and /* */ blocks before asserting. Without this the
# check fails on the comment that DOCUMENTS the removed clamp by quoting it —
# the assertion would be reading prose as if it were code, which is exactly the
# weakness that makes source-level greps a poor substitute for behaviour.
$js = [regex]::Replace($jsRaw, '/\*[\s\S]*?\*/', '')
$js = ($js -split "`n" | ForEach-Object { $_ -replace '(^|\s)//.*$', '' }) -join "`n"
$checks = @(
    @{ n='clamp removed (no Math.min against activeMax in live code)'; ok = ($js -notmatch 'Math\.min\(\s*inputVal\s*,\s*activeMax\s*\)') },
    @{ n='input.max removed rather than set';             ok = ($js -match "removeAttribute\('max'\)") -and ($js -notmatch '\binput\.max\s*=') },
    @{ n='quick-fill dispatches a real input event';      ok = ($js -match "dispatchEvent\(new Event\('input'") },
    @{ n='stale tick cleared when the box cannot be offered'; ok = ($js -match 'if \(!canOffer && box\.checked\) box\.checked = false') },
    @{ n='Confirm gate covers over-unticked, ticked-no-note and zero-unticked'; ok = ($js -match 'over && !ticked') -and ($js -match 'ticked && noteVal\.length === 0') -and ($js -match 'qty === 0 && !ticked') },
    @{ n='Cmd+Enter honours the Confirm gate';            ok = ($js -match 'if \(btn && btn\.disabled\) return;') }
)
foreach ($c in $checks) { if ($c.ok) { OK $c.n } else { Bad $c.n } }

# ---------------------------------------------------------------------------
Cleanup
Write-Host ""
if ($script:fail -eq 0) {
    Write-Host "ALL PASS — $($script:pass) assertions across the remaining section 8 cases." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED — $($script:fail) failed, $($script:pass) passed." -ForegroundColor Red
    exit 1
}
