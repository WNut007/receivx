# Smoke test: §3.5 typeahead — GET /api/pulls/search
#
# Validates:
#   1. Missing warehouseId → 400
#   2. q too short (< 2 chars) → 400
#   3. Default take caps the result at 10 (creates 11 matching pulls)
#   4. Prefix match on PullNumber ranks above substring-only matches
#   5. Closed pulls (status != pending/in_progress) excluded
#   6. Cross-warehouse isolation — a WH-02 pull never appears in a WH-01 search
#   7. Substring match works without needing a PullNumber prefix
#   8. Operator session (no CanManagePulls policy) → 403
#
# Test data is namespaced under PL-SMOKE-PS-% and ZZ-PL-SMOKE-PS-% so the
# pre/post SqlCleanup wipes are tight (won't touch seeded PL-2840-PL-2901).
#
# Assumes ReceivingOps.Web is running on http://localhost:5213.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_02 = '22222222-2222-2222-2222-000000000002'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; SqlCleanup; exit 1 }

function SqlCleanup {
    $sql = @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-SMOKE-PS-%' OR PullNumber LIKE 'ZZ-PL-SMOKE-PS-%';
'@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}

# Pre-test cleanup (idempotent)
SqlCleanup

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

function CreatePull($number, $whId, $session) {
    $body = @{
        pullNumber  = $number
        warehouseId = $whId
        pullDate    = (Get-Date).ToString('yyyy-MM-dd')
        notes       = 'smoke pull-search test'
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $body -ContentType 'application/json' -WebSession $session | Out-Null
}

# ----------------------------------------------------------------------------
# Login as admin
# ----------------------------------------------------------------------------
Step "Login (sadmin / WH-01)"
$adm = Login 'sadmin' 'admin' $WH_01
OK "Login ok"

# ----------------------------------------------------------------------------
# 1. Missing warehouseId
# ----------------------------------------------------------------------------
Step "GET /api/pulls/search without warehouseId → 400"
try {
    Invoke-WebRequest -Uri "$base/api/pulls/search?q=PL" -WebSession $adm | Out-Null
    Fail 'Expected 400, got success'
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 400) { Fail "Expected 400, got $code" }
    if ($_.ErrorDetails.Message -notmatch 'warehouseId') {
        Fail "Expected 'warehouseId' in title; got: $($_.ErrorDetails.Message)"
    }
    OK '400 with warehouseId message'
}

# ----------------------------------------------------------------------------
# 2. q too short
# ----------------------------------------------------------------------------
Step "GET /api/pulls/search?q=a (single char) → 400"
try {
    Invoke-WebRequest -Uri "$base/api/pulls/search?warehouseId=$WH_01&q=a" -WebSession $adm | Out-Null
    Fail 'Expected 400 on single-char q'
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 400) { Fail "Expected 400, got $code" }
    if ($_.ErrorDetails.Message -notmatch '2 characters') {
        Fail "Expected '2 characters' in title; got: $($_.ErrorDetails.Message)"
    }
    OK '400 with min-length message'
}

# ----------------------------------------------------------------------------
# 3. Default take caps at 10 (create 11, expect 10)
# ----------------------------------------------------------------------------
$tick = [DateTime]::UtcNow.Ticks % 1000000
Step "Create 11 matching pulls for take-cap test"
for ($i = 1; $i -le 11; $i++) {
    CreatePull "PL-SMOKE-PS-CAP-$tick-$('{0:D2}' -f $i)" $WH_01 $adm
}
OK '11 pulls created'

Step "Default take returns max 10"
$rows = Invoke-RestMethod -Uri "$base/api/pulls/search?warehouseId=$WH_01&q=PL-SMOKE-PS-CAP-$tick" -WebSession $adm
if (-not $rows -or $rows.Count -ne 10) { Fail "Expected 10 rows, got $($rows.Count)" }
OK 'Capped at 10'

# ----------------------------------------------------------------------------
# 4. Prefix-match ranking
# ----------------------------------------------------------------------------
Step 'Setup: one prefix-only + one substring-only pull for ranking test'
$preNum = "PL-SMOKE-PS-RANK-PRE-$tick"
$subNum = "ZZ-PL-SMOKE-PS-RANK-SUB-$tick"
CreatePull $preNum $WH_01 $adm
CreatePull $subNum $WH_01 $adm
OK 'PRE + SUB pulls created'

