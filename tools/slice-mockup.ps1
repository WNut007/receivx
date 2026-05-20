<#
.SYNOPSIS
  Slice mockups/receiving-mockup-v2-fullreceived.html into separate CSS/JS/body files
  using HTML-comment markers (<!-- BEGIN_<KIND>:<name> --> ... <!-- END_<KIND>:<name> -->).

.DESCRIPTION
  - Robust to line-number shifts: markers, not offsets, define each block.
  - For KIND=CSS and KIND=JS, strips the wrapping <style>...</style> or <script>...</script>
    tags from the extracted content so the output is pure CSS/JS.
  - For KIND=BODY, content is kept verbatim.

  Output files:
    src/ReceivingOps.Web/wwwroot/css/receiving.css   (CSS:main + CSS:tx-drawer + CSS:tx-reason)
    src/ReceivingOps.Web/wwwroot/js/receiving.js     (JS:main  + JS:journal)
    tools/receiving-body-raw.txt                     (BODY:main + BODY:tx-drawer)

.NOTES
  Re-run after re-editing the mockup. Idempotent.
  Stage B edits receiving.js heavily and the live file is no longer a verbatim
  extract — re-syncing the JS would clobber the backend wiring. Pass -SyncJs
  explicitly to overwrite the JS file.
#>

[CmdletBinding()]
param(
    [string]$Src     = "$PSScriptRoot\..\mockups\receiving-mockup-v2-fullreceived.html",
    [string]$Css     = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\css\receiving.css",
    [string]$Js      = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\js\receiving.js",
    [string]$BodyOut = "$PSScriptRoot\receiving-body-raw.txt",
    [switch]$SyncJs
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib-slicer.ps1"

Invoke-MockupSlice -Src $Src -Css $Css -Js $Js -BodyOut $BodyOut `
    -CssBlocks  @('main','tx-drawer','tx-reason') `
    -JsBlocks   @('main','journal') `
    -BodyBlocks @('main','tx-drawer') `
    -SyncJs:$SyncJs -MockName 'receiving'
