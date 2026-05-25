# Smoke: Phase 9 — 20 ERP-sourced PO Line fields.
#
# Covers:
#   1. Schema: 20 columns exist, Note=NVARCHAR(500), DeliveryDate=DATE
#   2. API round-trip: update a PO line via SQL (no write API by design —
#      ERP push is Phase 10), GET /api/pos/{id}, assert the 5 visible
#      fields AND 3 hidden fields surface in the JSON
#   3. Excel export: POST /api/exports/pos, verify the new "Lines" sheet
#      exists in the XLSX with the new header columns
#   4. Cleanup: NULL the test fields so the smoke is rerunnable
#
# Requires: dev server running on http://localhost:5213 with the Phase 9
# code (PoLineRow + GetLinesForPosAsync + new "Lines" sheet writer). If
# the server is on pre-Phase-9 code, test 3 fails the XLSX content check.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$exportRoot = 'C:\dev\receivx\src\ReceivingOps.Web\exports'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Sql($query) {
    # -h -1 strips headers; -W trims trailing whitespace; -I = QUOTED_IDENTIFIER ON
    # (matches what the app uses; some DML on filtered-index tables needs it).
    return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $query
}

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
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

function GetSharedStringsAndSheetXml($xlsxPath) {
    # XLSX is a zip. Extract sharedStrings + the Lines worksheet XML so we
    # can verify the new sheet exists with the right headers.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($xlsxPath)
    try {
        $result = @{ shared = ''; sheets = @() }
        $sharedEntry = $zip.Entries | Where-Object { $_.FullName -eq 'xl/sharedStrings.xml' } | Select-Object -First 1
        if ($sharedEntry) {
            $sr = New-Object System.IO.StreamReader($sharedEntry.Open())
            $result.shared = $sr.ReadToEnd(); $sr.Close()
        }
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -match '^xl/worksheets/sheet\d+\.xml$') {
                $sr = New-Object System.IO.StreamReader($entry.Open())
                $result.sheets += @{ name = $entry.FullName; xml = $sr.ReadToEnd() }
                $sr.Close()
            }
        }
        # Workbook.xml has the sheet name → rId mapping
        $wbEntry = $zip.Entries | Where-Object { $_.FullName -eq 'xl/workbook.xml' } | Select-Object -First 1
        if ($wbEntry) {
            $sr = New-Object System.IO.StreamReader($wbEntry.Open())
            $result.workbook = $sr.ReadToEnd(); $sr.Close()
        }
        return $result
    } finally {
        $zip.Dispose()
    }
}

# ----------------------------------------------------------------------------
# 1. Schema — 20 columns exist with correct types
# ----------------------------------------------------------------------------
Step "Schema: 20 ERP-sourced columns on PurchaseOrderLines"
$colCount = (Sql "SET NOCOUNT ON; SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'PurchaseOrderLines' AND COLUMN_NAME IN ('InvoiceNo','Location','PalletId','VmiPalletId','ProductionLine','Building','KanbanNo','AsnNo','OrderRound','SubInventory','ToLocation','PCCNo','ManufacturingControlNo','BatchNo','ExportDeclarationNo','CustomerReferenceNo','ManufacturingReferenceNo','VendorItem','DeliveryDate','Note');") -join '' -replace '\s',''
if ($colCount -ne '20') { Fail "Expected 20 new columns, found '$colCount'" }
OK "All 20 ERP-sourced columns present"

Step "Schema: Note is NVARCHAR(500)"
$noteLen = (Sql "SET NOCOUNT ON; SELECT CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'PurchaseOrderLines' AND COLUMN_NAME = 'Note';") -join '' -replace '\s',''
if ($noteLen -ne '500') { Fail "Note column length is '$noteLen', expected 500" }
OK "Note column is NVARCHAR(500)"

Step "Schema: DeliveryDate is DATE"
$ddType = (Sql "SET NOCOUNT ON; SELECT DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'PurchaseOrderLines' AND COLUMN_NAME = 'DeliveryDate';") -join '' -replace '\s',''
if ($ddType -ne 'date') { Fail "DeliveryDate type is '$ddType', expected 'date'" }
OK "DeliveryDate column is DATE"

# ----------------------------------------------------------------------------
# 2. API round-trip — populate test data, fetch via GET, assert fields
# ----------------------------------------------------------------------------
Step "Pick an existing open PO line for the round-trip test"
# First open PO line with no receipts (safe to mutate ERP metadata; receipts
# never reference our new fields anyway, but pick a clean target for clarity).
$lineRow = (Sql "SET NOCOUNT ON; SELECT TOP 1 CONVERT(VARCHAR(36), pol.Id) + '|' + CONVERT(VARCHAR(36), po.Id) FROM dbo.PurchaseOrderLines pol INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId WHERE po.Status = 'open' ORDER BY po.OrderDate, po.PoNumber, pol.LineNumber;") -join '' -replace '\s',''
if (-not $lineRow -or $lineRow -notmatch '^[a-f0-9-]{36}\|[a-f0-9-]{36}$') { Fail "Could not locate an open PO line; row='$lineRow'" }
$parts = $lineRow -split '\|'
$lineId = $parts[0]
$poId   = $parts[1]
OK "Target line $lineId on PO $poId"

