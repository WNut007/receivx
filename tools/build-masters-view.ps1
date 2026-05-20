<#
  Build src/ReceivingOps.Web/Views/Masters/Index.cshtml by stitching together:
    - a Razor head (Layout = null, own CSS/JS)
    - tools/masters-body-raw.txt  (body markup extracted by slice-masters.ps1)
    - footer script tags pointing at the extracted masters.js

  Run AFTER slice-masters.ps1 has produced the body file.
#>

[CmdletBinding()]
param(
    [string]$BodyRaw = "$PSScriptRoot\masters-body-raw.txt",
    [string]$Out     = "$PSScriptRoot\..\src\ReceivingOps.Web\Views\Masters\Index.cshtml"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BodyRaw)) { throw "Body file not found: $BodyRaw — run slice-masters.ps1 first." }

$head = @'
@{
    ViewData["Title"] = "Master Data";
    ViewData["PageId"] = "masters";
    Layout = null;  // mockup owns its own theme stylesheet + DOM
}
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Master Data · Receiving Operations</title>

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Roboto:wght@@300;400;500;600;700;900&family=Roboto+Mono:wght@@400;500;600;700&display=swap" rel="stylesheet">

    <link href="https://cdn.jsdelivr.net/npm/bootstrap@@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@@1.11.3/font/bootstrap-icons.min.css">

    <link rel="stylesheet" href="~/css/masters.css" asp-append-version="true">
</head>
<body data-app-page="masters">

'@

$tail = @'

<script src="https://cdn.jsdelivr.net/npm/bootstrap@@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script src="~/js/app-nav.js" asp-append-version="true"></script>
<script src="~/js/masters.js" asp-append-version="true"></script>

</body>
</html>
'@

$body = Get-Content -LiteralPath $BodyRaw -Raw
$content = $head + $body + $tail

$null = New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
Set-Content -LiteralPath $Out -Value $content -Encoding utf8 -NoNewline

Write-Host "Wrote $Out" -ForegroundColor Green
Write-Host ("  total chars: {0}" -f $content.Length)
