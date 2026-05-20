# Shared helper for mockup slicing. Dot-source from a thin wrapper script.

function Get-BlockLines {
    param(
        [Parameter(Mandatory)] $Lines,
        [Parameter(Mandatory)] [ValidateSet('CSS','JS','BODY')] [string]$Kind,
        [Parameter(Mandatory)] [string]$Name
    )
    $Lines = @($Lines)

    $beginRe = "<!--\s*BEGIN_${Kind}:${Name}\s*-->"
    $endRe   = "<!--\s*END_${Kind}:${Name}\s*-->"

    $startIdx = -1; $endIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($startIdx -lt 0 -and $Lines[$i] -match $beginRe) { $startIdx = $i }
        elseif ($startIdx -ge 0 -and $Lines[$i] -match $endRe) { $endIdx = $i; break }
    }
    if ($startIdx -lt 0) { throw "Marker BEGIN_${Kind}:${Name} not found" }
    if ($endIdx   -lt 0) { throw "Marker END_${Kind}:${Name} not found" }

    if ($endIdx - $startIdx -le 1) { return ,([string[]]@()) }
    $content = @($Lines[($startIdx + 1)..($endIdx - 1)])

    if ($Kind -eq 'CSS' -or $Kind -eq 'JS') {
        $openTag  = if ($Kind -eq 'CSS') { '<style>'  } else { '<script>'  }
        $closeTag = if ($Kind -eq 'CSS') { '</style>' } else { '</script>' }

        $first = 0
        while ($first -lt $content.Count -and $content[$first].Trim() -eq '') { $first++ }
        if ($first -ge $content.Count -or $content[$first].Trim() -ne $openTag) {
            throw "Expected first non-empty line of ${Kind}:${Name} to be '$openTag', got: '$($content[$first])'"
        }
        $first++

        $last = $content.Count - 1
        while ($last -ge 0 -and $content[$last].Trim() -eq '') { $last-- }
        if ($last -lt 0 -or $content[$last].Trim() -ne $closeTag) {
            throw "Expected last non-empty line of ${Kind}:${Name} to be '$closeTag', got: '$($content[$last])'"
        }
        $last--

        if ($last -lt $first) { return ,([string[]]@()) }
        $content = $content[$first..$last]
    }
    return ,([string[]]$content)
}

# Slice a mockup into concatenated CSS / JS / body files.
function Invoke-MockupSlice {
    param(
        [Parameter(Mandatory)] [string]$Src,
        [Parameter(Mandatory)] [string]$Css,
        [Parameter(Mandatory)] [string]$Js,
        [Parameter(Mandatory)] [string]$BodyOut,
        [string[]]$CssBlocks = @('main'),
        [string[]]$JsBlocks  = @('main'),
        [string[]]$BodyBlocks = @('main'),
        [switch]$SyncJs,
        [string]$MockName = ''
    )

    if (-not (Test-Path $Src)) { throw "Source mockup not found: $Src" }
    $lines = @(Get-Content -LiteralPath $Src)

    $tag = if ($MockName) { "[$MockName] " } else { '' }
    Write-Host "${tag}Source: $Src" -ForegroundColor Cyan
    Write-Host "${tag}Total lines: $($lines.Count)"

    $cssLines  = @()
    $jsLines   = @()
    $bodyLines = @()

    foreach ($name in $CssBlocks) {
        $block = Get-BlockLines -Lines $lines -Kind 'CSS' -Name $name
        $cssLines += "/* ===== CSS:$name (from $(Split-Path $Src -Leaf)) ===== */"
        if ($block.Count -gt 0) { $cssLines += $block }
        $cssLines += ''
        Write-Host ("${tag}  CSS:$name -> {0} lines" -f $block.Count)
    }
    if ($SyncJs) {
        foreach ($name in $JsBlocks) {
            $block = Get-BlockLines -Lines $lines -Kind 'JS' -Name $name
            $jsLines += "/* ===== JS:$name (from $(Split-Path $Src -Leaf)) ===== */"
            if ($block.Count -gt 0) { $jsLines += $block }
            $jsLines += ''
            Write-Host ("${tag}  JS:$name -> {0} lines" -f $block.Count)
        }
    } else {
        Write-Host "${tag}  JS extraction skipped (pass -SyncJs to overwrite $(Split-Path $Js -Leaf))" -ForegroundColor Yellow
    }
    foreach ($name in $BodyBlocks) {
        $block = Get-BlockLines -Lines $lines -Kind 'BODY' -Name $name
        $bodyLines += "<!-- ===== BODY:$name (from $(Split-Path $Src -Leaf)) ===== -->"
        if ($block.Count -gt 0) { $bodyLines += $block }
        $bodyLines += ''
        Write-Host ("${tag}  BODY:$name -> {0} lines" -f $block.Count)
    }

    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Css)     | Out-Null
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Js)      | Out-Null
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $BodyOut) | Out-Null

    Set-Content -LiteralPath $Css     -Value $cssLines  -Encoding utf8
    Set-Content -LiteralPath $BodyOut -Value $bodyLines -Encoding utf8
    if ($SyncJs) { Set-Content -LiteralPath $Js -Value $jsLines -Encoding utf8 }

    Write-Host ""
    Write-Host "${tag}Wrote:" -ForegroundColor Green
    Write-Host "${tag}  $Css     ($($cssLines.Count) lines)"
    if ($SyncJs) { Write-Host "${tag}  $Js      ($($jsLines.Count) lines)" } else { Write-Host "${tag}  $Js      (skipped — -SyncJs)" }
    Write-Host "${tag}  $BodyOut ($($bodyLines.Count) lines)"
    Write-Host ""
}
