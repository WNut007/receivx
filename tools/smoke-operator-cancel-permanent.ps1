# Smoke: an operator's cancel is permanent and ERP-proof.
#
# Two operator complaints, one principle: once an operator has decided
# something about a pull item, ERP sync must not undo it.
#
#   1. Operator deletes an item -> next ERP sync brings it back.
#   2. Operator adds or duplicates an item -> next ERP sync strikes it through.
#
# (2) was closed in 1eb4f53 by PullItems.Origin='operator'. (1) is closed here:
# the delete button becomes a CANCEL. Nothing is removed -- the row stays,
# flips to Status='canceled', and takes an OperatorFieldEdits mark on Status.
#
# WHY A MARK AND NOT JUST THE STATUS VALUE
#   ETL sets Status='canceled' itself when an item vanishes from the draft. Both
#   cancels write the identical string, so the value alone cannot tell them
#   apart and the never-re-import rule could not be enforced. The mark is the
#   discriminator, and marks are never released, so it survives the ERP line
#   reappearing any number of times.
#
#   Sections 1 and 3 are the pair that proves the two cancels behave
#   DIFFERENTLY. Either one alone would pass against a build that treated both
#   the same: section 1 alone passes if ETL skips every canceled row, section 3
#   alone passes if ETL skips none.
#
# HOW THIS RUNS THE ETL
#   Operator actions go through the REAL API, so the mark is written by the
#   shipping service -- a smoke that INSERTed into dbo.OperatorFieldEdits
#   directly would pass with the write site entirely unwired.
#   The sync side runs tools/ErpUpsertHarness, which executes the real
#   ErpUpsertService.UpsertAsync with no ERP host in the loop. HARNESS_NO_PURGE
#   keeps the rows between phases so the operator's action is still there when
#   the ETL runs over it.
#
# Fixtures are namespaced HARNESS-OWNER- (the same harness pull
# smoke-operator-owns-edits uses) and PL-CANX- for the closed-pull case. Purged
# on entry, on exit, and on the failure path.
#
# Asserts:
#   1. Operator cancels an ERP-fed item -> sync runs with that line STILL in the
#      draft -> item stays cancelled, values untouched
#   2. Same, across two sync runs -> still cancelled
#   3. ETL cancels an item that vanished -> the line reappears in a later draft
#      -> it REMAINS cancelled (today's behaviour, locked in) and ETL still
#      writes its fields, which is what distinguishes it from case 1
#   4. Operator-created item -> sync -> not cancelled, Origin='operator'
#   5. Operator duplicates an ERP-fed item -> sync -> the duplicate survives
#   6. Cancelled items count for nothing: EXPECTED, progress, the close check,
#      and the pull-sheet Grand Total
#   7. Cancel refused on a closed pull with 409
#   8. Audit row written for the cancel, and the ETL run reports the skip

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'
$PULL = 'HARNESS-OWNER-1'
$SKU = 'HARNESS-SKU-A'
$STORER_A = '5732'
$STORER_B = '84600'
$APIPULL = 'PL-CANX-1'

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

