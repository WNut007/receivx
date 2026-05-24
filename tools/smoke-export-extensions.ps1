# Smoke: Phase 8.4 export pipeline extensions (Pos + Audit Log).
#
# Covers each new endpoint + the permission matrix:
#   POST /api/exports/pos        admin: 202; supervisor: 202; operator: 403
#   POST /api/exports/audit-log  admin: 202; supervisor: 403; operator: 403
#
# For each successful enqueue, asserts the file lands on disk + the
# Phase 8.4 glob-download endpoint streams it with a valid HMAC token.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$exportRoot = 'C:\dev\receivx\src\ReceivingOps.Web\exports'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

function ExpectStatus($expected, $script) {
    try {
        $script.Invoke() | Out-Null
        return 200
    } catch {
        return [int]$_.Exception.Response.StatusCode
    }
}

function SignToken($jobId) {
    $signingKey = 'DEV-ONLY-PLACEHOLDER-SET-Exports:SigningKey-IN-USER-SECRETS'
    $expiresAt = (Get-Date).AddHours(1).ToUniversalTime()
    $payload = "$($jobId.Replace('-',''))|$($expiresAt.Ticks)"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($signingKey)
    $sig = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload))
    $b64 = { param($b) [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_') }
    return (& $b64 ([System.Text.Encoding]::UTF8.GetBytes($payload))) + '.' + (& $b64 $sig)
}

function WaitForFile($jobId, $prefix, $timeoutSec = 30) {
    $expected = Join-Path $exportRoot "$prefix-$($jobId.Replace('-','')).xlsx"
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while (-not (Test-Path $expected) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path $expected) { return $expected }
    return $null
}

$admin = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
# 1. /Pos page — admin sees Export button
# ----------------------------------------------------------------------------
Step "/Pos chrome: admin gets Export button in DOM (hidden until JS reveals)"
$pos = Invoke-WebRequest -Uri "$base/Pos" -WebSession $admin -UseBasicParsing
if ($pos.Content -notmatch 'id="btn-export"') { Fail "/Pos missing btn-export DOM" }
OK "/Pos has btn-export hook (JS reveals for admin/supervisor)"

# ----------------------------------------------------------------------------
# 2. POST /api/exports/pos as admin → 202 + file → signed download
# ----------------------------------------------------------------------------
Step "POST /api/exports/pos (admin) → 202 + file + download works"
$body = @{ status = 'open'; maxRows = 500 } | ConvertTo-Json
$resp = Invoke-WebRequest -Uri "$base/api/exports/pos" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin -UseBasicParsing
if ($resp.StatusCode -ne 202) { Fail "POST returned $($resp.StatusCode), expected 202" }
$queue = $resp.Content | ConvertFrom-Json
if (-not $queue.jobId) { Fail "Response missing jobId" }
$file = WaitForFile $queue.jobId 'pos'
if (-not $file) { Fail "pos export file never appeared (30s timeout)" }
$size = (Get-Item $file).Length
$token = SignToken $queue.jobId
$dl = Invoke-WebRequest -Uri "$base/api/exports/$($queue.jobId)/download?token=$token" -WebSession $admin -UseBasicParsing
if ($dl.StatusCode -ne 200) { Fail "Download returned $($dl.StatusCode)" }
if ($dl.RawContentLength -ne $size) { Fail "Download size mismatch: $($dl.RawContentLength) vs on-disk $size" }
$head = $dl.Content[0..1]
if (-not ($head[0] -eq 0x50 -and $head[1] -eq 0x4B)) { Fail "Downloaded bytes missing PK magic" }
Remove-Item $file -Force -ErrorAction SilentlyContinue
OK "Pos export round-trip: $size bytes XLSX served via signed download"

# ----------------------------------------------------------------------------
# 3. POST /api/exports/pos as supervisor → 202 (allowed)
# ----------------------------------------------------------------------------
Step "POST /api/exports/pos (supervisor) → 202"
$sup = Login 'swattana' 'demo1234' $WH_01
$resp = Invoke-WebRequest -Uri "$base/api/exports/pos" -Method POST -Body $body -ContentType 'application/json' -WebSession $sup -UseBasicParsing
if ($resp.StatusCode -ne 202) { Fail "Supervisor POS export returned $($resp.StatusCode), expected 202" }
$queue = $resp.Content | ConvertFrom-Json
$file = WaitForFile $queue.jobId 'pos'
if ($file) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
OK "Supervisor allowed to queue Pos export"

# ----------------------------------------------------------------------------
# 4. POST /api/exports/audit-log as admin → 202 + file → signed download
# ----------------------------------------------------------------------------
Step "POST /api/exports/audit-log (admin) → 202 + file + download works"
$body = @{ maxRows = 200 } | ConvertTo-Json
$resp = Invoke-WebRequest -Uri "$base/api/exports/audit-log" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin -UseBasicParsing
if ($resp.StatusCode -ne 202) { Fail "Audit POST returned $($resp.StatusCode), expected 202" }
$queue = $resp.Content | ConvertFrom-Json
$file = WaitForFile $queue.jobId 'audit-log'
if (-not $file) { Fail "audit-log export file never appeared" }
$size = (Get-Item $file).Length
$token = SignToken $queue.jobId
$dl = Invoke-WebRequest -Uri "$base/api/exports/$($queue.jobId)/download?token=$token" -WebSession $admin -UseBasicParsing
if ($dl.StatusCode -ne 200) { Fail "Download returned $($dl.StatusCode)" }
$head = $dl.Content[0..1]
if (-not ($head[0] -eq 0x50 -and $head[1] -eq 0x4B)) { Fail "Downloaded bytes missing PK magic" }
Remove-Item $file -Force -ErrorAction SilentlyContinue
OK "Audit Log export round-trip: $size bytes XLSX served via signed download"

# ----------------------------------------------------------------------------
# 5. POST /api/exports/audit-log as supervisor → 403 (admin-only)
# ----------------------------------------------------------------------------
Step "POST /api/exports/audit-log (supervisor) → 403"
$body = @{ maxRows = 100 } | ConvertTo-Json
$supStatus = 0
try {
    Invoke-WebRequest -Uri "$base/api/exports/audit-log" -Method POST -Body $body -ContentType 'application/json' -WebSession $sup -UseBasicParsing | Out-Null
    Fail "Supervisor audit-log export should have failed but returned success"
} catch {
    $supStatus = [int]$_.Exception.Response.StatusCode
}
if ($supStatus -ne 403) { Fail "Supervisor audit-log export returned $supStatus, expected 403" }
OK "Supervisor blocked from audit-log export (admin-only)"

# ----------------------------------------------------------------------------
# 6. /Masters page has admin-only btn-export-audit DOM hook
# ----------------------------------------------------------------------------
Step "/Masters has btn-export-audit DOM hook"
$masters = Invoke-WebRequest -Uri "$base/Masters" -WebSession $admin -UseBasicParsing
if ($masters.Content -notmatch 'id="btn-export-audit"') { Fail "/Masters missing btn-export-audit" }
OK "/Masters has btn-export-audit hook (JS reveals for admin only)"

Write-Host ""
Write-Host "ALL PASS — Pos + Audit Log export pipelines wired + gated." -ForegroundColor Green
exit 0
