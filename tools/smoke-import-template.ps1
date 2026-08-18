# Smoke: Download template on the Imports page.
#
# GET /api/imports/po/template hands the operator a workbook whose header row
# is generated from PoImportReader's own constants. The template exists for
# COMPARISON — an operator unsure whether they exported the right ERP sheet
# opens it and checks their header row against it — so the assertions here are
# about the template agreeing with the parser, not about pretty formatting.
#
# Asserts:
#   1. GET as admin → 200, xlsx content type, non-zero body, correct filename
#   2. GET as supervisor → 200; operator → 403; anonymous → 401 or login redirect
#   3. Workbook has a sheet named exactly 'data'
#   4. Header row carries all 28 mapped column names, spelled exactly —
#      including the deliberate misspelling EXPORT DECELERATION NO
#   5. Every name in PoImportReader.RequiredHeaders (read from the C# source,
#      not a literal list here) appears in the header row. Adding a required
#      header therefore fails this smoke until the template includes it.
#   6. Round-trip: the generated file fed back through PoImportReader.ParseAsync
#      (via POST /api/imports/po/upload) → 'validated', 2 rows, 0 errors
#   7. PULL SHEET ID / PRS NO sample values survive a save/reload cycle as
#      text with leading zeros intact
#   8. One sample row leaves PO blank and the file still parses clean
#
# Cleanup: the round-trip upload mints a PoImportLog row + a staged file but is
# never confirmed, so no PurchaseOrders are written. Both are removed on exit.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'
$readerSrc = Join-Path $webRoot 'Services\PoImport\PoImportReader.cs'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$WH_03 = '22222222-2222-2222-2222-000000000003'
$sqlSrv = 'LAPTOP-CSB3KO3E'
$templateFileName = 'ReceivingOps-PO-Import-Template.xlsx'
$xlsxContentType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

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

