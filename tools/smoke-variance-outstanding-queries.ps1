# Smoke: db/047 — the five outstanding / pending queries honour IsClosed = 0
#
# Brief §2c lists five parallel copies of the outstanding arithmetic. They are
# deliberately NOT consolidated into a shared helper in this change, so each one
# needs its own named test — a filter added to four of five is a bug that shows
# up weeks later in someone's worklist.
#
#   Q1  ReceiptService  window gate      — a closed window refuses further receipts
#   Q2  ReceiptService  :387 NOT EXISTS  — short-closed line does not pin the pull
#                                          off fully_received
#   Q3  ReceiptService  :413 count       — ReceiveResult.FullyReceived honours it
#   Q4  PullRepository  :42-45           — WindowsPending badge drops on close
#   Q5  CloseService    :67-72           — a short-closed pull can still be closed
#
# Each case creates its own PL-VQ-* fixture so the cases are order-independent
# and can be run individually while debugging.
#
# Assumes ReceivingOps.Web is running on http://localhost:5213 and that
# db/047 has been applied.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$SQL   = @{ S = 'LAPTOP-CSB3KO3E'; d = 'ReceivingOps' }

$script:pass = 0
$script:fail = 0
function Case($n) { Write-Host "`n=== $n ===" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  PASS: $m" -ForegroundColor Green; $script:pass++ }
function Bad($m)  { Write-Host "  FAIL: $m" -ForegroundColor Red;   $script:fail++ }

function Sql($query) {
    sqlcmd -S $SQL.S -E -C -d $SQL.d -I -h -1 -W -Q "SET NOCOUNT ON; $query" 2>&1
}

function Cleanup {
    $q = @'
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-VQ-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-VQ-%';
DELETE pol FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'PO-VQ-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-VQ-%';
'@
    sqlcmd -S $SQL.S -E -C -d $SQL.d -I -h -1 -W -Q $q 2>&1 | Out-Null
}

function Login {
    $body = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Creates a PO with capacity for every item code used, plus a pull carrying ONE
# item per spec — each with exactly ONE window.
#
# One window per item is deliberate, not incidental: the §2c guard refuses
# variance on a multi-window PullItem, so a fixture that piled several hours
# onto one item could never exercise the close path at all. It also mirrors real
# ERP data, where every item observed is 1:1.
#
# $specs: array of @{ code=<itemCode>; hour=<0-23>; qty=<expectedQty> }
# Returns PullId / PullNumber / Items (array of item ids, in spec order).
function NewFixture($tag, $specs) {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString().Substring(6)

    $lines = @()
    $n = 1
    foreach ($code in ($specs.code | Select-Object -Unique)) {
        $lines += @{ lineNumber=$n; itemCode=$code; description='vq'; orderedQty=100000 }
        $n++
    }
    $poBody = @{
        poNumber = "PO-VQ-$tag-$stamp"; warehouseId = $WH_01
        orderDate = (Get-Date -Format 'yyyy-MM-dd'); expectedDate = $null
        notes = 'db/047 query smoke'; pullId = $null
        lines = $lines
    } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri "$base/api/pos" -Method POST -Body $poBody -ContentType 'application/json' -WebSession $sv | Out-Null

    $pullNum = "PL-VQ-$tag-$stamp"
    $pullBody = @{
        pullNumber = $pullNum; warehouseId = $WH_01
        pullDate = (Get-Date -Format 'yyyy-MM-dd'); eta = $null; notes = $null
        lockPoByPull = $false; lockHourCap = $false
    } | ConvertTo-Json
    $pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv

    $ids = @()
    foreach ($s in $specs) {
        $itemBody = @{
            itemCode=$s.code; description='db/047 query smoke'
            windows=@(@{ hourOfDay=$s.hour; expectedQty=$s.qty })
        } | ConvertTo-Json -Depth 5
        $item = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -Body $itemBody -ContentType 'application/json' -WebSession $sv
        $ids += $item.id
    }

    [pscustomobject]@{ PullId=$pull.id; PullNumber=$pullNum; Items=$ids; ItemId=$ids[0] }
}

function Receive($itemId, $hour, $qty, $variance = $false, $note = $null) {
    $body = @{
        pullItemId=$itemId; hourOfDay=$hour; qty=$qty
        lotBatch=$null; palletId=$null; binLocation=$null
        qcStatus='pending'; note=$note; varianceAccepted=$variance
        # db/049 — a variance needs a reason code; COUNT_MISMATCH is valid in both
        # directions and needs no note. Reason rules: smoke-variance-reason.ps1.
        varianceReasonCode = $(if ($variance) { 'COUNT_MISMATCH' } else { $null })
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
}

function ReceiveExpectFail($itemId, $hour, $qty, $variance, $note, $expectStatus, $expectCode) {
    $body = @{
        pullItemId=$itemId; hourOfDay=$hour; qty=$qty
        lotBatch=$null; palletId=$null; binLocation=$null
        qcStatus='pending'; note=$note; varianceAccepted=$variance
        # db/049 — a variance needs a reason code; COUNT_MISMATCH is valid in both
        # directions and needs no note. Reason rules: smoke-variance-reason.ps1.
        varianceReasonCode = $(if ($variance) { 'COUNT_MISMATCH' } else { $null })
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv | Out-Null
        return [pscustomobject]@{ Ok=$false; Status=200; Code=$null; Msg='unexpected success' }
    } catch {
        $status = [int]$_.Exception.Response.StatusCode
        $code = $null; $title = $null
        if ($_.ErrorDetails.Message) {
            try { $pd = $_.ErrorDetails.Message | ConvertFrom-Json; $code = $pd.code; $title = $pd.title } catch {}
        }
        return [pscustomobject]@{ Ok=($status -eq $expectStatus -and $code -eq $expectCode); Status=$status; Code=$code; Msg=$title }
    }
}

Cleanup
$sv = Login

# ---------------------------------------------------------------------------
Case 'Q1 — ReceiptService window gate: a closed window refuses further receipts'
# 1000 expected; short-close at 400 with variance, then try to receive again.
$f1 = NewFixture 'Q1' @(@{ code='SUMMARY'; hour=10; qty=1000 })
$r = Receive $f1.ItemId 10 400 $true 'short close - truck not returning'
if ($r.isClosed -ne $true)       { Bad "expected isClosed=true, got $($r.isClosed)" }
elseif ($r.varianceQty -ne -600) { Bad "expected varianceQty=-600, got $($r.varianceQty)" }
elseif ($r.newOutstanding -ne 600) { Bad "expected newOutstanding=600, got $($r.newOutstanding)" }
else { OK "short close recorded: isClosed=true varianceQty=-600 outstanding=600" }

$blocked = ReceiveExpectFail $f1.ItemId 10 50 $false $null 409 'LINE_ALREADY_CLOSED'
if ($blocked.Ok) { OK "further receive refused 409 LINE_ALREADY_CLOSED" }
else { Bad "expected 409/LINE_ALREADY_CLOSED, got $($blocked.Status)/$($blocked.Code) — $($blocked.Msg)" }

# ---------------------------------------------------------------------------
Case 'Q2 — ReceiptService:387 NOT EXISTS: short-closed line does not pin the pull'
# Two windows. Close hour 10 short, fill hour 11 exactly. Pull must reach
# fully_received even though hour 10 still has Expected > Received.
$f2 = NewFixture 'Q2' @(@{ code='SUMMARY'; hour=10; qty=1000 }, @{ code='VQ-ITEM-B'; hour=11; qty=500 })
Receive $f2.ItemId 10 400 $true 'short close hour 10' | Out-Null
Receive $f2.Items[1] 11 500 $false $null | Out-Null
$status = (Sql "SELECT Status FROM dbo.Pulls WHERE PullNumber='$($f2.PullNumber)';").Trim()
if ($status -eq 'fully_received') { OK "pull reached fully_received despite the short-closed window" }
else { Bad "expected fully_received, got '$status' — the NOT EXISTS at :387 is not honouring IsClosed" }

# residual proof: hour 10 really is still Expected > Received
$resid = (Sql "SELECT CAST(COUNT(*) AS varchar(10)) FROM dbo.PullItemWindows piw JOIN dbo.PullItems pi ON pi.Id=piw.PullItemId JOIN dbo.Pulls p ON p.Id=pi.PullId WHERE p.PullNumber='$($f2.PullNumber)' AND piw.ExpectedQty > piw.ReceivedQty AND piw.IsClosed=1;").Trim()
if ($resid -eq '1') { OK "the closed window genuinely still has Expected > Received (arithmetic alone would call it pending)" }
else { Bad "expected 1 closed-but-unfilled window, got $resid" }

# ---------------------------------------------------------------------------
Case 'Q3 — ReceiptService:413 count: ReceiveResult.FullyReceived honours IsClosed'
$f3 = NewFixture 'Q3' @(@{ code='SUMMARY'; hour=10; qty=1000 }, @{ code='VQ-ITEM-B'; hour=11; qty=500 })
Receive $f3.ItemId 10 400 $true 'short close hour 10' | Out-Null
$last = Receive $f3.Items[1] 11 500 $false $null
if ($last.fullyReceived -eq $true) { OK "fullyReceived=true returned on the receive that filled the last open window" }
else { Bad "expected fullyReceived=true, got $($last.fullyReceived) — the count at :413 is not honouring IsClosed" }

# ---------------------------------------------------------------------------
Case 'Q4 — PullRepository:42-45 WindowsPending: the dashboard badge drops on close'
$f4 = NewFixture 'Q4' @(@{ code='SUMMARY'; hour=10; qty=1000 }, @{ code='VQ-ITEM-B'; hour=11; qty=500 })
$before = (Invoke-RestMethod -Uri "$base/api/pulls?page=1&pageSize=200" -WebSession $sv).items |
          Where-Object { $_.pullNumber -eq $f4.PullNumber }
if ($before.windowsPending -ne 2) { Bad "expected windowsPending=2 before, got $($before.windowsPending)" }
else { OK "windowsPending=2 before the close" }

Receive $f4.ItemId 10 100 $true 'short close for badge test' | Out-Null
$after = (Invoke-RestMethod -Uri "$base/api/pulls?page=1&pageSize=200" -WebSession $sv).items |
         Where-Object { $_.pullNumber -eq $f4.PullNumber }
if ($after.windowsPending -eq 1) { OK "windowsPending dropped to 1 — the closed line left the worklist" }
else { Bad "expected windowsPending=1 after close, got $($after.windowsPending)" }

# ---------------------------------------------------------------------------
Case 'Q5 — CloseService:67-72 close gate: a short-closed pull can still be closed'
$f5 = NewFixture 'Q5' @(@{ code='SUMMARY'; hour=10; qty=1000 })
Receive $f5.ItemId 10 250 $true 'short close - closing the pull after' | Out-Null
$closeBody = @{ signatureSvg='<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><path d="M0 0 L10 10"/></svg>' } | ConvertTo-Json
try {
    Invoke-RestMethod -Uri "$base/api/pulls/$($f5.PullId)/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $sv | Out-Null
    $st = (Sql "SELECT Status FROM dbo.Pulls WHERE PullNumber='$($f5.PullNumber)';").Trim()
    if ($st -eq 'closed') { OK "pull closed despite the window still showing Expected > Received" }
    else { Bad "close returned 200 but status is '$st'" }
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    Bad "close refused HTTP $s — the gate at CloseService:67-72 is not honouring IsClosed. $($_.ErrorDetails.Message)"
}

# ---------------------------------------------------------------------------
Cleanup
Write-Host ""
if ($script:fail -eq 0) {
    Write-Host "ALL PASS — $($script:pass) assertions across the five outstanding queries." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED — $($script:fail) failed, $($script:pass) passed." -ForegroundColor Red
    exit 1
}
