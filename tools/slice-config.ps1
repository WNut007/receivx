<#
.SYNOPSIS
  Slice mockups/config.html into separate CSS / JS / body files.
#>

[CmdletBinding()]
param(
    [string]$Src     = "$PSScriptRoot\..\mockups\config.html",
    [string]$Css     = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\css\config.css",
    [string]$Js      = "$PSScriptRoot\..\src\ReceivingOps.Web\wwwroot\js\config.js",
    [string]$BodyOut = "$PSScriptRoot\config-body-raw.txt",
    [switch]$SyncJs
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib-slicer.ps1"

Invoke-MockupSlice -Src $Src -Css $Css -Js $Js -BodyOut $BodyOut `
    -CssBlocks  @('main') `
    -JsBlocks   @('main') `
    -BodyBlocks @('main') `
    -SyncJs:$SyncJs -MockName 'config'
