# Smoke test: Reports → Pull Sheets — period map completeness.
#
# The six receiving periods must partition the day exactly: 6 x 4 = 24 hours,
# no gaps, no duplicates, end hour INCLUSIVE. They drive both the Receiving
# grid and the Pull Sheets report, so an hour that fell out of the map would
# not fail anything — it would quietly stop appearing in exports.
#
# This reads the map as the SERVER RENDERED IT rather than grepping
# Models/ReceivingPeriods.cs. Both pages render their <option> lists from
# ReceivingPeriods.All, so parsing the rendered HTML proves the shipped list,
# and proves both pages are reading the same one.
#
# Exercises:
#   1. /Reports renders 6 period options with data-hours.
#   2. Their hour sets union to exactly {0..23}, no duplicates.
#   3. Every period spans exactly 4 hours (inclusive end).
#   4. Night is the only period that wraps midnight.
#   5. /Receiving renders the SAME six start hours — one definition, two pages.
#
# Red-proof (docs/smoke-conventions.md §1): removing an hour from a period in
# ReceivingPeriods.cs fails step 2 with "uncovered", and the app also refuses
# to start (ReceivingPeriodsSelfTest.Verify). Verified 2026-08-21.
#
# No DB fixture — read-only against rendered pages, so there is nothing to
# clean up.

$ErrorActionPreference = 'Stop'
$base  = 'http://localhost:5213'
$WH_01 = '22222222-2222-2222-2222-000000000001'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Login($user, $pass, $whId) {
    $body = @{ username = $user; password = $pass; warehouseId = $whId; remember = $false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

$sv = Login 'sadmin' 'admin' $WH_01

# ----------------------------------------------------------------------------
Step '1. /Reports renders the six periods with their hour sets'
# ----------------------------------------------------------------------------
$html = (Invoke-WebRequest -Uri "$base/Reports" -WebSession $sv -UseBasicParsing).Content

# Scope the match to the ps-period select so a stray data-hours elsewhere on the
# page cannot stand in for the real picker.
$selMatch = [regex]::Match($html, '(?s)<select[^>]*id="ps-period"[^>]*>(.*?)</select>')
if (-not $selMatch.Success) { Fail 'No #ps-period select on /Reports — the Pull Sheets filter bar is missing' }

$optMatches = [regex]::Matches($selMatch.Groups[1].Value,
    '<option value="([^"]+)" data-hours="([^"]+)">([^<]*)</option>')
if ($optMatches.Count -ne 6) { Fail "Expected 6 period options, found $($optMatches.Count)" }

$periods = @()
foreach ($m in $optMatches) {
    $periods += [pscustomobject]@{
        Key   = $m.Groups[1].Value
        Hours = @($m.Groups[2].Value -split ',' | ForEach-Object { [int]$_ })
        Text  = $m.Groups[3].Value
    }
}
OK "6 periods rendered: $(($periods | ForEach-Object { $_.Key }) -join ', ')"

# ----------------------------------------------------------------------------
Step '2. Hour sets union to exactly {0..23} with no duplicates'
# ----------------------------------------------------------------------------
$all = @($periods | ForEach-Object { $_.Hours })
if ($all.Count -ne 24) { Fail "Expected 24 hour entries across all periods, got $($all.Count)" }

$dupes = $all | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
if ($dupes) { Fail "Periods overlap on hour(s): $($dupes -join ', ')" }

$missing = 0..23 | Where-Object { $all -notcontains $_ }
if ($missing) { Fail "Periods leave hour(s) uncovered: $($missing -join ', ')" }
OK 'The six periods tile 0..23 exactly — no gaps, no overlap'

# ----------------------------------------------------------------------------
Step '3. Every period spans exactly 4 hours (end hour inclusive)'
# ----------------------------------------------------------------------------
foreach ($p in $periods) {
    if ($p.Hours.Count -ne 4) { Fail "Period '$($p.Key)' has $($p.Hours.Count) hours, expected 4" }
    # Inclusive end: 07-10 must be {7,8,9,10}, NOT {7,8,9}. Rebuild from the
    # start hour and compare, so an off-by-one in the shipped derivation shows.
    $start    = $p.Hours[0]
    $expected = 0..3 | ForEach-Object { ($start + $_) % 24 }
    if (($p.Hours -join ',') -ne ($expected -join ',')) {
        Fail "Period '$($p.Key)' hours [$($p.Hours -join ',')] are not start+0..3 [$($expected -join ',')]"
    }
}
OK 'All six periods are start + 0..3 mod 24 (inclusive end)'

# ----------------------------------------------------------------------------
Step '4. Night is the only period that crosses midnight'
# ----------------------------------------------------------------------------
$wrapping = @($periods | Where-Object { $_.Hours[0] -gt $_.Hours[3] })
if ($wrapping.Count -ne 1) {
    Fail "Expected exactly 1 midnight-crossing period, found $($wrapping.Count): $(($wrapping | ForEach-Object { $_.Key }) -join ', ')"
}
if ($wrapping[0].Key -ne 'night') { Fail "The wrapping period is '$($wrapping[0].Key)', expected 'night'" }
if (($wrapping[0].Hours -join ',') -ne '23,0,1,2') {
    Fail "Night hours are [$($wrapping[0].Hours -join ',')], expected [23,0,1,2]"
}
OK 'Night = {23,0,1,2} and is the only period spanning two dates'

# ----------------------------------------------------------------------------
Step '5. /Receiving renders the SAME six periods (one shared definition)'
# ----------------------------------------------------------------------------
# The whole point of lifting the list into ReceivingPeriods was that the grid
# and the report cannot disagree. If this page ever goes back to a hardcoded
# option list, this step catches the divergence the moment the two drift.
$recv = (Invoke-WebRequest -Uri "$base/Receiving?pull=PL-2847" -WebSession $sv -UseBasicParsing).Content
$recvSel = [regex]::Match($recv, '(?s)<select[^>]*id="period-select"[^>]*>(.*?)</select>')
if (-not $recvSel.Success) { Fail 'No #period-select on /Receiving' }

$recvStarts = @([regex]::Matches($recvSel.Groups[1].Value, '<option value="(\d{2})"') |
    ForEach-Object { [int]$_.Groups[1].Value })
if ($recvStarts.Count -ne 6) { Fail "Receiving renders $($recvStarts.Count) periods, expected 6" }

$reportStarts = @($periods | ForEach-Object { $_.Hours[0] })
if ((($recvStarts | Sort-Object) -join ',') -ne (($reportStarts | Sort-Object) -join ',')) {
    Fail ("Receiving start hours [$(($recvStarts | Sort-Object) -join ',')] " +
          "differ from Reports [$(($reportStarts | Sort-Object) -join ',')] — the definition is no longer shared")
}
OK 'Receiving and Reports render identical period start hours'

Write-Host "`nALL PASS — period map is complete and shared" -ForegroundColor Green
exit 0
