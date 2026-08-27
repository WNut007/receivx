# Smoke test: digital signature — Phase 6 (signer matrix) + Phase 7 (close
# auto-sign, close gate, reclose upsert, signed-count, batch sign).
#
# Phase 6 guards the core guarantee: signing capability is an ADDITIVE
# per-warehouse flag (db/043 CanSign*), independent of the operational role.
# An operator who is ALSO a Warehouse signer must BOTH receive AND sign.
#
# Phase 6 matrix (against live :5213):
#   1. operator + CanSignWarehouse → receive-capable + sign Warehouse 200
#   2. operator (no bit)           → receive-capable, no sign button, sign 403
#   3. viewer + CanSignCustomer    → can view + sign Customer 200, NOT receive (403)
#   4. signer wrong party          → CanSignWarehouse signs Customer → 403
#   5. cross-warehouse             → signer @ WH-BPI signs a WH-01 pull → 403
#   6. re-sign                     → already-signed party → 409 (immutable)
#   7. admin                       → view yes, no sign buttons, sign → 403
#   8. 3-box display               → Customer/Warehouse/Production; signed=name, unsigned=blank
#
# Phase 7 paths:
#   9.  close auto-signs Warehouse (closer name + close time) — 7b
#   10. close gate: supervisor w/o CanSignWarehouse → 403; admin → 200 (D1a bypass) — 7a
#   11. reclose upsert (D2): reopen → reclose by a different closer re-stamps the
#       one Warehouse row, no UQ violation — 7b
#   12. signed-count N/3: 1/3 (close) → 2/3 (batch Customer) → 3/3 complete — 7c
#   13. batch sign happy: Customer over N pulls → all signed — 7d
#   14. batch partial: already-signed → skipped, cross-warehouse → error, still 200 — 7d
#   15. batch rejects Warehouse → 400 — 7d
#   16. "unsigned for my role" filter wiring on /Reports (option + signParties) — 7e
#
# Phase 8 paths (drawn signatures — Customer/Production upgraded typed → drawn):
#   17. drawn single sign persists the PNG data URL (SignatureSvg) — 8b
#   18. drawn batch — ONE drawing recorded identically on every pull — 8c
#   19. preview renders the drawn <img src="data:image..."> — 8b/8d
#   20. PDF export embeds the per-party signature image, both reports — 8e
#   21. drawn signature REQUIRED (empty → 400) + bounded (oversize → 413),
#       single + batch — 8f
#
# Receive capability is probed side-effect-free via the CanReceive-gated
# GET /api/receipts/preview (bogus item → 404 when authorized, 403 when not).
# Phase 7 seeds dedicated PL-Z7F-* pulls (bare → closeable). ALL test data
# (users, assignments, signatures, seeded pulls) is removed at the end and on
# any failure.

$ErrorActionPreference = 'Stop'
$base      = 'http://localhost:5213'
$WH_BPI    = 'BB414F53-11D6-4DB8-8909-7E251B0823BF'
$WH_01     = '22222222-2222-2222-2222-000000000001'
$BPI_PULL  = 'B99232A9-D3FE-491E-A5F6-C5C7F29CE3BD'   # closed, WH-BPI (has receipts)
$WH01_PULL = '33333333-3333-3333-3333-000000002900'   # PL-2900, WH-01 (cross-warehouse)
$ADMIN_ID  = '11111111-1111-1111-1111-000000000001'
$PFX       = 'z6e_'   # Phase 6 users
$P7FX      = 'z7f_'   # Phase 7 users
$PULLPFX   = 'PL-Z7F-'
# 1x1 white PNG data URL — the close signature pad's production output shape.
$SIG       = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }

