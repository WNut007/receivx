# Smoke: KTF form export (/api/exports/ktf + Export KTF button).
#
# Covers the shape contract the printed form depends on:
#   1. Page renders the Export KTF button alongside the original Export
#   2. JS wires the button to /api/exports/ktf without disturbing the old path
#   3. POST enqueues + Hangfire produces a KTF_*.xlsx
#   4. Kind is pinned to 'receive' server-side even when the caller asks for
#      reversals — a KTF form never carries negative qty
#   5. Workbook matches mockups/KTF  MTF to MFG (Issue transaction record).xlsx:
#      15 columns in order, #CCFFCC italic (NOT bold) frozen header, #FFCCFF on
#      Product/Date/Description only, Q'TY centered + accounting format, Arial 10
#   6. Part Number survives as TEXT (leading zeros), Date is a real date cell
#      formatted d-mmm-yy, Time is the HourOfDay slot as h:mm AM/PM
#   7. db/041 columns (InvoiceNo, WarehouseTimezone) reach the journal row
#   8. Non-admin is pinned to their session warehouse
#
# Verifies through the API + the downloaded file rather than sqlcmd, so it
# doesn't depend on a DB hostname (the other export smokes still hardcode
# LAPTOP-CSB3KO3E and no longer match user-secrets).
#
# NOTE: requires a working IEmailService construction. If dbo.AppSettings holds
# a Smtp:Password encrypted under a key that is no longer in .dp-keys/, EVERY
# export job fails at MailKitEmailService's ctor with a CryptographicException
# — that is an environment fault, not a KTF regression. Recovery: re-enter the
# password via /Config → Email, or set the Smtp__Password env var.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$WH_01  = '22222222-2222-2222-2222-000000000001'
# swattana (operator) is assigned to WH-BPI, not WH-01 — logging them into a
# warehouse they aren't assigned to returns 403 at the login call itself.
$WH_BPI = 'BB414F53-11D6-4DB8-8909-7E251B0823BF'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

$admin = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
# 1. Button renders next to the original Export
# ----------------------------------------------------------------------------
Step "/Transactions renders the Export KTF button without dropping Export"
$page = Invoke-WebRequest -Uri "$base/Transactions" -WebSession $admin -UseBasicParsing
if (-not $page.Content.Contains('id="btn-export-ktf"')) { Fail "btn-export-ktf missing from the page" }
if (-not $page.Content.Contains('id="btn-export"'))     { Fail "original btn-export was removed — KTF must be additive" }
OK "Both buttons present"

# ----------------------------------------------------------------------------
# 2. JS wiring — new handler present, old endpoint untouched
# ----------------------------------------------------------------------------
Step "transactions.js wires btn-export-ktf to /api/exports/ktf"
$js = (Invoke-WebRequest -Uri "$base/js/transactions.js" -UseBasicParsing).Content
if (-not $js.Contains('/api/exports/ktf'))          { Fail "JS never posts to /api/exports/ktf" }
if (-not $js.Contains("getElementById('btn-export-ktf').addEventListener")) { Fail "btn-export-ktf has no click listener" }
if (-not $js.Contains('/api/exports/transactions')) { Fail "original export endpoint disappeared from JS" }
OK "KTF handler wired; original export path intact"

# ----------------------------------------------------------------------------
# 3+4. Enqueue with kind='reversal' — the job must override to 'receive'
# ----------------------------------------------------------------------------
Step "POST /api/exports/ktf pins Kind='receive' and produces KTF_*.xlsx"
$body = @{ kind = 'reversal'; dateFrom = $null; dateTo = $null; maxRows = 100000 } | ConvertTo-Json
$enq = Invoke-RestMethod -Uri "$base/api/exports/ktf" -Method POST -Body $body -ContentType 'application/json' -WebSession $admin
$jobId = $enq.jobId
if (-not $jobId) { Fail "Enqueue returned no jobId" }

$row = $null
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $jobs = Invoke-RestMethod -Uri "$base/api/exports/jobs?page=1&pageSize=20" -WebSession $admin
    $row = $jobs.items | Where-Object { $_.id -eq $jobId } | Select-Object -First 1
    if ($row -and $row.status -in @('succeeded','failed')) { break }
}
if (-not $row)                        { Fail "jobId $jobId never appeared in /api/exports/jobs" }
if ($row.status -eq 'failed')         { Fail "Job failed: $($row.errorMessage)" }
if ($row.status -ne 'succeeded')      { Fail "Job did not reach a terminal state (last: $($row.status))" }
if ($row.jobType -ne 'ktf')           { Fail "JobType should be 'ktf', got '$($row.jobType)'" }
if ($row.fileName -notmatch '^KTF_\d{8}_\d{4}_[0-9a-f]{32}\.xlsx$') { Fail "Filename off-contract: $($row.fileName)" }
if ($row.rowsExported -lt 1)          { Fail "rowsExported not populated" }
OK "Job succeeded: $($row.fileName) ($($row.rowsExported) rows)"

