<#
.SYNOPSIS
    Interactive PullItem creator — ad-hoc tool for v2.0 (UI deferred to v2.1).

.DESCRIPTION
    v2 treats pulls as upstream artifacts (analogous to an ERP-sourced ASN);
    no in-app surface authors PullItem rows. The seed file db/006 is the
    only normal path. For exception cases (vendor over-ship, ad-hoc adds,
    demo fixtures) this tool wraps the INSERT pattern in a transaction with
    validation + idempotency + audit, so ops doesn't have to hand-write SQL.

    The pull-item admin UI is queued for v2.1 (see CLAUDE.md backlog).

    Behaviour:
      1. Validates the pull exists and isn't closed/fully_received (§7.4
         immutability after close).
      2. Looks up the ItemCode in open PurchaseOrderLines:
           - hit  -> uses the PO line's Description as the default
                     (override allowed at the prompt).
           - miss -> warns ("receives will 409 No PO capacity") and asks
                     to add anyway.
      3. Idempotency: if (PullId, ItemCode) already exists, shows the
         existing windows and offers a "replace windows" path. Refused
         when any existing window has ReceivedQty > 0 (would discard
         receive history); user must use raw SQL for that edge case.
      4. Wraps INSERT(s) in a transaction with XACT_ABORT ON — any
         failure rolls back and offers retry.
      5. Writes an AuditLog row with ActorName = '[script: <SQL_LOGIN>]'
         so these mutations stand out from real user actions.

    Schema this tool relies on (db/001 + db/010 + db/015):
      - dbo.Pulls(Id, PullNumber, Status)
      - dbo.PullItems(Id, PullId, ItemCode, Description, VendorCode,
                      VendorName, Tag NULL|'pcba'|'swap',
                      Status DEFAULT 'normal', SortOrder)
      - dbo.PullItemWindows(PullItemId, HourOfDay 0..23, ExpectedQty,
                            ReceivedQty)  — UQ_PIW_Hour on (PullItemId,HourOfDay)
      - dbo.PurchaseOrderLines(ItemCode, Description, ...) for the lookup
      - dbo.AuditLog(ActionType, EntityType, EntityId, Message,
                     ActorUserId NULL, ActorName)

.PARAMETER Server
    SQL Server instance. Defaults to the local dev box LAPTOP-CSB3KO3E.

.PARAMETER Database
    Database name. Defaults to ReceivingOps.

.EXAMPLE
    pwsh -File tools\add-pull-item.ps1
    pwsh -File tools\add-pull-item.ps1 -Server PRODSQL01 -Database ReceivingOps
#>

[CmdletBinding()]
param(
    [string]$Server   = 'LAPTOP-CSB3KO3E',
    [string]$Database = 'ReceivingOps'
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Console helpers
# -----------------------------------------------------------------------------
function Title([string]$s) { Write-Host ("`n=== {0} ===" -f $s) -ForegroundColor Cyan }
function Info([string]$s)  { Write-Host $s -ForegroundColor DarkGray }
function Warn([string]$s)  { Write-Host ("WARN: {0}"  -f $s) -ForegroundColor Yellow }
function Err([string]$s)   { Write-Host ("ERROR: {0}" -f $s) -ForegroundColor Red }
function Ok([string]$s)    { Write-Host ("OK: {0}"    -f $s) -ForegroundColor Green }

# -----------------------------------------------------------------------------
# SQL helpers — use sqlcmd because the tool is intentionally dependency-free
# (no Microsoft.Data.SqlClient or SqlServer module required).
# -----------------------------------------------------------------------------
function SqlScalar([string]$query) {
    # Returns the first non-empty line of the result, or $null. -h -1 strips
    # the header underline; -W trims trailing whitespace; -m 11 hushes
    # informational messages (severity < 11).
    $out = sqlcmd -S $Server -E -C -d $Database -h -1 -W -m 11 -Q ("SET NOCOUNT ON; " + $query) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("sqlcmd failed (exit {0}):`n{1}" -f $LASTEXITCODE, ($out -join "`n"))
    }
    foreach ($line in $out) {
        $t = ([string]$line).Trim()
        if ($t) { if ($t -eq 'NULL') { return $null } else { return $t } }
    }
    return $null
}

