#Requires -RunAsAdministrator
<#
.SYNOPSIS
    LocalDroid MDM Server - Windows OFFLINE Installation Script
.DESCRIPTION
    Installs LocalDroid MDM using local installer files (no internet required after prep).
    Supports resuming from a failed or cancelled installation - re-run at any time to
    pick up where you left off. Completed steps are automatically skipped.
.PARAMETER DownloadInstallers
    Download all required installers to the 'installers' folder (requires internet).
    Run this on an internet-connected machine, then copy the folder to the target.
.PARAMETER Fresh
    Clear all saved progress and start the installation from scratch.
.PARAMETER ResetStep
    Re-run a specific step by name (e.g. -ResetStep web_build).
    Step names: deps, config, database, env, migrations, web_build,
                server_build, apk, mosquitto, startup
.EXAMPLE
    .\install-windows-offline.ps1 -DownloadInstallers
    .\install-windows-offline.ps1
    .\install-windows-offline.ps1 -Fresh
    .\install-windows-offline.ps1 -ResetStep web_build
#>

param(
    [switch]$DownloadInstallers,
    [switch]$Fresh,
    [string]$ResetStep
)

# Script location
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallersDir = Join-Path $ScriptDir "installers"
$serverDir = Join-Path $ScriptDir "server"

