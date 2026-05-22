# Spot-verify (1): concurrent receivers — 3 trials, raw numbers.
#
# Each trial:
#   - 3 child PS jobs fire POST /api/receipts on the same PullItem concurrently
#   - capture (qty requested, HTTP status, receipt id) per job
#   - measure SUM(Receipts.QtyReceived) for that PullItem before/after
#   - assert: (SUM after - SUM before) == sum of qtys from jobs that returned 200
#   - cleanup: cancel all receipts from the trial

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH01 = '22222222-2222-2222-2222-000000000001'
$pcbaItem = '44444444-4444-4444-2847-000000000001'   # PL-2847 PCBA-AX450-R2

function Q($sql) {
    (sqlcmd -S LAPTOP-CSB3KO3E -E -C -d ReceivingOps -h -1 -W -Q "SET NOCOUNT ON; $sql" 2>&1 | Out-String).Trim()
}

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

$adm = Login 'sadmin' 'admin' $WH01

$qtysPerTrial = @(50, 75, 100)
$cancelBody = @{ reason='other'; note='spot-verify-1 cleanup' } | ConvertTo-Json

for ($trial = 1; $trial -le 3; $trial++) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host " TRIAL $trial " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan

    # Truth source: SUM(Receipts.QtyReceived) net of reversals — invariant we're testing
    $sumBefore = [int](Q "SELECT ISNULL(SUM(QtyReceived),0) FROM dbo.Receipts WHERE PullItemId='$pcbaItem';")
    Write-Host "  Pre-trial SUM(QtyReceived) on PullItem = $sumBefore"

    # Launch 3 jobs in parallel — each does its own login then POST /api/receipts
    Write-Host "  Launching 3 concurrent jobs (qtys: $($qtysPerTrial -join ', '))..."
    $jobs = $qtysPerTrial | ForEach-Object {
        $q = $_
        Start-Job -ScriptBlock {
            param($base, $WH01, $pcbaItem, $q, $trial)
            $body = @{ username='sadmin'; password='admin'; warehouseId=$WH01; remember=$false } | ConvertTo-Json
            $sv = $null
            try {
                Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
                $recvBody = @{ pullItemId=$pcbaItem; hourOfDay=10; qty=$q; note="spot1-trial$trial-q$q" } | ConvertTo-Json
                $resp = Invoke-WebRequest -Uri "$base/api/receipts" -Method POST -Body $recvBody -ContentType 'application/json' -WebSession $sv
                $body = $resp.Content | ConvertFrom-Json
                return @{
                    qty        = $q
                    httpStatus = [int]$resp.StatusCode
                    receiptIds = @($body.allocations | ForEach-Object { $_.receiptId })
                    totalQty   = $body.totalQty
                    error      = $null
                }
            } catch {
                $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode.value__ } else { 0 }
                return @{
                    qty        = $q
                    httpStatus = $code
                    receiptIds = @()
                    totalQty   = 0
                    error      = $_.Exception.Message
                }
            }
        } -ArgumentList $base, $WH01, $pcbaItem, $q, $trial
    }
    $results = $jobs | Wait-Job -Timeout 30 | Receive-Job
    $jobs | Remove-Job -Force

    Write-Host ""
    Write-Host "  Job results:"
    foreach ($r in $results) {
        $recipts = if ($r.receiptIds.Count -gt 0) { ($r.receiptIds -join ',') } else { '(none)' }
        Write-Host ("    qty={0,-4} HTTP={1,-3} totalQty={2,-4} receipts=[{3}]" -f $r.qty, $r.httpStatus, $r.totalQty, $recipts)
        if ($r.error) { Write-Host ("                 error: $($r.error)") -ForegroundColor DarkYellow }
    }

    $successQtySum = ($results | Where-Object { $_.httpStatus -eq 200 } | Measure-Object -Property qty -Sum).Sum
    if (-not $successQtySum) { $successQtySum = 0 }

    $sumAfter = [int](Q "SELECT ISNULL(SUM(QtyReceived),0) FROM dbo.Receipts WHERE PullItemId='$pcbaItem';")
    $dbDelta = $sumAfter - $sumBefore

    Write-Host ""
    Write-Host "  SUM(qty) over jobs with HTTP=200 : $successQtySum"
    Write-Host "  DB SUM delta (after - before)     : $dbDelta"
    Write-Host "  Pre-trial SUM                     : $sumBefore"
    Write-Host "  Post-trial SUM                    : $sumAfter"

    if ($dbDelta -eq $successQtySum) {
        Write-Host "  INVARIANT HOLDS: dbDelta == sumOfSuccessfulQtys ($dbDelta = $successQtySum)" -ForegroundColor Green
    } else {
        Write-Host "  INVARIANT VIOLATED: dbDelta=$dbDelta, expected=$successQtySum" -ForegroundColor Red
        exit 1
    }

    # Cleanup — cancel every receipt this trial created so the next trial starts clean
    $allReceipts = @($results | ForEach-Object { $_.receiptIds }) | Where-Object { $_ }
    foreach ($id in $allReceipts) {
        try { Invoke-RestMethod -Uri "$base/api/receipts/$id/cancel" -Method POST -Body $cancelBody -ContentType 'application/json' -WebSession $adm | Out-Null } catch { }
    }
    $sumPost = [int](Q "SELECT ISNULL(SUM(QtyReceived),0) FROM dbo.Receipts WHERE PullItemId='$pcbaItem';")
    Write-Host "  Post-cleanup SUM (after cancels) : $sumPost  (delta from pre-trial: $($sumPost - $sumBefore))"
}

Write-Host ""
Write-Host "All 3 trials passed: invariant SUM(QtyReceived in DB) == SUM(qty in HTTP=200 jobs)" -ForegroundColor Green
