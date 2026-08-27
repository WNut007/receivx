# Smoke: the ERP feed does not touch WIP.
#
# WIP pull sheets are built by the PO import, which synthesises the pull, its
# items, its windows, and a purchase order to receive against. The ERP feed
# knows nothing about that synthetic PO, so if it ever took a WIP pull over,
# an item it omitted would be canceled while its PO line kept the ReceivedQty
# already booked against it — a canceled item with live received quantity
# behind it and nothing to detect it.
#
# Two defences, deliberately keyed on different things:
#   - BpiPrsSource / PrbPrsSource drop WIP pull sheets at SHEET grain, before
#     a draft exists. Keyed on the STORER CODE.
#   - ErpUpsertService refuses to update or cancel a pull whose Origin is
#     'po-import'. Keyed on PROVENANCE.
# Either alone leaves a gap; the source filter cannot see a synthesised pull
# that later appears under a non-WIP storer, and the upsert guard cannot stop
# the feed creating WIP pulls of its own.
#
# Asserts:
#   1. Source shape — both readers filter at sheet grain and both reuse
#      WipPullSynthesis.IsWipStorerCode rather than carrying a second copy of
#      the rule; ErpUpsertService carries the Origin guard; the counters reach
#      SourceTotals
#   2. Transform behaviour, no ERP and no DB required (via ErpUpsertHarness):
#      an all-WIP sheet produces no pull; a MIXED WIP/non-WIP sheet produces
#      no pull either (the sheet-grain case — row grain would leave the pull
#      in the draft and let the orphan pass cancel its WIP items); detection
#      is case-insensitive substring; an ordinary sheet in the same batch is
#      untouched
#   3. Live run — no WIP sheet in the backfill window draws an etl-create or
#      etl-update row
#   4. Live run — pre-existing ERP-fed WIP pulls are neither updated nor
#      cancelled: byte-identical fingerprint across the run. 21 such pulls sat
#      in the window when this was written, so before the filter every one of
#      them was rewritten on every fire
#   5. Live run — pulls the PO import synthesised are untouched: item count,
#      Status, PullDate and windows all unchanged
#   6. Live run — non-WIP sheets still sync normally (the filter is not a
#      blanket off-switch)
#   7. Live run — the skip is REPORTED: SourceTotals carries the WIP counters
#      and the etl-end audit row names them. A run that drops 600+ rows and
#      says nothing is indistinguishable from a feed that shrank
#
# Sections 3-7 SKIP cleanly when the ERP host is unreachable (no VPN), same
# convention as the other Phase 10/13 smokes. Sections 1-2 always run.
#
# Note for whoever adds the first firing SkippedSynthesised case: it emits an
# 'etl-skip' audit row that smoke-phase-10-7 §1 does not expect, because that
# reconciliation sums the four ErpSyncLog scalar columns and this counter lives
# in SourceTotals JSON. It cannot fire today (every synthesised pull is WIP, so
# the sheet filter drops it long before the upsert sees it), which is why 10-7
# is left alone rather than pre-emptively patched.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$webRoot = Join-Path $repoRoot 'src\ReceivingOps.Web'
$erpSync = Join-Path $webRoot 'Services\ErpSync'
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Skip($m) { Write-Host "SKIP: $m" -ForegroundColor DarkYellow }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
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

function WaitForJob($session, $jobId, $timeoutSec = 180) {
    $terminal = @('Succeeded', 'Failed', 'Deleted')
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $state = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try {
            $s = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/jobs/$jobId" `
                -Method GET -WebSession $session -ErrorAction Stop
            $state = $s.state
            if ($state -in $terminal) { return $state }
        } catch { }
    }
    return $state
}

function Src([string]$file) {
    $p = Join-Path $erpSync $file
    if (-not (Test-Path $p)) { Fail "Expected source file not found: $p" }
    return (Get-Content -Raw -LiteralPath $p)
}

# ============================================================================
# SECTION 1 — source shape
# ============================================================================
Step "Section 1: both readers filter at sheet grain, reusing the importer's predicate"

$bpi = Src 'BpiPrsSource.cs'
$prb = Src 'PrbPrsSource.cs'
$ups = Src 'ErpUpsertService.cs'
$job = Src 'ErpSyncJob.cs'
$dft = Src 'ErpSyncDrafts.cs'

