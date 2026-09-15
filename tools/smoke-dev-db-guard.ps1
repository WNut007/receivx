# Smoke: a Development run refuses to start against a non-local database.
#
# The hazard: this machine carries a User-level ConnectionStrings__Default
# pointing at a remote host (required by a different application, so it stays).
# Environment variables outrank user-secrets in this project's precedence chain,
# so a plain `dotnet run` silently drove that remote database. Config alone
# cannot close this - the variable is legitimately there - so the pin is applied
# in launchSettings (F5 / profile runs) and in tools/run-smokes.ps1 (scripted
# runs), and DevDatabaseGuard is the backstop for the case both of those miss.
#
# Cases:
#   1. Guard source exists and is invoked before any service registration
#   2. launchSettings pins a LOCAL, PASSWORDLESS value in every Dev profile
#   3. run-smokes.ps1 pins the same value, process-scoped
#   4. THE BEHAVIOURAL CASE - a fake remote ConnectionStrings__Default in the
#      process env, with NO launch profile, must fail fast with the guard
#      message and a non-zero exit
#   5. The same invocation with the LOCAL value gets past the guard
#
# Touches no database and seeds no fixture: cases 4 and 5 start the app in a
# child process that is killed as soon as it has answered.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$proj     = Join-Path $repoRoot 'src/ReceivingOps.Web'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

$LOCAL_CS = 'Server=LAPTOP-CSB3KO3E;Database=ReceivingOps;Trusted_Connection=True;TrustServerCertificate=True;Encrypt=False;Application Name=ReceivingOps;'
$FAKE_CS  = 'Server=203.0.113.7;Database=SOMEONE_ELSES_DB;User Id=nobody;Password=not-a-real-password;TrustServerCertificate=True;'

# ---------------------------------------------------------------------------
Step "1. DevDatabaseGuard exists and runs before any service registration"
$guardPath = Join-Path $proj 'Data/DevDatabaseGuard.cs'
if (-not (Test-Path $guardPath)) { Fail "Data/DevDatabaseGuard.cs missing" }
$guard = Get-Content $guardPath -Raw
if ($guard -notmatch 'ExpectedDatabase\s*=\s*"ReceivingOps"') { Fail "guard does not pin the ReceivingOps database" }
if ($guard -notmatch 'Environment\.MachineName')              { Fail "guard does not accept this machine as local" }
if ($guard -notmatch 'root\.Providers')                       { Fail "guard does not identify the supplying provider" }
# The raw connection string may carry a password and must never be echoed.
if ($guard -match 'WriteLine\([^)]*connectionString') { Fail "guard echoes the raw connection string" }

$programPath = Join-Path $proj 'Program.cs'
$program = Get-Content $programPath -Raw
if ($program -notmatch 'DevDatabaseGuard\.Verify') { Fail "Program.cs never calls DevDatabaseGuard.Verify" }
if ($program -notmatch 'IsDevelopment\(\)\s*\)?\s*[\r\n ]*\s*DevDatabaseGuard\.Verify') {
    Fail "DevDatabaseGuard.Verify is not gated on IsDevelopment()"
}
# Must precede the first thing that could open a connection. AddHangfire reads
# ConnectionStrings:Default directly, so it is the deadline.
$guardIdx    = $program.IndexOf('DevDatabaseGuard.Verify')
$hangfireIdx = $program.IndexOf('AddHangfire')
$servicesIdx = $program.IndexOf('builder.Services.')
if ($hangfireIdx -ge 0 -and $guardIdx -gt $hangfireIdx) { Fail "guard runs AFTER Hangfire reads the connection string" }
if ($servicesIdx -ge 0 -and $guardIdx -gt $servicesIdx) { Fail "guard runs after service registration begins" }
OK "guard present, Development-gated, and ahead of every service registration"

# ---------------------------------------------------------------------------
Step "2. launchSettings pins a local, passwordless value in every Dev profile"
$lsPath = Join-Path $proj 'Properties/launchSettings.json'
$lsRaw  = Get-Content $lsPath -Raw
$ls     = $lsRaw | ConvertFrom-Json
$devProfiles = @()
foreach ($name in $ls.profiles.PSObject.Properties.Name) {
    $p = $ls.profiles.$name
    if ($p.environmentVariables.ASPNETCORE_ENVIRONMENT -eq 'Development') { $devProfiles += $name }
}
if ($devProfiles.Count -lt 1) { Fail "no Development profile found in launchSettings.json" }
foreach ($name in $devProfiles) {
    $cs = $ls.profiles.$name.environmentVariables.ConnectionStrings__Default
    if (-not $cs) { Fail "profile '$name' does not pin ConnectionStrings__Default" }
    if ($cs -notmatch 'Database=ReceivingOps')  { Fail "profile '$name' does not name the ReceivingOps database" }
    if ($cs -notmatch 'Server=LAPTOP-CSB3KO3E') { Fail "profile '$name' does not name the local server" }
    # A tracked file must never carry a credential.
    if ($cs -match 'Password\s*=' -or $cs -match 'User\s*Id\s*=') { Fail "profile '$name' carries a credential" }
    if ($cs -notmatch 'Trusted_Connection=True|Integrated Security=True') {
        Fail "profile '$name' does not use integrated auth"
    }
}
# The file is tracked, so a secret here would be committed.
& git -C $repoRoot ls-files --error-unmatch 'src/ReceivingOps.Web/Properties/launchSettings.json' *> $null
if ($LASTEXITCODE -ne 0) { Fail "launchSettings.json is NOT tracked in git - the pin would not reach anyone else" }
if ($lsRaw -match 'Password\s*=') { Fail "launchSettings.json contains a password" }
OK "$($devProfiles.Count) Dev profile(s) pinned to the local DB, integrated auth, no secret, tracked in git"

