# Smoke test: db/049 structured reason code for an accepted variance
#
# Brief: brief-variance-reason-dropdown.md (§6 test cases).
#
# WHAT THIS PROTECTS
# ------------------
# The Receive Goods modal used to require a free-text note whenever accept-variance was
# ticked. On the first real use in production the operator typed "." to satisfy it. That
# is not operator error: over-delivery happens on nearly every pull at this site, so a
# required prose field becomes a required keystroke and the audit trail fills with
# characters that record nothing.
#
# db/049 replaces it with a required CODE from a fixed set, and demotes the note to
# "required only when the code is OTHER". These cases exist to stop the old rule creeping
# back in either direction: a variance that records no reason, or a reason that can be
# satisfied without saying anything.
#
# Separate file rather than more cases in smoke-po-overflow-variance.ps1, which is already
# 836 lines carrying 13 cases of its own.
#
# CASES (§6)
#   0.  The reason endpoint — six codes, labels present and NOT silently translated
#   1.  over + valid over-code + no note        -> 200, code on window, ClosedReason empty
#   2.  over + OTHER + no note                  -> 400, nothing written
#   3.  over + OTHER + "."                      -> 400, nothing written
#   4.  over + OTHER + real note                -> 200, code AND note stored
#   5.  variance with NO code                   -> 400, server-side
#   6.  OVER_DELIVERY on a short close          -> 400, direction
#   7.  SHORT_DELIVERY on an over-receipt       -> 400, direction
#   8.  unknown code "FOO"                      -> 400
#   9.  zero-qty short close + short code       -> 200, NO Receipts row, code stored
#   10. multi-slice over-receipt + code         -> code stored ONCE on the window
#   11. cancel a slice                          -> code cleared with the other Closed* cols
#   12. exact-quantity final receipt            -> no code required, none stored
#   13. legacy window (code NULL)               -> untouched, still renders
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'

$WH_BPI  = 'bb414f53-11d6-4db8-8909-7e251b0823bf'
$PULL_NO = '0000026590'
$ITEM    = '2063-810743-0E4'
$HOUR    = 20
$VENDOR  = 'COI-HSABP1'
$SEED_PO = 'PO-VRC-ANCHOR'
$SQL     = @{ S = 'LAPTOP-CSB3KO3E'; d = 'ReceivingOps' }

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }

# -b so sqlcmd exits non-zero on a failed statement; temp file rather than -Q because
# sqlcmd re-tokenizes -Q and treats a bare "/" as a switch prefix. Both learned the hard
# way in smoke-po-overflow-variance.ps1 — see its header.
function Sql($q) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vrc-{0}.sql" -f [guid]::NewGuid())
    try {
        Set-Content -Path $tmp -Value $q -Encoding UTF8
        $out = sqlcmd -S $SQL.S -E -C -d $SQL.d -I -b -h -1 -W -i $tmp 2>&1
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed: $($out | Out-String)" }
        return $out
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}
function SqlScalar($q) { (Sql $q | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -First 1).Trim() }