# Remove any PoImportLog row (+ staged file) this smoke left behind previously.
function Cleanup-TemplateRuns {
    $paths = (Sql @"
SET NOCOUNT ON;
SELECT StoragePath FROM dbo.PoImportLog WHERE FileName = '$templateFileName';
"@) | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }

    Sql @"
SET NOCOUNT ON;
DELETE FROM dbo.PoImportLog WHERE FileName = '$templateFileName';
"@ | Out-Null

    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
}

$tmpDir = Join-Path $env:TEMP ("import-template-smoke-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
$dl = Join-Path $tmpDir $templateFileName

try {
    # ------------------------------------------------------------------
    Step "0. Dev server reachable + prior runs purged"
    try { Invoke-WebRequest -Uri "$base/Account/Login" -UseBasicParsing -TimeoutSec 10 | Out-Null }
    catch { Fail "Dev server not reachable at $base — start it with: dotnet run --launch-profile http" }
    Cleanup-TemplateRuns
    OK "server up, no residual template runs"

    # ------------------------------------------------------------------
    Step "1. GET /api/imports/po/template as admin"
    $admin = Login 'sadmin' 'admin' $WH_01
    $resp = Invoke-WebRequest -Uri "$base/api/imports/po/template" -WebSession $admin -UseBasicParsing
    if ($resp.StatusCode -ne 200) { Fail "Expected 200, got $($resp.StatusCode)" }

    $ct = ($resp.Headers['Content-Type'] | Select-Object -First 1)
    if ($ct -notlike "$xlsxContentType*") { Fail "Content-Type='$ct', expected '$xlsxContentType'" }

    $cd = ($resp.Headers['Content-Disposition'] | Select-Object -First 1)
    if ($cd -notmatch [regex]::Escape($templateFileName)) { Fail "Content-Disposition '$cd' does not name $templateFileName" }

    if ($resp.Content.Length -le 0) { Fail "Template body is empty" }
    [System.IO.File]::WriteAllBytes($dl, $resp.Content)
    $size = (Get-Item -LiteralPath $dl).Length
    if ($size -le 0) { Fail "Downloaded template is zero bytes" }
    # 'PK' — an xlsx is a zip container. Guards against an HTML error page
    # being saved with a 200 by some future middleware.
    $magic = [System.IO.File]::ReadAllBytes($dl)[0..1]
    if ($magic[0] -ne 0x50 -or $magic[1] -ne 0x4B) { Fail "Downloaded file is not a zip/xlsx container" }
    OK "200 · $xlsxContentType · $size bytes · $templateFileName"

    # ------------------------------------------------------------------
    Step "2. Role gate — supervisor 200 / operator 403 / anonymous rejected"
    $sup = Login 'swattana' 'demo1234' $WH_01
    $supResp = Invoke-WebRequest -Uri "$base/api/imports/po/template" -WebSession $sup -UseBasicParsing
    if ($supResp.StatusCode -ne 200) { Fail "Supervisor got $($supResp.StatusCode), expected 200" }
    if ($supResp.Content.Length -le 0) { Fail "Supervisor got an empty template" }

    $op = Login 'npatcharin' 'demo1234' $WH_03
    $opCode = 0
    try { Invoke-WebRequest -Uri "$base/api/imports/po/template" -WebSession $op -UseBasicParsing | Out-Null }
    catch { $opCode = [int]$_.Exception.Response.StatusCode }
    if ($opCode -ne 403) { Fail "Operator got $opCode, expected 403" }

    $anonCode = 0
    $anonLocation = ''
    try {
        $anon = Invoke-WebRequest -Uri "$base/api/imports/po/template" -UseBasicParsing -MaximumRedirection 0
        $anonCode = $anon.StatusCode
        $anonLocation = ($anon.Headers['Location'] | Select-Object -First 1)
    } catch {
        $anonCode = [int]$_.Exception.Response.StatusCode
        if ($_.Exception.Response.Headers.Contains('Location')) {
            $anonLocation = ($_.Exception.Response.Headers.GetValues('Location') | Select-Object -First 1)
        }
    }
    $anonOk = ($anonCode -eq 401) -or (($anonCode -eq 302) -and ($anonLocation -match '/Account/Login'))
    if (-not $anonOk) { Fail "Anonymous got $anonCode (Location='$anonLocation'), expected 401 or 302 to /Account/Login" }
    OK "supervisor 200 · operator 403 · anonymous $anonCode"

    # ------------------------------------------------------------------
    Step "3-4. Workbook shape — sheet 'data' + all 28 header names"
    $dll = Get-ChildItem (Join-Path $webRoot 'bin\Debug\net8.0') -Filter 'ClosedXML.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll) { Fail "ClosedXML.dll not found — build the project first" }
    Add-Type -Path $dll.FullName

    $expectedHeaders = @(
        'PULL SHEET ID / PRS NO','SKU','OPEN QTY','DELIVERY DATE','STORER CODE','STORER NAME',
        'SKU DESCRIPTION','ORDER ID','PO','ASN NO','INVOICE','KANBAN NO','PCC NO','BATCH / LOT NO',
        'MANUFACTURING CTRL NO','MANUFACTURING REF','CUSTOMER REFERENCE','EXPORT DECELERATION NO',
        'VENDOR SKU','PALLET ID','VMI PALLET ID','LOCATION','BUILDING','SUB INVENTORY','TO LOCATION',
        'PRODUCTION LINE','ROUND','NOTES'
    )

    $wb = New-Object ClosedXML.Excel.XLWorkbook($dl)
    try {
        $names = @($wb.Worksheets | ForEach-Object { $_.Name })
        if ($names -notcontains 'data') { Fail "No sheet named 'data' (sheets: $($names -join ', '))" }
        if ($names -notcontains 'README') { Fail "No README sheet (sheets: $($names -join ', '))" }
        OK "sheets: $($names -join ', ')"

        $ws = $wb.Worksheet('data')
        $lastCol = $ws.LastColumnUsed().ColumnNumber()
        if ($lastCol -ne $expectedHeaders.Count) { Fail "Header row has $lastCol columns, expected $($expectedHeaders.Count)" }

        $headerRow = @()
        for ($c = 1; $c -le $lastCol; $c++) { $headerRow += $ws.Cell(1, $c).GetString() }

        foreach ($h in $expectedHeaders) {
            if ($headerRow -notcontains $h) { Fail "Header row is missing '$h'" }
        }
        # Called out explicitly: the ERP header reads 'Deceleration' and the
        # reader matches that spelling. A well-meaning spelling fix in the
        # template is the most likely future regression.
        if ($headerRow -notcontains 'EXPORT DECELERATION NO') { Fail "EXPORT DECELERATION NO missing — do not 'fix' the ERP's spelling" }
        if ($headerRow -contains 'EXPORT DECLARATION NO')     { Fail "Header was 'corrected' to EXPORT DECLARATION NO — breaks the mapping" }
        OK "28 headers present, EXPORT DECELERATION NO spelled as the ERP emits it"

        # --------------------------------------------------------------
        Step "5. RequiredHeaders (read from PoImportReader.cs) all present"
        if (-not (Test-Path $readerSrc)) { Fail "PoImportReader.cs not found at $readerSrc" }
        $src = Get-Content -Raw -LiteralPath $readerSrc
        if ($src -notmatch '(?s)RequiredHeaders\s*=\s*new\[\]\s*\{(.*?)\};') { Fail "Could not locate RequiredHeaders array in PoImportReader.cs" }
        $required = [regex]::Matches($Matches[1], '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        if (-not $required -or $required.Count -lt 1) { Fail "Parsed zero entries out of RequiredHeaders" }
        foreach ($h in $required) {
            if ($headerRow -notcontains $h) { Fail "Required header '$h' is in PoImportReader.RequiredHeaders but not in the template" }
        }
        # The generator must not have hard-copied the four names either.
        if ($src -notmatch 'internal static readonly string\[\] RequiredHeaders') {
            Fail "RequiredHeaders is no longer internal — the template generator reads it directly"
        }
        OK "$($required.Count) required headers, all present: $($required -join ' · ')"

        # --------------------------------------------------------------
        Step "7. PULL SHEET ID / PRS NO survives as text with leading zeros"
        $psCol = 1 + [Array]::IndexOf($headerRow, 'PULL SHEET ID / PRS NO')
        if ($psCol -lt 1) { Fail "PULL SHEET ID / PRS NO column not found" }
        foreach ($r in 2, 3) {
            $cell = $ws.Cell($r, $psCol)
            if ($cell.DataType -ne [ClosedXML.Excel.XLDataType]::Text) { Fail "Row $r PULL SHEET ID is $($cell.DataType), expected Text" }
            $v = $cell.GetString()
            if ($v -notmatch '^0\d+$') { Fail "Row $r PULL SHEET ID '$v' is not a zero-padded numeric string" }
        }
        $beforeSave = @($ws.Cell(2, $psCol).GetString(), $ws.Cell(3, $psCol).GetString())
        OK "both sample values are Text cells: $($beforeSave -join ' · ')"

        # --------------------------------------------------------------
        Step "8. One sample row leaves PO blank"
        $poCol = 1 + [Array]::IndexOf($headerRow, 'PO')
        if ($poCol -lt 1) { Fail "PO column not found" }
        $poVals = @($ws.Cell(2, $poCol).GetString(), $ws.Cell(3, $poCol).GetString())
        $blankCount = @($poVals | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
        if ($blankCount -ne 1) { Fail "Expected exactly one sample row with PO blank, got $blankCount (values: '$($poVals -join "','")')" }
        OK "PO blank on one of the two sample rows ('$($poVals[0])' / '$($poVals[1])')"

        # Save/reload cycle — proves the leading zeros are stored as text in
        # the file rather than merely rendered that way in memory.
        $resaved = Join-Path $tmpDir 'resaved.xlsx'
        $wb.SaveAs($resaved)
        $wb2 = New-Object ClosedXML.Excel.XLWorkbook($resaved)
        try {
            $ws2 = $wb2.Worksheet('data')
            foreach ($i in 0, 1) {
                $cell = $ws2.Cell($i + 2, $psCol)
                if ($cell.DataType -ne [ClosedXML.Excel.XLDataType]::Text) { Fail "After reload, row $($i+2) PULL SHEET ID is $($cell.DataType), expected Text" }
                if ($cell.GetString() -ne $beforeSave[$i]) { Fail "After reload, row $($i+2) PULL SHEET ID '$($cell.GetString())' != '$($beforeSave[$i])'" }
            }
        } finally { $wb2.Dispose() }
        OK "leading zeros intact after save/reload: $($beforeSave -join ' · ')"
    }
    finally { $wb.Dispose() }

    # ------------------------------------------------------------------
    # Runs last on purpose: the workbook handle above has to be released
    # before the same file can be handed to the upload endpoint.
    Step "6. Round-trip — the template parses clean through PoImportReader"
    $upload = Invoke-RestMethod -Uri "$base/api/imports/po/upload" `
        -Method POST -WebSession $sup `
        -Form @{ file = Get-Item -LiteralPath $dl }

    if (-not $upload.runId)                  { Fail "Upload response missing runId" }
    if ($upload.status -ne 'validated')      { Fail "status='$($upload.status)', expected 'validated' — the template's own sample rows must pass validation" }
    if ($upload.totalRowsRead -ne 2)         { Fail "totalRowsRead=$($upload.totalRowsRead), expected 2" }
    if ($upload.validationErrorCount -ne 0)  { Fail "validationErrorCount=$($upload.validationErrorCount), expected 0 — errors: $($upload.validationErrorsPreview | ConvertTo-Json -Compress)" }
    if ($upload.distinctPoCount -ne 2)       { Fail "distinctPoCount=$($upload.distinctPoCount), expected 2" }
    OK "ParseAsync: 2 rows, 0 validation errors, status=validated"

    # Never confirmed → nothing may have reached PurchaseOrders.
    $poCount = (Sql @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.PurchaseOrders WHERE PoNumber IN ('0000000001','0000000002');
"@ | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
    if ([int]$poCount -ne 0) { Fail "Template sample PoNumbers reached dbo.PurchaseOrders ($poCount rows) — the smoke never confirmed the import" }
    OK "no PurchaseOrders written (import left unconfirmed)"

    # ------------------------------------------------------------------
    # Discoverability guard: an endpoint nobody can reach from the page is
    # the same as no endpoint. Mirrors the nav-entry check in
    # smoke-phase-12-6 for the same reason.
    Step "9. /Imports surfaces the download link (and only to uploaders)"
    $supPage = (Invoke-WebRequest -Uri "$base/Imports" -WebSession $sup -UseBasicParsing).Content
    foreach ($token in 'imports-template-link', '/api/imports/po/template', 'ดาวน์โหลดเทมเพลต', 'imports-source-hint', 'xxwdt0061_stock_shipped') {
        if ($supPage -notmatch [regex]::Escape($token)) { Fail "/Imports (supervisor) is missing '$token'" }
    }
    $opPage = (Invoke-WebRequest -Uri "$base/Imports" -WebSession $op -UseBasicParsing).Content
    if ($opPage -match [regex]::Escape('/api/imports/po/template')) { Fail "/Imports (operator) offers the template link — the uploader block is admin/supervisor-only" }
    OK "download link + ERP source hint render for uploaders, hidden from operators"
}
finally {
    Cleanup-TemplateRuns
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nAll import-template assertions passed." -ForegroundColor Green
exit 0
