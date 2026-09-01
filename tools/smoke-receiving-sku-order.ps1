# Smoke: the Receiving console grid is ordered by SKU, not by insertion order.
#
# The console used to order by (SortOrder, ItemCode) — insertion order, with
# SKU only as a tiebreaker. Two things broke once pull items were grained by
# (SKU, storer) in fa8a0e2:
#
#   1. The same SKU legitimately appears more than once on one pull sheet,
#      once per storer, each holding its own purchase order. Those rows belong
#      next to each other; ordered by SortOrder they land wherever they were
#      written.
#   2. A storer split is appended at MAX(SortOrder)+1, so the second storer's
#      row drops to the BOTTOM of the grid — the furthest possible point from
#      the sibling it has to be read against.
#
# The order is now (ItemCode, VendorCode, SortOrder) at four sites in
# PullRepository plus the client re-sort in receiving.js, which fed on
# sortOrder alone and would have overridden all four.
#
# VendorCode is second rather than skipped: it keeps a SKU's storer rows
# adjacent AND stable relative to each other. SortOrder stays as the final
# tiebreaker so two rows can never swap between loads.
#
# Cases:
#   2. multi-storer pull  — same-SKU rows adjacent, ascending SKU, on BOTH
#                           endpoints (GET /api/pulls/{id} and .../items)
#   3. NULL VendorCode    — sorts first within its SKU group, never scattered
#   4. single-storer pull — plain ascending SKU order
#   5. window hours       — still ascending within an item
#   6. client comparator  — receiving.js reproduces the server order from a
#                           shuffled input (the site that used to override it)
#   7. export path        — the per-pull xlsx (now server-generated, shared with
#                           Reports -> Pull Sheets) lists rows in grid order
#   8. source guard       — all four PullRepository sites carry the new key
#
# Fixtures are seeded through SQL: the ordering is a read-path property, and
# the point is to control SortOrder exactly, which no write endpoint allows.
# Prefix SKUORD- everywhere, purged on entry and exit.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'