foreach ($pair in @(@{n='BpiPrsSource'; s=$bpi}, @{n='PrbPrsSource'; s=$prb})) {
    $name = $pair.n; $body = $pair.s

    if ($body -notmatch 'using ReceivingOps\.Web\.Services\.PoImport;') {
        Fail "$name does not import the PoImport namespace — it cannot be reusing the importer's predicate"
    }
    # The predicate must be CALLED, not reimplemented. A local Contains("WIP")
    # would pass a naive "does it filter" check while quietly drifting from the
    # importer's definition of a WIP sheet.
    if ($body -notmatch 'WipPullSynthesis\.IsWipStorerCode\(') {
        Fail "$name does not call WipPullSynthesis.IsWipStorerCode"
    }
    if ($body -match '\.Contains\(\s*"WIP"') {
        Fail "$name carries its own inline WIP substring test — that is the second copy the shared predicate exists to prevent"
    }
    # Sheet grain: the test is over the whole PRS_ID group (pullGroup.Any),
    # not over a single row inside the item loop.
    if ($body -notmatch 'if \(pullGroup\.Any\(r => WipPullSynthesis\.IsWipStorerCode\(r\.VENDOR\)\)\)') {
        Fail "$name does not test the whole pull-sheet group — filter is not at sheet grain"
    }
    if ($body -notmatch 'draft\.NoteWipSkippedSheet\(') {
        Fail "$name drops WIP sheets without recording them"
    }
    OK "$name filters at sheet grain via the shared predicate and records the skip"
}

# The counting lives on the draft so the two readers cannot drift on what
# counts as mixed or on where the sample list is capped.
foreach ($m in @('WipSkippedRowCount','WipSkippedPullCount','WipMixedPullCount',
                 'WipMixedNonWipRowCount','WipMixedNonWipQty','NoteWipSkippedSheet')) {
    if ($dft -notmatch [regex]::Escape($m)) { Fail "ErpSyncDrafts.cs missing $m" }
}
OK "ErpSyncDraft carries the skip counters + the shared NoteWipSkippedSheet recorder"

# Origin guard — provenance-keyed, and ahead of the closed check so a closed
# synthesised pull is attributed to the guard rather than to 'closed'.
if ($ups -notmatch 'existing\.Origin, WipPullSynthesis\.OriginPoImport') {
    Fail "ErpUpsertService has no Origin guard — the feed can still take over a synthesised pull"
}
$guardIdx  = $ups.IndexOf('existing.Origin, WipPullSynthesis.OriginPoImport')
$closedIdx = $ups.IndexOf('if (string.Equals(existing.Status, "closed"')
if ($guardIdx -lt 0 -or $closedIdx -lt 0) { Fail "Could not locate both guards in ErpUpsertService" }
if ($guardIdx -gt $closedIdx) {
    Fail "Origin guard sits AFTER the closed check — a closed synthesised pull would be counted as skipped-closed"
}
if ($ups -notmatch 'SkippedSynthesised\+\+') { Fail "ErpUpsertService does not count the synthesised skip" }
OK "ErpUpsertService refuses po-import pulls, ahead of the closed check, and counts it"

# The db/050 cancel-synth block is now unreachable; it is kept on purpose as a
# tripwire, so a future 'tidy up dead code' pass has something to read first.
if ($ups -notmatch 'etl-cancel-synth') {
    Fail "The etl-cancel-synth tripwire was removed — deleting it means a removed Origin guard leaves no trail"
}
OK "etl-cancel-synth tripwire retained"

foreach ($m in @('WipSkippedRowCount','WipSkippedPullCount','WipMixedPullCount',
                 'SkippedSynthesised','SkippedRowCount','wipSkipRows','wipSkipSheets')) {
    if ($job -notmatch [regex]::Escape($m)) { Fail "ErpSyncJob.cs does not surface $m" }
}
# SkippedRowCount was counted since Phase 10.2 and read by nothing until now.
if ($job -notmatch 'SkippedRowCount\s*=\s*draft\.SkippedRowCount') {
    Fail "ErpSyncJob still does not read draft.SkippedRowCount — the dead-end counter is back"
}
OK "ErpSyncJob carries every skip counter into SourceTotals, including the previously-dead SkippedRowCount"

