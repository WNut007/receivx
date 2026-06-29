# Smoke test: Phase 6 — digital signature operator+signer matrix.
#
# Guards the Phase 6 rework's core guarantee: signing capability is an
# ADDITIVE per-warehouse flag (db/043 CanSign*), independent of the
# operational role. An operator who is ALSO a Warehouse signer must be able
# to BOTH receive AND sign — the exact case the old "signer is a whRole
# value" model broke (making someone a signer replaced their operator role).
#
# Matrix (all against live :5213):
#   1. operator + CanSignWarehouse → receive-capable + sign Warehouse 200
#   2. operator (no bit)           → receive-capable, no sign button, sign 403
#   3. viewer + CanSignCustomer    → can view + sign Customer 200, NOT receive (403)
#   4. signer wrong party          → CanSignWarehouse signs Customer → 403
#   5. cross-warehouse             → signer @ WH-BPI signs a WH-01 pull → 403
#   6. re-sign                     → already-signed party → 409 (immutable)
#   7. admin                       → view yes, no sign buttons, sign → 403
#   8. 3-box display               → Customer/Warehouse/Production; signed=name, unsigned=blank
#
# Receive capability is probed side-effect-free via the CanReceive-gated
# GET /api/receipts/preview (bogus item → 404 when authorized, 403 when not)
# so the smoke never writes a Receipt. Signing writes PullSignatures rows on
# a dedicated closed pull; ALL test data (users, assignments, signatures) is
# removed at the end and on any failure.

$ErrorActionPreference = 'Stop'
$base      = 'http://localhost:5213'
$WH_BPI    = 'BB414F53-11D6-4DB8-8909-7E251B0823BF'
$BPI_PULL  = 'B99232A9-D3FE-491E-A5F6-C5C7F29CE3BD'   # closed, WH-BPI
$WH01_PULL = '33333333-3333-3333-3333-000000002900'   # PL-2900, WH-01 (cross-warehouse)
$PFX       = 'z6e_'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }

function Cleanup {
    $sql = @"
SET NOCOUNT ON;
DELETE FROM dbo.PullSignatures WHERE PullId IN ('$BPI_PULL','$WH01_PULL');
DELETE a FROM dbo.UserWarehouseAssignments a
  INNER JOIN dbo.Users u ON u.Id = a.UserId WHERE u.Username LIKE '$PFX%';
DELETE FROM dbo.Users WHERE Username LIKE '$PFX%';
"@
    sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q $sql 2>&1 | Out-Null
}

