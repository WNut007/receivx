# Smoke: db/047 — every outstanding / pending computation honours IsClosed = 0
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
#   Q6  receiving.js                     — the browser's own gate, header, filter
#                                          and export (added 2026-08-18)
#
# §2c's enumeration of "five copies" counted SERVER copies. The browser had
# four more, and nothing tested them: Q1-Q5 all stop at the API boundary, and
# Q5 in particular proves the close gate by POSTing /close directly, which no
# operator ever does. Pull 0000028388 shipped with the server ready to close
# and the button disabled. Q6 covers the client side; if a seventh copy of the
# arithmetic appears anywhere, it needs its own case here.
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
-- FK_PullSig_Pull and FK_PO_Pull do NOT cascade from dbo.Pulls, so a pull
-- closed with a signature (or carrying a PO) refuses the DELETE below. The
-- delete is set-based, so ONE such pull strands the whole range -- 148 rows
-- accumulated this way before 2026-08-20. See
-- docs/defect-pull-signature-fk-blocks-smoke-cleanup.md
DELETE s FROM dbo.PullSignatures s
INNER JOIN dbo.Pulls p ON p.Id = s.PullId
WHERE p.PullNumber LIKE 'PL-VQ-%';
UPDATE po SET PullId = NULL FROM dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE p.PullNumber LIKE 'PL-VQ-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-VQ-%';
PRINT 'cleanup: pulls removed = ' + CONVERT(varchar, @@ROWCOUNT);
DELETE pol FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'PO-VQ-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-VQ-%';
'@
    # -b makes sqlcmd exit non-zero on a SQL error, and the output is kept so a
    # refusal is printed instead of discarded. A cleanup that cannot report its
    # own failure is how 148 fixture pulls accumulated unnoticed.
    $cleanupOut = sqlcmd -S $SQL.S -E -C -d $SQL.d -I -h -1 -W -b -Q $q 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "CLEANUP FAILED (exit $LASTEXITCODE): $cleanupOut" -ForegroundColor Red
        exit 2
    }
    $cleanupOut | Where-Object { $_ -match 'cleanup:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
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
# Q6 — the SIXTH copy of the outstanding arithmetic, and the one that shipped
# the bug: the Receiving console's own gate.
#
# Q1-Q5 all stop at the API boundary. Q5 proves the server lets a short-closed
# pull close — by POSTing /close directly, which no operator ever does. The
# browser never got a test, and the browser had four more copies of
# `slot.r < slot.e`: the close-pull gate, the period header, the row filter
# and the export. On pull 0000028388 (item 2R53-810288-253, window 19:00,
# 790/792 closed short) the server was ready to close and the button stayed
# disabled, because isFullyReceived() had never heard of IsClosed.
#
# Two parts, because source-greps alone are how the first four copies stayed
# wrong: first EXECUTE the shipped predicates against the real repro numbers,
# then assert every call site routes through them.
Case 'Q6 — receiving.js outstanding predicates honour IsClosed (executed, not grepped)'

$jsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\ReceivingOps.Web\wwwroot\js\receiving.js'
if (-not (Test-Path $jsPath)) { Bad "receiving.js not found at $jsPath" }
else {
    $js = Get-Content -Raw -LiteralPath $jsPath

    # Lift the two helpers straight out of the shipped file and run them in
    # node. This executes the real code — not a re-implementation of it — so a
    # future edit that breaks the rule fails here rather than in production.
    $mSettled = [regex]::Match($js, '(?s)function isSettled\(slot\) \{.*?\n  \}')
    $mOut     = [regex]::Match($js, '(?s)function slotOutstanding\(slot\) \{.*?\n  \}')
    $mVar     = [regex]::Match($js, '(?s)function slotVariance\(slot\) \{.*?\n  \}')
    if (-not $mSettled.Success -or -not $mOut.Success -or -not $mVar.Success) {
        Bad "could not extract isSettled/slotOutstanding/slotVariance from receiving.js — were they renamed?"
    } else {
        $harness = @"
$($mSettled.Value)
$($mOut.Value)
$($mVar.Value)
const cases = [
  // the production repro: 790 of 792, closed short with accept-variance
  ['closed-short settled',      isSettled({e:792, r:790, c:true}),        true],
  ['closed-short owes nothing', slotOutstanding({e:792, r:790, c:true}),  0],
  ['open partial not settled',  isSettled({e:792, r:790, c:false}),       false],
  ['open partial owes 2',       slotOutstanding({e:792, r:790, c:false}), 2],
  ['exact fill settled',        isSettled({e:792, r:792, c:false}),       true],
  ['exact fill owes nothing',   slotOutstanding({e:792, r:792, c:false}), 0],
  ['over-receipt settled',      isSettled({e:100, r:150, c:true}),        true],
  ['unscheduled settled',       isSettled({e:0,   r:0,   c:false}),       true],
  ['nothing received owes all', slotOutstanding({e:500, r:0, c:false}),   500],

  // Variance is signed like Receipts.VarianceQty: negative short, positive
  // over. Only settled windows carry one — an open partial's gap is work
  // still owed, not a decision anybody took.
  ['short close is -2',         slotVariance({e:792, r:790, c:true}),     -2],
  ['over-receipt is +50',       slotVariance({e:100, r:150, c:true}),     50],
  ['exact fill is 0',           slotVariance({e:792, r:792, c:false}),    0],
  ['open partial has none',     slotVariance({e:792, r:790, c:false}),    0],
  ['unscheduled has none',      slotVariance({e:0,   r:0,   c:false}),    0],
];

// Expected = Received - Variance + Outstanding, for every window state. This
// identity is the whole reason the figure is on the strip: without it the
// three numbers stop adding up the moment a line is written off, and an
// operator reads that as a bug.
for (const s of [{e:792,r:790,c:true}, {e:100,r:150,c:true}, {e:500,r:100,c:false},
                 {e:792,r:792,c:false}, {e:0,r:0,c:false}]) {
  const lhs = s.e;
  const rhs = s.r - slotVariance(s) + slotOutstanding(s);
  cases.push(['identity ' + JSON.stringify(s), rhs, lhs]);
}
let bad = 0;
for (const [name, got, want] of cases) {
  if (got !== want) { console.log('MISMATCH ' + name + ': got ' + got + ', want ' + want); bad++; }
}
console.log(bad === 0 ? 'PREDICATES_OK' : 'PREDICATES_FAIL');
"@
        $tmpJs = Join-Path $env:TEMP "vq-predicates-$([guid]::NewGuid().ToString('N')).js"
        try {
            Set-Content -LiteralPath $tmpJs -Value $harness -Encoding UTF8
            $nodeOut = & node $tmpJs 2>&1
            if ($LASTEXITCODE -ne 0)            { Bad "node failed to run the predicate harness: $nodeOut" }
            elseif ($nodeOut -match 'MISMATCH') { Bad "predicate mismatch: $($nodeOut -join ' | ')" }
            elseif ($nodeOut -match 'PREDICATES_OK') { OK "19 predicate cases pass — 790/792 closed short → settled, 0 outstanding, variance -2, and Expected = Received - Variance + Outstanding holds in every state" }
            else                                { Bad "unexpected harness output: $nodeOut" }
        } finally {
            Remove-Item -LiteralPath $tmpJs -ErrorAction SilentlyContinue
        }
    }

    # Call sites. The predicates being right is worthless if a surface computes
    # its own answer — which is exactly what happened.
    $sites = @(
        @{ fn = 'isFullyReceived'; needs = 'isSettled';       what = 'CLOSE PULL SHEET gate' },
        @{ fn = 'itemClass';       needs = 'isSettled';       what = 'Outstanding row filter' },
        @{ fn = 'updateStats';     needs = 'slotOutstanding'; what = 'period OUTSTANDING header' },
        @{ fn = 'updateStats';     needs = 'slotVariance';    what = 'period VARIANCE figure' }
    )
    foreach ($s in $sites) {
        $body = [regex]::Match($js, "(?s)function $($s.fn)\(.*?\n  \}")
        # Strip // comments before hunting for bare arithmetic: these functions
        # now carry comments that quote the very expressions being banned, and
        # a check that fails on its own explanation teaches people to delete
        # the explanation.
        $code = ($body.Value -split "`n" | ForEach-Object { ($_ -replace '//.*$', '') }) -join "`n"
        if (-not $body.Success)                 { Bad "could not locate $($s.fn)() in receiving.js" }
        elseif ($code -notmatch $s.needs)       { Bad "$($s.what): $($s.fn)() does not call $($s.needs)()" }
        elseif ($code -match 'slot\.r < slot\.e' -or $code -match '\bexp - rec\b') {
            Bad "$($s.what): $($s.fn)() still carries a bare outstanding term"
        }
        else                                    { OK "$($s.what) routes through $($s.needs)()" }
    }

    # The export is the fourth copy; it must use the helper and it must not
    # label a written-off line as work still coming.
    if ($js -notmatch "const outstanding = slotOutstanding\(slot\)") {
        Bad "export detail sheet does not use slotOutstanding()"
    } elseif ($js -notmatch "'Closed short'") {
        Bad "export does not distinguish a closed-short line from a Partial"
    } else {
        OK "export uses slotOutstanding() and labels closed-short lines"
    }

    # db/047 §6 — the receive response carries the window's post-tx IsClosed so
    # the client can update without a refetch. Dropping it left a just-closed
    # window reading as pending until the next page load.
    # The figure needs somewhere to render. A computed value with no element is
    # the same as no value — and the strip's grid has to make room for it.
    $viewPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\ReceivingOps.Web\Views\Receiving\Index.cshtml'
    $cssPath  = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\ReceivingOps.Web\wwwroot\css\receiving.css'
    $view = Get-Content -Raw -LiteralPath $viewPath
    $css  = Get-Content -Raw -LiteralPath $cssPath
    if ($view -notmatch 'id="stat-var"' -or $view -notmatch 'id="stat-var-sub"') {
        Bad "the Receiving strip has no variance figure (stat-var / stat-var-sub)"
    } elseif ($view -notmatch 'stat-trend muted') {
        Bad "the variance sub-line is not neutral-styled — it must not read as a warning"
    } elseif ($css -notmatch 'repeat\(5, minmax\(0, 1fr\)\) auto') {
        # minmax(0, …) rather than plain 1fr is load-bearing, not tidiness: a
        # 1fr track floors at min-content, and five stats put the track list's
        # min-content at ~1045px — the measurement that used to drag the whole
        # body sideways and take the frozen item column with it.
        Bad "the progress strip does not reserve 5 compressible columns (repeat(5, minmax(0, 1fr)) auto)"
    } elseif ($css -notmatch '@media \(max-width: 1080px\)') {
        Bad "no intermediate reflow band — the 5-stat strip overflows between 840px and ~1045px"
    } else {
        OK "variance figure present on the strip, neutral sub-line, 5 compressible columns, 1080px reflow band"
    }

    $confirm = [regex]::Match($js, '(?s)const result = await resp\.json\(\);.*?closeModal\(\);')
    if (-not $confirm.Success) {
        Bad "could not locate the confirmReceipt success path"
    } elseif ($confirm.Value -notmatch 'result\.isClosed') {
        Bad "confirmReceipt drops result.isClosed — a just-short-closed window stays 'pending' until refresh"
    } else {
        OK "confirmReceipt applies result.isClosed to the cached slot"
    }
}

# ---------------------------------------------------------------------------
Cleanup
Write-Host ""
if ($script:fail -eq 0) {
    Write-Host "ALL PASS — $($script:pass) assertions across the six outstanding computations." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED — $($script:fail) failed, $($script:pass) passed." -ForegroundColor Red
    exit 1
}
