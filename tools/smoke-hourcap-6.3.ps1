# Smoke test: v2.1 Hour Cap Phase 6.3 — PUT immutability for LockHourCap
#
# Mirrors the §3.5 LockPoByPull immutability pattern (smoke-phase-4d):
# PullAdminService.UpdateAsync rejects any PUT whose body carries a
# LockHourCap value that differs from the current state — in both
# directions. Existing v2 PUT contract (PullDate/Eta/Notes editable) is
# preserved.
#
# 6 cases:
#   1. PUT a strict pull WITH lockHourCap=true → 200 (echo OK)
#   2. PUT a strict pull WITH lockHourCap=false → 409 (true → false rejected)
#   3. PUT a strict pull WITHOUT lockHourCap → 409 (defaults to true via DTO; sent body has false default? no — see comment)
#      Actually: PullUpdateRequest defaults LockHourCap=true, so omitting it
#      from the JSON body sends true. Test 3 covers omit → 200 on strict pulls.
#   4. PUT a loose pull WITH lockHourCap=false → 200 (echo OK)
#   5. PUT a loose pull WITH lockHourCap=true → 409 (false → true rejected)
#   6. PUT a loose pull WITHOUT lockHourCap → 409 (DTO default true mismatches loose)
#   7. PUT with same-value echo also accepts PullDate/Eta/Notes edits → 200
#
# Setup: PL-SHC-{seconds}-{counter}-{kind} via the API (mirrors 6.2 naming).
# Receipts FK doesn't block here — these tests don't receive. Cleanup just
# DELETEs the pulls.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

$script:smkN = 0