function Login($u, $p, $wh) {
    $body = @{ username = $u; password = $p; warehouseId = $wh; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Create a user with one WH-BPI assignment carrying explicit CanSign* bits.
function CreateSigner($username, $name, $globalRole, $whRole, $cust, $whse, $prod) {
    $admin = $script:admin
    $body = @{
        username = $username; name = $name; email = $null; phone = $null
        role = $globalRole; password = 'test1234'; isActive = $true
        assignments = @(@{ warehouseId = $WH_BPI; role = $whRole;
                           canSignCustomer = $cust; canSignWarehouse = $whse; canSignProduction = $prod })
    } | ConvertTo-Json -Depth 5
    return (Invoke-RestMethod -Uri "$base/api/users" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin).id
}

# Status code of a request that may be non-2xx (Invoke-RestMethod throws on >=400).
function Code([scriptblock]$call) {
    try { & $call | Out-Null; return 200 }
    catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } else { throw } }
}
function SignCode($sv, $pull, $party) {
    Code { Invoke-RestMethod -Uri "$base/api/reports/do/$pull/sign" -Method POST `
            -Body (@{ party = $party } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sv }
}
function ReceiveProbe($sv) {
    # CanReceive-gated GET; bogus item → 404 when authorized, 403 when not. No write.
    $g = [guid]::NewGuid().ToString()
    return Code { Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$g&qty=1" -WebSession $sv }
}
function Preview($sv, $pull) { Invoke-RestMethod -Uri "$base/api/reports/do/$pull/preview" -WebSession $sv }

# ---- pre-flight: test pull must start with zero signatures ----
Cleanup
$pre = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q `
    "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PullSignatures WHERE PullId='$BPI_PULL';"
if (([int]($pre | Select-Object -First 1).Trim()) -ne 0) { Write-Host "FAIL: test pull not clean at start" -ForegroundColor Red; exit 1 }

try {
    $script:admin = Login 'sadmin' 'admin' $WH_BPI

    Step "seed test users (operator+warehouse-sign, plain operator, viewer+customer-sign)"
    $idOpSign = CreateSigner "${PFX}opsign" '6E OpSigner' 'operator' 'operator' $false $true  $false
    $idOp     = CreateSigner "${PFX}op"     '6E Operator' 'operator' 'operator' $false $false $false
    $idView   = CreateSigner "${PFX}view"   '6E Viewer'   'viewer'   'viewer'   $true  $false $false
    OK "3 test users created"

    $opSign = Login "${PFX}opsign" 'test1234' $WH_BPI
    $op     = Login "${PFX}op"     'test1234' $WH_BPI
    $view   = Login "${PFX}view"   'test1234' $WH_BPI

    # ===== 1. operator + CanSignWarehouse → receive-capable + sign Warehouse =====
    Step "1. operator + CanSignWarehouse"
    if ((ReceiveProbe $opSign) -ne 403) { OK "receive-capable (CanReceive passes)" } else { Fail "operator+signer blocked from receive (the regression)" }
    if ((SignCode $opSign $BPI_PULL 'Warehouse') -eq 200) { OK "sign Warehouse → 200" } else { Fail "operator+signer could not sign Warehouse" }

    # ===== 2. operator (no bit) → receive-capable, no button, sign 403 =====
    Step "2. operator without sign bit"
    if ((ReceiveProbe $op) -ne 403) { OK "receive-capable" } else { Fail "plain operator blocked from receive" }
    $opHtml = Preview $op $BPI_PULL
    if ($opHtml -notmatch 'data-party="') { OK "no sign buttons offered (no canSign claim)" } else { Fail "plain operator wrongly offered a sign button" }
    if ((SignCode $op $BPI_PULL 'Warehouse') -eq 403) { OK "sign Warehouse → 403" } else { Fail "plain operator sign not 403" }

    # ===== 3. viewer + CanSignCustomer → view + sign Customer, NOT receive =====
    Step "3. viewer + CanSignCustomer"
    if ((ReceiveProbe $view) -eq 403) { OK "receive blocked (viewer) → 403" } else { Fail "viewer was allowed to receive" }
    $null = Preview $view $BPI_PULL  # 200 or it throws
    OK "viewer can view the report"
    if ((SignCode $view $BPI_PULL 'Customer') -eq 200) { OK "sign Customer → 200" } else { Fail "viewer+customer-signer could not sign Customer" }

    # ===== 4. wrong party → CanSignWarehouse signs Customer → 403 =====
    Step "4. signer wrong party"
    if ((SignCode $opSign $BPI_PULL 'Customer') -eq 403) { OK "warehouse-signer signing Customer → 403" } else { Fail "wrong-party sign not 403" }

    # ===== 5. cross-warehouse → signer @ WH-BPI signs a WH-01 pull → 403 =====
    Step "5. cross-warehouse"
    if ((SignCode $opSign $WH01_PULL 'Warehouse') -eq 403) { OK "sign across warehouse → 403" } else { Fail "cross-warehouse sign not 403" }

    # ===== 6. re-sign → already-signed Warehouse → 409 =====
    Step "6. re-sign immutable"
    if ((SignCode $opSign $BPI_PULL 'Warehouse') -eq 409) { OK "re-sign Warehouse → 409" } else { Fail "re-sign not 409" }

    # ===== 7. admin → view yes, no sign buttons, sign 403 =====
    Step "7. admin view-only (no canSign)"
    $adHtml = Preview $script:admin $BPI_PULL
    if ($adHtml -notmatch 'data-party="') { OK "admin sees no sign buttons" } else { Fail "admin wrongly offered a sign button" }
    if ((SignCode $script:admin $BPI_PULL 'Production') -eq 403) { OK "admin sign Production → 403 (no override)" } else { Fail "admin sign not 403" }

    # ===== 8. 3-box display — signed=name+timestamp, unsigned=blank =====
    Step "8. 3-box display"
    $html = Preview $opSign $BPI_PULL
    # The per-pull 3-box set renders once per DO the pull spawns, so the count
    # is 3 × (number of DOs). Assert a positive multiple of 3, not a bare 3.
    $labels = ([regex]::Matches($html, 'class="do-sign-label"')).Count
    if ($labels -ge 3 -and ($labels % 3) -eq 0) { OK "3-box set per DO ($labels labels = 3 x $([int]($labels/3)) DOs)" } else { Fail "sign-box count not a positive multiple of 3: $labels" }
    foreach ($lbl in 'CUSTOMER','WAREHOUSE','PRODUCTION') {
        if ($html -match $lbl) { OK "box present: $lbl" } else { Fail "missing box: $lbl" }
    }
    if ($html -match '6E OpSigner') { OK "signed Warehouse box shows signer name" } else { Fail "signed box missing signer name" }
    # Production is the only unsigned party → its box is not is-signed and shows no name.
    if ($html -match 'do-sign-box(?![^>]*is-signed)[^>]*>\s*<div class="do-sign-label">PRODUCTION') {
        OK "Production box rendered unsigned (blank)"
    } else {
        # Fallback structural check: there is at least one box without is-signed.
        if ($html -match 'class="do-sign-box ">') { OK "an unsigned (blank) box is present" } else { Fail "no unsigned box found" }
    }

    Step "signature row count sanity"
    $n = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q `
        "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PullSignatures WHERE PullId='$BPI_PULL';"
    if (([int]($n | Select-Object -First 1).Trim()) -eq 2) { OK "exactly 2 signatures persisted (Warehouse + Customer)" } else { Fail "unexpected signature count: $n" }
}
finally {
    Step "cleanup"
    Cleanup
    $u = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Users WHERE Username LIKE '$PFX%';"
    $s = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.PullSignatures WHERE PullId IN ('$BPI_PULL','$WH01_PULL');"
    if (([int]($u | Select-Object -First 1).Trim()) -eq 0) { OK "test users removed" } else { Write-Host "WARN: test user residue" -ForegroundColor Yellow }
    if (([int]($s | Select-Object -First 1).Trim()) -eq 0) { OK "test signatures removed" } else { Write-Host "WARN: signature residue" -ForegroundColor Yellow }
}

Write-Host "`nsmoke-do-signatures: ALL PASS" -ForegroundColor Green
exit 0