# ============================================================================
# SECTION 2 — transform behaviour (no ERP, no DB)
# ============================================================================
Step "Section 2: transform drops WIP sheets whole"

$harness = Join-Path $repoRoot 'tools\ErpUpsertHarness'
& dotnet build $harness -v q --nologo 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "ErpUpsertHarness failed to build" }

function Transform([string]$scenario) {
    $out = & dotnet run --project $harness --no-build -- $scenario 2>$null
    $line = ($out | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1)
    if (-not $line) { Fail "Harness produced no JSON for scenario '$scenario'" }
    return ($line | ConvertFrom-Json)
}

$r = Transform 'transform-wip-sheet'
if ($r.pulls.Count -ne 0)          { Fail "all-WIP sheet produced $($r.pulls.Count) pull(s); expected 0" }
if ($r.wipSkippedRowCount -ne 2)   { Fail "all-WIP sheet: wipSkippedRowCount=$($r.wipSkippedRowCount), expected 2" }
if ($r.wipSkippedPullCount -ne 1)  { Fail "all-WIP sheet: wipSkippedPullCount=$($r.wipSkippedPullCount), expected 1" }
if ($r.wipMixedPullCount -ne 0)    { Fail "all-WIP sheet counted as mixed" }
OK "An all-WIP sheet produces no pull, and both rows are counted"

# The sheet-grain case. Under a row-grain filter this sheet would survive
# carrying only its two non-WIP items, and ErpUpsertService's orphan pass would
# then cancel the WIP item on the existing pull — the exact outcome the whole
# change exists to prevent.
$r = Transform 'transform-wip-mixed'
if ($r.pulls.Count -ne 0) {
    Fail "MIXED sheet produced $($r.pulls.Count) pull(s); expected 0. Filter has regressed to row grain — a mixed sheet now reaches the upsert with its WIP items missing, and the orphan pass will cancel them"
}
if ($r.wipSkippedRowCount -ne 3)      { Fail "mixed sheet: wipSkippedRowCount=$($r.wipSkippedRowCount), expected 3 (the whole sheet)" }
if ($r.wipMixedPullCount -ne 1)       { Fail "mixed sheet not reported as mixed" }
if ($r.wipMixedNonWipRowCount -ne 2)  { Fail "mixed sheet: non-WIP row cost=$($r.wipMixedNonWipRowCount), expected 2" }
if ($r.wipMixedNonWipQty -ne 1640)    { Fail "mixed sheet: non-WIP qty cost=$($r.wipMixedNonWipQty), expected 1640" }
if ($r.wipMixedPullNumbers -notcontains 'HARNESS-W2') { Fail "mixed sheet PRS_ID not named in the report" }
OK "A MIXED sheet produces no pull, and the non-WIP rows it costs are reported by number, not absorbed"

$r = Transform 'transform-wip-casing'
if ($r.pulls.Count -ne 0)         { Fail "'coi-WiPbp1' was not detected as a WIP storer — detection is not case-insensitive substring" }
if ($r.wipSkippedPullCount -ne 1) { Fail "casing scenario: sheet not counted" }
OK "Detection is case-insensitive substring, matching the importer"

$r = Transform 'transform-wip-and-clean'
if ($r.pulls.Count -ne 1)         { Fail "expected exactly 1 surviving pull, got $($r.pulls.Count)" }
if ($r.pulls[0].PullNumber -ne 'HARNESS-W4-CLEAN') { Fail "the wrong pull survived: $($r.pulls[0].PullNumber)" }
if ($r.pulls[0].items.Count -ne 2){ Fail "ordinary sheet lost items: $($r.pulls[0].items.Count) of 2" }
$totalQty = ($r.pulls[0].items | Measure-Object -Property qty -Sum).Sum
if ($totalQty -ne 750)            { Fail "ordinary sheet qty=$totalQty, expected 750" }
if ($r.wipSkippedPullCount -ne 1) { Fail "the WIP sheet in the same batch was not counted" }
OK "A WIP sheet in the same batch leaves an ordinary sheet completely untouched"

# ============================================================================
# Preflight for the live sections
# ============================================================================
Step "Preflight — dev server + ERP reachability"