Step "q='PL-SMOKE-PS-RANK' — prefix match must rank above substring"
$rows = Invoke-RestMethod -Uri "$base/api/pulls/search?warehouseId=$WH_01&q=PL-SMOKE-PS-RANK" -WebSession $adm
if ($rows.Count -lt 2) { Fail "Expected >= 2 rows, got $($rows.Count)" }
if ($rows[0].pullNumber -ne $preNum) {
    Fail "Expected prefix '$preNum' first; got '$($rows[0].pullNumber)'"
}
$subIdx = -1
for ($i = 0; $i -lt $rows.Count; $i++) {
    if ($rows[$i].pullNumber -eq $subNum) { $subIdx = $i; break }
}
if ($subIdx -lt 0) { Fail "Substring pull '$subNum' not returned" }
if ($subIdx -eq 0) { Fail "Substring pull ranked first; should be lower than prefix" }
OK "Prefix match ranks first (substring at idx $subIdx)"

# ----------------------------------------------------------------------------
# 5. Closed pulls excluded
# ----------------------------------------------------------------------------
Step 'Closed pulls excluded — create then force Status=closed via SQL'
$closedNum = "PL-SMOKE-PS-CLOSED-$tick"
CreatePull $closedNum $WH_01 $adm

# Sanity: before closing, the pull IS searchable (proves the test setup)
$before = Invoke-RestMethod -Uri "$base/api/pulls/search?warehouseId=$WH_01&q=$closedNum" -WebSession $adm
if ($before.Count -lt 1) { Fail 'Setup broken — created pull is not searchable while still open' }

$sqlClose = "SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON; UPDATE dbo.Pulls SET Status = 'closed' WHERE PullNumber = '$closedNum';"
sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sqlClose 2>&1 | Out-Null

$after = Invoke-RestMethod -Uri "$base/api/pulls/search?warehouseId=$WH_01&q=$closedNum" -WebSession $adm
if ($after.Count -gt 0) { Fail "Closed pull returned in search results: $($after[0].pullNumber)" }
OK 'Closed pull excluded (was 1 result before close → 0 after)'

# ----------------------------------------------------------------------------
# 6. Cross-warehouse isolation
# ----------------------------------------------------------------------------
Step 'Create pull in WH-02; WH-01 search must NOT include it'
$wh2Num = "PL-SMOKE-PS-WH2-$tick"
CreatePull $wh2Num $WH_02 $adm

$rowsWh1 = Invoke-RestMethod -Uri "$base/api/pulls/search?warehouseId=$WH_01&q=$wh2Num" -WebSession $adm
if ($rowsWh1.Count -gt 0) { Fail 'WH-02 pull leaked into WH-01 search results' }

# Sanity — WH-02 search DOES find it
$rowsWh2 = Invoke-RestMethod -Uri "$base/api/pulls/search?warehouseId=$WH_02&q=$wh2Num" -WebSession $adm
if ($rowsWh2.Count -lt 1) { Fail 'WH-02 pull not found in WH-02 search either — fixture broken' }
OK 'Cross-warehouse isolation enforced'

# ----------------------------------------------------------------------------
# 7. Substring match — q does not have to be a PullNumber prefix
# ----------------------------------------------------------------------------
Step "Substring search 'RANK-SUB-$tick' finds the ZZ-prefixed pull"
$rows = Invoke-RestMethod -Uri "$base/api/pulls/search?warehouseId=$WH_01&q=RANK-SUB-$tick" -WebSession $adm
$found = $rows | Where-Object { $_.pullNumber -eq $subNum }
if (-not $found) { Fail "Substring search didn't find '$subNum'" }
OK 'Substring match works (no PullNumber prefix needed)'

# ----------------------------------------------------------------------------
# 8. Operator (no CanManagePulls) → 403
#   swattana is supervisor at WH-01 and operator at WH-02. Logging in at WH-02
#   makes the session role 'operator', which fails CanManagePulls. The cookie
#   scheme's OnRedirectToAccessDenied handler converts /api/* redirects into a
#   real 403 (see Program.cs).
# ----------------------------------------------------------------------------
Step 'Operator session (swattana@WH-02) → 403'
$op = Login 'swattana' 'demo1234' $WH_02
try {
    Invoke-WebRequest -Uri "$base/api/pulls/search?warehouseId=$WH_02&q=PL" -WebSession $op | Out-Null
    Fail 'Expected 403, got success'
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 403) { Fail "Expected 403, got $code" }
    OK '403 — operator refused'
}

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
Step 'Cleanup smoke pulls'
SqlCleanup
$remaining = (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE 'PL-SMOKE-PS-%' OR PullNumber LIKE 'ZZ-PL-SMOKE-PS-%';" 2>&1 | Out-String).Trim()
if ($remaining -ne '0') { Fail "Cleanup failed: $remaining smoke pull(s) remain" }
OK 'Smoke pulls cleaned'

Write-Host "`nPull search smoke PASSED." -ForegroundColor Green
exit 0
