# Smoke: Phase 8.4 — decoupled export pipeline.
#
# Covers the full flow:
#   1. Hangfire dashboard reachable for admin, blocked for anon
#   2. POST /api/exports/transactions returns a jobId
#   3. Hangfire worker runs the job; XLSX lands at the expected path
#   4. Download endpoint rejects missing/bogus tokens (401)
#   5. Download endpoint streams the file when given a valid token
#      (token issuance happens via a tiny .NET program that runs
#      ExportTokenService.Issue with the same SigningKey the server
#      uses — we read the key from user-secrets / appsettings the
#      same way the server does, then sign locally)
#
# SMTP is intentionally unconfigured in dev: the job's email step falls
# back to a log line. Real SMTP send is exercised manually after the
# user sets the Gmail app password in user-secrets.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$exportRoot = 'C:\dev\receivx\src\ReceivingOps.Web\exports'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

$loginBody = @{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable sv | Out-Null

# ----------------------------------------------------------------------------
# 1. /hangfire reachable for admin, blocked for anon
# ----------------------------------------------------------------------------
Step "/hangfire authn — admin 200, anon 401"
$admin = Invoke-WebRequest -Uri "$base/hangfire" -WebSession $sv -UseBasicParsing
if ($admin.StatusCode -ne 200) { Fail "Admin /hangfire returned $($admin.StatusCode), expected 200" }
if ($admin.Content -notmatch 'Hangfire') { Fail "/hangfire dashboard HTML doesn't contain 'Hangfire'" }
try {
    Invoke-WebRequest -Uri "$base/hangfire" -UseBasicParsing | Out-Null
    Fail "Anon /hangfire returned 200 — should be blocked"
} catch {
    $status = [int]$_.Exception.Response.StatusCode
    if ($status -ne 401 -and $status -ne 403) { Fail "Anon /hangfire returned $status (expected 401/403)" }
}
OK "/hangfire admin-gated"

# ----------------------------------------------------------------------------
# 2. POST /api/exports/transactions returns a jobId
# ----------------------------------------------------------------------------
Step "POST /api/exports/transactions enqueues a job"
$body = @{ kind='receive'; maxRows=200 } | ConvertTo-Json
$queue = Invoke-RestMethod -Uri "$base/api/exports/transactions" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
if (-not $queue.jobId) { Fail "Response missing jobId" }
if (-not $queue.email) { Fail "Response missing email" }
if (-not $queue.message) { Fail "Response missing message" }
$jobId = $queue.jobId
OK "Queued: jobId=$jobId for $($queue.email)"

# ----------------------------------------------------------------------------
# 3. Hangfire runs the job; XLSX lands on disk
# ----------------------------------------------------------------------------
Step "Hangfire worker runs the job; XLSX file appears within 20s"
$expectedPath = Join-Path $exportRoot "transactions-$($jobId.Replace('-','')).xlsx"
$deadline = (Get-Date).AddSeconds(20)
while (-not (Test-Path $expectedPath) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
}
if (-not (Test-Path $expectedPath)) { Fail "Export file never appeared at $expectedPath (waited 20s)" }
$size = (Get-Item $expectedPath).Length
if ($size -lt 1000) { Fail "Export file suspiciously small: $size bytes" }
# XLSX = ZIP archive — first 2 bytes "PK" magic
$head2 = [System.IO.File]::ReadAllBytes($expectedPath)[0..1]
if (-not ($head2[0] -eq 0x50 -and $head2[1] -eq 0x4B)) { Fail "File is not a valid ZIP/XLSX (missing PK magic)" }
OK "XLSX written ($size bytes) with PK magic"

# ----------------------------------------------------------------------------
# 4. Download endpoint rejects missing/bogus tokens
# ----------------------------------------------------------------------------
Step "Download endpoint — no token + bogus token rejected"
try {
    Invoke-WebRequest -Uri "$base/api/exports/$jobId/download" -WebSession $sv -UseBasicParsing | Out-Null
    Fail "No-token download succeeded — should be rejected"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 400 -and $s -ne 401) { Fail "No-token returned $s (expected 400/401)" }
}
try {
    Invoke-WebRequest -Uri "$base/api/exports/$jobId/download?token=garbage" -WebSession $sv -UseBasicParsing | Out-Null
    Fail "Bogus-token download succeeded — should be rejected"
} catch {
    $s = [int]$_.Exception.Response.StatusCode
    if ($s -ne 401) { Fail "Bogus-token returned $s (expected 401)" }
}
OK "Missing + bogus tokens rejected"

# ----------------------------------------------------------------------------
# 5. Valid token streams the file
# (Sign locally with the same dev SigningKey the server uses. Production
#  smokes would inject the real key via env var.)
# ----------------------------------------------------------------------------
Step "Download endpoint — valid HMAC token streams the file"
$signingKey = 'DEV-ONLY-PLACEHOLDER-SET-Exports:SigningKey-IN-USER-SECRETS'
$expiresAt = (Get-Date).AddHours(1).ToUniversalTime()
$payload = "$($jobId.Replace('-',''))|$($expiresAt.Ticks)"
$hmac = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($signingKey)
$sigBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload))
function UrlB64($bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}
$payloadB64 = UrlB64 ([System.Text.Encoding]::UTF8.GetBytes($payload))
$sigB64     = UrlB64 $sigBytes
$token = "$payloadB64.$sigB64"

$dl = Invoke-WebRequest -Uri "$base/api/exports/$jobId/download?token=$token" -WebSession $sv -UseBasicParsing
if ($dl.StatusCode -ne 200) { Fail "Download with valid token returned $($dl.StatusCode), expected 200" }
if ($dl.Headers['Content-Type'] -notmatch 'application/vnd\.openxmlformats-officedocument\.spreadsheetml\.sheet') {
    Fail "Wrong Content-Type: $($dl.Headers['Content-Type'])"
}
if ($dl.RawContentLength -ne $size) { Fail "Download size $($dl.RawContentLength) != on-disk size $size" }
$dlHead2 = $dl.Content[0..1]
if (-not ($dlHead2[0] -eq 0x50 -and $dlHead2[1] -eq 0x4B)) { Fail "Downloaded bytes missing PK magic" }
OK "Valid HMAC token downloads the file ($size bytes, PK magic)"

# Cleanup
Remove-Item $expectedPath -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "ALL PASS — Phase 8.4 decoupled export pipeline." -ForegroundColor Green
exit 0
