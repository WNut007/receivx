# Smoke: §7.4 close + §7.5 reopen — full happy path + gate + permission rules.
# Test target: PL-2843 in WH-03 (1 outstanding window: 600 pcs @ hour 12).

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH03 = '22222222-2222-2222-2222-000000000003'
$PullId_2843 = '33333333-3333-3333-3333-000000002843'
$PullItem_2843 = '44444444-4444-4444-2843-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}
function ExpectStatus([int]$expected, [scriptblock]$block) {
    try { & $block | Out-Null } catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -ne $expected) { Fail "Expected $expected, got $sc" }
        return
    }
    Fail "Expected $expected, got success"
}

# ---- 0. Reset PL-2843 to a known starting state (no receipts, status whatever) ----
Step "Reset PL-2843 in DB so the test is repeatable"
# -I enables QUOTED_IDENTIFIER, required because the Receipts table touches
# filtered indexes (which require it for DELETE).
$resetSql = @"
SET QUOTED_IDENTIFIER ON;
DELETE r FROM dbo.Receipts r INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId WHERE pi.PullId = '$PullId_2843';
UPDATE dbo.PullItemWindows SET ReceivedQty = 0 WHERE PullItemId IN (SELECT Id FROM dbo.PullItems WHERE PullId = '$PullId_2843');
UPDATE dbo.Pulls SET Status = 'pending', ClosedAt = NULL, ClosedBy = NULL, SignatureSvg = NULL, ReopenedAt = NULL, ReopenedBy = NULL, ReopenReason = NULL, FirstReceiptAt = NULL, LastActivityAt = NULL WHERE Id = '$PullId_2843';
DELETE FROM dbo.AuditLog WHERE EntityType = 'Pull' AND EntityId = '$PullId_2843';
"@
$resetOut = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -b -Q $resetSql 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host $resetOut -ForegroundColor Red; Fail "Reset SQL failed" }
$check = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT Status FROM dbo.Pulls WHERE Id='$PullId_2843';"
if ($check.Trim() -ne 'pending') { Fail "Reset didn't take effect, status=$($check.Trim())" }
OK "PL-2843 reset (status=pending)"

# ---- 1. Login as sadmin (admin override) ----
$sess = Login 'sadmin' 'admin' $WH03
OK "Login sadmin / WH-03"

# ---- 2. Close on incomplete pull → 409 ----
Step "POST /api/pulls/{id}/close before fully received → 409"
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/pulls/$PullId_2843/close" -Method POST -Body (@{ signatureSvg='data:image/png;base64,AAAA' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess -ErrorAction Stop }
OK "Refuses when outstanding > 0"

# ---- 3. Fully receive the 600-pc window ----
Step "Receive 600 pcs to make PL-2843 fully received"
$body = @{ pullItemId=$PullItem_2843; hourOfDay=12; qty=600 } | ConvertTo-Json
$r = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -Body $body -ContentType 'application/json' -WebSession $sess
if ($r.newReceivedQty -ne 600) { Fail "newReceivedQty=$($r.newReceivedQty)" }
$origReceiptId = $r.allocations[0].receiptId   # v2: receive returns allocations[]
OK "Receipt $origReceiptId, pull is now fully received"

# ---- 4. Close with empty signature → 409 ----
Step "POST close with empty signature → 409"
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/pulls/$PullId_2843/close" -Method POST -Body (@{ signatureSvg='' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess -ErrorAction Stop }
OK "Refuses empty signature"

