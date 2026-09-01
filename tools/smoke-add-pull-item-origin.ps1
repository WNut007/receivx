# Smoke test: an item created by tools/add-pull-item.ps1 survives an ERP sync
#
# WHY THIS EXISTS
#   db/052 added dbo.PullItems.Origin so the ETL's missing-from-draft cancel
#   path can tell an operator-created row from an ERP-sourced one. An item an
#   operator creates is BY DEFINITION never in the ERP draft, so without the
#   'operator' stamp the next in-window sync strikes it through -- db/052
#   records one traceable production victim of exactly that (WIDGET-1000 on
#   pull 0000015899, cancelled 28 minutes after it was created).
#
#   The API create path was stamped when db/052 landed and is covered by
#   smoke-operator-cancel-permanent case 4. tools/add-pull-item.ps1 was NOT.
#   Its INSERT named its columns explicitly and omitted Origin, so every item
#   it made was unexempt -- while CLAUDE.md still documents it as the supported
#   headless / CI / pre-UI-deploy route. This smoke covers that second path.
#
# WHAT IT PROVES, AND WHY BEHAVIOURALLY
#   Not "the INSERT contains the word Origin" -- that is a source grep and it
#   would pass against a build that wrote the column into the wrong statement,
#   or wrote it as something the ETL does not treat as exempt. The assertion is
#   that the row is still Status='normal' AFTER a real ErpUpsertService.UpsertAsync
#   has run over its pull with the row absent from the draft. Revert the one-line
#   fix at add-pull-item.ps1's INSERT and section 4 goes red: the sync cancels it.
#
# HOW THE SCRIPT IS DRIVEN
#   add-pull-item.ps1 is interactive -- every field is a Read-Host and it takes
#   no non-interactive parameters beyond -Server / -Database. It is driven here
#   by piping its answers on stdin, which pwsh's Read-Host consumes in order.
#   That makes section 3 sensitive to the PROMPT ORDER: add or reorder a prompt
#   in that script and the answers desync, the create never completes, and this
#   smoke fails at section 3 rather than silently testing nothing. The expected
#   sequence is written out beside the answers below; keep the two in step.
#
#   ITEM_CODE is deliberately one that matches no open PO line, which selects
#   the script's "not on any open PO -- Add anyway?" branch. That branch is
#   stable regardless of what POs happen to exist in the dev database; the
#   PO-hit branch prompts differently and would make the answer list depend on
#   seed data.
#
# Sections:
#   1. purge the namespace on entry
#   2. seed the harness pull (real ErpUpsertService, no ERP host needed)
#   3. create an item through add-pull-item.ps1 and check the stamp landed
#   4. run the ETL again with the item absent from the draft -- it must survive
#   5. the run reports the exemption
#
# Needs: sqlcmd against the dev DB, and tools/ErpUpsertHarness built
# (dotnet build tools/ErpUpsertHarness). Does NOT need the web server.

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.."
$sqlSrv   = 'LAPTOP-CSB3KO3E'
$PULL     = 'HARNESS-OWNER-1'     # the harness owns this number; it purges HARNESS-%
$ITEM     = 'APIO-SCRIPT-MADE'    # namespaced; matches no PO line, by design

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

