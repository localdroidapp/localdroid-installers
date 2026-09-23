<#
.SYNOPSIS
    Removes LocalDroid MDM from a Windows server.

.DESCRIPTION
    Default: removes the LocalDroid server and keeps its data. It stops the
    server, removes its scheduled tasks and firewall rules, and deletes the
    install folder. The PostgreSQL database is kept, so a reinstall picks up
    where this one left off.

    -Purge also deletes the database and the Mosquitto configuration
    LocalDroid wrote, leaving nothing of LocalDroid behind.

    -RemoveDependencies (with -Purge) also uninstalls PostgreSQL and
    Mosquitto, including PostgreSQL's data folder. Use this to get the machine
    back to the state it was in before LocalDroid was ever installed.

    A final backup (database dump, .env, license and certificates) is written
    to C:\LocalDroid-final-backup-<time> first, unless -NoBackup is given.

.PARAMETER InstallDir
    The LocalDroid folder (containing server\). Detected from the scheduled
    task when omitted, then C:\LocalDroid.

.PARAMETER Yes
    Do not ask for confirmation.

.EXAMPLE
    .\uninstall-windows.ps1                               # remove, keep the database
.EXAMPLE
    .\uninstall-windows.ps1 -Purge -RemoveDependencies    # back to a clean machine
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [switch]$Purge,
    [switch]$RemoveDependencies,
    [switch]$RemoveBuildTools,
    [switch]$NoBackup,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "`n[FAILED] $m" -ForegroundColor Red; exit 1 }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Run this from an Administrator PowerShell."
}
if ($RemoveDependencies -and -not $Purge) { Fail "-RemoveDependencies also removes the database server, so it requires -Purge." }

# Every task a LocalDroid version has registered, including hand-made
# duplicates seen in the field.
$Tasks = @('LocalDroid MDM Server', 'LocalDroid MDM Restart', 'LocalDroid TLS certificate reload',
           'Localdroid-server', 'LocalDroid-Server', 'LocalDroid Server')

if (-not $InstallDir) {
    $t = Get-ScheduledTask -TaskName 'LocalDroid MDM Server' -ErrorAction SilentlyContinue
    if ($t -and $t.Actions[0].WorkingDirectory) { $InstallDir = Split-Path $t.Actions[0].WorkingDirectory -Parent }
    if (-not $InstallDir) { $InstallDir = 'C:\LocalDroid' }
}
$ServerDir = Join-Path $InstallDir 'server'
$EnvFile = Join-Path $ServerDir '.env'
$MqConf = 'C:\Program Files\mosquitto\mosquitto.conf'

function Get-EnvValue($key, $default) {
    if (-not (Test-Path $EnvFile)) { return $default }
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
    if ($line) { return ([string]$line -replace "^\s*$key\s*=\s*", '').Trim().Trim('"') }
    return $default
}
$db = @{
    Host = Get-EnvValue 'DB_HOST' 'localhost'; Port = Get-EnvValue 'DB_PORT' '5432'
    User = Get-EnvValue 'DB_USER' 'postgres';  Name = Get-EnvValue 'DB_NAME' 'localdroid'
}
$env:PGPASSWORD = Get-EnvValue 'DB_PASSWORD' ''
$pgBin = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
    Sort-Object { [int]$_.Directory.Parent.Name } -Descending | Select-Object -First 1
$pgDir = if ($pgBin) { $pgBin.DirectoryName } else { $null }
$pgConn = @('-h', $db.Host, '-p', $db.Port, '-U', $db.User)

# ---------------------------------------------------------------- confirm
Write-Host ""
Write-Host "LocalDroid uninstall" -ForegroundColor White
Write-Host "  Install folder : $InstallDir $(if (-not (Test-Path $InstallDir)) { '(not found)' })"
Write-Host "  Will remove    : the server, its scheduled tasks and firewall rules, and the install folder"
if ($Purge) {
    Write-Host "                   the '$($db.Name)' database and LocalDroid's Mosquitto configuration" -ForegroundColor Yellow
} else {
    Write-Host "  Will keep      : the '$($db.Name)' database (use -Purge to delete it)"
}
if ($RemoveDependencies) { Write-Host "                   PostgreSQL (with ALL its databases) and Mosquitto" -ForegroundColor Yellow }
if ($RemoveBuildTools)   { Write-Host "                   Go, Node.js and Git" -ForegroundColor Yellow }
if ($NoBackup) { Write-Host "  Final backup   : none (-NoBackup)" -ForegroundColor Yellow }
else { Write-Host "  Final backup   : C:\LocalDroid-final-backup-<time>" }
Write-Host ""
if (-not $Yes) {
    $answer = Read-Host "Type UNINSTALL to continue"
    if ($answer -ne 'UNINSTALL') { Write-Host "Cancelled."; exit 0 }
}

