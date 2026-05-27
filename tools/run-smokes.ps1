# Aggregate smoke runner with reliable exit-code propagation.
#
# Previous wrappers used `& script.ps1` and inspected $LASTEXITCODE, which is
# unreliable: PowerShell's $LASTEXITCODE only reflects native commands, not
# `exit N` from a dot-sourced or call-operator script. The result was that
# scripts which Wrote "exit 1" still left $LASTEXITCODE as the value from the
# last sqlcmd they happened to run — usually 0 — so failed smokes looked green.
#
# This runner spawns each script in a CHILD PowerShell process. Child-process
# exit codes are propagated by the OS, so `exit 1` is observed as `$proc.ExitCode = 1`.
# Aggregate exit is the OR of all child exits, so CI/git-hooks can rely on it.
#
# Usage:
#   tools\run-smokes.ps1                          # default battery
#   tools\run-smokes.ps1 -Scripts foo.ps1,bar.ps1
#   tools\run-smokes.ps1 -Verbose                 # echo each script's stdout
#
# Exit codes:
#   0 — every script exited 0
#   1 — at least one script exited non-zero (or threw)

[CmdletBinding()]
param(
    # Positional list of script filenames (basename, resolved against tools/).
    # `Start-Process -ArgumentList` passes args as separate tokens, and
    # `ValueFromRemainingArguments` collects them, so `-File run-smokes.ps1 foo.ps1 bar.ps1`
    # binds $Scripts = @('foo.ps1','bar.ps1') reliably.
    # If invoked with no script args, fall back to the default battery.
    [Parameter(Position=0, ValueFromRemainingArguments=$true)]
    [string[]] $Scripts
)

if (-not $Scripts -or $Scripts.Count -eq 0) {
    $Scripts = @(
        'verify-phase-3.5.ps1'
        'smoke-phase-4a.ps1'
        'smoke-phase-4b.ps1'
        'smoke-phase-4c.ps1'
        'smoke-phase-4d.ps1'
        'smoke-phase-4e.ps1'
        'smoke-phase-5a.ps1'
        'smoke-phase-5b.ps1'
        'smoke-phase-5c.ps1'
        'smoke-phase-5d.ps1'
        'smoke-phase-5e.ps1'
        'smoke-pull-search.ps1'
        'smoke-phase-6.1.ps1'
        'smoke-phase-6.2.ps1'
        'smoke-phase-6.3.ps1'
        'smoke-confirm-modal.ps1'
        'verify-hourcap-6.1.ps1'
        'smoke-hourcap-6.2.ps1'
        'smoke-hourcap-6.3.ps1'
        'smoke-hourcap-6.4.ps1'
        'smoke-hourcap-6.5.ps1'
        'smoke-pull-detail-refresh.ps1'
        'smoke-pull-close-display.ps1'
        'smoke-pull-reference.ps1'
        'smoke-fastreport-bootstrap.ps1'
        'smoke-do-report.ps1'
        'smoke-pos-date-filter.ps1'
        'smoke-phase-8.1-pagination.ps1'
        'smoke-phase-8.2-pagination-component.ps1'
        'smoke-phase-8.3-pagination-wireup.ps1'
        'smoke-phase-8.4-exports.ps1'
        'smoke-email-test.ps1'
        'smoke-export-extensions.ps1'
        'smoke-my-exports.ps1'
        'smoke-exports-badge.ps1'
        'smoke-exports-2tab.ps1'
        'smoke-phase-9-extended-fields.ps1'
        'smoke-phase-9-1-pull-extended-fields.ps1'
        'smoke-phase-10-1-erp-connection.ps1'
        'smoke-phase-10-2-erp-read-transform.ps1'
        'smoke-phase-10-3-erp-upsert.ps1'
        'smoke-phase-10-4-erp-trigger.ps1'
        'smoke-phase-10-5-erp-audit.ps1'
        'smoke-phase-10-6-erp-sync-page.ps1'
        'smoke-phase-10-7-integration.ps1'
        'smoke-phase-11-1-app-settings.ps1'
        'smoke-phase-11-2-config-ui.ps1'
        'smoke-phase-12-2-po-import-reader.ps1'
        'smoke-phase-12-3-po-import-log-repo.ps1'
        'smoke-phase-12-4-po-import-service.ps1'
        'smoke-phase-12-5-po-import-job.ps1'
        'smoke-receive.ps1'
        'smoke-stage-b.ps1'
        'smoke-transactions.ps1'
        'smoke-close-reopen.ps1'
    )
}

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Prefer PowerShell 7 (pwsh.exe) — it defaults to UTF-8 for .ps1 source. Windows
# PowerShell 5.1 (powershell.exe) reads .ps1 files as the system codepage, which
# mangles em-dashes / Thai text in our smoke scripts and triggers parser errors.
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
if (-not $pwsh) { Write-Error "Neither pwsh.exe nor powershell.exe found on PATH."; exit 2 }

$results = New-Object System.Collections.Generic.List[hashtable]

foreach ($scriptName in $Scripts) {
    $scriptPath = Join-Path $toolsDir $scriptName
    if (-not (Test-Path $scriptPath)) {
        $results.Add(@{ name=$scriptName; status='MISSING'; exitCode=-1; output='' })
        continue
    }

    # Spawn a child PowerShell process. -NoProfile keeps startup deterministic;
    # -File makes `exit N` propagate as the process exit code. stdout+stderr are
    # captured to a tmp file so we can show context on failure.
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $pwsh `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath `
            -PassThru -Wait `
            -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -NoNewWindow
        $exit = $proc.ExitCode
        # Merge stdout + stderr in the order they were written; both are useful diagnostics.
        $output = (Get-Content -Raw -LiteralPath $tmpOut) + (Get-Content -Raw -LiteralPath $tmpErr)
    }
    finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -ErrorAction SilentlyContinue
    }

    $status = if ($exit -eq 0) { 'PASS' } else { 'FAIL' }
    $results.Add(@{ name=$scriptName; status=$status; exitCode=$exit; output=$output })

    $color = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $status, $scriptName) -ForegroundColor $color
    if ($VerbosePreference -eq 'Continue' -or $status -ne 'PASS') {
        # Always echo output on failure so the diagnostic isn't a black box.
        $output -split "`r?`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

# Wrap in @() so a single-match Where-Object returns a 1-element array, not the
# bare hashtable (whose .Count would be the keyCount, not 1).
$passCount = @($results | Where-Object { $_.status -eq 'PASS' }).Count
$failCount = @($results | Where-Object { $_.status -ne 'PASS' }).Count

Write-Host ""
Write-Host ("Summary: {0} pass / {1} fail / {2} total" -f $passCount, $failCount, $results.Count)
if ($failCount -gt 0) {
    Write-Host "  Failures:" -ForegroundColor Red
    $results | Where-Object { $_.status -ne 'PASS' } | ForEach-Object {
        Write-Host ("    - {0} (exit {1})" -f $_.name, $_.exitCode) -ForegroundColor Red
    }
    exit 1
}
exit 0