function Cleanup {
    $q = @"
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DECLARE @pullItem UNIQUEIDENTIFIER = (
    SELECT pi.Id FROM dbo.PullItems pi
    INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
    WHERE p.PullNumber = '$PULL_NO' AND pi.ItemCode = '$ITEM');

DECLARE @touched TABLE (LineId UNIQUEIDENTIFIER PRIMARY KEY);
INSERT INTO @touched (LineId)
SELECT DISTINCT PurchaseOrderLineId FROM dbo.Receipts
WHERE PullItemId = @pullItem AND PurchaseOrderLineId IS NOT NULL;

UPDATE dbo.Receipts SET ReversedById = NULL WHERE PullItemId = @pullItem;
DELETE FROM dbo.Receipts WHERE PullItemId = @pullItem AND ReversesReceiptId IS NOT NULL;
DELETE FROM dbo.Receipts WHERE PullItemId = @pullItem;

-- Set-from-truth, not decrement: the overflow slice in case 10 lands on a REAL PO line
-- this smoke did not create and must not corrupt (same reasoning as db/038).
UPDATE pol SET ReceivedQty = ISNULL(t.Qty, 0)
FROM dbo.PurchaseOrderLines pol
INNER JOIN @touched tt ON tt.LineId = pol.Id
OUTER APPLY (SELECT SUM(r.QtyReceived) AS Qty FROM dbo.Receipts r
             WHERE r.PurchaseOrderLineId = pol.Id) t;

UPDATE po SET Status = 'open', ClosedAt = NULL
FROM dbo.PurchaseOrders po
WHERE po.Status = 'closed'
  AND EXISTS (SELECT 1 FROM dbo.PurchaseOrderLines pol
              INNER JOIN @touched tt ON tt.LineId = pol.Id
              WHERE pol.PurchaseOrderId = po.Id AND pol.OrderedQty > pol.ReceivedQty);

UPDATE dbo.PullItemWindows
   SET ReceivedQty = 0, IsClosed = 0, ClosedAt = NULL, ClosedBy = NULL,
       ClosedReason = NULL, VarianceReasonCode = NULL
 WHERE PullItemId = @pullItem AND HourOfDay = $HOUR;

UPDATE dbo.Pulls SET Status = 'pending', FirstReceiptAt = NULL
 WHERE PullNumber = '$PULL_NO' AND Status IN ('in_progress','fully_received');

DELETE FROM dbo.PurchaseOrderLines WHERE PurchaseOrderId IN
    (SELECT Id FROM dbo.PurchaseOrders WHERE PoNumber = '$SEED_PO');
DELETE FROM dbo.PurchaseOrders WHERE PoNumber = '$SEED_PO';
"@
    Sql $q | Out-Null
}

# Pull-linked anchor (PullExternalRef = the pull number) so §7.15 lock-by-pull FIFO can
# reach it. $ordered controls whether a case spills into the shared overflow pool.
function SeedAnchorPo($ordered) {
    Sql @"
SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;
DECLARE @po UNIQUEIDENTIFIER = NEWID();
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, OrderDate, Status, PullExternalRef, CreatedBy)
VALUES (@po, '$SEED_PO', '$WH_BPI', CAST(DATEADD(day,-30,SYSUTCDATETIME()) AS DATE), 'open', '$PULL_NO',
        '11111111-1111-1111-1111-000000000001');
INSERT INTO dbo.PurchaseOrderLines
    (PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode, VendorName)
VALUES (@po, 1, '$ITEM', 'VRC anchor line', $ordered, 0, '$VENDOR', 'Western Digital');
"@ | Out-Null
}