function SqlExec([string]$tsql) {
    # Bubble up sqlcmd's exit code; the caller decides whether to retry.
    $out = sqlcmd -S $Server -E -C -d $Database -I -h -1 -W -b -Q $tsql 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $out
    }
}

function SqlEscape([string]$s) {
    # T-SQL single-quote escape. We never construct identifiers from input,
    # so this is the only safety net we need.
    if ($null -eq $s) { return '' }
    return ($s -replace "'", "''")
}

# -----------------------------------------------------------------------------
# Prompt helpers
# -----------------------------------------------------------------------------
function Prompt([string]$label, [string]$default = '', [switch]$Required) {
    while ($true) {
        $suffix = if ($default) { " [$default]" } else { '' }
        $val = Read-Host ("$label$suffix")
        if ([string]::IsNullOrWhiteSpace($val)) { $val = $default }
        if ($Required -and [string]::IsNullOrWhiteSpace($val)) {
            Warn 'Value required.'
            continue
        }
        return $val
    }
}

function PromptInt([string]$label, [int]$min, [int]$max, [switch]$Required) {
    while ($true) {
        $raw = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($Required) { Warn 'Value required.'; continue }
            return $null
        }
        $n = 0
        if (-not [int]::TryParse($raw, [ref]$n)) { Warn 'Not an integer.'; continue }
        if ($n -lt $min -or $n -gt $max) { Warn "Must be between $min and $max."; continue }
        return $n
    }
}

function ConfirmYN([string]$label, [string]$default = 'N') {
    $suffix = if ($default.ToUpper() -eq 'Y') { '[Y/n]' } else { '[y/N]' }
    $val = (Read-Host "$label $suffix").Trim().ToUpper()
    if (-not $val) { $val = $default.ToUpper() }
    return ($val -eq 'Y')
}

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------
Title 'Add PullItem — v2.0 ad-hoc tool (UI deferred to v2.1)'
Info "Server: $Server / Database: $Database"
Info 'Press Ctrl+C at any prompt to abort.'

