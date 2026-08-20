# Smoke: db/047 §2c — preview and confirm must agree
#
# "A preview that promises more than confirm delivers is the same defect wearing
# a different hat." GET /api/receipts/preview and POST /api/receipts must apply
# the identical rule and return the identical status AND code for every input.
#
# Matrix: {below, exactly, above outstanding} x {variance off, on}
#         x {LockHourCap false, true}
# plus the three quantities the quick-fill buttons produce (§2e):
#         FILL OUTSTANDING (= exact), HALF (= below), MARK ZERO (= 0).
#
# Preview is read-only, so each case previews first and then confirms against
# the SAME fixture and compares the two outcomes.
#
# Note on the quick-fill cases: this asserts the SERVER agrees for the
# quantities those buttons produce. The client-side half of §2e — the buttons
# dispatching a real `input` event so the preview actually re-runs — is a UI
# change and is covered in the UI pass.
#
# Assumes ReceivingOps.Web on http://localhost:5213 and db/047 applied.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

$script:pass = 0
$script:fail = 0
function OK($m)  { Write-Host "  PASS: $m" -ForegroundColor Green; $script:pass++ }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red;   $script:fail++ }

function Cleanup {
    $q = @'
DELETE r FROM dbo.Receipts r
INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'PL-PCA-%';
-- FK_PullSig_Pull and FK_PO_Pull do NOT cascade from dbo.Pulls, so a pull
-- closed with a signature (or carrying a PO) refuses the DELETE below. The
-- delete is set-based, so ONE such pull strands the whole range -- 148 rows
-- accumulated this way before 2026-08-20. See
-- docs/defect-pull-signature-fk-blocks-smoke-cleanup.md
DELETE s FROM dbo.PullSignatures s
INNER JOIN dbo.Pulls p ON p.Id = s.PullId
WHERE p.PullNumber LIKE 'PL-PCA-%';
UPDATE po SET PullId = NULL FROM dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE p.PullNumber LIKE 'PL-PCA-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'PL-PCA-%';
PRINT 'cleanup: pulls removed = ' + CONVERT(varchar, @@ROWCOUNT);
DELETE pol FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'PO-PCA-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'PO-PCA-%';
'@
    # -b makes sqlcmd exit non-zero on a SQL error, and the output is kept so a
    # refusal is printed instead of discarded. A cleanup that cannot report its
    # own failure is how 148 fixture pulls accumulated unnoticed.
    $cleanupOut = sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -I -h -1 -W -b -Q $q 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "CLEANUP FAILED (exit $LASTEXITCODE): $cleanupOut" -ForegroundColor Red
        exit 2
    }
    $cleanupOut | Where-Object { $_ -match 'cleanup:' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -ContentType 'application/json' -SessionVariable sv `
    -Body (@{ username='sadmin'; password='admin'; warehouseId=$WH_01; remember=$false } | ConvertTo-Json) | Out-Null

function NewFixture($lockHourCap, $expected = 1000) {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString().Substring(7)
    Invoke-RestMethod -Uri "$base/api/pos" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        poNumber="PO-PCA-$stamp"; warehouseId=$WH_01; orderDate=(Get-Date -Format 'yyyy-MM-dd')
        expectedDate=$null; notes='pca'; pullId=$null
        lines=@(@{ lineNumber=1; itemCode='SUMMARY'; description='pca'; orderedQty=100000 })
    } | ConvertTo-Json -Depth 5) | Out-Null

    $pullNum = "PL-PCA-$stamp"
    $p = Invoke-RestMethod -Uri "$base/api/pulls" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        pullNumber=$pullNum; warehouseId=$WH_01; pullDate=(Get-Date -Format 'yyyy-MM-dd')
        eta=$null; notes=$null; lockPoByPull=$false; lockHourCap=$lockHourCap
    } | ConvertTo-Json)
    $i = Invoke-RestMethod -Uri "$base/api/pulls/$($p.id)/items" -Method POST -ContentType 'application/json' -WebSession $sv -Body (@{
        itemCode='SUMMARY'; description='pca'; windows=@(@{ hourOfDay=10; expectedQty=$expected })
    } | ConvertTo-Json -Depth 5)
    [pscustomobject]@{ PullNumber=$pullNum; ItemId=$i.id }
}

# Returns @{ Status; Code } for either verb — 200 with Code=$null on success.
function CallPreview($itemId, $qty, $variance) {
    try {
        Invoke-RestMethod -WebSession $sv -Method GET `
            -Uri "$base/api/receipts/preview?pullItemId=$itemId&qty=$qty&hour=10&varianceAccepted=$($variance.ToString().ToLower())" | Out-Null
        return [pscustomobject]@{ Status=200; Code=$null }
    } catch {
        $s=[int]$_.Exception.Response.StatusCode; $c=$null
        if ($_.ErrorDetails.Message) { try { $c = ($_.ErrorDetails.Message | ConvertFrom-Json).code } catch {} }
        return [pscustomobject]@{ Status=$s; Code=$c }
    }
}
function CallConfirm($itemId, $qty, $variance) {
    $body = @{ pullItemId=$itemId; hourOfDay=10; qty=$qty; lotBatch=$null; palletId=$null
               binLocation=$null; qcStatus='pending'; note='agreement smoke'; varianceAccepted=$variance
               varianceReasonCode = $(if ($variance) { 'COUNT_MISMATCH' } else { $null }) } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -ContentType 'application/json' -WebSession $sv -Body $body | Out-Null
        return [pscustomobject]@{ Status=200; Code=$null }
    } catch {
        $s=[int]$_.Exception.Response.StatusCode; $c=$null
        if ($_.ErrorDetails.Message) { try { $c = ($_.ErrorDetails.Message | ConvertFrom-Json).code } catch {} }
        return [pscustomobject]@{ Status=$s; Code=$c }
    }
}

