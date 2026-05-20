<#
.SYNOPSIS
  Slice mockups/masters.html into separate CSS / JS / body files.

.NOTES
  Same marker convention as slice-transactions.ps1. Re-runnable. JS extraction is
  opt-in via -SyncJs so a future API-wired masters.js isn't clobbered.
#>

[CmdletBinding()]
param(
    [string]$Src     = "$PSScriptRoot\..\mockups\masters.html",
    [string]$Css     = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\css\masters.css",
    [string]$Js      = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\js\masters.js",
    [string]$BodyOut = "$PSScriptRoot\masters-body-raw.txt",
    [switch]$SyncJs
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib-slicer.ps1"

Invoke-MockupSlice -Src $Src -Css $Css -Js $Js -BodyOut $BodyOut `
    -CssBlocks  @('main') `
    -JsBlocks   @('main') `
    -BodyBlocks @('main') `
    -SyncJs:$SyncJs -MockName 'masters'
