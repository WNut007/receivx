# Smoke test: v2.1 Phase 6.2 — PullItem windows sub-resource
#
# Covers /api/pulls/{id}/items/{itemId}/windows[/{hour}]:
#   - Source landmarks on the controller + service + DTOs
#   - GET list reflects the windows on an item
#   - POST adds a new hour → 201, GET reflects it
#   - POST duplicate hour → 409 (UQ_PIW_Hour mapped to friendly message)
#   - POST bad ExpectedQty (<=0) → 400
#   - POST HourOfDay=25 → 400
#   - PUT changes ExpectedQty → 200, GET reflects new qty
#   - PUT below current ReceivedQty → 409 (pre-check before CK_PIW_Caps)
#   - PUT route hour=99 → 400 (controller-level guard)
#   - DELETE happy path → 204, GET no longer includes it
#   - DELETE with ReceivedQty > 0 → 409 (SQL poke to simulate post-receive)
#   - DELETE non-existent hour → 404
#
# Each run uses a fresh PL-SMOKE-6.2-{tick} pull so re-runs don't collide.
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

function SqlCleanup {
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-SMOKE-6.2-%';
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

# ----------------------------------------------------------------------------
# 1. Source-level
# ----------------------------------------------------------------------------
Step "Source: controller endpoints + service methods + DTOs"
$ctl = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Controllers\Api\PullsApiController.cs' -Raw
foreach ($needle in @(
    'HttpGet("{id:guid}/items/{itemId:guid}/windows")',
    'HttpPost("{id:guid}/items/{itemId:guid}/windows")',
    'HttpPut("{id:guid}/items/{itemId:guid}/windows/{hour:int}")',
    'HttpDelete("{id:guid}/items/{itemId:guid}/windows/{hour:int}")'
)) {
    if ($ctl -notmatch [regex]::Escape($needle)) { Fail "PullsApiController missing $needle" }
}

$svc = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Services\IPullItemAdminService.cs' -Raw
foreach ($m in @('AddWindowAsync', 'UpdateWindowAsync', 'DeleteWindowAsync')) {
    if ($svc -notmatch [regex]::Escape($m)) { Fail "IPullItemAdminService missing $m" }
}

$dto = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Models\Dtos\PullItemDtos.cs' -Raw
foreach ($cls in @('PullItemWindowCreateRequest', 'PullItemWindowUpdateRequest')) {
    if ($dto -notmatch [regex]::Escape($cls)) { Fail "PullItemDtos missing $cls" }
}
OK "Source landmarks present"

# ----------------------------------------------------------------------------
# 2. Setup: login + create smoke pull + a single item to host windows
# ----------------------------------------------------------------------------
Step "Login sadmin / WH-01 + create smoke pull + seed item"
$sv = Login 'sadmin' 'admin' $WH_01

$pullNum = "PL-SMOKE-6.2-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$pullBody = @{
    pullNumber = $pullNum; warehouseId = $WH_01
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null; lockPoByPull = $false
} | ConvertTo-Json
$pullId = (Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $pullBody -ContentType 'application/json' -WebSession $sv).id

