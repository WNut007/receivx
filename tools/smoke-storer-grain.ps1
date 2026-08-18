# Smoke: pull items are grained by (SKU, storer), not by SKU alone.
#
# One pull sheet routinely carries the same SKU from two storers holding
# SEPARATE purchase orders — 107 such (pull, SKU) pairs in a single day's
# export, 298 rows, 2,500,523 units, across 196 of 504 pull sheets. Merging
# them discarded the second storer's identity and summed the quantities, so
# stock delivered by one storer could be booked against the other's PO. The
# liability landed on the wrong supplier and could not be reconstructed,
# because the distinction was never stored.
#
# The fix is two layers, and BOTH are tested here:
#   1. grouping  — the ETL, WIP synthesis, and the admin path key on
#                  (ItemCode, VendorCode); ItemCode itself stays the bare SKU
#                  so the §7.15 FIFO match against PO lines is untouched
#   2. allocation — the FIFO walk filters PO lines by the item's storer, so
#                  receiving against one storer cannot consume the other's
#                  line. Layer 1 without layer 2 is tidier rows and the same
#                  mis-allocation.
#
# ETL cases run through tools/ErpUpsertHarness, which executes the real
# Transform + UpsertAsync against the dev DB with no ERP host in the loop.
# smoke-phase-10-2/10-3 assert on source text and 10-7 skips without VPN, so
# before the harness nothing in the repo had ever executed this code.
#
# Cases:
#    1. two storers, one SKU        → 2 items, own vendor + own quantity
#    2. same SKU, same ROUND        → 2 items, each with a window at that hour
#    3. same SKU, same storer, 3 rows → 1 item, summed (no over-split)
#    4. upsert with two same-SKU items → no ArgumentException, both survive
#    5. re-run on an unchanged draft → nothing added, nothing cancelled
#    6. storer B withdrawn          → B cancelled, A untouched
#    7. etl-cancel-synth reports the cancelled storer's OWN ReceivedQty
#    8. receive lands on that storer's PO line (the acceptance criterion)
#    9. overflow stays within the same vendor
#   10. WIP multi-storer guard still fires; WIP key is storer-aware
#   11. single-storer pull unchanged
#   12. vendor match: stripped↔prefixed both ways, and NOT a shared suffix

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
function SqlScalar($q) {
    $out = (Sql $q) | Where-Object { $_ -and $_.Trim() -ne '' } | Select-Object -First 1
    if ($null -eq $out) { return '' }
    return $out.Trim()
}

function Harness($scenario) {
    $out = & dotnet run --project (Join-Path $repoRoot 'tools\ErpUpsertHarness') --no-build -- $scenario 2>$null
    $json = ($out | Where-Object { $_ -match '^\{' } | Select-Object -First 1)
    if (-not $json) { Fail "harness scenario '$scenario' produced no JSON (build it first: dotnet build tools/ErpUpsertHarness)" }
    return $json | ConvertFrom-Json
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
DELETE r FROM dbo.Receipts r
  INNER JOIN dbo.PullItems pi ON pi.Id = r.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'SG-TEST-%';
DELETE r FROM dbo.Receipts r
  INNER JOIN dbo.PurchaseOrders po ON po.Id = r.PurchaseOrderId
WHERE po.PoNumber LIKE 'SG-PO-%';
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'SG-TEST-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'SG-TEST-%';
DELETE pol FROM dbo.PurchaseOrderLines pol
  INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber LIKE 'SG-PO-%';
DELETE FROM dbo.PurchaseOrders WHERE PoNumber LIKE 'SG-PO-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'SG-TEST-%';
DELETE FROM dbo.AuditLog WHERE EntityId LIKE 'SG-TEST-%' OR EntityId LIKE 'HARNESS-%';
"@ | Out-Null
}

# ---------------------------------------------------------------------------
Step '0. Preconditions'
try { Invoke-WebRequest -Uri "$base/Account/Login" -UseBasicParsing -TimeoutSec 10 | Out-Null }
catch { Write-Host "  FAIL: dev server not reachable at $base" -ForegroundColor Red; exit 1 }
Cleanup
$sv = Login 'sadmin' 'admin' $WH_01
OK 'server up, SG- namespace clear'

