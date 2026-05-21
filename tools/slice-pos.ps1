<#
.SYNOPSIS
  Slice mockups/pos.html into wwwroot/css/pos.css + body raw file.

.NOTES
  Same marker convention as slice-mockup.ps1. Re-runnable. JS extraction
  is opt-in via -SyncJs — pos.js is hand-written Stage B from day one,
  the mockup has no JS:main block to extract.
#>

[CmdletBinding()]
param(
    [string]$Src     = "$PSScriptRoot\..\mockups\pos.html",
    [string]$Css     = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\css\pos.css",
    [string]$Js      = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\js\pos.js",
    [string]$BodyOut = "$PSScriptRoot\pos-body-raw.txt",
    [switch]$SyncJs
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib-slicer.ps1"

Invoke-MockupSlice -Src $Src -Css $Css -Js $Js -BodyOut $BodyOut `
    -CssBlocks  @('main') `
    -JsBlocks   @() `
    -BodyBlocks @('main') `
    -SyncJs:$SyncJs -MockName 'pos'