while ($true) {
    # ---------------------------- Pull lookup ----------------------------
    $pullNumber = Prompt 'Pull number (e.g. PL-2847)' -Required
    $pullInfo = SqlScalar @"
SELECT CONVERT(NVARCHAR(36), Id) + '|' + Status
FROM   dbo.Pulls
WHERE  PullNumber = '$(SqlEscape $pullNumber)';
"@
    if (-not $pullInfo) {
        Err "Pull '$pullNumber' not found."
        if (ConfirmYN 'Try again?') { continue } else { exit 1 }
    }
    $parts      = $pullInfo -split '\|'
    $pullId     = $parts[0]
    $pullStatus = $parts[1]
    if ($pullStatus -in @('closed', 'fully_received')) {
        Err "Pull is '$pullStatus' — cannot add items to a non-open pull (§7.4)."
        if (ConfirmYN 'Try a different pull?') { continue } else { exit 1 }
    }
    Ok ("Pull {0} found (status={1}, id={2}…)" -f $pullNumber, $pullStatus, $pullId.Substring(0,8))

    # ---------------------------- ItemCode + idempotency check ----------------------------
    $itemCode = Prompt 'Item code' -Required

    $existingPi = SqlScalar @"
SELECT CONVERT(NVARCHAR(36), Id)
FROM   dbo.PullItems
WHERE  PullId   = '$pullId'
  AND  ItemCode = '$(SqlEscape $itemCode)';
"@

    $mode        = $null   # 'create' | 'replace-windows'
    $pullItemId  = $null
    $description = ''
    $vendorCode  = ''
    $vendorName  = ''
    $tag         = 'none'

    if ($existingPi) {
        $pullItemId = $existingPi
        Title 'Item already exists on this pull — review existing state'
        $existingWindows = sqlcmd -S $Server -E -C -d $Database -h -1 -W -m 11 -Q @"
SET NOCOUNT ON;
SELECT FORMATMESSAGE('  hour %02d:00  expected=%d  received=%d', HourOfDay, ExpectedQty, ReceivedQty)
FROM   dbo.PullItemWindows
WHERE  PullItemId = '$pullItemId'
ORDER BY HourOfDay;
"@ 2>&1
        $existingWindows | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }

        $hasReceipts = SqlScalar @"
SELECT TOP 1 1
FROM   dbo.PullItemWindows
WHERE  PullItemId = '$pullItemId' AND ReceivedQty > 0;
"@
        if ($hasReceipts -eq '1') {
            Err 'At least one window has ReceivedQty > 0 — cannot replace windows on this item.'
            Info 'Edit windows via raw SQL if you absolutely must (see docs/runbooks/add-pull-items.md).'
            if (ConfirmYN 'Try a different item?') { continue } else { exit 1 }
        }

        if (-not (ConfirmYN 'Replace all windows on this existing item?')) {
            if (ConfirmYN 'Try a different item?') { continue } else { exit 1 }
        }
        $mode = 'replace-windows'

    } else {
        $mode       = 'create'
        $pullItemId = [Guid]::NewGuid().ToString()

        # Warn (don't block) if the ItemCode isn't on an open PO line.
        # Pulled also serves as the source of the Description default.
        $poDescriptionHit = SqlScalar @"
SELECT TOP 1 pol.Description
FROM   dbo.PurchaseOrderLines pol
INNER JOIN dbo.PurchaseOrders po ON po.Id = pol.PurchaseOrderId
WHERE  pol.ItemCode = '$(SqlEscape $itemCode)' AND po.Status = 'open'
ORDER BY po.OrderDate DESC;
"@
        if (-not $poDescriptionHit) {
            Warn "ItemCode '$itemCode' is not on any open PO line — receives will 409 'No PO capacity' until a PO line covers it."
            if (-not (ConfirmYN 'Add anyway?')) {
                if (ConfirmYN 'Try a different item?') { continue } else { exit 1 }
            }
            $descDefault = ''
        } else {
            Ok "ItemCode found on open PO — defaulting Description to '$poDescriptionHit' (override allowed)."
            $descDefault = $poDescriptionHit
        }

        $description = Prompt 'Description' $descDefault -Required
        $vendorCode  = Prompt 'Vendor code (optional)' ''
        $vendorName  = Prompt 'Vendor name (optional)' ''

        while ($true) {
            $tag = (Prompt 'Tag (pcba|swap|none)' 'none').ToLower()
            if ($tag -in @('pcba','swap','none')) { break }
            Warn 'Tag must be one of: pcba, swap, none.'
        }
    }

    # ---------------------------- Per-hour windows ----------------------------
    Title 'Hour windows (HourOfDay 0..23, no duplicates)'
    $count = PromptInt 'How many hour windows?' 1 24 -Required
    $windows = @()
    for ($i = 1; $i -le $count; $i++) {
        $hourUsed = $windows | ForEach-Object { $_.HourOfDay }
        while ($true) {
            $h = PromptInt ("  Window {0}: hour (0-23)" -f $i) 0 23 -Required
            if ($hourUsed -contains $h) {
                Warn "Hour $h already used in this batch — pick another."
                continue
            }
            $q = PromptInt ("  Window {0}: expected qty (>0)" -f $i) 1 1000000 -Required
            $windows += [pscustomobject]@{ HourOfDay = $h; ExpectedQty = $q }
            break
        }
    }

    # ---------------------------- Summary + confirm ----------------------------
    Title 'Summary'
    Write-Host ("  Mode:        {0}" -f $mode)
    Write-Host ("  Pull:        {0}  (id={1}…)" -f $pullNumber, $pullId.Substring(0,8))
    Write-Host ("  ItemCode:    {0}" -f $itemCode)
    if ($mode -eq 'create') {
        Write-Host ("  Description: {0}" -f $description)
        Write-Host ("  Vendor:      {0} / {1}" -f $vendorCode, $vendorName)
        Write-Host ("  Tag:         {0}" -f $tag)
    } else {
        Write-Host ("  PullItemId:  {0}…  (existing)" -f $pullItemId.Substring(0,8))
    }
    Write-Host '  Windows:'
    foreach ($w in ($windows | Sort-Object HourOfDay)) {
        Write-Host ("    hour {0:D2}:00  qty={1}" -f $w.HourOfDay, $w.ExpectedQty)
    }

    if (-not (ConfirmYN 'Apply now?' 'Y')) {
        if (ConfirmYN 'Start over?') { continue } else { exit 1 }
    }

    # ---------------------------- Apply (transactional) ----------------------------
    $sortOrder = $null
    if ($mode -eq 'create') {
        $sortOrder = SqlScalar @"
SELECT ISNULL(MAX(SortOrder), 0) + 1
FROM   dbo.PullItems
WHERE  PullId = '$pullId';
"@
    }

    $tagSql        = if ($mode -eq 'create' -and $tag -ne 'none') { "'$(SqlEscape $tag)'" } else { 'NULL' }
    $vendorCodeSql = if ($mode -eq 'create' -and $vendorCode)     { "'$(SqlEscape $vendorCode)'" } else { 'NULL' }
    $vendorNameSql = if ($mode -eq 'create' -and $vendorName)     { "N'$(SqlEscape $vendorName)'" } else { 'NULL' }

    $windowsListForAudit = (
        ($windows | Sort-Object HourOfDay | ForEach-Object {
            '{0:D2}h:{1}' -f $_.HourOfDay, $_.ExpectedQty
        }) -join ', '
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('SET QUOTED_IDENTIFIER ON;')
    [void]$sb.AppendLine('SET NOCOUNT ON;')
    [void]$sb.AppendLine('SET XACT_ABORT ON;')
    [void]$sb.AppendLine('BEGIN TRAN;')

    if ($mode -eq 'create') {
        [void]$sb.AppendLine(@"
INSERT INTO dbo.PullItems
       (Id, PullId, ItemCode, Description, VendorCode, VendorName, Tag, Status, SortOrder)
VALUES ('$pullItemId',
        '$pullId',
        '$(SqlEscape $itemCode)',
        N'$(SqlEscape $description)',
        $vendorCodeSql, $vendorNameSql, $tagSql, 'normal', $sortOrder);
"@)
    } else {
        [void]$sb.AppendLine("DELETE FROM dbo.PullItemWindows WHERE PullItemId = '$pullItemId';")
    }

    foreach ($w in $windows) {
        [void]$sb.AppendLine(
            "INSERT INTO dbo.PullItemWindows (PullItemId, HourOfDay, ExpectedQty) VALUES ('$pullItemId', $($w.HourOfDay), $($w.ExpectedQty));"
        )
    }

    $auditAction  = if ($mode -eq 'create') { 'create' } else { 'update' }
    $auditMessage = if ($mode -eq 'create') {
        "Added item $(SqlEscape $itemCode) to $pullNumber via add-pull-item.ps1 (windows: $windowsListForAudit)"
    } else {
        "Replaced windows for $(SqlEscape $itemCode) in $pullNumber via add-pull-item.ps1 (now: $windowsListForAudit)"
    }
    [void]$sb.AppendLine(@"
INSERT INTO dbo.AuditLog
       (ActionType, EntityType, EntityId, Message, ActorUserId, ActorName)
VALUES ('$auditAction',
        'PullItem',
        '$pullItemId',
        N'$auditMessage',
        NULL,
        N'[script: ' + SUSER_SNAME() + ']');
"@)
    [void]$sb.AppendLine('COMMIT TRAN;')

    Info 'Executing transaction…'
    $result = SqlExec $sb.ToString()
    if ($result.ExitCode -ne 0) {
        Err 'Transaction failed — rolled back:'
        $result.Output | ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor Red }
        if (ConfirmYN 'Retry?') { continue } else { exit 1 }
    }
    Ok ("Committed PullItem {0}…  ({1} window(s))" -f $pullItemId.Substring(0,8), $windows.Count)
    Info 'Audit row written; OccurredAt = now (UTC).'

    if (-not (ConfirmYN 'Add another?')) { break }
}

Write-Host "`nDone." -ForegroundColor Green
exit 0