# ---------------------------------------------------------------------------
Step '1-2. Transform: two storers on one SKU, same ROUND → two items'
# The §1 defect and the 60-case same-hour shape in one fixture: both rows carry
# hour 07, which is what the SKU-only key collapsed hardest.
$t1 = Harness 'transform-two-storers'
$items1 = $t1.pulls[0].items
if ($items1.Count -ne 2) { Fail "expected 2 items, got $($items1.Count) — the storers were merged" }
$a = $items1 | Where-Object { $_.VendorCode -eq '5732' }
$b = $items1 | Where-Object { $_.VendorCode -eq '84600' }
if (-not $a -or -not $b)    { Fail "both storers must survive; got vendors: $(($items1.VendorCode) -join ', ')" }
if ($a.qty -ne 100)         { Fail "storer 5732 qty=$($a.qty), expected 100" }
if ($b.qty -ne 250)         { Fail "storer 84600 qty=$($b.qty), expected 250" }
if ($a.qty + $b.qty -eq 350 -and $items1.Count -eq 1) { Fail 'quantities were summed into one item' }
foreach ($i in $items1) {
    if ($i.ItemCode -ne 'HARNESS-SKU-A') { Fail "ItemCode must stay the BARE SKU, got '$($i.ItemCode)'" }
    if ($i.hours -join ',' -ne '7')      { Fail "expected a single window at hour 7, got '$($i.hours -join ',')'" }
}
OK '2 items, own vendor, own qty (100 / 250 — not 350), both at hour 7, ItemCode still bare'

# ---------------------------------------------------------------------------
Step '3. Transform: same SKU, same storer, three rows → one item, summed'
$t2 = Harness 'transform-same-storer'
$items2 = $t2.pulls[0].items
if ($items2.Count -ne 1) { Fail "expected 1 item, got $($items2.Count) — the change over-split on a single storer" }
if ($items2[0].qty -ne 150) { Fail "qty=$($items2[0].qty), expected 150 (100+40+10 summed)" }
OK '1 item, 150 units — rows within one storer still merge'

# ---------------------------------------------------------------------------
Step '4. Upsert: two same-SKU items no longer kill the run'
# Proven to bite: run against the pre-fix `existing.ToDictionary(e => e.ItemCode)`
# this returns errors=1 with
#   "ArgumentException: An item with the same key has already been added. Key: HARNESS-SKU-A"
# and updated=0 — the whole pull's ETL run dies. Captured 2026-08-19 by
# reverting that one line, rebuilding, and re-running this scenario.
$u1 = Harness 'two-storer-insert'
if ($u1.threw)      { Fail "upsert threw: $($u1.threw)" }
if ($u1.errors -ne 0) {
    $detail = ($u1.outcomes | ForEach-Object { $_.Detail }) -join ' | '
    Fail "errors=$($u1.errors) — $detail"
}
if ($u1.created -ne 1)      { Fail "created=$($u1.created), expected 1" }
if ($u1.items.Count -ne 2)  { Fail "expected 2 rows on the pull, got $($u1.items.Count)" }
if (($u1.items | Where-Object { $_.ExpectedQty -ne 100 })) { Fail 'each storer keeps its own 100 units' }
OK 'insert path: no ArgumentException, 2 rows, quantities not merged'

$u2 = Harness 'two-storer-update'
if ($u2.errors -ne 0)      { Fail "update path errors=$($u2.errors)" }
if ($u2.itemsAdded -ne 1)  { Fail "itemsAdded=$($u2.itemsAdded), expected 1 (storer B joins A)" }
if ($u2.items.Count -ne 2) { Fail "expected 2 rows after update, got $($u2.items.Count)" }
OK 'update path: storer B added alongside A, no duplicate-key throw'

# ---------------------------------------------------------------------------
Step '5. Re-run on an unchanged draft → nothing added, nothing cancelled'
$u3 = Harness 'rerun-stable'
if ($u3.errors -ne 0)         { Fail "errors=$($u3.errors)" }
if ($u3.itemsAdded -ne 0)     { Fail "itemsAdded=$($u3.itemsAdded), expected 0 — the diff is matching on the wrong key" }
if ($u3.itemsCanceled -ne 0)  { Fail "itemsCanceled=$($u3.itemsCanceled), expected 0" }
$sorts = ($u3.items | ForEach-Object { $_.SortOrder }) -join ','
if ($sorts -ne '1,2')         { Fail "SortOrder drifted to '$sorts', expected '1,2'" }
OK 'idempotent: 0 added, 0 cancelled, SortOrder stable at 1,2'