# Installer file names and download URLs
$Installers = @{
    PostgreSQL = @{
        FileName = "postgresql-16-windows-x64.exe"
        Url = "https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64.exe"
        DisplayName = "PostgreSQL 16"
    }
    Go = @{
        FileName = "go-windows-amd64.msi"
        Url = "https://go.dev/dl/go1.23.4.windows-amd64.msi"
        DisplayName = "Go 1.23"
    }
    NodeJS = @{
        FileName = "node-lts-x64.msi"
        Url = "https://nodejs.org/dist/v20.18.1/node-v20.18.1-x64.msi"
        DisplayName = "Node.js 20 LTS"
    }
    Mosquitto = @{
        FileName = "mosquitto-windows-x64.exe"
        Url = "https://mosquitto.org/files/binary/win64/mosquitto-2.0.20-install-windows-x64.exe"
        DisplayName = "Mosquitto MQTT"
    }
    Git = @{
        FileName = "git-windows-64.exe"
        Url = "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe"
        DisplayName = "Git"
    }
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step    { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host " [OK] $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err     { param($msg) Write-Host "[ERR] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------
$StateFile = Join-Path $ScriptDir ".install-state.json"

function Get-InstallState {
    if (Test-Path $StateFile) {
        try { return (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch {}
    }
    return [PSCustomObject]@{}
}

function Save-InstallState([PSCustomObject]$State) {
    $State | ConvertTo-Json -Depth 5 | Out-File $StateFile -Encoding UTF8
}

function Get-StateVal([string]$Key, [string]$Default = "") {
    $s = Get-InstallState
    if ($s.PSObject.Properties.Name -contains $Key) { return $s.$Key }
    return $Default
}

function Set-StateVal([string]$Key, [string]$Value) {
    $s = Get-InstallState
    $s | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    Save-InstallState $s
}

function Test-StepDone([string]$Step) {
    return (Get-StateVal "step_$Step") -eq "done"
}

function Set-StepComplete([string]$Step) {
    Set-StateVal "step_$Step" "done"
    Write-Success "Step '$Step' complete"
}

# ---------------------------------------------------------------------------
# Handle -Fresh and -ResetStep
# ---------------------------------------------------------------------------
if ($Fresh -and (Test-Path $StateFile)) {
    Remove-Item $StateFile -Force
    Write-Host "Progress cleared. Starting fresh." -ForegroundColor Yellow
}

if ($ResetStep) {
    $s = Get-InstallState
    $key = "step_$ResetStep"
    if ($s.PSObject.Properties.Name -contains $key) {
        $s.PSObject.Properties.Remove($key)
        Save-InstallState $s
        Write-Host "Step '$ResetStep' reset - will re-run this time." -ForegroundColor Yellow
    } else {
        Write-Warn "Step '$ResetStep' not found in state."
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host @"

  _                    _ ____            _     _
 | |    ___   ___ __ _| |  _ \ _ __ ___ (_) __| |
 | |   / _ \ / __/ _` | | | | | '__/ _ \| |/ _` |
 | |__| (_) | (_| (_| | | |_| | | | (_) | | (_| |
 |_____\___/ \___\__,_|_|____/|_|  \___/|_|\__,_|

  Windows OFFLINE Installation Script

"@ -ForegroundColor Blue

if ((Test-Path $StateFile) -and -not $Fresh) {
    $doneSteps = (Get-InstallState).PSObject.Properties | Where-Object { $_.Value -eq "done" }
    if ($doneSteps) {
        Write-Host "Resuming - $($doneSteps.Count) step(s) already done (will be skipped)." -ForegroundColor Cyan
        Write-Host "  To start over: .\install-windows-offline.ps1 -Fresh" -ForegroundColor Gray
        Write-Host ""
    }
}

# Admin check
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "This script must be run as Administrator!"
    Write-Host "Right-click PowerShell and select 'Run as Administrator'"
    exit 1
}

# Create installers directory if needed
if (-not (Test-Path $InstallersDir)) {
    New-Item -ItemType Directory -Path $InstallersDir -Force | Out-Null
    Write-Success "Created installers directory: $InstallersDir"
}

# ============================================================================
# DOWNLOAD MODE
# ============================================================================
if ($DownloadInstallers) {
    Write-Step "Downloading installers to: $InstallersDir"
    Write-Host ""

    foreach ($key in $Installers.Keys) {
        $installer = $Installers[$key]
        $filePath = Join-Path $InstallersDir $installer.FileName

        if (Test-Path $filePath) {
            Write-Success "$($installer.DisplayName) already downloaded"
        } else {
            Write-Host "Downloading $($installer.DisplayName)..."
            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $installer.Url -OutFile $filePath -UseBasicParsing
                $ProgressPreference = 'Continue'
                Write-Success "Downloaded: $($installer.FileName)"
            } catch {
                Write-Err "Failed to download $($installer.DisplayName): $_"
                Write-Host "  Manual download URL: $($installer.Url)" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Installers downloaded to: $InstallersDir" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Copy the entire 'localdroid' folder (including 'installers') to USB."
    Write-Host "Then run this script again WITHOUT -DownloadInstallers on the target machine."
    Write-Host ""
    exit 0
}

# ============================================================================
# OFFLINE INSTALLATION MODE
# ============================================================================
Write-Step "Checking for installer files in: $InstallersDir"

# Go, Node.js, and Git are only needed to BUILD from source. The air-gap zip
# ships a prebuilt server.exe + web/dist, so those are optional - absence just
# means "no source build available" (which is fine). Only PostgreSQL and
# Mosquitto are hard requirements to run the stack.
$optionalInstallers = @("Go", "NodeJS", "Git")
$missingInstallers = @()
foreach ($key in $Installers.Keys) {
    $installer = $Installers[$key]
    $filePath = Join-Path $InstallersDir $installer.FileName

    # Also check for any file matching the pattern (user may have different version)
    $pattern = switch ($key) {
        "PostgreSQL" { "postgresql*.exe" }
        "Go" { "go*.msi" }
        "NodeJS" { "node*.msi" }
        "Mosquitto" { "mosquitto*.exe" }
        "Git" { "Git*.exe" }
    }
    $foundFile = Get-ChildItem -Path $InstallersDir -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($foundFile) {
        $Installers[$key].ActualFile = $foundFile.FullName
        Write-Success "$($installer.DisplayName): $($foundFile.Name)"
    } elseif (Test-Path $filePath) {
        $Installers[$key].ActualFile = $filePath
        Write-Success "$($installer.DisplayName): $($installer.FileName)"
    } elseif ($optionalInstallers -contains $key) {
        $Installers[$key].ActualFile = $null
        Write-Host "  $($installer.DisplayName): not bundled (only needed for source builds - skipping)" -ForegroundColor Gray
    } else {
        Write-Err "$($installer.DisplayName): NOT FOUND"
        $missingInstallers += $installer.DisplayName
    }
}

if ($missingInstallers.Count -gt 0) {
    Write-Host ""
    Write-Err "Missing installers! Please add these files to: $InstallersDir"
    Write-Host ""
    Write-Host "Option 1: Run with -DownloadInstallers on an internet-connected machine:" -ForegroundColor Yellow
    Write-Host "  .\install-windows-offline.ps1 -DownloadInstallers" -ForegroundColor White
    Write-Host ""
    Write-Host "Option 2: Manually download and place in installers folder:" -ForegroundColor Yellow
    foreach ($key in $Installers.Keys) {
        $installer = $Installers[$key]
        if ($missingInstallers -contains $installer.DisplayName) {
            Write-Host "  $($installer.DisplayName):" -ForegroundColor White
            Write-Host "    $($installer.Url)" -ForegroundColor Gray
        }
    }
    exit 1
}

# ============================================================================
# STEP 1: Install Dependencies
# ============================================================================
if (Test-StepDone "deps") {
    Write-Step "Step 1: Dependencies - already installed, skipping"
} else {
    Write-Step "Step 1: Installing Dependencies"

    # PostgreSQL
    Write-Host "  Checking PostgreSQL..."
    if (Get-Command psql -ErrorAction SilentlyContinue) {
        Write-Success "PostgreSQL already installed"
    } else {
        Write-Host "  Running PostgreSQL installer..."
        Write-Host "  IMPORTANT: Note the password you set! Keep default port 5432." -ForegroundColor Yellow
        $pgInstaller = $Installers["PostgreSQL"].ActualFile
        Start-Process -FilePath $pgInstaller -Wait
        $pgBin = "C:\Program Files\PostgreSQL\16\bin"
        if (Test-Path $pgBin) {
            $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($cp -notlike "*$pgBin*") {
                [Environment]::SetEnvironmentVariable("Path", "$cp;$pgBin", "Machine")
                $env:Path = "$env:Path;$pgBin"
            }
        }
    }

    # Go (only when bundled - source builds. The air-gap zip ships a prebuilt
    # server.exe, so Go is absent and this is skipped.)
    if ($Installers["Go"].ActualFile) {
        Write-Host "  Checking Go..."
        if (Get-Command go -ErrorAction SilentlyContinue) {
            Write-Success "Go already installed"
        } else {
            Write-Host "  Running Go installer..."
            $goInstaller = $Installers["Go"].ActualFile
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$goInstaller`" /quiet /norestart" -Wait
            $goBin = "C:\Program Files\Go\bin"; $goPkg = "$env:USERPROFILE\go\bin"
            $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($cp -notlike "*$goBin*") {
                [Environment]::SetEnvironmentVariable("Path", "$cp;$goBin;$goPkg", "Machine")
                $env:Path = "$env:Path;$goBin;$goPkg"
            }
        }
    }

    # Node.js (only when bundled - source builds. Prebuilt web/dist ships in
    # the air-gap zip, so Node is absent and this is skipped.)
    if ($Installers["NodeJS"].ActualFile) {
        Write-Host "  Checking Node.js..."
        if (Get-Command node -ErrorAction SilentlyContinue) {
            Write-Success "Node.js already installed"
        } else {
            Write-Host "  Running Node.js installer..."
            $nodeInstaller = $Installers["NodeJS"].ActualFile
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$nodeInstaller`" /quiet /norestart" -Wait
        }
    }

    # Mosquitto
    Write-Host "  Checking Mosquitto..."
    if (Test-Path "C:\Program Files\mosquitto\mosquitto.exe") {
        Write-Success "Mosquitto already installed"
    } else {
        Write-Host "  Running Mosquitto installer..."
        $mqInstaller = $Installers["Mosquitto"].ActualFile
        Start-Process -FilePath $mqInstaller -ArgumentList "/S" -Wait
        $mqBin = "C:\Program Files\mosquitto"
        $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($cp -notlike "*$mqBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$cp;$mqBin", "Machine")
            $env:Path = "$env:Path;$mqBin"
        }
    }

    # Git (only when bundled - source builds; not needed for a prebuilt install)
    if ($Installers["Git"].ActualFile) {
        Write-Host "  Checking Git..."
        if (Get-Command git -ErrorAction SilentlyContinue) {
            Write-Success "Git already installed"
        } else {
            Write-Host "  Running Git installer..."
            $gitInstaller = $Installers["Git"].ActualFile
            Start-Process -FilePath $gitInstaller -ArgumentList "/VERYSILENT /NORESTART" -Wait
        }
    }

    Set-StepComplete "deps"

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  Dependencies installed. RESTART PowerShell as Administrator" -ForegroundColor Yellow
    Write-Host "  then run this script again to continue."                     -ForegroundColor Yellow
    Write-Host "  Progress has been saved - completed steps will be skipped." -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# ============================================================================
# STEP 2: Verify Tools
# ============================================================================
Write-Step "Step 2: Verifying Tools"

$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [Environment]::GetEnvironmentVariable("Path", "User")

$knownPaths = @{
    "psql" = "C:\Program Files\PostgreSQL\16\bin\psql.exe"
    "go"   = "C:\Program Files\Go\bin\go.exe"
    "node" = "C:\Program Files\nodejs\node.exe"
    "npm"  = "C:\Program Files\nodejs\npm.cmd"
}

# psql is always required. go/node/npm are only required when we'll build from
# source - the air-gap zip ships a prebuilt server.exe + web/dist, so they're
# not needed there. Decide based on whether the prebuilt artifacts are present.
$prebuiltServer = Test-Path (Join-Path $serverDir "localdroid-server.exe")
$prebuiltWeb    = Test-Path (Join-Path $serverDir "web\dist\index.html")
$requiredTools  = @("psql")
if (-not ($prebuiltServer -and $prebuiltWeb)) {
    $requiredTools += @("go", "node", "npm")
    Write-Host "  (no prebuilt binaries - will build from source, so Go/Node are required)" -ForegroundColor Gray
} else {
    Write-Host "  Prebuilt server.exe + web/dist present - Go/Node not required." -ForegroundColor Gray
}

$allFound = $true
foreach ($tool in $requiredTools) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Success "$tool found"
    } elseif ($knownPaths.ContainsKey($tool) -and (Test-Path $knownPaths[$tool])) {
        $dir = Split-Path $knownPaths[$tool]
        if ($env:Path -notlike "*$dir*") { $env:Path = "$dir;$env:Path" }
        Write-Success "$tool found at known location"
    } else {
        Write-Err "$tool not found! Close ALL PowerShell windows, reopen as Admin, and re-run."
        $allFound = $false
    }
}
if (-not $allFound) { exit 1 }

# ============================================================================
# STEP 3: Collect Configuration (saved so re-run doesn't re-prompt)
# ============================================================================
Write-Step "Step 3: Server Configuration"

$serverDir = Join-Path $ScriptDir "server"

if (Test-StepDone "config") {
    $serverIP         = Get-StateVal "cfg_serverIP"
    $serverPort       = Get-StateVal "cfg_serverPort"
    $mqttPort         = Get-StateVal "cfg_mqttPort"
    $mqttExternalHost = Get-StateVal "cfg_mqttExternalHost"
    $isAirGapped      = (Get-StateVal "cfg_isAirGapped") -eq "true"
    $adminEmail       = Get-StateVal "cfg_adminEmail"
    $adminPasswordPlain = Get-StateVal "cfg_adminPassword"
    Write-Success "Loaded saved configuration (server=$serverIP`:$serverPort)"
} else {
    Write-Host ""
    Write-Host "Deployment Mode:" -ForegroundColor Yellow
    Write-Host "  1. Air-Gapped / Local Network"
    Write-Host "  2. Internet Connected (cloud)"
    $deployMode = Read-Host "Select (1 or 2, Enter for 1)"
    if ([string]::IsNullOrEmpty($deployMode)) { $deployMode = "1" }
    $isAirGapped = ($deployMode -eq "1")

    $localIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } |
        Select-Object -First 1).IPAddress

    Write-Host "Detected local IP: $localIP"
    $serverIP = Read-Host "Server IP (Enter for $localIP)"
    if ([string]::IsNullOrEmpty($serverIP)) { $serverIP = $localIP }

    $serverPort = Read-Host "HTTP port (Enter for 80)"
    if ([string]::IsNullOrEmpty($serverPort)) { $serverPort = "80" }

    $mqttPort = Read-Host "MQTT port (Enter for 1883)"
    if ([string]::IsNullOrEmpty($mqttPort)) { $mqttPort = "1883" }

    if ($isAirGapped) {
        $mqttExternalHost = $serverIP
    } else {
        $mqttExternalHost = Read-Host "MQTT hostname for remote devices (Enter for $serverIP)"
        if ([string]::IsNullOrEmpty($mqttExternalHost)) { $mqttExternalHost = $serverIP }
    }

    Write-Host ""
    Write-Host "Administrator Login:" -ForegroundColor Yellow
    Write-Host "  Initial admin user for the MDM web UI. The server seeds this on"
    Write-Host "  first boot via LOCALDROID_ADMIN_* env vars in .env, then bcrypt-"
    Write-Host "  hashes the password."
    $adminEmail = Read-Host "Admin email (Enter for admin@localdroid.app)"
    if ([string]::IsNullOrEmpty($adminEmail)) { $adminEmail = "admin@localdroid.app" }
    while ($true) {
        $secure1 = Read-Host "Admin password (min 8 chars)" -AsSecureString
        $adminPasswordPlain = [System.Net.NetworkCredential]::new("", $secure1).Password
        if ($adminPasswordPlain.Length -lt 8) {
            Write-Host "  Password must be at least 8 characters. Try again." -ForegroundColor Yellow
            continue
        }
        $secure2 = Read-Host "Confirm admin password" -AsSecureString
        $confirm = [System.Net.NetworkCredential]::new("", $secure2).Password
        if ($adminPasswordPlain -ne $confirm) {
            Write-Host "  Passwords don't match. Try again." -ForegroundColor Yellow
            continue
        }
        break
    }
    Write-Host "  Admin login configured: $adminEmail" -ForegroundColor Green

    Set-StateVal "cfg_serverIP"         $serverIP
    Set-StateVal "cfg_serverPort"       $serverPort
    Set-StateVal "cfg_mqttPort"         $mqttPort
    Set-StateVal "cfg_mqttExternalHost" $mqttExternalHost
    Set-StateVal "cfg_isAirGapped"      ($isAirGapped.ToString().ToLower())
    Set-StateVal "cfg_adminEmail"       $adminEmail
    Set-StateVal "cfg_adminPassword"    $adminPasswordPlain
    Set-StepComplete "config"
}

# ============================================================================
# STEP 4: PostgreSQL Database Setup
# ============================================================================
Write-Step "Step 4: PostgreSQL Database"

if (Test-StepDone "database") {
    Write-Success "Database already configured, skipping"
    $envPath = Join-Path $serverDir ".env"
    if (Test-Path $envPath) {
        $pgPasswordPlain = (Get-Content $envPath |
            Where-Object { $_ -match "^DB_PASSWORD=" }) -replace "^DB_PASSWORD=", ""
    } else {
        $pgPasswordPlain = Get-StateVal "cfg_pgPassword"
    }
    $env:PGPASSWORD = $pgPasswordPlain
} else {
    Write-Host ""
    Write-Host "Enter the PostgreSQL 'postgres' superuser password." -ForegroundColor Yellow
    $pgSec = Read-Host "PostgreSQL 'postgres' password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pgSec)
    $pgPasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    $env:PGPASSWORD = $pgPasswordPlain

    Write-Host "Testing connection..."
    psql -U postgres -h localhost -c "SELECT 1;" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Cannot connect to PostgreSQL. Verify the password and that the service is running."
        Write-Host "  Open Services (services.msc) and check 'postgresql-x64-16' is Running." -ForegroundColor Yellow
        exit 1
    }
    Write-Success "PostgreSQL connection OK"

    $dbExists = psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname='localdroid'" 2>$null
    if ($dbExists -eq "1") {
        Write-Warn "Database 'localdroid' already exists"
    } else {
        psql -U postgres -h localhost -c "CREATE DATABASE localdroid;" 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to create database"; exit 1 }
        Write-Success "Database 'localdroid' created"
    }

    Set-StateVal "cfg_pgPassword" $pgPasswordPlain
    Set-StepComplete "database"
}

# ============================================================================
# STEP 5: Create .env Configuration File
# ============================================================================
Write-Step "Step 5: Configuration File"

$envPath = Join-Path $serverDir ".env"

if (Test-StepDone "env") {
    Write-Success "Configuration file already created, skipping"
} else {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes); $rng.Dispose()
    $jwtSecret = [Convert]::ToBase64String($bytes)
    $deployModeStr = if ($isAirGapped) { "airgapped" } else { "cloud" }

    if (-not (Test-Path $serverDir)) { New-Item -ItemType Directory -Path $serverDir -Force | Out-Null }

    @"
# LocalDroid Server Configuration
# Generated by install-windows-offline.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

SERVER_HOST=0.0.0.0
SERVER_PORT=$serverPort

DB_HOST=localhost
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$pgPasswordPlain
DB_NAME=localdroid
DB_SSLMODE=disable

MQTT_HOST=localhost
MQTT_PORT=$mqttPort
MQTT_EXTERNAL_HOST=$mqttExternalHost

JWT_SECRET=$jwtSecret
JWT_EXPIRES_HOURS=24

EXTERNAL_URL=http://${serverIP}:${serverPort}
DEPLOYMENT_MODE=$deployModeStr

STORAGE_PATH=./storage
APK_SIGNATURE_CHECKSUM=

# Licensing - the LocalDroid license-authority public key ships as the
# default so a signed license.lic verifies out of the box on air-gapped
# servers (the key is public: it can only VERIFY licenses, never create
# them). Point LOCALDROID_LICENSE_FILE at your license.lic to auto-activate.
LICENSE_SERVER_URL=
LICENSE_PUBLIC_KEY=woL+6yGOhnbu9E+iALVqMzIx1Uez7Rk2kP8pEXIQDDc=

# Administrator credentials - seeded into the users table on first boot.
# Setting LOCALDROID_ADMIN_PASSWORD here is authoritative: changing it
# resets the admin password on the next restart. Comment both lines out
# after first login if you prefer to manage the admin from the UI.
LOCALDROID_ADMIN_EMAIL=$adminEmail
LOCALDROID_ADMIN_PASSWORD=$adminPasswordPlain
"@ | Out-File -FilePath $envPath -Encoding ASCII

    Set-StepComplete "env"
    Write-Success "Configuration saved: $envPath"
}

# ============================================================================
# STEP 6: Database Migrations
# ============================================================================
Write-Step "Step 6: Database Migrations"

if (Test-StepDone "migrations") {
    Write-Success "Migrations already applied, skipping"
} else {
    $migrationsDir = Join-Path $serverDir "migrations"
    if (Test-Path $migrationsDir) {
        $migrations = Get-ChildItem -Path $migrationsDir -Filter "*.sql" | Sort-Object Name
        foreach ($migration in $migrations) {
            Write-Host "  Applying: $($migration.Name)" -ForegroundColor Gray
            cmd /c "psql -U postgres -h localhost -d localdroid -f `"$($migration.FullName)`" 2>nul"
        }
        Set-StepComplete "migrations"
        Write-Success "Migrations completed"
    } else {
        Write-Warn "Migrations directory not found: $migrationsDir"
        Set-StepComplete "migrations"
    }
}

# ============================================================================
# STEP 7: Web UI  (use prebuilt if present, else build from source)
# ============================================================================
Write-Step "Step 7: Web UI"

$webDir = Join-Path $ScriptDir "web"
$distDst = Join-Path $serverDir "web\dist"

if (Test-StepDone "web_build") {
    Write-Success "Web UI already built, skipping"
} elseif (Test-Path (Join-Path $distDst "index.html")) {
    # Prebuilt web UI shipped in the bundle (source-free install) - no Node,
    # no web/ source needed. This is the normal path for the air-gap zip.
    Set-StepComplete "web_build"
    Write-Success "Prebuilt web UI found at server\web\dist - skipping build"
} else {
    if (-not (Test-Path $webDir)) { Write-Err "Web directory not found: $webDir (and no prebuilt server\web\dist)"; exit 1 }

    Push-Location $webDir
    try {
        Write-Host "  Installing npm dependencies..."
        npm install
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "npm install failed, trying clean install..."
            Remove-Item -Recurse -Force node_modules -ErrorAction SilentlyContinue
            Remove-Item -Force package-lock.json -ErrorAction SilentlyContinue
            npm install
            if ($LASTEXITCODE -ne 0) { throw "npm install failed after clean retry" }
        }
        Write-Host "  Building production bundle..."
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed" }
    } catch {
        Pop-Location
        Write-Err "Web UI build failed: $_"
        Write-Host "  Re-run: .\install-windows-offline.ps1 -ResetStep web_build" -ForegroundColor Yellow
        exit 1
    }
    Pop-Location

    $distSrc = Join-Path $webDir "dist"
    $distDst = Join-Path $serverDir "web\dist"
    if (Test-Path $distSrc) {
        if (Test-Path $distDst) { Remove-Item -Path $distDst -Recurse -Force }
        New-Item -ItemType Directory -Path $distDst -Force | Out-Null
        Copy-Item -Path "$distSrc\*" -Destination $distDst -Recurse -Force -ErrorAction Stop
        Set-StepComplete "web_build"
        Write-Success "Web UI built and deployed to server\web\dist"
    } else {
        Write-Err "Build output not found at: $distSrc"
        exit 1
    }
}

# ============================================================================
# STEP 8: Go Server  (use prebuilt if present, else build from source)
# ============================================================================
Write-Step "Step 8: Go Server"

$serverExe = Join-Path $serverDir "localdroid-server.exe"

if (Test-StepDone "server_build") {
    Write-Success "Server already built, skipping"
} elseif (Test-Path $serverExe) {
    # Prebuilt, cross-compiled server.exe shipped in the bundle (source-free
    # install) - no Go, no server/ source needed. Normal path for the air-gap zip.
    Set-StepComplete "server_build"
    Write-Success "Prebuilt localdroid-server.exe found - skipping build"
} else {
    if (-not (Test-Path $serverDir)) { Write-Err "Server directory not found: $serverDir (and no prebuilt localdroid-server.exe)"; exit 1 }

    Push-Location $serverDir
    try {
        Write-Host "  Downloading Go module dependencies..."
        go mod download

        Write-Host "  Compiling server..."
        go build -o localdroid-server.exe ./cmd/server
        if ($LASTEXITCODE -ne 0) { throw "go build failed" }
    } catch {
        Pop-Location
        Write-Err "Server build failed: $_"
        Write-Host "  Re-run: .\install-windows-offline.ps1 -ResetStep server_build" -ForegroundColor Yellow
        exit 1
    }
    Pop-Location

    if (Test-Path $serverExe) {
        Set-StepComplete "server_build"
        Write-Success "Server built: localdroid-server.exe"
    } else {
        Write-Err "Build reported success but executable not found"
        exit 1
    }
}

# ============================================================================
# STEP 9: Android Agent APK
# ============================================================================
Write-Step "Step 9: Android Agent APK"

$agentStorageDir = Join-Path $serverDir "storage\agent"
$apkDest = Join-Path $agentStorageDir "localdroid-agent.apk"

if (Test-StepDone "apk") {
    Write-Success "Android APK already installed, skipping"
} else {
    New-Item -ItemType Directory -Path $agentStorageDir -Force | Out-Null

    # Offline installer - local files only. seed/ is the canonical bundle
    # layout; releases/ stays for backwards compat with older deployments.
    $localApk = @(
        (Join-Path $ScriptDir "seed\localdroid-agent.apk"),
        (Join-Path $ScriptDir "releases\localdroid-agent.apk"),
        (Join-Path $ScriptDir "releases\localdroid-agent-v1.0.0.apk")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($localApk) {
        Copy-Item $localApk $apkDest -Force
        Set-StepComplete "apk"
        Write-Success "Android APK copied from $localApk"
    } else {
        Write-Warn "No Android APK found in seed\ or releases\ folder."
        Write-Host "  Drop localdroid-agent.apk at one of:" -ForegroundColor Yellow
        Write-Host "    $ScriptDir\seed\localdroid-agent.apk" -ForegroundColor Yellow
        Write-Host "    $apkDest" -ForegroundColor Yellow
        Write-Host "  Then re-run this script." -ForegroundColor Yellow
        Set-StepComplete "apk"
    }
}

# STEP 9b: APK signing-cert checksum (Zero-Touch enrollment verification).
# Air-gapped boxes won't have Android build-tools - the sidecar file is the
# REQUIRED source here. build-native-bundle.sh produces it; if it's missing,
# we can't recover and Zero-Touch will fail.
if (Test-Path $apkDest) {
    $apkChecksum = ""
    $sidecarCandidates = @(
        (Join-Path $ScriptDir "seed\localdroid-agent.apk.cert-sha256"),
        (Join-Path $ScriptDir "releases\localdroid-agent.apk.cert-sha256")
    )
    foreach ($s in $sidecarCandidates) {
        if (Test-Path $s) {
            $apkChecksum = (Get-Content $s -Raw).Trim()
            Write-Host "  APK checksum loaded from sidecar: $(Split-Path -Leaf $s)"
            break
        }
    }
    if ($apkChecksum) {
        $currentLine = (Get-Content $envPath) | Where-Object { $_ -match '^APK_SIGNATURE_CHECKSUM=' } | Select-Object -First 1
        $currentChecksum = if ($currentLine) { ($currentLine -split '=', 2)[1] } else { "" }
        if ($currentChecksum -ne $apkChecksum) {
            (Get-Content $envPath) -replace '^APK_SIGNATURE_CHECKSUM=.*', "APK_SIGNATURE_CHECKSUM=$apkChecksum" |
                Set-Content $envPath -Encoding ASCII
            Write-Success "APK signing-cert checksum set: $apkChecksum"
        } else {
            Write-Success "APK signing-cert checksum already correct"
        }
    } else {
        Write-Warn "No APK signing-cert sidecar (localdroid-agent.apk.cert-sha256) found."
        Write-Host "    Zero-Touch enrollment will fail until APK_SIGNATURE_CHECKSUM is set in:" -ForegroundColor Yellow
        Write-Host "      $envPath" -ForegroundColor Yellow
        Write-Host "    Re-run scripts/build-native-bundle.sh (with apksigner installed)" -ForegroundColor Yellow
        Write-Host "    to regenerate the sidecar." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 9c: Baked-in customer license (optional)
# ============================================================================
# If the bundle shipped a license.lic, install it next to the server and point
# LOCALDROID_LICENSE_FILE at it so the server auto-activates on first start -
# the customer never pastes a license. Mirrors install.sh STEP 9b (Linux).
Write-Step "Step 9c: Customer License"
if (Test-StepDone "license_seed") {
    Write-Success "License already installed, skipping"
} else {
    $bundledLicense = Join-Path $ScriptDir "license.lic"
    if (Test-Path $bundledLicense) {
        $licenseDest = Join-Path $serverDir "license.lic"
        Copy-Item $bundledLicense $licenseDest -Force
        if (Select-String -Path $envPath -Pattern '^LOCALDROID_LICENSE_FILE=' -Quiet) {
            (Get-Content $envPath) -replace '^LOCALDROID_LICENSE_FILE=.*', "LOCALDROID_LICENSE_FILE=$licenseDest" |
                Set-Content $envPath -Encoding ASCII
        } else {
            Add-Content -Path $envPath -Value "LOCALDROID_LICENSE_FILE=$licenseDest" -Encoding ASCII
        }
        Write-Success "License staged - MDM will auto-activate on first start"
    } else {
        Write-Host "  No bundled license.lic - MDM starts unlicensed (activate later under Settings -> License)." -ForegroundColor Gray
    }
    Set-StepComplete "license_seed"
}

# ============================================================================
# STEP 10: Configure Mosquitto
# ============================================================================
Write-Step "Step 10: Configure Mosquitto"

if (Test-StepDone "mosquitto") {
    Write-Success "Mosquitto already configured, skipping"
} else {
    $mqConfPath = "C:\Program Files\mosquitto\mosquitto.conf"
    if (Test-Path "C:\Program Files\mosquitto") {
        @"
# LocalDroid Mosquitto Configuration
listener $mqttPort
allow_anonymous true

# Resource limits — a runaway client can't exhaust the broker or flood the
# network. Size max_connections to device count plus headroom.
max_connections 1024
max_queued_messages 200
max_inflight_messages 20
message_size_limit 10485760
max_keepalive 120
"@ | Out-File -FilePath $mqConfPath -Encoding UTF8
        Set-StepComplete "mosquitto"
        Write-Success "Mosquitto configured on port $mqttPort"
    } else {
        Write-Warn "Mosquitto not found at default path - configure mosquitto.conf manually"
        Set-StepComplete "mosquitto"
    }
}

# ============================================================================
# STEP 11: Create Startup Script
# ============================================================================
Write-Step "Step 11: Startup Script"

if (Test-StepDone "startup") {
    Write-Success "Startup script already created, skipping"
} else {
    @"
@echo off
echo Starting LocalDroid MDM Server...
echo.

tasklist /FI "IMAGENAME eq mosquitto.exe" 2>NUL | find /I "mosquitto.exe" >NUL
if "%ERRORLEVEL%"=="1" (
    echo Starting Mosquitto MQTT Broker...
    start /B "" "C:\Program Files\mosquitto\mosquitto.exe" -c "C:\Program Files\mosquitto\mosquitto.conf"
    timeout /t 2 /nobreak >nul
)

cd /d "%~dp0server"
echo Server running at http://${serverIP}:${serverPort}
echo Press Ctrl+C to stop
echo.
localdroid-server.exe
pause
"@ | Out-File -FilePath (Join-Path $ScriptDir "start-server.bat") -Encoding ASCII

    Set-StepComplete "startup"
    Write-Success "Created: start-server.bat"
}

# ============================================================================
# STEP 12: Remote control - firewall + TURN guidance
# ============================================================================
# Windows VNC relays through the Go server (server port only). Android WebRTC
# remote control over the internet needs a TURN relay (coturn), which has no
# native Windows package. Open the firewall and document the relay options.
# An air-gapped LAN install usually doesn't need TURN at all (host candidates).
Write-Step "Step 12: Remote Control Firewall"

if (Test-StepDone "remote_firewall") {
    Write-Success "Remote-control firewall already configured, skipping"
} else {
    $fwRules = @(
        @{ Name = "LocalDroid Server $serverPort/tcp"; Port = $serverPort; Proto = "TCP" },
        @{ Name = "LocalDroid MQTT $mqttPort/tcp";      Port = $mqttPort;    Proto = "TCP" },
        @{ Name = "LocalDroid TURN 3478/tcp";          Port = 3478;         Proto = "TCP" },
        @{ Name = "LocalDroid TURN 3478/udp";          Port = 3478;         Proto = "UDP" }
    )
    foreach ($r in $fwRules) {
        try {
            if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
                    -Protocol $r.Proto -LocalPort $r.Port -ErrorAction Stop | Out-Null
            }
            Write-Success "Firewall: allowed $($r.Proto) $($r.Port)"
        } catch {
            Write-Warn "Could not add firewall rule '$($r.Name)' (run as Administrator): $_"
        }
    }
    try {
        $relayName = "LocalDroid TURN media 49152-49200/udp"
        if (-not (Get-NetFirewallRule -DisplayName $relayName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $relayName -Direction Inbound -Action Allow `
                -Protocol UDP -LocalPort "49152-49200" -ErrorAction Stop | Out-Null
        }
        Write-Success "Firewall: allowed UDP 49152-49200 (TURN media)"
    } catch {
        Write-Warn "Could not add TURN media firewall rule (run as Administrator): $_"
    }

    Write-Host ""
    Write-Host "Android remote control over the internet needs a TURN relay (coturn)." -ForegroundColor Yellow
    Write-Host "coturn has no native Windows package. Provide one on a Linux box/VPS" -ForegroundColor Yellow
    Write-Host "(apt install coturn):" -ForegroundColor Yellow
    Write-Host '      turnserver -n --use-auth-secret --static-auth-secret=localdroid_turn_secret_2024 \' -ForegroundColor Gray
    Write-Host "        --realm=$serverIP --min-port=49152 --max-port=49200 --external-ip=<PUBLIC_IP>" -ForegroundColor Gray
    Write-Host "  Keep the secret as 'localdroid_turn_secret_2024' to match the clients." -ForegroundColor Yellow
    Write-Host "Windows-device VNC works with no TURN server." -ForegroundColor Green
    Write-Host ""
    Set-StepComplete "remote_firewall"
}

# ============================================================================
# COMPLETE
# ============================================================================
$env:PGPASSWORD = ""

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  LocalDroid MDM Server Installation Complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Installation : $ScriptDir" -ForegroundColor Cyan
Write-Host "Web UI       : http://${serverIP}:${serverPort}" -ForegroundColor Cyan
Write-Host "Login        : admin@localdroid.app / admin" -ForegroundColor Cyan
Write-Host ""
Write-Host "Start the server:" -ForegroundColor Yellow
Write-Host "  Double-click: $(Join-Path $ScriptDir 'start-server.bat')"
Write-Host ""
Write-Host "Open firewall ports if needed: $serverPort (HTTP), $mqttPort (MQTT)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Progress file: $StateFile" -ForegroundColor Gray
Write-Host "Re-run a step: .\install-windows-offline.ps1 -ResetStep <step_name>" -ForegroundColor Gray
Write-Host "Start fresh  : .\install-windows-offline.ps1 -Fresh" -ForegroundColor Gray
Write-Host ""