# ---------------------------------------------------------------- backup
if (-not $NoBackup) {
    Step "Final backup"
    $bdir = 'C:\LocalDroid-final-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Force $bdir | Out-Null
    foreach ($f in '.env', 'license.lic', 'install-manifest.json') {
        $p = Join-Path $ServerDir $f
        if (Test-Path $p) { Copy-Item $p $bdir }
    }
    foreach ($d in 'certs') {
        $p = Join-Path $InstallDir $d
        if (Test-Path $p) { Copy-Item $p (Join-Path $bdir $d) -Recurse }
    }
    if ($pgDir) {
        $dump = Join-Path $bdir 'localdroid-db.dump'
        & (Join-Path $pgDir 'pg_dump.exe') @pgConn -Fc -f $dump $db.Name 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $dump)) { Ok "Database dumped to $dump" }
        else {
            Warn "Could not dump the database (it may not exist)."
            if ($Purge -and -not $Yes) {
                if ((Read-Host "Continue and delete the database without a backup? (y/N)") -ne 'y') { exit 1 }
            }
        }
    }
    Ok "Backup folder: $bdir"
}

# ---------------------------------------------------------------- stop + tasks
Step "Stopping the server and removing scheduled tasks"
foreach ($n in $Tasks) {
    if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $n -Confirm:$false
        Ok "Removed task '$n'"
    }
}
# The supervisor loop and any hand-started copy.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'localdroid-supervisor\.ps1|localdroid-server\.exe' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process localdroid-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20 -and (Get-Process localdroid-server -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
Ok "Server stopped"

# ---------------------------------------------------------------- firewall
Step "Removing firewall rules"
$rules = @(Get-NetFirewallRule -DisplayName 'LocalDroid*' -ErrorAction SilentlyContinue)
$rules | Remove-NetFirewallRule
Ok "$($rules.Count) rule(s) removed"

# ---------------------------------------------------------------- database
if ($Purge) {
    Step "Deleting the '$($db.Name)' database"
    if ($pgDir) {
        $q = "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$($db.Name)' AND pid <> pg_backend_pid();"
        & (Join-Path $pgDir 'psql.exe') @pgConn -d postgres -X -q -c $q 2>$null | Out-Null
        & (Join-Path $pgDir 'psql.exe') @pgConn -d postgres -X -q -c "DROP DATABASE IF EXISTS `"$($db.Name)`";"
        if ($LASTEXITCODE -eq 0) { Ok "Database deleted" } else { Warn "Could not delete the database." }
        if ($db.User -ne 'postgres') {
            & (Join-Path $pgDir 'psql.exe') @pgConn -d postgres -X -q -c "DROP ROLE IF EXISTS `"$($db.User)`";" 2>$null
        }
    } else {
        Warn "psql.exe not found; the database was not deleted."
    }

    Step "Removing LocalDroid's Mosquitto configuration"
    if ((Test-Path $MqConf) -and (Select-String -Path $MqConf -Pattern 'LocalDroid|listener' -Quiet)) {
        Copy-Item $MqConf "$MqConf.localdroid-uninstalled" -Force
        [IO.File]::WriteAllText($MqConf, "# LocalDroid removed its configuration. Previous file: mosquitto.conf.localdroid-uninstalled`r`n",
            (New-Object System.Text.UTF8Encoding($false)))
        Restart-Service mosquitto -ErrorAction SilentlyContinue
        Ok "mosquitto.conf reset (previous copy kept beside it)"
    }
}

# ---------------------------------------------------------------- files
Step "Deleting $InstallDir"
if (Test-Path $InstallDir) {
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        Start-Sleep 3
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $InstallDir) { Warn "Some files could not be deleted; remove $InstallDir after a reboot." }
    else { Ok "Deleted" }
}

# ---------------------------------------------------------------- dependencies
function Remove-Winget($id, $label) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Warn "winget not available; uninstall $label from Settings -> Apps."; return }
    winget uninstall -e --id $id --silent --accept-source-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "$label uninstalled" } else { Warn "$label was not uninstalled by winget (it may have been installed another way)." }
}

if ($RemoveDependencies) {
    Step "Uninstalling PostgreSQL and Mosquitto"
    Get-Service postgresql* -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    Stop-Service mosquitto -Force -ErrorAction SilentlyContinue
    Remove-Winget 'PostgreSQL.PostgreSQL.16' 'PostgreSQL 16'
    Remove-Winget 'EclipseFoundation.Mosquitto' 'Mosquitto'
    # Both uninstallers leave data and config behind; a fresh install must not find them.
    foreach ($d in 'C:\Program Files\PostgreSQL', 'C:\Program Files\mosquitto') {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; Ok "Deleted $d" }
    }
}
if ($RemoveBuildTools) {
    Step "Uninstalling Go, Node.js and Git"
    Remove-Winget 'GoLang.Go' 'Go'
    Remove-Winget 'OpenJS.NodeJS.LTS' 'Node.js'
    Remove-Winget 'Git.Git' 'Git'
}

# ---------------------------------------------------------------- state file
# The installer resumes from .install-state.json in the folder it was run
# from. One left behind makes the next "fresh" install skip steps.
$stale = @()
foreach ($d in @($PSScriptRoot, (Join-Path $env:USERPROFILE 'Downloads'), $env:USERPROFILE)) {
    if ($d) {
        $p = Join-Path $d '.install-state.json'
        if (Test-Path $p) { $stale += $p }
    }
}
foreach ($p in $stale) { Remove-Item $p -Force; Ok "Removed installer state $p" }

Write-Host ""
Write-Host "LocalDroid has been removed." -ForegroundColor Green
if (-not $Purge) { Write-Host "  The '$($db.Name)' database was kept. Run again with -Purge to delete it." }
Write-Host "  If you ran the installer from another folder, delete the .install-state.json there before reinstalling."
