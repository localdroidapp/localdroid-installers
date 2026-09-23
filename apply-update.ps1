<#
.SYNOPSIS
    Installs a LocalDroid update package (localdroid-update-windows-amd64.zip)
    on a Windows server, from the command line.

.DESCRIPTION
    From v1.9.0 on, upgrade from the dashboard: Settings -> System -> Updates.
    Use this script when the dashboard cannot do it:

      * the server runs a version older than v1.9.0, which has no in-app
        upgrade (this is how every existing server gets to v1.9.0), or
      * the server will not start and you need to put a working version in place.

    What it does, stopping at the first problem:
      1. Verifies every file in the package against its update.json checksums.
      2. Backs up the database (pg_dump) and the server files into
         <server>\storage\backups\, in the same format the dashboard uses, so
         the backup is listed in Settings -> System and can be restored there.
      3. Stops the server, swaps in the new executable, web UI, migrations
         and agents, and starts it again.
      4. Waits for /api/health to report the new version. If the server does
         not come up, it puts the previous files and database back and starts
         the old version.

    The new server applies database migrations when it starts, records the
    install manifest, and brings the "LocalDroid MDM Server" scheduled task
    up to date. Nothing else needs doing afterwards.

.PARAMETER Package
    Path to localdroid-update-windows-amd64.zip.

.PARAMETER InstallDir
    LocalDroid install folder (the one containing server\). Detected from the
    scheduled task when omitted, then falls back to C:\LocalDroid.

.PARAMETER TimeoutSeconds
    How long to wait for the new version to report healthy. Default 180.

.EXAMPLE
    .\apply-update.ps1 -Package C:\Users\me\Downloads\localdroid-update-windows-amd64.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Package,
    [string]$InstallDir = "",
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$TaskName = 'LocalDroid MDM Server'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "`n[FAILED] $m" -ForegroundColor Red; exit 1 }

# Files the Go server reads (backup.json) must not start with a BOM.
function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, $Utf8NoBom) }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Run this from an Administrator PowerShell."
}

# ---------------------------------------------------------------- locate
if (-not $InstallDir) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t -and $t.Actions[0].WorkingDirectory) { $InstallDir = Split-Path $t.Actions[0].WorkingDirectory -Parent }
    if (-not $InstallDir) { $InstallDir = 'C:\LocalDroid' }
}
$ServerDir = Join-Path $InstallDir 'server'
$Exe = Join-Path $ServerDir 'localdroid-server.exe'
$EnvFile = Join-Path $ServerDir '.env'
if (-not (Test-Path $Exe))     { Fail "No server at $Exe. Pass -InstallDir." }
if (-not (Test-Path $EnvFile)) { Fail "No .env at $EnvFile." }
if (-not (Test-Path $Package)) { Fail "Package not found: $Package" }
Write-Host "Install folder: $InstallDir"

function Get-EnvValue($key, $default) {
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^\s*$key\s*=\s*", '').Trim().Trim('"') }
    return $default
}

