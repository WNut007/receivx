# Smoke: operator edits win permanently over ERP sync (db/052).
#
# Once data is in Receivx, it belongs to Receivx. ERP sync populates a pull
# initially; after that, anything an operator changes is authoritative and no
# later sync may overwrite it — EVEN IF ERP later sends a different value.
# That last clause is the whole design: this is "the operator wins
# permanently", not "the operator wins until ERP changes". §3 below is the
# case that tells those two apart, and it is the reason the harness draft
# carries deliberately DIFFERENT values on the re-run.
#
# Protection is FIELD-level, not row-level. Editing Remark must not freeze
# Description, ProductFamily or ExpectedQty on the same row.
#
# Twelve protectable fields: Pulls.PullDate; PullItems.{Description,
# VendorCode, Remark} plus the seven Phase 9.1 extended fields;
# PullItemWindows.ExpectedQty.
#
# HOW THIS RUNS THE ETL
#   Operator edits go through the REAL API, so ownership marks are written by
#   the shipping service rather than by fixture SQL — a smoke that inserted
#   into dbo.OperatorFieldEdits directly would pass with the write sites
#   entirely unwired.
#   The sync side runs through tools/ErpUpsertHarness, which executes the real
#   ErpUpsertService.UpsertAsync against the dev DB with no ERP host in the
#   loop (the same vehicle smoke-storer-grain uses). Two phases against ONE
#   pull, with HARNESS_NO_PURGE=1 on the second so the operator's edit is
#   still there when the ETL runs over it.
#
# Fixtures are namespaced HARNESS-OWNER- and purged on entry, on exit, and on
# the failure path.
#
# Asserts:
#   1. Operator sets Remark        → sync runs → Remark unchanged
#   2. ERP sends a DIFFERENT Remark → still unchanged (permanent, not
#      until-ERP-changes)
#   3. Field-level: the same row's untouched Description / ProductFamily /
#      ExpectedQty are updated by ETL normally
#   4. Untouched row → ETL updates it exactly as before. No regression
#   5. Operator-created item → survives sync as Status='normal', values intact
#   6. ERP-sourced item that disappears from the draft → still 'canceled'
#   7. Row with no ownership history (a pre-migration row by definition) →
#      treated as untouched, ETL updates it
#   8. Per-run reporting: counts and affected fields, on ErpUpsertResult and
#      on the dbo.ErpSyncLog columns
#   9. Un-editing: a field edited BACK to its original ERP value stays owned
#  10. Pulls.PullDate ownership (the one header-level protectable field)

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$WH_01 = '22222222-2222-2222-2222-000000000001'
$sqlSrv = 'LAPTOP-CSB3KO3E'
$PULL = 'HARNESS-OWNER-1'
$SKU = 'HARNESS-SKU-A'
$STORER_A = '5732'
$STORER_B = '84600'

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

# Purge every HARNESS-OWNER- artefact plus its ownership marks. The marks are
# keyed by row GUID, so they must go BEFORE the rows they point at or the ids
# are unrecoverable and the table accumulates orphans across runs.
function Cleanup {
    Sql @"
SET NOCOUNT ON;
DELETE e FROM dbo.OperatorFieldEdits e
WHERE  e.EntityType = 'PullItemWindow'
  AND  e.EntityId IN (SELECT w.Id FROM dbo.PullItemWindows w
                        INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
                        INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
                      WHERE p.PullNumber LIKE 'HARNESS-OWNER-%');
DELETE e FROM dbo.OperatorFieldEdits e
WHERE  e.EntityType = 'PullItem'
  AND  e.EntityId IN (SELECT pi.Id FROM dbo.PullItems pi
                        INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
                      WHERE p.PullNumber LIKE 'HARNESS-OWNER-%');
DELETE e FROM dbo.OperatorFieldEdits e
WHERE  e.EntityType = 'Pull'
  AND  e.EntityId IN (SELECT p.Id FROM dbo.Pulls p WHERE p.PullNumber LIKE 'HARNESS-OWNER-%');
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'HARNESS-OWNER-%';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber LIKE 'HARNESS-OWNER-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'HARNESS-OWNER-%';
DELETE FROM dbo.AuditLog WHERE EntityId LIKE 'HARNESS-OWNER-%';
"@ | Out-Null
}