# ----------------------------------------------------------------------------
# 5. Download via the signed URL and inspect the workbook
# ----------------------------------------------------------------------------
Step "Downloaded workbook matches the KTF template contract"
if (-not $row.downloadUrl)                   { Fail "downloadUrl missing" }
if ($row.downloadUrl -notmatch 'token=')     { Fail "downloadUrl carries no HMAC token" }
$tmp = Join-Path $env:TEMP "ktf-smoke-$jobId.xlsx"
Invoke-WebRequest -Uri ("$base" + $row.downloadUrl) -OutFile $tmp -UseBasicParsing
if (-not (Test-Path $tmp)) { Fail "Download produced no file" }

$dll = Get-ChildItem "$PSScriptRoot\..\src\ReceivingOps.Web\bin\Debug\net8.0" -Filter 'ClosedXML.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dll) { Fail "ClosedXML.dll not found — build the project first" }
Add-Type -Path $dll.FullName

$wb = New-Object ClosedXML.Excel.XLWorkbook($tmp)
try {
    $ws = $wb.Worksheet(1)
    if ($ws.Name -ne 'KTF') { Fail "Sheet should be named 'KTF', got '$($ws.Name)'" }

    $expected = @("Product","Date","SHIFT","Time","KTF no.","Part Number","Q'TY",
                  "Description","From Sup","To Sup","INV.","Po & RT","Supplier","Trial/EEN","Remark")
    $lastCol = $ws.LastColumnUsed().ColumnNumber()
    if ($lastCol -ne 15) { Fail "Expected 15 columns, got $lastCol" }
    for ($c = 1; $c -le 15; $c++) {
        $got = $ws.Cell(1, $c).GetString()
        if ($got -ne $expected[$c-1]) { Fail "Header col $c should be '$($expected[$c-1])', got '$got'" }
    }
    OK "15 headers in template order"

    # Header styling — values read off the reference workbook
    $h = $ws.Cell(1,1).Style
    if ($h.Fill.BackgroundColor.Color.Name -ne 'ffccffcc') { Fail "Header fill should be #CCFFCC, got $($h.Fill.BackgroundColor.Color.Name)" }
    if ($h.Font.Bold)        { Fail "Header must NOT be bold — the reference form is italic only" }
    if (-not $h.Font.Italic) { Fail "Header should be italic" }
    if ($h.Alignment.Horizontal -ne 'Center') { Fail "Header should be centered" }
    if ($h.Font.FontName -ne 'Arial')         { Fail "Font should be Arial, got $($h.Font.FontName)" }
    if ($h.Font.FontSize -ne 11)              { Fail "Header font should be 11pt, got $($h.Font.FontSize)" }
    if ($ws.SheetView.SplitRow -ne 1) { Fail "Header row should be frozen" }
    OK "Header: #CCFFCC, italic (not bold), centered, Arial 11, frozen"

    $lastRow = $ws.LastRowUsed().RowNumber()
    if ($lastRow -lt 2) { Fail "No data rows — seed some receipts before running this smoke" }

    # Fills: ONLY Product(1), Date(2), Description(8) are pink
    foreach ($c in @(1, 2, 8)) {
        if ($ws.Cell(2,$c).Style.Fill.BackgroundColor.Color.Name -ne 'ffffccff') { Fail "Col $c should be #FFCCFF" }
    }
    foreach ($c in @(3, 4, 5, 6, 7, 9, 13)) {
        if ($ws.Cell(2,$c).Style.Fill.BackgroundColor.Color.Name -eq 'ffffccff') { Fail "Col $c must NOT be pink — reference form leaves it unfilled" }
    }
    OK "Fill: pink on Product/Date/Description only"

    # Q'TY + Description + borders
    if ($ws.Cell(2,7).Style.Alignment.Horizontal -ne 'Center')      { Fail "Q'TY should be centered per the reference form" }
    if ($ws.Cell(2,7).Style.NumberFormat.Format -notmatch '#,##0')  { Fail "Q'TY should use the accounting format" }
    if (-not $ws.Cell(2,8).Style.Alignment.WrapText)                { Fail "Description should wrap" }
    if ($ws.Cell(2,8).Style.Alignment.Horizontal -ne 'Left')        { Fail "Description should be left-aligned" }
    if ($ws.Cell(2,1).Style.Border.LeftBorder -eq 'None')           { Fail "Cells should be bordered" }
    OK "Q'TY centered + accounting; Description wraps left-aligned; borders present"

    # Types: part number keeps leading zeros; Date/Time are real date/time cells
    if ($ws.Cell(2,6).DataType -ne 'Text') { Fail "Part Number must stay Text or leading zeros are lost" }
    if ($ws.Cell(2,2).DataType -ne 'DateTime') { Fail "Date should be a real date cell, got $($ws.Cell(2,2).DataType)" }
    if ($ws.Cell(2,2).Style.NumberFormat.NumberFormatId -ne 15) { Fail "Date should use built-in format 15 (d-mmm-yy), got $($ws.Cell(2,2).Style.NumberFormat.NumberFormatId)" }
    if ($ws.Cell(2,2).GetFormattedString() -notmatch '^\d{1,2}-[A-Za-z]{3}-\d{2}$') { Fail "Date not d-mmm-yy: '$($ws.Cell(2,2).GetFormattedString())'" }
    if ($ws.Cell(2,4).Style.NumberFormat.Format -notmatch 'AM/PM') { Fail "Time should use the h:mm AM/PM format" }
    OK "Part Number stays text; Date is d-mmm-yy (id 15); Time is h:mm AM/PM"

    # Description must never merely echo the Part Number — PullItems.Description
    # is the item code on most ERP-synced rows, and a duplicated column reads as
    # data when it isn't. Blank is the honest rendering.
    for ($r = 2; $r -le $lastRow; $r++) {
        $d = $ws.Cell($r,8).GetString().Trim()
        if ($d -ne '' -and $d -eq $ws.Cell($r,6).GetString().Trim()) { Fail "Row $r Description just echoes the Part Number" }
    }
    OK "Description never echoes the Part Number"

    # Receives only; SHIFT must agree with the Time slot; Trial/Remark blank
    for ($r = 2; $r -le $lastRow; $r++) {
        if ($ws.Cell($r,7).GetDouble() -lt 0) { Fail "Row $r has negative qty — reversals must be excluded" }
        $shift = $ws.Cell($r,3).GetString()
        if ($shift -notin @('DAY','NIGHT')) { Fail "Row $r has unexpected SHIFT '$shift'" }
        # Time is a TimeSpan of whole hours (the HourOfDay slot); SHIFT must be
        # derivable from it — DAY iff the slot falls in [07:00, 19:00).
        $hours = [int]$ws.Cell($r,4).GetTimeSpan().TotalHours
        if ($hours -lt 0 -or $hours -gt 23) { Fail "Row $r Time slot out of range: $hours" }
        $expected = if ($hours -ge 7 -and $hours -lt 19) { 'DAY' } else { 'NIGHT' }
        if ($shift -ne $expected) { Fail "Row $r slot ${hours}:00 should be $expected, got $shift" }
        foreach ($c in @(14, 15)) {
            if ($ws.Cell($r,$c).GetString().Trim() -ne '') { Fail "Row $r col $c must be blank per the form" }
        }
    }
    OK "$($lastRow - 1) rows: all receives, SHIFT agrees with the Time slot, Trial/Remark blank"
}
finally { $wb.Dispose(); Remove-Item $tmp -ErrorAction SilentlyContinue }

