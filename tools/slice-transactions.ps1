<#
.SYNOPSIS
  Slice mockups/transactions.html into separate CSS / JS / body files.

.NOTES
  Same marker convention as slice-mockup.ps1. Re-runnable. JS extraction is
  opt-in via -SyncJs so a future API-wired transactions.js isn't clobbered.
#>

[CmdletBinding()]
param(
    [string]$Src     = "$PSScriptRoot\..\mockups\transactions.html",
    [string]$Css     = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\css\transactions.css",
    [string]$Js      = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\js\transactions.js",
    [string]$BodyOut = "$PSScriptRoot\transactions-body-raw.txt",
    [switch]$SyncJs
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib-slicer.ps1"

Invoke-MockupSlice -Src $Src -Css $Css -Js $Js -BodyOut $BodyOut `
    -CssBlocks  @('main') `
    -JsBlocks   @('main') `
    -BodyBlocks @('main') `
    -SyncJs:$SyncJs -MockName 'transactions'