# ---------------------------------------------------------------- 1. verify
Step "Verifying the update package"
$work = Join-Path $env:TEMP ("localdroid-update-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
try {
    Expand-Archive -Path $Package -DestinationPath $work -Force
} catch {
    Fail "Could not open the package: $_"
}
$metaPath = Join-Path $work 'update.json'
if (-not (Test-Path $metaPath)) { Fail "Not a LocalDroid update package (no update.json)." }
$meta = Get-Content $metaPath -Raw | ConvertFrom-Json
if ($meta.format -ne 1) { Fail "Unsupported package format $($meta.format)." }
if ($meta.os -ne 'windows' -or $meta.arch -ne 'amd64') {
    Fail "This package is for $($meta.os)-$($meta.arch). Use localdroid-update-windows-amd64.zip."
}
$listed = @($meta.files.PSObject.Properties)
foreach ($f in $listed) {
    $p = Join-Path $work ($f.Name -replace '/', '\')
    if (-not (Test-Path $p)) { Fail "Package is missing $($f.Name)." }
    if ((Get-FileHash $p -Algorithm SHA256).Hash -ne $f.Value.ToUpper()) { Fail "$($f.Name) is damaged. Download the package again." }
}
$newServer = Join-Path $work 'server'
if (-not (Test-Path (Join-Path $newServer 'localdroid-server.exe'))) { Fail "Package has no server executable." }
Ok "Version $($meta.version), $($listed.Count) files verified"

# ---------------------------------------------------------------- 2. backup
Step "Backing up the database and server files"
$pgBin = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\pg_dump.exe' -ErrorAction SilentlyContinue |
    Sort-Object { [int]$_.Directory.Parent.Name } -Descending | Select-Object -First 1
if (-not $pgBin) { Fail "pg_dump.exe not found under C:\Program Files\PostgreSQL." }
$pgDir = $pgBin.DirectoryName

$db = @{
    Host = Get-EnvValue 'DB_HOST' 'localhost'; Port = Get-EnvValue 'DB_PORT' '5432'
    User = Get-EnvValue 'DB_USER' 'postgres';  Name = Get-EnvValue 'DB_NAME' 'localdroid'
}
$env:PGPASSWORD = Get-EnvValue 'DB_PASSWORD' ''
$pgConn = @('-h', $db.Host, '-p', $db.Port, '-U', $db.User)

# v1.9.0+ reports its version on /api/health; anything older has no endpoint.
$oldVersion = 'pre-1.9.0'
try {
    $p = Get-EnvValue 'SERVER_PORT' '8080'
    $h = Invoke-RestMethod -Uri "http://127.0.0.1:$p/api/health" -TimeoutSec 5
    if ($h.version -and $h.version -ne 'dev') { $oldVersion = $h.version }
} catch { }
$now = (Get-Date).ToUniversalTime()
$backupId = $now.ToString('yyyyMMdd-HHmmss') + '_' + $oldVersion
$backupDir = Join-Path $ServerDir "storage\backups\$backupId"
New-Item -ItemType Directory -Force (Join-Path $backupDir 'files') | Out-Null

# -f, never '>': PowerShell 5.1 re-encodes redirected native output as UTF-16,
# which restores as an empty schema (see 8ae3b76).
$dump = Join-Path $backupDir 'db.dump'
& (Join-Path $pgDir 'pg_dump.exe') @pgConn -Fc -f $dump $db.Name
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dump) -or (Get-Item $dump).Length -lt 1024) {
    Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    Fail "pg_dump failed; nothing was changed."
}

$targets = @('localdroid-server.exe', 'migrations', 'web\dist', 'storage\agent', '.env', 'license.lic',
             'install-manifest.json', 'localdroid-supervisor.ps1')
