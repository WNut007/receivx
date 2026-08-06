# Smoke test: v2.1 Hour Cap Phase 6.2 — backend enforcement
#
# Naming note: v2.1 has two parallel "Phase 6" series — PullItem admin
# (smoke-phase-6.1/6.2/6.3) and Hour Cap (verify-hourcap-6.1 +
# smoke-hourcap-6.2 + ...). The hourcap- prefix avoids file collisions
# while keeping the phase numbering aligned with the spec docs.
#
# Scope (as of db/047 rev 11): ReceiptService.PreviewAsync + ReceiveAsync no
# longer consult pull.LockHourCap at all. An over-receipt is refused on EVERY
# pull unless the accept-variance box is ticked with a note, and permitted on
# every pull when it is. The per-hour WINDOW is unchanged — a receive still
# targets a (PullItemId, HourOfDay) and outstanding is still computed per window
# as MAX(0, Expected - Received). What went away is the cap's power to refuse.
#
# Setup per case: create a fresh PL-SMOKE-HC-{tick}-{kind} pull via the API,
# attach a SUMMARY item (db/014 already seeded SUMMARY PO coverage at 50k
# capacity in WH-01) with a tight 200-pcs window at hour 14, then exercise
# the cap edges.
#
# 10 cases:
#   1.  Strict pull, receive 100 on 200-cap → 200 OK
#   2.  Strict pull at 100/200, receive 300 UNTICKED → 400 OVER_RECEIPT_NOT_ACCEPTED
#   2b. Strict pull, over-receipt TICKED + note → 200, line closed, +VarianceQty
#   3.  Strict pull, receive remaining 100 → 200 OK (window now exactly full)
#   4.  Strict pull, receive 1 on full window UNTICKED → 400 (outstanding is 0)
#   5.  Preview WITH ?hour= on full window → 400, same status AND code as Receive
#   6.  Preview WITHOUT ?hour= on full window → 200 (back-compat, skip check)
#   7a. Loose pull, over-receipt UNTICKED → 400 OVER_RECEIPT_NOT_ACCEPTED
#   7b. Loose pull, over-receipt TICKED + note → 200, line closed, +VarianceQty
#   8.  Legacy over-state — SQL poke ReceivedQty=300, receive 1 UNTICKED → 400
#
# 2b and 7a/7b are the pair that matters: the SAME over-receipt is refused
# unticked and accepted ticked on BOTH a strict and a loose pull. That is the
# rev 11 rule stated as a test rather than as a comment.
#
# WHY CASES 2, 4 AND 8 CHANGED (db/047, brief rev 11 §2f — REVERSED)
# -------------------------------------------------------------------
# These three asserted 409 "Insufficient hour capacity" for an over-receipt on a
# strict (LockHourCap = true) pull. That refusal no longer exists: over-receipt
# is now permitted on EVERY pull, locked or not, and only with the
# final-receipt checkbox ticked plus a note. LockHourCap does not change the
# outcome of a receive at all. Unticked over-receipt returns
# 400 OVER_RECEIPT_NOT_ACCEPTED regardless of the flag.
#
# Rewriting a test to fit a change is usually a warning sign — it normally means
# the product is being bent to fit the change rather than the reverse, and that
# is exactly what an earlier revision of this file recorded when case 7 flipped.
# The distinction here is that this is a deliberate rule change made with the
# numbers in hand, not an unnoticed collision:
#
#   * 11,588 of the 11,594 open pulls with outstanding work carry
#     LockHourCap = 1; the six that do not are fixtures created by this work.
#   * ErpUpsertService.cs:189 writes a hardcoded 1 — not a parameter, not a
#     default, not an upstream flag. PullAdminService and dashboard.js:123
#     assert true a second and third time.
#   * So nobody has ever chosen the value per pull. The flag was true
#     everywhere, which makes it a constant rather than a control, and
#     honouring it made the over-receipt path unreachable on live data.
#
# The assertions below are therefore what became stale, not the product.
# The hour-cap ENFORCEMENT is gone; the hour WINDOW is untouched — a receive
# still targets a specific (PullItemId, HourOfDay) and outstanding is still
# computed per window. Cases 1, 3, 5, 6 and 7a/7b all still hold unchanged.
#
# WHY CASE 7 CHANGED EARLIER (db/047, brief §2f — "the lock stays a lock")
# ----------------------------------------------------------------
# Case 7 used to assert "Loose pull, receive 500 on a 200-cap window → 200 OK
# (cap not enforced)". db/047 replaced that: on a pull with LockHourCap=false an
# over-receipt is now permitted ONLY with an explicit accept-variance tick, and
# ticking also closes the line. Unticked it returns 400 OVER_RECEIPT_NOT_ACCEPTED.
#
# The old assertion was testing a path no operator could reach. `receiving.js:752`
# did `Math.min(inputVal, activeMax)`, silently clamping every quantity to
# outstanding regardless of the lock — so the loose-pull over-receipt only ever
# happened via a direct API call. db/047 removes that clamp (it was silent data
# loss: type 1,500, get 1,000 recorded, no error) and replaces the unreachable
# implicit path with an explicit, audited one.
#
# (That paragraph's conclusion — "with LockHourCap=true the cap is absolute" —
# was itself withdrawn by rev 11 above. Kept as the record of why case 7 moved,
# not as a statement of current behaviour.)
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
        $code   = $null      # db/047 — ProblemDetails.Extensions["code"]
        if ($_.ErrorDetails.Message) {
            try {
                $pd = $_.ErrorDetails.Message | ConvertFrom-Json
                $title = $pd.title
                $code  = $pd.code
            } catch { $title = $_.ErrorDetails.Message }
        }
        if ($status -ne $expectedStatus) {
            return [pscustomobject]@{ Status=$status; Title=$title; Code=$code; Wrong=$true }
        }
        return [pscustomobject]@{ Status=$status; Title=$title; Code=$code; Wrong=$false }
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

