# Smoke test: v2.1 Hour Cap Phase 6.5 — integration + regression
#
# Closes the Phase 6 test coverage matrix by exercising the cases that
# split across earlier sub-phases:
#   8.  LockHourCap=true pull with 2 windows (one full, one open) →
#       receive in the OTHER window goes through (cap is per-window, not
#       per-item).
#   9.  Close pull with a legacy-over window (ReceivedQty > ExpectedQty)
#       still succeeds — the §7.4 close gate counts windows where
#       Expected > Received (i.e. outstanding), and over-windows are
#       Expected < Received, so they're not outstanding.
#   10. Verify-style regression: PL-2900 + PL-2901 (the seeded §3.5
#       LockPoByPull=1 pulls) also have LockHourCap=1 after the backfill,
#       confirming both lock flags coexist on the same row.
#
# Tests 1-7 + Preview-matches-Receive are already in:
#   - tools/verify-hourcap-6.1.ps1  (1-2: schema + POST default/persist)
#   - tools/smoke-hourcap-6.2.ps1   (4-7: enforcement + Preview match)
#   - tools/smoke-hourcap-6.3.ps1   (3: PUT immutability)
#   - tools/smoke-hourcap-6.4.ps1   (UI source landmarks)
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

$script:smkN = 0

function SqlCleanup {
    # Same Receipts-then-Pulls order as smoke-hourcap-6.2 (Receipts FK blocks
    # Pulls deletion when this smoke actually receives).
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-SHC-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-SHC-%';
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

function NewStrictPullWithItem($windows) {
    $script:smkN++
    $pullNum = "PL-SHC-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$($script:smkN)-65"
    $body = @{
        pullNumber = $pullNum; warehouseId = $WH_01
        pullDate = (Get-Date -Format 'yyyy-MM-dd')
        eta = $null; notes = $null
        lockPoByPull = $false; lockHourCap = $true
    } | ConvertTo-Json
    $pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
    $itemBody = @{
        itemCode = 'SUMMARY'; description = 'Smoke 6.5 item'
        windows = $windows
    } | ConvertTo-Json -Depth 5
    $item = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -Body $itemBody -ContentType 'application/json' -WebSession $sv
    return [pscustomobject]@{ PullId = $pull.id; PullNumber = $pullNum; ItemId = $item.id }
}

function Receive($pullItemId, $hour, $qty) {
    $body = @{
        pullItemId = $pullItemId; hourOfDay = $hour; qty = $qty;
        lotBatch = $null; palletId = $null; binLocation = $null;
        qcStatus = 'pending'; note = $null
    } | ConvertTo-Json
    return Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
}

# ----------------------------------------------------------------------------
$sv = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
# Test 8 — Strict pull, 2 windows; receive in the OTHER window still works
# ----------------------------------------------------------------------------
Step "Strict pull with 2 windows; one full, receive in the other → 200"
$twoWin = NewStrictPullWithItem @(
    @{ hourOfDay = 14; expectedQty = 200 }
    @{ hourOfDay = 15; expectedQty = 100 }
)

# Fill the hour-14 window first
$r1 = Receive $twoWin.ItemId 14 200
if ($r1.newReceivedQty -ne 200) { Fail "h14 fill: expected 200, got $($r1.newReceivedQty)" }

# Try receive in the (still empty) hour-15 window — the cap check is
# per-window, so hour-14 being full shouldn't affect hour-15.
$r2 = Receive $twoWin.ItemId 15 50
if ($r2.newReceivedQty -ne 50) { Fail "h15 receive: expected 50, got $($r2.newReceivedQty)" }
OK "Strict cap is per-window — full h14 doesn't block h15 receive"

# ----------------------------------------------------------------------------
# Test 9 — Close pull with legacy-over window still allowed
# ----------------------------------------------------------------------------
Step "Strict pull with SQL-poked over-state, close → 200 (close gate is hour-cap-agnostic)"
$closeMe = NewStrictPullWithItem @(@{ hourOfDay = 14; expectedQty = 200 })

# Fill the window so the pull can be closed (close gate refuses when any
# window has Expected > Received). Then SQL-poke to 300 → window is over
# but still NOT outstanding (Expected < Received).
$r3 = Receive $closeMe.ItemId 14 200
if ($r3.newReceivedQty -ne 200) { Fail "fill before poke: expected 200, got $($r3.newReceivedQty)" }

$pokeSql = @"
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
UPDATE dbo.PullItemWindows
   SET ReceivedQty = 300
 WHERE PullItemId = '$($closeMe.ItemId)' AND HourOfDay = 14;
"@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -b -Q $pokeSql 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "SQL poke for legacy-over failed (exit $LASTEXITCODE)" }

$closeBody = @{ signatureSvg = 'data:image/png;base64,AAAA' } | ConvertTo-Json
$closeResult = Invoke-RestMethod -Uri "$base/api/pulls/$($closeMe.PullId)/close" -Method POST -Body $closeBody -ContentType 'application/json' -WebSession $sv
if (-not $closeResult.closedAt) { Fail "Close response missing closedAt: $($closeResult | ConvertTo-Json)" }

# Verify the pull is actually closed in DB.
$status = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT Status FROM dbo.Pulls WHERE Id = '$($closeMe.PullId)';" 2>&1
if ($status.Trim() -ne 'closed') { Fail "After close, pull Status = '$status', expected 'closed'" }
OK "Strict pull with over-window closed cleanly (Q2=A: close is hour-cap-agnostic)"

# ----------------------------------------------------------------------------
# Test 10 — Regression: PL-2900 + PL-2901 carry BOTH locks
# ----------------------------------------------------------------------------
Step "Regression: PL-2900 + PL-2901 have LockPoByPull=1 AND LockHourCap=1"
foreach ($pn in @('PL-2900', 'PL-2901')) {
    $row = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(LockPoByPull AS VARCHAR) + '|' + CAST(LockHourCap AS VARCHAR) FROM dbo.Pulls WHERE PullNumber = '$pn';" 2>&1
    if ($row.Trim() -ne '1|1') { Fail "$pn flags = '$row', expected '1|1'" }
}
OK "Both seeded §3.5 locked pulls also have LockHourCap=1 (backfill clean)"

SqlCleanup
Write-Host ""
Write-Host "ALL PASS — Hour Cap Phase 6.5 integration + regression covered." -ForegroundColor Green
exit 0