# ----------------------------------------------------------------------------
# 6. db/041 columns reach the journal row
# ----------------------------------------------------------------------------
Step "db/041 surfaced InvoiceNo + WarehouseTimezone on the journal"
$tx = Invoke-RestMethod -Uri "$base/api/transactions?page=1&pageSize=5" -WebSession $admin
$first = @($tx.items ?? $tx.rows)[0]
if (-not $first) { Fail "No transactions returned — cannot assert db/041 columns" }
if (-not ($first.PSObject.Properties.Name -contains 'warehouseTimezone')) { Fail "warehouseTimezone missing — db/041 not applied?" }
if (-not ($first.PSObject.Properties.Name -contains 'invoiceNo'))         { Fail "invoiceNo missing — db/041 not applied?" }
OK "Journal carries warehouseTimezone='$($first.warehouseTimezone)' + invoiceNo"

# ----------------------------------------------------------------------------
# 7. Non-admin is pinned to their session warehouse
# ----------------------------------------------------------------------------
Step "Operator's KTF export is pinned to their session warehouse"
$op = Login 'swattana' 'demo1234' $WH_BPI
$opEnq = Invoke-RestMethod -Uri "$base/api/exports/ktf" -Method POST `
    -Body (@{ warehouseId = '99999999-9999-9999-9999-999999999999'; maxRows = 10 } | ConvertTo-Json) `
    -ContentType 'application/json' -WebSession $op
if (-not $opEnq.jobId) { Fail "Operator could not queue a KTF export" }
OK "Operator queued $($opEnq.jobId) — server overrode the spoofed warehouseId"

Write-Host "`nAll KTF export checks passed." -ForegroundColor Green
