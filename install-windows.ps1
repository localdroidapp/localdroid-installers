#Requires -RunAsAdministrator
<#
.SYNOPSIS
    LocalDroid MDM Server - Windows Installation Script
.DESCRIPTION
    Installs all required dependencies and sets up LocalDroid MDM on Windows.
    Supports resuming from a failed or cancelled installation - re-run at any time
    to pick up where you left off. Completed steps are automatically skipped.
.PARAMETER Fresh
    Clear all saved progress and start the installation from scratch.
.PARAMETER ResetStep
    Re-run a specific step by name (e.g. -ResetStep web_build).
    Step names: deps, config, clone, database, env, migrations, web_build,
                server_build, apk, mosquitto, startup
.EXAMPLE
    .\install-windows.ps1
    .\install-windows.ps1 -Fresh
    .\install-windows.ps1 -ResetStep web_build
.NOTES
    Requires Windows 10/11 with winget (App Installer) available.
#>

param(
    [switch]$Fresh,
    [string]$ResetStep
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile = Join-Path $ScriptDir ".install-state.json"

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
# Handle -Fresh and -ResetStep flags
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
        Write-Warn "Step '$ResetStep' not found in state (may not have run yet)."
    }
}

# ---------------------------------------------------------------------------
# Banner + Resume notice
# ---------------------------------------------------------------------------
Write-Host @"

  _                    _ ____            _     _ 
 | |    ___   ___ __ _| |  _ \ _ __ ___ (_) __| |
 | |   / _ \ / __/ _` | | | | | '__/ _ \| |/ _` |
 | |__| (_) | (_| (_| | | |_| | | | (_) | | (_| |
 |_____\___/ \___\__,_|_|____/|_|  \___/|_|\__,_|

  Windows Server Installation Script

"@ -ForegroundColor Blue

if ((Test-Path $StateFile) -and -not $Fresh) {
    $doneSteps = (Get-InstallState).PSObject.Properties | Where-Object { $_.Value -eq "done" }
    if ($doneSteps) {
        Write-Host "Resuming - $($doneSteps.Count) step(s) already done (will be skipped)." -ForegroundColor Cyan
        Write-Host "  To start over: .\install-windows.ps1 -Fresh" -ForegroundColor Gray
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

# ============================================================================
# STEP 1: Install Dependencies (PostgreSQL, Go, Node, Mosquitto, Git)
# ============================================================================
if (Test-StepDone "deps") {
    Write-Step "Step 1: Dependencies - already installed, skipping"
} else {
    Write-Step "Step 1: Installing Dependencies"

    # winget check
    try { $wv = winget --version 2>$null; Write-Success "winget: $wv" } catch {
        Write-Err "winget not found. Install 'App Installer' from the Microsoft Store."
        exit 1
    }

    # PostgreSQL
    Write-Host "  Checking PostgreSQL..."
    if (Get-Command psql -ErrorAction SilentlyContinue) {
        Write-Success "PostgreSQL already installed"
    } else {
        Write-Host "  Installing PostgreSQL 16..."
        winget install -e --id PostgreSQL.PostgreSQL.16 --accept-source-agreements --accept-package-agreements
        $pgBin = "C:\Program Files\PostgreSQL\16\bin"
        if (Test-Path $pgBin) {
            $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($cp -notlike "*$pgBin*") {
                [Environment]::SetEnvironmentVariable("Path", "$cp;$pgBin", "Machine")
                $env:Path = "$env:Path;$pgBin"
            }
        }
    }

    # Go
    Write-Host "  Checking Go..."
    if (Get-Command go -ErrorAction SilentlyContinue) { Write-Success "Go already installed" } else {
        Write-Host "  Installing Go..."
        winget install -e --id GoLang.Go --accept-source-agreements --accept-package-agreements
        $goBin = "C:\Program Files\Go\bin"; $goPkg = "$env:USERPROFILE\go\bin"
        $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($cp -notlike "*$goBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$cp;$goBin;$goPkg", "Machine")
            $env:Path = "$env:Path;$goBin;$goPkg"
        }
    }

    # Node.js
    Write-Host "  Checking Node.js..."
    if (Get-Command node -ErrorAction SilentlyContinue) { Write-Success "Node.js already installed" } else {
        Write-Host "  Installing Node.js LTS..."
        winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
    }

    # Mosquitto
    Write-Host "  Checking Mosquitto..."
    if (Test-Path "C:\Program Files\mosquitto\mosquitto.exe") {
        Write-Success "Mosquitto already installed"
    } else {
        Write-Host "  Installing Mosquitto..."
        winget install -e --id EclipseFoundation.Mosquitto --accept-source-agreements --accept-package-agreements
        $mqBin = "C:\Program Files\mosquitto"
        $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($cp -notlike "*$mqBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$cp;$mqBin", "Machine")
            $env:Path = "$env:Path;$mqBin"
        }
    }

    # Git
    Write-Host "  Checking Git..."
    if (Get-Command git -ErrorAction SilentlyContinue) { Write-Success "Git already installed" } else {
        Write-Host "  Installing Git..."
        winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements
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
# STEP 2: Verify Tools in PATH
# ============================================================================
Write-Step "Step 2: Verifying Tools"

# Refresh PATH from registry
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [Environment]::GetEnvironmentVariable("Path", "User")

$knownPaths = @{
    "psql" = "C:\Program Files\PostgreSQL\16\bin\psql.exe"
    "go"   = "C:\Program Files\Go\bin\go.exe"
    "node" = "C:\Program Files\nodejs\node.exe"
    "npm"  = "C:\Program Files\nodejs\npm.cmd"
}

$allFound = $true
foreach ($tool in @("psql", "go", "node", "npm")) {
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

if (Test-StepDone "config") {
    $serverIP         = Get-StateVal "cfg_serverIP"
    $serverPort       = Get-StateVal "cfg_serverPort"
    $mqttPort         = Get-StateVal "cfg_mqttPort"
    $mqttExternalHost = Get-StateVal "cfg_mqttExternalHost"
    $isAirGapped      = (Get-StateVal "cfg_isAirGapped") -eq "true"
    $installDir       = Get-StateVal "cfg_installDir"
    $licenseServerUrl = Get-StateVal "cfg_licenseServerUrl"
    $adminEmail       = Get-StateVal "cfg_adminEmail"
    $adminPasswordPlain = Get-StateVal "cfg_adminPassword"
    Write-Success "Loaded saved configuration (server=$serverIP`:$serverPort, dir=$installDir)"
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

    $installDir = Read-Host "Installation directory (Enter for C:\LocalDroid)"
    if ([string]::IsNullOrEmpty($installDir)) { $installDir = "C:\LocalDroid" }

    Write-Host ""
    Write-Host "Licensing:" -ForegroundColor Yellow
    # Portal at localdroid.app is the canonical license authority. Override
    # by setting $env:LICENSE_SERVER_URL before running (empty string for
    # fully air-gapped operation).
    if ($null -ne $env:LICENSE_SERVER_URL) {
        $licenseServerUrl = $env:LICENSE_SERVER_URL
    } else {
        $licenseServerUrl = "https://localdroid.app"
    }
    if ([string]::IsNullOrEmpty($licenseServerUrl)) {
        Write-Host "  License authority: <none> - air-gapped mode" -ForegroundColor Yellow
    } else {
        Write-Host "  License authority: $licenseServerUrl" -ForegroundColor Green
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
    Set-StateVal "cfg_installDir"       $installDir
    Set-StateVal "cfg_licenseServerUrl" $licenseServerUrl
    Set-StateVal "cfg_adminEmail"       $adminEmail
    Set-StateVal "cfg_adminPassword"    $adminPasswordPlain
    Set-StepComplete "config"
}

$serverDir = Join-Path $installDir "server"

# ============================================================================
# STEP 4: Clone or Update Repository
# ============================================================================
Write-Step "Step 4: Repository"

if (Test-StepDone "clone") {
    Write-Success "Repository already set up, skipping"
} else {
    if (Test-Path (Join-Path $installDir "server")) {
        Write-Host "Updating existing installation at $installDir ..."
        Push-Location $installDir; git pull 2>$null; Pop-Location
    } else {
        Write-Host "Cloning LocalDroid to $installDir ..."
        # The source repo is private (auth required). Prefer extracting the
        # prebuilt customer bundle into $installDir before running this script;
        # the git-clone fallback only works for developers with repo access.
        git clone https://github.com/zherrin85/localdroid.git $installDir
        if ($LASTEXITCODE -ne 0) {
            Write-Err "git clone failed — extract the LocalDroid customer bundle into $installDir before running this script."
            exit 1
        }
    }
    Set-StepComplete "clone"
}

# ============================================================================
# STEP 5: PostgreSQL Database Setup
# ============================================================================
Write-Step "Step 5: PostgreSQL Database"

if (Test-StepDone "database") {
    Write-Success "Database already configured, skipping"
    # Load PG password for use in .env step (try .env first, then state)
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
    Write-Host "(This is the password you set during PostgreSQL installation)" -ForegroundColor Gray
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

    # Create database (idempotent)
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
# STEP 6: Create .env Configuration File
# ============================================================================
Write-Step "Step 6: Configuration File"

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
# Generated by install-windows.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

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

# Licensing - leave empty to run in unlimited free mode. To enable license
# verification, set LICENSE_SERVER_URL and LICENSE_PUBLIC_KEY (auto-fetched
# below if the server is reachable).
LICENSE_SERVER_URL=$licenseServerUrl
LICENSE_PUBLIC_KEY=

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
# STEP 6b: License public key bootstrap
# ============================================================================
Write-Step "Step 6b: License Public Key"
if (Test-StepDone "license_bootstrap") {
    Write-Success "License public key already configured, skipping"
} elseif ([string]::IsNullOrWhiteSpace($licenseServerUrl)) {
    Write-Host "  No license server configured - MDM will run in unlimited free mode."
    Set-StepComplete "license_bootstrap"
} else {
    Write-Host "  Fetching public key from $licenseServerUrl/api/public-key ..."
    try {
        $pkResp = Invoke-RestMethod -Uri "$licenseServerUrl/api/public-key" -TimeoutSec 10 -ErrorAction Stop
        if ($pkResp.public_key) {
            (Get-Content $envPath) -replace '^LICENSE_PUBLIC_KEY=.*', "LICENSE_PUBLIC_KEY=$($pkResp.public_key)" |
                Set-Content $envPath -Encoding ASCII
            Write-Success "License public key written to $envPath"
            Set-StepComplete "license_bootstrap"
        } else {
            Write-Host "  Response did not contain a public_key field - skipping."
        }
    } catch {
        Write-Host "  Could not reach $licenseServerUrl/api/public-key - skipping."
        Write-Host "  The MDM will start in unlimited free mode. To enable license"
        Write-Host "  verification later, set LICENSE_PUBLIC_KEY in $envPath."
    }
}

# ============================================================================
# STEP 7: (reserved — APK signing-cert checksum is now derived in STEP 11
# AFTER the APK is seeded, so we know the file is in place.)
# ============================================================================

# ============================================================================
# STEP 8: Database Migrations
# ============================================================================
Write-Step "Step 8: Database Migrations"

if (Test-StepDone "migrations") {
    Write-Success "Migrations already applied, skipping"
} else {
    $migrationsDir = Join-Path $serverDir "migrations"
    if (Test-Path $migrationsDir) {
        $migrations = Get-ChildItem -Path $migrationsDir -Filter "*.sql" | Sort-Object Name
        foreach ($migration in $migrations) {
            Write-Host "  Applying: $($migration.Name)" -ForegroundColor Gray
            cmd /c "psql -U postgres -h localhost -d localdroid -f `"$($migration.FullName)`" 2>nul"
            # Migrations may warn about existing objects - that's OK, don't treat as failure
        }
        Set-StepComplete "migrations"
        Write-Success "Migrations completed"
    } else {
        Write-Warn "Migrations directory not found: $migrationsDir"
        Set-StepComplete "migrations"
    }
}

# ============================================================================
# STEP 9: Build Web UI
# ============================================================================
Write-Step "Step 9: Build Web UI"

$webDir = Join-Path $installDir "web"

if (Test-StepDone "web_build") {
    Write-Success "Web UI already built, skipping"
} else {
    if (-not (Test-Path $webDir)) { Write-Err "Web directory not found: $webDir"; exit 1 }

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
        Write-Host "  Re-run: .\install-windows.ps1 -ResetStep web_build" -ForegroundColor Yellow
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
# STEP 10: Build Go Server
# ============================================================================
Write-Step "Step 10: Build Go Server"

$serverExe = Join-Path $serverDir "localdroid-server.exe"

if (Test-StepDone "server_build") {
    Write-Success "Server already built, skipping"
} else {
    if (-not (Test-Path $serverDir)) { Write-Err "Server directory not found: $serverDir"; exit 1 }

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
        Write-Host "  Re-run: .\install-windows.ps1 -ResetStep server_build" -ForegroundColor Yellow
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
# STEP 11: Download Android Agent APK
# ============================================================================
Write-Step "Step 11: Android Agent APK"

$agentStorageDir = Join-Path $serverDir "storage\agent"
$apkDest = Join-Path $agentStorageDir "localdroid-agent.apk"

if (Test-StepDone "apk") {
    Write-Success "Android APK already installed, skipping"
} else {
    New-Item -ItemType Directory -Path $agentStorageDir -Force | Out-Null

    # Local-file priority list. seed/ is the canonical bundle layout; the
    # legacy releases/ paths stay so old hand-rolled deployments still work.
    # We DO NOT fetch from the internet — the source repo is private and the
    # binary ships in the tarball.
    $localApk = @(
        (Join-Path $ScriptDir "seed\localdroid-agent.apk"),
        (Join-Path $installDir "seed\localdroid-agent.apk"),
        (Join-Path $ScriptDir "releases\localdroid-agent.apk"),
        (Join-Path $installDir "releases\localdroid-agent.apk"),
        (Join-Path $ScriptDir "releases\localdroid-agent-v1.0.0.apk"),
        (Join-Path $installDir "releases\localdroid-agent-v1.0.0.apk")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($localApk) {
        Copy-Item $localApk $apkDest -Force
        Set-StepComplete "apk"
        Write-Success "Android APK copied from $localApk"
    } else {
        Write-Warn "No Android APK found in seed\ or releases\ folder."
        Write-Host "  Drop a copy of localdroid-agent.apk at: $apkDest" -ForegroundColor Yellow
        Write-Host "  Then restart the LocalDroid service to seed it in." -ForegroundColor Yellow
        Set-StepComplete "apk"
    }
}

# STEP 11b: APK signing-cert checksum (Zero-Touch enrollment verification).
# Run after the APK is seeded. Sidecar from build-native-bundle.sh first;
# apksigner against the seeded file as a fallback for dev installs. Always
# recompute so that re-seeding a re-signed APK + re-running this script
# updates .env automatically.
if (Test-Path $apkDest) {
    $apkChecksum = ""

    # 1. Sidecar produced by scripts/build-native-bundle.sh
    $sidecarCandidates = @(
        (Join-Path $ScriptDir "seed\localdroid-agent.apk.cert-sha256"),
        (Join-Path $installDir "seed\localdroid-agent.apk.cert-sha256"),
        (Join-Path $ScriptDir "releases\localdroid-agent.apk.cert-sha256"),
        (Join-Path $installDir "releases\localdroid-agent.apk.cert-sha256")
    )
    foreach ($s in $sidecarCandidates) {
        if (Test-Path $s) {
            $apkChecksum = (Get-Content $s -Raw).Trim()
            Write-Host "  APK checksum loaded from sidecar: $(Split-Path -Leaf $s)"
            break
        }
    }

    # 2. Compute via apksigner against the seeded APK
    if (-not $apkChecksum) {
        $apkSigner = $null
        $androidHome = $env:ANDROID_HOME
        if ($androidHome -and (Test-Path $androidHome)) {
            $btPath = Join-Path $androidHome "build-tools"
            if (Test-Path $btPath) {
                $latest = Get-ChildItem $btPath | Sort-Object Name -Descending | Select-Object -First 1
                $sig = Join-Path $latest.FullName "apksigner.bat"
                if (Test-Path $sig) { $apkSigner = $sig }
            }
        }
        if ($apkSigner) {
            try {
                $certInfo = & $apkSigner verify --print-certs $apkDest 2>$null
                $sha256Line = $certInfo | Select-String "SHA-256 digest" | Select-Object -First 1
                if ($sha256Line) {
                    $hex = (($sha256Line -split ":")[-1]).Trim() -replace " ", ""
                    $hBytes = [byte[]]::new($hex.Length / 2)
                    for ($i = 0; $i -lt $hex.Length; $i += 2) {
                        $hBytes[$i/2] = [Convert]::ToByte($hex.Substring($i, 2), 16)
                    }
                    $apkChecksum = ([Convert]::ToBase64String($hBytes)) -replace '\+','-' -replace '/','_' -replace '=',''
                    Write-Host "  APK checksum computed via apksigner"
                }
            } catch { Write-Warn "apksigner ran but failed to produce a checksum" }
        }
    }

    # 3. Apply or warn
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
        Write-Warn "Could not determine APK signing-cert checksum."
        Write-Host "    Zero-Touch enrollment will fail until APK_SIGNATURE_CHECKSUM is set in:" -ForegroundColor Yellow
        Write-Host "      $envPath" -ForegroundColor Yellow
        Write-Host "    Either install Android build-tools (for apksigner) or ship a bundle" -ForegroundColor Yellow
        Write-Host "    with seed\localdroid-agent.apk.cert-sha256." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 12: Configure Mosquitto
# ============================================================================
Write-Step "Step 12: Configure Mosquitto"

if (Test-StepDone "mosquitto") {
    Write-Success "Mosquitto already configured, skipping"
} else {
    $mqConfPath = "C:\Program Files\mosquitto\mosquitto.conf"
    if (Test-Path "C:\Program Files\mosquitto") {
        @"
# LocalDroid Mosquitto Configuration
listener $mqttPort
allow_anonymous true
"@ | Out-File -FilePath $mqConfPath -Encoding UTF8
        Set-StepComplete "mosquitto"
        Write-Success "Mosquitto configured on port $mqttPort"
    } else {
        Write-Warn "Mosquitto not found at default path - configure mosquitto.conf manually"
        Set-StepComplete "mosquitto"
    }
}

# ============================================================================
# STEP 13: Create Startup Script
# ============================================================================
Write-Step "Step 13: Startup Script"

if (Test-StepDone "startup") {
    Write-Success "Startup script already created, skipping"
} else {
    @"
@echo off
echo Starting LocalDroid MDM Server...
echo.

REM Start Mosquitto if not running
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
"@ | Out-File -FilePath (Join-Path $installDir "start-server.bat") -Encoding ASCII

    Set-StepComplete "startup"
    Write-Success "Created: start-server.bat"
}

# ============================================================================
# STEP 14: Remote control — firewall + TURN guidance
# ============================================================================
# Windows VNC (for Windows devices) relays through the Go server over the HTTP
# port — no extra ports. Android remote control uses WebRTC, which over the
# internet needs a TURN relay (coturn). coturn has no clean native Windows
# package, so we open the firewall here and tell the operator how to provide a
# relay. On a Windows host managing only Windows devices, you can ignore TURN.
Write-Step "Step 14: Remote Control Firewall"

if (Test-StepDone "remote_firewall") {
    Write-Success "Remote-control firewall already configured, skipping"
} else {
    # Always allow the server port (covers Windows VNC relay over HTTP/WSS).
    $fwRules = @(
        @{ Name = "LocalDroid Server $serverPort/tcp"; Port = $serverPort; Proto = "TCP" },
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
    # TURN media relay range.
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
    Write-Host "coturn has no native Windows package. To provide one, EITHER:" -ForegroundColor Yellow
    Write-Host "  - run it on a small Linux box / VPS, OR" -ForegroundColor Yellow
    Write-Host "  - run it via Docker Desktop / WSL2 on this host, e.g.:" -ForegroundColor Yellow
    Write-Host '      docker run -d --name coturn --network host coturn/coturn:4 \' -ForegroundColor Gray
    Write-Host '        -n --use-auth-secret --static-auth-secret=localdroid_turn_secret_2024 \' -ForegroundColor Gray
    Write-Host "        --realm=$serverIP --min-port=49152 --max-port=49200 --external-ip=<PUBLIC_IP>" -ForegroundColor Gray
    Write-Host "  The static-auth-secret MUST stay 'localdroid_turn_secret_2024' to match clients." -ForegroundColor Yellow
    Write-Host "Windows-device VNC works with no TURN server — server port only." -ForegroundColor Green
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
Write-Host "Installation : $installDir" -ForegroundColor Cyan
Write-Host "Web UI       : http://${serverIP}:${serverPort}" -ForegroundColor Cyan
Write-Host "Login        : admin@localdroid.app / admin" -ForegroundColor Cyan
Write-Host ""
Write-Host "Start the server:" -ForegroundColor Yellow
Write-Host "  Double-click: $(Join-Path $installDir 'start-server.bat')"
Write-Host ""
Write-Host "Open firewall ports if needed: $serverPort (HTTP), $mqttPort (MQTT)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Progress file: $StateFile" -ForegroundColor Gray
Write-Host "Re-run a step: .\install-windows.ps1 -ResetStep <step_name>" -ForegroundColor Gray
Write-Host "Start fresh  : .\install-windows.ps1 -Fresh" -ForegroundColor Gray
Write-Host ""
