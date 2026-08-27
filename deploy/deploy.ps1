<#
================================================================================
 deploy.ps1  —  ReceivingOps production deploy (self-contained)
================================================================================
 WHAT IT DOES (in order)
   1. publish            dotnet publish -c Release  ->  a staging folder
   2. inject env vars    rebuild web.config <environmentVariables> from the
                         ACL-locked deploy-secrets.json  (ALL FOUR vars, always)
   3. backup             snapshot the live app folder (timestamped)
   4. stop pool          stop the IIS app pool so DLLs unlock
   5. robocopy           mirror staging -> live, EXCEPT web.config is copied
                         from the injected staging copy (never the raw publish)
   6. start pool         start the app pool
   7. health check       hit the site over loopback; expect a healthy status
   8. auto-rollback      if health fails, restore the backup and restart

 WHY THE ENV-VAR STEP EXISTS
   `dotnet publish` regenerates web.config every time, wiping any hand-added
   env vars. The app needs FOUR of them under
   <location><system.webServer><aspNetCore><environmentVariables>:
       ConnectionStrings__Default     app DB
       ASPNETCORE_ENVIRONMENT         "Production"
       DataProtection__KeyDirectory   persisted key ring (or old secrets can't
                                      decrypt -> CryptographicException -> the
                                      ConfigController dies at DI -> phantom 405s)
       ErpDb__ConnectionString        ERP source DB (ErpSqlConnectionFactory
                                      reads this from IConfiguration, NOT the
                                      DB-backed AppSettings)
   Miss any of these and the app breaks in exactly the ways we debugged.
   This script re-injects all four on EVERY deploy, so they can never drift.

 SECRETS
   The two credential-bearing values come from deploy-secrets.json (written by
   set-secret.ps1, ACL-locked). Nothing secret is hardcoded in this script, so
   it is safe to commit to source control.

 USAGE
   # normal deploy (uses all defaults)
   .\deploy.ps1

   # dry run — publish + inject to staging, show what WOULD change, copy nothing
   .\deploy.ps1 -WhatIfCopy

   # override any path if the layout ever changes
   .\deploy.ps1 -RepoRoot 'D:\src\receivx' -LiveDir 'C:\Programs\ReceivingOps'
================================================================================
#>

