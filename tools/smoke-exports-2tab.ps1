# Smoke: Phase 8.4 ext — 2-tab My Exports (Pending / Downloaded).
#
# Verifies:
#   1. tab-counts endpoint shape (pending + downloaded ints)
#   2. New succeeded export lands in Pending tab + bumps tab count
#   3. New succeeded export does NOT appear in Downloaded tab
#   4. POST /mark-downloaded stamps DownloadedAt + 200 response
#   5. Row drifts: Pending count down, Downloaded count up
#   6. List queries reflect the drift (gone from Pending, present in Downloaded)
#   7. ExportJobsLog.DownloadedAt populated in DB (sqlcmd verify)
#   8. Idempotency — second mark-downloaded on the same row returns 404
#   9. Privacy — supervisor cannot mark admin's row (404), tab counts isolated

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
# 1. tab-counts shape — must always return both pending + downloaded as ints
# ----------------------------------------------------------------------------
Step "tab-counts baseline — shape check"
$c0 = Invoke-RestMethod -Uri "$base/api/exports/tab-counts" -WebSession $admin
if ($null -eq $c0.pending -or $null -eq $c0.downloaded) {
    Fail "tab-counts response missing fields. Got: $($c0 | ConvertTo-Json -Compress)"
}
$basePending    = [int]$c0.pending
$baseDownloaded = [int]$c0.downloaded
OK "tab-counts shape OK — pending=$basePending downloaded=$baseDownloaded"

# ----------------------------------------------------------------------------
# 2. Enqueue an export → wait for succeeded → confirm in Pending tab
# ----------------------------------------------------------------------------
Step "Enqueue export — verify it lands in Pending"
$enq = Invoke-RestMethod -Uri "$base/api/exports/transactions" -Method POST `
    -Body (@{ kind='receive'; maxRows=50 } | ConvertTo-Json) `
    -ContentType 'application/json' -WebSession $admin
$jobId = $enq.jobId
if (-not $jobId) { Fail "No jobId returned from enqueue" }
Write-Host "Queued jobId = $jobId"

# Wait for the worker to finish (up to ~20s)
$succeeded = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    $row = Invoke-RestMethod -Uri "$base/api/exports/jobs?pageSize=200" -WebSession $admin
    $match = $row.items | Where-Object { $_.id -eq $jobId } | Select-Object -First 1
    if ($match -and $match.status -eq 'succeeded') { $succeeded = $true; break }
    if ($match -and $match.status -eq 'failed')    { Fail "Job failed: $($match.errorMessage)" }
}
if (-not $succeeded) { Fail "Job did not reach 'succeeded' within 20s" }
OK "Job reached succeeded status"

# Now must be visible in Pending tab
$pending = Invoke-RestMethod -Uri "$base/api/exports/jobs?tab=pending&pageSize=200" -WebSession $admin
$inPending = @($pending.items | Where-Object { $_.id -eq $jobId }).Count
if ($inPending -ne 1) { Fail "New succeeded job not in Pending tab (found $inPending)" }
OK "Job visible in Pending tab"

# Tab count bumped
$c1 = Invoke-RestMethod -Uri "$base/api/exports/tab-counts" -WebSession $admin
if ([int]$c1.pending -le $basePending) {
    Fail "Pending count did not increase: was $basePending, now $($c1.pending)"
}
OK "Pending count bumped: $basePending → $($c1.pending)"

# ----------------------------------------------------------------------------
# 3. Not yet in Downloaded tab
# ----------------------------------------------------------------------------
Step "New job should NOT be in Downloaded tab yet"
$dl = Invoke-RestMethod -Uri "$base/api/exports/jobs?tab=downloaded&pageSize=200" -WebSession $admin
$inDl = @($dl.items | Where-Object { $_.id -eq $jobId }).Count
if ($inDl -ne 0) { Fail "New undownloaded job leaked into Downloaded tab" }
OK "New job correctly absent from Downloaded tab"

# ----------------------------------------------------------------------------
# 4. POST mark-downloaded → 200 with downloadedAt timestamp
# ----------------------------------------------------------------------------
Step "POST mark-downloaded — first call returns 200"
$mark = Invoke-RestMethod -Uri "$base/api/exports/$jobId/mark-downloaded" -Method POST -WebSession $admin
if ($mark.id -ne $jobId) { Fail "mark-downloaded response id mismatch" }
if (-not $mark.downloadedAt) { Fail "mark-downloaded response missing downloadedAt" }
OK "mark-downloaded returned id + downloadedAt"

# ----------------------------------------------------------------------------
# 5. Counts drift — pending--, downloaded++
# ----------------------------------------------------------------------------
Step "tab-counts reflect the drift"
$c2 = Invoke-RestMethod -Uri "$base/api/exports/tab-counts" -WebSession $admin
if ([int]$c2.pending -ne ([int]$c1.pending - 1)) {
    Fail "Pending should decrement by 1: was $($c1.pending), now $($c2.pending)"
}
if ([int]$c2.downloaded -ne ([int]$c1.downloaded + 1)) {
    Fail "Downloaded should increment by 1: was $($c1.downloaded), now $($c2.downloaded)"
}
OK "Counts drifted correctly: pending $($c1.pending) → $($c2.pending), downloaded $($c1.downloaded) → $($c2.downloaded)"