# Runs the harness. $noPurge keeps the existing rows (phase 2+); HARNESS_KEEP
# always set, because this smoke owns the cleanup and needs the rows between
# invocations.
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

function PullId    { return SqlScalar "SET NOCOUNT ON; SELECT CAST(Id AS VARCHAR(36)) FROM dbo.Pulls WHERE PullNumber = '$PULL';" }
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

# The item PUT is bulk-overwrite: every field must be echoed or it is nulled.
function EditItem($session, $pullId, $itemId, $hash) {
    return Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$itemId" -Method PUT `
        -WebSession $session -ContentType 'application/json' -Body ($hash | ConvertTo-Json)
}

try {
    # ------------------------------------------------------------------
    Step "0. Preconditions — server, db/052, harness built, clean slate"
    try { Invoke-WebRequest -Uri "$base/Account/Login" -UseBasicParsing -TimeoutSec 10 | Out-Null }
    catch { Fail "Dev server not reachable at $base — start it with: dotnet run --launch-profile http" }

    if ((SqlScalar "SET NOCOUNT ON; SELECT CAST(ISNULL(OBJECT_ID('dbo.OperatorFieldEdits'),0) AS VARCHAR);") -eq '0') {
        Fail "dbo.OperatorFieldEdits missing — run db/052_operator_field_edits.sql first"
    }
    if ((SqlScalar "SET NOCOUNT ON; SELECT CAST(ISNULL(COL_LENGTH('dbo.PullItems','Origin'),0) AS VARCHAR);") -eq '0') {
        Fail "dbo.PullItems.Origin missing — run db/052 first"
    }
    foreach ($c in @('FieldsSkippedCount','FieldsWrittenCount','FieldProtectionTotals')) {
        if ((SqlScalar "SET NOCOUNT ON; SELECT CAST(ISNULL(COL_LENGTH('dbo.ErpSyncLog','$c'),0) AS VARCHAR);") -eq '0') {
            Fail "dbo.ErpSyncLog.$c missing — run db/052 first"
        }
    }

    Cleanup
    $sup = Login 'swattana' 'demo1234' $WH_01
    OK "db/052 applied, supervisor session at WH-01, namespace clear"

    # ------------------------------------------------------------------
    Step "1. Seed the pull through the real ETL (baseline ERP values)"
    $seed = Harness 'ownership-seed'
    if ($seed.errors -ne 0)        { Fail "seed reported errors=$($seed.errors)" }
    if ($seed.fieldsSkipped -ne 0) { Fail "seed skipped $($seed.fieldsSkipped) field(s) — nothing is owned yet" }
    if ((ItemField $STORER_A 'Remark') -ne 'ERP-BASE') { Fail "seed Remark on $STORER_A = '$(ItemField $STORER_A 'Remark')', expected ERP-BASE" }
    $pullId = PullId
    $itemA = ItemId $STORER_A
    $itemB = ItemId $STORER_B
    if (-not $itemA -or -not $itemB) { Fail "seeded items not found (A='$itemA' B='$itemB')" }
    OK "pull seeded via real UpsertAsync: 2 storers at ERP-BASE, 0 fields owned"

    # ------------------------------------------------------------------
    Step "2. Operator edits Remark on storer A through the real API"
    EditItem $sup $pullId $itemA @{
        description = 'harness item'; vendorCode = $STORER_A; vendorName = $null
        tag = $null; status = 'normal'; remark = 'OPERATOR-OWNED'
    } | Out-Null

    if ((ItemField $STORER_A 'Remark') -ne 'OPERATOR-OWNED') { Fail "operator edit did not land" }
    if ((MarkCount 'PullItem' $itemA 'Remark') -ne 1) {
        Fail "no ownership mark written for Remark — the write site is not wired to OperatorFieldEdits"
    }
    # Field-level, not row-level: the PUT carried Description and VendorCode
    # unchanged, so they must NOT be marked. This is the presence-vs-diff
    # distinction; marking on presence would show 1 here.
    if ((MarkCount 'PullItem' $itemA 'Description') -ne 0) {
        Fail "Description was marked owned though the operator did not change it — ownership is keyed on request presence, not on a value diff"
    }
    if ((MarkCount 'PullItem' $itemA 'VendorCode') -ne 0) {
        Fail "VendorCode was marked owned though it did not change — presence, not diff"
    }
    OK "Remark marked owned; Description + VendorCode carried unchanged in the same PUT were NOT marked"

    # ------------------------------------------------------------------
    Step "3. Assertions 1-4, 7 — sync runs with DIFFERENT ERP values"
    $run = Harness 'ownership-changed' -NoPurge

    # 1 + 2. The operator's Remark survives, and ERP sent something else.
    $remarkA = ItemField $STORER_A 'Remark'
    if ($remarkA -ne 'OPERATOR-OWNED') {
        Fail "Remark on $STORER_A = '$remarkA', expected OPERATOR-OWNED. ERP sent ERP-CHANGED, so this is the (1)-vs-(2) distinction failing: the operator must win PERMANENTLY, not until ERP changes"
    }

    # 3. Field-level: untouched fields on the SAME row still updated.
    $descA = ItemField $STORER_A 'Description'
    $famA  = ItemField $STORER_A 'ProductFamily'
    if ($descA -ne 'ERP DESC CHANGED') { Fail "Description on $STORER_A = '$descA', expected 'ERP DESC CHANGED' — protection is row-level, not field-level" }
    if ($famA -ne 'PF-CHANGED')        { Fail "ProductFamily on $STORER_A = '$famA', expected PF-CHANGED — protection is row-level, not field-level" }

    # 4 + 7. The untouched row has no marks at all, which is exactly what a
    # pre-migration row looks like, and ETL updates it as it always did.
    $marksB = [int](SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR) FROM dbo.OperatorFieldEdits WHERE EntityId = '$itemB';")
    if ($marksB -ne 0) { Fail "storer B carries $marksB mark(s) — it should have none" }
    $remarkB = ItemField $STORER_B 'Remark'
    if ($remarkB -ne 'ERP-CHANGED') { Fail "Remark on untouched $STORER_B = '$remarkB', expected ERP-CHANGED — no-history rows must stay fully writable" }
    OK "owned Remark held at OPERATOR-OWNED while Description/ProductFamily on the SAME row took ERP's new values; no-history row updated normally"

    # ------------------------------------------------------------------
    Step "4. Assertion 8 — per-run reporting names the counts and the fields"
    if ($run.fieldsSkipped -ne 1) { Fail "fieldsSkipped=$($run.fieldsSkipped), expected exactly 1 (Remark on storer A)" }
    if ($run.rowsWithAnySkip -ne 1) { Fail "rowsWithAnySkip=$($run.rowsWithAnySkip), expected 1" }
    if ($run.skippedByField.Remark -ne 1) { Fail "skippedByField.Remark=$($run.skippedByField.Remark), expected 1" }
    # 23 candidates total (1 PullDate + 2 items x 10 + 2 windows) minus the 1 skipped.
    if ($run.fieldsWritten -ne 22) { Fail "fieldsWritten=$($run.fieldsWritten), expected 22 (23 candidates - 1 owned)" }
    OK "run reports fieldsSkipped=1 (Remark), rowsWithAnySkip=1, fieldsWritten=22"

    # ------------------------------------------------------------------
    Step "5. Assertion 9 — un-editing: back to the ERP value stays owned"
    # The operator sets Remark to exactly what ERP last sent. Under "stays
    # owned" the field is still protected afterwards; under a release-on-match
    # rule ETL would silently take it back.
    EditItem $sup $pullId $itemA @{
        description = 'ERP DESC CHANGED'; vendorCode = $STORER_A; vendorName = $null
        tag = $null; status = 'normal'; remark = 'ERP-CHANGED'
    } | Out-Null
    if ((MarkCount 'PullItem' $itemA 'Remark') -ne 1) { Fail "Remark mark disappeared after an un-edit — ownership must never be released" }

    # Now ERP sends ERP-CHANGED again on the next run; if ownership had been
    # released the value would be identical either way, so re-point the field
    # at something only the operator could have set, then re-run.
    EditItem $sup $pullId $itemA @{
        description = 'ERP DESC CHANGED'; vendorCode = $STORER_A; vendorName = $null
        tag = $null; status = 'normal'; remark = 'OPERATOR-AGAIN'
    } | Out-Null
    Harness 'ownership-changed' -NoPurge | Out-Null
    if ((ItemField $STORER_A 'Remark') -ne 'OPERATOR-AGAIN') {
        Fail "Remark = '$(ItemField $STORER_A 'Remark')' after an un-edit round trip, expected OPERATOR-AGAIN"
    }
    OK "a field edited back to its ERP value stays owned; ownership is never released"

    # ------------------------------------------------------------------
    Step "6. Assertion 10 — Pulls.PullDate is protectable too"
    $origDate = SqlScalar "SET NOCOUNT ON; SELECT CONVERT(varchar(10), PullDate, 23) FROM dbo.Pulls WHERE PullNumber = '$PULL';"
    $newDate = (Get-Date $origDate).AddDays(3).ToString('yyyy-MM-dd')
    Invoke-RestMethod -Uri "$base/api/pulls/$pullId" -Method PUT -WebSession $sup `
        -ContentType 'application/json' -Body (@{
            pullDate = $newDate; eta = $null; notes = 'owned-date-test'
            referenceNumber = $null; lockPoByPull = $true; lockHourCap = $true
        } | ConvertTo-Json) | Out-Null

    if ((MarkCount 'Pull' $pullId 'PullDate') -ne 1) { Fail "PullDate not marked owned after the operator changed it" }
    $r2 = Harness 'ownership-changed' -NoPurge
    $dateNow = SqlScalar "SET NOCOUNT ON; SELECT CONVERT(varchar(10), PullDate, 23) FROM dbo.Pulls WHERE PullNumber = '$PULL';"
    if ($dateNow -ne $newDate) { Fail "PullDate = $dateNow after sync, expected $newDate — ETL overwrote an owned header field" }
    if ($r2.skippedByField.PullDate -ne 1) { Fail "run did not report PullDate as skipped" }
    OK "operator-set PullDate survived the sync and is reported as skipped"

    # ------------------------------------------------------------------
    Step "7. Assertion 5 — an operator-created item is never canceled by ETL"
    $created = Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items" -Method POST -WebSession $sup `
        -ContentType 'application/json' -Body (@{
            itemCode = 'HARNESS-OWNER-MANUAL'; description = 'operator added this'
            vendorCode = $STORER_A; remark = 'MANUAL-REMARK'
            windows = @(@{ hourOfDay = 7; expectedQty = 42 })
        } | ConvertTo-Json)

    $manualOrigin = SqlScalar @"
SET NOCOUNT ON;
SELECT ISNULL(pi.Origin,'(null)') FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL' AND pi.ItemCode = 'HARNESS-OWNER-MANUAL';
"@
    if ($manualOrigin -ne 'operator') { Fail "operator-created item Origin='$manualOrigin', expected 'operator' — provenance is not being stamped" }

    $r3 = Harness 'ownership-changed' -NoPurge
    $manual = SqlScalar @"
SET NOCOUNT ON;
SELECT pi.Status + '|' + ISNULL(pi.Remark,'(null)') + '|' + CAST(ISNULL((SELECT SUM(w.ExpectedQty) FROM dbo.PullItemWindows w WHERE w.PullItemId = pi.Id),0) AS VARCHAR)
FROM dbo.PullItems pi INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL' AND pi.ItemCode = 'HARNESS-OWNER-MANUAL';
"@
    if ($manual -ne 'normal|MANUAL-REMARK|42') {
        Fail "operator-created item after sync = '$manual', expected 'normal|MANUAL-REMARK|42' — it must be neither canceled nor touched"
    }
    if ($r3.itemsExemptCreated -lt 1) { Fail "run reported itemsExemptCreated=$($r3.itemsExemptCreated), expected at least 1" }
    OK "operator-created item survived sync untouched (normal, own remark, own qty) and is reported as exempt"

    # ------------------------------------------------------------------
    Step "8. Assertion 6 — an ERP item that disappears is still canceled"
    $r4 = Harness 'ownership-withdraw' -NoPurge
    $statusB = ItemField $STORER_B 'Status'
    if ($statusB -ne 'canceled') { Fail "withdrawn ERP item on $STORER_B = '$statusB', expected canceled — existing behaviour must be unchanged" }
    if ($r4.itemsCanceled -lt 1)  { Fail "run reported itemsCanceled=$($r4.itemsCanceled), expected at least 1" }
    # …and the operator's item, equally absent from that draft, is not.
    $manualStatus = SqlScalar @"
SET NOCOUNT ON;
SELECT pi.Status FROM dbo.PullItems pi INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE p.PullNumber = '$PULL' AND pi.ItemCode = 'HARNESS-OWNER-MANUAL';
"@
    if ($manualStatus -ne 'normal') { Fail "operator-created item = '$manualStatus' on the withdraw run, expected normal" }
    OK "ERP-sourced item absent from the draft canceled as before; the operator-created item absent from the SAME draft was not"

    # ------------------------------------------------------------------
    Step "9. Assertion 3 (windows) — ExpectedQty is owned independently"
    $winQty = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(w.ExpectedQty AS VARCHAR) FROM dbo.PullItemWindows w
WHERE w.PullItemId = '$itemA' AND w.HourOfDay = 7;
"@
    Invoke-RestMethod -Uri "$base/api/pulls/$pullId/items/$itemA/windows/7" -Method PUT -WebSession $sup `
        -ContentType 'application/json' -Body (@{ expectedQty = 777 } | ConvertTo-Json) | Out-Null

    $winId = SqlScalar "SET NOCOUNT ON; SELECT CAST(Id AS VARCHAR(36)) FROM dbo.PullItemWindows WHERE PullItemId = '$itemA' AND HourOfDay = 7;"
    if ((MarkCount 'PullItemWindow' $winId 'ExpectedQty') -ne 1) { Fail "window ExpectedQty not marked owned" }

    Harness 'ownership-changed' -NoPurge | Out-Null
    $winAfter = SqlScalar "SET NOCOUNT ON; SELECT CAST(ExpectedQty AS VARCHAR) FROM dbo.PullItemWindows WHERE Id = '$winId';"
    if ($winAfter -ne '777') { Fail "window ExpectedQty = $winAfter after sync, expected 777 (was $winQty before the operator set it)" }
    # Storer B's window, unowned, still tracks ERP.
    $winB = SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(w.ExpectedQty AS VARCHAR) FROM dbo.PullItemWindows w WHERE w.PullItemId = '$itemB' AND w.HourOfDay = 7;
"@
    if ($winB -ne '250') { Fail "unowned window on storer B = $winB, expected 250 from the ERP draft" }
    OK "operator-set ExpectedQty held at 777 while the unowned window on the other row tracked ERP to 250"

    # ------------------------------------------------------------------
    Step "10. Assertion 7 explicit — clearing history hands the field back"
    # A pre-migration row is definitionally one with no marks. Deleting this
    # row's marks reproduces that state exactly, and ETL must then write it
    # again. Without this the no-history case rests on storer B never having
    # been edited, which a bug that ignores the table entirely would also pass.
    Sql "SET NOCOUNT ON; DELETE FROM dbo.OperatorFieldEdits WHERE EntityId = '$itemA' AND FieldName = 'Remark';" | Out-Null
    Harness 'ownership-changed' -NoPurge | Out-Null
    $remarkAfterClear = ItemField $STORER_A 'Remark'
    if ($remarkAfterClear -ne 'ERP-CHANGED') {
        Fail "Remark = '$remarkAfterClear' after its mark was removed, expected ERP-CHANGED — a row with no history must be fully writable"
    }
    OK "with the mark removed the field reverts to ETL control — no-history rows behave exactly as before db/052"

    # ------------------------------------------------------------------
    Step "11. Assertion 8 (persistence) — ErpSyncLog carries the run summary"
    # The harness calls UpsertAsync directly and never writes ErpSyncLog, so
    # persistence is proven by a real ErpSyncJob run. ERP-dependent, and
    # skipped cleanly when the host is unreachable, matching the other ERP
    # smokes rather than failing the battery off-VPN.
    $erpUp = $false
    try {
        $probe = New-Object System.Net.Sockets.TcpClient
        $probe.SendTimeout = 2000; $probe.ReceiveTimeout = 2000
        if ($probe.ConnectAsync('103.13.229.21', 1433).Wait(2000)) { $erpUp = $true }
        $probe.Close()
    } catch { $erpUp = $false }

    if (-not $erpUp) {
        Write-Host "  SKIP: ERP host unreachable — ErpSyncLog persistence not exercised" -ForegroundColor Yellow
    }
    else {
        $admin = Login 'sadmin' 'admin' $WH_01
        $trig = Invoke-RestMethod -Uri "$base/api/admin/erp-sync/trigger" -Method POST -WebSession $admin `
            -ContentType 'application/json' -Body (@{ sourceName = 'BPI_PRS' } | ConvertTo-Json)
        $deadline = (Get-Date).AddSeconds(180)
        $row = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $row = SqlScalar @"
SET NOCOUNT ON;
SELECT TOP 1 Status + '|' + ISNULL(CAST(FieldsSkippedCount AS VARCHAR),'(null)')
     + '|' + ISNULL(CAST(FieldsWrittenCount AS VARCHAR),'(null)')
     + '|' + ISNULL(LEFT(FieldProtectionTotals, 60),'(null)')
FROM dbo.ErpSyncLog ORDER BY StartedAt DESC;
"@
            if ($row -like 'succeeded|*' -or $row -like 'failed|*') { break }
        }
        if (-not $row)            { Fail "no ErpSyncLog row appeared for the triggered run" }
        if ($row -like 'failed|*') { Write-Host "  SKIP: triggered run failed upstream ($row) — persistence not exercised" -ForegroundColor Yellow }
        else {
            $parts = $row -split '\|', 4
            if ($parts[1] -eq '(null)') { Fail "FieldsSkippedCount is NULL on a succeeded run — ErpSyncJob is not persisting it" }
            if ($parts[2] -eq '(null)') { Fail "FieldsWrittenCount is NULL on a succeeded run" }
            if ($parts[3] -notmatch 'skipped') { Fail "FieldProtectionTotals does not carry the expected JSON shape: $($parts[3])" }
            if ([int]$parts[2] -le 0)   { Fail "FieldsWrittenCount=$($parts[2]) on a real run — ETL wrote nothing, which cannot be right" }
            OK "real ErpSyncJob run persisted FieldsSkippedCount=$($parts[1]), FieldsWrittenCount=$($parts[2]), and the JSON breakdown"
        }
    }

    # ------------------------------------------------------------------
    Step "12. Source — the two gates stay separate and the diff rule is stated"
    $svc = Get-Content (Join-Path $repoRoot 'src\ReceivingOps.Web\Services\ErpSync\ErpUpsertService.cs') -Raw
    # The STATIC protected-column list must survive untouched: db/052 is an
    # additional gate, not a replacement, and folding one into the other would
    # silently drop Pulls.Status / ReceivedQty protection for everybody.
    foreach ($tok in @('LockPoByPull, LockHourCap, ClosedAt, ClosedBy', 'PullItemWindows: ReceivedQty')) {
        if ($svc -notmatch [regex]::Escape($tok)) { Fail "static protected-column list lost '$tok'" }
    }
    if ($svc -notmatch 'OperatorFieldEdits\.ReadForPullAsync') { Fail "ErpUpsertService no longer reads ownership marks" }

    $helper = Get-Content (Join-Path $repoRoot 'src\ReceivingOps.Web\Data\OperatorFieldEdits.cs') -Raw
    $mark = [regex]::Match($helper, '(?s)public static async Task<IReadOnlyList<string>> MarkChangedAsync\(.*?\n    \}')
    if (-not $mark.Success) { Fail "MarkChangedAsync not found" }
    if ($mark.Value -notmatch 'if \(SameValue\(change\.OldValue, change\.NewValue\)\) continue;') {
        Fail "MarkChangedAsync no longer skips unchanged fields — ownership would be taken on request presence, freezing whole rows on the first edit"
    }
    OK "static list intact, ETL reads marks, and ownership is still gated on a value diff"

    Write-Host "`n$($script:pass) assertion group(s) passed." -ForegroundColor Green
}
finally {
    Cleanup
}

Write-Host "`nAll operator-ownership assertions passed." -ForegroundColor Green
exit 0
