# Smoke: Phase 8.5 — My Exports page + /api/exports/jobs.
#
# Covers the log-write pipeline end-to-end:
#   1. POST /api/exports/transactions writes a queued row to
#      dbo.ExportJobsLog with the requester's userId
#   2. After Hangfire runs the job, the row flips to Status=succeeded
#      + FileName + RowsExported are populated
#   3. GET /api/exports/jobs (per-user) returns the new row with
#      downloadUrl, EffectiveStatus='succeeded'
#   4. Admin's ?all=true variant includes RequesterEmail / RequesterName
#   5. Non-admin's ?all=true is rejected silently (returns only their own)
#   6. /Exports page renders with the DOM hooks the JS needs

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
# 1. POST enqueues + writes log row at Status='queued'
# ----------------------------------------------------------------------------
Step "POST /api/exports/transactions writes ExportJobsLog row + Hangfire runs it"
$body = @{ kind = 'receive'; maxRows = 100 } | ConvertTo-Json
$enq = Invoke-RestMethod -Uri "$base/api/exports/transactions" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin
$jobId = $enq.jobId
if (-not $jobId) { Fail "Enqueue returned no jobId" }
OK "Enqueued $jobId"

# Wait for worker
Start-Sleep -Seconds 6

# ----------------------------------------------------------------------------
# 2. DB row shows Status='succeeded' + FileName + RowsExported
# ----------------------------------------------------------------------------
Step "DB row Status='succeeded' + FileName + RowsExported populated"
$check = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; SELECT Status, FileName, RowsExported FROM dbo.ExportJobsLog WHERE Id = '$jobId';") -join ' '
if ($check -notmatch 'succeeded')                   { Fail "Row not succeeded — got: $check" }
if ($check -notmatch 'transactions-' )              { Fail "FileName not populated — got: $check" }
OK "Log row updated: $check"

# ----------------------------------------------------------------------------
# 3. GET /api/exports/jobs (per-user) returns the row with downloadUrl
# ----------------------------------------------------------------------------
Step "GET /api/exports/jobs returns the row with downloadUrl"
$jobs = Invoke-RestMethod -Uri "$base/api/exports/jobs?page=1&pageSize=10" -WebSession $admin
$ourRow = $jobs.items | Where-Object { $_.id -eq $jobId } | Select-Object -First 1
if (-not $ourRow)                                    { Fail "Our jobId not in /jobs response" }
if ($ourRow.status -ne 'succeeded')                  { Fail "Status not succeeded: $($ourRow.status)" }
if ($ourRow.effectiveStatus -ne 'succeeded')         { Fail "EffectiveStatus not succeeded: $($ourRow.effectiveStatus)" }
if (-not $ourRow.downloadUrl)                        { Fail "downloadUrl missing for succeeded job" }
if ($ourRow.downloadUrl -notmatch 'token=')          { Fail "downloadUrl missing HMAC token: $($ourRow.downloadUrl)" }
if ($ourRow.rowsExported -lt 1)                      { Fail "rowsExported not populated" }
# Requester fields NOT populated on default (per-user) view
if ($ourRow.requesterEmail)                          { Fail "Per-user view should not leak requester fields, got '$($ourRow.requesterEmail)'" }
OK "Per-user view returns row with downloadUrl + no requester leak"

# Confirm the HMAC URL actually downloads
$dl = Invoke-WebRequest -Uri ("$base" + $ourRow.downloadUrl) -WebSession $admin -UseBasicParsing
if ($dl.StatusCode -ne 200) { Fail "Download URL returned $($dl.StatusCode)" }
if ($dl.RawContentLength -lt 1000) { Fail "Download suspiciously small ($($dl.RawContentLength))" }
OK "downloadUrl works ($($dl.RawContentLength) bytes)"

# ----------------------------------------------------------------------------
# 4. Admin ?all=true includes RequesterEmail/Name
# ----------------------------------------------------------------------------
Step "GET /api/exports/jobs?all=true (admin) includes RequesterEmail"
$all = Invoke-RestMethod -Uri "$base/api/exports/jobs?all=true&page=1&pageSize=10" -WebSession $admin
$ourRowAll = $all.items | Where-Object { $_.id -eq $jobId } | Select-Object -First 1
if (-not $ourRowAll)                       { Fail "Our jobId not in ?all=true response" }
if (-not $ourRowAll.requesterEmail)        { Fail "requesterEmail missing in see-all view" }
if (-not $ourRowAll.requesterName)         { Fail "requesterName missing in see-all view" }
OK "See-all view includes requester ($($ourRowAll.requesterEmail))"

# ----------------------------------------------------------------------------
# 5. Non-admin ?all=true falls back to their own only
# ----------------------------------------------------------------------------
Step "GET /api/exports/jobs?all=true (non-admin) only returns their own"
# swattana = supervisor at WH-01 (non-admin) per seed data; same user
# the export-extensions smoke uses for non-admin probes.
$op = Login 'swattana' 'demo1234' $WH_01
# Operator has no exports of their own (yet). Enqueue one so we can verify.
$opEnq = Invoke-RestMethod -Uri "$base/api/exports/transactions" -Method POST -Body $body -ContentType 'application/json' -WebSession $op
$opJobId = $opEnq.jobId
Start-Sleep -Seconds 4
$opAllResp = Invoke-RestMethod -Uri "$base/api/exports/jobs?all=true&page=1&pageSize=50" -WebSession $op
$leak = $opAllResp.items | Where-Object { $_.id -eq $jobId }
if ($leak) { Fail "Operator's ?all=true leaked admin's job — privacy boundary broken" }
$ownRow = $opAllResp.items | Where-Object { $_.id -eq $opJobId } | Select-Object -First 1
if (-not $ownRow) { Fail "Operator should still see their own export" }
OK "Operator ?all=true silently scoped to own exports only (no privacy leak)"

# ----------------------------------------------------------------------------
# 6. /Exports page has the expected DOM hooks
# ----------------------------------------------------------------------------
Step "/Exports page renders with expected DOM hooks"
$page = Invoke-WebRequest -Uri "$base/Exports" -WebSession $admin -UseBasicParsing
foreach ($needle in 'My Exports', 'id="exports-tbody"', 'id="exports-pagination"', 'id="see-all"', 'data-admin-only', 'auto-refresh-banner') {
    if ($page.Content -notmatch [regex]::Escape($needle)) { Fail "/Exports page missing $needle" }
}
OK "/Exports page chrome complete"

Write-Host ""
Write-Host "ALL PASS — Phase 8.5 My Exports list + log-write pipeline." -ForegroundColor Green
exit 0
