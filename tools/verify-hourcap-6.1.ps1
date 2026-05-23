# Verify-phase-6.1 — schema migration for Pulls.LockHourCap
#
# Checks per the Phase 6 spec:
#   1. Column dbo.Pulls.LockHourCap exists, NOT NULL, BIT.
#   2. DF_Pulls_LockHourCap default constraint exists and = 1.
#   3. All existing pulls have LockHourCap = 1 (backfill via DEFAULT).
#   4. PullSummary + PullDetail responses carry lockHourCap (read path).
#   5. POST /api/pulls without lockHourCap → persists 1 (strict default).
#   6. POST /api/pulls with lockHourCap=false → persists 0.
#
# Smoke pulls are prefixed PL-VERIFY-6.1- and wiped before/after to keep the
# audit log readable and avoid colliding with PL-2900/2901 + later smokes.
#
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
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-VERIFY-6.1-%';
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

# ----------------------------------------------------------------------------
# 1. Schema — column + default constraint
# ----------------------------------------------------------------------------
Step "Column dbo.Pulls.LockHourCap exists (NOT NULL BIT)"
$colMeta = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q @'
SET NOCOUNT ON;
SELECT TYPE_NAME(c.system_type_id) + '|' + CAST(c.is_nullable AS VARCHAR)
FROM sys.columns c
WHERE c.name = 'LockHourCap'
  AND c.object_id = OBJECT_ID('dbo.Pulls');
'@ 2>&1
if ($colMeta -notmatch 'bit\|0') { Fail "LockHourCap missing or wrong type/nullability: $colMeta" }
OK "LockHourCap column is BIT NOT NULL"

Step "DF_Pulls_LockHourCap default constraint exists and = 1"
$dfMeta = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q @'
SET NOCOUNT ON;
SELECT dc.name + '|' + dc.definition
FROM sys.default_constraints dc
INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
WHERE c.name = 'LockHourCap'
  AND c.object_id = OBJECT_ID('dbo.Pulls');
'@ 2>&1
if ($dfMeta -notmatch 'DF_Pulls_LockHourCap\|\(\(1\)\)') { Fail "DF_Pulls_LockHourCap missing or not = 1: $dfMeta" }
OK "DF_Pulls_LockHourCap = ((1))"

# ----------------------------------------------------------------------------
# 2. Backfill — all existing pulls = 1
# ----------------------------------------------------------------------------
Step "All seeded pulls have LockHourCap = 1 (smoke/verify namespaces excluded)"
# The backfill invariant is about pulls that existed BEFORE the migration —
# i.e. seeded fixtures. Smoke harnesses (PL-SMOKE-%, PL-SHC-%, PL-VERIFY-%)
# create loose pulls on purpose; counting them here would chase a moving
# target, especially when an earlier smoke leaves a loose pull behind due
# to a Receipts FK that blocks cleanup.
$nonStrict = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.Pulls
WHERE LockHourCap = 0
  AND PullNumber NOT LIKE 'PL-SMOKE-%'
  AND PullNumber NOT LIKE 'PL-SHC-%'
  AND PullNumber NOT LIKE 'PL-VERIFY-%';
"@ 2>&1
if ([int]($nonStrict.Trim()) -ne 0) { Fail "$nonStrict seeded pull(s) have LockHourCap = 0 after backfill (expected 0)" }
OK "Backfill clean — all seeded pulls strict"

# ----------------------------------------------------------------------------
# 3. Read path — PullSummary + PullDetail expose lockHourCap
# ----------------------------------------------------------------------------
Step "GET /api/pulls (PullSummary) carries lockHourCap"
$sv = Login 'sadmin' 'admin' $WH_01
$summaries = Invoke-RestMethod -Uri "$base/api/pulls" -Method GET -WebSession $sv
if (-not $summaries -or $summaries.Count -eq 0) { Fail "GET /api/pulls returned empty" }
$first = $summaries[0]
if (-not ($first | Get-Member -Name 'lockHourCap' -MemberType NoteProperty)) {
    Fail "PullSummary missing lockHourCap field"
}
if ($first.lockHourCap -ne $true) { Fail "Existing pull lockHourCap not true: $($first.lockHourCap)" }
OK "PullSummary.lockHourCap present + true on existing pulls"

Step "GET /api/pulls/{id} (PullDetail) carries lockHourCap"
$detail = Invoke-RestMethod -Uri "$base/api/pulls/$($first.id)" -Method GET -WebSession $sv
if (-not ($detail | Get-Member -Name 'lockHourCap' -MemberType NoteProperty)) {
    Fail "PullDetail missing lockHourCap"
}
if ($detail.lockHourCap -ne $true) { Fail "PullDetail.lockHourCap not true: $($detail.lockHourCap)" }
OK "PullDetail.lockHourCap present + true"

# ----------------------------------------------------------------------------
# 4. POST default — body without lockHourCap → defaults to 1
# ----------------------------------------------------------------------------
Step "POST /api/pulls WITHOUT lockHourCap → defaults to true"
$defaultPullNum = "PL-VERIFY-6.1-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-DEF"
$body = @{
    pullNumber = $defaultPullNum
    warehouseId = $WH_01
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null
    lockPoByPull = $false
    # lockHourCap omitted on purpose
} | ConvertTo-Json
$created = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
if ($created.lockHourCap -ne $true) { Fail "Created pull's lockHourCap not true (got $($created.lockHourCap))" }
$dbVal = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT LockHourCap FROM dbo.Pulls WHERE PullNumber = '$defaultPullNum';" 2>&1
if ($dbVal.Trim() -ne '1') { Fail "DB persisted LockHourCap = $dbVal, expected 1" }
OK "Default insert is strict (LockHourCap = 1)"

# ----------------------------------------------------------------------------
# 5. POST explicit false → persists 0
# ----------------------------------------------------------------------------
Step "POST /api/pulls WITH lockHourCap=false → persists 0"
$loosePullNum = "PL-VERIFY-6.1-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-LOOSE"
$body = @{
    pullNumber = $loosePullNum
    warehouseId = $WH_01
    pullDate = (Get-Date -Format 'yyyy-MM-dd')
    eta = $null; notes = $null
    lockPoByPull = $false
    lockHourCap = $false
} | ConvertTo-Json
$created = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
if ($created.lockHourCap -ne $false) { Fail "Created pull's lockHourCap not false (got $($created.lockHourCap))" }
$dbVal = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT LockHourCap FROM dbo.Pulls WHERE PullNumber = '$loosePullNum';" 2>&1
if ($dbVal.Trim() -ne '0') { Fail "DB persisted LockHourCap = $dbVal, expected 0" }
OK "Explicit lockHourCap=false persisted as 0"

# ----------------------------------------------------------------------------
# 6. Audit row — the create event flags non-strict
# ----------------------------------------------------------------------------
Step "Audit row for the loose pull flags LockHourCap=false"
$auditMsg = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT TOP 1 Message FROM dbo.AuditLog WHERE EntityType = 'Pull' AND Message LIKE 'Created pull $loosePullNum%' ORDER BY OccurredAt DESC;" 2>&1
if ($auditMsg -notmatch 'LockHourCap=false') { Fail "Audit message missing LockHourCap=false: $auditMsg" }
OK "Audit row carries LockHourCap=false marker"

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
SqlCleanup
Write-Host ""
Write-Host "ALL PASS — Phase 6.1 schema + read path + POST default wired." -ForegroundColor Green
exit 0