function Login {
    $body = @{ username='sadmin'; password='admin'; warehouseId=$WH_BPI; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body `
        -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# $reason = $null means "omit the field entirely", which is what case 5 needs.
function Receive($session, $pullItemId, $qty, $variance, $note, $reason) {
    $b = @{ pullItemId=$pullItemId; hourOfDay=$HOUR; qty=$qty; varianceAccepted=$variance }
    if ($null -ne $note)   { $b.note = $note }
    if ($null -ne $reason) { $b.varianceReasonCode = $reason }
    Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body ($b | ConvertTo-Json) `
        -ContentType 'application/json' -WebSession $session
}

function ReceiveExpect400($session, $pullItemId, $qty, $variance, $note, $reason, $label) {
    try {
        Receive $session $pullItemId $qty $variance $note $reason | Out-Null
        Fail "$label — expected 400, request SUCCEEDED"
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        $status = [int]$resp.StatusCode
        $code = $null; $title = $null
        if ($_.ErrorDetails.Message) {
            try { $pd = $_.ErrorDetails.Message | ConvertFrom-Json; $title = $pd.title; $code = $pd.code }
            catch { $title = $_.ErrorDetails.Message }
        }
        if ($status -ne 400) { Fail "$label — expected 400, got $status ($title)" }
        return [pscustomobject]@{ Status=$status; Code=$code; Title=$title }
    }
}

function Win($pi) {
    $r = Sql @"
SET NOCOUNT ON;
SELECT CAST(ReceivedQty AS VARCHAR)+'|'+CAST(IsClosed AS VARCHAR)+'|'
     + ISNULL(VarianceReasonCode,'<NULL>')+'|'+ISNULL(ClosedReason,'<NULL>')+'|'
     + CASE WHEN ClosedBy IS NULL THEN 'NULL' ELSE 'set' END+'|'
     + CASE WHEN ClosedAt IS NULL THEN 'NULL' ELSE 'set' END
FROM dbo.PullItemWindows WHERE PullItemId='$pi' AND HourOfDay=$HOUR;
"@
    $p = ($r | Where-Object { $_ -match '\|' } | Select-Object -First 1).Trim() -split '\|'
    return [pscustomobject]@{ Received=[int]$p[0]; IsClosed=($p[1] -eq '1'); Code=$p[2]
                              ClosedReason=$p[3]; ClosedBy=$p[4]; ClosedAt=$p[5] }
}

function ReceiptCount($pi) {
    [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Receipts WHERE PullItemId='$pi';")
}

function AssertNothingWritten($pi, $label) {
    $n = ReceiptCount $pi
    if ($n -ne 0) { Fail "$label — expected 0 receipt rows, got $n" }
    $w = Win $pi
    if ($w.IsClosed)          { Fail "$label — window must not be closed" }
    if ($w.Code -ne '<NULL>') { Fail "$label — window must carry no reason code, got '$($w.Code)'" }
}

# ===========================================================================
Cleanup
$sv = Login
$pi = SqlScalar @"
SET NOCOUNT ON;
SELECT pi.Id FROM dbo.PullItems pi
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber='$PULL_NO' AND pi.ItemCode='$ITEM';
"@
if (-not $pi) { Write-Host "FAIL: pull $PULL_NO / item $ITEM not present in this database." -ForegroundColor Red; exit 1 }
Write-Host "PullItemId = $pi" -ForegroundColor DarkGray

$expected = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(ExpectedQty AS VARCHAR) FROM dbo.PullItemWindows WHERE PullItemId='$pi' AND HourOfDay=$HOUR;")
if ($expected -ne 400) { Fail "fixture drift: window ExpectedQty is $expected, these cases assume 400" }

# ---------------------------------------------------------------------------
Step '0. GET /api/receipts/variance-reasons — the one map, served to the client'
$reasons = Invoke-RestMethod -Uri "$base/api/receipts/variance-reasons" -WebSession $sv
if ($reasons.Count -ne 6) { Fail "expected 6 reason codes, got $($reasons.Count)" }
$codes = ($reasons | ForEach-Object { $_.code }) -join ','
$want  = 'OVER_DELIVERY,SHORT_DELIVERY,COUNT_MISMATCH,DAMAGED_PARTIAL_RETURN,PO_SPLIT_MISMATCH,OTHER'
if ($codes -ne $want) { Fail "code set/order drift.`n  expected: $want`n  got:      $codes" }

# Labels must be non-empty AND non-ASCII. Asserting the exact Thai strings would make this
# smoke a hostage to file encoding; asserting non-ASCII catches the failure that actually
# matters — someone quietly translating them to English, which is the thing the brief
# forbids and which would put the dropdown back into a language the operators skim.
foreach ($r in $reasons) {
    if ([string]::IsNullOrWhiteSpace($r.label)) { Fail "code $($r.code) has no label" }
    if ($r.label -match '^[\x00-\x7F]+$')       { Fail "code $($r.code) label '$($r.label)' is pure ASCII — labels must stay Thai" }
}
# Direction flags drive the client filter; a wrong flag silently offers the wrong reason.
$over  = ($reasons | Where-Object { $_.validOver }  | ForEach-Object { $_.code }) -join ','
$short = ($reasons | Where-Object { $_.validShort } | ForEach-Object { $_.code }) -join ','
if ($over  -ne 'OVER_DELIVERY,COUNT_MISMATCH,PO_SPLIT_MISMATCH,OTHER')          { Fail "over-direction set wrong: $over" }
if ($short -ne 'SHORT_DELIVERY,COUNT_MISMATCH,DAMAGED_PARTIAL_RETURN,PO_SPLIT_MISMATCH,OTHER') { Fail "short-direction set wrong: $short" }
OK "6 codes in order, all labels non-ASCII, direction flags correct"

# ---------------------------------------------------------------------------
Step '1. Over-receipt + valid over-code + NO note -> succeeds, code stored, no free text'
Cleanup; SeedAnchorPo 500
Receive $sv $pi 420 $true $null 'OVER_DELIVERY' | Out-Null
$w1 = Win $pi
if (-not $w1.IsClosed)               { Fail "window should be closed" }
if ($w1.Code -ne 'OVER_DELIVERY')    { Fail "expected OVER_DELIVERY on the window, got '$($w1.Code)'" }
if ($w1.ClosedReason -ne '<NULL>')   { Fail "no note was sent, so ClosedReason should be NULL, got '$($w1.ClosedReason)'" }
if ($w1.ClosedBy -ne 'set' -or $w1.ClosedAt -ne 'set') { Fail "ClosedBy/ClosedAt should both be set" }
OK "420 of 400 accepted with a code and no prose — the '.' is no longer needed"

# ---------------------------------------------------------------------------
Step '2. Over-receipt + OTHER + no note -> 400, nothing written'
Cleanup; SeedAnchorPo 500
$e2 = ReceiveExpect400 $sv $pi 420 $true $null 'OTHER' 'case 2'
if ($e2.Code -ne 'VARIANCE_NOTE_REQUIRED') { Fail "expected VARIANCE_NOTE_REQUIRED, got '$($e2.Code)'" }
AssertNothingWritten $pi 'case 2'
OK "OTHER without a note refused ($($e2.Code)), zero rows"

# ---------------------------------------------------------------------------
Step '3. Over-receipt + OTHER + "." -> 400, nothing written'
# The exact production input this change exists to eliminate.
Cleanup; SeedAnchorPo 500
$e3 = ReceiveExpect400 $sv $pi 420 $true '.' 'OTHER' 'case 3'
if ($e3.Code -ne 'VARIANCE_NOTE_REQUIRED') { Fail "expected VARIANCE_NOTE_REQUIRED, got '$($e3.Code)'" }
AssertNothingWritten $pi 'case 3'
OK "the literal '.' is refused — the defect that prompted this brief cannot recur"

# ---------------------------------------------------------------------------
Step '4. Over-receipt + OTHER + a real note -> succeeds, both stored'
Cleanup; SeedAnchorPo 500
$note4 = 'Vendor combined two shipments into one pallet'
Receive $sv $pi 420 $true $note4 'OTHER' | Out-Null
$w4 = Win $pi
if ($w4.Code -ne 'OTHER')           { Fail "expected OTHER on the window, got '$($w4.Code)'" }
if ($w4.ClosedReason -ne $note4)    { Fail "note not stored verbatim, got '$($w4.ClosedReason)'" }
OK "OTHER + real note: code and free text both stored, note verbatim"

# ---------------------------------------------------------------------------
Step '5. Variance accepted with NO code at all -> 400 server-side'
# The request is otherwise well-formed; only the server can refuse it, since a crafted
# call never passes through the modal's Confirm gate.
Cleanup; SeedAnchorPo 500
$e5 = ReceiveExpect400 $sv $pi 420 $true 'a perfectly good note' $null 'case 5'
if ($e5.Code -ne 'VARIANCE_REASON_REQUIRED') { Fail "expected VARIANCE_REASON_REQUIRED, got '$($e5.Code)'" }
AssertNothingWritten $pi 'case 5'
OK "a note alone no longer satisfies the audit requirement ($($e5.Code))"

# ---------------------------------------------------------------------------
Step '6. OVER_DELIVERY on a SHORT close -> 400 direction'
Cleanup; SeedAnchorPo 500
$e6 = ReceiveExpect400 $sv $pi 300 $true $null 'OVER_DELIVERY' 'case 6'
if ($e6.Code -ne 'VARIANCE_REASON_WRONG_DIRECTION') { Fail "expected VARIANCE_REASON_WRONG_DIRECTION, got '$($e6.Code)'" }
AssertNothingWritten $pi 'case 6'
OK "over-code on a short close refused ($($e6.Code))"

# ---------------------------------------------------------------------------
Step '7. SHORT_DELIVERY on an OVER-receipt -> 400 direction'
Cleanup; SeedAnchorPo 500
$e7 = ReceiveExpect400 $sv $pi 420 $true $null 'SHORT_DELIVERY' 'case 7'
if ($e7.Code -ne 'VARIANCE_REASON_WRONG_DIRECTION') { Fail "expected VARIANCE_REASON_WRONG_DIRECTION, got '$($e7.Code)'" }
AssertNothingWritten $pi 'case 7'
OK "short-code on an over-receipt refused ($($e7.Code))"

# ---------------------------------------------------------------------------
Step '8. Unknown code -> 400'
Cleanup; SeedAnchorPo 500
$e8 = ReceiveExpect400 $sv $pi 420 $true $null 'FOO' 'case 8'
if ($e8.Code -ne 'VARIANCE_REASON_UNKNOWN') { Fail "expected VARIANCE_REASON_UNKNOWN, got '$($e8.Code)'" }
AssertNothingWritten $pi 'case 8'
OK "unknown code refused ($($e8.Code)) — the set is closed even without a CHECK constraint"

# ---------------------------------------------------------------------------
Step '9. Zero-quantity short close + short code -> succeeds, NO Receipts row, code stored'
# §2d holds: a zero close writes no ledger row, so the window Closed* columns (now
# including the code) are the ONLY record of it.
Cleanup; SeedAnchorPo 500
Receive $sv $pi 0 $true $null 'DAMAGED_PARTIAL_RETURN' | Out-Null
$w9 = Win $pi
if (-not $w9.IsClosed)                       { Fail "zero close should close the window" }
if ($w9.Code -ne 'DAMAGED_PARTIAL_RETURN')   { Fail "expected DAMAGED_PARTIAL_RETURN, got '$($w9.Code)'" }
if ($w9.Received -ne 0)                      { Fail "ReceivedQty must stay 0, got $($w9.Received)" }
$n9 = ReceiptCount $pi
if ($n9 -ne 0) { Fail "§2d violated: zero close wrote $n9 Receipts row(s)" }
OK "zero close: no ledger row, code is the sole structured record"

# ---------------------------------------------------------------------------
Step '10. Multi-slice over-receipt + code -> code stored ONCE on the window'
# 401 against a 400 anchor spills onto the shared vendor pool -> two receipt rows. The
# code is window-grain, so it must appear once regardless of how many rows the FIFO walk
# wrote. This is exactly the duplication that made a receipt-grain column the wrong shape.
Cleanup; SeedAnchorPo 400
$r10 = Receive $sv $pi 401 $true $null 'COUNT_MISMATCH'
if ($r10.allocations.Count -ne 2) { Fail "expected 2 slices, got $($r10.allocations.Count)" }
$w10 = Win $pi
if ($w10.Code -ne 'COUNT_MISMATCH') { Fail "expected COUNT_MISMATCH on the window, got '$($w10.Code)'" }
if ($w10.Received -ne 401)          { Fail "window should be 401, got $($w10.Received)" }
$codeRows = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PullItemWindows
WHERE PullItemId='$pi' AND VarianceReasonCode IS NOT NULL;
"@
if ($codeRows -ne '1') { Fail "the code should exist on exactly 1 window row, got $codeRows" }
OK "2 receipt rows, 1 window, 1 code — no per-slice duplication to orphan later"

# ---------------------------------------------------------------------------
Step '11. Cancel a slice -> code cleared alongside ClosedBy/ClosedAt/ClosedReason'
# §4.4. A reopened window carrying a stale code is the same defect class as the orphaned
# VarianceQty fixed in 7c15ef9: the window would still claim a decision that no longer
# holds. Cancelling the OVERFLOW slice (not the carrier) is the harder direction.
$slice2 = $r10.allocations | Where-Object { $_.isPullLinked -eq $false } | Select-Object -First 1
if (-not $slice2) { Fail "case 11 precondition: no overflow slice to cancel" }
Invoke-RestMethod -Uri "$base/api/receipts/$($slice2.receiptId)/cancel" -Method POST `
    -Body (@{ reason='miscount'; note='smoke: reverse overflow slice' } | ConvertTo-Json) `
    -ContentType 'application/json' -WebSession $sv | Out-Null

$w11 = Win $pi
if ($w11.IsClosed)                 { Fail "window should have reopened" }
if ($w11.Code -ne '<NULL>')        { Fail "VarianceReasonCode should be cleared, got '$($w11.Code)'" }
if ($w11.ClosedReason -ne '<NULL>'){ Fail "ClosedReason should be cleared, got '$($w11.ClosedReason)'" }
if ($w11.ClosedBy -ne 'NULL')      { Fail "ClosedBy should be cleared" }
if ($w11.ClosedAt -ne 'NULL')      { Fail "ClosedAt should be cleared" }
OK "reopened window carries no residue — all five close columns cleared together"

# ---------------------------------------------------------------------------
Step '12. Exact-quantity final receipt -> not a variance, no code required or stored'
# §4.1. The tick is ignored when the quantity lands exactly on outstanding, so demanding
# a reason here would be asking the operator to explain a delivery that was correct.
Cleanup; SeedAnchorPo 500
Receive $sv $pi 400 $true $null $null | Out-Null
$w12 = Win $pi
if ($w12.Received -ne 400)   { Fail "window should be 400, got $($w12.Received)" }
if ($w12.Code -ne '<NULL>')  { Fail "an exact receipt must store no reason code, got '$($w12.Code)'" }
OK "exact 400 of 400 succeeded with no code — a correct delivery is not a variance"

# ---------------------------------------------------------------------------
Step '13. Legacy window (closed before db/049) -> NULL code, untouched, still renders'
# Simulates the real production state: rows closed by the shipped build, which had no
# reason code. NULL must mean "closed before reason codes existed" and must never be
# dressed up as OTHER — that would attribute a decision to an operator who never made one.
Cleanup; SeedAnchorPo 500
Receive $sv $pi 420 $true 'legacy close' 'OVER_DELIVERY' | Out-Null
Sql "SET NOCOUNT ON; UPDATE dbo.PullItemWindows SET VarianceReasonCode = NULL WHERE PullItemId='$pi' AND HourOfDay=$HOUR;" | Out-Null

$wLegacy = Win $pi
if (-not $wLegacy.IsClosed)              { Fail "legacy window should still read closed" }
if ($wLegacy.Code -ne '<NULL>')          { Fail "legacy code should be NULL, got '$($wLegacy.Code)'" }
if ($wLegacy.ClosedReason -ne 'legacy close') { Fail "legacy ClosedReason should survive, got '$($wLegacy.ClosedReason)'" }

# The Receiving view reads this through GET /api/pulls/{id}: both new fields must come
# back null WITHOUT the window disappearing or the request failing.
$pullId = SqlScalar "SET NOCOUNT ON; SELECT CAST(Id AS VARCHAR(36)) FROM dbo.Pulls WHERE PullNumber='$PULL_NO';"
$detail = Invoke-RestMethod -Uri "$base/api/pulls/$pullId" -WebSession $sv
$itemD  = $detail.items | Where-Object { $_.itemCode -eq $ITEM } | Select-Object -First 1
if (-not $itemD) { Fail "item $ITEM missing from PullDetail" }
$winD = $itemD.windows | Where-Object { $_.hourOfDay -eq $HOUR } | Select-Object -First 1
if (-not $winD)                            { Fail "hour $HOUR window missing from PullDetail" }
if ($winD.isClosed -ne $true)              { Fail "PullDetail should report the window closed" }
if ($null -ne $winD.varianceReasonCode)    { Fail "varianceReasonCode should be null, got '$($winD.varianceReasonCode)'" }
if ($null -ne $winD.varianceReasonLabel)   { Fail "varianceReasonLabel should be null, got '$($winD.varianceReasonLabel)'" }
if ($winD.closedReason -ne 'legacy close') { Fail "closedReason should survive to the wire, got '$($winD.closedReason)'" }
OK "legacy row renders: closed, note intact, code and label both null — not folded into OTHER"

# ---------------------------------------------------------------------------
Cleanup
Write-Host "`nALL CASES PASSED" -ForegroundColor Green

# ---------------------------------------------------------------------------
# NOT COVERED HERE, deliberately:
#   • The dropdown's DOM behaviour (three note states, direction filtering, the
#     placeholder that cannot be submitted). Those are client-side and this suite has no
#     browser driver; the SERVER refuses every case the UI is meant to prevent, which is
#     what §4.2 makes authoritative. The UI states are listed in the brief and were
#     verified by hand.
#   • Reports/exports grouping by code — explicitly out of scope (§8).
#   • Concurrency on the conditional close. Unchanged by this work; the reason code rides
#     inside the same single UPDATE that already carried IsClosed.
