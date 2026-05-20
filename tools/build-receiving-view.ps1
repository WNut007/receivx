<#
  Build src/ReceivingOps.Web/Views/Receiving/Index.cshtml by stitching together:
    - a Razor head (mirroring the Dashboard pattern: Layout = null, own CSS/JS)
    - tools/receiving-body-raw.txt          (body markup extracted by slice-mockup.ps1)
    - footer script tags pointing at the extracted receiving.js

  Run AFTER slice-mockup.ps1 has produced the body file.
#>

[CmdletBinding()]
param(
    [string]$BodyRaw = "$PSScriptRoot\receiving-body-raw.txt",
    [string]$Out     = "$PSScriptRoot\..\src\ReceivingOps.Web\Views\Receiving\Index.cshtml"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BodyRaw)) { throw "Body file not found: $BodyRaw — run slice-mockup.ps1 first." }

$head = @'
@{
    ViewData["Title"] = "Receiving Console";
    ViewData["PageId"] = "receiving";
    Layout = null;  // The mockup owns its own theme stylesheet + DOM structure.
}
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Receiving Console · Receiving Operations</title>

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Roboto:ital,wght@@0,300;0,400;0,500;0,600;0,700;0,900;1,300;1,400;1,500&family=Roboto+Mono:wght@@400;500;600;700&display=swap" rel="stylesheet">

    <link href="https://cdn.jsdelivr.net/npm/bootstrap@@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@@1.11.3/font/bootstrap-icons.min.css">
    <script src="https://cdn.jsdelivr.net/npm/xlsx@@0.18.5/dist/xlsx.full.min.js"></script>

    <link rel="stylesheet" href="~/css/receiving.css" asp-append-version="true">
</head>
<body data-app-page="receiving">

'@

$tail = @'

<script src="~/js/app-nav.js" asp-append-version="true"></script>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script src="~/js/receiving.js" asp-append-version="true"></script>

</body>
</html>
'@

$body = Get-Content -LiteralPath $BodyRaw -Raw

# The body raw file came from inside <body data-app-page="receiving">...</body>.
# We've already opened <body> in the head, so just splice $body in as-is.
$content = $head + $body + $tail

$null = New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
Set-Content -LiteralPath $Out -Value $content -Encoding utf8 -NoNewline

Write-Host "Wrote $Out" -ForegroundColor Green
Write-Host ("  total chars: {0}" -f $content.Length)