# ---- 5. Close with oversize signature → 413 ----
Step "POST close with 250 KB signature → 413"
$bigSig = 'data:image/png;base64,' + ('A' * (250 * 1024))
ExpectStatus 413 { Invoke-WebRequest -Uri "$base/api/pulls/$PullId_2843/close" -Method POST -Body (@{ signatureSvg=$bigSig } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess -ErrorAction Stop }
OK "Refuses oversize signature"

# ---- 6. Close with valid signature → 200 ----
Step "POST close with valid signature → 200"
$sig = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII='
$resp = Invoke-RestMethod -Uri "$base/api/pulls/$PullId_2843/close" -Method POST -Body (@{ signatureSvg=$sig } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess
if (-not $resp.closedAt) { Fail "No closedAt returned" }
if ($resp.totalReceived -ne 600) { Fail "totalReceived=$($resp.totalReceived), expected 600" }
$closedAt = $resp.closedAt
OK "Closed; totalReceived=600, closedAt=$closedAt"

# ---- 7. Verify DB state ----
Step "DB state: Status=closed, ClosedAt, ClosedBy, SignatureSvg set"
$row = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT Status + '|' + ISNULL(CAST(ClosedBy AS varchar(36)),'') + '|' + CAST(LEN(SignatureSvg) AS varchar(10)) FROM dbo.Pulls WHERE Id='$PullId_2843';"
$parts = $row.Trim().Split('|')
if ($parts[0] -ne 'closed') { Fail "Status=$($parts[0])" }
if ([string]::IsNullOrEmpty($parts[1])) { Fail "ClosedBy null" }
if ([int]$parts[2] -lt 10) { Fail "SignatureSvg suspiciously short: $($parts[2]) chars" }
OK "DB shows Status=closed, ClosedBy set, signature stored ($($parts[2]) chars)"

# ---- 8. Close again → 409 ----
Step "POST close on already-closed pull → 409"
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/pulls/$PullId_2843/close" -Method POST -Body (@{ signatureSvg=$sig } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess -ErrorAction Stop }
OK "Re-close refused"

# ---- 9. Receive against closed pull → 409 (covered already, but quick re-check) ----
Step "Receive against closed pull → 409"
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body (@{ pullItemId=$PullItem_2843; hourOfDay=12; qty=1 } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess -ErrorAction Stop }
OK "Receive on closed pull refused"

# ---- 10. Reopen by an operator → 403 ----
Step "Login npatcharin (operator in WH-03) and try reopen → 403"
$sess_op = Login 'npatcharin' 'demo1234' $WH03
ExpectStatus 403 { Invoke-WebRequest -Uri "$base/api/pulls/$PullId_2843/reopen" -Method POST -Body (@{ reason='whatever' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess_op -ErrorAction Stop }
OK "Operator blocked from reopen"

# ---- 11. Reopen without reason → 409 ----
Step "Reopen with empty reason (as sadmin) → 409"
ExpectStatus 409 { Invoke-WebRequest -Uri "$base/api/pulls/$PullId_2843/reopen" -Method POST -Body (@{ reason='   ' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess -ErrorAction Stop }
OK "Reopen demands a reason"

# ---- 12. Reopen with reason → 200, status=in_progress, preserves close fields ----
Step "Reopen with reason → 200; ClosedAt/ClosedBy/SignatureSvg PRESERVED"
$reopenResp = Invoke-RestMethod -Uri "$base/api/pulls/$PullId_2843/reopen" -Method POST -Body (@{ reason='QC found a mismatch; needs another pass' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess
if (-not $reopenResp.reopenedAt) { Fail "No reopenedAt returned" }
$row2 = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT Status + '|' + ISNULL(CAST(ClosedBy AS varchar(36)),'') + '|' + CAST(LEN(ISNULL(SignatureSvg,'')) AS varchar(10)) + '|' + ISNULL(CAST(ReopenedBy AS varchar(36)),'') + '|' + ISNULL(ReopenReason,'') FROM dbo.Pulls WHERE Id='$PullId_2843';"
$p2 = $row2.Trim().Split('|')
if ($p2[0] -ne 'in_progress') { Fail "Status=$($p2[0]), expected in_progress" }
if ([string]::IsNullOrEmpty($p2[1])) { Fail "ClosedBy was cleared (must be preserved)" }
if ([int]$p2[2] -lt 10) { Fail "SignatureSvg was cleared (must be preserved)" }
if ([string]::IsNullOrEmpty($p2[3])) { Fail "ReopenedBy not set" }
if ($p2[4] -notmatch 'QC found a mismatch') { Fail "ReopenReason not stored, got: $($p2[4])" }
OK "in_progress; close history preserved; reopen fields set"

# ---- 13. After reopen, can receive again ----
Step "Reverse the 600-pc receipt → drops total to 0"
$c = Invoke-RestMethod -Uri "$base/api/receipts/$origReceiptId/cancel" -Method POST -Body (@{ reason='miscount'; note='smoke teardown' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sess
if ($c.newReceivedQty -ne 0) { Fail "Post-reopen cancel: newReceivedQty=$($c.newReceivedQty)" }
OK "Can receive/cancel on reopened pull; newReceivedQty=0"

# ---- 14. Audit rows exist for close + reopen ----
Step "AuditLog: close + reopen rows present"
$auditRows = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT TOP 5 ActionType + '|' + ISNULL(Message,'') FROM dbo.AuditLog WHERE EntityType='Pull' AND EntityId='$PullId_2843' ORDER BY OccurredAt DESC;"
$audit = ($auditRows -join "`n")
if ($audit -notmatch '(?i)reopen') { Fail "No 'reopen' audit row. Got:`n$audit" }
if ($audit -notmatch '(?i)close')  { Fail "No 'close' audit row. Got:`n$audit"  }
OK "Audit rows present"

Write-Host "`nClose + Reopen smoke passed." -ForegroundColor Green