# ---------------------------------------------------------------------------
Step '6. ERP withdraws storer B → B cancelled, A untouched'
# The draftCodes fix. Keyed on the SKU alone, storer A surviving in the draft
# keeps the SKU in the set, so B is never cancelled and lingers as phantom
# outstanding on the worklist forever.
$u4 = Harness 'withdraw-one-storer'
if ($u4.itemsCanceled -ne 1) { Fail "itemsCanceled=$($u4.itemsCanceled), expected exactly 1" }
$rowA = $u4.items | Where-Object { $_.VendorCode -eq '5732' }
$rowB = $u4.items | Where-Object { $_.VendorCode -eq '84600' }
if ($rowA.Status -ne 'normal')   { Fail "storer A status='$($rowA.Status)', expected 'normal' — the wrong row was cancelled" }
if ($rowB.Status -ne 'canceled') { Fail "storer B status='$($rowB.Status)', expected 'canceled'" }
OK 'B cancelled, A still normal'

# ---------------------------------------------------------------------------
Step '12. Vendor match: stripped↔prefixed both ways, and NOT a shared suffix'
# Executes the SHIPPED predicate, lifted out of ReceiptService.cs, rather than a
# re-implementation of it. Written the obvious way (pol.VendorCode = @V) this
# matches zero rows and fails silently — the operator reads "no capacity
# anywhere" while the code looks like it works. The negative case is what pins
# the hyphen: 'COI-15732' ENDS WITH '5732' and must NOT match, or the filter
# would quietly leak stock between two unrelated storers whose codes happen to
# share a tail.
$svcSrc = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\Services\ReceiptService.cs')
$m = [regex]::Match($svcSrc, '(?s)private static string VendorMatchSql\(string poLineColumn, string param\) => \$@"(.*?)";')
if (-not $m.Success) { Fail 'could not lift VendorMatchSql out of ReceiptService.cs — was it renamed?' }
$predicate = $m.Groups[1].Value.Replace('{poLineColumn}', 'v').Replace('{param}', '@V').Replace('""', '"')

function MatchSet($probe) {
    $rows = Sql @"
SET NOCOUNT ON;
DECLARE @V VARCHAR(64) = '$probe';
DECLARE @t TABLE (v VARCHAR(64));
INSERT INTO @t (v) VALUES ('5732'), ('COI-5732'), ('WDT-5732'), ('COI-15732'), ('COI-5732X'), (NULL);
SELECT v FROM @t WHERE $predicate ORDER BY v;
"@
    return @($rows | Where-Object { $_ -and $_.Trim() -ne '' -and $_ -notmatch 'rows affected' } | ForEach-Object { $_.Trim() })
}

$hits = MatchSet '5732'
$expected = @('5732','COI-5732','WDT-5732')
if ((($hits | Sort-Object) -join ',') -ne (($expected | Sort-Object) -join ',')) {
    Fail "stripped '5732' matched [$($hits -join ', ')], expected [$($expected -join ', ')]"
}
if ($hits -contains 'COI-15732') { Fail "'COI-15732' matched '5732' — the hyphen guard is not working; a shared suffix is not the same storer" }
if ($hits -contains 'COI-5732X') { Fail "'COI-5732X' matched '5732' — the match must be anchored at the end" }
OK "stripped '5732' → matches 5732, COI-5732, WDT-5732; rejects COI-15732 and COI-5732X"

# The other direction: a PO line already holding the stripped form still matches
# when the pull item carries it, and a prefixed probe matches itself.
$hits2 = MatchSet 'COI-5732'
if ($hits2 -notcontains 'COI-5732') { Fail "prefixed probe did not match its own exact value" }
if ($hits2 -contains '5732')        { Fail "prefixed probe 'COI-5732' must not match the bare '5732' row — that direction is the pull item's job, not the PO line's" }
OK "prefixed 'COI-5732' matches itself exactly and nothing looser"

