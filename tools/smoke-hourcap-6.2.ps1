# Smoke test: v2.1 Hour Cap Phase 6.2 — backend enforcement
#
# Naming note: v2.1 has two parallel "Phase 6" series — PullItem admin
# (smoke-phase-6.1/6.2/6.3) and Hour Cap (verify-hourcap-6.1 +
# smoke-hourcap-6.2 + ...). The hourcap- prefix avoids file collisions
# while keeping the phase numbering aligned with the spec docs.
#
# Scope: ReceiptService.PreviewAsync + ReceiveAsync read pull.LockHourCap and,
# when true, reject receives that would push the (PullItem, Hour) window past
# its ExpectedQty BEFORE walking PO lines. When false, the legacy §7.1 v2
# behavior holds — PO is the only hard cap.
#
# Setup per case: create a fresh PL-SMOKE-HC-{tick}-{kind} pull via the API,
# attach a SUMMARY item (db/014 already seeded SUMMARY PO coverage at 50k
# capacity in WH-01) with a tight 200-pcs window at hour 14, then exercise
# the cap edges.
#
# 8 cases:
#   1. Strict pull, receive 100 on 200-cap → 200 OK
#   2. Strict pull at 100/200, receive 300 → 409 "Insufficient hour capacity"
#   3. Strict pull, receive remaining 100 → 200 OK (window now exactly full)
#   4. Strict pull, receive 1 on full window → 409 (zero remaining)
#   5. Preview WITH ?hour= on full window → 409 (Preview matches Receive)
#   6. Preview WITHOUT ?hour= on full window → 200 (back-compat, skip check)
#   7. Loose pull (LockHourCap=false), receive 500 on 200-cap → 200 OK
#   8. Legacy over-state — SQL poke ReceivedQty=300 on strict pull, receive 1 → 409
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

# Counter for unique pull numbers across rapid same-second calls; reset per run.
$script:smkN = 0

function SqlCleanup {
    # Receipts.PullItemId FK blocks Pulls deletion when this smoke has actually
    # received. Receipts is "append-only" in production (CLAUDE.md convention)
    # but this is test teardown — wiping the smoke namespace is the point.
    # Order: receipts → pulls (windows + items cascade with Pulls).
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

function InvokeExpectFail($method, $uri, $body, $session, $expectedStatus) {
    try {
        $args = @{ Uri = $uri; Method = $method; WebSession = $session; ContentType = 'application/json' }
        if ($body) { $args.Body = $body }
        Invoke-RestMethod @args | Out-Null
        return $null
    }
    catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        $status = [int]$resp.StatusCode
        $title  = $null
        if ($_.ErrorDetails.Message) {
            try {
                $pd = $_.ErrorDetails.Message | ConvertFrom-Json
                $title = $pd.title
            } catch { $title = $_.ErrorDetails.Message }
        }
        if ($status -ne $expectedStatus) {
            return [pscustomobject]@{ Status=$status; Title=$title; Wrong=$true }
        }
        return [pscustomobject]@{ Status=$status; Title=$title; Wrong=$false }
    }
}

# Convenience: create a fresh pull + a single SUMMARY item with one window.
function NewSmokePullWithItem($lockHourCap, $kind, $windowQty = 200, $hour = 14) {
    # Pull number is UNIQUE; keep < 32 chars (PullCreateRequest validates). Format:
    # PL-SHC-{unix_seconds}-{counter}-{kind} → max ~24 chars when kind is short.
    $script:smkN++
    $pullNum = "PL-SHC-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$($script:smkN)-$kind"
    $pullBody = @{
        pullNumber = $pullNum; warehouseId = $WH_01
        pullDate = (Get-Date -Format 'yyyy-MM-dd')
        eta = $null; notes = $null
        lockPoByPull = $false
        lockHourCap = $lockHourCap
    } | ConvertTo-Json
    $pull = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv
    $itemBody = @{
        itemCode = 'SUMMARY'; description = 'Smoke HC SUMMARY item'
        windows = @(@{ hourOfDay = $hour; expectedQty = $windowQty })
    } | ConvertTo-Json -Depth 5
    $item = Invoke-RestMethod -Uri "$base/api/pulls/$($pull.id)/items" -Method POST -Body $itemBody -ContentType 'application/json' -WebSession $sv
    return [pscustomobject]@{
        PullId = $pull.id; PullNumber = $pullNum;
        ItemId = $item.id; Hour = $hour;
        WindowQty = $windowQty;
    }
}

function Receive($pullItemId, $hour, $qty, $session = $sv) {
    $body = @{
        pullItemId = $pullItemId; hourOfDay = $hour; qty = $qty;
        lotBatch = $null; palletId = $null; binLocation = $null;
        qcStatus = 'pending'; note = $null
    } | ConvertTo-Json
    return Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $session
}

# ----------------------------------------------------------------------------
$sv = Login 'sadmin' 'admin' $WH_01

# Source check — service has the hour-cap branch
Step "Source: ReceiptService has EnforceHourCapAsync + LockHourCap branch"
$svc = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Services\ReceiptService.cs' -Raw
foreach ($needle in @(
    'EnforceHourCapAsync',
    'pullCtx.LockHourCap',
    'Insufficient hour capacity',
    'p.LockHourCap'   # both Preview + Receive SELECTs should include the column
)) {
    if ($svc -notmatch [regex]::Escape($needle)) { Fail "ReceiptService missing $needle" }
}
OK "Service carries hour-cap enforcement branch"