# db/047 added varianceAccepted + note. Both default to the pre-db/047 values, so
# the cases above that call Receive with three arguments are unchanged.
function Receive($pullItemId, $hour, $qty, $variance = $false, $note = $null) {
    $body = @{
        pullItemId = $pullItemId; hourOfDay = $hour; qty = $qty;
        lotBatch = $null; palletId = $null; binLocation = $null;
        qcStatus = 'pending'; note = $note; varianceAccepted = $variance
    } | ConvertTo-Json
    return Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
}

# ----------------------------------------------------------------------------
$sv = Login 'sadmin' 'admin' $WH_01

# Source check — service has the hour-cap branch
Step "Source: hour-cap enforcement removed (rev 11); window read + tick rule intact"
$svc = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Services\ReceiptService.cs' -Raw
# rev 11 — EnforceHourCapAsync and the "Insufficient hour capacity" message are
# GONE, deliberately: the hour cap no longer refuses a receive. Assert their
# ABSENCE, so a future revert that quietly reinstates the gate is caught here
# rather than by an operator who cannot record an over-delivery.
#
# Comments are stripped first. The file explains the removal by NAMING what was
# removed, so matching raw source makes the assertion fail on the very comment
# documenting the change — the same trap that caught the clamp assertion in
# smoke-variance-section8.ps1. An absence check has to read code, not prose.
$svcCode = [regex]::Replace($svc, '/\*[\s\S]*?\*/', '')
$svcCode = ($svcCode -split "`n" | ForEach-Object { $_ -replace '(^|\s)//.*$', '' }) -join "`n"
foreach ($gone in @('EnforceHourCapAsync', 'Insufficient hour capacity')) {
    if ($svcCode -match [regex]::Escape($gone)) {
        Fail "ReceiptService still carries '$gone' in live code — the rev 11 rule reversal has been undone"
    }
}
# The window read and the over-receipt rule must still be there.
foreach ($needle in @('ReadWindowStateAsync', 'OVER_RECEIPT_NOT_ACCEPTED', 'p.LockHourCap')) {
    if ($svc -notmatch [regex]::Escape($needle)) { Fail "ReceiptService missing $needle" }
}
OK "Hour-cap enforcement removed; the window read and the tick rule remain"

# ----------------------------------------------------------------------------
# 1. Strict pull — receive 100 of 200 → OK
# ----------------------------------------------------------------------------
Step "Strict pull, receive 100 of 200 cap → 200 OK"
$strict = NewSmokePullWithItem $true 'STRICT-A'
$r = Receive $strict.ItemId $strict.Hour 100
if ($r.newReceivedQty -ne 100) { Fail "Expected newReceivedQty=100, got $($r.newReceivedQty)" }
OK "Receive 100 → newReceivedQty=100"