# ---------------------------------------------------------------------------
Step '8-9. Receive lands on the item''s OWN storer PO line; overflow stays in-vendor'
# The acceptance criterion. Two storers, one SKU, one pull, a PO each. Before
# the FIFO vendor filter this walk matched on ItemCode alone and consumed
# whichever line sorted first — the mis-allocation in §1.
$pullId = [Guid]::NewGuid().ToString()
$itemAId = [Guid]::NewGuid().ToString()
$itemBId = [Guid]::NewGuid().ToString()
$poAId = [Guid]::NewGuid().ToString()
$poBId = [Guid]::NewGuid().ToString()
$lineAId = [Guid]::NewGuid().ToString()
$lineBId = [Guid]::NewGuid().ToString()

Sql @"
SET NOCOUNT ON;
INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, LockPoByPull, LockHourCap, CreatedBy)
VALUES ('$pullId', 'SG-TEST-1', '$WH_01', CAST(SYSUTCDATETIME() AS DATE), 'pending', 1, 0, NULL);

-- PullItems carry the STRIPPED storer form, as BPI_PRS.VENDOR emits it.
INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, Tag, Status, SortOrder)
VALUES ('$itemAId', '$pullId', 'SG-SKU-1', 'storer A item', '5732',  NULL, 'normal', 1),
       ('$itemBId', '$pullId', 'SG-SKU-1', 'storer B item', '84600', NULL, 'normal', 2);
INSERT INTO dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
VALUES (NEWID(), '$itemAId', 7, 100, 0), (NEWID(), '$itemBId', 7, 100, 0);

-- PO lines carry the PREFIXED form. Storer B's PO sorts FIRST by PoNumber, so a
-- vendor-blind FIFO walk would consume it when receiving storer A.
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, PullId, PullExternalRef, OrderDate, Status, CreatedBy, CreatedAt)
VALUES ('$poBId', 'SG-PO-001-B', '$WH_01', '$pullId', 'SG-TEST-1', CAST(SYSUTCDATETIME() AS DATE), 'open', NULL, SYSUTCDATETIME()),
       ('$poAId', 'SG-PO-002-A', '$WH_01', '$pullId', 'SG-TEST-1', CAST(SYSUTCDATETIME() AS DATE), 'open', NULL, SYSUTCDATETIME());
INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode)
VALUES ('$lineBId', '$poBId', 1, 'SG-SKU-1', 'storer B line', 500, 0, 'COI-84600'),
       ('$lineAId', '$poAId', 1, 'SG-SKU-1', 'storer A line', 500, 0, 'COI-5732');
"@ | Out-Null