# ---------------------------------------------------------------------------
Step "3. run-smokes.ps1 pins the same value, process-scoped"
$runner = Get-Content (Join-Path $PSScriptRoot 'run-smokes.ps1') -Raw
if ($runner -notmatch '\$env:ConnectionStrings__Default\s*=') { Fail "run-smokes.ps1 does not pin ConnectionStrings__Default" }
if ($runner -notmatch 'Database=ReceivingOps')                { Fail "run-smokes.ps1 pin does not name the ReceivingOps database" }
if ($runner -notmatch 'Server=LAPTOP-CSB3KO3E')               { Fail "run-smokes.ps1 pin does not name the local server" }
if ($runner -match 'Password\s*=')                            { Fail "run-smokes.ps1 pin carries a password" }
# Must be set before the first child process is spawned, or the children that
# matter inherit the machine value. Match the INVOCATION, not the word: the
# param block's own comment mentions Start-Process ~150 lines earlier, and a
# bare IndexOf finds that instead and reports a false failure.
$pinIdx   = $runner.IndexOf('$env:ConnectionStrings__Default')
$spawn    = [regex]::Match($runner, '(?m)^\s*(\$\w+\s*=\s*)?Start-Process\b')
if (-not $spawn.Success) { Fail "run-smokes.ps1 no longer spawns children via Start-Process - re-check this assertion" }
if ($pinIdx -gt $spawn.Index) { Fail "run-smokes.ps1 pins the value AFTER spawning children" }
# Machine/User scope must not be touched - the variable belongs to another app.
if ($runner -match 'SetEnvironmentVariable\([^)]*(Machine|User)') { Fail "run-smokes.ps1 writes a persistent environment variable" }
OK "runner pins the local DB before spawning, process-scoped only"

# ---------------------------------------------------------------------------
# 4. The behavioural case. --no-launch-profile means launchSettings cannot
#    rescue the run, so the only thing between the app and the wrong database
#    is the guard.
# ---------------------------------------------------------------------------
Step "4. fake remote ConnectionStrings__Default + no launch profile -> fails fast"

function RunApp([string]$connectionString, [int]$timeoutSeconds) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = 'dotnet'
    # A port nothing else uses: cases that get PAST the guard must not collide
    # with a dev server the operator already has running on 5213.
    $psi.Arguments = "run --project `"$proj`" --no-launch-profile --no-build"
    $psi.WorkingDirectory = $repoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.EnvironmentVariables['ConnectionStrings__Default'] = $connectionString
    $psi.EnvironmentVariables['ASPNETCORE_ENVIRONMENT']     = 'Development'
    $psi.EnvironmentVariables['ASPNETCORE_URLS']            = 'http://127.0.0.1:5399'

    $proc = [System.Diagnostics.Process]::Start($psi)
    # Read both streams asynchronously: a full pipe buffer would deadlock a
    # process we are also waiting on.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $exited  = $proc.WaitForExit($timeoutSeconds * 1000)
    if (-not $exited) {
        try { $proc.Kill($true) } catch { }
        $proc.WaitForExit(10000) | Out-Null
    }
    return [pscustomobject]@{
        Exited   = $exited
        ExitCode = $(if ($exited) { $proc.ExitCode } else { $null })
        Output   = ($outTask.Result + "`n" + $errTask.Result)
    }
}

$bad = RunApp $FAKE_CS 90
if (-not $bad.Exited) { Fail "app did NOT exit with a remote connection string - the guard never fired" }
if ($bad.ExitCode -eq 0) { Fail "app exited 0 with a remote connection string - the guard never fired" }
if ($bad.Output -notmatch 'Refusing to start') {
    # Exiting non-zero is NOT enough: without the guard the app still dies, just
    # later and on a SQL connection timeout instead. Distinguish "refused for the
    # right reason" from "failed for some reason", and say so when the child
    # produced nothing at all.
    $seen = $bad.Output.Trim()
    $seen = if ($seen) { $seen.Substring(0, [Math]::Min(600, $seen.Length)) } else { '(no output)' }
    Fail "exited $($bad.ExitCode) but without the guard message - it failed for some other reason. Got: $seen"
}
if ($bad.Output -notmatch 'SOMEONE_ELSES_DB') { Fail "guard message does not name the offending database" }
if ($bad.Output -notmatch '203\.0\.113\.7')   { Fail "guard message does not name the offending server" }
if ($bad.Output -notmatch 'Supplied by:')     { Fail "guard message does not name the supplying provider" }
if ($bad.Output -notmatch 'EnvironmentVariables') {
    Fail "guard did not identify the environment as the source"
}
# The refusal must not leak the credential that came with the bad string.
if ($bad.Output -match 'not-a-real-password') { Fail "guard leaked the password from the connection string" }
OK "refused with exit $($bad.ExitCode), named server + database + EnvironmentVariables provider, no password leaked"

# ---------------------------------------------------------------------------
# 5. The guard must not be a blanket refusal: the local value gets through it.
#    Asserted on the ABSENCE of the guard message, not on a successful boot -
#    this smoke must not depend on SQL Server being reachable.
# ---------------------------------------------------------------------------
Step "5. the local value passes the guard"
$good = RunApp $LOCAL_CS 40
if ($good.Output -match 'Refusing to start') {
    Fail "guard rejected the LOCAL connection string: $($good.Output.Substring(0, [Math]::Min(600, $good.Output.Length)))"
}
OK "local connection string is not refused"

Write-Host "`nALL PASS - Development runs are pinned to the local database." -ForegroundColor Green
exit 0
