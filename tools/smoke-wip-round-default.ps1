# Smoke: a WIP row with a blank ROUND defaults to hour 07 on manual upload.
#
# The two ingestion paths treat WIP differently on purpose. The ERP pull
# (BpiPrsSource / PrbPrsSource) SKIPS any pull sheet carrying a WIP row, at
# PRS_ID grain. The manual workbook upload at /Imports accepts them — an
# operator uploading the file is deliberately bringing that data in — and a
# WIP row whose ROUND is blank lands on hour 07 rather than failing the file.
#
# Before this, such a row failed validation ("...The receiving hour cannot be
# guessed"), and because the import is atomic ONE blank ROUND rejected the
# whole workbook: 32 of 32 rows in Test WIPKIT v01.xlsx.
#
# The default is narrow and both halves matter:
#   WIP + blank        → hour 07
#   WIP + a value      → that value, never 07  (the default fills a gap,
#                        it does not override)
#   WIP + unusable     → still an error        (a wrong value is a defect;
#                        only ABSENCE is defaulted)
#   non-WIP            → untouched by any of it
#
# Fixtures authored by tools/build-wip-fixture.ps1 (one-shot, not in battery).
# Namespaced WIPRND- — a range no other smoke purges — so this can run beside
# smoke-wip-pull-synthesis.ps1 without either one's cleanup reaching the
# other's rows.
#
# Asserts:
#   1. WIP + blank ROUND      → imports clean, no issue raised, window at hour 07
#   2. WIP + populated ROUND  → uses the given value (11), not 07
#   3. non-WIP + blank ROUND  → unchanged by this feature (see §3 for what
#                               "unchanged" actually means here)
#   4. Mixed workbook (WIP blank + WIP populated + non-WIP populated) → all
#      commit, hours land per row
#   5. Several blank WIP rows on one sheet → ONE hour-07 window carrying the
#      SUMMED qty, not duplicates. PullItemWindows is unique on
#      (PullItemId, HourOfDay), so getting this wrong is a hard failure.
#   6. A defaulted row surfaces under Morning on the Pull Sheets report
#   7. WIP + unusable ROUND ('03:00|04:00') still rejected — the guard that
#      keeps the default from being widened into swallowing real defects
#   8. Source: the resolver gates on WIP and on blankness, in ONE definition

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$fixtures = Join-Path $repoRoot 'tools\fixtures'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }
function Sql($q)  { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }
function SqlScalar($q) {
    $out = (Sql $q) | Where-Object { $_ -and $_.Trim() -ne '' } | Select-Object -First 1
    if ($null -eq $out) { return '' }
    return $out.Trim()
}

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body `
        -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Purge every WIPRND- artefact. FK order: receipts → windows → items → pulls,
# and lines → POs. FK_PullSig_Pull / FK_PO_Pull do NOT cascade from dbo.Pulls,
# so signatures go first and POs are unlinked before the pull delete — a
# set-based DELETE is all-or-nothing and one blocked pull strands the range.
# See docs/defect-pull-signature-fk-blocks-smoke-cleanup.md.
function Cleanup {
    Sql @"
SET NOCOUNT ON;
DELETE r FROM dbo.Receipts r
  INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'WIPRND-%';
DELETE r FROM dbo.Receipts r
  INNER JOIN dbo.PurchaseOrders po ON po.Id = r.PurchaseOrderId
WHERE po.PoNumber LIKE 'WIPRND-%';
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'WIPRND-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'WIPRND-%';
DELETE pol FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'WIPRND-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'WIPRND-%';
DELETE s FROM dbo.PullSignatures s
  INNER JOIN dbo.Pulls p ON p.Id = s.PullId
WHERE p.PullNumber LIKE 'WIPRND-%';
UPDATE po SET PullId = NULL FROM dbo.PurchaseOrders po
  INNER JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE p.PullNumber LIKE 'WIPRND-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'WIPRND-%';
DELETE FROM dbo.PoImportLog WHERE FileName IN
    ('po-import-wip-round-default.xlsx','po-import-nonwip-blank-round.xlsx','po-import-wip-bad-round.xlsx');
DELETE FROM dbo.AuditLog WHERE EntityId LIKE 'WIPRND-%';
"@ | Out-Null
}

function Upload($session, $fixtureName) {
    $path = Join-Path $fixtures $fixtureName
    if (-not (Test-Path $path)) { Fail "Fixture missing: $path — run tools/build-wip-fixture.ps1" }
    return Invoke-RestMethod -Uri "$base/api/imports/po/upload" -Method POST `
        -WebSession $session -Form @{ file = Get-Item -LiteralPath $path }
}