Step "Populate 8 test ERP fields via direct SQL (no write API by design)"
$update = @"
UPDATE dbo.PurchaseOrderLines SET
    InvoiceNo    = 'P9-INV-001',
    PalletId     = 'P9-PAL-001',
    VmiPalletId  = 'P9-VMI-001',
    SubInventory = 'P9-SUB',
    ToLocation   = 'P9-LOC',
    KanbanNo     = 'P9-KAN-001',
    DeliveryDate = '2026-06-01',
    Note         = 'Phase 9 smoke test marker'
WHERE Id = '$lineId';
"@
Sql $update | Out-Null
OK "Test data written to line $lineId"

Step "GET /api/pos/{id} returns all 8 populated fields"
$admin = Login 'sadmin' 'admin' $WH_01
$po = Invoke-RestMethod -Uri "$base/api/pos/$poId" -WebSession $admin
$line = $po.lines | Where-Object { $_.id -eq $lineId } | Select-Object -First 1
if (-not $line) { Fail "API response missing line $lineId" }

# 5 UI-visible fields
if ($line.invoiceNo    -ne 'P9-INV-001') { Fail "invoiceNo: '$($line.invoiceNo)'" }
if ($line.palletId     -ne 'P9-PAL-001') { Fail "palletId: '$($line.palletId)'" }
if ($line.vmiPalletId  -ne 'P9-VMI-001') { Fail "vmiPalletId: '$($line.vmiPalletId)'" }
if ($line.subInventory -ne 'P9-SUB')     { Fail "subInventory: '$($line.subInventory)'" }
if ($line.toLocation   -ne 'P9-LOC')     { Fail "toLocation: '$($line.toLocation)'" }
OK "All 5 UI-visible fields surface in API"

# 3 API-only fields (hidden from UI but must appear in JSON)
if ($line.kanbanNo -ne 'P9-KAN-001') { Fail "kanbanNo (API-only): '$($line.kanbanNo)'" }
if ($line.note     -ne 'Phase 9 smoke test marker') { Fail "note (API-only): '$($line.note)'" }
if (-not $line.deliveryDate -or $line.deliveryDate -notmatch '^2026-06-01') { Fail "deliveryDate (API-only): '$($line.deliveryDate)'" }
OK "3 API-only fields (kanbanNo, note, deliveryDate) surface in API"

# ----------------------------------------------------------------------------
# 3. PO Excel export — new "Lines" sheet with ERP headers
# ----------------------------------------------------------------------------
Step "POST /api/exports/pos → 202; await file"
$body = @{ status = 'open'; maxRows = 500 } | ConvertTo-Json
$resp = Invoke-WebRequest -Uri "$base/api/exports/pos" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin -UseBasicParsing
if ($resp.StatusCode -ne 202) { Fail "POST returned $($resp.StatusCode), expected 202" }
$queue = $resp.Content | ConvertFrom-Json
$file = WaitForFile $queue.jobId 'pos'
if (-not $file) { Fail "pos export file never appeared (30s timeout)" }
$size = (Get-Item $file).Length
OK "Export file written: $size bytes"

Step "XLSX contains 'Lines' sheet with ERP column headers"
$content = GetSharedStringsAndSheetXml $file
if ($content.workbook -notmatch 'name="Lines"') {
    Fail "workbook.xml does not declare a 'Lines' sheet — server may be on pre-Phase-9 code"
}
# Header strings live in xl/sharedStrings.xml when reused, or inlined in the
# sheet XML when unique. We check the union to avoid coupling to ClosedXML's
# internal choice.
$haystack = $content.shared
foreach ($s in $content.sheets) { $haystack += $s.xml }
$mustContain = @('InvoiceNo','KanbanNo','PalletId','VmiPalletId','SubInventory','ToLocation','DeliveryDate','Note','ManufacturingControlNo','OrderRound')
foreach ($needle in $mustContain) {
    if ($haystack -notmatch [regex]::Escape($needle)) {
        Fail "XLSX missing expected header '$needle'"
    }
}
OK "All 10 sampled ERP headers present in workbook"

Step "XLSX contains the test marker value in the Lines sheet body"
if ($haystack -notmatch [regex]::Escape('P9-INV-001')) {
    Fail "Lines sheet missing test marker 'P9-INV-001' — repo did not surface ERP fields to the export"
}
OK "Test marker 'P9-INV-001' present — full ERP data path verified"

Remove-Item $file -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# 4. Cleanup — NULL out the test fields so the smoke is rerunnable
# ----------------------------------------------------------------------------
Step "Cleanup: NULL the test ERP fields"
$cleanup = @"
UPDATE dbo.PurchaseOrderLines SET
    InvoiceNo = NULL, PalletId = NULL, VmiPalletId = NULL,
    SubInventory = NULL, ToLocation = NULL, KanbanNo = NULL,
    DeliveryDate = NULL, Note = NULL
WHERE Id = '$lineId';
"@
Sql $cleanup | Out-Null
OK "Test data NULLed"

Write-Host ""
Write-Host "ALL PASS — Phase 9: schema + API + Excel export of 20 ERP fields." -ForegroundColor Green
exit 0
