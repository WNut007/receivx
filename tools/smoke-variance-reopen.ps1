# Smoke: db/047 §2d — the reopen action
#
# A zero-quantity close writes no Receipts row, so there is nothing to reverse.
# Without an explicit reopen a line closed that way would stay closed forever.
# §2d therefore adds one endpoint, POST /api/receipts/reopen, available for ANY
# closed window — not only zero-closed ones.
#
# Cases:
#   1. Zero close writes NO Receipts row, but DOES close the window
#   2. Reopen clears IsClosed / ClosedAt / ClosedBy / ClosedReason
#   3. Reopen writes an audit row carrying the reason
#   4. Reopen without a reason  -> 400 REOPEN_REASON_REQUIRED
#   5. Reopen a window that is not closed -> 409 LINE_NOT_CLOSED
#   6. After reopen the line receives normally again (outstanding restored)
#   7. Reopen works on a SHORT-CLOSED line too (not just zero-closed)
#   8. Reversing a variance receipt reopens the window (the other route, §2b)
#
# Assumes ReceivingOps.Web on http://localhost:5213 and db/047 applied.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

$script:pass = 0
$script:fail = 0
function Case($n) { Write-Host "`n=== $n ===" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  PASS: $m" -ForegroundColor Green; $script:pass++ }
function Bad($m)  { Write-Host "  FAIL: $m" -ForegroundColor Red;   $script:fail++ }

function Sql($q) { sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; $q" 2>&1 }

function Cleanup {
    $q = @'
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-ROP-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-ROP-%';
DELETE pol FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'PO-ROP-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-ROP-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $q 2>&1 | Out-Null
}

$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -ContentType 'application/json' -SessionVariable sv `
    -Body (@{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json) | Out-Null

function NewFixture($expected = 1000) {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString().Substring(7)
    Invoke-RestMethod -Uri "$base/api/pos" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        poNumber="PO-ROP-$stamp"; warehouseId=$WH_01; orderDate=(Get-Date -Format 'yyyy-MM-dd')
        expectedDate=$null; notes='reopen smoke'; pullId=$null
        lines=@(@{ lineNumber=1; itemCode='SUMMARY'; description='rop'; orderedQty=100000 })
    } | ConvertTo-Json -Depth 5) | Out-Null
    $p = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        pullNumber="PL-ROP-$stamp"; warehouseId=$WH_01; pullDate=(Get-Date -Format 'yyyy-MM-dd')
        eta=$null; notes=$null; lockPoByPull=$false; lockHourCap=$false
    } | ConvertTo-Json)
    $i = Invoke-RestMethod -Uri "$base/api/pulls/$($p.id)/items" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        itemCode='SUMMARY'; description='rop'; windows=@(@{ hourOfDay=10; expectedQty=$expected })
    } | ConvertTo-Json -Depth 5)
    [pscustomobject]@{ PullNumber="PL-ROP-$stamp"; PullId=$p.id; ItemId=$i.id }
}

function Receive($itemId, $qty, $variance, $note) {
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        pullItemId=$itemId; hourOfDay=10; qty=$qty; lotBatch=$null; palletId=$null
        binLocation=$null; qcStatus='pending'; note=$note; varianceAccepted=$variance
    } | ConvertTo-Json)
}
function Reopen($itemId, $reason) {
    Invoke-RestMethod -Uri "$base/api/receipts/reopen" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        pullItemId=$itemId; hourOfDay=10; reason=$reason
    } | ConvertTo-Json)
}
function ReopenExpectFail($itemId, $reason, $expectStatus, $expectCode) {
    try {
        Reopen $itemId $reason | Out-Null
        return [pscustomobject]@{ Ok=$false; Status=200; Code=$null }
    } catch {
        $s=[int]$_.Exception.Response.StatusCode; $c=$null
        if ($_.ErrorDetails.Message) { try { $c=($_.ErrorDetails.Message|ConvertFrom-Json).code } catch {} }
        return [pscustomobject]@{ Ok=($s -eq $expectStatus -and $c -eq $expectCode); Status=$s; Code=$c }
    }
}

Cleanup

# ---------------------------------------------------------------------------
Case '1 — zero close writes NO Receipts row but DOES close the window'
$f = NewFixture 1000
$r = Receive $f.ItemId 0 $true 'nothing arrived - closing short'
$rows = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.Receipts r JOIN dbo.PullItems pi ON pi.Id=r.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f.PullNumber)';").Trim()
if ($rows -ne '0') { Bad "expected 0 Receipts rows for a zero close, got $rows — CK_Receipts_QtyNonZero would have been violated" }
else { OK "no Receipts row written (the ledger invariant is intact)" }
if ($r.isClosed -ne $true) { Bad "expected isClosed=true, got $($r.isClosed)" }
elseif ($r.varianceQty -ne -1000) { Bad "expected varianceQty=-1000, got $($r.varianceQty)" }
else { OK "window closed with varianceQty=-1000 (full outstanding written off)" }
$recv = (Sql "SELECT CAST(piw.ReceivedQty AS varchar(10)) FROM dbo.PullItemWindows piw JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f.PullNumber)';").Trim()
if ($recv -eq '0') { OK "ReceivedQty untouched at 0 — a zero close moves no goods" }
else { Bad "expected ReceivedQty=0, got $recv" }

# ---------------------------------------------------------------------------
Case '2 — reopen clears all four close columns'
$res = Reopen $f.ItemId 'operator closed the wrong line'
if ($res.isClosed -ne $false) { Bad "expected isClosed=false in response, got $($res.isClosed)" }
else { OK "response reports isClosed=false, outstanding=$($res.newOutstanding)" }
$cols = (Sql "SELECT CONCAT(CAST(piw.IsClosed AS int), '|', ISNULL(CONVERT(varchar(30),piw.ClosedAt,120),'NULL'), '|', ISNULL(CAST(piw.ClosedBy AS varchar(40)),'NULL'), '|', ISNULL(piw.ClosedReason,'NULL')) FROM dbo.PullItemWindows piw JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f.PullNumber)';").Trim()
if ($cols -eq '0|NULL|NULL|NULL') { OK "IsClosed=0, ClosedAt/ClosedBy/ClosedReason all NULL" }
else { Bad "close columns not fully cleared: '$cols'" }

# ---------------------------------------------------------------------------
Case '3 — reopen writes an audit row carrying the reason'
$aud = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.AuditLog WHERE ActionType='window-reopen' AND Message LIKE '%operator closed the wrong line%';").Trim()
if ($aud -ge '1') { OK "audit row present with ActionType='window-reopen' and the reason in the message" }
else { Bad "no audit row found for the reopen" }

# ---------------------------------------------------------------------------
Case '4 — reopen without a reason is refused'
$f4 = NewFixture 500
Receive $f4.ItemId 0 $true 'close for reason test' | Out-Null
$r4 = ReopenExpectFail $f4.ItemId '   ' 400 'REOPEN_REASON_REQUIRED'
if ($r4.Ok) { OK "400 REOPEN_REASON_REQUIRED on a whitespace-only reason" }
else { Bad "expected 400/REOPEN_REASON_REQUIRED, got $($r4.Status)/$($r4.Code)" }

# ---------------------------------------------------------------------------
Case '5 — reopening a window that is not closed is refused'
$f5 = NewFixture 500
$r5 = ReopenExpectFail $f5.ItemId 'nothing to reopen here' 409 'LINE_NOT_CLOSED'
if ($r5.Ok) { OK "409 LINE_NOT_CLOSED — the conditional update matched no row" }
else { Bad "expected 409/LINE_NOT_CLOSED, got $($r5.Status)/$($r5.Code)" }

# ---------------------------------------------------------------------------
Case '6 — after reopen the line receives normally again'
$r6 = Receive $f.ItemId 250 $false $null
if ($r6.newReceivedQty -eq 250 -and $r6.newOutstanding -eq 750 -and $r6.isClosed -eq $false) {
    OK "partial of 250 accepted, outstanding 750, line open"
} else {
    Bad "unexpected after-reopen state: received=$($r6.newReceivedQty) outstanding=$($r6.newOutstanding) closed=$($r6.isClosed)"
}

# ---------------------------------------------------------------------------
Case '7 — reopen works on a SHORT-CLOSED line, not just a zero-closed one'
$f7 = NewFixture 1000
Receive $f7.ItemId 600 $true 'short close - remainder written off' | Out-Null
$before = (Sql "SELECT CAST(piw.IsClosed AS int) FROM dbo.PullItemWindows piw JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f7.PullNumber)';").Trim()
$res7 = Reopen $f7.ItemId 'the rest turned up after all'
$after = (Sql "SELECT CAST(piw.IsClosed AS int) FROM dbo.PullItemWindows piw JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f7.PullNumber)';").Trim()
if ($before -eq '1' -and $after -eq '0' -and $res7.newOutstanding -eq 400) {
    OK "short-closed line reopened; the 600 already received is retained and 400 is outstanding again"
} else { Bad "before=$before after=$after outstanding=$($res7.newOutstanding) (expected 1, 0, 400)" }

# ---------------------------------------------------------------------------
Case '8 — reversing a variance receipt reopens the window (the other route)'
$f8 = NewFixture 1000
$rec8 = Receive $f8.ItemId 700 $true 'short close to be reversed'
$closedBefore = (Sql "SELECT CAST(piw.IsClosed AS int) FROM dbo.PullItemWindows piw JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f8.PullNumber)';").Trim()
$receiptId = $rec8.allocations[0].receiptId
Invoke-RestMethod -Uri "$base/api/receipts/$receiptId/cancel" -Method POST -ContentType 'application/json' -WebSession $sv `
    -Body (@{ reason='miscount'; note='reversing the variance close' } | ConvertTo-Json) | Out-Null
$closedAfter = (Sql "SELECT CONCAT(CAST(piw.IsClosed AS int), '|', ISNULL(piw.ClosedReason,'NULL'), '|', CAST(piw.ReceivedQty AS varchar(10))) FROM dbo.PullItemWindows piw JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f8.PullNumber)';").Trim()
if ($closedBefore -eq '1' -and $closedAfter -eq '0|NULL|0') {
    OK "reversal cleared IsClosed and ClosedReason and restored ReceivedQty to 0"
} else { Bad "before=$closedBefore after='$closedAfter' (expected 1, then '0|NULL|0')" }

# ---------------------------------------------------------------------------
Cleanup
Write-Host ""
if ($script:fail -eq 0) {
    Write-Host "ALL PASS — $($script:pass) assertions across the reopen action." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED — $($script:fail) failed, $($script:pass) passed." -ForegroundColor Red
    exit 1
}