function ConfirmAndWait($session, $runId, $label) {
    Invoke-RestMethod -Uri "$base/api/imports/po/$runId/confirm" -Method POST -WebSession $session | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $row = Invoke-RestMethod -Uri "$base/api/imports/po/$runId" -WebSession $session
        if ($row.status -eq 'succeeded') { return $row }
        if ($row.status -eq 'failed')    { Fail "$label — import failed: $($row.errorMessage)" }
        Start-Sleep -Milliseconds 800
    }
    Fail "$label — import did not reach a terminal status within 60s"
}

# "hour/expected" for every window on a (pull, sku), ordered by hour.
function Windows($pullNumber, $sku) {
    $rows = Sql @"
SET NOCOUNT ON;
SELECT CAST(w.HourOfDay AS VARCHAR) + '/' + CAST(w.ExpectedQty AS VARCHAR)
FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$pullNumber' AND pi.ItemCode = '$sku'
ORDER BY w.HourOfDay;
"@
    return (($rows | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }) -join ',')
}

try {
    # ------------------------------------------------------------------
    Step "0. Preconditions — server up, fixtures present, clean slate"
    try { Invoke-WebRequest -Uri "$base/Account/Login" -UseBasicParsing -TimeoutSec 10 | Out-Null }
    catch { Fail "Dev server not reachable at $base — start it with: dotnet run --launch-profile http" }

    Cleanup
    $leftovers = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Pulls WHERE PullNumber LIKE 'WIPRND-%';")
    if ($leftovers -ne 0) { Fail "Cleanup left $leftovers WIPRND pull(s) behind" }
    $sup = Login 'swattana' 'demo1234' $WH_01
    OK "fixtures namespace clear, supervisor session at WH-01"

    # ------------------------------------------------------------------
    # Assertions 1, 2, 4 and 5 all ride on this one workbook, because the
    # claim being made is about a whole file reviewing clean and committing —
    # not about four unrelated rows.
    Step "1. Review is CLEAN — a blank WIP ROUND raises no issue, warning or notice"
    $up = Upload $sup 'po-import-wip-round-default.xlsx'
    if ($up.status -ne 'validated') {
        $msgs = ($up.validationErrorsPreview | ForEach-Object { $_.message }) -join ' | '
        Fail "status='$($up.status)', expected 'validated'. Errors: $msgs"
    }
    if ($up.validationErrorCount -ne 0) {
        Fail "validationErrorCount=$($up.validationErrorCount), expected 0 — the default must be silent"
    }
    # The whole point of "silent": no issue anywhere in the operator's payload
    # mentions ROUND. A warnings array added later that carries the default
    # would trip this.
    $payload = $up | ConvertTo-Json -Depth 8
    if ($payload -match 'ROUND') {
        Fail "the upload response mentions ROUND — the default must not surface to the operator: $payload"
    }
    if ($up.wip.pullCount -ne 1)   { Fail "wip.pullCount=$($up.wip.pullCount), expected 1 (the WIP sheet only)" }
    if ($up.wip.createCount -ne 1) { Fail "wip.createCount=$($up.wip.createCount), expected 1" }
    OK "workbook whose only problem was blank WIP ROUNDs reviews clean: 0 errors, nothing mentions ROUND"

    # ------------------------------------------------------------------
    Step "2. Commit — assertions 1, 2, 4, 5"
    ConfirmAndWait $sup $up.runId 'round-default' | Out-Null

    # 5. TWO blank rows on the same (sheet, SKU) → ONE window, qty summed.
    #    Two windows here would mean a duplicate; 10 or 15 alone would mean a
    #    row was dropped rather than summed.
    $d1 = Windows 'WIPRND-0001' 'WIPRNDSKU-D1'
    if ($d1 -ne '7/25') {
        Fail "D1 windows='$d1', expected '7/25' — two blank-ROUND rows must collapse into ONE hour-07 window of 10+15"
    }

    # 2. A populated ROUND is used as given. If the default ever overrode
    #    rather than filled a gap, this would read 7/30.
    $d2 = Windows 'WIPRND-0001' 'WIPRNDSKU-D2'
    if ($d2 -ne '11/30') { Fail "D2 windows='$d2', expected '11/30' — a populated ROUND must win over the default" }

    # 1. A blank row on its own item still lands at 07.
    $d3 = Windows 'WIPRND-0001' 'WIPRNDSKU-D3'
    if ($d3 -ne '7/40') { Fail "D3 windows='$d3', expected '7/40'" }

    # 4. The non-WIP sheet in the same workbook commits as an ordinary PO with
    #    no pull, exactly as before.
    $plainPull = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Pulls WHERE PullNumber = 'WIPRND-0002';")
    if ($plainPull -ne 0) { Fail "non-WIP sheet WIPRND-0002 synthesised a pull — it must not" }
    $plainPo = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PurchaseOrders WHERE PoNumber = 'WIPRND-0002';")
    if ($plainPo -ne 1) { Fail "non-WIP sheet WIPRND-0002 produced $plainPo PO(s), expected 1" }
    OK "blank→07 (x2 collapsed to one window of 25, and one of 40), 11:00→11, non-WIP sheet an ordinary PO with no pull"

    # ------------------------------------------------------------------
    Step "3. Assertion 3 — a NON-WIP sheet with a blank ROUND is untouched by the feature"
    # Stated precisely, because the honest claim is narrower than "still fails":
    # ROUND is not a required header and PoImportReader.ValidateRow has never
    # inspected it, so the ONLY blank-ROUND rejection that has ever existed in
    # this codebase is the WIP one. A non-WIP sheet with a blank ROUND
    # therefore imports cleanly today and imported cleanly before — what this
    # asserts is that the default did NOT leak onto it and invent a pull.
    $upN = Upload $sup 'po-import-nonwip-blank-round.xlsx'
    if ($upN.status -ne 'validated') { Fail "non-WIP blank ROUND: status='$($upN.status)', expected 'validated'" }
    # A file with no WIP sheets carries no wip summary at all, so absent and
    # zero are both correct here; a pullCount above zero is not.
    $nPlanned = if ($null -eq $upN.wip) { 0 } else { [int]$upN.wip.pullCount }
    if ($nPlanned -ne 0) { Fail "non-WIP blank ROUND planned $nPlanned WIP pull(s), expected 0" }
    ConfirmAndWait $sup $upN.runId 'nonwip-blank-round' | Out-Null

    $nPull = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Pulls WHERE PullNumber = 'WIPRND-0004';")
    if ($nPull -ne 0) { Fail "non-WIP blank-ROUND sheet synthesised a pull — the default reached a row it must not" }
    $nWin = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = 'WIPRND-0004';
"@)
    if ($nWin -ne 0) { Fail "non-WIP blank-ROUND sheet produced $nWin window(s) at hour 07 — the default is WIP-only" }
    OK "non-WIP blank ROUND: no pull, no hour-07 window — the default did not generalise"

    # ------------------------------------------------------------------
    Step "4. Assertion 7 — a WIP ROUND that is PRESENT but unusable is still rejected"
    # The mutation guard for widening. '03:00|04:00' names two windows; a
    # default that swallowed it would put stock in the wrong hour silently.
    $upB = Upload $sup 'po-import-wip-bad-round.xlsx'
    if ($upB.status -ne 'validation_failed') {
        Fail "unusable ROUND: status='$($upB.status)', expected 'validation_failed' — only ABSENCE is defaulted"
    }
    $bMsgs = ($upB.validationErrorsPreview | ForEach-Object { $_.message }) -join ' | '
    if ($bMsgs -notmatch 'unusable ROUND') { Fail "unusable ROUND: error text was '$bMsgs'" }
    $bRows = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.Pulls WHERE PullNumber = 'WIPTEST-0008';")
    if ($bRows -ne 0) { Fail "unusable-ROUND file committed $bRows pull(s) — it must reject at Stage 1" }
    OK "'03:00|04:00' still rejected at Stage 1, nothing committed"

    # ------------------------------------------------------------------
    Step "5. Assertion 6 — a defaulted row surfaces under Morning on the Pull Sheets report"
    # Hour 07 is the first hour of ReceivingPeriods.Morning (07-10 inclusive).
    # This is the end of the path the brief asks to confirm rather than assume:
    # ROUND → WipWindowPlan.HourOfDay → PullItemWindows.HourOfDay → the
    # report's period filter.
    $pullDate = SqlScalar "SET NOCOUNT ON; SELECT CONVERT(varchar(10), PullDate, 23) FROM dbo.Pulls WHERE PullNumber = 'WIPRND-0001';"
    if ([string]::IsNullOrWhiteSpace($pullDate)) { Fail "WIPRND-0001 has no PullDate — the synthesis did not run" }

    $prev = Invoke-RestMethod -WebSession $sup `
        -Uri "$base/api/reports/pull-sheets/preview?warehouseId=$WH_01&date=$pullDate&period=morning"
    if ($prev.periodLabel -ne 'Morning') { Fail "periodLabel='$($prev.periodLabel)', expected 'Morning'" }
    if ($prev.pullNumbers -notcontains 'WIPRND-0001') {
        Fail "WIPRND-0001 absent from the Morning report on $pullDate. Pulls found: $($prev.pullNumbers -join ', ')"
    }
    $skus = $prev.summaryPreview | ForEach-Object { $_.itemCode }
    if ($skus -notcontains 'WIPRNDSKU-D1') { Fail "defaulted item WIPRNDSKU-D1 absent from Morning summary. Got: $($skus -join ', ')" }
    if ($skus -notcontains 'WIPRNDSKU-D3') { Fail "defaulted item WIPRNDSKU-D3 absent from Morning summary. Got: $($skus -join ', ')" }
    # The 11:00 item is Midday-and-later, NOT Morning (07-10 inclusive) — if it
    # showed up here the period filter would be reading everything, and the two
    # assertions above would prove nothing.
    if ($skus -contains 'WIPRNDSKU-D2') { Fail "the 11:00 item appears under Morning — the period filter is not discriminating" }
    $d1Row = $prev.summaryPreview | Where-Object { $_.itemCode -eq 'WIPRNDSKU-D1' } | Select-Object -First 1
    if ($d1Row.expectedQty -ne 25) { Fail "Morning report shows D1 expectedQty=$($d1Row.expectedQty), expected 25" }
    OK "defaulted rows land in Morning with the summed qty; the 11:00 row correctly does not"

    # ------------------------------------------------------------------
    Step "6. Assertion 8 — the resolver is ONE definition gated on WIP and on blankness"
    # Source-level, and kept alongside the behavioural checks rather than
    # instead of them: §3's behavioural proof is weak on its own, because a
    # non-WIP row never reaches the ROUND code path at all, so a widened gate
    # would not show up there. This is the check that would.
    $synthPath = Join-Path $repoRoot 'src\ReceivingOps.Web\Services\PoImport\WipPullSynthesis.cs'
    $synth = Get-Content $synthPath -Raw

    $resolver = [regex]::Match($synth,
        '(?s)public static bool TryResolveRoundHour\(.*?\n    \}')
    if (-not $resolver.Success) { Fail "TryResolveRoundHour not found in WipPullSynthesis.cs" }
    $body = $resolver.Value

    # Both halves of the gate, as the CONDITIONAL, not as loose tokens.
    # Matching 'isWipRow' anywhere in the body is not this check: the
    # parameter is named in the signature, so deleting the gate from the
    # `if` still matched it and the mutation went undetected on the first
    # attempt. The assertion has to name the expression it is protecting.
    if ($body -notmatch 'if \(isWipRow && string\.IsNullOrWhiteSpace\(round\)\)') {
        Fail "TryResolveRoundHour's guard is not 'if (isWipRow && string.IsNullOrWhiteSpace(round))' — " +
             "dropping either half widens the default onto rows that must keep failing"
    }
    if ($body -notmatch 'WipBlankRoundHour') {
        Fail "TryResolveRoundHour does not use the WipBlankRoundHour constant"
    }
    if ($synth -notmatch 'public const byte WipBlankRoundHour = 7;') {
        Fail "WipBlankRoundHour is not 7 — the brief specifies hour 07 always"
    }

    # One definition, not two: the resolver is the only place a default hour
    # is produced. TryParseRoundHour stays a pure parser.
    $parser = [regex]::Match($synth, '(?s)public static bool TryParseRoundHour\(.*?\n    \}')
    if (-not $parser.Success) { Fail "TryParseRoundHour not found" }
    if ($parser.Value -match 'WipBlankRoundHour') {
        Fail "TryParseRoundHour applies the default — it must stay a parser, or every caller silently inherits it"
    }

    # And the callers that decide an hour go through the resolver.
    $groupBy = [regex]::Match($synth, '(?s)foreach \(var hourGroup in itemGroup.*?\.OrderBy\(g => g\.Key\)\)')
    if (-not $groupBy.Success) { Fail "hour GroupBy not found — re-check the window grouping" }
    if ($groupBy.Value -notmatch 'TryResolveRoundHour') {
        Fail "the window GroupBy does not use TryResolveRoundHour — blank rows would be accepted then grouped into hour 0"
    }
    OK "one gated definition; parser stays default-free; the window GroupBy resolves rather than parses"

    # ------------------------------------------------------------------
    Step "7. WIP detection is still a single shared predicate"
    if ($synth -notmatch 'public static bool IsWipStorerCode\(string\? storerCode\)') {
        Fail "IsWipStorerCode signature changed — every caller keys off this one definition"
    }
    if ($synth -notmatch 'Contains\("WIP", StringComparison\.OrdinalIgnoreCase\)') {
        Fail "IsWipStorerCode is no longer a case-insensitive substring match on WIP"
    }
    OK "IsWipStorerCode unchanged — ERP skip and import default still share one WIP definition"
}
finally {
    Cleanup
}

Write-Host "`nAll WIP blank-ROUND default assertions passed." -ForegroundColor Green
exit 0