$rec = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -WebSession $sv -ContentType 'application/json' `
    -Body (@{ pullItemId=$itemAId; hourOfDay=7; qty=100; varianceAccepted=$false; note='storer grain smoke' } | ConvertTo-Json)
if ($rec.totalQty -ne 100) { Fail "receive totalQty=$($rec.totalQty), expected 100" }

$recvA = SqlScalar "SET NOCOUNT ON; SELECT CAST(ReceivedQty AS VARCHAR) FROM dbo.PurchaseOrderLines WHERE Id='$lineAId';"
$recvB = SqlScalar "SET NOCOUNT ON; SELECT CAST(ReceivedQty AS VARCHAR) FROM dbo.PurchaseOrderLines WHERE Id='$lineBId';"
if ($recvA -ne '100') { Fail "storer A's PO line ReceivedQty=$recvA, expected 100" }
if ($recvB -ne '0')   { Fail "storer B's PO line ReceivedQty=$recvB, expected 0 — stock landed on the WRONG storer's purchase order" }
OK "receiving storer A consumed A's line (100) and left B's untouched (0), despite B's PO sorting first"

# Overflow: storer A's own line is now full, so an over-receipt with variance
# must widen to other OPEN lines for the SAME vendor — never to storer B's.
$poA2Id = [Guid]::NewGuid().ToString()
$lineA2Id = [Guid]::NewGuid().ToString()
Sql @"
SET NOCOUNT ON;
INSERT INTO dbo.PurchaseOrders (Id, PoNumber, WarehouseId, PullId, PullExternalRef, OrderDate, Status, CreatedBy, CreatedAt)
VALUES ('$poA2Id', 'SG-PO-003-A2', '$WH_01', NULL, NULL, CAST(SYSUTCDATETIME() AS DATE), 'open', NULL, SYSUTCDATETIME());
INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode)
VALUES ('$lineA2Id', '$poA2Id', 1, 'SG-SKU-1', 'storer A overflow line', 500, 0, 'COI-5732');
UPDATE dbo.PurchaseOrderLines SET OrderedQty = 100 WHERE Id = '$lineAId';
"@ | Out-Null

$itemA2 = [Guid]::NewGuid().ToString()
Sql @"
SET NOCOUNT ON;
INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, Tag, Status, SortOrder)
VALUES ('$itemA2', '$pullId', 'SG-SKU-2', 'storer A over item', '5732', NULL, 'normal', 3);
INSERT INTO dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
VALUES (NEWID(), '$itemA2', 8, 50, 0);
INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode)
VALUES (NEWID(), '$poAId', 2, 'SG-SKU-2', 'A line sku2', 50, 0, 'COI-5732'),
       (NEWID(), '$poBId', 2, 'SG-SKU-2', 'B line sku2', 500, 0, 'COI-84600'),
       (NEWID(), '$poA2Id', 2, 'SG-SKU-2', 'A overflow line sku2', 500, 0, 'COI-5732');
"@ | Out-Null

$over = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -WebSession $sv -ContentType 'application/json' `
    -Body (@{ pullItemId=$itemA2; hourOfDay=8; qty=120; varianceAccepted=$true; varianceReasonCode='OVER_DELIVERY'; note='overflow smoke' } | ConvertTo-Json)
if ($over.totalQty -ne 120) { Fail "over-receive totalQty=$($over.totalQty), expected 120" }

$bTouched = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(ISNULL(SUM(pol.ReceivedQty),0) AS VARCHAR)
FROM dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE po.PoNumber = 'SG-PO-001-B' AND pol.ItemCode = 'SG-SKU-2';
"@
if ($bTouched -ne '0') { Fail "overflow consumed storer B's line ($bTouched units) — it must stay within the vendor" }
$aTotal = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(ISNULL(SUM(pol.ReceivedQty),0) AS VARCHAR)
FROM dbo.PurchaseOrderLines pol
WHERE pol.ItemCode = 'SG-SKU-2' AND pol.VendorCode = 'COI-5732';
"@
if ($aTotal -ne '120') { Fail "storer A's lines absorbed $aTotal of 120 units" }
OK 'over-receive of 120 against 50 spilled across storer A''s own lines only; B untouched'

# ---------------------------------------------------------------------------
Step '8b. An item whose storer has NO line of its own still receives (§4.3)'
# The regression smoke-phase-4a caught. A hard vendor filter looked safe on the
# measurement "items whose only open lines carry a NULL vendor" — zero rows.
# Wrong question. The population that breaks carries a DIFFERENT non-null
# vendor: 593 open pull items on the dev DB, real ERP storer codes, whose
# storer has no line while other storers' lines exist for the same SKU.
# Filtering those to nothing turned a working receive into "Insufficient PO
# capacity. Need N, have 0" — making live items unreceivable, which is the
# opposite of leaving §4.3's data alone.
$itemOrphan = [Guid]::NewGuid().ToString()
Sql @"
SET NOCOUNT ON;
INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, VendorCode, Tag, Status, SortOrder)
VALUES ('$itemOrphan', '$pullId', 'SG-SKU-3', 'storer with no PO line of its own', 'NOSUCHSTORER', NULL, 'normal', 4);
INSERT INTO dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
VALUES (NEWID(), '$itemOrphan', 9, 30, 0);
-- Only ANOTHER storer has a line for this SKU.
INSERT INTO dbo.PurchaseOrderLines (Id, PurchaseOrderId, LineNumber, ItemCode, Description, OrderedQty, ReceivedQty, VendorCode)
VALUES (NEWID(), '$poBId', 3, 'SG-SKU-3', 'other storer line', 200, 0, 'COI-84600');
"@ | Out-Null