# ----------------------------------------------------------------------------
# 2. Strict pull — over-receipt UNTICKED → 400 (rev 11: the lock no longer refuses)
# ----------------------------------------------------------------------------
Step "Strict pull at 100/200, receive 300 UNTICKED → 400 OVER_RECEIPT_NOT_ACCEPTED"
$body = @{
    pullItemId = $strict.ItemId; hourOfDay = $strict.Hour; qty = 300;
    lotBatch = $null; palletId = $null; binLocation = $null;
    qcStatus = 'pending'; note = $null; varianceAccepted = $false
} | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/receipts" $body $sv 400
if (-not $r -or $r.Wrong) { Fail "Expected 400, got $($r.Status)" }
if ($r.Title -notmatch 'exceeds the 100 pcs outstanding') { Fail "Title wrong: $($r.Title)" }
OK "400 — the tick is required even on a strict pull; the lock no longer decides"

# 2b. Strict pull — the SAME over-receipt, TICKED → accepted and the line closes.
#     This is the case rev 11 exists for: on live data essentially every pull is
#     strict, so if the tick did not work here it would not work anywhere.
#
#     Its OWN fixture on purpose — ticking closes the window, which would leave
#     $strict unusable for cases 3, 4 and 5 below.
Step "Strict pull, receive 300 TICKED + note → 200, line closed, VarianceQty=+100"
$strictOver = NewSmokePullWithItem $true 'STRICT-OVER'
$r = Receive $strictOver.ItemId $strictOver.Hour 300 $true 'over-delivery accepted on a strict pull'
if ($r.varianceQty -ne 100)  { Fail "Expected varianceQty=+100 (300 entered vs 200 outstanding), got $($r.varianceQty)" }
if ($r.isClosed -ne $true)   { Fail "Expected isClosed=true, got $($r.isClosed)" }
if ($r.newOutstanding -ne 0) { Fail "Expected newOutstanding=0 (never negative), got $($r.newOutstanding)" }
OK "Over-receipt recorded on a STRICT pull at the entered figure; line closed"

# ----------------------------------------------------------------------------
# 3. Strict pull — fill the remaining 100 exactly → OK, window full
# ----------------------------------------------------------------------------
Step "Strict pull, receive 100 fills window exactly → 200 OK"
$r = Receive $strict.ItemId $strict.Hour 100
if ($r.newReceivedQty -ne 200) { Fail "Expected newReceivedQty=200, got $($r.newReceivedQty)" }
OK "Receive 100 → newReceivedQty=200 (cap reached)"

# ----------------------------------------------------------------------------
# 4. Strict pull — receive 1 on a full window, UNTICKED → 400 (rev 11)
#    Outstanding is 0, so 1 is an over-receipt and needs the tick like any other.
# ----------------------------------------------------------------------------
Step "Strict pull at 200/200, receive 1 UNTICKED → 400 OVER_RECEIPT_NOT_ACCEPTED"
$body = @{
    pullItemId = $strict.ItemId; hourOfDay = $strict.Hour; qty = 1;
    lotBatch = $null; palletId = $null; binLocation = $null;
    qcStatus = 'pending'; note = $null; varianceAccepted = $false
} | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/receipts" $body $sv 400
if (-not $r -or $r.Wrong) { Fail "Expected 400 on full window, got $($r.Status)" }
if ($r.Title -notmatch 'exceeds the 0 pcs outstanding') { Fail "Title wrong: $($r.Title)" }
OK "400 — a full window is just outstanding 0; the tick is what opens it"

# ----------------------------------------------------------------------------
# 5. Preview WITH ?hour= on the full window → 400, matching Receive exactly.
#    The status changed with the rule (was 409); the point of the case has not:
#    preview and confirm must give the same answer to the same question.
# ----------------------------------------------------------------------------
Step "GET /preview?pullItemId=&qty=50&hour=14 on full window → 400 (same as Receive)"
$r = InvokeExpectFail 'GET' "$base/api/receipts/preview?pullItemId=$($strict.ItemId)&qty=50&hour=14" $null $sv 400
if (-not $r -or $r.Wrong) { Fail "Preview expected 400, got $($r.Status)" }
if ($r.Code -ne 'OVER_RECEIPT_NOT_ACCEPTED') { Fail "Preview code wrong: $($r.Code)" }
OK "Preview refuses with the same status and code Receive gives"