# Marks are keyed by row GUID, so they go BEFORE the rows they point at or the
# ids are unrecoverable and dbo.OperatorFieldEdits accumulates orphans. The
# ITEM leg is separate from the pull leg because a desynced run in section 3
# can leave the item on a pull the harness has already purged.
function Cleanup {
    Sql @"
SET NOCOUNT ON;
DELETE e FROM dbo.OperatorFieldEdits e
WHERE  e.EntityType = 'PullItem'
  AND  e.EntityId IN (SELECT pi.Id FROM dbo.PullItems pi
                        INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
                      WHERE p.PullNumber LIKE 'HARNESS-OWNER-%');
DELETE e FROM dbo.OperatorFieldEdits e
WHERE  e.EntityType = 'PullItem'
  AND  e.EntityId IN (SELECT Id FROM dbo.PullItems WHERE ItemCode = '$ITEM');
DELETE e FROM dbo.OperatorFieldEdits e
WHERE  e.EntityType = 'Pull'
  AND  e.EntityId IN (SELECT Id FROM dbo.Pulls WHERE PullNumber LIKE 'HARNESS-OWNER-%');
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
WHERE  pi.ItemCode = '$ITEM';
DELETE w FROM dbo.PullItemWindows w
  INNER JOIN dbo.PullItems pi ON pi.Id = w.PullItemId
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE  p.PullNumber LIKE 'HARNESS-OWNER-%';
DELETE FROM dbo.AuditLog
WHERE  EntityType = 'PullItem'
  AND  EntityId IN (SELECT CONVERT(VARCHAR(36), Id) FROM dbo.PullItems WHERE ItemCode = '$ITEM');
DELETE FROM dbo.PullItems WHERE ItemCode = '$ITEM';
DELETE pi FROM dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE  p.PullNumber LIKE 'HARNESS-OWNER-%';
DELETE FROM dbo.Pulls WHERE PullNumber LIKE 'HARNESS-OWNER-%';
DELETE FROM dbo.AuditLog WHERE EntityId LIKE 'HARNESS-OWNER-%';
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

function ItemField($col) {
    return SqlScalar @"
SET NOCOUNT ON;
SELECT ISNULL(CAST(pi.[$col] AS VARCHAR(200)), '(null)')
FROM   dbo.PullItems pi
  INNER JOIN dbo.Pulls p ON p.Id = pi.PullId
WHERE  p.PullNumber = '$PULL' AND pi.ItemCode = '$ITEM';
"@
}

# ---------------------------------------------------------------------------
Step '1. Purge the namespace on entry'
Cleanup
$stale = SqlScalar "SET NOCOUNT ON; SELECT CONVERT(VARCHAR, COUNT(*)) FROM dbo.PullItems WHERE ItemCode = '$ITEM';"
if ($stale -ne '0') { Fail "entry purge left $stale row(s) of $ITEM behind" }
OK 'namespace clean'

# ---------------------------------------------------------------------------
Step '2. Seed the harness pull'
$seed = Harness 'ownership-seed'
if ($seed.errors -ne 0) { Fail "seed run reported errors=$($seed.errors)" }
$pullId = SqlScalar "SET NOCOUNT ON; SELECT CAST(Id AS VARCHAR(36)) FROM dbo.Pulls WHERE PullNumber = '$PULL';"
if (-not $pullId) { Fail "harness did not create pull $PULL" }
OK "pull $PULL seeded by the real upsert service"

# ---------------------------------------------------------------------------
Step '3. Create an item through add-pull-item.ps1'
# Answers, in the order the script asks for them on the create / no-open-PO
# branch. A change to the prompt sequence desyncs this list -- see the header.
#   1  Pull number
#   2  Item code
#   3  Storer / vendor code       (blank -> NULL)
#   4  Add anyway?                (fires because ITEM is on no open PO line)
#   5  Description
#   6  Vendor name                (blank)
#   7  Tag                        (blank -> 'none')
#   8  How many hour windows?
#   9  Window 1: hour
#  10  Window 1: expected qty
#  11  Apply now?
#  12  Add another?
$answers = @(
    $PULL
    $ITEM
    ''
    'y'
    'created by add-pull-item.ps1'
    ''
    ''
    '1'
    '9'
    '40'
    'y'
    'n'
) -join "`n"

$scriptOut = $answers | pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tools\add-pull-item.ps1') 2>&1
$scriptExit = $LASTEXITCODE
if ($scriptExit -ne 0) {
    Write-Host ($scriptOut | Out-String) -ForegroundColor DarkGray
    Fail "add-pull-item.ps1 exited $scriptExit (prompt sequence changed? see the header)"
}

$madeStatus = ItemField 'Status'
if (-not $madeStatus) { Fail "add-pull-item.ps1 reported success but no $ITEM row exists on $PULL" }

$madeOrigin = ItemField 'Origin'
if ($madeOrigin -ne 'operator') {
    Fail ("add-pull-item.ps1 created the item with Origin='$madeOrigin', expected 'operator'. " +
          "Its INSERT names its columns explicitly -- if Origin is not in that list the row is " +
          "unexempt and section 4 will cancel it.")
}
OK "script-created item exists on $PULL with Origin='operator'"

# ---------------------------------------------------------------------------
Step '4. ETL runs with the item absent from the draft -- it must survive'
# The harness draft carries only HARNESS-SKU-A for the two ERP storers. The
# script-made item is missing from it, which is precisely the input that
# reaches the missing-from-draft cancel path.
$run = Harness 'ownership-changed' -NoPurge
if ($run.errors -ne 0) { Fail "sync run reported errors=$($run.errors)" }

$afterStatus = ItemField 'Status'
if ($afterStatus -eq '') { Fail 'the script-made item disappeared during the sync' }
if ($afterStatus -ne 'normal') {
    Fail ("sync struck the script-made item through (Status='$afterStatus'). " +
          "add-pull-item.ps1's INSERT is not stamping Origin='operator'.")
}
$afterOrigin = ItemField 'Origin'
if ($afterOrigin -ne 'operator') { Fail "Origin after sync is '$afterOrigin', expected 'operator'" }
OK 'script-created item survived the sync as normal'

# ---------------------------------------------------------------------------
Step '5. The run reports the exemption'
# Counted, not just observed: a build that stopped running the cancel path at
# all would also leave the row alone and pass section 4 on its own.
if ($null -eq $run.itemsExemptCreated) {
    Fail 'harness output has no itemsExemptCreated - the run-level counter is unwired'
}
if ($run.itemsExemptCreated -lt 1) {
    Fail ("run reported itemsExemptCreated=$($run.itemsExemptCreated), expected at least 1. " +
          'The row surviving without being counted means the cancel path never considered it.')
}
OK "sync reported itemsExemptCreated=$($run.itemsExemptCreated)"

# ---------------------------------------------------------------------------
Cleanup
$left = SqlScalar "SET NOCOUNT ON; SELECT CONVERT(VARCHAR, COUNT(*)) FROM dbo.PullItems WHERE ItemCode = '$ITEM';"
if ($left -ne '0') { Write-Host "  WARN: exit purge left $left row(s) behind" -ForegroundColor Yellow }

Write-Host ""
Write-Host "ALL PASS ($script:pass checks) - add-pull-item.ps1 stamps Origin and its items survive ERP sync." -ForegroundColor Green
exit 0
