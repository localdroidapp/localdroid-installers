<#
.SYNOPSIS
    Build a self-contained LocalDroid MDM deployment package for air-gapped Windows servers.
.DESCRIPTION
    Builds server binary, web UI, and packages everything into a zip that can be
    copied to an air-gapped machine. The target machine only needs PostgreSQL and Mosquitto.
.PARAMETER IncludeInstallers
    Download PostgreSQL and Mosquitto installers into the package (requires internet).
.PARAMETER OutputPath
    Output directory for the zip file. Defaults to current directory.
#>

param(
    [switch]$IncludeInstallers,
    [string]$OutputPath = "."
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Err { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

Write-Host @"

  _                    _ ____            _     _ 
 | |    ___   ___ __ _| |  _ \ _ __ ___ (_) __| |
 | |   / _ \ / __/ _`` | | | | | '__/ _ \| |/ _`` |
 | |__| (_) | (_| (_| | | |_| | | | (_) | | (_| |
 |_____\___/ \___\__,_|_|____/|_|  \___/|_|\__,_|
                                                 
  Deployment Package Builder
  
"@ -ForegroundColor Blue

# ============================================================================
# Create staging directory
# ============================================================================
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stagingDir = Join-Path $env:TEMP "localdroid-deploy-$timestamp"
$packageName = "localdroid-deploy-$timestamp"

Write-Step "Creating staging directory: $stagingDir"
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
New-Item -ItemType Directory -Path "$stagingDir\server" -Force | Out-Null
New-Item -ItemType Directory -Path "$stagingDir\server\web\dist" -Force | Out-Null
New-Item -ItemType Directory -Path "$stagingDir\server\storage\agent" -Force | Out-Null
New-Item -ItemType Directory -Path "$stagingDir\server\storage\files" -Force | Out-Null
New-Item -ItemType Directory -Path "$stagingDir\server\storage\apps" -Force | Out-Null
New-Item -ItemType Directory -Path "$stagingDir\server\migrations" -Force | Out-Null
New-Item -ItemType Directory -Path "$stagingDir\mosquitto" -Force | Out-Null
if ($IncludeInstallers) {
    New-Item -ItemType Directory -Path "$stagingDir\installers" -Force | Out-Null
}

# ============================================================================
# Build server binary
# ============================================================================
Write-Step "Building Go server binary..."
Push-Location "$ScriptDir\server"
go build -o localdroid-server.exe ./cmd/server
Pop-Location

if (-not (Test-Path "$ScriptDir\server\localdroid-server.exe")) {
    Write-Err "Failed to build server binary"
    exit 1
}
Copy-Item "$ScriptDir\server\localdroid-server.exe" "$stagingDir\server\localdroid-server.exe"
Write-Success "Server binary built and copied"

# ============================================================================
# Build web UI
# ============================================================================
Write-Step "Building web UI..."
Push-Location "$ScriptDir\web"
npm run build 2>$null
Pop-Location

if (-not (Test-Path "$ScriptDir\web\dist\index.html")) {
    Write-Err "Failed to build web UI"
    exit 1
}
Copy-Item -Path "$ScriptDir\web\dist\*" -Destination "$stagingDir\server\web\dist\" -Recurse -Force
Write-Success "Web UI built and copied"

# ============================================================================
# Copy Android agent APK (from local files only — no internet fetch)
# ============================================================================
Write-Step "Copying Android agent APK..."
$stagingApk = "$stagingDir\server\storage\agent\localdroid-agent.apk"
New-Item -ItemType Directory -Path "$stagingDir\server\storage\agent" -Force | Out-Null

# Priority order matches install.sh's STEP 9 — seed/ first (canonical bundle),
# releases/ second (legacy hand-rolled), then the developer's local build.
$apkCandidates = @(
    "$ScriptDir\seed\localdroid-agent.apk",
    "$ScriptDir\releases\localdroid-agent.apk",
    "$ScriptDir\releases\localdroid-agent-v1.0.0.apk",
    "$ScriptDir\android-agent\app\build\outputs\apk\release\app-release.apk"
)
$apkSource = $apkCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($apkSource) {
    Copy-Item $apkSource $stagingApk -Force
    Write-Success "Agent APK copied from $apkSource"
} else {
    Write-Host "  [WARN] No APK found. Drop localdroid-agent.apk in seed\ or releases\ and re-run, or add manually post-install." -ForegroundColor Yellow
}

# ============================================================================
# Copy database migrations
# ============================================================================
Write-Step "Copying database migrations..."
Copy-Item -Path "$ScriptDir\server\migrations\*.sql" -Destination "$stagingDir\server\migrations\" -Force
$migrationCount = (Get-ChildItem "$stagingDir\server\migrations\*.sql").Count
Write-Success "Copied $migrationCount migration files"

# ============================================================================
# Create mosquitto config for Windows
# ============================================================================
Write-Step "Creating Mosquitto configuration..."
$mosquittoConf = @"
# Mosquitto MQTT Broker Configuration for LocalDroid
# Air-gapped network configuration

listener 1883
protocol mqtt

listener 9001
protocol websockets

allow_anonymous true

persistence true
persistence_location C:/ProgramData/localdroid/mosquitto/

log_dest file C:/ProgramData/localdroid/mosquitto/mosquitto.log
log_type error
log_type warning
log_type notice

# Resource limits — a runaway client can't exhaust the broker or flood the
# network. Size max_connections to device count plus headroom.
max_connections 1024
max_queued_messages 200
max_inflight_messages 20
message_size_limit 10485760
max_keepalive 120
"@
$mosquittoConf | Out-File -FilePath "$stagingDir\mosquitto\mosquitto.conf" -Encoding UTF8 -NoNewline
Write-Success "Mosquitto config created"

# ============================================================================
# Create .env template
# ============================================================================
Write-Step "Creating configuration template..."
$envTemplate = @"
SERVER_HOST=0.0.0.0
SERVER_PORT=80
DB_HOST=localhost
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=CHANGE_ME
DB_NAME=localdroid
DB_SSLMODE=disable
MQTT_HOST=localhost
MQTT_PORT=1883
JWT_SECRET=CHANGE_ME_RANDOM_STRING
EXTERNAL_URL=http://SERVER_IP
# APK_SIGNATURE_CHECKSUM is derived from the actual seeded APK by install.sh /
# install-windows.ps1 at install time (sidecar in seed/ takes priority, then
# apksigner against the APK). Do NOT hardcode a value here — it goes stale
# the moment the APK is re-signed.
APK_SIGNATURE_CHECKSUM=
# LocalDroid license-authority public key — safe to distribute (verify-only).
# Point LOCALDROID_LICENSE_FILE at a signed license.lic to auto-activate.
LICENSE_PUBLIC_KEY=woL+6yGOhnbu9E+iALVqMzIx1Uez7Rk2kP8pEXIQDDc=
"@
$envTemplate | Out-File -FilePath "$stagingDir\server\.env.template" -Encoding ASCII -NoNewline
Write-Success "Config template created"

# ============================================================================
# Download installers (optional)
# ============================================================================
if ($IncludeInstallers) {
    Write-Step "Downloading third-party installers..."
    
    $downloads = @(
        @{
            Name = "PostgreSQL 16"
            File = "postgresql-16-windows-x64.exe"
            Url  = "https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64.exe"
        },
        @{
            Name = "Mosquitto MQTT"
            File = "mosquitto-windows-x64.exe"
            Url  = "https://mosquitto.org/files/binary/win64/mosquitto-2.0.20-install-windows-x64.exe"
        }
    )
    
    foreach ($dl in $downloads) {
        $dest = Join-Path "$stagingDir\installers" $dl.File
        Write-Host "  Downloading $($dl.Name)..."
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $dl.Url -OutFile $dest -UseBasicParsing
            $ProgressPreference = 'Continue'
            Write-Success "Downloaded: $($dl.File)"
        } catch {
            Write-Host "  [WARN] Failed to download $($dl.Name): $_" -ForegroundColor Yellow
            Write-Host "  Manual download: $($dl.Url)" -ForegroundColor Gray
        }
    }
}

# ============================================================================
# Create the install scripts for the target machine
# ============================================================================
# Both Windows installers ship in every package. They read the same bundle
# layout and differ only in how they configure the deployment:
#   install-windows-offline.ps1 - air-gapped / local network (plain HTTP, LAN IP)
#   install-windows-cloud.ps1   - internet-connected (public domain, HTTPS,
#                                 MQTT over TLS, per-device broker auth)
# Shipping only the air-gapped one is what left cloud customers with no working
# Windows path, so a missing cloud installer is a hard failure here, not a warning.
Write-Step "Creating install scripts..."

$installScripts = @(
    @{ Name = "install-windows-offline.ps1"; Label = "Air-gapped installer"; Required = $true },
    @{ Name = "install-windows-cloud.ps1";   Label = "Cloud installer";      Required = $true }
)

foreach ($s in $installScripts) {
    # The packaging script may run from the source repo root or from a checkout
    # of the public installers repo - look in both.
    $candidates = @(
        (Join-Path $ScriptDir $s.Name),
        (Join-Path $ScriptDir "deploy\$($s.Name)"),
        (Join-Path $ScriptDir "installers\$($s.Name)")
    )
    $src = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($src) {
        Copy-Item $src (Join-Path $stagingDir $s.Name) -Force
        Write-Success "$($s.Label): $($s.Name)"
    } elseif ($s.Required) {
        Write-Err "$($s.Label) not found: $($s.Name)"
        Write-Host "  Looked in:" -ForegroundColor Yellow
        $candidates | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        exit 1
    } else {
        Write-Host "  [WARN] $($s.Label) not found, skipping" -ForegroundColor Yellow
    }
}

# Legacy entry point - older docs tell people to run install.ps1.
Copy-Item "$ScriptDir\deploy\install-airgapped.ps1" "$stagingDir\install.ps1" -ErrorAction SilentlyContinue

# ============================================================================
# Create README
# ============================================================================
$readme = @"
# LocalDroid MDM - Windows Deployment Package

Built: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

## Which installer do I run?

This package contains both Windows installers. Pick the one that matches how
devices will reach the server:

| Your deployment | Run |
|---|---|
| Devices on the same local network (air-gapped) | ``.\install-windows-offline.ps1`` |
| Devices connect over the internet (cloud) | ``.\install-windows-cloud.ps1`` |

**Do not use the air-gapped installer for an internet-connected server.** Its
"Internet Connected" menu option only tags the config as cloud - it still asks
for a LAN IP, writes a plain ``http://`` external URL, and leaves the MQTT
broker anonymous. The cloud installer is the one that asks for your public
domain and sets up HTTPS, MQTT over TLS and per-device broker credentials.

## Prerequisites

Install on the target Windows server:
1. **PostgreSQL 16+** (installers included if built with -IncludeInstallers)
2. **Mosquitto MQTT 2.0+** (installers included if built with -IncludeInstallers)

The cloud installer downloads either of these automatically if they are not
bundled - a cloud server has internet access by definition.

### Extra prerequisites for a cloud install

- A public domain name for this server (e.g. ``mdm.yourcompany.com``)
- A public DNS A-record for it pointing at this server's public IP
- Port 80/tcp reachable from the internet during install (certificate
  challenge), plus 443/tcp and 8883/tcp open for day-to-day traffic

## Quick Install

1. Copy this entire folder to the target server
2. Open PowerShell **as Administrator**
3. Run the installer for your deployment (see the table above)
4. Follow the prompts

Both installers are resumable - if a step fails, fix the cause and re-run.
Completed steps are skipped.

## Manual Install

If the install script doesn't work:

### 1. Install PostgreSQL & Mosquitto
Use the installers in the ``installers\`` folder or install manually.

### 2. Create Database
```powershell
psql -U postgres -c "CREATE DATABASE localdroid;"
cd server\migrations
Get-ChildItem *.sql | Sort-Object Name | ForEach-Object { psql -U postgres -d localdroid -f `$_.FullName }
```

### 3. Configure
Copy ``server\.env.template`` to ``server\.env`` and edit:
- Set ``DB_PASSWORD`` to your PostgreSQL password
- Set ``JWT_SECRET`` to a random string (use: ``[guid]::NewGuid().ToString("N")``)
- Set ``EXTERNAL_URL`` to ``http://<YOUR_SERVER_IP>``

### 4. Configure Mosquitto
Copy ``mosquitto\mosquitto.conf`` to ``C:\Program Files\mosquitto\mosquitto.conf``
Restart the Mosquitto service.

### 5. Open Firewall
```powershell
New-NetFirewallRule -DisplayName "LocalDroid HTTP" -Direction Inbound -Port 80 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "LocalDroid MQTT" -Direction Inbound -Port 1883 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "LocalDroid MQTT WS" -Direction Inbound -Port 9001 -Protocol TCP -Action Allow
```

### 6. Start Server
```powershell
cd server
.\localdroid-server.exe
```

### 7. Login
- URL: ``http://<SERVER_IP>``
- Username: ``admin@localdroid.app``
- Password: ``admin`` (change immediately!)

## Contents

- ``server\`` - Pre-built server binary, web UI, and storage
- ``server\migrations\`` - Database schema files
- ``server\web\dist\`` - Pre-built web frontend
- ``server\storage\agent\`` - Android agent APK
- ``mosquitto\`` - MQTT broker configuration
- ``installers\`` - Third-party installers (if included)
- ``install-windows-offline.ps1`` - Air-gapped / local network installer
- ``install-windows-cloud.ps1`` - Internet-connected (cloud) installer
"@
$readme | Out-File -FilePath "$stagingDir\README.md" -Encoding UTF8
Write-Success "README created"

# ============================================================================
# Create zip package
# ============================================================================
Write-Step "Creating zip package..."

$zipPath = Join-Path (Resolve-Path $OutputPath) "$packageName.zip"
Compress-Archive -Path "$stagingDir\*" -DestinationPath $zipPath -Force

$zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Success "Package created: $zipPath ($zipSize MB)"

# Cleanup staging
Remove-Item -Recurse -Force $stagingDir

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Deployment Package Ready!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Package: $zipPath" -ForegroundColor Cyan
Write-Host "  Size:    $zipSize MB" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Copy this zip to the air-gapped server and extract it." -ForegroundColor White
Write-Host "  Then run install.ps1 as Administrator." -ForegroundColor White
Write-Host ""