$copied = @()
$filesBytes = 0
foreach ($rel in $targets) {
    $src = Join-Path $ServerDir $rel
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path (Join-Path $backupDir 'files') $rel
    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
    Copy-Item $src $dst -Recurse -Force
    $filesBytes += (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $copied += ($rel -replace '\\', '/')
}
$dumpItem = Get-Item $dump
$backupMeta = [ordered]@{
    id          = $backupId
    version     = $oldVersion
    reason      = 'pre-upgrade'
    note        = "before upgrading to $($meta.version) with apply-update.ps1"
    created_at  = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    db_bytes    = $dumpItem.Length
    db_sha256   = (Get-FileHash $dump -Algorithm SHA256).Hash.ToLower()
    files_bytes = [int64]$filesBytes
    files       = $copied
}
Write-Utf8 (Join-Path $backupDir 'backup.json') ($backupMeta | ConvertTo-Json -Depth 4)
Ok "Backup $backupId ($([math]::Round($dumpItem.Length / 1MB, 1)) MB database)"

# ---------------------------------------------------------------- 3. swap
function Stop-Server {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Get-Process localdroid-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30 -and (Get-Process localdroid-server -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    if (Get-Process localdroid-server -ErrorAction SilentlyContinue) { Fail "The server did not stop." }
}

function Start-Server {
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        # No auto-start task (a hand-started server). Register the plain loop;
        # the new server replaces it with its supervisor on first start.
        $cmd = "while(`$true){ & '$Exe'; Start-Sleep 5 }"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $ServerDir `
            -Argument ('-NoProfile -WindowStyle Hidden -Command "' + $cmd + '"')
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
            -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
        Ok "Registered the '$TaskName' scheduled task (it had none)"
    }
    Start-ScheduledTask -TaskName $TaskName
}

function Replace-Item($src, $dst) {
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
    Copy-Item $src $dst -Recurse -Force
}

function Restore-Previous {
    Write-Host "    Restoring the previous version from backup $backupId..." -ForegroundColor Yellow
    Stop-Server
    foreach ($rel in $copied) {
        $r = $rel -replace '/', '\'
        Replace-Item (Join-Path (Join-Path $backupDir 'files') $r) (Join-Path $ServerDir $r)
    }
    # Drop and restore in one transaction, so a failed restore changes nothing.
    $sql = Join-Path $work 'restore.sql'
    & (Join-Path $pgDir 'pg_restore.exe') --no-owner -f $sql $dump
    $reset = Join-Path $work 'reset.sql'
    Write-Utf8 $reset "DROP SCHEMA public CASCADE;`nCREATE SCHEMA public;`nGRANT USAGE ON SCHEMA public TO public;`n"
    & (Join-Path $pgDir 'psql.exe') @pgConn -d $db.Name -X -q -v ON_ERROR_STOP=1 --single-transaction -f $reset -f $sql | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn "Database restore failed; the database is unchanged from the failed upgrade. Restore $dump by hand." }
    Start-Server
}

Step "Stopping the server"
Stop-Server
Ok "Stopped"

Step "Installing $($meta.version)"
Copy-Item (Join-Path $newServer 'localdroid-server.exe') $Exe -Force
Replace-Item (Join-Path $newServer 'migrations') (Join-Path $ServerDir 'migrations')
Replace-Item (Join-Path $newServer 'web\dist') (Join-Path $ServerDir 'web\dist')
New-Item -ItemType Directory -Force (Join-Path $ServerDir 'storage\agent') | Out-Null
Get-ChildItem (Join-Path $newServer 'storage\agent') -File | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $ServerDir "storage\agent\$($_.Name)") -Force
}
# Zero-Touch enrollment compares against this; keep it equal to the shipped sidecar.
$sidecar = Join-Path $ServerDir 'storage\agent\localdroid-agent.apk.cert-sha256'
if (Test-Path $sidecar) {
    $cert = (Get-Content $sidecar -Raw).Trim()
    $lines = @(Get-Content $EnvFile)
    if ($lines -match '^APK_SIGNATURE_CHECKSUM=') {
        $lines = $lines | ForEach-Object { if ($_ -match '^APK_SIGNATURE_CHECKSUM=') { "APK_SIGNATURE_CHECKSUM=$cert" } else { $_ } }
    } else { $lines += "APK_SIGNATURE_CHECKSUM=$cert" }
    Write-Utf8 $EnvFile (($lines -join "`r`n") + "`r`n")
}
Ok "Files installed"

# ---------------------------------------------------------------- 4. verify
Step "Starting $($meta.version) (it applies database migrations on first start)"
Start-Server
$port = Get-EnvValue 'SERVER_PORT' '8080'
$scheme = 'http'
if ((Get-EnvValue 'ENABLE_TLS' 'false') -eq 'true') { $scheme = 'https' }
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$url = "${scheme}://127.0.0.1:$port/api/health"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$healthy = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep 3
    try {
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 5
        if ($r.status -eq 'ok' -and $r.version -eq $meta.version) { $healthy = $true; break }
    } catch { }
}

if (-not $healthy) {
    Warn "$($meta.version) did not report healthy within $TimeoutSeconds seconds."
    $log = Join-Path $ServerDir 'storage\logs\server.log'
    if (Test-Path $log) { Write-Host "    Last lines of $log`:"; Get-Content $log -Tail 15 | ForEach-Object { Write-Host "      $_" } }
    Restore-Previous
    Fail "The upgrade was rolled back. The previous version is running again. Backup: $backupDir"
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "LocalDroid $($meta.version) is running." -ForegroundColor Green
Write-Host "  Backup of the previous version: $backupDir"
Write-Host "  Server log: $(Join-Path $ServerDir 'storage\logs\server.log')"
Write-Host "  Future upgrades: Settings -> System -> Updates in the dashboard."