$itemBody = @{
    itemCode = 'SMK62-A'; description = 'Smoke 6.2 item A'
    windows = @(@{ hourOfDay = 8; expectedQty = 100 })
} | ConvertTo-Json -Depth 5
$itemId = (Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items" -Method POST -Body $itemBody -ContentType 'application/json' -WebSession $sv).id
OK "Created $pullNum + item SMK62-A with one window at 08:00"

# ----------------------------------------------------------------------------
# 3. GET /windows — initial state
# ----------------------------------------------------------------------------
Step "GET /windows returns the seeded window"
$wins = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$itemId/windows" -Method GET -WebSession $sv
if ($wins.Count -ne 1)           { Fail "Expected 1 window, got $($wins.Count)" }
if ($wins[0].hourOfDay -ne 8)    { Fail "Expected hour 8, got $($wins[0].hourOfDay)" }
if ($wins[0].expectedQty -ne 100){ Fail "Expected qty 100, got $($wins[0].expectedQty)" }
OK "GET /windows reflects the seeded window"

# ----------------------------------------------------------------------------
# 4. POST /windows happy path
# ----------------------------------------------------------------------------
Step "POST /windows new hour → 201"
$addBody = @{ hourOfDay = 9; expectedQty = 200 } | ConvertTo-Json
$added = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$itemId/windows" -Method POST -Body $addBody -ContentType 'application/json' -WebSession $sv
if ($added.hourOfDay -ne 9)     { Fail "Added window wrong hour: $($added.hourOfDay)" }
if ($added.expectedQty -ne 200) { Fail "Added window wrong qty: $($added.expectedQty)" }
OK "POST /windows added hour 9 / 200 pcs"

$wins = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$itemId/windows" -Method GET -WebSession $sv
if ($wins.Count -ne 2) { Fail "Expected 2 windows after add, got $($wins.Count)" }
OK "GET /windows reflects the add"

# ----------------------------------------------------------------------------
# 5. POST duplicate hour → 409
# ----------------------------------------------------------------------------
Step "POST duplicate hour → 409"
$dup = @{ hourOfDay = 9; expectedQty = 50 } | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/pulls/$pullId/items/$itemId/windows" $dup $sv 409
if (-not $r -or $r.Wrong) { Fail "Expected 409 dup hour, got $($r.Status)" }
if ($r.Title -notmatch 'already exists') { Fail "Expected 'already exists' in title: $($r.Title)" }
OK "Duplicate hour rejected with 409"

# ----------------------------------------------------------------------------
# 6. Validation: zero qty / negative qty / hour=25
# ----------------------------------------------------------------------------
Step "POST ExpectedQty=0 → 400"
$bad = @{ hourOfDay = 11; expectedQty = 0 } | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/pulls/$pullId/items/$itemId/windows" $bad $sv 400
if (-not $r -or $r.Wrong) { Fail "Expected 400 qty=0, got $($r.Status)" }
OK "ExpectedQty=0 → 400"

Step "POST HourOfDay=25 → 400"
$bad = @{ hourOfDay = 25; expectedQty = 5 } | ConvertTo-Json
$r = InvokeExpectFail 'POST' "$base/api/pulls/$pullId/items/$itemId/windows" $bad $sv 400
if (-not $r -or $r.Wrong) { Fail "Expected 400 hour=25, got $($r.Status)" }
OK "HourOfDay=25 → 400"

# ----------------------------------------------------------------------------
# 7. PUT updates ExpectedQty
# ----------------------------------------------------------------------------
Step "PUT /windows/9 updates ExpectedQty → 200"
$putBody = @{ expectedQty = 300 } | ConvertTo-Json
$put = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$itemId/windows/9" -Method PUT -Body $putBody -ContentType 'application/json' -WebSession $sv
if ($put.expectedQty -ne 300) { Fail "PUT response wrong qty: $($put.expectedQty)" }

$wins = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$itemId/windows" -Method GET -WebSession $sv
$w9 = $wins | Where-Object hourOfDay -eq 9
if ($w9.expectedQty -ne 300) { Fail "GET after PUT still shows old qty: $($w9.expectedQty)" }
OK "PUT applied 300 pcs to hour 9"

# ----------------------------------------------------------------------------
# 8. PUT below ReceivedQty (SQL poke for ReceivedQty=50, try PUT to 25 → 409)
# ----------------------------------------------------------------------------
Step "PUT ExpectedQty < ReceivedQty → 409"
$pokeSql = @"
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
UPDATE dbo.PullItemWindows
   SET ReceivedQty = 50
 WHERE PullItemId = '$itemId' AND HourOfDay = 9;
"@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -b -Q $pokeSql 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "SQL poke failed" }

$lowBody = @{ expectedQty = 25 } | ConvertTo-Json
$r = InvokeExpectFail 'PUT' "$base/api/pulls/$pullId/items/$itemId/windows/9" $lowBody $sv 409
if (-not $r -or $r.Wrong) { Fail "Expected 409 qty<received, got $($r.Status)" }
if ($r.Title -notmatch 'below ReceivedQty') { Fail "Expected 'below ReceivedQty' in title: $($r.Title)" }
OK "PUT below ReceivedQty rejected with 409"

# ----------------------------------------------------------------------------
# 9. PUT route-hour=99 → 400 (controller-level guard)
# ----------------------------------------------------------------------------
Step "PUT route /windows/99 → 400"
$any = @{ expectedQty = 1 } | ConvertTo-Json
$r = InvokeExpectFail 'PUT' "$base/api/pulls/$pullId/items/$itemId/windows/99" $any $sv 400
if (-not $r -or $r.Wrong) { Fail "Expected 400 route hour=99, got $($r.Status)" }
OK "Route hour > 23 → 400"

# ----------------------------------------------------------------------------
# 10. DELETE window with ReceivedQty > 0 → 409
# ----------------------------------------------------------------------------
Step "DELETE /windows/9 with ReceivedQty=50 → 409"
$r = InvokeExpectFail 'DELETE' "$base/api/pulls/$pullId/items/$itemId/windows/9" $null $sv 409
if (-not $r -or $r.Wrong) { Fail "Expected 409 delete with receipts, got $($r.Status)" }
OK "DELETE with receipts → 409"

# Restore for happy-path delete below
$resetSql = @"
SET QUOTED_IDENTIFIER ON;
UPDATE dbo.PullItemWindows SET ReceivedQty = 0 WHERE PullItemId = '$itemId' AND HourOfDay = 9;
"@
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -b -Q $resetSql 2>&1 | Out-Null

# ----------------------------------------------------------------------------
# 11. DELETE happy path → 204
# ----------------------------------------------------------------------------
Step "DELETE /windows/9 (no receipts now) → 204"
try {
    Invoke-WebRequest -Uri "$base/api/pulls/$pullId/items/$itemId/windows/9" -Method DELETE -WebSession $sv -UseBasicParsing | Out-Null
    OK "DELETE returned 2xx"
} catch {
    Fail "DELETE happy path failed: $($_.Exception.Message)"
}

$wins = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$itemId/windows" -Method GET -WebSession $sv
if ($wins.Count -ne 1) { Fail "Expected 1 window after delete, got $($wins.Count)" }
if (($wins | Where-Object hourOfDay -eq 9)) { Fail "Hour 9 still present after DELETE" }
OK "Hour 9 gone from list"

# ----------------------------------------------------------------------------
# 12. DELETE non-existent hour → 404
# ----------------------------------------------------------------------------
Step "DELETE /windows/9 second time → 404"
$r = InvokeExpectFail 'DELETE' "$base/api/pulls/$pullId/items/$itemId/windows/9" $null $sv 404
if (-not $r -or $r.Wrong) { Fail "Expected 404 second delete, got $($r.Status)" }
OK "DELETE non-existent → 404"

# ----------------------------------------------------------------------------
# Final cleanup
# ----------------------------------------------------------------------------
SqlCleanup
Write-Host ""
Write-Host "ALL PASS — Phase 6.2 PullItem windows sub-resource wired correctly." -ForegroundColor Green
exit 0