$script:pass = 0
function Step($n) { Write-Host "`n=== $n ===" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  PASS: $m" -ForegroundColor Green; $script:pass++ }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; Cleanup; exit 1 }
function Sql($q)  { return sqlcmd -S $sqlSrv -E -C -d ReceivingOps -I -h -1 -W -Q $q }
function SqlVal($q) {
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

function Cleanup {
    Sql @"
SET NOCOUNT ON;
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'SKUORD-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'SKUORD-%';
-- FK_PullSig_Pull and FK_PO_Pull do NOT cascade from dbo.Pulls, so a pull
-- closed with a signature (or carrying a PO) refuses the DELETE below. The
-- delete is set-based, so ONE such pull strands the whole range -- 148 rows
-- accumulated this way before 2026-08-20. See
-- docs/defect-pull-signature-fk-blocks-smoke-cleanup.md
DELETE s FROM dbo.PullSignatures s
INNER JOIN dbo.Pulls p ON p.Id = s.PullId
WHERE p.PullNumber LIKE 'SKUORD-%';
UPDATE po SET PullId = NULL FROM dbo.PurchaseOrders po
INNER JOIN dbo.Pulls p ON p.Id = po.PullId
WHERE p.PullNumber LIKE 'SKUORD-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'SKUORD-%';
PRINT 'cleanup: pulls removed = ' + CONVERT(varchar, @@ROWCOUNT);
"@ | Out-Null
}

function SeedPull($pnum) {
    Sql "INSERT INTO dbo.Pulls (Id,PullNumber,WarehouseId,PullDate,Status,LockPoByPull,LockHourCap,CreatedAt) VALUES (NEWID(),'$pnum','$WH_01',CAST(SYSUTCDATETIME() AS date),'pending',1,1,SYSUTCDATETIME());" | Out-Null
    return SqlVal "SELECT CAST(Id AS varchar(36)) FROM dbo.Pulls WHERE PullNumber='$pnum';"
}

# A $vendor of '' seeds a NULL VendorCode — the "no storer recorded" row.
# Windows are written 9 before 7 so hour order can never pass on insertion order.
function SeedItem($pullId, $code, $vendor, $sortOrder) {
    $v = if ($vendor -eq '') { 'NULL' } else { "'$vendor'" }
    $id = [guid]::NewGuid().ToString()
    Sql @"
SET NOCOUNT ON;
INSERT INTO dbo.PullItems (Id,PullId,ItemCode,Description,VendorCode,Status,SortOrder)
VALUES ('$id','$pullId','$code','$code desc',$v,'normal',$sortOrder);
INSERT INTO dbo.PullItemWindows (Id,PullItemId,HourOfDay,ExpectedQty,ReceivedQty)
VALUES (NEWID(),'$id',9,50,0), (NEWID(),'$id',7,100,0);
"@ | Out-Null
}

# "SKU@storer" per row, in the order the API returned them.
function Shape($items) {
    return (($items | ForEach-Object {
        $v = if ([string]::IsNullOrEmpty($_.vendorCode)) { '<null>' } else { $_.vendorCode }
        "$($_.itemCode)@$v"
    }) -join ' | ')
}

# ---------------------------------------------------------------------------
Step '1. Preconditions + fixtures'
try { Invoke-WebRequest -Uri "$base/Account/Login" -UseBasicParsing -TimeoutSec 10 | Out-Null }
catch { Write-Host "  FAIL: dev server not reachable at $base" -ForegroundColor Red; exit 1 }
Cleanup
$sv = Login 'sadmin' 'admin' $WH_01

# SortOrder is deliberately adversarial: under the OLD (SortOrder, ItemCode)
# order every one of these lands somewhere else, and the SKUORD-A storer rows
# sit at opposite ends of the grid.
#
#   SKUORD-B @ ST-ALPHA   SortOrder 1
#   SKUORD-A @ ST-ALPHA   SortOrder 2
#   SKUORD-C @ ST-ALPHA   SortOrder 3
#   SKUORD-A @ (null)     SortOrder 50   <- no storer recorded
#   SKUORD-A @ ST-BRAVO   SortOrder 99   <- the storer split, appended at MAX+1
$multi = SeedPull 'SKUORD-MULTI'
if (-not $multi) { Fail 'could not seed SKUORD-MULTI' }
SeedItem $multi 'SKUORD-B' 'ST-ALPHA' 1
SeedItem $multi 'SKUORD-A' 'ST-ALPHA' 2
SeedItem $multi 'SKUORD-C' 'ST-ALPHA' 3
SeedItem $multi 'SKUORD-A' ''         50
SeedItem $multi 'SKUORD-A' 'ST-BRAVO' 99

# Single storer, SortOrder the exact REVERSE of SKU order, so ascending-by-SKU
# cannot pass by accident on insertion order.
$single = SeedPull 'SKUORD-SINGLE'
if (-not $single) { Fail 'could not seed SKUORD-SINGLE' }
SeedItem $single 'SKUORD-Z' 'ST-ALPHA' 1
SeedItem $single 'SKUORD-M' 'ST-ALPHA' 2
SeedItem $single 'SKUORD-D' 'ST-ALPHA' 3
OK 'server up, SKUORD- namespace clear, 2 pulls seeded (5 items / 3 storers, 3 items / 1 storer)'

# ---------------------------------------------------------------------------
Step '2. Multi-storer pull: same-SKU rows adjacent, ascending SKU'
# Null storer first, then ST-ALPHA, then ST-BRAVO. SQL's NULLs-first rule and
# StringComparer.Ordinal agree on this — checked side by side against the live
# DB collation (SQL_Latin1_General_CP1_CI_AS) before the order was chosen.
$wantMulti = 'SKUORD-A@<null> | SKUORD-A@ST-ALPHA | SKUORD-A@ST-BRAVO | SKUORD-B@ST-ALPHA | SKUORD-C@ST-ALPHA'
$oldMulti  = 'SKUORD-B@ST-ALPHA | SKUORD-A@ST-ALPHA | SKUORD-C@ST-ALPHA | SKUORD-A@<null> | SKUORD-A@ST-BRAVO'

$detail = Invoke-RestMethod -Uri "$base/api/pulls/$multi" -WebSession $sv
$shapeDetail = Shape $detail.items
if ($shapeDetail -eq $oldMulti) { Fail "GET /api/pulls/{id} is still on the SortOrder order:`n  $shapeDetail" }
if ($shapeDetail -ne $wantMulti) { Fail "GET /api/pulls/{id} order wrong.`n  expected: $wantMulti`n  got:      $shapeDetail" }
OK 'GET /api/pulls/{id} — 3 SKUORD-A rows adjacent at the top, then B, then C'

$itemsOnly = Invoke-RestMethod -Uri "$base/api/pulls/$multi/items" -WebSession $sv
$shapeItems = Shape $itemsOnly
if ($shapeItems -ne $wantMulti) { Fail "GET /api/pulls/{id}/items disagrees with GET /api/pulls/{id}.`n  expected: $wantMulti`n  got:      $shapeItems" }
OK 'GET /api/pulls/{id}/items — identical order (the drawer cannot disagree with the console)'

# Adjacency stated on its own, independent of the exact expected string above:
# whatever else moves, one SKU's rows form one unbroken run.
$codes = @($detail.items | ForEach-Object { $_.itemCode })
$firstA = [array]::IndexOf($codes, 'SKUORD-A')
$lastA  = [array]::LastIndexOf($codes, 'SKUORD-A')
if (($lastA - $firstA) -ne 2) { Fail "SKUORD-A rows are not contiguous: positions $firstA..$lastA of $($codes.Count)" }
OK 'the three SKUORD-A rows occupy one unbroken run'

# ---------------------------------------------------------------------------
Step '3. NULL VendorCode sorts predictably (first), not scattered'
$aRows = @($detail.items | Where-Object { $_.itemCode -eq 'SKUORD-A' })
if (-not [string]::IsNullOrEmpty($aRows[0].vendorCode)) {
    Fail "the null-storer row is not first within SKUORD-A: got '$($aRows[0].vendorCode)'"
}
$aVendors = (($aRows | ForEach-Object { if ([string]::IsNullOrEmpty($_.vendorCode)) { '<null>' } else { $_.vendorCode } }) -join ',')
if ($aVendors -ne '<null>,ST-ALPHA,ST-BRAVO') { Fail "storer order within SKUORD-A drifted: $aVendors" }
OK 'null storer sorts first, then ST-ALPHA, ST-BRAVO — one predictable bucket'

# ---------------------------------------------------------------------------
Step '4. Single-storer pull: plain ascending SKU'
$wantSingle = 'SKUORD-D@ST-ALPHA | SKUORD-M@ST-ALPHA | SKUORD-Z@ST-ALPHA'
$sDetail = Invoke-RestMethod -Uri "$base/api/pulls/$single" -WebSession $sv
$shapeSingle = Shape $sDetail.items
if ($shapeSingle -ne $wantSingle) { Fail "single-storer order wrong.`n  expected: $wantSingle`n  got:      $shapeSingle" }
$sItems = Invoke-RestMethod -Uri "$base/api/pulls/$single/items" -WebSession $sv
if ((Shape $sItems) -ne $wantSingle) { Fail "single-storer /items order wrong: $(Shape $sItems)" }
OK 'D, M, Z — ascending SKU, the exact reverse of the seeded SortOrder'

# ---------------------------------------------------------------------------
Step '5. Window hours still ascend within an item'
# HourOfDay stays the LAST key in both SQL sites. Seeded 9 before 7 on purpose.
foreach ($it in $detail.items) {
    $hours = @($it.windows | ForEach-Object { $_.hourOfDay })
    if (($hours -join ',') -ne '7,9') { Fail "windows on $($it.itemCode) are not hour-ascending: $($hours -join ',')" }
}
OK 'every item reports its windows 7 then 9, despite being written 9 then 7'

# ---------------------------------------------------------------------------
Step '6. receiving.js reproduces the server order from a shuffled input'
# The client re-sort is the site that would silently undo all four server ones,
# so it is exercised rather than merely grepped: the real comparator is lifted
# out of the shipped file and run over the fixture in reverse.
#
# Every failure in this step is the SAME failure — the ordering rule is written
# twice and the two copies no longer agree — so every message below says that
# and names both files. The tempting fix six months from now is to adjust
# whichever side the assertion happens to point at, which would leave the two
# still disagreeing and the grid still wrong.
$jsPath   = Join-Path $repoRoot 'src\ReceivingOps.Web\wwwroot\js\receiving.js'
$repoPath = Join-Path $repoRoot 'src\ReceivingOps.Web\Data\Repositories\PullRepository.cs'
$js = Get-Content -Raw $jsPath

$drift = @'

  DRIFT: the item ordering rule is implemented TWICE and the two copies no
  longer agree.
      server  src\ReceivingOps.Web\Data\Repositories\PullRepository.cs
              4 sites, ordering by ItemCode -> VendorCode -> SortOrder
      client  src\ReceivingOps.Web\wwwroot\js\receiving.js
              ingestPullDetail's .sort, which runs LAST and therefore wins
  Fix the drift — bring the two back into agreement. Do NOT relax this
  assertion to match whichever side changed. The client sort has the last word
  on what the grid renders, so a client that disagrees silently reverts all
  four server sites, and the Excel export inherits the same wrong order.
'@

if ($js -notmatch '(?m)^\s*const cmpOrdinal = [^\r\n]+;') {
    Fail "the client's cmpOrdinal helper is gone from receiving.js.$drift"
}
$cmpDef = $Matches[0].Trim()

# Scoped to ingestPullDetail: receiving.js sorts several other lists (the
# transaction rows by receivedAt, among them), and an unscoped match lands on
# whichever comes first in the file.
if ($js -notmatch '(?s)function ingestPullDetail\(pd\)\s*\{(.*?)\r?\n  \}') {
    Fail "could not isolate ingestPullDetail in receiving.js — the client half of the ordering rule cannot be located.$drift"
}
$ingest = $Matches[1]
if ($ingest -notmatch '(?s)\.sort\(\(\s*a\s*,\s*b\s*\)\s*=>(.*?)\)\s*\r?\n\s*\.map\(') {
    Fail "no item sort found in ingestPullDetail — reverted to a sortOrder-only .sort()?$drift"
}
$body = $Matches[1].Trim()
if ($body -notmatch 'itemCode') {
    Fail "the client sort does not order on itemCode, the server's first key:`n  $body$drift"
}
if ($body -notmatch 'vendorCode') {
    Fail "the client sort does not order on vendorCode, the server's second key — a SKU's storer rows will not stay adjacent:`n  $body$drift"
}
if ($body -match '^\(?\s*a\.sortOrder') {
    Fail "the client sort leads on sortOrder again; the server leads on ItemCode:`n  $body$drift"
}

# Feed it the server's own rows, reversed, and require the server order back.
$fixture = ($detail.items | ForEach-Object {
    $v = if ([string]::IsNullOrEmpty($_.vendorCode)) { 'null' } else { """$($_.vendorCode)""" }
    "  {itemCode: ""$($_.itemCode)"", vendorCode: $v, sortOrder: $($_.sortOrder)}"
}) -join ",`n"

$nodeSrc = @"
$cmpDef
const rows = [
$fixture
].reverse();
rows.sort((a, b) => $body);
console.log(rows.map(r => r.itemCode + '@' + (r.vendorCode || '<null>')).join(' | '));
"@
$tmp = Join-Path ([IO.Path]::GetTempPath()) "skuord-$([guid]::NewGuid().ToString('N')).js"
Set-Content -Path $tmp -Value $nodeSrc -Encoding UTF8
try { $jsOut = (& node $tmp 2>&1 | Out-String).Trim() } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
if ($LASTEXITCODE -ne 0) { Fail "node could not run the comparator extracted from receiving.js:`n$jsOut" }
if ($jsOut -ne $wantMulti) {
    Fail "the client sort and the server disagree on the same rows.`n  server (PullRepository.cs): $wantMulti`n  client (receiving.js):      $jsOut$drift"
}
OK 'the shipped comparator, run over the reversed rows, returns the server order exactly'

# ---------------------------------------------------------------------------
Step '7. The export inherits the grid order'
# The per-pull Export button no longer builds the workbook in the browser. It
# calls /api/reports/pull-sheets/pull/{id}/export.xlsx, the same generator
# Reports -> Pull Sheets uses, so the ordering claim now belongs to the server
# query. Assert it against the FILE rather than against source: the sheet the
# operator opens must list rows in the order the grid shows them.
$dll = Get-ChildItem "$repoRoot\src\ReceivingOps.Web\bin\Debug\net8.0" -Filter 'ClosedXML.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dll) { Fail 'ClosedXML.dll not found — build the project first' }
Add-Type -Path $dll.FullName

$xlsx = Join-Path ([IO.Path]::GetTempPath()) "skuord-$([guid]::NewGuid().ToString('N')).xlsx"
try {
    $xr = Invoke-WebRequest -Uri "$base/api/reports/pull-sheets/pull/$multi/export.xlsx" -WebSession $sv -UseBasicParsing
} catch {
    Fail "per-pull export request failed: $($_.Exception.Message)"
}
[IO.File]::WriteAllBytes($xlsx, $xr.Content)

$xwb = New-Object ClosedXML.Excel.XLWorkbook($xlsx)
$xd  = $xwb.Worksheet('Detail')
# Resolve columns by header name so a column insertion cannot shift the check.
$xh = @{}
foreach ($c in 1..($xd.LastColumnUsed().ColumnNumber())) { $xh[$xd.Cell(1,$c).GetString()] = $c }
foreach ($need in 'Item Code','Vendor Code') {
    if (-not $xh.ContainsKey($need)) { $xwb.Dispose(); Fail "export Detail sheet has no '$need' column" }
}

# Detail is window-grained (each fixture item carries hours 7 and 9), so collapse
# consecutive duplicates to get the ROW order the grid would show.
$seq = @()
foreach ($r in 2..($xd.LastRowUsed().RowNumber())) {
    $code = $xd.Cell($r, $xh['Item Code']).GetString()
    $vend = $xd.Cell($r, $xh['Vendor Code']).GetString()
    if ([string]::IsNullOrEmpty($vend)) { $vend = '<null>' }
    $key = "$code@$vend"
    if ($seq.Count -eq 0 -or $seq[-1] -ne $key) { $seq += $key }
}
$xwb.Dispose()
Remove-Item $xlsx -Force -ErrorAction SilentlyContinue

$shapeExport = $seq -join ' | '
if ($shapeExport -eq $oldMulti) { Fail "the export is still on the SortOrder order:`n  $shapeExport" }
if ($shapeExport -ne $wantMulti) {
    Fail "the exported sheet disagrees with the grid.`n  grid (API):   $wantMulti`n  sheet (xlsx): $shapeExport"
}
OK 'the exported Detail sheet lists rows in exactly the grid order'

# ---------------------------------------------------------------------------
Step '8. All four PullRepository sites carry the new key'
$repo = Get-Content -Raw $repoPath
$sqlSites = ([regex]::Matches($repo, 'ORDER BY pi\.ItemCode, pi\.VendorCode, pi\.SortOrder, piw\.HourOfDay')).Count
if ($sqlSites -ne 2) { Fail "expected 2 SQL ORDER BY sites on the new key, found $sqlSites" }
$linqPattern = '(?s)OrderBy\(i => i\.ItemCode, StringComparer\.Ordinal\)\s*\.ThenBy\(i => i\.VendorCode, StringComparer\.Ordinal\)\s*\.ThenBy\(i => i\.SortOrder\)'
$linqSites = ([regex]::Matches($repo, $linqPattern)).Count
if ($linqSites -ne 2) { Fail "expected 2 LINQ sites on the new key, found $linqSites" }
if ($repo -match 'ORDER BY pi\.SortOrder')       { Fail 'a SQL site still leads on pi.SortOrder' }
if ($repo -match 'OrderBy\(i => i\.SortOrder\)') { Fail 'a LINQ site still leads on SortOrder' }
OK '2 SQL + 2 LINQ sites on (ItemCode, VendorCode, SortOrder); no leading-SortOrder survivor'

# ---------------------------------------------------------------------------
Cleanup
Write-Host ""
Write-Host "ALL PASS — $($script:pass) assertions across the SKU-ordered console." -ForegroundColor Green
exit 0