function Agree($label, $lockHourCap, $qty, $variance) {
    $f = NewFixture $lockHourCap
    $p = CallPreview $f.ItemId $qty $variance
    $c = CallConfirm $f.ItemId $qty $variance
    if ($p.Status -eq $c.Status -and $p.Code -eq $c.Code) {
        OK ("{0,-52} preview={1}/{2} confirm={3}/{4}" -f $label, $p.Status, ($p.Code ?? '-'), $c.Status, ($c.Code ?? '-'))
    } else {
        Bad ("{0,-52} DISAGREE preview={1}/{2} confirm={3}/{4}" -f $label, $p.Status, ($p.Code ?? '-'), $c.Status, ($c.Code ?? '-'))
    }
}

Cleanup

foreach ($lock in @($false, $true)) {
    $tag = if ($lock) { 'LOCKED' } else { 'loose ' }
    Write-Host "`n=== LockHourCap = $lock ===" -ForegroundColor Cyan

    Agree "$tag below outstanding,   variance off"  $lock 400  $false
    Agree "$tag below outstanding,   variance ON"   $lock 400  $true
    Agree "$tag exactly outstanding, variance off"  $lock 1000 $false
    Agree "$tag exactly outstanding, variance ON"   $lock 1000 $true
    Agree "$tag above outstanding,   variance off"  $lock 1500 $false
    Agree "$tag above outstanding,   variance ON"   $lock 1500 $true

    # §2e — the three quantities the quick-fill buttons produce.
    Agree "$tag quick-fill FILL OUTSTANDING (=1000)" $lock 1000 $false
    Agree "$tag quick-fill HALF (=500)"              $lock 500  $false
    Agree "$tag quick-fill MARK ZERO, variance off"  $lock 0    $false
    Agree "$tag quick-fill MARK ZERO, variance ON"   $lock 0    $true
}

Cleanup
Write-Host ""
if ($script:fail -eq 0) {
    Write-Host "ALL PASS — $($script:pass) preview/confirm pairs agree." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED — $($script:fail) disagreed, $($script:pass) agreed." -ForegroundColor Red
    exit 1
}
