# Smoke: Phase 9.1 — 7 ERP-sourced fields on dbo.PullItems.
#
# Covers:
#   1. Schema: 7 columns on dbo.PullItems (db/024)
#   2. View: 7 columns appended to vw_TransactionsJournal (db/025)
#   3. API round-trip: PUT extended fields → GET pull → assert all 7
#      surface in JSON
#   4. Permission: operator (operator-only login) blocked with 403
#   5. Permission: PUT on a closed pull → 409 (skipped if no closed pull)
#   6. Audit: one AuditLog row written per successful PUT
#   7. Excel export: Transactions XLSX has the 7 new column headers + the
#      test marker value reaches the sheet body (the marker is set on the
#      PullItem so any receipt against it carries the marker through the
#      view's PullItems JOIN — proving the full data path end-to-end)
#   8. Cleanup: NULL the test fields so the smoke is rerunnable
#
# Requires: dev server running on http://localhost:5213 with Phase 9.1
# code (new PUT endpoint + extended ReceiptJournalRow + extended export).
# If the server is on pre-Phase-9.1 code, test 3 will fail with 404 on
# the PUT endpoint.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_03 = '22222222-2222-2222-2222-000000000003'
$exportRoot = 'C:\dev\receivx\src\ReceivingOps.Web\exports'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function Sql($q)  { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

function ExpectStatus([int]$expected, [scriptblock]$block) {
    try { & $block | Out-Null } catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -ne $expected) { Fail "Expected $expected, got $sc" }
        return
    }
    Fail "Expected $expected, got success"
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

function WaitForFile($jobId, $prefix, $timeoutSec = 45) {
    # File appears early (0 bytes) and grows as Hangfire writes. Wait for the
    # file to exist, be non-zero, AND not be exclusively locked by the writer —
    # otherwise downstream OpenRead races the writer and throws.
    $expected = Join-Path $exportRoot "$prefix-$($jobId.Replace('-','')).xlsx"
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $expected) {
            $len = (Get-Item $expected -ErrorAction SilentlyContinue).Length
            if ($len -gt 0) {
                try {
                    # FileShare.None — succeeds only if no other handle has it open.
                    $fs = [System.IO.File]::Open($expected, 'Open', 'Read', 'None')
                    $fs.Close()
                    return $expected
                } catch { }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function ReadXlsxText($xlsxPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($xlsxPath)
    try {
        $buf = ''
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -eq 'xl/sharedStrings.xml' -or
                $entry.FullName -match '^xl/worksheets/sheet\d+\.xml$') {
                $sr = New-Object System.IO.StreamReader($entry.Open())
                $buf += $sr.ReadToEnd()
                $sr.Close()
            }
        }
        return $buf
    } finally { $zip.Dispose() }
}

# ----------------------------------------------------------------------------
# 1. Schema — 7 columns on PullItems (db/024)
# ----------------------------------------------------------------------------
Step "Schema: 7 ERP-sourced columns on PullItems"
$colCount = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'PullItems' AND COLUMN_NAME IN ('ProductFamily','FromSubInventory','ToSubInventory','SpecialControl','TrialId','Location','Phase');") -join '' -replace '\s',''
if ($colCount -ne '7') { Fail "Expected 7 new columns on PullItems, found '$colCount'" }
OK "All 7 PullItems columns present (db/024)"

# ----------------------------------------------------------------------------
# 2. View — 7 columns appended to vw_TransactionsJournal (db/025)
# ----------------------------------------------------------------------------
Step "View: 7 columns appended to vw_TransactionsJournal"
$viewCount = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'vw_TransactionsJournal' AND COLUMN_NAME IN ('ProductFamily','FromSubInventory','ToSubInventory','SpecialControl','TrialId','PullLocation','PullPhase');") -join '' -replace '\s',''
if ($viewCount -ne '7') { Fail "Expected 7 ERP columns on view, found '$viewCount'" }
OK "All 7 view columns present (db/025; PullLocation/PullPhase aliased)"