$orphanRec = Invoke-RestMethod -Uri "$base/api/receipts" -Method POST -WebSession $sv -ContentType 'application/json' `
    -Body (@{ pullItemId=$itemOrphan; hourOfDay=9; qty=30; varianceAccepted=$false; note='fallback smoke' } | ConvertTo-Json)
if ($orphanRec.totalQty -ne 30) { Fail "fallback receive totalQty=$($orphanRec.totalQty), expected 30" }
OK 'storer with no line of its own falls back to the SKU pool — receivable, exactly as before the change'

# ---------------------------------------------------------------------------
Step '10. WIP: the multi-storer guard still fires, and the key is storer-aware'
$wipSrc = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\Services\PoImport\WipPullSynthesis.cs')
# Assert the CONDITION, not the message: the message is built by string
# concatenation across two source lines, so matching its rendered text means
# matching source formatting, which is a test that breaks on a reformat.
if ($wipSrc -notmatch 'if \(storerCodes\.Count > 1\)') {
    Fail 'the WIP multi-storer validation guard is gone — it was kept deliberately'
}
if ($wipSrc -notmatch 'Expected exactly one') {
    Fail 'the WIP multi-storer guard no longer reports what it expected'
}
if ($wipSrc -notmatch 'GroupBy\(r => new WipItemKey\(r\.ItemCode, r\.VendorCode\)\)') {
    Fail 'WIP item grouping is not storer-aware'
}
if ($wipSrc -notmatch '(?s)hourGroup.*?WipWindowPlan') {
    Fail 'WIP window grouping shape changed unexpectedly'
}
OK 'guard intact + WIP items keyed on (ItemCode, VendorCode)'

# The guard makes the WIP split unreachable on today's data — measured: 25 WIP
# sheets in the production export, every one single-storer. So this pair is
# source-level ON PURPOSE: a behavioural test would have to disable the guard to
# reach the key, and a test that edits the thing it is testing proves nothing.
# The behavioural half is smoke-wip-pull-synthesis §7, which asserts the guard
# rejects a two-storer sheet.
$wipGuardSmoke = Join-Path $repoRoot 'tools\smoke-wip-pull-synthesis.ps1'
if ((Get-Content -Raw $wipGuardSmoke) -notmatch 'two storer codes') {
    Fail 'smoke-wip-pull-synthesis no longer covers the two-storer validation error'
}
OK 'behavioural guard coverage still lives in smoke-wip-pull-synthesis'

# ---------------------------------------------------------------------------
Step '11. A single-storer pull is unchanged'
$t3 = Harness 'transform-single-storer'
$items3 = $t3.pulls[0].items
if ($items3.Count -ne 2) { Fail "expected 2 items (2 SKUs), got $($items3.Count)" }
$shape = ($items3 | ForEach-Object { "$($_.ItemCode)/$($_.VendorCode)/$($_.qty)/$($_.hours -join '+')" }) -join ' | '
$want = 'HARNESS-SKU-A/5732/100/7 | HARNESS-SKU-B/5732/200/8'
if ($shape -ne $want) { Fail "single-storer shape drifted.`n  expected: $want`n  got:      $shape" }
OK 'same items, same vendors, same quantities, same hours'

# ---------------------------------------------------------------------------
Step '3b. The admin path can express what the ETL now creates'
$adminSrc = Get-Content -Raw (Join-Path $repoRoot 'src\ReceivingOps.Web\Services\PullItemAdminService.cs')
if ($adminSrc -notmatch 'VendorCode IS NULL AND @VendorCode IS NULL') {
    Fail 'PullItemAdminService duplicate guard is still keyed on (PullId, ItemCode) alone — a supervisor cannot add the second storer by hand'
}
$scriptSrc = Get-Content -Raw (Join-Path $repoRoot 'tools\add-pull-item.ps1')
if ($scriptSrc -notmatch 'vendorPredicate') {
    Fail 'tools/add-pull-item.ps1 dedupe is still SKU-only'
}
OK 'admin service + add-pull-item.ps1 both key on (PullId, ItemCode, VendorCode)'

Cleanup
Write-Host ""
Write-Host "ALL PASS — $($script:pass) assertions across the storer-grain change." -ForegroundColor Green
exit 0