# ----------------------------------------------------------------------------
# 1. Strict pull — receive 100 of 200 → OK
# ----------------------------------------------------------------------------
Step "Strict pull, receive 100 of 200 cap → 200 OK"
$strict = NewSmokePullWithItem $true 'STRICT-A'
$r = Receive $strict.ItemId $strict.Hour 100
if ($r.newReceivedQty -ne 100) { Fail "Expected newReceivedQty=100, got $($r.newReceivedQty)" }
OK "Receive 100 → newReceivedQty=100"

# ----------------------------------------------------------------------------
# 2. Strict pull — receive 300 more would overflow → 409
# ----------------------------------------------------------------------------
Step "Strict pull at 100/200, receive 300 → 409 'Insufficient hour capacity'"
$body = @{
    pullItemId = $strict.ItemId; hourOfDay = $strict.Hour; qty = 300;
    lotBatch = $null; palletId = $null; binLocation = $null;
    qcStatus = 'pending'; note = $null
} | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/receipts" $body $sv 409
if (-not $r -or $r.Wrong) { Fail "Expected 409, got $($r.Status)" }
if ($r.Title -notmatch 'Insufficient hour capacity') { Fail "Title missing 'Insufficient hour capacity': $($r.Title)" }
if ($r.Title -notmatch 'Hour 14:00') { Fail "Title missing 'Hour 14:00': $($r.Title)" }
OK "409 with the expected title"

# ----------------------------------------------------------------------------
# 3. Strict pull — fill the remaining 100 exactly → OK, window full
# ----------------------------------------------------------------------------
Step "Strict pull, receive 100 fills window exactly → 200 OK"
$r = Receive $strict.ItemId $strict.Hour 100
if ($r.newReceivedQty -ne 200) { Fail "Expected newReceivedQty=200, got $($r.newReceivedQty)" }
OK "Receive 100 → newReceivedQty=200 (cap reached)"

# ----------------------------------------------------------------------------
# 4. Strict pull — receive 1 on full window → 409
# ----------------------------------------------------------------------------
Step "Strict pull at 200/200, receive 1 → 409 (zero remaining)"
$body = @{
    pullItemId = $strict.ItemId; hourOfDay = $strict.Hour; qty = 1;
    lotBatch = $null; palletId = $null; binLocation = $null;
    qcStatus = 'pending'; note = $null
} | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/receipts" $body $sv 409
if (-not $r -or $r.Wrong) { Fail "Expected 409 on full window, got $($r.Status)" }
if ($r.Title -notmatch 'already received 200') { Fail "Title missing 'already received 200': $($r.Title)" }
OK "409 — full window rejected"

# ----------------------------------------------------------------------------
# 5. Preview WITH ?hour= on the full window → 409
# ----------------------------------------------------------------------------
Step "GET /preview?pullItemId=&qty=50&hour=14 on full window → 409"
$r = InvokeExpectFail 'GET' "$base/api/receipts/preview?pullItemId=$($strict.ItemId)&qty=50&hour=14" $null $sv 409
if (-not $r -or $r.Wrong) { Fail "Preview expected 409, got $($r.Status)" }
if ($r.Title -notmatch 'Insufficient hour capacity') { Fail "Preview title wrong: $($r.Title)" }
OK "Preview also rejects when hour passed"

# ----------------------------------------------------------------------------
# 6. Preview WITHOUT ?hour= → 200 (back-compat path skips the check)
# ----------------------------------------------------------------------------
Step "GET /preview WITHOUT hour on full window → 200 (back-compat)"
$preview = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$($strict.ItemId)&qty=50" -Method GET -WebSession $sv
if (-not $preview.allocations) { Fail "Preview returned no allocations" }
OK "Preview returns allocations when hour omitted (skip cap check)"

# ----------------------------------------------------------------------------
# 7. Loose pull (LockHourCap=false) — over-cap receive → 200 OK
# ----------------------------------------------------------------------------
Step "Loose pull, receive 500 on 200-cap window → 200 OK (cap not enforced)"
$loose = NewSmokePullWithItem $false 'LOOSE-A'
$r = Receive $loose.ItemId $loose.Hour 500
if ($r.newReceivedQty -ne 500) { Fail "Loose expected newReceivedQty=500, got $($r.newReceivedQty)" }
OK "Loose pull receive 500 over 200-cap allowed (§7.1 legacy behavior preserved)"

# ----------------------------------------------------------------------------
# 8. Legacy over-state on strict pull — SQL poke ReceivedQty=300, receive 1 → 409
# ----------------------------------------------------------------------------
Step "Strict pull with SQL-poked over-state (300/200), receive 1 → 409"
$over = NewSmokePullWithItem $true 'OVER-A'
$pokeSql = @"
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
UPDATE dbo.PullItemWindows
   SET ReceivedQty = 300
 WHERE PullItemId = '$($over.ItemId)' AND HourOfDay = $($over.Hour);
"@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -b -Q $pokeSql 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "SQL poke failed (exit $LASTEXITCODE)" }

$body = @{
    pullItemId = $over.ItemId; hourOfDay = $over.Hour; qty = 1;
    lotBatch = $null; palletId = $null; binLocation = $null;
    qcStatus = 'pending'; note = $null
} | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/receipts" $body $sv 409
if (-not $r -or $r.Wrong) { Fail "Legacy over-state expected 409, got $($r.Status)" }
if ($r.Title -notmatch 'already received 300') { Fail "Title missing 'already received 300': $($r.Title)" }
OK "Strict pull rejects future receives on legacy-over windows"

SqlCleanup
Write-Host ""
Write-Host "ALL PASS — Hour Cap Phase 6.2 backend enforcement wired into Preview + Receive." -ForegroundColor Green
exit 0