# ----------------------------------------------------------------------------
# 3. Pick an open pull + item that already has at least one receipt — so the
#    Excel export's view JOIN surfaces the marker value through any
#    transaction row, not just rows we'd have to invent.
# ----------------------------------------------------------------------------
Step "Pick an open pull with an item that has receipts"
$pickRow = (Sql @"
SET NOCOUNT ON;
SELECT TOP 1 CONVERT(VARCHAR(36), p.Id) + '|' + CONVERT(VARCHAR(36), pi.Id) + '|' + p.PullNumber
FROM dbo.PullItems pi
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
INNER JOIN dbo.Receipts r ON r.PullItemId = pi.Id AND r.ReversedById IS NULL
WHERE p.Status IN ('pending','in_progress')
GROUP BY p.Id, pi.Id, p.PullNumber
ORDER BY p.PullNumber;
"@) -join '' -replace '\s',''
if (-not $pickRow -or $pickRow -notmatch '^[a-f0-9-]{36}\|[a-f0-9-]{36}\|') {
    Fail "Could not locate an open pull with a receipted item; row='$pickRow'"
}
$parts    = $pickRow -split '\|'
$pullId   = $parts[0]
$itemId   = $parts[1]
$pullNum  = $parts[2]
OK "Target: pull $pullNum / itemId $itemId"

# Discover the pull's warehouse so we can log in scoped correctly.
$whId = (Sql "SET NOCOUNT ON; SELECT CONVERT(VARCHAR(36), WarehouseId) FROM dbo.Pulls WHERE Id = '$pullId';") -join '' -replace '\s',''
if (-not $whId) { Fail "Could not resolve warehouseId for pull $pullId" }

# ----------------------------------------------------------------------------
# 4. PUT extended fields as admin → 200
# ----------------------------------------------------------------------------
Step "Login sadmin (admin) and PUT extended fields"
$admin = Login 'sadmin' 'admin' $whId
$payload = @{
    productFamily    = 'P91-FAM'
    fromSubInventory = 'P91-FROM'
    toSubInventory   = 'P91-TO'
    specialControl   = 'P91-SC'
    trialId          = 'P91-TRIAL'
    location         = 'P91-LOC'
    phase            = 'P91-PHASE'
} | ConvertTo-Json
$resp = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$itemId/extended-fields" `
    -Method PUT -Body $payload -ContentType 'application/json' -WebSession $admin
if (-not $resp -or $resp.id -ne $itemId) { Fail "PUT returned unexpected body: $($resp | ConvertTo-Json -Compress)" }
OK "PUT returned refreshed item"

# Echo-from-PUT-response check (cheaper than a follow-up GET, but we still do GET below
# to prove the SELECT path includes the new columns).
if ($resp.productFamily -ne 'P91-FAM') { Fail "PUT response productFamily='$($resp.productFamily)'" }
if ($resp.trialId       -ne 'P91-TRIAL') { Fail "PUT response trialId='$($resp.trialId)'" }
OK "PUT response carries 2 sampled fields"

# ----------------------------------------------------------------------------
# 5. GET /api/pulls/{id} → assert all 7 fields surface
# ----------------------------------------------------------------------------
Step "GET /api/pulls/{id} surfaces all 7 ERP fields"
$pull = Invoke-RestMethod -Uri "$base/api/pulls/$pullId" -WebSession $admin
$gotItem = $pull.items | Where-Object { $_.id -eq $itemId } | Select-Object -First 1
if (-not $gotItem) { Fail "Pull payload missing item $itemId" }
$pairs = @{
    productFamily    = 'P91-FAM'
    fromSubInventory = 'P91-FROM'
    toSubInventory   = 'P91-TO'
    specialControl   = 'P91-SC'
    trialId          = 'P91-TRIAL'
    location         = 'P91-LOC'
    phase            = 'P91-PHASE'
}
foreach ($k in $pairs.Keys) {
    $got = $gotItem.$k
    if ($got -ne $pairs[$k]) { Fail "GET item.$k='$got', expected '$($pairs[$k])'" }
}
OK "All 7 ERP fields round-trip through GET"

# ----------------------------------------------------------------------------
# 6. Operator login → 403 (CanManagePulls = admin OR whRole=supervisor)
# ----------------------------------------------------------------------------
Step "Operator (npatcharin@WH-03, operator-only) blocked with 403"
$op = Login 'npatcharin' 'demo1234' $WH_03
ExpectStatus 403 {
    Invoke-WebRequest -Uri "$base/api/pulls/$pullId/items/$itemId/extended-fields" `
        -Method PUT -Body $payload -ContentType 'application/json' `
        -WebSession $op -ErrorAction Stop
}
OK "Operator denied (403)"

# ----------------------------------------------------------------------------
# 7. Closed pull → 409 (skipped if no closed pull with items exists)
# ----------------------------------------------------------------------------
Step "Closed pull → 409 (or skip if none available)"
$closedRow = (Sql @"
SET NOCOUNT ON;
SELECT TOP 1 CONVERT(VARCHAR(36), p.Id) + '|' + CONVERT(VARCHAR(36), pi.Id) + '|' + CONVERT(VARCHAR(36), p.WarehouseId)
FROM dbo.PullItems pi
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.Status = 'closed'
ORDER BY p.PullNumber;
"@) -join '' -replace '\s',''
if ($closedRow -match '^[a-f0-9-]{36}\|[a-f0-9-]{36}\|[a-f0-9-]{36}$') {
    $cParts  = $closedRow -split '\|'
    $cPullId = $cParts[0]; $cItemId = $cParts[1]; $cWhId = $cParts[2]
    $cAdmin = Login 'sadmin' 'admin' $cWhId
    ExpectStatus 409 {
        Invoke-WebRequest -Uri "$base/api/pulls/$cPullId/items/$cItemId/extended-fields" `
            -Method PUT -Body $payload -ContentType 'application/json' `
            -WebSession $cAdmin -ErrorAction Stop
    }
    OK "Closed pull rejected (409)"
} else {
    Write-Host "  (skipped — no closed pull with items in this DB)" -ForegroundColor DarkYellow
}

# ----------------------------------------------------------------------------
# 8. Audit row written
# ----------------------------------------------------------------------------
Step "AuditLog has at least one 'PullItem' update row for this item"
$auditCount = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.AuditLog WHERE EntityType = 'PullItem' AND EntityId = '$itemId' AND ActionType = 'update' AND Message LIKE '%extended fields%';") -join '' -replace '\s',''
if ([int]$auditCount -lt 1) { Fail "AuditLog count for item=$itemId returned '$auditCount'" }
OK "Audit row count: $auditCount"

# ----------------------------------------------------------------------------
# 9. Transactions Excel export — headers + marker value in body
# ----------------------------------------------------------------------------
Step "POST /api/exports/transactions for the target pull → 202; await file"
# Filter by PullNumber so the export is tightly scoped (fewer rows = faster + the
# marker row is much easier to spot). Operator-export uses pullNumber, not GUID.
$exportBody = @{ pullNumber = $pullNum; maxRows = 500 } | ConvertTo-Json
$resp = Invoke-WebRequest -Uri "$base/api/exports/transactions" -Method POST `
    -Body $exportBody -ContentType 'application/json' -WebSession $admin -UseBasicParsing
if ($resp.StatusCode -ne 202) { Fail "POST returned $($resp.StatusCode), expected 202" }
$queue = $resp.Content | ConvertFrom-Json
$file = WaitForFile $queue.jobId 'transactions'
if (-not $file) { Fail "transactions export file never appeared (30s timeout)" }
OK "Export file written: $((Get-Item $file).Length) bytes"

Step "XLSX contains 7 new ERP column headers"
$haystack = ReadXlsxText $file
$mustContain = @('ProductFamily','FromSubInventory','ToSubInventory','TrialId','PullLocation','PullPhase','SpecialControl')
foreach ($needle in $mustContain) {
    if ($haystack -notmatch [regex]::Escape($needle)) {
        Fail "XLSX missing expected header '$needle' — server may be on pre-Phase-9.1 code"
    }
}
OK "All 7 ERP column headers present"

Step "XLSX body carries the test marker through the PullItem JOIN"
if ($haystack -notmatch [regex]::Escape('P91-TRIAL')) {
    Fail "Transactions sheet missing test marker 'P91-TRIAL' — PullItem ERP fields did not reach the export"
}
OK "Test marker 'P91-TRIAL' present — full data path verified"

Remove-Item $file -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# 10. Cleanup — NULL out the test fields so the smoke is rerunnable
# ----------------------------------------------------------------------------
Step "Cleanup: NULL the test ERP fields"
$cleanup = @"
UPDATE dbo.PullItems SET
    ProductFamily = NULL, FromSubInventory = NULL, ToSubInventory = NULL,
    SpecialControl = NULL, TrialId = NULL, Location = NULL, [Phase] = NULL
WHERE Id = '$itemId';
"@
Sql $cleanup | Out-Null
OK "Test data NULLed"

Write-Host ""
Write-Host "ALL PASS — Phase 9.1: schema + view + API + Excel for 7 PullItem ERP fields." -ForegroundColor Green
exit 0