function SqlCleanup {
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
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

function NewPull($lockHourCap, $kind) {
    $script:smkN++
    $pullNum = "PL-SHC-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$($script:smkN)-$kind"
    $body = @{
        pullNumber = $pullNum; warehouseId = $WH_01
        pullDate = (Get-Date -Format 'yyyy-MM-dd')
        eta = '14:00'; notes = 'phase 6.3 smoke'
        lockPoByPull = $false
        lockHourCap = $lockHourCap
    } | ConvertTo-Json
    return Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
}

# ----------------------------------------------------------------------------
$sv = Login 'sadmin' 'admin' $WH_01

# Source check — PullUpdateRequest gains LockHourCap + PullAdminService gains immutability
Step "Source: PullUpdateRequest + PullAdminService carry LockHourCap immutability"
$dto = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Models\Dtos\PullDtos.cs' -Raw
if ($dto -notmatch 'LockHourCap.*=\s*true.*immutable') {
    if ($dto -notmatch 'public bool LockHourCap') { Fail "PullUpdateRequest missing LockHourCap" }
}
$svc = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Services\PullAdminService.cs' -Raw
foreach ($needle in @(
    'req.LockHourCap != pull.LockHourCap',
    'LockHourCap is immutable after pull creation'
)) {
    if ($svc -notmatch [regex]::Escape($needle)) { Fail "PullAdminService missing $needle" }
}
OK "Source carries PUT immutability check + DTO field"

# ----------------------------------------------------------------------------
# 1. Strict pull, PUT with echo true → 200
# ----------------------------------------------------------------------------
Step "Strict pull, PUT with lockHourCap=true (echo) → 200"
$p1 = NewPull $true 'PUT-ECHO-T'
$putBody = @{
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = '15:00'; notes = 'edited'
    lockPoByPull = $false
    lockHourCap = $true
} | ConvertTo-Json
$updated = Invoke-RestMethod -Uri "$base/api/pulls/$($p1.id)" -Method PUT -Body $putBody -ContentType 'application/json' -WebSession $sv
if ($updated.lockHourCap -ne $true) { Fail "Echo update: expected lockHourCap=true, got $($updated.lockHourCap)" }
if ($updated.eta -ne '15:00')        { Fail "Echo update didn't apply Eta: $($updated.eta)" }
OK "Echo PUT applied non-flag edits, kept lockHourCap=true"

# ----------------------------------------------------------------------------
# 2. Strict pull, PUT flip true → false → 409
# ----------------------------------------------------------------------------
Step "Strict pull, PUT flip true→false → 409"
$flipBody = @{
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = '15:00'; notes = 'edited'
    lockPoByPull = $false
    lockHourCap = $false
} | ConvertTo-Json
$r = InvokeExpectFail 'PUT' "$base/api/pulls/$($p1.id)" $flipBody $sv 409
if (-not $r -or $r.Wrong) { Fail "Expected 409 on strict→loose flip, got $($r.Status)" }
if ($r.Title -notmatch 'LockHourCap is immutable') { Fail "Title missing 'LockHourCap is immutable': $($r.Title)" }
OK "Strict pull rejects true→false flip with 409"

# ----------------------------------------------------------------------------
# 3. Loose pull, PUT with echo false → 200
# ----------------------------------------------------------------------------
Step "Loose pull, PUT with lockHourCap=false (echo) → 200"
$p2 = NewPull $false 'PUT-ECHO-F'
$echoBody = @{
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = '16:00'; notes = 'edited loose'
    lockPoByPull = $false
    lockHourCap = $false
} | ConvertTo-Json
$updated2 = Invoke-RestMethod -Uri "$base/api/pulls/$($p2.id)" -Method PUT -Body $echoBody -ContentType 'application/json' -WebSession $sv
if ($updated2.lockHourCap -ne $false) { Fail "Loose echo: expected false, got $($updated2.lockHourCap)" }
OK "Loose pull echo PUT 200"

# ----------------------------------------------------------------------------
# 4. Loose pull, PUT flip false → true → 409
# ----------------------------------------------------------------------------
Step "Loose pull, PUT flip false→true → 409"
$flipBody2 = @{
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = '16:00'; notes = 'edited loose'
    lockPoByPull = $false
    lockHourCap = $true
} | ConvertTo-Json
$r = InvokeExpectFail 'PUT' "$base/api/pulls/$($p2.id)" $flipBody2 $sv 409
if (-not $r -or $r.Wrong) { Fail "Expected 409 on loose→strict flip, got $($r.Status)" }
if ($r.Title -notmatch 'LockHourCap is immutable') { Fail "Title missing 'LockHourCap is immutable': $($r.Title)" }
OK "Loose pull rejects false→true flip with 409"

# ----------------------------------------------------------------------------
# 5. Loose pull, PUT WITHOUT lockHourCap → 409 (DTO defaults to true; mismatches loose state)
# ----------------------------------------------------------------------------
Step "Loose pull, PUT body OMITS lockHourCap → 409 (DTO defaults to true)"
$omitBody = @{
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = '17:00'; notes = 'omit hcap'
    lockPoByPull = $false
    # lockHourCap omitted on purpose; DTO default = true
} | ConvertTo-Json
$r = InvokeExpectFail 'PUT' "$base/api/pulls/$($p2.id)" $omitBody $sv 409
if (-not $r -or $r.Wrong) { Fail "Expected 409 when body omits lockHourCap on loose pull, got $($r.Status)" }
OK "Loose pull rejects PUT that omits lockHourCap (default-true mismatch)"

# ----------------------------------------------------------------------------
# 6. Strict pull, PUT WITHOUT lockHourCap → 200 (default true matches strict state)
# ----------------------------------------------------------------------------
Step "Strict pull, PUT body OMITS lockHourCap → 200 (DTO default matches)"
$strictOmit = NewPull $true 'PUT-OMIT-S'
$omitBody2 = @{
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = '18:00'; notes = 'omit on strict'
    lockPoByPull = $false
    # lockHourCap omitted; DTO default true matches strict pull state
} | ConvertTo-Json
$updated3 = Invoke-RestMethod -Uri "$base/api/pulls/$($strictOmit.id)" -Method PUT -Body $omitBody2 -ContentType 'application/json' -WebSession $sv
if ($updated3.eta -ne '18:00') { Fail "Omit-on-strict didn't apply Eta: $($updated3.eta)" }
OK "Strict pull accepts PUT that omits lockHourCap (default-true matches)"

SqlCleanup
Write-Host ""
Write-Host "ALL PASS — Hour Cap Phase 6.3 PUT immutability wired." -ForegroundColor Green
exit 0
