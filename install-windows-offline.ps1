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
    Step names: deps, config, database, env, migrations, letsencrypt,
                tls_automation, mosquitto, startup, apk, web_build,
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
    $mqExe = "C:\Program Files\mosquitto\mosquitto.exe"
    if (Test-Path $mqExe) {
        Write-Success "Mosquitto already installed"
    } else {
        Write-Host "  Running Mosquitto installer..."
        $mqInstaller = $Installers["Mosquitto"].ActualFile
        Start-Process -FilePath $mqInstaller -ArgumentList "/S" -Wait

        # The NSIS installer exits 0 even when a silent run installs nothing
        # (a missing Visual C++ runtime is the usual cause). Verify instead of
        # trusting it: an absent broker surfaces much later and much more
        # confusingly, as devices that simply never connect.
        if (-not (Test-Path $mqExe)) {
            Write-Warn "Silent install produced no mosquitto.exe - retrying interactively."
            Write-Host "  Complete the wizard, ticking the 'Service' component." -ForegroundColor Yellow
            Start-Process -FilePath $mqInstaller -Wait
        }
        if (-not (Test-Path $mqExe)) {
            Write-Err "Mosquitto failed to install."
            Write-Host "  LocalDroid cannot run without the broker - devices talk to it for" -ForegroundColor Yellow
            Write-Host "  every command. Install it by hand from:" -ForegroundColor Yellow
            Write-Host "    $mqInstaller" -ForegroundColor White
            Write-Host "  If it refuses, install the Visual C++ Redistributable first." -ForegroundColor Yellow
            Write-Host "  Then re-run this script." -ForegroundColor Yellow
            exit 1
        }
        $mqBin = "C:\Program Files\mosquitto"
        $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($cp -notlike "*$mqBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$cp;$mqBin", "Machine")
            $env:Path = "$env:Path;$mqBin"
        }
    }

    # A silent install can drop the binary without registering the Windows
    # service, which leaves a broker that never starts at boot. Register it
    # if it's missing.
    if ((Test-Path $mqExe) -and -not (Get-Service mosquitto -ErrorAction SilentlyContinue)) {
        Write-Host "  Registering the Mosquitto service..."
        try { & $mqExe install 2>&1 | Out-Null } catch {}
        if (-not (Get-Service mosquitto -ErrorAction SilentlyContinue)) {
            try {
                New-Service -Name mosquitto -DisplayName "Mosquitto Broker" `
                    -BinaryPathName "`"$mqExe`" run" -StartupType Automatic -ErrorAction Stop | Out-Null
            } catch {
                Write-Warn "Could not register the Mosquitto service: $_"
            }
        }
        if (Get-Service mosquitto -ErrorAction SilentlyContinue) {
            Set-Service mosquitto -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Success "Mosquitto service registered"
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
    $adminEmail       = Get-StateVal "cfg_adminEmail"
    $adminPasswordPlain = Get-StateVal "cfg_adminPassword"
    Write-Success "Loaded saved configuration (server=$serverIP`:$serverPort, external=$externalUrl)"
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

    # An air-gapped box has no route to the portal, so it verifies signed
    # licence files offline against the public key below. A cloud install can
    # reach the portal, so point it there and a raw licence key activates on
    # its own. Override with $env:LICENSE_SERVER_URL before running.
    if ($null -ne $env:LICENSE_SERVER_URL) {
        $licenseServerUrl = $env:LICENSE_SERVER_URL
    } elseif ($isAirGapped) {
        $licenseServerUrl = ""
    } else {
        $licenseServerUrl = "https://localdroid.app"
    }

    # A browser omits the default port from the Origin header, so an
    # EXTERNAL_URL of http://host:80 arrives as http://host. List both forms
    # or the origin check rejects a request that is in fact same-origin.
    $allowedOrigins = $externalUrl
    if ($externalUrl -match '^http://(.+):80$')   { $allowedOrigins = "$externalUrl,http://$($Matches[1])" }
    if ($externalUrl -match '^https://(.+):443$') { $allowedOrigins = "$externalUrl,https://$($Matches[1])" }

    if (-not (Test-Path $serverDir)) { New-Item -ItemType Directory -Path $serverDir -Force | Out-Null }

    @"
# LocalDroid Server Configuration
# Generated by install-windows-offline.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

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
# default so a signed license.lic verifies out of the box on air-gapped
# servers (the key is public: it can only VERIFY licenses, never create
# them). Point LOCALDROID_LICENSE_FILE at your license.lic to auto-activate.
# Cloud installs get the portal URL so a raw license key can activate online;
# air-gapped installs leave it blank and verify signed licence files offline.
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

# ============================================================================
# STEP 9a: Windows Agent EXE
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
Write-Step "Step 9a: Windows Agent EXE"

$exeDest = Join-Path $agentStorageDir "localdroid-agent.exe"
New-Item -ItemType Directory -Path $agentStorageDir -Force | Out-Null

$localExe = @(
    (Join-Path $ScriptDir "seed\localdroid-agent.exe"),
    (Join-Path $ScriptDir "releases\localdroid-agent.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($localExe) {
    Copy-Item $localExe $exeDest -Force
    $exeSize = [math]::Round((Get-Item $exeDest).Length / 1MB, 1)
    Write-Success "Windows agent EXE copied from $localExe ($exeSize MB)"
} else {
    Write-Warn "No Windows agent EXE found in seed\ or releases\ folder."
    Write-Host "  Windows device enrollment and agent self-update BOTH need this file." -ForegroundColor Yellow
    Write-Host "  Drop localdroid-agent.exe at: $exeDest" -ForegroundColor Yellow
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

        # Mosquitto refuses to start if persistence_location or the log
        # directory is missing, so create it before writing a config that
        # references it. This is also the path the Diagnostics page tells
        # operators to read when the broker misbehaves.
        $mqDataDir = "C:\ProgramData\localdroid\mosquitto"
        New-Item -ItemType Directory -Path $mqDataDir -Force | Out-Null

        @"
# LocalDroid Mosquitto Configuration
# Generated by install-windows-offline.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

$listenerBlock
# Resource limits — a runaway client can't exhaust the broker or flood the
# network. Size max_connections to device count plus headroom.
max_connections 1024
max_queued_messages 200
max_inflight_messages 20
message_size_limit 10485760
max_keepalive 120

# Retain queued messages across restarts, and log where the Diagnostics page
# points operators.
persistence true
persistence_location $mqDataDir\
log_dest file $mqDataDir\mosquitto.log
log_type error
log_type warning
log_type notice
"@ | Out-File -FilePath $mqConfPath -Encoding UTF8

        # Pick up the new config; a running broker keeps the old one otherwise.
        # Start (not just restart) so a registered-but-stopped service comes up.
        try {
            $mqSvc = Get-Service mosquitto -ErrorAction SilentlyContinue
            if ($mqSvc) {
                if ($mqSvc.Status -eq 'Running') {
                    Restart-Service mosquitto -Force -ErrorAction Stop
                    Write-Success "Mosquitto service restarted"
                } else {
                    Start-Service mosquitto -ErrorAction Stop
                    Write-Success "Mosquitto service started"
                }
            } else {
                Write-Warn "No Mosquitto service registered - the broker won't start at boot."
                Write-Host "  Re-run the installer, or register it with: mosquitto install" -ForegroundColor Yellow
            }
        } catch {
            Write-Warn "Could not start the Mosquitto service: $_"
            Write-Host "  Check $mqDataDir\mosquitto.log for the reason." -ForegroundColor Yellow
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
        # Deliberately NOT marked complete. Marking it done here means that
        # installing Mosquitto afterwards and re-running silently skips the
        # config step forever, leaving a broker with no LocalDroid listeners.
        Write-Err "Mosquitto is not installed at C:\Program Files\mosquitto"
        Write-Host "  The broker is required - devices cannot connect without it." -ForegroundColor Yellow
        Write-Host "  Install it from: $(Join-Path $InstallersDir 'mosquitto-windows-x64.exe')" -ForegroundColor Yellow
        Write-Host "  Tick the 'Service' component so it registers as a Windows service." -ForegroundColor Yellow
        Write-Host "  Then re-run this script - it will configure the broker." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 10a: Obtain a Let's Encrypt certificate (cloud only)
# ============================================================================
# Mirrors what install.sh does on Linux with certbot --standalone. win-acme's
# "selfhosting" validation binds port 80 just long enough to answer the ACME
# HTTP-01 challenge, so this works with no IIS and no nginx - the Go server
# keeps 443 (or its backend port) to itself.
if (-not $isAirGapped -and ($enableTls -or $mqttExternalTls)) {
    Write-Step "Step 10a: TLS Certificate (Let's Encrypt)"

    $certDir = Split-Path -Parent $tlsCert

    if (Test-StepDone "letsencrypt") {
        Write-Success "Certificate step already done, skipping"
    } elseif ((Test-Path $tlsCert) -and (Test-Path $tlsKey)) {
        Write-Success "Certificate already present at $tlsCert - skipping issuance"
        Set-StepComplete "letsencrypt"
    } else {
        $wacs = @(
            (Join-Path $InstallersDir "win-acme\wacs.exe"),
            (Join-Path $ScriptDir "installers\win-acme\wacs.exe"),
            "C:\win-acme\wacs.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        Write-Host ""
        Write-Host "A certificate can be requested automatically from Let's Encrypt."
        Write-Host "Requirements - both must already be true:" -ForegroundColor Yellow
        Write-Host "  1. DNS for $mqttExternalHost resolves to this server's public IP"
        Write-Host "  2. TCP port 80 is open from the internet to this machine"
        Write-Host "     (used only for the domain-ownership check, then released)"
        if (-not $wacs) {
            Write-Warn "win-acme not found in the bundle - automatic issuance unavailable."
        }

        $doAcme = "n"
        if ($wacs) {
            $doAcme = Read-Host "Request a certificate now? (Y/n)"
            if ([string]::IsNullOrEmpty($doAcme)) { $doAcme = "y" }
        }

        if ($doAcme -match '^[Yy]') {
            New-Item -ItemType Directory -Path $certDir -Force | Out-Null

            # Port 80 must be free for the challenge, and reachable. Check the
            # local half now - a bound port fails instantly and confusingly.
            $port80 = Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue
            if ($port80) {
                Write-Warn "Something is already listening on port 80:"
                $port80 | ForEach-Object {
                    $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                    Write-Host "    PID $($_.OwningProcess) $(if ($p) { $p.ProcessName })" -ForegroundColor Yellow
                }
                Write-Host "  Stop it, or answer n and supply a certificate manually." -ForegroundColor Yellow
            }

            try {
                New-NetFirewallRule -DisplayName "LocalDroid ACME http-01 (80/tcp)" `
                    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80 `
                    -ErrorAction SilentlyContinue | Out-Null
            } catch {}

            Write-Host ""
            Write-Host "  Running win-acme for $mqttExternalHost ..." -ForegroundColor Cyan
            $acmeArgs = @(
                "--target", "manual",
                "--host", $mqttExternalHost,
                "--validation", "selfhosting",
                "--store", "pemfiles",
                "--pemfilespath", $certDir,
                "--accepttos",
                "--emailaddress", $adminEmail
            )
            & $wacs @acmeArgs
            $acmeExit = $LASTEXITCODE

            # win-acme names its output after the target (e.g.
            # mdm.example.com-chain.pem), and the exact suffixes vary between
            # versions - so discover the files rather than assume a name, and
            # normalise to the canonical paths .env already points at.
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
                Write-Host "  Source: $($issuedCert.Name) / $($issuedKey.Name)" -ForegroundColor Gray
            } else {
                Write-Warn "win-acme finished (exit $acmeExit) but no certificate was found in $certDir."
                Write-Host "  Most common causes: DNS not pointing here yet, or port 80 blocked" -ForegroundColor Yellow
                Write-Host "  upstream (cloud security group / router)." -ForegroundColor Yellow
                Write-Host "  Fix that, then re-run:  .\install-windows-offline.ps1 -ResetStep letsencrypt" -ForegroundColor Yellow
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
# STEP 10b: TLS certificate automation (cloud + MQTT TLS only)
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
    Write-Step "Step 10b: TLS Certificate Automation"

    if (Test-StepDone "tls_automation") {
        Write-Success "TLS automation already configured, skipping"
    } else {
        $applyScript = Join-Path $ScriptDir "apply-tls-certs.ps1"
        $stampFile   = Join-Path $ScriptDir ".tls-cert-stamp"

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

# Mosquitto refuses to start if these directories are missing.
$DataDir = "C:\ProgramData\localdroid\mosquitto"
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

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

# Retain queued messages across restarts, and log where the Diagnostics page
# points operators.
persistence true
persistence_location $DataDir\
log_dest file $DataDir\mosquitto.log
log_type error
log_type warning
log_type notice
"@ | Out-File -FilePath $MqConfPath -Encoding UTF8

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
echo Server running at $externalUrl
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
    # Open the port devices actually connect to. In cloud mode the local broker
    # port is loopback-only, so opening it would expose an anonymous listener
    # to the internet for no reason.
    $fwRules = @(
        @{ Name = "LocalDroid Server $serverPort/tcp";        Port = $serverPort;       Proto = "TCP" },
        @{ Name = "LocalDroid MQTT $mqttExternalPort/tcp";    Port = $mqttExternalPort; Proto = "TCP" },
        @{ Name = "LocalDroid TURN 3478/tcp";                 Port = 3478;              Proto = "TCP" },
        @{ Name = "LocalDroid TURN 3478/udp";                 Port = 3478;              Proto = "UDP" }
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
        Write-Host "  Keep the secret as 'localdroid_turn_secret_2024' to match the clients." -ForegroundColor Yellow
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
Write-Host "Installation : $ScriptDir" -ForegroundColor Cyan
Write-Host "Web UI       : $externalUrl" -ForegroundColor Cyan
Write-Host "Login        : $adminEmail (password set during install)" -ForegroundColor Cyan
Write-Host "MQTT devices : ${mqttExternalHost}:${mqttExternalPort}$(if ($mqttExternalTls) { ' (TLS)' } else { ' (plain)' })" -ForegroundColor Cyan
Write-Host ""
Write-Host "Start the server:" -ForegroundColor Yellow
Write-Host "  Double-click: $(Join-Path $ScriptDir 'start-server.bat')"
Write-Host ""

if (-not $isAirGapped) {
    $certsInPlace = $tlsCert -and (Test-Path $tlsCert) -and $tlsKey -and (Test-Path $tlsKey)
    if (-not $certsInPlace) {
        Write-Host "!! NEXT STEP: TLS certificate" -ForegroundColor Yellow
        Write-Host "   No certificate at $tlsCert yet, so TLS is not active."
        Write-Host "   1. Get one (Let's Encrypt via win-acme, or your commercial cert):"
        Write-Host "        cd C:\win-acme; .\wacs.exe --target manual --host $mqttExternalHost ``" -ForegroundColor Gray
        Write-Host "          --store pemfiles --pemfilespath $(Split-Path -Parent $tlsCert)" -ForegroundColor Gray
        Write-Host "   2. Then run, from this folder:"
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
Write-Host "Re-run a step: .\install-windows-offline.ps1 -ResetStep <step_name>" -ForegroundColor Gray
Write-Host "Start fresh  : .\install-windows-offline.ps1 -Fresh" -ForegroundColor Gray
Write-Host ""