$serverUp = $false
try {
    $probe = Invoke-WebRequest -Uri "$base/api/auth/me" -Method GET -UseBasicParsing -ErrorAction Stop
    $serverUp = ($probe.StatusCode -in @(200, 401))
} catch {
    $sc = $null
    try { $sc = $_.Exception.Response.StatusCode.value__ } catch { }
    $serverUp = ($sc -in @(200, 401))
}
if (-not $serverUp) {
    Skip "Dev server not responding — live sections 3-7 skipped"
    Write-Host "`nALL PASS — sections 1-2 (source + transform) green; live sections skipped." -ForegroundColor Green
    exit 0
}
OK "Dev server up"

$secretsList = & dotnet user-secrets list --project (Join-Path $webRoot 'ReceivingOps.Web.csproj') 2>$null
$hasErpDb = $secretsList | Where-Object { $_ -match '^ErpDb:ConnectionString' }
$reachable = $false; $erpServer = $null; $erpUser = $null; $erpPass = $null; $erpDbName = 'CW'
if ($hasErpDb) {
    $cs = ($hasErpDb -split '=', 2)[1].Trim()
    foreach ($part in ($cs -split ';')) {
        if ($part -match '^\s*Server\s*=\s*(.+)$')            { $erpServer = $matches[1].Trim() }
        if ($part -match '^\s*Database\s*=\s*(.+)$')          { $erpDbName = $matches[1].Trim() }
        if ($part -match '^\s*User\s*Id\s*=\s*(.+)$')         { $erpUser   = $matches[1].Trim() }
        if ($part -match '^\s*Password\s*=\s*(.+)$')          { $erpPass   = $matches[1].Trim() }
    }
    if ($erpServer) {
        $tcpHost = $erpServer
        if ($tcpHost -match '^(.+?)\\') { $tcpHost = $matches[1] }
        if ($tcpHost -match '^(.+?),\d+$') { $tcpHost = $matches[1] }
        $port = if ($erpServer -match ',(\d+)$') { [int]$matches[1] } else { 1433 }
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($tcpHost, $port, $null, $null)
        $reachable = $async.AsyncWaitHandle.WaitOne(2000)
        if ($reachable) { try { $tcp.EndConnect($async) } catch { $reachable = $false } }
        $tcp.Close()
    }
}
if (-not $reachable) {
    Skip "ERP DB unreachable — live sections 3-7 skipped (firewall/VPN)"
    Write-Host "`nALL PASS — sections 1-2 (source + transform) green; live sections skipped." -ForegroundColor Green
    exit 0
}
OK "ERP reachable"

function ErpSql($q) {
    return sqlcmd -S $erpServer -U $erpUser -P $erpPass -C -d $erpDbName -I -h -1 -W -l 20 -Q $q
}

# The job reads its window from config, so the smoke must read the same value
# rather than assume one — a /Config edit would otherwise silently make the
# assertions compare different row sets.
$backfill = SqlScalar "SET NOCOUNT ON; SELECT ISNULL(TRY_CONVERT(int, [Value]), 2) FROM dbo.AppSettings WHERE [Key] = 'ErpSync:Sources:Bpi:BackfillDays';"
if (-not $backfill) { $backfill = '2' }
OK "BPI backfill window = $backfill day(s)"