# ----------------------------------------------------------------------------
# 6. List queries reflect the move
# ----------------------------------------------------------------------------
Step "Row moved from Pending to Downloaded in list queries"
$pending2 = Invoke-RestMethod -Uri "$base/api/exports/jobs?tab=pending&pageSize=200" -WebSession $admin
$stillPending = @($pending2.items | Where-Object { $_.id -eq $jobId }).Count
if ($stillPending -ne 0) { Fail "Job still in Pending after mark-downloaded" }

$dl2 = Invoke-RestMethod -Uri "$base/api/exports/jobs?tab=downloaded&pageSize=200" -WebSession $admin
$nowDl = $dl2.items | Where-Object { $_.id -eq $jobId } | Select-Object -First 1
if (-not $nowDl) { Fail "Job not in Downloaded tab after mark-downloaded" }
if (-not $nowDl.downloadedAt) { Fail "Job's downloadedAt not returned in Downloaded list" }
OK "Row moved Pending → Downloaded in list queries"

# ----------------------------------------------------------------------------
# 7. DB-level verification — DownloadedAt populated
# ----------------------------------------------------------------------------
Step "DB row's DownloadedAt is populated"
$dlAt = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(30), DownloadedAt, 121) FROM dbo.ExportJobsLog WHERE Id = '$jobId';") -join ''
$dlAt = $dlAt.Trim()
if (-not $dlAt -or $dlAt -eq 'NULL') { Fail "DownloadedAt should be populated, got: '$dlAt'" }
OK "DB DownloadedAt = $dlAt"

# ----------------------------------------------------------------------------
# 8. Idempotency — second mark-downloaded returns 404
# ----------------------------------------------------------------------------
Step "Second mark-downloaded on same row returns 404 (idempotent)"
$status = 0
try {
    Invoke-WebRequest -Uri "$base/api/exports/$jobId/mark-downloaded" -Method POST -WebSession $admin -ErrorAction Stop | Out-Null
    Fail "Expected 404 on double-mark, got success"
}
catch {
    $status = [int]$_.Exception.Response.StatusCode.value__
}
if ($status -ne 404) { Fail "Expected 404, got $status" }
OK "Second mark returned 404 — idempotent"

# ----------------------------------------------------------------------------
# 9. Privacy — supervisor can't mark admin's row
# ----------------------------------------------------------------------------
Step "Privacy — supervisor cannot mark admin's export"

# Need a fresh undownloaded admin row to target (the one above is already marked).
$enq2 = Invoke-RestMethod -Uri "$base/api/exports/transactions" -Method POST `
    -Body (@{ kind='receive'; maxRows=50 } | ConvertTo-Json) `
    -ContentType 'application/json' -WebSession $admin
$jobId2 = $enq2.jobId

# Wait for succeeded
$succeeded2 = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    $row = Invoke-RestMethod -Uri "$base/api/exports/jobs?pageSize=200" -WebSession $admin
    $match = $row.items | Where-Object { $_.id -eq $jobId2 } | Select-Object -First 1
    if ($match -and $match.status -eq 'succeeded') { $succeeded2 = $true; break }
}
if (-not $succeeded2) { Fail "Second job did not reach 'succeeded' within 20s" }

$sup = Login 'swattana' 'demo1234' $WH_01

# Supervisor attempts to mark admin's row → 404
$privStatus = 0
try {
    Invoke-WebRequest -Uri "$base/api/exports/$jobId2/mark-downloaded" -Method POST -WebSession $sup -ErrorAction Stop | Out-Null
    Fail "Expected 404 on cross-user mark, got success"
}
catch {
    $privStatus = [int]$_.Exception.Response.StatusCode.value__
}
if ($privStatus -ne 404) { Fail "Cross-user mark should be 404, got $privStatus" }
OK "Cross-user mark blocked (404) — privacy guard works"

# Confirm admin's row was NOT touched — DownloadedAt still NULL in DB
$stillNull = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; SELECT ISNULL(CONVERT(VARCHAR(30), DownloadedAt, 121), 'NULL') FROM dbo.ExportJobsLog WHERE Id = '$jobId2';") -join ''
$stillNull = $stillNull.Trim()
if ($stillNull -ne 'NULL') { Fail "Admin's row was touched by supervisor: DownloadedAt = '$stillNull'" }
OK "Admin's row untouched: DownloadedAt remains NULL"

# Supervisor's own tab counts must NOT be inflated by admin's pending rows
$supCounts = Invoke-RestMethod -Uri "$base/api/exports/tab-counts" -WebSession $sup
# Can't assert exact 0 (supervisor may have their own history) but can assert
# the admin's job is not in supervisor's pending list
$supPending = Invoke-RestMethod -Uri "$base/api/exports/jobs?tab=pending&pageSize=200" -WebSession $sup
$leak = @($supPending.items | Where-Object { $_.id -eq $jobId2 }).Count
if ($leak -ne 0) { Fail "Admin's pending job leaked into supervisor's Pending tab" }
OK "Supervisor's Pending tab does not show admin's job"

# Clean up — mark the second job as admin so the smoke is idempotent
Invoke-RestMethod -Uri "$base/api/exports/$jobId2/mark-downloaded" -Method POST -WebSession $admin | Out-Null

Write-Host ""
Write-Host "ALL PASS — exports 2-tab Pending/Downloaded + mark-downloaded + privacy." -ForegroundColor Green
exit 0