[CmdletBinding()]
param(
    # --- Source / build ---
    [string] $RepoRoot   = 'C:\dev\receivx',
    [string] $ProjectDir = 'src\ReceivingOps.Web',
    [string] $Configuration = 'Release',

    # --- Targets ---
    [string] $LiveDir    = 'C:\Programs\ReceivingOps',
    [string] $StagingDir = 'C:\Programs\ReceivingOps-staging',
    [string] $BackupRoot = 'C:\Programs',
    [string] $SecretsPath = 'C:\Programs\ReceivingOps-config\deploy-secrets.json',

    # --- IIS ---
    [string] $AppPoolName = 'receivingops.webgeplus.com',
    [string] $SiteHost    = 'receivingops.webgeplus.com',
    [string] $LoopbackIp  = '127.0.0.1',

    # --- Non-secret env values (safe defaults; override only if they change) ---
    [string] $AspNetCoreEnvironment      = 'Production',
    [string] $DataProtectionKeyDirectory = 'C:\ProgramData\ReceivingOps\keys',

    # --- Behavior ---
    [int]    $HealthTimeoutSec = 30,
    [int]    $BackupsToKeep    = 5,
    [switch] $WhatIfCopy       # publish + inject to staging, but do not touch live
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module WebAdministration -ErrorAction Stop

$ProjectPath = Join-Path $RepoRoot $ProjectDir
$LiveWebConfig    = Join-Path $LiveDir    'web.config'
$StagingWebConfig = Join-Path $StagingDir 'web.config'

function Write-Step { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg"   -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [!!] $Msg"   -ForegroundColor Yellow }

# ============================================================================
#  ENV-VAR INJECTION  (rebuilds <environmentVariables> from deploy-secrets.json)
#  This is the whole point of the script — all four vars, every deploy.
# ============================================================================
function Set-WebConfigEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WebConfigPath,
        [Parameter(Mandatory)] [string] $SecretsPath,
        [string] $AspNetCoreEnvironment      = 'Production',
        [string] $DataProtectionKeyDirectory = 'C:\ProgramData\ReceivingOps\keys'
    )

    if (-not (Test-Path $WebConfigPath)) {
        throw "web.config not found at '$WebConfigPath' — did publish run first?"
    }
    if (-not (Test-Path $SecretsPath)) {
        throw "Secrets file not found at '$SecretsPath' — run set-secret.ps1 once to create it."
    }

    # deploy-secrets.json expected shape:
    # {
    #   "ConnectionStrings__Default": "Server=...;Database=ReceivingOps;...",
    #   "ErpDb__ConnectionString":    "Server=...;Database=CW;..."
    # }
    $secrets = Get-Content -Raw -LiteralPath $SecretsPath | ConvertFrom-Json
    $appDb = $secrets.'ConnectionStrings__Default'
    $erpDb = $secrets.'ErpDb__ConnectionString'

    if ([string]::IsNullOrWhiteSpace($appDb)) {
        throw "deploy-secrets.json is missing 'ConnectionStrings__Default'."
    }
    if ([string]::IsNullOrWhiteSpace($erpDb)) {
        throw "deploy-secrets.json is missing 'ErpDb__ConnectionString'. " +
              "Add it once (see set-secret.ps1), or ERP sync will throw " +
              "'ErpDb:ConnectionString is not configured'."
    }

    # Single source of truth for the block. Order preserved.
    $envVars = [ordered]@{
        'ConnectionStrings__Default'   = $appDb
        'ASPNETCORE_ENVIRONMENT'       = $AspNetCoreEnvironment
        'DataProtection__KeyDirectory' = $DataProtectionKeyDirectory
        'ErpDb__ConnectionString'      = $erpDb
    }

    [xml]$xml = Get-Content -Raw -LiteralPath $WebConfigPath

    # The ONLY correct nesting is <location><system.webServer><aspNetCore>.
    # Env vars anywhere else are silently ignored by the ASP.NET Core Module.
    $aspNetCore = $xml.SelectSingleNode('/configuration/location/system.webServer/aspNetCore')
    if ($null -eq $aspNetCore) {
        $aspNetCore = $xml.SelectSingleNode('/configuration/system.webServer/aspNetCore')
    }
    if ($null -eq $aspNetCore) {
        throw "Could not find <aspNetCore> in web.config. Publish output layout changed — inspect before injecting."
    }

    # Rebuild from scratch => idempotent, no duplicates, always correct nesting.
    $existing = $aspNetCore.SelectSingleNode('environmentVariables')
    if ($null -ne $existing) { [void]$aspNetCore.RemoveChild($existing) }

    $envNode = $xml.CreateElement('environmentVariables')
    foreach ($name in $envVars.Keys) {
        $ev = $xml.CreateElement('environmentVariable')
        $ev.SetAttribute('name',  $name)
        $ev.SetAttribute('value', [string]$envVars[$name])
        [void]$envNode.AppendChild($ev)
    }
    [void]$aspNetCore.AppendChild($envNode)

    # Save UTF-8 no BOM to match publish output.
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent   = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($WebConfigPath, $settings)
    try   { $xml.Save($writer) } finally { $writer.Dispose() }

    Write-Host "  web.config <environmentVariables> injected ($($envVars.Count) vars):"
    foreach ($name in $envVars.Keys) {
        $val = [string]$envVars[$name]
        if ($val -match 'Password=') { $val = $val -replace 'Password=[^;]*', 'Password=***' }
        Write-Host ("    {0} = {1}" -f $name, $val)
    }
}