function Login($user, $pass, $whId) {
    $body = @{ username=$user; password=$pass; warehouseId=$whId; remember=$false } | ConvertTo-Json
    $sv = $null
    Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body `
        -ContentType 'application/json' -SessionVariable sv | Out-Null
    return $sv
}

# Marks are keyed by row GUID, so they must go BEFORE the rows they point at or
# the ids are unrecoverable and dbo.OperatorFieldEdits accumulates orphans.
function Cleanup {
    Sql @"
SET NOCOUNT ON;
DELETE e FROM dbo.OperatorFieldEdits e
WHERE  e.EntityType = 'PullItemWindow'
  AND  e.EntityId IN (SELECT w.Id FROM dbo.PullItemWindows w
                        INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
                        INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
                      WHERE p.PullNumber LIKE 'HARNESS-OWNER-%' OR p.PullNumber LIKE 'PL-CANX-%');
DELETE e FROM dbo.OperatorFieldEdits e
WHERE  e.EntityType = 'PullItem'
  AND  e.EntityId IN (SELECT pi.Id FROM dbo.PullItems pi
                        INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
                      WHERE p.PullNumber LIKE 'HARNESS-OWNER-%' OR p.PullNumber LIKE 'PL-CANX-%');
DELETE e FROM dbo.OperatorFieldEdits e
WHERE  e.EntityType = 'Pull'
  AND  e.EntityId IN (SELECT p.Id FROM dbo.Pulls p
                      WHERE p.PullNumber LIKE 'HARNESS-OWNER-%' OR p.PullNumber LIKE 'PL-CANX-%');
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'HARNESS-OWNER-%' OR p.PullNumber LIKE 'PL-CANX-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'HARNESS-OWNER-%' OR p.PullNumber LIKE 'PL-CANX-%';
DELETE FROM dbo.PullSignatures WHERE PullId IN
  (SELECT Id FROM dbo.Pulls WHERE PullNumber LIKE 'PL-CANX-%');
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'HARNESS-OWNER-%' OR PullNumber LIKE 'PL-CANX-%';
DELETE FROM dbo.AuditLog WHERE EntityId LIKE 'HARNESS-OWNER-%' OR EntityId LIKE 'PL-CANX-%';
"@ | Out-Null
}

function Harness($scenario, [switch]$NoPurge) {
    $env:HARNESS_KEEP = '1'
    if ($NoPurge) { $env:HARNESS_NO_PURGE = '1' } else { Remove-Item Env:HARNESS_NO_PURGE -ErrorAction SilentlyContinue }
    try {
        $out = & dotnet run --project (Join-Path $repoRoot 'tools\ErpUpsertHarness') --no-build -- $scenario 2>$null
        $json = ($out | Where-Object { $_ -match '^\{' } | Select-Object -First 1)
        if (-not $json) { Fail "harness scenario '$scenario' produced no JSON (build it: dotnet build tools/ErpUpsertHarness)" }
        return $json | ConvertFrom-Json
    }
    finally {
        Remove-Item Env:HARNESS_KEEP -ErrorAction SilentlyContinue
        Remove-Item Env:HARNESS_NO_PURGE -ErrorAction SilentlyContinue
    }
}

function PullId { return SqlScalar "SET NOCOUNT ON; SELECT CAST(Id AS VARCHAR(36)) FROM dbo.Pulls WHERE PullNumber = '$PULL';" }

function ItemId($storer) {
    return SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(pi.Id AS VARCHAR(36)) FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL' AND pi.VendorCode = '$storer' AND pi.ItemCode = '$SKU';
"@
}

function ItemField($storer, $col) {
    return SqlScalar @"
SET NOCOUNT ON;
SELECT ISNULL(CAST(pi.[$col] AS VARCHAR(200)), '(null)') FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL' AND pi.VendorCode = '$storer' AND pi.ItemCode = '$SKU';
"@
}

function MarkCount($entityType, $entityId, $field) {
    return [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.OperatorFieldEdits
WHERE EntityType = '$entityType' AND EntityId = '$entityId' AND FieldName = '$field';
"@)
}

# Column headers of a worksheet, left to right until the first blank.
function HeaderRow($ws) {
    $hdr = @(); $c = 1
    while ($true) {
        $v = $ws.Cell(1, $c).GetString()
        if ([string]::IsNullOrWhiteSpace($v)) { break }
        $hdr += $v; $c++
    }
    return $hdr
}

function CancelItem($session, $pullId, $itemId) {
    return Invoke-WebRequest -Uri "$base/api/pulls/$pullId/items/$itemId/cancel" `
        -Method POST -WebSession $session -UseBasicParsing
}

