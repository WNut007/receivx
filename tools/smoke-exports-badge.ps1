# Smoke: Phase 8.5+ — unread-exports badge counter.
#
# Verifies:
#   1. Mark all-read on smoke start (clean baseline). Count == 0.
#   2. Enqueue an export; wait for the job to flip to succeeded.
#   3. Count goes to >= 1 (the new succeeded job is unread).
#   4. POST /mark-all-read returns marked >= 1, then count == 0.
#   5. DB row's ReadAt is now populated.
#   6. Privacy: enqueue as user A, then user B's count is unaffected
#      (A's job doesn't leak into B's badge).

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

$admin = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
# 1. Clean baseline — mark all read, then assert 0
# ----------------------------------------------------------------------------
Step "Baseline — mark-all-read sets count to 0"
Invoke-RestMethod -Uri "$base/api/exports/mark-all-read" -Method POST -WebSession $admin | Out-Null
$cBaseline = Invoke-RestMethod -Uri "$base/api/exports/unread-count" -WebSession $admin
if ($cBaseline.count -ne 0) { Fail "Baseline count should be 0, got $($cBaseline.count)" }
OK "Baseline count == 0"

# ----------------------------------------------------------------------------
# 2-3. Enqueue → wait → count >= 1
# ----------------------------------------------------------------------------
Step "Enqueue export → count goes >= 1"
$enq = Invoke-RestMethod -Uri "$base/api/exports/transactions" -Method POST `
    -Body (@{ kind='receive'; maxRows=100 } | ConvertTo-Json) `
    -ContentType 'application/json' -WebSession $admin
$jobId = $enq.jobId
Start-Sleep -Seconds 6
$cAfter = Invoke-RestMethod -Uri "$base/api/exports/unread-count" -WebSession $admin
if ($cAfter.count -lt 1) { Fail "Count should be >= 1 after a succeeded export, got $($cAfter.count)" }
OK "Count after enqueue + run = $($cAfter.count)"

# ----------------------------------------------------------------------------
# 4. mark-all-read returns >= 1, then count back to 0
# ----------------------------------------------------------------------------
Step "mark-all-read clears the badge"
$mark = Invoke-RestMethod -Uri "$base/api/exports/mark-all-read" -Method POST -WebSession $admin
if ($mark.marked -lt 1) { Fail "mark-all-read should affect >= 1 row, got $($mark.marked)" }
$cAfterMark = Invoke-RestMethod -Uri "$base/api/exports/unread-count" -WebSession $admin
if ($cAfterMark.count -ne 0) { Fail "Count should be 0 after mark-read, got $($cAfterMark.count)" }
OK "marked=$($mark.marked), count back to 0"

# ----------------------------------------------------------------------------
# 5. ReadAt populated in DB
# ----------------------------------------------------------------------------
Step "ExportJobsLog row's ReadAt is populated"
$readAt = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(30), ReadAt, 121) FROM dbo.ExportJobsLog WHERE Id = '$jobId';") -join ''
$readAt = $readAt.Trim()
if (-not $readAt -or $readAt -eq 'NULL') { Fail "ReadAt should be populated, got: '$readAt'" }
OK "ReadAt = $readAt"

# ----------------------------------------------------------------------------
# 6. Privacy — supervisor's mark-all-read doesn't affect admin's count
#    and admin's job doesn't leak into supervisor's count
# ----------------------------------------------------------------------------
Step "Privacy — different users have isolated counts"
$sup = Login 'swattana' 'demo1234' $WH_01
# Clean supervisor baseline
Invoke-RestMethod -Uri "$base/api/exports/mark-all-read" -Method POST -WebSession $sup | Out-Null
$supCount0 = Invoke-RestMethod -Uri "$base/api/exports/unread-count" -WebSession $sup
if ($supCount0.count -ne 0) { Fail "Sup baseline should be 0, got $($supCount0.count)" }

# Admin enqueues — sup count should NOT change
Invoke-RestMethod -Uri "$base/api/exports/transactions" -Method POST `
    -Body (@{ kind='receive'; maxRows=100 } | ConvertTo-Json) `
    -ContentType 'application/json' -WebSession $admin | Out-Null
Start-Sleep -Seconds 6
$supCount1 = Invoke-RestMethod -Uri "$base/api/exports/unread-count" -WebSession $sup
if ($supCount1.count -ne 0) { Fail "Admin's export leaked into supervisor's count: $($supCount1.count)" }

# Admin's count went up though
$adminCount1 = Invoke-RestMethod -Uri "$base/api/exports/unread-count" -WebSession $admin
if ($adminCount1.count -lt 1) { Fail "Admin's own count should reflect own enqueue, got $($adminCount1.count)" }
OK "Privacy intact — admin count=$($adminCount1.count), sup count=$($supCount1.count)"

# Clean up so future smoke runs don't see leftover unread for admin
Invoke-RestMethod -Uri "$base/api/exports/mark-all-read" -Method POST -WebSession $admin | Out-Null

Write-Host ""
Write-Host "ALL PASS — exports badge counter + auto-dismiss + privacy." -ForegroundColor Green
exit 0