$wipIds = ErpSql "SET NOCOUNT ON; SELECT DISTINCT PRS_ID FROM dbo.BPI_PRS WHERE DeliveryDate >= CAST(DATEADD(day,-$backfill,GETUTCDATE()) AS date) AND VENDOR LIKE '%WIP%' AND PRS_ID IS NOT NULL;" |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if (-not $wipIds -or $wipIds.Count -eq 0) {
    Skip "No WIP sheets in the current $backfill-day window — nothing for the live sections to prove"
    Write-Host "`nALL PASS — sections 1-2 green; live sections had no WIP rows to exercise." -ForegroundColor Green
    exit 0
}
$wipInList = ($wipIds | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
OK "$($wipIds.Count) WIP pull sheet(s) in the window — the feed must ignore every one"

# ============================================================================
# SECTION 3-7 — live run
# ============================================================================
Step "Section 3: snapshot, then run a sync"

# Fingerprint = order-independent checksum over everything the ETL is able to
# write on a pull, plus the row count. Any update, insert, or cancel moves it.
$fingerprintSql = @"
SET NOCOUNT ON;
SELECT CONVERT(varchar(20), ISNULL(CHECKSUM_AGG(CHECKSUM(
           p.PullNumber, CONVERT(varchar(10), p.PullDate, 23), p.Status,
           pi.ItemCode, ISNULL(pi.VendorCode,''), pi.Status,
           w.HourOfDay, w.ExpectedQty)), 0))
     + '/' + CONVERT(varchar(20), COUNT(*))
FROM   dbo.Pulls p
LEFT JOIN dbo.PullItems pi ON pi.PullId = p.Id
LEFT JOIN dbo.PullItemWindows w ON w.PullItemId = pi.Id
WHERE  {0};
"@

$erpWipWhere  = "p.PullNumber IN ($wipInList) AND p.Origin IS NULL"
$synthWhere   = "p.Origin = 'po-import'"

$erpWipBefore = SqlScalar ($fingerprintSql -f $erpWipWhere)
$synthBefore  = SqlScalar ($fingerprintSql -f $synthWhere)
$erpWipCount  = SqlScalar "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Pulls p WHERE $erpWipWhere;"
$synthCount   = SqlScalar "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Pulls p WHERE $synthWhere;"
OK "Snapshot: $erpWipCount pre-existing ERP-fed WIP pull(s) in window [$erpWipBefore]; $synthCount synthesised pull(s) [$synthBefore]"

if ([int]$erpWipCount -eq 0) {
    Skip "No pre-existing ERP-fed WIP pull sits in the window — section 4 proves nothing today"
}

$auditBefore = SqlScalar "SET NOCOUNT ON; SELECT ISNULL(MAX(Id), 0) FROM dbo.AuditLog;"
$admin = Login 'sadmin' 'admin' $WH_01

$trig = Invoke-WebRequest -Uri "$base/api/admin/erp-sync/trigger" -Method POST `
    -Body (@{ sourceName = 'BPI_PRS' } | ConvertTo-Json) -ContentType 'application/json' `
    -WebSession $admin -UseBasicParsing
if ($trig.StatusCode -ne 202) { Fail "Trigger returned $($trig.StatusCode)" }
$jobId = ($trig.Content | ConvertFrom-Json).jobId
$state = WaitForJob $admin $jobId
if ($state -ne 'Succeeded') { Fail "Sync did not Succeed — final state: $state" }

$newest = (Invoke-RestMethod -Uri "$base/api/admin/erp-sync/log?page=1&pageSize=1" -Method GET -WebSession $admin).items[0]
if (-not $newest) { Fail "ErpSyncLog has no row after the trigger" }
$runId = $newest.runId
OK "Run $runId completed — created=$($newest.created), updated=$($newest.updated), errors=$($newest.errors)"

# --- 3: no WIP sheet was created or updated ---------------------------------
$wipTouched = SqlScalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.AuditLog
WHERE  Id > $auditBefore
  AND  EntityType = 'Pull'
  AND  ActionType IN ('etl-create','etl-update','etl-cancel-synth')
  AND  EntityId IN ($wipInList);
"@
if ([int]$wipTouched -ne 0) {
    Fail "$wipTouched WIP pull sheet(s) were created or updated by the run — the feed is still touching WIP"
}
OK "No WIP sheet in the window drew an etl-create, etl-update, or etl-cancel row"

# --- 4: pre-existing ERP-fed WIP pulls unchanged ----------------------------
Step "Section 4: pre-existing ERP-fed WIP pulls are neither updated nor cancelled"
$erpWipAfter = SqlScalar ($fingerprintSql -f $erpWipWhere)
if ($erpWipAfter -ne $erpWipBefore) {
    Fail "ERP-fed WIP pulls changed across the run: [$erpWipBefore] -> [$erpWipAfter]"
}
$wipCanceled = SqlScalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.PullItems pi
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE  p.PullNumber IN ($wipInList) AND pi.Status = 'canceled';
"@
OK "Fingerprint held at [$erpWipAfter] across the run; canceled WIP items on those pulls: $wipCanceled (unchanged by this run)"

# --- 5: synthesised pulls unchanged -----------------------------------------
Step "Section 5: PO-import pulls are untouched"
$synthAfter = SqlScalar ($fingerprintSql -f $synthWhere)
if ($synthAfter -ne $synthBefore) {
    Fail "Synthesised (Origin='po-import') pulls changed across the run: [$synthBefore] -> [$synthAfter]"
}
$synthTouched = SqlScalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.AuditLog
WHERE  Id > $auditBefore
  AND  EntityType = 'Pull'
  AND  ActionType IN ('etl-create','etl-update','etl-cancel-synth')
  AND  EntityId IN (SELECT PullNumber FROM dbo.Pulls WHERE Origin = 'po-import');
"@
if ([int]$synthTouched -ne 0) { Fail "$synthTouched synthesised pull(s) were mutated by the run" }
OK "Synthesised pulls held at [$synthAfter] with no ETL mutation rows"

# --- 6: non-WIP work still happens ------------------------------------------
Step "Section 6: non-WIP sheets are unaffected"
$processed = [int]$newest.created + [int]$newest.updated
if ($processed -le 0) {
    Fail "The run processed 0 pulls — the WIP filter has become a blanket off-switch"
}
$nonWipTouched = SqlScalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.AuditLog
WHERE  Id > $auditBefore
  AND  EntityType = 'Pull'
  AND  ActionType IN ('etl-create','etl-update')
  AND  EntityId NOT IN ($wipInList);
"@
if ([int]$nonWipTouched -le 0) { Fail "No non-WIP pull was created or updated — ordinary sync is broken" }
OK "$processed pull(s) processed, $nonWipTouched non-WIP pull(s) created or updated"

# --- 7: the skip is reported ------------------------------------------------
Step "Section 7: the skip is counted and reported"
$totals = $newest.sourceTotals
if (-not $totals) { Fail "SourceTotals is null on the run row" }
if ($totals -notmatch '"WipSkippedRowCount"\s*:\s*(\d+)') { Fail "SourceTotals carries no WipSkippedRowCount: $totals" }
$reportedRows = [int]$matches[1]
if ($reportedRows -le 0) {
    Fail "SourceTotals reports WipSkippedRowCount=0 while $($wipIds.Count) WIP sheet(s) sit in the window — the filter ran but reported nothing"
}
if ($totals -notmatch '"WipSkippedPullCount"\s*:\s*(\d+)') { Fail "SourceTotals carries no WipSkippedPullCount" }
$reportedSheets = [int]$matches[1]
if ($reportedSheets -ne $wipIds.Count) {
    Fail "SourceTotals reports $reportedSheets skipped sheet(s); the ERP window holds $($wipIds.Count)"
}
foreach ($k in @('SkippedRowCount','SkippedSynthesised','WipMixedPullCount','WipMixedNonWipRowCount','WipMixedNonWipQty')) {
    if ($totals -notmatch ('"' + $k + '"')) { Fail "SourceTotals is missing $k" }
}
OK "SourceTotals reports $reportedRows row(s) across $reportedSheets sheet(s), and carries every skip counter"

$endMsg = SqlScalar @"
SET NOCOUNT ON;
SELECT TOP 1 Message FROM dbo.AuditLog
WHERE Id > $auditBefore AND ActionType = 'etl-end' AND EntityId = '$runId';
"@
if (-not $endMsg) { Fail "No etl-end audit row for run $runId" }
if ($endMsg -notmatch 'wipSkipRows=(\d+)')   { Fail "etl-end message does not name wipSkipRows: $endMsg" }
if ([int]$matches[1] -ne $reportedRows)      { Fail "etl-end wipSkipRows disagrees with SourceTotals" }
if ($endMsg -notmatch 'wipSkipSheets=(\d+)') { Fail "etl-end message does not name wipSkipSheets" }
if ($endMsg -notmatch 'rowSkip=')            { Fail "etl-end message does not name rowSkip (the previously-dead SkippedRowCount)" }
if ($endMsg -notmatch 'synthSkip=')          { Fail "etl-end message does not name synthSkip" }
# NVARCHAR(1000), and IAuditService swallows write failures — an over-long
# message leaves no row at all rather than erroring. The row exists, so the cap
# held; assert the length too so a future addition cannot creep past it silently.
if ($endMsg.Length -gt 1000) { Fail "etl-end message is $($endMsg.Length) chars; AuditLog.Message is NVARCHAR(1000)" }
OK "etl-end audit row names the skip figures and agrees with SourceTotals ($($endMsg.Length) chars)"

Write-Host "`nALL PASS — the ERP feed no longer creates, updates, or takes over a WIP pull." -ForegroundColor Green
exit 0