# ============================================================================
#  HEALTH CHECK  (loopback GET with correct SNI host; any non-5xx = alive)
# ============================================================================
function Test-SiteHealthy {
    param([string]$SiteHost, [string]$LoopbackIp, [int]$TimeoutSec)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $url = "https://$SiteHost/"
    while ((Get-Date) -lt $deadline) {
        try {
            # curl.exe with --resolve so SNI matches the cert; -k skips cert chain.
            $code = & curl.exe -k -s -o NUL -w "%{http_code}" `
                        --resolve "${SiteHost}:443:${LoopbackIp}" `
                        --max-time 8 $url 2>$null
            if ($code -match '^\d{3}$') {
                # 200/302/401 = the app is up and serving. 5xx = booted but crashing.
                if ([int]$code -lt 500) {
                    Write-Ok "Health check passed (HTTP $code)"
                    return $true
                }
                Write-Warn "Health check got HTTP $code — retrying..."
            }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ============================================================================
#  MAIN
# ============================================================================
$deployStart = Get-Date
$backupDir = Join-Path $BackupRoot ("ReceivingOps-backup-{0:yyyyMMdd-HHmmss}" -f $deployStart)

try {
    # --- 0. sanity ---
    Write-Step "Pre-flight checks"
    if (-not (Test-Path $ProjectPath)) { throw "Project not found at '$ProjectPath'." }
    if (-not (Test-Path $SecretsPath))  { throw "Secrets file not found at '$SecretsPath'. Run set-secret.ps1 first." }
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw "'dotnet' not on PATH." }
    if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) { throw "App pool '$AppPoolName' does not exist." }
    Write-Ok "Project, secrets, dotnet, and app pool all present"

    # --- 1. publish to a clean staging dir ---
    Write-Step "Publishing ($Configuration)"
    if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
    & dotnet publish $ProjectPath -c $Configuration -o $StagingDir --nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)." }
    if (-not (Test-Path (Join-Path $StagingDir 'ReceivingOps.Web.dll'))) {
        throw "Publish produced no ReceivingOps.Web.dll — aborting."
    }
    Write-Ok "Published to staging: $StagingDir"

    # --- 2. inject env vars into the STAGING web.config ---
    Write-Step "Injecting web.config environment variables"
    Set-WebConfigEnvironment `
        -WebConfigPath $StagingWebConfig `
        -SecretsPath   $SecretsPath `
        -AspNetCoreEnvironment      $AspNetCoreEnvironment `
        -DataProtectionKeyDirectory $DataProtectionKeyDirectory
    Write-Ok "Staging web.config carries all four env vars"

    if ($WhatIfCopy) {
        Write-Step "WhatIfCopy — stopping before touching live"
        Write-Warn "Staging is ready at $StagingDir. Live app was NOT modified."
        Write-Warn "Inspect $StagingWebConfig, then re-run without -WhatIfCopy to deploy."
        return
    }

    # --- 3. backup live (only if a live deploy already exists) ---
    Write-Step "Backing up live app"
    if (Test-Path $LiveDir) {
        Copy-Item $LiveDir $backupDir -Recurse -Force
        Write-Ok "Backup created: $backupDir"
    } else {
        New-Item -ItemType Directory -Force $LiveDir | Out-Null
        Write-Warn "No existing live app — first deploy. Created empty $LiveDir (no backup)."
    }

    # --- 4. stop pool ---
    Write-Step "Stopping app pool '$AppPoolName'"
    if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') {
        Stop-WebAppPool -Name $AppPoolName
        # wait for it to actually stop so DLLs unlock
        $t = (Get-Date).AddSeconds(20)
        while ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped' -and (Get-Date) -lt $t) {
            Start-Sleep -Milliseconds 500
        }
    }
    Write-Ok "App pool stopped"

    # --- 5. robocopy staging -> live ---
    # Mirror everything. web.config is included here because the STAGING copy is
    # the injected one (step 2) — so live ends up with the correct 4-var block.
    # /MIR keeps live clean of files removed from the build. We protect the
    # DataProtection key dir only if it were ever nested under the app (it isn't
    # here — it lives in C:\ProgramData — but the /XD guard is cheap insurance).
    Write-Step "Copying staging -> live"
    $roboArgs = @(
        $StagingDir, $LiveDir,
        '/MIR',
        '/XD', (Join-Path $LiveDir '.dp-keys'),   # never nuke a stray local keyring
        '/R:2', '/W:2', '/NFL', '/NDL', '/NP'
    )
    & robocopy @roboArgs | Out-Null
    # robocopy exit codes 0-7 are success (8+ = failure)
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE)." }
    Write-Ok "Files mirrored to live (exit $LASTEXITCODE)"

    # sanity: confirm the injected block actually landed in live web.config
    if (-not (Select-String -Path $LiveWebConfig -Pattern 'DataProtection__KeyDirectory' -Quiet)) {
        throw "Live web.config is missing DataProtection__KeyDirectory after copy — aborting before start."
    }
    if (-not (Select-String -Path $LiveWebConfig -Pattern 'ErpDb__ConnectionString' -Quiet)) {
        throw "Live web.config is missing ErpDb__ConnectionString after copy — aborting before start."
    }
    Write-Ok "Verified all env vars present in live web.config"

    # --- 6. start pool ---
    Write-Step "Starting app pool"
    Start-WebAppPool -Name $AppPoolName
    Start-Sleep -Seconds 2
    Write-Ok "App pool started"

    # --- 7. health check ---
    Write-Step "Health check (loopback)"
    if (-not (Test-SiteHealthy -SiteHost $SiteHost -LoopbackIp $LoopbackIp -TimeoutSec $HealthTimeoutSec)) {
        throw "Health check FAILED within $HealthTimeoutSec s — triggering rollback."
    }

    # --- 8. prune old backups ---
    Write-Step "Pruning old backups (keep $BackupsToKeep)"
    Get-ChildItem $BackupRoot -Directory -Filter 'ReceivingOps-backup-*' |
        Sort-Object Name -Descending |
        Select-Object -Skip $BackupsToKeep |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force; Write-Host "    pruned $($_.Name)" }

    $elapsed = [int]((Get-Date) - $deployStart).TotalSeconds
    Write-Host "`n=== DEPLOY SUCCESSFUL in ${elapsed}s ===" -ForegroundColor Green
    Write-Host "  Live: $LiveDir" -ForegroundColor Green
    Write-Host "  Backup kept at: $backupDir" -ForegroundColor Green
}
catch {
    Write-Host "`n=== DEPLOY FAILED ===" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red

    # ---------- AUTO-ROLLBACK ----------
    if (Test-Path $backupDir) {
        Write-Step "Rolling back to backup"
        try {
            if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') {
                Stop-WebAppPool -Name $AppPoolName
                Start-Sleep -Seconds 2
            }
            & robocopy $backupDir $LiveDir '/MIR' '/R:2' '/W:2' '/NFL' '/NDL' '/NP' | Out-Null
            Start-WebAppPool -Name $AppPoolName
            Start-Sleep -Seconds 2

            if (Test-SiteHealthy -SiteHost $SiteHost -LoopbackIp $LoopbackIp -TimeoutSec $HealthTimeoutSec) {
                Write-Host "  Rollback restored the previous version — site is healthy again." -ForegroundColor Yellow
            } else {
                Write-Host "  Rollback copied files but health check STILL fails — manual attention needed." -ForegroundColor Red
                Write-Host "  Backup is at: $backupDir" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "  ROLLBACK ITSELF FAILED: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  Restore manually from: $backupDir" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  No backup to roll back to (failure happened before/without backup)." -ForegroundColor Red
        # make sure we don't leave the pool stopped
        try { Start-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue } catch {}
    }

    exit 1
}
