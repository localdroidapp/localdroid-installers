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
    Step names: deps, config, clone, database, env, migrations, letsencrypt,
                tls_automation, web_build,
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
    $mqttExternalPort = Get-StateVal "cfg_mqttExternalPort" "1883"
    $mqttExternalTls  = (Get-StateVal "cfg_mqttExternalTls") -eq "true"
    $mqttCertFile     = Get-StateVal "cfg_mqttCertFile"
    $mqttKeyFile      = Get-StateVal "cfg_mqttKeyFile"
    $isAirGapped      = (Get-StateVal "cfg_isAirGapped") -eq "true"
    $externalUrl      = Get-StateVal "cfg_externalUrl"
    $enableTls        = (Get-StateVal "cfg_enableTls") -eq "true"
    $tlsCert          = Get-StateVal "cfg_tlsCert"
    $tlsKey           = Get-StateVal "cfg_tlsKey"
    $trustProxy       = (Get-StateVal "cfg_trustProxy") -eq "true"
    $installDir       = Get-StateVal "cfg_installDir"
    $licenseServerUrl = Get-StateVal "cfg_licenseServerUrl"
    $adminEmail       = Get-StateVal "cfg_adminEmail"
    $adminPasswordPlain = Get-StateVal "cfg_adminPassword"
    Write-Success "Loaded saved configuration (external=$externalUrl, dir=$installDir)"
} else {
    Write-Host ""
    Write-Host "Deployment Mode:" -ForegroundColor Yellow
    Write-Host "  1. Air-Gapped / Local Network"
    Write-Host "     Devices sit on the same network as this server. No domain or TLS needed."
    Write-Host "  2. Internet Connected (cloud)"
    Write-Host "     Devices connect over the internet. Needs a public domain name or IP."
    $deployMode = Read-Host "Select (1 or 2, Enter for 1)"
    if ([string]::IsNullOrEmpty($deployMode)) { $deployMode = "1" }
    $isAirGapped = ($deployMode -eq "1")

    $localIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } |
        Select-Object -First 1).IPAddress

    # Defaults for the settings only the cloud branch asks about, so the
    # air-gapped path stays a straight run of Enter presses.
    $enableTls  = $false
    $tlsCert    = ""
    $tlsKey     = ""
    $trustProxy = $false
    $mqttCertFile = ""
    $mqttKeyFile  = ""

    if ($isAirGapped) {
        Write-Host "Detected local IP: $localIP"
        $serverIP = Read-Host "Server IP (Enter for $localIP)"
        if ([string]::IsNullOrEmpty($serverIP)) { $serverIP = $localIP }

        $serverPort = Read-Host "HTTP port (Enter for 80)"
        if ([string]::IsNullOrEmpty($serverPort)) { $serverPort = "80" }

        $mqttPort = Read-Host "MQTT port (Enter for 1883)"
        if ([string]::IsNullOrEmpty($mqttPort)) { $mqttPort = "1883" }

        $externalUrl      = "http://${serverIP}:${serverPort}"
        $mqttExternalHost = $serverIP
        $mqttExternalPort = $mqttPort
        $mqttExternalTls  = $false
    } else {
        # --- Public address devices will use -------------------------------
        Write-Host ""
        Write-Host "Public Address:" -ForegroundColor Yellow
        Write-Host "  The domain name (or public IP) that devices use to reach this server."
        Write-Host "  Examples: mdm.yourcompany.com  |  203.0.113.10"
        Write-Host "  A domain name is strongly preferred - it is required for TLS and lets"
        Write-Host "  you move the server later without re-enrolling every device."
        while ($true) {
            $publicHost = (Read-Host "Domain name or public IP for devices").Trim()
            if ($publicHost) { break }
            Write-Host "  Required in cloud mode - devices need a public address." -ForegroundColor Yellow
        }
        $serverIP = $publicHost

        # --- How TLS is terminated -----------------------------------------
        Write-Host ""
        Write-Host "HTTPS / TLS:" -ForegroundColor Yellow
        Write-Host "  1. This server terminates TLS directly (recommended)"
        Write-Host "     LocalDroid listens on 443 with your certificate. No IIS/nginx needed."
        Write-Host "  2. A reverse proxy in front terminates TLS (IIS, nginx, Caddy)"
        Write-Host "     LocalDroid listens on a plain HTTP backend port behind the proxy."
        $tlsMode = Read-Host "Select (1 or 2, Enter for 1)"
        if ([string]::IsNullOrEmpty($tlsMode)) { $tlsMode = "1" }

        if ($tlsMode -eq "1") {
            $serverPort = Read-Host "HTTPS port (Enter for 443)"
            if ([string]::IsNullOrEmpty($serverPort)) { $serverPort = "443" }
            $enableTls  = $true
            $trustProxy = $false
            $externalUrl = if ($serverPort -eq "443") { "https://$publicHost" } else { "https://${publicHost}:${serverPort}" }
        } else {
            $serverPort = Read-Host "Backend HTTP port LocalDroid listens on (Enter for 8080)"
            if ([string]::IsNullOrEmpty($serverPort)) { $serverPort = "8080" }
            $enableTls = $false
            # Behind a proxy the client IP arrives in X-Forwarded-For; without
            # this every request looks like 127.0.0.1 and rate limits misfire.
            $trustProxy = $true

            $urlIn = (Read-Host "Public URL devices will use (Enter for https://$publicHost)").Trim()
            if ([string]::IsNullOrEmpty($urlIn)) { $urlIn = "https://$publicHost" }
            # A bare domain makes the server emit http:// links in QR codes; the
            # proxy then 301s to https://, which Android's HttpURLConnection
            # refuses to follow - enrollment fails with no useful error.
            if ($urlIn -notmatch '^https?://') {
                $urlIn = "https://$urlIn"
                Write-Host "  No scheme given - assuming HTTPS: $urlIn" -ForegroundColor Yellow
            }
            $externalUrl = $urlIn.TrimEnd('/')

            Write-Host "  Point your proxy at http://127.0.0.1:$serverPort" -ForegroundColor Cyan
        }

        # --- MQTT ----------------------------------------------------------
        Write-Host ""
        Write-Host "MQTT:" -ForegroundColor Yellow
        Write-Host "  Port 8883 = TLS (recommended over the internet). Port 1883 = unencrypted."
        Write-Host "  The server itself always talks to the broker over loopback in plain text."
        $mqttPort = Read-Host "Local broker port the server connects to (Enter for 1883)"
        if ([string]::IsNullOrEmpty($mqttPort)) { $mqttPort = "1883" }

        $mqttExternalHost = Read-Host "MQTT hostname for devices (Enter for $publicHost)"
        if ([string]::IsNullOrEmpty($mqttExternalHost)) { $mqttExternalHost = $publicHost }

        $mqttExternalPort = Read-Host "MQTT port for devices (Enter for 8883)"
        if ([string]::IsNullOrEmpty($mqttExternalPort)) { $mqttExternalPort = "8883" }
        $mqttExternalTls = ($mqttExternalPort -eq "8883")

        # --- TLS certificate: asked ONCE, used by everything ---------------
        # The web listener and the MQTT broker present the same certificate,
        # so there is one question, not one per component. The files do NOT
        # have to exist yet - win-acme/certbot normally runs after this
        # installer, so we record the paths and apply-tls-certs.ps1 wires
        # them up (and reloads on every renewal) once they appear.
        if ($enableTls -or $mqttExternalTls) {
            Write-Host ""
            Write-Host "TLS Certificate:" -ForegroundColor Yellow
            Write-Host "  One certificate covers both the web UI and the MQTT broker."
            Write-Host "  It must be valid for $publicHost and issued by a public CA"
            Write-Host "  (Let's Encrypt or commercial) - devices verify it against the"
            Write-Host "  system trust store, so self-signed will not work."
            Write-Host ""
            Write-Host "  You do NOT need the files yet. Press Enter to accept the default"
            Write-Host "  paths, finish the install, then run win-acme to write the certs"
            Write-Host "  there. TLS switches on automatically once they exist." -ForegroundColor Gray

            $tlsCert = (Read-Host "  Certificate path (Enter for C:\Certificates\fullchain.pem)").Trim('"', ' ')
            if ([string]::IsNullOrEmpty($tlsCert)) { $tlsCert = "C:\Certificates\fullchain.pem" }
            $tlsKey = (Read-Host "  Private key path (Enter for C:\Certificates\privkey.pem)").Trim('"', ' ')
            if ([string]::IsNullOrEmpty($tlsKey)) { $tlsKey = "C:\Certificates\privkey.pem" }

            # The broker uses the same pair - no second prompt.
            $mqttCertFile = $tlsCert
            $mqttKeyFile  = $tlsKey

            if ((Test-Path $tlsCert) -and (Test-Path $tlsKey)) {
                Write-Success "Certificate found - TLS will be enabled during this install"
            } else {
                Write-Host ""
                Write-Warn "Certificate not present yet - that's fine, continuing."
                Write-Host "  After the install, get a certificate and save it to those paths:" -ForegroundColor Yellow
                Write-Host "      cd C:\win-acme; .\wacs.exe --target manual --host $publicHost ``" -ForegroundColor Gray
                Write-Host "        --store pemfiles --pemfilespath C:\Certificates" -ForegroundColor Gray
                Write-Host "  then run apply-tls-certs.ps1 from the install folder." -ForegroundColor Yellow
            }
        }
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
    Set-StateVal "cfg_mqttExternalPort" $mqttExternalPort
    Set-StateVal "cfg_mqttExternalTls"  ($mqttExternalTls.ToString().ToLower())
    Set-StateVal "cfg_mqttCertFile"     $mqttCertFile
    Set-StateVal "cfg_mqttKeyFile"      $mqttKeyFile
    Set-StateVal "cfg_isAirGapped"      ($isAirGapped.ToString().ToLower())
    Set-StateVal "cfg_externalUrl"      $externalUrl
    Set-StateVal "cfg_enableTls"        ($enableTls.ToString().ToLower())
    Set-StateVal "cfg_tlsCert"          $tlsCert
    Set-StateVal "cfg_tlsKey"           $tlsKey
    Set-StateVal "cfg_trustProxy"       ($trustProxy.ToString().ToLower())
    Set-StateVal "cfg_installDir"       $installDir
    Set-StateVal "cfg_licenseServerUrl" $licenseServerUrl
    Set-StateVal "cfg_adminEmail"       $adminEmail
    Set-StateVal "cfg_adminPassword"    $adminPasswordPlain
    Set-StepComplete "config"

    Write-Host ""
    Write-Host "Configuration summary:" -ForegroundColor Cyan
    Write-Host "  Mode        : $(if ($isAirGapped) { 'Air-gapped / local network' } else { 'Internet connected (cloud)' })"
    Write-Host "  Web UI / API: $externalUrl"
    Write-Host "  Listening on: $(if ($enableTls) { 'https' } else { 'http' })://0.0.0.0:$serverPort"
    Write-Host "  MQTT devices: ${mqttExternalHost}:${mqttExternalPort}$(if ($mqttExternalTls) { ' (TLS)' } else { ' (plain)' })"
    Write-Host "  Admin login : $adminEmail"
    Write-Host "  Install dir : $installDir"
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

    # A browser omits the default port from the Origin header, so an
    # EXTERNAL_URL of http://host:80 arrives as http://host. List both forms
    # or the origin check rejects a request that is in fact same-origin.
    $allowedOrigins = $externalUrl
    if ($externalUrl -match '^http://(.+):80$')   { $allowedOrigins = "$externalUrl,http://$($Matches[1])" }
    if ($externalUrl -match '^https://(.+):443$') { $allowedOrigins = "$externalUrl,https://$($Matches[1])" }

    if (-not (Test-Path $serverDir)) { New-Item -ItemType Directory -Path $serverDir -Force | Out-Null }

    @"
# LocalDroid Server Configuration
# Generated by install-windows.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

SERVER_HOST=0.0.0.0
SERVER_PORT=$serverPort

# TLS terminated by this server (cloud + direct-TLS mode). When a reverse
# proxy handles TLS instead, ENABLE_TLS stays false and the proxy talks to
# the plain HTTP port above.
ENABLE_TLS=$($enableTls.ToString().ToLower())
TLS_CERT=$tlsCert
TLS_KEY=$tlsKey
# Honour X-Forwarded-For. Only true behind a trusted proxy - turning this on
# with no proxy in front lets clients spoof their own IP past rate limits.
TRUST_PROXY=$($trustProxy.ToString().ToLower())

DB_HOST=localhost
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$pgPasswordPlain
DB_NAME=localdroid
DB_SSLMODE=disable

MQTT_HOST=localhost
MQTT_PORT=$mqttPort
MQTT_EXTERNAL_HOST=$mqttExternalHost
MQTT_EXTERNAL_PORT=$mqttExternalPort
MQTT_EXTERNAL_USE_TLS=$($mqttExternalTls.ToString().ToLower())

JWT_SECRET=$jwtSecret
JWT_EXPIRES_HOURS=24

EXTERNAL_URL=$externalUrl
ALLOWED_ORIGINS=$allowedOrigins
DEPLOYMENT_MODE=$deployModeStr

STORAGE_PATH=./storage
APK_SIGNATURE_CHECKSUM=

# Licensing - the LocalDroid license-authority public key ships as the
# default so signed license.lic files verify out of the box (the key is
# public: it can only VERIFY licenses, never create them). Auto-refreshed
# from the portal below when LICENSE_SERVER_URL is reachable.
LICENSE_SERVER_URL=$licenseServerUrl
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

# ============================================================================
# STEP 11a: Windows Agent EXE
# ============================================================================
# LocalDroid manages Windows devices as well as Android ones, and the server
# hands enrolling Windows machines /agent/localdroid-agent.exe (handlers.go) —
# the same storage\agent\ folder the APK lives in. Neither Windows installer has
# ever copied it: `git log -S localdroid-agent.exe` over both .ps1 files is
# empty. install.sh seeds BOTH agents via seed_agent_binary(); that fix was
# never ported here, so every Windows install has silently shipped without the
# Windows agent and needed a manual copy. This is that missing port.
#
# Deliberately NOT guarded by Test-StepDone: the marker means "a file was placed
# once", not "the file is current", so on an upgrade it would keep a stale agent
# and say nothing. The bundle's copy is always the right one to install.
Write-Step "Step 11a: Windows Agent EXE"

$exeDest = Join-Path $agentStorageDir "localdroid-agent.exe"
New-Item -ItemType Directory -Path $agentStorageDir -Force | Out-Null

$localExe = @(
    (Join-Path $ScriptDir "seed\localdroid-agent.exe"),
    (Join-Path $installDir "seed\localdroid-agent.exe"),
    (Join-Path $ScriptDir "releases\localdroid-agent.exe"),
    (Join-Path $installDir "releases\localdroid-agent.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($localExe) {
    Copy-Item $localExe $exeDest -Force
    $exeSize = [math]::Round((Get-Item $exeDest).Length / 1MB, 1)
    Write-Success "Windows agent EXE copied from $localExe ($exeSize MB)"
} else {
    Write-Warn "No Windows agent EXE found in seed\ or releases\ folder."
    Write-Host "  Windows device enrollment and agent self-update BOTH need this file." -ForegroundColor Yellow
    Write-Host "  Drop a copy of localdroid-agent.exe at: $exeDest" -ForegroundColor Yellow
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
        # Air-gapped: one plain listener on the LAN, devices connect straight to it.
        # Cloud: the plain listener is bound to loopback for the Go server only, and
        # devices get a separate TLS listener. Binding 1883 to 127.0.0.1 matters —
        # an internet-facing anonymous 1883 would let anyone publish device commands.
        $listenerBlock = if ($isAirGapped -or -not $mqttExternalTls) {
            @"
listener $mqttPort
allow_anonymous true
"@
        } else {
            @"
# Local listener: the LocalDroid server connects here over loopback only.
listener $mqttPort 127.0.0.1
allow_anonymous true

# Public TLS listener: Android and Windows devices connect here.
listener $mqttExternalPort
certfile $mqttCertFile
keyfile $mqttKeyFile
allow_anonymous true
"@
        }

        # A TLS listener pointing at files that don't exist takes the WHOLE
        # broker down on start - including the loopback listener the server
        # itself needs - so only write it once the certs are actually there.
        # apply-tls-certs.ps1 adds the listener later without a reinstall.
        $certsPresent = $mqttCertFile -and $mqttKeyFile -and
                        (Test-Path $mqttCertFile) -and (Test-Path $mqttKeyFile)
        if (-not $isAirGapped -and $mqttExternalTls -and -not $certsPresent) {
            $listenerBlock = @"
listener $mqttPort 127.0.0.1
allow_anonymous true
"@
            Write-Warn "Certificate not in place yet - wrote a loopback-only broker config."
            Write-Host "  This is expected if you haven't run win-acme yet. Once the cert" -ForegroundColor Yellow
            Write-Host "  exists at $mqttCertFile, run:" -ForegroundColor Yellow
            Write-Host "      .\apply-tls-certs.ps1" -ForegroundColor Gray
            Write-Host "  to add the $mqttExternalPort TLS listener and restart the broker." -ForegroundColor Yellow
        }

        @"
# LocalDroid Mosquitto Configuration
# Generated by install-windows.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

$listenerBlock
# Resource limits — a runaway client can't exhaust the broker or flood the
# network. Size max_connections to device count plus headroom.
max_connections 1024
max_queued_messages 200
max_inflight_messages 20
message_size_limit 10485760
max_keepalive 120
# NOTE: ASCII, not UTF8. Out-File -Encoding UTF8 under Windows PowerShell 5.1
# emits a BOM, and mosquitto refuses to parse one: it dies at startup with
#   Error: Unknown configuration variable "<BOM>#"  ...  at mosquitto.conf:1
# which as a service just looks like "starts then stops immediately".
"@ | Out-File -FilePath $mqConfPath -Encoding ASCII

        # Pick up the new config; a running broker keeps the old one otherwise.
        try {
            if (Get-Service mosquitto -ErrorAction SilentlyContinue) {
                Restart-Service mosquitto -Force -ErrorAction Stop
                Write-Success "Mosquitto service restarted"
            }
        } catch {
            Write-Warn "Could not restart the Mosquitto service: $_"
        }

        Set-StepComplete "mosquitto"
        if ($isAirGapped -or -not $mqttExternalTls) {
            Write-Success "Mosquitto configured on port $mqttPort"
        } elseif ($certsPresent) {
            Write-Success "Mosquitto configured: $mqttPort (loopback) + $mqttExternalPort (TLS, devices)"
        } else {
            Write-Success "Mosquitto configured: $mqttPort (loopback) - TLS listener pending certificate"
        }
    } else {
        Write-Warn "Mosquitto not found at default path - configure mosquitto.conf manually"
        Set-StepComplete "mosquitto"
    }
}

# ============================================================================
# STEP 12a: Obtain a Let's Encrypt certificate (cloud only)
# ============================================================================
# Mirrors what install.sh does on Linux with certbot --standalone. win-acme's
# "selfhosting" validation binds port 80 just long enough to answer the ACME
# HTTP-01 challenge, so this works with no IIS and no nginx - the Go server
# keeps 443 (or its backend port) to itself.
if (-not $isAirGapped -and ($enableTls -or $mqttExternalTls)) {
    Write-Step "Step 12a: TLS Certificate (Let's Encrypt)"

    $certDir = Split-Path -Parent $tlsCert

    if (Test-StepDone "letsencrypt") {
        Write-Success "Certificate step already done, skipping"
    } elseif ((Test-Path $tlsCert) -and (Test-Path $tlsKey)) {
        Write-Success "Certificate already present at $tlsCert - skipping issuance"
        Set-StepComplete "letsencrypt"
    } else {
        Write-Host ""
        Write-Host "A certificate can be requested automatically from Let's Encrypt."
        Write-Host "Requirements - both must already be true:" -ForegroundColor Yellow
        Write-Host "  1. DNS for $mqttExternalHost resolves to this server's public IP"
        Write-Host "  2. TCP port 80 is open from the internet to this machine"
        Write-Host "     (used only for the domain-ownership check, then released)"

        $doAcme = Read-Host "Request a certificate now? (Y/n)"
        if ([string]::IsNullOrEmpty($doAcme)) { $doAcme = "y" }

        if ($doAcme -match '^[Yy]') {
            New-Item -ItemType Directory -Path $certDir -Force | Out-Null

            $wacs = @("C:\win-acme\wacs.exe",
                      (Join-Path $installDir "win-acme\wacs.exe")) |
                    Where-Object { Test-Path $_ } | Select-Object -First 1

            # This installer builds from source on an internet-connected host,
            # so fetching win-acme here is fine (the offline bundle ships it).
            if (-not $wacs) {
                try {
                    Write-Host "  Downloading win-acme..." -ForegroundColor Cyan
                    $waZip = Join-Path $env:TEMP "win-acme.zip"
                    $waDir = Join-Path $installDir "win-acme"
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -UseBasicParsing -OutFile $waZip `
                        -Uri "https://github.com/win-acme/win-acme/releases/download/v2.2.9.1701/win-acme.v2.2.9.1701.x64.pluggable.zip"
                    $ProgressPreference = 'Continue'
                    Expand-Archive -Path $waZip -DestinationPath $waDir -Force
                    Remove-Item $waZip -Force -ErrorAction SilentlyContinue
                    $wacs = Join-Path $waDir "wacs.exe"
                    if (-not (Test-Path $wacs)) { $wacs = $null }
                } catch {
                    Write-Warn "Could not download win-acme: $_"
                    $wacs = $null
                }
            }

            if (-not $wacs) {
                Write-Warn "win-acme unavailable - skipping automatic issuance."
                Write-Host "  Install it from https://www.win-acme.com/ to C:\win-acme," -ForegroundColor Yellow
                Write-Host "  or place a certificate at $tlsCert manually." -ForegroundColor Yellow
            } else {
                # Port 80 must be free for the challenge, and reachable. Check
                # the local half now - a bound port fails instantly and
                # confusingly.
                $port80 = Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue
                if ($port80) {
                    Write-Warn "Something is already listening on port 80:"
                    $port80 | ForEach-Object {
                        $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                        Write-Host "    PID $($_.OwningProcess) $(if ($p) { $p.ProcessName })" -ForegroundColor Yellow
                    }
                    Write-Host "  Stop it, or supply a certificate manually." -ForegroundColor Yellow
                }

                try {
                    New-NetFirewallRule -DisplayName "LocalDroid ACME http-01 (80/tcp)" `
                        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80 `
                        -ErrorAction SilentlyContinue | Out-Null
                } catch {}

                Write-Host ""
                Write-Host "  Running win-acme for $mqttExternalHost ..." -ForegroundColor Cyan
                & $wacs --target manual --host $mqttExternalHost --validation selfhosting `
                        --store pemfiles --pemfilespath $certDir --accepttos --emailaddress $adminEmail
                $acmeExit = $LASTEXITCODE

                # win-acme names its output after the target (e.g.
                # mdm.example.com-chain.pem), and the exact suffixes vary
                # between versions - discover the files rather than assume a
                # name, then normalise to the paths .env already points at.
                $issuedCert = Get-ChildItem -Path $certDir -Filter "*-chain.pem" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike "*chain-only*" } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if (-not $issuedCert) {
                    $issuedCert = Get-ChildItem -Path $certDir -Filter "*-crt.pem" -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                }
                $issuedKey = Get-ChildItem -Path $certDir -Filter "*-key.pem" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1

                if ($issuedCert -and $issuedKey) {
                    Copy-Item $issuedCert.FullName $tlsCert -Force
                    Copy-Item $issuedKey.FullName  $tlsKey  -Force
                    Write-Success "Certificate issued and installed to $tlsCert"
                } else {
                    Write-Warn "win-acme finished (exit $acmeExit) but no certificate was found in $certDir."
                    Write-Host "  Most common causes: DNS not pointing here yet, or port 80 blocked" -ForegroundColor Yellow
                    Write-Host "  upstream (cloud security group / router)." -ForegroundColor Yellow
                    Write-Host "  Fix that, then: .\install-windows.ps1 -ResetStep letsencrypt" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "  Skipping automatic issuance." -ForegroundColor Gray
            Write-Host "  Place your certificate at $tlsCert and key at $tlsKey," -ForegroundColor Yellow
            Write-Host "  then run .\apply-tls-certs.ps1" -ForegroundColor Yellow
        }
        Set-StepComplete "letsencrypt"
    }
}

# ============================================================================
# STEP 12b: TLS certificate automation (cloud + MQTT TLS only)
# ============================================================================
# Writes apply-tls-certs.ps1 and schedules it daily. It does two jobs:
#   1. First run after win-acme/certbot: adds the TLS listener to
#      mosquitto.conf, which the installer deliberately left out while the
#      cert files were missing (a listener pointing at absent files stops the
#      broker dead, taking the server's loopback connection with it).
#   2. Every renewal: Mosquitto reads its certificate once at startup, so a
#      renewed cert on disk does nothing until the service restarts. The
#      scheduled task notices the file changed and restarts it.
if (-not $isAirGapped -and $mqttExternalTls) {
    Write-Step "Step 12b: TLS Certificate Automation"

    if (Test-StepDone "tls_automation") {
        Write-Success "TLS automation already configured, skipping"
    } else {
        $applyScript = Join-Path $installDir "apply-tls-certs.ps1"
        $stampFile   = Join-Path $installDir ".tls-cert-stamp"

        # Single-quoted here-string: this is the generated script's own source,
        # so nothing here should expand at install time except the placeholders
        # substituted immediately below.
        $applyBody = @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Apply the TLS certificate to Mosquitto and restart it when the cert changes.
.DESCRIPTION
    Run this after obtaining or renewing a certificate. It is idempotent and
    safe to run on a schedule - it only acts when the certificate on disk is
    newer than the last one applied, unless -Force is passed.

    The installer registers this as a daily scheduled task, so Let's Encrypt
    renewals are picked up without anyone remembering to restart the broker.
.PARAMETER Force
    Rewrite the config and restart even if the certificate has not changed.
#>
param([switch]$Force)

$ErrorActionPreference = "Stop"
$CertFile   = "__CERT__"
$KeyFile    = "__KEY__"
$LocalPort  = "__LOCALPORT__"
$TlsPort    = "__TLSPORT__"
$StampFile  = "__STAMP__"
$MqConfPath = "C:\Program Files\mosquitto\mosquitto.conf"
$CertDir    = Split-Path -Parent $CertFile

# win-acme renews on its own schedule and writes <host>-chain.pem /
# <host>-key.pem into this folder - it does not touch our canonical filenames.
# Promote the newest issued pair onto the paths mosquitto.conf and .env point
# at, so a renewal flows through without anyone editing config by hand.
if (Test-Path $CertDir) {
    $issued = Get-ChildItem -Path $CertDir -Filter "*-chain.pem" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*chain-only*" } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $issued) {
        $issued = Get-ChildItem -Path $CertDir -Filter "*-crt.pem" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    $issuedKey = Get-ChildItem -Path $CertDir -Filter "*-key.pem" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($issued -and $issuedKey) {
        $canonicalAge = if (Test-Path $CertFile) { (Get-Item $CertFile).LastWriteTime } else { [datetime]::MinValue }
        if ($issued.LastWriteTime -gt $canonicalAge) {
            Copy-Item $issued.FullName    $CertFile -Force
            Copy-Item $issuedKey.FullName $KeyFile  -Force
            Write-Host "    Promoted renewed certificate: $($issued.Name)" -ForegroundColor Gray
        }
    }
}

if (-not ((Test-Path $CertFile) -and (Test-Path $KeyFile))) {
    Write-Host "[WAIT] Certificate not present yet:" -ForegroundColor Yellow
    Write-Host "         $CertFile"
    Write-Host "         $KeyFile"
    Write-Host "       Obtain one, then re-run this script. Nothing changed." -ForegroundColor Yellow
    exit 0
}

# Fingerprint the cert so a renewal (new thumbprint) is detected even if the
# file timestamp is preserved by whatever copied it into place.
try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CertFile
    $current = $cert.Thumbprint
    $expires = $cert.NotAfter
} catch {
    # Not a parseable single cert (e.g. a full chain PEM) - fall back to a
    # content hash, which changes on renewal just the same.
    $current = (Get-FileHash $CertFile -Algorithm SHA256).Hash
    $expires = $null
}

$previous = if (Test-Path $StampFile) { (Get-Content $StampFile -Raw).Trim() } else { "" }
if ($current -eq $previous -and -not $Force) {
    Write-Host "[OK] Certificate unchanged - nothing to do." -ForegroundColor Green
    if ($expires) { Write-Host "     Expires: $expires" -ForegroundColor Gray }
    exit 0
}

Write-Host "==> Applying certificate to Mosquitto" -ForegroundColor Cyan
if ($expires) { Write-Host "    Expires: $expires" -ForegroundColor Gray }

@"
# LocalDroid Mosquitto Configuration
# Written by apply-tls-certs.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

# Local listener: the LocalDroid server connects here over loopback only.
listener $LocalPort 127.0.0.1
allow_anonymous true

# Public TLS listener: Android and Windows devices connect here.
listener $TlsPort
certfile $CertFile
keyfile $KeyFile
allow_anonymous true

# Resource limits - a runaway client can't exhaust the broker or flood the
# network. Size max_connections to device count plus headroom.
max_connections 1024
max_queued_messages 200
max_inflight_messages 20
message_size_limit 10485760
max_keepalive 120
# NOTE: ASCII, not UTF8. Out-File -Encoding UTF8 under Windows PowerShell 5.1
# emits a BOM, and mosquitto refuses to parse one: it dies at startup with
#   Error: Unknown configuration variable "<BOM>#"  ...  at mosquitto.conf:1
# which as a service just looks like "starts then stops immediately".
"@ | Out-File -FilePath $MqConfPath -Encoding ASCII

try {
    Restart-Service mosquitto -Force -ErrorAction Stop
    Write-Host "[OK] Mosquitto restarted with the new certificate." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Could not restart Mosquitto: $_" -ForegroundColor Red
    Write-Host "        The config was written; restart the service manually." -ForegroundColor Yellow
    exit 1
}

# Only stamp after a successful restart, so a failure retries next run.
$current | Out-File -FilePath $StampFile -Encoding ASCII -NoNewline
Write-Host "[OK] Devices can now connect on port $TlsPort (TLS)." -ForegroundColor Green

# The Go server reads its certificate once at startup too. If it is the thing
# terminating HTTPS (ENABLE_TLS=true), it needs a restart to serve the renewed
# cert - the web UI would otherwise keep presenting the expired one.
# Everything above already succeeded by this point, so a problem here must not
# fail the run: this executes unattended from a scheduled task.
$EnvPath = "__ENVPATH__"
try {
    if ((Test-Path $EnvPath) -and
        ((Get-Content $EnvPath | Where-Object { $_ -match '^ENABLE_TLS=true' }) -ne $null) -and
        (Get-Process localdroid-server -ErrorAction SilentlyContinue)) {
        Write-Host "[ACTION] The LocalDroid server is serving HTTPS with the old certificate." -ForegroundColor Yellow
        Write-Host "         Restart it to pick up the renewal: stop the server window," -ForegroundColor Yellow
        Write-Host "         then run start-server.bat" -ForegroundColor Yellow
    }
} catch {
    Write-Host "[NOTE] Could not check whether the server needs restarting: $_" -ForegroundColor Gray
}
'@

        $applyBody = $applyBody.
            Replace('__CERT__',      $mqttCertFile).
            Replace('__KEY__',       $mqttKeyFile).
            Replace('__LOCALPORT__', $mqttPort).
            Replace('__TLSPORT__',   $mqttExternalPort).
            Replace('__STAMP__',     $stampFile).
            Replace('__ENVPATH__',   $envPath)
        $applyBody | Out-File -FilePath $applyScript -Encoding UTF8
        Write-Success "Created: apply-tls-certs.ps1"

        # Daily check. win-acme renews around 60 days, so a daily poll picks a
        # renewal up within 24h without needing a win-acme hook to be wired.
        try {
            $taskName = "LocalDroid TLS certificate reload"
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$applyScript`""
            $trigger = New-ScheduledTaskTrigger -Daily -At 3am
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -RunLevel Highest -User "SYSTEM" -Description `
                "Reloads Mosquitto when the LocalDroid TLS certificate is renewed." `
                -ErrorAction Stop | Out-Null
            Write-Success "Scheduled daily certificate check (3am) - renewals reload automatically"
        } catch {
            Write-Warn "Could not register the scheduled task: $_"
            Write-Host "  Run apply-tls-certs.ps1 by hand after each certificate renewal." -ForegroundColor Yellow
        }

        # If the certs already exist, apply immediately so the install finishes
        # with a working TLS listener rather than one pending a scheduled run.
        if ((Test-Path $mqttCertFile) -and (Test-Path $mqttKeyFile)) {
            & $applyScript -Force
        }

        Set-StepComplete "tls_automation"
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
echo Server running at $externalUrl
echo Press Ctrl+C to stop
echo.
localdroid-server.exe
pause
"@ | Out-File -FilePath (Join-Path $installDir "start-server.bat") -Encoding ASCII

    Set-StepComplete "startup"
    Write-Success "Created: start-server.bat"

# ============================================================================
# Auto-start service (boot + restart-on-crash)
# ============================================================================
# Linux gets a systemd unit with Restart=always / RestartSec=5 and
# WantedBy=multi-user.target. Windows only ever got start-server.bat, which ends
# in `pause` - an interactive launcher. So on Windows the MDM died on reboot and
# stayed down until somebody logged in and double-clicked it. This is the
# missing parity.
#
# A Scheduled Task rather than sc.exe: localdroid-server.exe is a plain console
# binary with no windows/svc control handler, so the SCM would start it, get no
# response to a service-control message, and kill it. The while() wrapper is what
# supplies Restart=always semantics - a task on its own does not relaunch a
# process that simply exits.
#
# Not guarded by Test-StepDone: -Force makes re-registration idempotent, and an
# upgrade must be able to correct a stale command line.
Write-Step "Auto-start service"

try {
    $svcTaskName = "LocalDroid MDM Server"
    $svcDir      = Join-Path $installDir "server"
    $svcExe      = Join-Path $svcDir "localdroid-server.exe"

    # Backtick-escaped $true so it survives into the child shell unexpanded.
    $svcCmd = "while(`$true){ & '$svcExe'; Start-Sleep 5 }"
    $svcArg = '-NoProfile -WindowStyle Hidden -Command "' + $svcCmd + '"'

    Unregister-ScheduledTask -TaskName $svcTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $svcAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $svcArg -WorkingDirectory $svcDir
    $svcSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
    $svcTrigger = New-ScheduledTaskTrigger -AtStartup

    Register-ScheduledTask -TaskName $svcTaskName -Action $svcAction -Trigger $svcTrigger -Settings $svcSettings -User "SYSTEM" -RunLevel Highest -Force -Description "Starts the LocalDroid MDM server at boot and restarts it if it exits." -ErrorAction Stop | Out-Null

    Write-Success "Auto-start registered: scheduled task '$svcTaskName' (SYSTEM, at boot)"
    Write-Host "  Start it now with:  Start-ScheduledTask -TaskName '$svcTaskName'" -ForegroundColor Gray
} catch {
    Write-Warn "Could not register the auto-start task: $_"
    Write-Host "  The server will NOT start on boot. Use start-server.bat manually," -ForegroundColor Yellow
    Write-Host "  or register the task by hand once the cause is resolved." -ForegroundColor Yellow
}
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
    # Always allow the server port (covers Windows VNC relay over HTTP/WSS) and
    # the port devices actually reach MQTT on. In cloud mode the local broker
    # port is loopback-only, so opening it would expose an anonymous listener
    # to the internet for no reason.
    $fwRules = @(
        @{ Name = "LocalDroid Server $serverPort/tcp";     Port = $serverPort;       Proto = "TCP" },
        @{ Name = "LocalDroid MQTT $mqttExternalPort/tcp"; Port = $mqttExternalPort; Proto = "TCP" },
        @{ Name = "LocalDroid TURN 3478/tcp";              Port = 3478;              Proto = "TCP" },
        @{ Name = "LocalDroid TURN 3478/udp";              Port = 3478;              Proto = "UDP" }
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
    Write-Host "Windows-device remote control (VNC) works now - it relays through the" -ForegroundColor Green
    Write-Host "LocalDroid server on port $serverPort, so no extra setup is needed." -ForegroundColor Green
    if (-not $isAirGapped) {
        Write-Host ""
        Write-Host "Android remote control over the internet needs a TURN relay (coturn)," -ForegroundColor Yellow
        Write-Host "which has no native Windows build. Run coturn on any Linux host or VPS" -ForegroundColor Yellow
        Write-Host "that devices can reach:" -ForegroundColor Yellow
        Write-Host "      turnserver -n --use-auth-secret \" -ForegroundColor Gray
        Write-Host "        --static-auth-secret=localdroid_turn_secret_2024 \" -ForegroundColor Gray
        Write-Host "        --realm=$mqttExternalHost --min-port=49152 --max-port=49200 \" -ForegroundColor Gray
        Write-Host "        --external-ip=<PUBLIC_IP>" -ForegroundColor Gray
        Write-Host "  The static-auth-secret MUST stay 'localdroid_turn_secret_2024' to match clients." -ForegroundColor Yellow
    } else {
        Write-Host "On a local network Android remote control works without a TURN relay." -ForegroundColor Green
    }
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
Write-Host "Web UI       : $externalUrl" -ForegroundColor Cyan
Write-Host "Login        : $adminEmail (password set during install)" -ForegroundColor Cyan
Write-Host "MQTT devices : ${mqttExternalHost}:${mqttExternalPort}$(if ($mqttExternalTls) { ' (TLS)' } else { ' (plain)' })" -ForegroundColor Cyan
Write-Host ""
Write-Host "Start the server:" -ForegroundColor Yellow
Write-Host "  Double-click: $(Join-Path $installDir 'start-server.bat')"
Write-Host ""

if (-not $isAirGapped) {
    $certsInPlace = $tlsCert -and (Test-Path $tlsCert) -and $tlsKey -and (Test-Path $tlsKey)
    if (-not $certsInPlace) {
        Write-Host "!! NEXT STEP: TLS certificate" -ForegroundColor Yellow
        Write-Host "   No certificate at $tlsCert yet, so TLS is not active."
        Write-Host "   1. Get one (Let's Encrypt via win-acme, or your commercial cert):"
        Write-Host "        cd C:\win-acme; .\wacs.exe --target manual --host $mqttExternalHost ``" -ForegroundColor Gray
        Write-Host "          --store pemfiles --pemfilespath $(Split-Path -Parent $tlsCert)" -ForegroundColor Gray
        Write-Host "   2. Then run, from the install folder:"
        Write-Host "        .\apply-tls-certs.ps1" -ForegroundColor Gray
        Write-Host "   Renewals after that reload automatically (daily scheduled task)."
        Write-Host ""
    }
    Write-Host "Before enrolling devices, confirm:" -ForegroundColor Yellow
    Write-Host "  - DNS for $mqttExternalHost resolves to this server's public IP"
    Write-Host "  - Ports $serverPort and $mqttExternalPort are open to the internet (router/cloud firewall too)"
    if ($trustProxy) {
        Write-Host "  - Your reverse proxy forwards to http://127.0.0.1:$serverPort and sets X-Forwarded-For"
    }
    Write-Host ""
    Write-Host "Enrollment QR codes are generated from $externalUrl - devices will use" -ForegroundColor Gray
    Write-Host "that exact URL, so make sure it is reachable from outside your network." -ForegroundColor Gray
    Write-Host ""
}
Write-Host "Progress file: $StateFile" -ForegroundColor Gray
Write-Host "Re-run a step: .\install-windows.ps1 -ResetStep <step_name>" -ForegroundColor Gray
Write-Host "Start fresh  : .\install-windows.ps1 -Fresh" -ForegroundColor Gray
Write-Host ""