function CancelExpectFail($session, $pullId, $itemId, $expected) {
    try {
        Invoke-WebRequest -Uri "$base/api/pulls/$pullId/items/$itemId/cancel" `
            -Method POST -WebSession $session -UseBasicParsing | Out-Null
        return @{ Status = 200; Wrong = $true; Title = '' }
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        $title = ''
        try { $title = ($_.ErrorDetails.Message | ConvertFrom-Json).title } catch {}
        return @{ Status = $code; Wrong = ($code -ne $expected); Title = $title }
    }
}

try {
    Step "0. Preconditions - server, db/052, clean slate"
    try { Invoke-WebRequest -Uri "$base/Account/Login" -UseBasicParsing -TimeoutSec 10 | Out-Null }
    catch { Fail "Dev server not reachable at $base - start it with: dotnet run --launch-profile http" }

    if ((SqlScalar "SET NOCOUNT ON; SELECT CAST(ISNULL(OBJECT_ID('dbo.OperatorFieldEdits'),0) AS VARCHAR);") -eq '0') {
        Fail "dbo.OperatorFieldEdits missing - run db/052_operator_field_edits.sql first"
    }

    Cleanup
    $sup = Login 'swattana' 'demo1234' $WH_01
    OK "db/052 applied, supervisor session at WH-01, namespace clear"

    Step "1. Operator cancels an ERP-fed item; ERP keeps sending the line"
    $seed = Harness 'ownership-seed'
    if ($seed.errors -ne 0) { Fail "seed reported errors=$($seed.errors)" }
    $pullId = PullId
    $itemA  = ItemId $STORER_A
    $itemB  = ItemId $STORER_B
    if (-not $itemA -or -not $itemB) { Fail "seeded items not found (A='$itemA' B='$itemB')" }
    if ((ItemField $STORER_A 'Remark') -ne 'ERP-BASE') { Fail "seed Remark on A = '$(ItemField $STORER_A 'Remark')', expected ERP-BASE" }

    # The DELETE that used to live at this URL must be GONE, not aliased onto
    # cancel. If it still answers, the hard-delete path is reachable and every
    # assertion below is moot.
    try {
        Invoke-WebRequest -Uri "$base/api/pulls/$pullId/items/$itemA" -Method DELETE `
            -WebSession $sup -UseBasicParsing | Out-Null
        Fail "DELETE /api/pulls/{id}/items/{itemId} still answers - the hard-delete path is still reachable"
    } catch {
        $dc = 0
        try { $dc = [int]$_.Exception.Response.StatusCode } catch {}
        if ($dc -eq 200 -or $dc -eq 204) { Fail "DELETE still succeeded (HTTP $dc)" }
    }
    if ((SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.PullItems WHERE Id = '$itemA';") -ne '1') {
        Fail "the DELETE probe removed the row - hard delete is still live"
    }
    OK "the item DELETE endpoint is gone (not aliased onto cancel)"

    $resp = CancelItem $sup $pullId $itemA
    if ($resp.StatusCode -ne 204) { Fail "cancel returned $($resp.StatusCode), expected 204" }
    if ((ItemField $STORER_A 'Status') -ne 'canceled') { Fail "after cancel, A Status = '$(ItemField $STORER_A 'Status')'" }
    if ((MarkCount 'PullItem' $itemA 'Status') -ne 1) {
        Fail "no OperatorFieldEdits mark on Status for item A - ETL cannot tell this cancel from its own"
    }
    OK "operator cancel: row kept, Status='canceled', Status mark written"

    # ownership-changed sends the SAME line back with DIFFERENT values for every
    # protectable field. Under a build that suppressed only the Status column,
    # the remark would come back ERP-CHANGED.
    $run1 = Harness 'ownership-changed' -NoPurge
    if ($run1.errors -ne 0) { Fail "sync run 1 reported errors=$($run1.errors)" }
    if ((ItemField $STORER_A 'Status') -ne 'canceled') { Fail "sync UN-CANCELLED item A - Status is now '$(ItemField $STORER_A 'Status')'" }
    if ((ItemField $STORER_A 'Remark') -ne 'ERP-BASE') {
        Fail "sync rewrote a cancelled item's Remark to '$(ItemField $STORER_A 'Remark')' - the row must be skipped WHOLE, not field-by-field"
    }
    if ((ItemField $STORER_A 'ProductFamily') -ne 'PF-BASE') { Fail "sync rewrote ProductFamily on a cancelled item" }
    if ((ItemField $STORER_A 'Description') -ne 'harness item') { Fail "sync rewrote Description on a cancelled item" }
    OK "sync ran with the line still in the draft: still cancelled, every value untouched"

    Step "2. Still cancelled after a SECOND sync run"
    $run2 = Harness 'ownership-changed' -NoPurge
    if ($run2.errors -ne 0) { Fail "sync run 2 reported errors=$($run2.errors)" }
    if ((ItemField $STORER_A 'Status') -ne 'canceled') { Fail "second sync un-cancelled item A" }
    if ((ItemField $STORER_A 'Remark') -ne 'ERP-BASE')  { Fail "second sync rewrote Remark" }
    if ((MarkCount 'PullItem' $itemA 'Status') -ne 1)   { Fail "Status mark lost after the second run" }
    OK "two sync runs later: still cancelled, values still untouched, mark intact"

    Step "3. ETL's OWN cancel behaves differently - reappearing line stays cancelled but IS written"
    # Storer B is currently live. 'ownership-withdraw' drops B from the draft,
    # so ETL cancels it. B carries no Status mark: this is ETL's cancel.
    $wd = Harness 'ownership-withdraw' -NoPurge
    if ((ItemField $STORER_B 'Status') -ne 'canceled') { Fail "ETL did not cancel the withdrawn storer B (Status='$(ItemField $STORER_B 'Status')')" }
    if ((MarkCount 'PullItem' $itemB 'Status') -ne 0)  { Fail "ETL's own cancel wrote an operator ownership mark - the two cancels are no longer distinguishable" }
    if ($wd.itemsCanceled -lt 1) { Fail "harness reported itemsCanceled=$($wd.itemsCanceled), expected >= 1" }
    OK "ETL cancelled the withdrawn line, with no ownership mark"

    # Stamp a sentinel on B FIRST. Without it this section is vacuous: B has
    # already been through two 'ownership-changed' runs above, so its Remark is
    # ALREADY 'ERP-CHANGED' and the assertion below would hold whether or not
    # the reappearance run wrote anything. The first mutation run caught exactly
    # that -- the smoke stayed green with the distinction removed.
    Sql "SET NOCOUNT ON; UPDATE dbo.PullItems SET Remark = 'PRE-REAPPEAR' WHERE Id = '$itemB';" | Out-Null
    if ((ItemField $STORER_B 'Remark') -ne 'PRE-REAPPEAR') { Fail "sentinel poke on B did not land" }

    $back = Harness 'ownership-changed' -NoPurge
    if ($back.errors -ne 0) { Fail "reappearance run reported errors=$($back.errors)" }
    if ((ItemField $STORER_B 'Status') -ne 'canceled') {
        Fail "an ETL-cancelled line that reappeared was un-cancelled (Status='$(ItemField $STORER_B 'Status')') - nothing may write Status back to normal"
    }
    # THE DISCRIMINATOR. B is cancelled but unowned, so ETL still updates its
    # fields. A is cancelled and owned, so ETL writes nothing. A build that
    # treats both cancels alike fails one of these two whichever way it goes.
    if ((ItemField $STORER_B 'Remark') -ne 'ERP-CHANGED') {
        Fail "ETL skipped an ETL-cancelled row (Remark='$(ItemField $STORER_B 'Remark')') - only an OPERATOR cancel skips the row whole"
    }
    if ((ItemField $STORER_A 'Remark') -ne 'ERP-BASE') { Fail "operator-cancelled row A was written in the same run that wrote B" }
    OK "ETL-cancelled line reappearing: stays cancelled, but its fields ARE written - unlike the operator's"

    Step "4. Operator-created item survives sync (1eb4f53 regression guard)"
    $newItem = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items" -Method POST `
        -WebSession $sup -ContentType 'application/json' -Body (@{
            itemCode = 'CANX-MADE-BY-OP'; description = 'operator row'
            windows = @(@{ hourOfDay = 9; expectedQty = 40 })
        } | ConvertTo-Json -Depth 5)
    $madeId = $newItem.id
    Harness 'ownership-changed' -NoPurge | Out-Null
    $madeStatus = SqlScalar "SET NOCOUNT ON; SELECT Status FROM dbo.PullItems WHERE Id = '$madeId';"
    $madeOrigin = SqlScalar "SET NOCOUNT ON; SELECT ISNULL(Origin,'(null)') FROM dbo.PullItems WHERE Id = '$madeId';"
    if ($madeStatus -ne 'normal')   { Fail "operator-created item was struck through by sync (Status='$madeStatus')" }
    if ($madeOrigin -ne 'operator') { Fail "operator-created item has Origin='$madeOrigin', expected 'operator'" }
    OK "operator-created item survives sync as normal, Origin='operator'"

    Step "5. Operator DUPLICATE of an ERP-fed row survives sync"
    # The drawer's duplicate action clears vendorCode and reuses the ordinary
    # create endpoint, so the copy is a new (ItemCode, VendorCode) key. If a
    # duplicate ever inherited Origin=NULL it would be absent from the draft,
    # unexempt, and cancelled on the next run - the hole this case exists for.
    $dup = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items" -Method POST `
        -WebSession $sup -ContentType 'application/json' -Body (@{
            itemCode = $SKU; description = 'harness item'; vendorCode = 'CANX-DUP-STORER'
            windows = @(@{ hourOfDay = 7; expectedQty = 100 })
        } | ConvertTo-Json -Depth 5)
    $dupId = $dup.id
    if ((SqlScalar "SET NOCOUNT ON; SELECT ISNULL(Origin,'(null)') FROM dbo.PullItems WHERE Id = '$dupId';") -ne 'operator') {
        Fail "duplicated row did not get Origin='operator' - it will be cancelled by the next sync"
    }
    Harness 'ownership-changed' -NoPurge | Out-Null
    $dupStatus = SqlScalar "SET NOCOUNT ON; SELECT Status FROM dbo.PullItems WHERE Id = '$dupId';"
    if ($dupStatus -ne 'normal') { Fail "the duplicated row was struck through by sync (Status='$dupStatus')" }
    OK "duplicated ERP-fed row survives sync as normal"

    Step "8a. The sync run reports the operator-cancelled skip"
    if ($null -eq $back.itemsSkippedOperatorCanceled) {
        Fail "harness output has no itemsSkippedOperatorCanceled - the run-level counter is unwired"
    }
    # EXACTLY one: item A. A build that skipped every canceled row rather than
    # only operator-cancelled ones would report 2 here (A and the ETL-cancelled B),
    # so the exact count is a second, independent detector for that mutation.
    if ($back.itemsSkippedOperatorCanceled -ne 1) {
        Fail "run reported itemsSkippedOperatorCanceled=$($back.itemsSkippedOperatorCanceled), expected exactly 1 (item A only). 2 means ETL is skipping its OWN cancels too."
    }
    OK "ETL run reports the operator-cancelled row as skipped ($($back.itemsSkippedOperatorCanceled))"

    Step "8b. Audit row written for the cancel"
    $auditCount = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.AuditLog
WHERE ActionType = 'cancel' AND EntityType = 'PullItem' AND EntityId = '$itemA';
"@)
    if ($auditCount -lt 1) { Fail "no audit row with ActionType='cancel' for the cancelled item" }
    $auditMsg = SqlScalar @"
SET NOCOUNT ON;
SELECT TOP 1 Message FROM dbo.AuditLog
WHERE ActionType = 'cancel' AND EntityType = 'PullItem' AND EntityId = '$itemA';
"@
    if ($auditMsg -notmatch 'Canceled item') { Fail "cancel audit message reads '$auditMsg'" }
    OK "audit row written: $auditMsg"

    Step "6. Cancelled items count for nothing - EXPECTED, progress, close gate"
    $detail = Invoke-RestMethod -Uri "$base/api/pulls/$pullId" -Method GET -WebSession $sup
    $liveExpected = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(ISNULL(SUM(w.ExpectedQty),0) AS VARCHAR)
FROM dbo.PullItemWindows w
INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL' AND pi.Status <> 'canceled';
"@)
    $allExpected = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(ISNULL(SUM(w.ExpectedQty),0) AS VARCHAR)
FROM dbo.PullItemWindows w
INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL';
"@)
    if ($allExpected -le $liveExpected) { Fail "fixture is not exercising the exclusion: all=$allExpected live=$liveExpected" }
    if ($detail.totalExpected -ne $liveExpected) {
        Fail "totalExpected=$($detail.totalExpected) includes cancelled quantity (live=$liveExpected, all=$allExpected)"
    }
    if ($detail.canceledCount -lt 2) { Fail "canceledCount=$($detail.canceledCount), expected >= 2" }
    OK "EXPECTED excludes cancelled ($liveExpected of $allExpected); canceledCount=$($detail.canceledCount)"

    Step "6b. Pull-sheet Grand Total excludes cancelled quantity"
    # BEHAVIOURAL, against the real workbook -- a source grep here was the first
    # draft and it was wrong twice over: the negative assertion matched
    # BuildGrandTotal's own filter through BuildSummary, and no grep proves what
    # lands in the sheet.
    #
    # Fixture at this point, all on ItemCode HARNESS-SKU-A at hour 07 (Morning):
    #   storer 5732             cancelled by the OPERATOR   Expected 100
    #   storer 84600            cancelled by ETL            Expected 250
    #   storer CANX-DUP-STORER  live                        Expected 100
    # Grand Total groups by ItemCode alone, so all three collapse into one row.
    # It must read 100 -- the live row only -- and not 450. Summary is per
    # (pull, item, vendor), so the cancelled rows keep their own rows there and
    # must still say Canceled: the fix is an aggregation filter, not a row drop.
    $pullDate = SqlScalar "SET NOCOUNT ON; SELECT CONVERT(varchar(10), PullDate, 23) FROM dbo.Pulls WHERE PullNumber = '$PULL';"
    $tmpXlsx = Join-Path ([IO.Path]::GetTempPath()) 'smoke-operator-cancel-permanent.xlsx'
    if (Test-Path $tmpXlsx) { Remove-Item $tmpXlsx -Force }
    Invoke-WebRequest -WebSession $sup -OutFile $tmpXlsx `
        -Uri "$base/api/reports/pull-sheets/export.xlsx?warehouseId=$WH_01&date=$pullDate&period=morning" | Out-Null
    if (-not (Test-Path $tmpXlsx)) { Fail 'export.xlsx produced no file' }

    $closedXml = Join-Path $repoRoot 'src/ReceivingOps.Web/bin/Debug/net8.0/ClosedXML.dll'
    if (-not (Test-Path $closedXml)) { Fail "ClosedXML.dll not found at $closedXml -- build the project first" }
    Add-Type -Path $closedXml
    $wb = New-Object ClosedXML.Excel.XLWorkbook $tmpXlsx
    try {
        $gtWs = $wb.Worksheet('Grand Total')
        $gtHdr = HeaderRow $gtWs
        $gtKey = [array]::IndexOf($gtHdr, 'Item Code') + 1
        $gtExp = [array]::IndexOf($gtHdr, 'Expected') + 1
        if ($gtKey -lt 1 -or $gtExp -lt 1) { Fail "Grand Total headers unexpected -- [$($gtHdr -join ' | ')]" }
        $gtValue = $null
        2..($gtWs.LastRowUsed().RowNumber()) | ForEach-Object {
            if ($gtWs.Cell($_, $gtKey).GetString() -eq $SKU) { $gtValue = $gtWs.Cell($_, $gtExp).GetString() }
        }
        if ($null -eq $gtValue) { Fail "Grand Total has no row for $SKU -- the fixture never reached the sheet" }
        if ([int]$gtValue -ne 100) {
            Fail "Grand Total Expected for $SKU is $gtValue, expected 100 (the live row only). 450 means both cancelled rows are still counted; 350 or 200 means one of them is."
        }

        $sumWs = $wb.Worksheet('Summary')
        $sumHdr = HeaderRow $sumWs
        $sKey = [array]::IndexOf($sumHdr, 'Item Code') + 1
        $sVen = [array]::IndexOf($sumHdr, 'Vendor Code') + 1
        $sSta = [array]::IndexOf($sumHdr, 'Row Status') + 1
        if ($sKey -lt 1 -or $sVen -lt 1 -or $sSta -lt 1) { Fail "Summary headers unexpected -- [$($sumHdr -join ' | ')]" }
        $seenCancelled = 0; $seenLive = 0
        2..($sumWs.LastRowUsed().RowNumber()) | ForEach-Object {
            if ($sumWs.Cell($_, $sKey).GetString() -eq $SKU) {
                $v = $sumWs.Cell($_, $sVen).GetString()
                $st = $sumWs.Cell($_, $sSta).GetString()
                if ($v -eq $STORER_A) {
                    if ($st -notmatch 'Cancel') { Fail "Summary row for the operator-cancelled storer reads Row Status '$st', expected Canceled" }
                    $seenCancelled++
                }
                if ($v -eq 'CANX-DUP-STORER') { $seenLive++ }
            }
        }
        if ($seenCancelled -lt 1) { Fail "Summary dropped the cancelled row entirely -- it must still be listed, as Canceled" }
        if ($seenLive -lt 1)      { Fail "Summary lost the live row" }
        OK "Grand Total counts only the live row (100); Summary still lists the cancelled row as Canceled"
    }
    finally {
        $wb.Dispose()
        if (Test-Path $tmpXlsx) { Remove-Item $tmpXlsx -Force -ErrorAction SilentlyContinue }
    }

    Step "6c. Close gate counts only live rows"
    $outstandingLive = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR)
FROM dbo.PullItemWindows w
INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL' AND pi.Status <> 'canceled' AND w.ExpectedQty > w.ReceivedQty;
"@)
    foreach ($live in @($madeId, $dupId)) { CancelItem $sup $pullId $live | Out-Null }
    $outstandingAfter = [int](SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR)
FROM dbo.PullItemWindows w
INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL' AND pi.Status <> 'canceled' AND w.ExpectedQty > w.ReceivedQty;
"@)
    if ($outstandingLive -lt 1)   { Fail "fixture had no outstanding live windows to begin with" }
    if ($outstandingAfter -ne 0)  { Fail "close gate still sees $outstandingAfter outstanding window(s) after every live row was cancelled" }
    OK "close gate: outstanding fell $outstandingLive -> 0 once the live rows were cancelled"

    Step "7. Cancel refused on a closed pull -> 409"
    $closedPullId = [Guid]::NewGuid().ToString()
    $closedItemId = [Guid]::NewGuid().ToString()
    Sql @"
SET NOCOUNT ON;
INSERT INTO dbo.Pulls (Id, PullNumber, WarehouseId, PullDate, Status, LockPoByPull, LockHourCap)
VALUES ('$closedPullId', '$APIPULL', '$WH_01', CAST(GETUTCDATE() AS date), 'closed', 0, 1);
INSERT INTO dbo.PullItems (Id, PullId, ItemCode, Description, Status, SortOrder)
VALUES ('$closedItemId', '$closedPullId', 'CANX-CLOSED', 'closed pull row', 'normal', 1);
INSERT INTO dbo.PullItemWindows (Id, PullItemId, HourOfDay, ExpectedQty, ReceivedQty)
VALUES (NEWID(), '$closedItemId', 8, 10, 0);
"@ | Out-Null
    $r = CancelExpectFail $sup $closedPullId $closedItemId 409
    if ($r.Wrong) { Fail "cancel on a closed pull returned $($r.Status), expected 409" }
    if ((SqlScalar "SET NOCOUNT ON; SELECT Status FROM dbo.PullItems WHERE Id = '$closedItemId';") -ne 'normal') {
        Fail "the refused cancel still mutated the row"
    }
    if ((MarkCount 'PullItem' $closedItemId 'Status') -ne 0) { Fail "the refused cancel still wrote an ownership mark" }
    OK "cancel on a closed pull refused with 409, nothing written"

    Cleanup
    Write-Host ""
    Write-Host "ALL PASS ($script:pass checks) - operator cancel is permanent and ERP-proof." -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "FAIL: unhandled - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Cleanup
    exit 1
}