# ----------------------------------------------------------------------------
# 6. Preview WITHOUT ?hour= → 200 (back-compat path skips the check)
# ----------------------------------------------------------------------------
Step "GET /preview WITHOUT hour on full window → 200 (back-compat)"
$preview = Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$($strict.ItemId)&qty=50" -Method GET -WebSession $sv
if (-not $preview.allocations) { Fail "Preview returned no allocations" }
OK "Preview returns allocations when hour omitted (skip cap check)"

# ----------------------------------------------------------------------------
# 7a. Loose pull (LockHourCap=false) — over-receipt UNTICKED → 400
# ----------------------------------------------------------------------------
Step "Loose pull, receive 500 on 200-cap window UNTICKED → 400 OVER_RECEIPT_NOT_ACCEPTED"
$loose = NewSmokePullWithItem $false 'LOOSE-A'
$body = @{
    pullItemId = $loose.ItemId; hourOfDay = $loose.Hour; qty = 500;
    lotBatch = $null; palletId = $null; binLocation = $null;
    qcStatus = 'pending'; note = $null; varianceAccepted = $false
} | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/receipts" $body $sv 400
if (-not $r -or $r.Wrong) { Fail "Expected 400 on unticked loose over-receipt, got $($r.Status)" }
if ($r.Title -notmatch 'exceeds the 200 pcs outstanding') { Fail "Title wrong: $($r.Title)" }
OK "400 — an over-receipt needs the tick even when the hour cap is off"

# ----------------------------------------------------------------------------
# 7b. Loose pull — over-receipt TICKED + note → 200, line closed, +VarianceQty
# ----------------------------------------------------------------------------
Step "Loose pull, receive 500 on 200-cap window TICKED → 200, line closed, VarianceQty=+300"
$r = Receive $loose.ItemId $loose.Hour 500 $true 'over-delivery accepted by smoke'
if ($r.newReceivedQty -ne 500) { Fail "Expected newReceivedQty=500, got $($r.newReceivedQty)" }
if ($r.varianceQty -ne 300)    { Fail "Expected varianceQty=+300 (500 entered vs 200 outstanding), got $($r.varianceQty)" }
if ($r.isClosed -ne $true)     { Fail "Expected isClosed=true after an accepted over-receipt, got $($r.isClosed)" }
if ($r.newOutstanding -ne 0)   { Fail "Expected newOutstanding=0 (never negative), got $($r.newOutstanding)" }
$dbClosed = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(IsClosed AS int) FROM dbo.PullItemWindows WHERE PullItemId='$($loose.ItemId)' AND HourOfDay=$($loose.Hour);" 2>&1).Trim()
if ($dbClosed -ne '1') { Fail "PullItemWindows.IsClosed is '$dbClosed', expected 1" }
OK "Over-receipt recorded at the entered figure, line closed, outstanding floored at 0"

# ----------------------------------------------------------------------------
# 8. Legacy over-state on strict pull — SQL poke ReceivedQty=300, receive 1 → 409
# ----------------------------------------------------------------------------
Step "Strict pull with SQL-poked over-state (300/200), receive 1 UNTICKED → 400"
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
    qcStatus = 'pending'; note = $null; varianceAccepted = $false
} | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/receipts" $body $sv 400
if (-not $r -or $r.Wrong) { Fail "Legacy over-state expected 400, got $($r.Status)" }
# MAX(0, 200-300) = 0 — an over-received window reports outstanding 0, never a
# negative figure (§5). So 1 is an over-receipt and needs the tick.
if ($r.Title -notmatch 'exceeds the 0 pcs outstanding') { Fail "Title wrong: $($r.Title)" }
OK "Legacy-over window reports outstanding 0 and still requires the tick"

SqlCleanup
Write-Host ""
Write-Host "ALL PASS — Hour Cap Phase 6.2 backend enforcement wired into Preview + Receive." -ForegroundColor Green
exit 0
