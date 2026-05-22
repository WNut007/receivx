# Self-test for run-smokes.ps1.
#
# Verifies the runner correctly propagates exit codes from:
#   case A — a script that exits 0 (PASS path)
#   case B — a script that exits 1 (FAIL path)
#   case C — a mixed batch (FAIL path; at least one failure pulls the whole batch down)
#
# Each case spawns run-smokes.ps1 in a child process and inspects $ExitCode.

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner = Join-Path $toolsDir 'run-smokes.ps1'

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
if (-not $pwsh) { Write-Error "Neither pwsh.exe nor powershell.exe found on PATH."; exit 2 }

function InvokeRunner([string[]] $scripts) {
    # Spawn the runner in a child process so we get a real ExitCode. Each script
    # name is passed as a separate positional arg; the runner binds them via
    # ValueFromRemainingArguments.
    $runnerArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner) + $scripts
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $pwsh -ArgumentList $runnerArgs `
            -PassThru -Wait -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -NoNewWindow
        $merged = (Get-Content -Raw -LiteralPath $tmpOut) + (Get-Content -Raw -LiteralPath $tmpErr)
        return @{ exit=$proc.ExitCode; out=$merged }
    } finally { Remove-Item -LiteralPath $tmpOut, $tmpErr -ErrorAction SilentlyContinue }
}

function Expect([string] $label, [int] $wantExit, [hashtable] $got) {
    if ($got.exit -eq $wantExit) {
        Write-Host "PASS: $label (exit=$($got.exit))" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $label (wanted exit=$wantExit, got exit=$($got.exit))" -ForegroundColor Red
        Write-Host "--- runner output ---" -ForegroundColor DarkGray
        Write-Host $got.out -ForegroundColor DarkGray
        exit 1
    }
}

Write-Host "Case A: passing-only batch should exit 0" -ForegroundColor Cyan
$a = InvokeRunner @('_fixture-pass.ps1')
Expect "passing-only → 0" 0 $a

Write-Host ""
Write-Host "Case B: failing-only batch should exit 1" -ForegroundColor Cyan
$b = InvokeRunner @('_fixture-fail.ps1')
Expect "failing-only → 1" 1 $b

Write-Host ""
Write-Host "Case C: mixed batch (1 pass + 1 fail) should exit 1" -ForegroundColor Cyan
$c = InvokeRunner @('_fixture-pass.ps1','_fixture-fail.ps1')
Expect "mixed → 1" 1 $c
# Sanity: failure summary should name the failing script
if ($c.out -notmatch '_fixture-fail.ps1') {
    Write-Host "FAIL: mixed batch output did not mention the failing script" -ForegroundColor Red
    Write-Host $c.out -ForegroundColor DarkGray
    exit 1
}
Write-Host "PASS: mixed batch output names the failing script" -ForegroundColor Green
# Regression guard: summary line counts must reflect script count, not key-count
# of a single match (a previous bug had failCount=4 when there was 1 failed script).
if ($c.out -notmatch 'Summary: 1 pass / 1 fail / 2 total') {
    Write-Host "FAIL: mixed batch summary counts wrong. Output:" -ForegroundColor Red
    Write-Host $c.out -ForegroundColor DarkGray
    exit 1
}
Write-Host "PASS: mixed batch summary counts correct"

Write-Host ""
Write-Host "Case D: pass-after-fail batch — runner keeps going, still exits 1" -ForegroundColor Cyan
$d = InvokeRunner @('_fixture-fail.ps1','_fixture-pass.ps1')
Expect "fail-then-pass → 1" 1 $d
if ($d.out -notmatch '\[PASS\] _fixture-pass.ps1') {
    Write-Host "FAIL: runner stopped after failure (expected to continue)" -ForegroundColor Red
    Write-Host $d.out -ForegroundColor DarkGray
    exit 1
}
Write-Host "PASS: runner continued after fail, second script still ran"

Write-Host ""
Write-Host "All runner self-tests passed — exit-code propagation is correct." -ForegroundColor Green