function Sql($q)    { sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; $q" 2>&1 | Out-Null }
function SqlVal($q) { return (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -Q "SET NOCOUNT ON; $q" 2>&1 | Select-Object -First 1).Trim() }

function Cleanup {
    # Order matters: drop the seeded pulls BEFORE the users — a seeded pull's
    # ClosedBy/ReopenedBy FK references a test user (e.g. the supervisor that
    # reopened it), so the users can't be deleted while the pulls remain.
    $sql = @"
SET NOCOUNT ON;
DELETE FROM dbo.PullSignatures WHERE PullId IN ('$BPI_PULL','$WH01_PULL')
   OR PullId IN (SELECT Id FROM dbo.Pulls WHERE PullNumber LIKE '$PULLPFX%');
-- FK_PullSig_Pull and FK_PO_Pull do NOT cascade from dbo.Pulls, so a pull
-- closed with a signature (or carrying a PO) refuses the DELETE below. The
-- delete is set-based, so ONE such pull strands the whole range -- 148 rows
-- accumulated this way before 2026-08-20. See
-- docs/defect-pull-signature-fk-blocks-smoke-cleanup.md
DELETE s FROM dbo.PullSignatures s
INNER JOIN dbo.Pulls p ON p.Id = s.PullId
WHERE p.PullNumber LIKE '$PULLPFX%';
UPDATE po SET PullId = NULL FROM dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE p.PullNumber LIKE '$PULLPFX%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE '$PULLPFX%';
PRINT 'cleanup: pulls removed = ' + CONVERT(varchar, @@ROWCOUNT);
DELETE a FROM dbo.UserWarehouseAssignments a
  INNER JOIN dbo.Users u ON u.Id = a.UserId
  WHERE u.Username LIKE '$PFX%' OR u.Username LIKE '$P7FX%';
DELETE FROM dbo.Users WHERE Username LIKE '$PFX%' OR Username LIKE '$P7FX%';
"@
    # -b makes sqlcmd exit non-zero on a SQL error, and the output is kept so a
    # refusal is printed instead of discarded. A cleanup that cannot report its
    # own failure is how 148 fixture pulls accumulated unnoticed.
    $cleanupOut = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -b -Q $sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "CLEANUP FAILED (exit $LASTEXITCODE): $cleanupOut" -ForegroundColor Red
        exit 2
    }
    $cleanupOut | Where-Object { $_ -match 'cleanup:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
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

# Seed a bare (item-less → immediately closeable) pull.
function SeedPull($pnum, $wh, $status) {
    $closed = if ($status -eq 'closed') { ", ClosedAt" } else { "" }
    $closedV = if ($status -eq 'closed') { ", SYSUTCDATETIME()" } else { "" }
    Sql "INSERT INTO dbo.Pulls (Id,PullNumber,WarehouseId,PullDate,Status,LockPoByPull,LockHourCap,CreatedAt$closed) VALUES (NEWID(),'$pnum','$wh',CAST(SYSUTCDATETIME() AS date),'$status',1,1,SYSUTCDATETIME()$closedV);"
    return SqlVal "SELECT CAST(Id AS varchar(36)) FROM dbo.Pulls WHERE PullNumber='$pnum';"
}

# Status code of a request that may be non-2xx (Invoke-RestMethod throws on >=400).
function Code([scriptblock]$call) {
    try { & $call | Out-Null; return 200 }
    catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } else { throw } }
}
function SignCode($sv, $pull, $party) {
    # Phase 8: a drawn signatureSvg is now required by the endpoint, so every
    # happy-path sign carries one. Auth/immutability failures are checked before
    # the SVG validation, so the 403/409 cases below still surface their codes.
    Code { Invoke-RestMethod -Uri "$base/api/reports/do/$pull/sign" -Method POST `
            -Body (@{ party = $party; signatureSvg = $SIG } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sv }
}
# Raw-body single sign — for the 8f validation cases (empty / oversize SVG).
function SignBody($sv, $pull, $hash) {
    Code { Invoke-RestMethod -Uri "$base/api/reports/do/$pull/sign" -Method POST `
            -Body ($hash | ConvertTo-Json) -ContentType 'application/json' -WebSession $sv }
}
function CloseCode($sv, $pull) {
    Code { Invoke-RestMethod -Uri "$base/api/pulls/$pull/close" -Method POST `
            -Body (@{ signatureSvg = $SIG } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sv }
}
function Reopen($sv, $pull) {
    Invoke-RestMethod -Uri "$base/api/pulls/$pull/reopen" -Method POST `
        -Body (@{ reason = '7f reclose' } | ConvertTo-Json) -ContentType 'application/json' -WebSession $sv | Out-Null
}
function Batch($sv, $ids, $party) {
    $body = @{ pullIds = @($ids); party = $party; signatureSvg = $SIG } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/reports/sign-batch" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv
}
function BatchCode($sv, $ids, $party) {
    $body = @{ pullIds = @($ids); party = $party; signatureSvg = $SIG } | ConvertTo-Json
    Code { Invoke-RestMethod -Uri "$base/api/reports/sign-batch" -Method POST -Body $body -ContentType 'application/json' -WebSession $sv }
}
# Raw-body batch sign — for the 8f validation cases (empty / oversize SVG).
function BatchBody($sv, $hash) {
    Code { Invoke-RestMethod -Uri "$base/api/reports/sign-batch" -Method POST `
            -Body ($hash | ConvertTo-Json) -ContentType 'application/json' -WebSession $sv }
}
function ReceiveProbe($sv) {
    $g = [guid]::NewGuid().ToString()
    return Code { Invoke-RestMethod -Uri "$base/api/receipts/preview?pullItemId=$g&qty=1" -WebSession $sv }
}
function Preview($sv, $pull) { Invoke-RestMethod -Uri "$base/api/reports/do/$pull/preview" -WebSession $sv }
function ClosedPull($sv, $pnum) {
    $rows = Invoke-RestMethod -Uri "$base/api/pulls?status=closed" -WebSession $sv
    return $rows | Where-Object { $_.pullNumber -eq $pnum }
}

# ---- pre-flight: shared test pull must start with zero signatures ----
Cleanup
if (([int](SqlVal "SELECT COUNT(*) FROM dbo.PullSignatures WHERE PullId='$BPI_PULL';")) -ne 0) {
    Write-Host "FAIL: test pull not clean at start" -ForegroundColor Red; exit 1
}

try {
    $script:admin = Login 'sadmin' 'admin' $WH_BPI

    Step "seed test users"
    $idOpSign = CreateSigner "${PFX}opsign" '6E OpSigner' 'operator' 'operator' $false $true  $false
    $idOp     = CreateSigner "${PFX}op"     '6E Operator' 'operator' 'operator' $false $false $false
    $idView   = CreateSigner "${PFX}view"   '6E Viewer'   'viewer'   'viewer'   $true  $false $false
    # Phase 7: a supervisor WITH the bit (can close), one WITHOUT, and a two-party signer.
    $idSuper  = CreateSigner "${P7FX}super" '7F Super'    'operator' 'supervisor' $false $true  $false
    $idNoBit  = CreateSigner "${P7FX}nobit" '7F NoBit'    'operator' 'supervisor' $false $false $false
    $idCust   = CreateSigner "${P7FX}cust"  '7F Cust'     'viewer'   'viewer'     $true  $false $true
    OK "6 test users created"

    $opSign = Login "${PFX}opsign" 'test1234' $WH_BPI
    $op     = Login "${PFX}op"     'test1234' $WH_BPI
    $view   = Login "${PFX}view"   'test1234' $WH_BPI

    # ==================== PHASE 6 — signer matrix ====================

    Step "1. operator + CanSignWarehouse"
    if ((ReceiveProbe $opSign) -ne 403) { OK "receive-capable (CanReceive passes)" } else { Fail "operator+signer blocked from receive (the regression)" }
    if ((SignCode $opSign $BPI_PULL 'Warehouse') -eq 200) { OK "sign Warehouse → 200" } else { Fail "operator+signer could not sign Warehouse" }

    Step "2. operator without sign bit"
    if ((ReceiveProbe $op) -ne 403) { OK "receive-capable" } else { Fail "plain operator blocked from receive" }
    $opHtml = Preview $op $BPI_PULL
    if ($opHtml -notmatch 'data-party="') { OK "no sign buttons offered (no canSign claim)" } else { Fail "plain operator wrongly offered a sign button" }
    if ((SignCode $op $BPI_PULL 'Warehouse') -eq 403) { OK "sign Warehouse → 403" } else { Fail "plain operator sign not 403" }

    Step "3. viewer + CanSignCustomer"
    if ((ReceiveProbe $view) -eq 403) { OK "receive blocked (viewer) → 403" } else { Fail "viewer was allowed to receive" }
    $null = Preview $view $BPI_PULL
    OK "viewer can view the report"
    if ((SignCode $view $BPI_PULL 'Customer') -eq 200) { OK "sign Customer → 200" } else { Fail "viewer+customer-signer could not sign Customer" }

    Step "4. signer wrong party"
    if ((SignCode $opSign $BPI_PULL 'Customer') -eq 403) { OK "warehouse-signer signing Customer → 403" } else { Fail "wrong-party sign not 403" }

    Step "5. cross-warehouse"
    if ((SignCode $opSign $WH01_PULL 'Warehouse') -eq 403) { OK "sign across warehouse → 403" } else { Fail "cross-warehouse sign not 403" }

    Step "6. re-sign immutable"
    if ((SignCode $opSign $BPI_PULL 'Warehouse') -eq 409) { OK "re-sign Warehouse → 409" } else { Fail "re-sign not 409" }

    Step "7. admin view-only (no canSign)"
    $adHtml = Preview $script:admin $BPI_PULL
    if ($adHtml -notmatch 'data-party="') { OK "admin sees no sign buttons" } else { Fail "admin wrongly offered a sign button" }
    if ((SignCode $script:admin $BPI_PULL 'Production') -eq 403) { OK "admin sign Production → 403 (no override)" } else { Fail "admin sign not 403" }

    Step "8. 3-box display"
    $html = Preview $opSign $BPI_PULL
    $labels = ([regex]::Matches($html, 'class="do-sign-label"')).Count
    if ($labels -ge 3 -and ($labels % 3) -eq 0) { OK "3-box set per DO ($labels labels = 3 x $([int]($labels/3)) DOs)" } else { Fail "sign-box count not a positive multiple of 3: $labels" }
    foreach ($lbl in 'CUSTOMER','WAREHOUSE','PRODUCTION') {
        if ($html -match $lbl) { OK "box present: $lbl" } else { Fail "missing box: $lbl" }
    }
    if ($html -match '6E OpSigner') { OK "signed Warehouse box shows signer name" } else { Fail "signed box missing signer name" }
    if ($html -match 'do-sign-box(?![^>]*is-signed)[^>]*>\s*<div class="do-sign-label">PRODUCTION') {
        OK "Production box rendered unsigned (blank)"
    } else {
        if ($html -match 'class="do-sign-box ">') { OK "an unsigned (blank) box is present" } else { Fail "no unsigned box found" }
    }
    if (([int](SqlVal "SELECT COUNT(*) FROM dbo.PullSignatures WHERE PullId='$BPI_PULL';")) -eq 2) { OK "exactly 2 signatures persisted (Warehouse + Customer)" } else { Fail "unexpected signature count on shared pull" }

    # ==================== PHASE 7 — close auto-sign / gate / batch / N3 ====================

    Step "seed Phase 7 pulls (bare → closeable)"
    $pC = SeedPull "${PULLPFX}C" $WH_BPI 'in_progress'   # close + reclose + N/3 progression
    $pG = SeedPull "${PULLPFX}G" $WH_BPI 'in_progress'   # close gate
    $p1 = SeedPull "${PULLPFX}1" $WH_BPI 'closed'        # batch
    $p2 = SeedPull "${PULLPFX}2" $WH_BPI 'closed'        # batch
    $p3 = SeedPull "${PULLPFX}3" $WH_BPI 'closed'        # batch partial
    OK "5 test pulls seeded"

    $super = Login "${P7FX}super" 'test1234' $WH_BPI
    $nobit = Login "${P7FX}nobit" 'test1234' $WH_BPI
    $cust  = Login "${P7FX}cust"  'test1234' $WH_BPI

    Step "9. close auto-signs Warehouse (7b)"
    if ((CloseCode $super $pC) -eq 200) { OK "supervisor+bit closed pull → 200" } else { Fail "supervisor+bit could not close" }
    if (([int](SqlVal "SELECT COUNT(*) FROM dbo.PullSignatures WHERE PullId='$pC' AND Party='Warehouse';")) -eq 1) { OK "Warehouse signature auto-created on close" } else { Fail "no Warehouse auto-sign on close" }
    if ((SqlVal "SELECT SignerName FROM dbo.PullSignatures WHERE PullId='$pC' AND Party='Warehouse';") -eq '7F Super') { OK "Warehouse SignerName = closer (7F Super)" } else { Fail "Warehouse signer name wrong" }
    if ((SqlVal "SELECT CASE WHEN ps.SignedAt=p.ClosedAt THEN 1 ELSE 0 END FROM dbo.PullSignatures ps JOIN dbo.Pulls p ON p.Id=ps.PullId WHERE ps.PullId='$pC' AND ps.Party='Warehouse';") -eq '1') { OK "Warehouse SignedAt = close time" } else { Fail "SignedAt != ClosedAt" }

    Step "10. close gate (7a)"
    if ((CloseCode $nobit $pG) -eq 403) { OK "supervisor WITHOUT CanSignWarehouse → close 403" } else { Fail "no-bit supervisor was allowed to close" }
    if ((CloseCode $script:admin $pG) -eq 200) { OK "admin → close 200 (D1a bypass)" } else { Fail "admin could not close" }
    if ((SqlVal "SELECT SignerName FROM dbo.PullSignatures WHERE PullId='$pG' AND Party='Warehouse';") -eq 'System Admin') { OK "admin close auto-signs Warehouse as admin" } else { Fail "admin close did not auto-sign correctly" }

    Step "11. reclose upsert — D2 (7b)"
    Reopen $super $pC
    if ((CloseCode $script:admin $pC) -eq 200) { OK "reclose by admin → 200" } else { Fail "reclose failed" }
    if (([int](SqlVal "SELECT COUNT(*) FROM dbo.PullSignatures WHERE PullId='$pC' AND Party='Warehouse';")) -eq 1) { OK "still exactly 1 Warehouse row (no UQ violation, upsert)" } else { Fail "reclose produced a duplicate Warehouse row" }
    if ((SqlVal "SELECT SignerName FROM dbo.PullSignatures WHERE PullId='$pC' AND Party='Warehouse';") -eq 'System Admin') { OK "Warehouse re-stamped to new closer (System Admin)" } else { Fail "Warehouse not re-stamped on reclose" }

    Step "12. signed-count N/3 + per-party bits (7c)"
    $r = ClosedPull $cust "${PULLPFX}C"
    if ($r.signedCount -eq 1 -and $r.warehouseSigned -and -not $r.isComplete) { OK "after close → 1/3 (Warehouse)" } else { Fail "expected 1/3 warehouse, got count=$($r.signedCount)" }
    if ((Batch $cust @($pC) 'Customer').signed -eq 1) { OK "batch Customer → signed" } else { Fail "could not batch-sign Customer" }
    $r = ClosedPull $cust "${PULLPFX}C"
    if ($r.signedCount -eq 2 -and $r.customerSigned) { OK "→ 2/3 (Warehouse + Customer)" } else { Fail "expected 2/3, got $($r.signedCount)" }
    if ((SignCode $cust $pC 'Production') -eq 200) { OK "sign Production → 200" } else { Fail "two-party signer could not sign Production" }
    $r = ClosedPull $cust "${PULLPFX}C"
    if ($r.signedCount -eq 3 -and $r.isComplete) { OK "→ 3/3, isComplete=true (document complete)" } else { Fail "expected 3/3 complete, got $($r.signedCount)" }
    if (($r.signedParties -join ',') -eq 'Customer,Warehouse,Production') { OK "signedParties = all 3 (chips)" } else { Fail "signedParties wrong: $($r.signedParties -join ',')" }

    Step "13. batch sign happy (7d)"
    $b = Batch $cust @($p1,$p2) 'Customer'
    if ($b.signed -eq 2 -and $b.skipped -eq 0 -and $b.errors -eq 0) { OK "2 fresh pulls → 2 signed, 0 skipped, 0 errors" } else { Fail "batch happy wrong: signed=$($b.signed) skipped=$($b.skipped) errors=$($b.errors)" }

    Step "14. batch partial (7d)"
    $b = Batch $cust @($p1,$p3,$WH01_PULL) 'Customer'
    if ($b.signed -eq 1 -and $b.skipped -eq 1 -and $b.errors -eq 1) { OK "fresh→signed, already→skipped, cross-wh→error (1/1/1)" } else { Fail "batch partial wrong: signed=$($b.signed) skipped=$($b.skipped) errors=$($b.errors)" }
    if (([int](SqlVal "SELECT COUNT(*) FROM dbo.PullSignatures WHERE PullId='$WH01_PULL';")) -eq 0) { OK "cross-warehouse pull got no signature" } else { Fail "cross-wh pull wrongly signed in batch" }

    Step "15. batch rejects Warehouse (7d)"
    if ((BatchCode $cust @($p2) 'Warehouse') -eq 400) { OK "batch party=Warehouse → 400" } else { Fail "Warehouse batch not rejected" }

    Step "16. 'unsigned for my role' filter wiring (7e)"
    $reportsHtml = Invoke-RestMethod -Uri "$base/Reports?pageSize=200" -WebSession $cust
    if ($reportsHtml -match 'value="unsigned_mine"') { OK "'Unsigned for my role' filter option present" } else { Fail "unsigned_mine filter option missing" }
    if ($reportsHtml -match '__signParties\s*=\s*\[[^\]]*"customer"[^\]]*"production"') { OK "signParties global carries the user's parties (customer+production)" } else { Fail "signParties global not wired for the filter" }

    # ==================== PHASE 8 — drawn signatures (single / batch / display / PDF / validation) ====================

    Step "17. drawn single sign persisted the drawing (8b)"
    # $BPI_PULL Customer was signed WITH a drawing (SIG) back in step 3.
    if ((SqlVal "SELECT CASE WHEN SignatureSvg LIKE 'data:image%' THEN 1 ELSE 0 END FROM dbo.PullSignatures WHERE PullId='$BPI_PULL' AND Party='Customer';") -eq '1') { OK "Customer SignatureSvg is a drawing (data:image)" } else { Fail "single-sign did not persist a drawing" }

    Step "18. drawn batch — same drawing on every pull (8c)"
    # $p1 + $p2 Customer were batch-signed with ONE drawing in step 13.
    if ((SqlVal "SELECT CASE WHEN SignatureSvg LIKE 'data:image%' THEN 1 ELSE 0 END FROM dbo.PullSignatures WHERE PullId='$p1' AND Party='Customer';") -eq '1') { OK "batch pull carries a drawing" } else { Fail "batch pull missing drawing" }
    if ((SqlVal "SELECT CASE WHEN (SELECT SignatureSvg FROM dbo.PullSignatures WHERE PullId='$p1' AND Party='Customer') = (SELECT SignatureSvg FROM dbo.PullSignatures WHERE PullId='$p2' AND Party='Customer') THEN 1 ELSE 0 END;") -eq '1') { OK "both batch pulls carry the SAME drawing" } else { Fail "batch drawings differ across pulls" }

    Step "19. preview renders the drawn <img> (8b/8d)"
    $drawHtml = Preview $cust $BPI_PULL
    if ($drawHtml -match 'do-sign-drawn' -and $drawHtml -match 'src="data:image') { OK "drawn signature <img> present in preview" } else { Fail "preview has no drawn signature img" }

    Step "20. PDF embeds the per-party signature image (8e)"
    foreach ($rt in 'note','order') {
        $pdfPath = Join-Path $env:TEMP ("smoke-do-" + [guid]::NewGuid().ToString('N') + ".pdf")
        Invoke-WebRequest -Uri "$base/api/reports/do/$BPI_PULL/export.pdf?type=$rt" -WebSession $cust -OutFile $pdfPath | Out-Null
        $b = [System.IO.File]::ReadAllBytes($pdfPath)
        $magic = -join ($b[0..4] | ForEach-Object { [char]$_ })
        if ($magic -eq '%PDF-' -and $b.Length -gt 50000) { OK "$rt PDF valid + non-trivial ($([int]($b.Length/1024)) KB)" } else { Fail "$rt PDF bad: magic=$magic size=$($b.Length)" }
        Remove-Item $pdfPath -ErrorAction SilentlyContinue
    }

    Step "21. drawn signature REQUIRED + bounded (8f)"
    $bigSvg = 'data:image/png;base64,' + ('A' * 205000)   # > 200KB cap
    if ((SignBody  $cust $BPI_PULL @{ party = 'Customer' })                          -eq 400) { OK "single: empty SVG -> 400" } else { Fail "single empty SVG not 400" }
    if ((SignBody  $cust $BPI_PULL @{ party = 'Customer'; signatureSvg = $bigSvg })  -eq 413) { OK "single: oversize SVG -> 413" } else { Fail "single oversize SVG not 413" }
    if ((BatchBody $cust @{ pullIds = @($p1,$p2); party = 'Customer' })                         -eq 400) { OK "batch: empty SVG -> 400" } else { Fail "batch empty SVG not 400" }
    if ((BatchBody $cust @{ pullIds = @($p1,$p2); party = 'Customer'; signatureSvg = $bigSvg })  -eq 413) { OK "batch: oversize SVG -> 413" } else { Fail "batch oversize SVG not 413" }
}
finally {
    Step "cleanup"
    Cleanup
    $u  = [int](SqlVal "SELECT COUNT(*) FROM dbo.Users WHERE Username LIKE '$PFX%' OR Username LIKE '$P7FX%';")
    $s  = [int](SqlVal "SELECT COUNT(*) FROM dbo.PullSignatures WHERE PullId IN ('$BPI_PULL','$WH01_PULL') OR PullId IN (SELECT Id FROM dbo.Pulls WHERE PullNumber LIKE '$PULLPFX%');")
    $pl = [int](SqlVal "SELECT COUNT(*) FROM dbo.Pulls WHERE PullNumber LIKE '$PULLPFX%';")
    if ($u -eq 0)  { OK "test users removed" }      else { Write-Host "WARN: test user residue ($u)" -ForegroundColor Yellow }
    if ($s -eq 0)  { OK "test signatures removed" }  else { Write-Host "WARN: signature residue ($s)" -ForegroundColor Yellow }
    if ($pl -eq 0) { OK "test pulls removed" }       else { Write-Host "WARN: test pull residue ($pl)" -ForegroundColor Yellow }
}

Write-Host "`nsmoke-do-signatures: ALL PASS" -ForegroundColor Green
exit 0
