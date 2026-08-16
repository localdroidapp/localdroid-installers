#Requires -RunAsAdministrator
<#
.SYNOPSIS
    LocalDroid MDM Server - Windows CLOUD (internet-connected) Installation Script
.DESCRIPTION
    Installs LocalDroid MDM on an internet-connected Windows Server so that devices
    can enroll and stay managed from ANYWHERE on the internet - not just the LAN.

    This is the Windows counterpart to install.sh's "Internet Connected (Cloud)"
    mode. Compared to install-windows-offline.ps1 (air-gapped / LAN), it adds
    everything a public deployment actually needs:

      * Prompts for a PUBLIC domain name (or public IP) instead of the LAN IP,
        and pre-flights DNS + public IP + port reachability before touching
        anything.
      * Real HTTPS. Certificates are obtained automatically from Let's Encrypt
        (ACME HTTP-01 via Posh-ACME) and auto-renewed by a scheduled task, or
        you can supply your own PEM files, or terminate TLS on an external
        reverse proxy.
      * MQTT over TLS on 8883 with PER-DEVICE authentication. The loopback
        listener stays anonymous for the server itself; the public listener
        requires the credentials the server renders from Postgres.
      * Cloud .env flags: CLOUD_MODE, ALLOW_REMOTE_ENROLLMENT, TRUST_PROXY,
        ALLOWED_ORIGINS, MQTT_EXTERNAL_USE_TLS, MQTT_AUTH_DIR - the settings
        Zero-Touch enrollment and remote device connections depend on.
      * Runs the server as a real background service (scheduled task as SYSTEM,
        auto-start at boot, auto-restart on crash) instead of a .bat you have to
        keep a console open for.
      * Verifies HTTPS end-to-end before declaring success.

    Run it from the extracted LocalDroid bundle folder - the same layout the
    air-gap zip uses:

        <bundle>\install-windows-cloud.ps1     <- this script
        <bundle>\server\localdroid-server.exe  <- prebuilt server
        <bundle>\server\web\dist\index.html    <- prebuilt web UI
        <bundle>\server\migrations\*.sql
        <bundle>\seed\localdroid-agent.apk     (optional - downloaded if absent)
        <bundle>\installers\*.exe              (optional - downloaded if absent)

    Because a cloud server has internet access, PostgreSQL, Mosquitto and the
    device agents are downloaded automatically when they are not bundled.

    Re-runnable: completed steps are recorded in .install-state-cloud.json and
    skipped on the next run, so a failed cert or firewall step can be fixed and
    the installer re-run without starting over.

.PARAMETER Fresh
    Clear all saved progress and start the installation from scratch.
.PARAMETER ResetStep
    Re-run a single step by name (e.g. -ResetStep tls).
    Step names: deps, config, database, env, license_bootstrap, tls, migrations,
                agents, license_seed, mosquitto, firewall, service
.PARAMETER Staging
    Use the Let's Encrypt STAGING environment for certificates. Staging certs are
    not publicly trusted, but they have far higher rate limits - use this to
    rehearse an install without burning the 5-per-week production limit.
.PARAMETER SkipPreflight
    Skip the DNS / public-IP / port-80 pre-flight checks. Use only when you know
    the checks give a false negative (e.g. split-horizon DNS on the install host).
.EXAMPLE
    .\install-windows-cloud.ps1
    .\install-windows-cloud.ps1 -Staging
    .\install-windows-cloud.ps1 -ResetStep tls
    .\install-windows-cloud.ps1 -Fresh
#>

param(
    [switch]$Fresh,
    [string]$ResetStep,
    [switch]$Staging,
    [switch]$SkipPreflight
)

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallersDir = Join-Path $ScriptDir "installers"
$serverDir     = Join-Path $ScriptDir "server"
$envPath       = Join-Path $serverDir ".env"

# Machine-wide data root. Certificates, MQTT auth files and the ACME account
# live here rather than in the bundle folder so they survive a bundle upgrade
# (extract a new zip over the top and re-run - certs are not re-issued).
$DataRoot     = "C:\ProgramData\localdroid"
$CertDir      = Join-Path $DataRoot "certs"
$MqttAuthDir  = Join-Path $DataRoot "mqtt-auth"
$PoshAcmeHome = Join-Path $DataRoot "posh-acme"
$LogDir       = Join-Path $DataRoot "logs"

$MosquittoDir  = "C:\Program Files\mosquitto"
$MosquittoConf = Join-Path $MosquittoDir "mosquitto.conf"

$ServerTaskName = "LocalDroid MDM Server"
$ReloadTaskName = "LocalDroid MQTT Auth Reload"
$RenewTaskName  = "LocalDroid Certificate Renewal"

# Where agent binaries are fetched from when the bundle has no seed\ folder.
# Same public mirrors install.sh uses - never the private source repo.
$AgentReleaseBase = "https://github.com/localdroidapp/localdroid-installers/releases/latest/download"

$Installers = @{
    PostgreSQL = @{
        FileName    = "postgresql-16-windows-x64.exe"
        Url         = "https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64.exe"
        DisplayName = "PostgreSQL 16"
        Pattern     = "postgresql*.exe"
    }
    Mosquitto = @{
        FileName    = "mosquitto-windows-x64.exe"
        Url         = "https://mosquitto.org/files/binary/win64/mosquitto-2.0.20-install-windows-x64.exe"
        DisplayName = "Mosquitto MQTT"
        Pattern     = "mosquitto*.exe"
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
# State management (mirrors install-windows-offline.ps1 so the two behave alike)
# ---------------------------------------------------------------------------
$StateFile = Join-Path $ScriptDir ".install-state-cloud.json"

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

function Test-StepDone([string]$Step) { return (Get-StateVal "step_$Step") -eq "done" }

function Set-StepComplete([string]$Step) {
    Set-StateVal "step_$Step" "done"
    Write-Success "Step '$Step' complete"
}

# Rewrite (or append) a KEY=value line in the .env file. Built line by line
# rather than with -replace: values here include base64 keys, bcrypt-style
# hashes and paths, and a '$' in a -replace replacement string is a capture-
# group reference that would silently mangle the value.
function Set-EnvValue([string]$Key, [string]$Value) {
    if (-not (Test-Path $envPath)) { return }
    $prefix  = "$Key="
    $found   = $false
    $updated = foreach ($line in (Get-Content $envPath)) {
        if ($line.StartsWith($prefix)) { $found = $true; "$prefix$Value" } else { $line }
    }
    if (-not $found) { $updated = @($updated) + "$prefix$Value" }
    $updated | Set-Content $envPath -Encoding ASCII
}

function Read-WithDefault([string]$Prompt, [string]$Default) {
    if ([string]::IsNullOrEmpty($Default)) {
        return (Read-Host $Prompt)
    }
    $v = Read-Host "$Prompt (Enter for $Default)"
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

# Strip scheme/port/path off a URL or host:port pair, leaving the bare hostname.
function Get-HostName([string]$Value) {
    $h = $Value -replace '^https?://', ''
    $h = ($h -split '/')[0]
    $h = ($h -split ':')[0]
    return $h.Trim()
}

function Test-IsIPAddress([string]$Value) {
    $parsed = [System.Net.IPAddress]::None
    return [System.Net.IPAddress]::TryParse($Value, [ref]$parsed)
}

# ---------------------------------------------------------------------------
# -Fresh / -ResetStep
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

  Windows CLOUD Installation Script
  (internet-connected server - public domain, HTTPS, MQTT over TLS)

"@ -ForegroundColor Blue

if ((Test-Path $StateFile) -and -not $Fresh) {
    $doneSteps = (Get-InstallState).PSObject.Properties | Where-Object { $_.Value -eq "done" }
    if ($doneSteps) {
        Write-Host "Resuming - $($doneSteps.Count) step(s) already done (will be skipped)." -ForegroundColor Cyan
        Write-Host "  To start over: .\install-windows-cloud.ps1 -Fresh" -ForegroundColor Gray
        Write-Host ""
    }
}

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "This script must be run as Administrator!"
    Write-Host "Right-click PowerShell and select 'Run as Administrator'"
    exit 1
}

# TLS 1.2+ for every download this script makes (Server 2016/2019 default to
# SSL3/TLS1.0 for .NET web requests, which every modern host now rejects).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

foreach ($d in @($DataRoot, $CertDir, $MqttAuthDir, $PoshAcmeHome, $LogDir, $InstallersDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ============================================================================
# STEP 0: Cloud prerequisites briefing
# ============================================================================
if (-not (Test-StepDone "config")) {
    Write-Host "=== Cloud mode prerequisites (read before continuing) ===" -ForegroundColor Yellow
    Write-Host "This installer obtains real Let's Encrypt certificates for HTTPS and MQTT"
    Write-Host "TLS. For that to succeed, BEFORE you continue you must have:"
    Write-Host ""
    Write-Host "  1. A public domain name for this server" -ForegroundColor Cyan
    Write-Host "     (used for the web/API and MQTT - one hostname for both is fine)."
    Write-Host "  2. A public DNS A-record for that domain pointing at THIS server's" -ForegroundColor Cyan
    Write-Host "     PUBLIC IP. It must resolve publicly - a LAN-only / split-horizon"
    Write-Host "     record is not enough; Let's Encrypt validates from the internet."
    Write-Host "  3. Port 80/tcp reachable from the internet during install" -ForegroundColor Cyan
    Write-Host "     - the certificate challenge runs an HTTP check on port 80."
    Write-Host "     Open it on the host AND any router / cloud security group."
    Write-Host "  4. Ports 443/tcp (HTTPS) and 8883/tcp (MQTT over TLS) open for" -ForegroundColor Cyan
    Write-Host "     day-to-day device connections."
    Write-Host ""
    Write-Host "If any of these aren't ready, press Ctrl+C, fix them, and re-run - the"
    Write-Host "installer resumes where it left off."
    Write-Host ""
    Read-Host "Press Enter to confirm these are in place and continue"
}

# ============================================================================
# STEP 1: Dependencies (PostgreSQL + Mosquitto)
# ============================================================================
# A cloud box has internet, so anything not bundled in installers\ is fetched.
if (Test-StepDone "deps") {
    Write-Step "Step 1: Dependencies - already installed, skipping"
} else {
    Write-Step "Step 1: Dependencies"

    $needRestart = $false

    # -- PostgreSQL ---------------------------------------------------------
    Write-Host "  Checking PostgreSQL..."
    if (Get-Command psql -ErrorAction SilentlyContinue) {
        Write-Success "PostgreSQL already installed"
    } elseif (Test-Path "C:\Program Files\PostgreSQL\16\bin\psql.exe") {
        Write-Success "PostgreSQL already installed (adding to PATH)"
        $pgBin = "C:\Program Files\PostgreSQL\16\bin"
        $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($cp -notlike "*$pgBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$cp;$pgBin", "Machine")
        }
        $env:Path = "$env:Path;$pgBin"
        $needRestart = $true
    } else {
        $pgLocal = Get-ChildItem -Path $InstallersDir -Filter $Installers.PostgreSQL.Pattern -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $pgLocal) {
            Write-Host "  Downloading $($Installers.PostgreSQL.DisplayName) (~350 MB)..."
            $dest = Join-Path $InstallersDir $Installers.PostgreSQL.FileName
            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $Installers.PostgreSQL.Url -OutFile $dest -UseBasicParsing
                $ProgressPreference = 'Continue'
                $pgLocal = Get-Item $dest
                Write-Success "Downloaded $($Installers.PostgreSQL.FileName)"
            } catch {
                Write-Err "Failed to download PostgreSQL: $_"
                Write-Host "  Download it manually to $InstallersDir and re-run:" -ForegroundColor Yellow
                Write-Host "    $($Installers.PostgreSQL.Url)" -ForegroundColor Gray
                exit 1
            }
        }
        Write-Host "  Running the PostgreSQL installer..."
        Write-Host "  IMPORTANT: note the 'postgres' password you set. Keep port 5432." -ForegroundColor Yellow
        Start-Process -FilePath $pgLocal.FullName -Wait
        $pgBin = "C:\Program Files\PostgreSQL\16\bin"
        if (Test-Path $pgBin) {
            $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($cp -notlike "*$pgBin*") {
                [Environment]::SetEnvironmentVariable("Path", "$cp;$pgBin", "Machine")
            }
            $env:Path = "$env:Path;$pgBin"
        }
        $needRestart = $true
    }

    # -- Mosquitto ----------------------------------------------------------
    Write-Host "  Checking Mosquitto..."
    if (Test-Path (Join-Path $MosquittoDir "mosquitto.exe")) {
        Write-Success "Mosquitto already installed"
    } else {
        $mqLocal = Get-ChildItem -Path $InstallersDir -Filter $Installers.Mosquitto.Pattern -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $mqLocal) {
            Write-Host "  Downloading $($Installers.Mosquitto.DisplayName)..."
            $dest = Join-Path $InstallersDir $Installers.Mosquitto.FileName
            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $Installers.Mosquitto.Url -OutFile $dest -UseBasicParsing
                $ProgressPreference = 'Continue'
                $mqLocal = Get-Item $dest
                Write-Success "Downloaded $($Installers.Mosquitto.FileName)"
            } catch {
                Write-Err "Failed to download Mosquitto: $_"
                Write-Host "  Download it manually to $InstallersDir and re-run:" -ForegroundColor Yellow
                Write-Host "    $($Installers.Mosquitto.Url)" -ForegroundColor Gray
                exit 1
            }
        }
        Write-Host "  Installing Mosquitto (silent)..."
        Start-Process -FilePath $mqLocal.FullName -ArgumentList "/S" -Wait
        $cp = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($cp -notlike "*$MosquittoDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$cp;$MosquittoDir", "Machine")
        }
        $env:Path = "$env:Path;$MosquittoDir"
        $needRestart = $true
    }

    Set-StepComplete "deps"

    if ($needRestart) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host "  Dependencies installed. RESTART PowerShell as Administrator" -ForegroundColor Yellow
        Write-Host "  then run this script again to continue."                     -ForegroundColor Yellow
        Write-Host "  Progress has been saved - completed steps will be skipped."   -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
}

# ============================================================================
# STEP 2: Verify tools
# ============================================================================
Write-Step "Step 2: Verifying Tools"

$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [Environment]::GetEnvironmentVariable("Path", "User")

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    $pgPsql = "C:\Program Files\PostgreSQL\16\bin\psql.exe"
    if (Test-Path $pgPsql) {
        $env:Path = "$(Split-Path $pgPsql);$env:Path"
        Write-Success "psql found at known location"
    } else {
        Write-Err "psql not found! Close ALL PowerShell windows, reopen as Admin, and re-run."
        exit 1
    }
} else {
    Write-Success "psql found"
}

if (Test-Path (Join-Path $MosquittoDir "mosquitto.exe")) {
    Write-Success "mosquitto found"
} else {
    Write-Err "Mosquitto not found at $MosquittoDir"
    exit 1
}

# The cloud installer is source-free by design: a public server should not need
# Go/Node toolchains. Both prebuilt artifacts must be present in the bundle.
$prebuiltServer = Test-Path (Join-Path $serverDir "localdroid-server.exe")
$prebuiltWeb    = Test-Path (Join-Path $serverDir "web\dist\index.html")
if (-not ($prebuiltServer -and $prebuiltWeb)) {
    Write-Err "This bundle is missing the prebuilt server and/or web UI."
    Write-Host "  Expected:" -ForegroundColor Yellow
    Write-Host "    $(Join-Path $serverDir 'localdroid-server.exe')  $(if($prebuiltServer){'[found]'}else{'[MISSING]'})" -ForegroundColor Yellow
    Write-Host "    $(Join-Path $serverDir 'web\dist\index.html')    $(if($prebuiltWeb){'[found]'}else{'[MISSING]'})" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Extract this script into the LocalDroid Windows bundle folder" -ForegroundColor Yellow
    Write-Host "  (the same folder layout the air-gap zip uses) and re-run." -ForegroundColor Yellow
    exit 1
}
Write-Success "Prebuilt server.exe + web/dist present"

# ============================================================================
# STEP 3: Collect configuration
# ============================================================================
Write-Step "Step 3: Server Configuration"

if (Test-StepDone "config") {
    $publicHost        = Get-StateVal "cfg_publicHost"
    $externalUrl       = Get-StateVal "cfg_externalUrl"
    $serverPort        = Get-StateVal "cfg_serverPort"
    $tlsMode           = Get-StateVal "cfg_tlsMode"
    $tlsCert           = Get-StateVal "cfg_tlsCert"
    $tlsKey            = Get-StateVal "cfg_tlsKey"
    $certEmail         = Get-StateVal "cfg_certEmail"
    $mqttPort          = Get-StateVal "cfg_mqttPort"
    $mqttExternalHost  = Get-StateVal "cfg_mqttExternalHost"
    $mqttExternalPort  = Get-StateVal "cfg_mqttExternalPort"
    $mqttDeviceListen  = Get-StateVal "cfg_mqttDeviceListen"
    $licenseServerUrl  = Get-StateVal "cfg_licenseServerUrl"
    $adminEmail        = Get-StateVal "cfg_adminEmail"
    $adminPasswordPlain = Get-StateVal "cfg_adminPassword"
    Write-Success "Loaded saved configuration ($externalUrl, TLS mode: $tlsMode)"
} else {
    # -- Public address -----------------------------------------------------
    Write-Host ""
    Write-Host "=== Public Server Address ===" -ForegroundColor Yellow
    Write-Host "The domain name devices and admins use to reach this server over the"
    Write-Host "internet. A domain name is strongly preferred - it is required for"
    Write-Host "Let's Encrypt certificates and lets you move servers without"
    Write-Host "re-enrolling every device."
    Write-Host ""
    Write-Host "  Examples: mdm.yourcompany.com   |   cloud.localdroid.app" -ForegroundColor Cyan
    Write-Host ""
    $publicHost = ""
    while ([string]::IsNullOrWhiteSpace($publicHost)) {
        $publicHost = (Read-Host "Public domain name for this server").Trim()
        $publicHost = Get-HostName $publicHost
        if ([string]::IsNullOrWhiteSpace($publicHost)) {
            Write-Warn "A public domain (or public IP) is required for cloud mode."
        }
    }
    $publicHostIsIP = Test-IsIPAddress $publicHost
    if ($publicHostIsIP) {
        Write-Warn "You entered an IP address. Let's Encrypt cannot issue certificates"
        Write-Host "         for bare IPs - automatic HTTPS will not be available and" -ForegroundColor Yellow
        Write-Host "         Zero-Touch enrollment (which requires TLS) will not work." -ForegroundColor Yellow
        Write-Host "         Choose 'existing certificate' or 'external proxy' below," -ForegroundColor Yellow
        Write-Host "         or press Ctrl+C and re-run with a domain name." -ForegroundColor Yellow
    }

    # -- TLS / reverse proxy ------------------------------------------------
    Write-Host ""
    Write-Host "=== HTTPS / TLS ===" -ForegroundColor Yellow
    Write-Host "How should HTTPS be handled?"
    Write-Host ""
    Write-Host "  1. Automatic (recommended)" -ForegroundColor Cyan
    Write-Host "     Get free Let's Encrypt certificates now and auto-renew them."
    Write-Host "     The LocalDroid server terminates TLS itself on port 443 - no"
    Write-Host "     IIS, nginx or Caddy needed. Requires port 80 reachable now."
    Write-Host ""
    Write-Host "  2. I already have a certificate" -ForegroundColor Cyan
    Write-Host "     Supply your own PEM certificate + private key files (for"
    Write-Host "     example from your own ACME client or a commercial CA)."
    Write-Host ""
    Write-Host "  3. TLS is handled by a reverse proxy in front of this server" -ForegroundColor Cyan
    Write-Host "     IIS/ARR, nginx, Caddy, Cloudflare, an AWS/Azure load balancer..."
    Write-Host "     This server will listen on a plain HTTP backend port and this"
    Write-Host "     installer will NOT touch certificates."
    Write-Host ""
    $tlsChoice = Read-WithDefault "Select (1, 2 or 3)" "1"

    $certEmail = ""
    switch ($tlsChoice) {
        "2" {
            $tlsMode    = "existing"
            $serverPort = Read-WithDefault "HTTPS port for the server to listen on" "443"
            Write-Host ""
            Write-Host "Paths to PEM files. The certificate file must be the FULL CHAIN" -ForegroundColor Yellow
            Write-Host "(leaf + intermediates) or Android devices will reject it." -ForegroundColor Yellow
            $tlsCert = (Read-Host "Path to certificate (fullchain.pem)").Trim('"')
            $tlsKey  = (Read-Host "Path to private key (privkey.pem)").Trim('"')
            if (-not (Test-Path $tlsCert)) { Write-Warn "Certificate not found at $tlsCert - fix it before starting the server." }
            if (-not (Test-Path $tlsKey))  { Write-Warn "Private key not found at $tlsKey - fix it before starting the server." }
        }
        "3" {
            $tlsMode    = "proxy"
            $serverPort = Read-WithDefault "Plain HTTP backend port for this server" "8080"
            $tlsCert    = ""
            $tlsKey     = ""
        }
        default {
            $tlsMode    = "acme"
            $serverPort = Read-WithDefault "HTTPS port for the server to listen on" "443"
            $tlsCert    = Join-Path $CertDir "fullchain.pem"
            $tlsKey     = Join-Path $CertDir "privkey.pem"
            Write-Host ""
            Write-Host "Let's Encrypt sends expiry warnings to this address." -ForegroundColor Gray
            $certEmail = Read-WithDefault "Email for certificate renewal notices" "admin@$publicHost"
        }
    }

    # -- External URL -------------------------------------------------------
    Write-Host ""
    Write-Host "=== External URL ===" -ForegroundColor Yellow
    Write-Host "The public URL devices use to reach the API. Always the public"
    Write-Host "domain - never the backend port."
    $defaultUrl = if ($tlsMode -eq "proxy") { "https://$publicHost" } else {
        if ($serverPort -eq "443") { "https://$publicHost" } else { "https://${publicHost}:$serverPort" }
    }
    $externalUrl = Read-WithDefault "External API URL" $defaultUrl
    # Auto-prefix the scheme. Without one the server emits http:// in enrollment
    # QR codes, the proxy 301s to https://, and Android's HttpURLConnection
    # refuses to follow the cross-scheme redirect - enrollment silently fails.
    if ($externalUrl -notmatch '^https?://') {
        $externalUrl = "https://$externalUrl"
        Write-Host "  No scheme provided - assuming HTTPS: $externalUrl" -ForegroundColor Yellow
    }
    $externalUrl = $externalUrl.TrimEnd('/')

    # -- MQTT ---------------------------------------------------------------
    Write-Host ""
    Write-Host "=== MQTT (real-time device channel) ===" -ForegroundColor Yellow
    Write-Host "The broker runs on this server. It gets two listeners:"
    Write-Host "  - a loopback listener the LocalDroid server itself uses (127.0.0.1)"
    Write-Host "  - a public listener your devices connect to, with per-device"
    Write-Host "    credentials that the server renders from the database."
    Write-Host ""
    $mqttPort = Read-WithDefault "Local (loopback) broker port" "1883"
    $mqttExternalHost = Read-WithDefault "MQTT hostname for devices (public)" $publicHost
    Write-Host ""
    Write-Host "  Port 8883 = MQTT over TLS (recommended for the internet)." -ForegroundColor Gray
    Write-Host "  Port 1883 = unencrypted. Only sane behind a VPN." -ForegroundColor Gray
    $mqttExternalPort = Read-WithDefault "MQTT port for devices" "8883"

    if ($tlsMode -eq "proxy") {
        # An external proxy terminates MQTT TLS and forwards plain to this host.
        # Use a dedicated plain port so it never collides with the anonymous
        # loopback listener on 1883.
        $mqttDeviceListen = "1884"
        Write-Host ""
        Write-Host "  External proxy mode: the broker's device listener will be plain" -ForegroundColor Cyan
        Write-Host "  TCP on port 1884. Forward ${mqttExternalPort}/tcp (TLS) to this" -ForegroundColor Cyan
        Write-Host "  host's port 1884 from your proxy / load balancer." -ForegroundColor Cyan
    } else {
        $mqttDeviceListen = $mqttExternalPort
    }

    # -- Licensing ----------------------------------------------------------
    Write-Host ""
    Write-Host "Licensing:" -ForegroundColor Yellow
    if ($null -ne $env:LICENSE_SERVER_URL) {
        $licenseServerUrl = $env:LICENSE_SERVER_URL
    } else {
        $licenseServerUrl = "https://localdroid.app"
    }
    if ([string]::IsNullOrEmpty($licenseServerUrl)) {
        Write-Host "  License authority: <none>" -ForegroundColor Yellow
    } else {
        Write-Host "  License authority: $licenseServerUrl" -ForegroundColor Green
    }

    # -- Admin login --------------------------------------------------------
    Write-Host ""
    Write-Host "Administrator Login:" -ForegroundColor Yellow
    Write-Host "  Initial admin user for the MDM web UI. The server seeds this on"
    Write-Host "  first boot via LOCALDROID_ADMIN_* env vars in .env, then bcrypt-"
    Write-Host "  hashes the password."
    $adminEmail = Read-WithDefault "Admin email" "admin@localdroid.app"
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

    Set-StateVal "cfg_publicHost"       $publicHost
    Set-StateVal "cfg_externalUrl"      $externalUrl
    Set-StateVal "cfg_serverPort"       $serverPort
    Set-StateVal "cfg_tlsMode"          $tlsMode
    Set-StateVal "cfg_tlsCert"          $tlsCert
    Set-StateVal "cfg_tlsKey"           $tlsKey
    Set-StateVal "cfg_certEmail"        $certEmail
    Set-StateVal "cfg_mqttPort"         $mqttPort
    Set-StateVal "cfg_mqttExternalHost" $mqttExternalHost
    Set-StateVal "cfg_mqttExternalPort" $mqttExternalPort
    Set-StateVal "cfg_mqttDeviceListen" $mqttDeviceListen
    Set-StateVal "cfg_licenseServerUrl" $licenseServerUrl
    Set-StateVal "cfg_adminEmail"       $adminEmail
    Set-StateVal "cfg_adminPassword"    $adminPasswordPlain
    Set-StepComplete "config"
}

$apiDomain  = Get-HostName $externalUrl
$mqttDomain = Get-HostName $mqttExternalHost
$mqttExternalUseTls = if ($mqttExternalPort -eq "8883") { "true" } else { "false" }
# Only trust X-Forwarded-* when something is actually in front of us. Trusting
# it with no proxy would let any client spoof its source IP past the login
# brute-force limiter.
$trustProxy = if ($tlsMode -eq "proxy") { "true" } else { "false" }

# ============================================================================
# STEP 3b: Pre-flight - DNS, public IP, port availability
# ============================================================================
if ($SkipPreflight) {
    Write-Step "Step 3b: Pre-flight checks - skipped (-SkipPreflight)"
} else {
    Write-Step "Step 3b: Pre-flight Checks"

    $publicIp = $null
    try {
        $publicIp = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 10).ip
        Write-Success "This server's public IP: $publicIp"
    } catch {
        Write-Warn "Could not determine this server's public IP (no outbound internet?)."
    }

    foreach ($d in @($apiDomain, $mqttDomain) | Select-Object -Unique) {
        if (Test-IsIPAddress $d) {
            Write-Host "  $d is a literal IP - skipping DNS check." -ForegroundColor Gray
            continue
        }
        try {
            # Ask a public resolver, not the host's - a split-horizon internal
            # DNS server would happily return a LAN answer that Let's Encrypt
            # will never see.
            $records = Resolve-DnsName -Name $d -Type A -Server "1.1.1.1" -ErrorAction Stop |
                Where-Object { $_.Type -eq "A" }
            $ips = @($records.IPAddress)
            if ($ips.Count -eq 0) {
                Write-Warn "$d has no public A-record. Let's Encrypt validation will fail."
            } elseif ($publicIp -and ($ips -notcontains $publicIp)) {
                Write-Warn "$d resolves to $($ips -join ', ') but this server's public IP is $publicIp."
                Write-Host "         If this server is behind NAT / a load balancer that forwards" -ForegroundColor Yellow
                Write-Host "         80 and 443 here, that is fine. Otherwise fix the A-record." -ForegroundColor Yellow
            } else {
                Write-Success "$d resolves publicly to $($ips -join ', ')"
            }
        } catch {
            Write-Warn "Public DNS lookup for $d failed: $($_.Exception.Message)"
            Write-Host "         Certificate issuance needs a public A-record for this name." -ForegroundColor Yellow
        }
    }

    # Port 80 must be free for the ACME HTTP-01 challenge.
    if ($tlsMode -eq "acme") {
        $listener80 = Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($listener80) {
            $owner = (Get-Process -Id $listener80.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            Write-Warn "Port 80 is already in use by '$owner' (PID $($listener80.OwningProcess))."
            Write-Host "         The Let's Encrypt HTTP-01 challenge needs port 80 free." -ForegroundColor Yellow
            Write-Host "         Stop that service (commonly IIS: 'iisreset /stop' or" -ForegroundColor Yellow
            Write-Host "         'Stop-Service W3SVC') and re-run, or choose TLS option 2/3." -ForegroundColor Yellow
        } else {
            Write-Success "Port 80 is free for the certificate challenge"
        }
    }

    $portInUse = Get-NetTCPConnection -LocalPort ([int]$serverPort) -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($portInUse) {
        $owner = (Get-Process -Id $portInUse.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Write-Warn "Port $serverPort is already in use by '$owner' - the server will fail to bind."
    } else {
        Write-Success "Port $serverPort is free for the LocalDroid server"
    }
    Write-Host ""
}

# ============================================================================
# STEP 4: PostgreSQL database
# ============================================================================
Write-Step "Step 4: PostgreSQL Database"

if (Test-StepDone "database") {
    Write-Success "Database already configured, skipping"
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
    Write-Host "(The password you set during the PostgreSQL install.)" -ForegroundColor Gray
    $pgSec = Read-Host "PostgreSQL 'postgres' password" -AsSecureString
    $pgPasswordPlain = [System.Net.NetworkCredential]::new("", $pgSec).Password
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
# STEP 5: .env configuration file (CLOUD MODE)
# ============================================================================
Write-Step "Step 5: Configuration File"

if (Test-StepDone "env") {
    Write-Success "Configuration file already created, skipping"
} else {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes); $rng.Dispose()
    $jwtSecret = [Convert]::ToBase64String($bytes)

    $enableTls = if ($tlsMode -eq "proxy") { "false" } else { "true" }

    if (-not (Test-Path $serverDir)) { New-Item -ItemType Directory -Path $serverDir -Force | Out-Null }

    @"
# LocalDroid MDM Server Configuration - CLOUD MODE
# Generated by install-windows-cloud.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

# Server
SERVER_HOST=0.0.0.0
SERVER_PORT=$serverPort
PUBLIC_URL=$externalUrl
EXTERNAL_URL=$externalUrl
# CORS allowlist - must include EXTERNAL_URL so browsers on that origin can
# call /api/*. Empty => preflights fail (System Health flags this).
ALLOWED_ORIGINS=$externalUrl

# TLS/SSL (required for Zero-Touch enrollment over the internet).
# ENABLE_TLS=false means something else terminates TLS in front of this server.
ENABLE_TLS=$enableTls
TLS_CERT=$tlsCert
TLS_KEY=$tlsKey

# Database
DB_HOST=localhost
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$pgPasswordPlain
DB_NAME=localdroid
DB_SSLMODE=disable
DB_MAX_CONNS=50

# MQTT - the server's own connection to the local broker. This is always
# loopback plain text, so MQTT_USE_TLS stays false even when devices use TLS
# externally: this setting governs THIS process's connection, not the devices'.
MQTT_HOST=localhost
MQTT_PORT=$mqttPort
MQTT_USE_TLS=false
MQTT_USERNAME=
MQTT_PASSWORD=

# MQTT - what devices connect to (public hostname/port)
MQTT_EXTERNAL_HOST=$mqttExternalHost
MQTT_EXTERNAL_PORT=$mqttExternalPort
MQTT_EXTERNAL_USE_TLS=$mqttExternalUseTls

# Where the server renders per-device MQTT credentials + ACLs from Postgres.
# A watcher task restarts Mosquitto when these change so new enrollments can
# connect without manual intervention.
MQTT_AUTH_DIR=$MqttAuthDir

# JWT
JWT_SECRET=$jwtSecret
JWT_ACCESS_EXPIRY=60
JWT_REFRESH_EXPIRY=168
JWT_ISSUER=localdroid-cloud

# Cloud mode flags
DEPLOYMENT_MODE=cloud
CLOUD_MODE=true
ALLOW_REMOTE_ENROLLMENT=true

# Trust X-Forwarded-For from the reverse proxy. Required so the login
# brute-force limiter sees real client IPs instead of the proxy's. Only enable
# when this server really is behind a single trusted proxy.
TRUST_PROXY=$trustProxy

# Storage
STORAGE_PATH=./storage
MAX_FILE_SIZE=500

# APK signing-cert checksum for Zero-Touch enrollment - filled in from the
# bundled sidecar in the agents step below.
APK_SIGNATURE_CHECKSUM=

# Licensing - the LocalDroid license-authority public key ships as the default
# so a signed license.lic verifies out of the box (the key is public: it can
# only VERIFY licenses, never create them). Refreshed from the portal below.
LICENSE_SERVER_URL=$licenseServerUrl
LICENSE_PUBLIC_KEY=woL+6yGOhnbu9E+iALVqMzIx1Uez7Rk2kP8pEXIQDDc=

# Administrator credentials - seeded into the users table on first boot.
# Setting LOCALDROID_ADMIN_PASSWORD here is authoritative: changing it resets
# the admin password on the next restart. Comment both lines out after first
# login if you prefer to manage the admin from the UI.
LOCALDROID_ADMIN_EMAIL=$adminEmail
LOCALDROID_ADMIN_PASSWORD=$adminPasswordPlain
"@ | Out-File -FilePath $envPath -Encoding ASCII

    Set-StepComplete "env"
    Write-Success "Configuration saved: $envPath"
}

# ============================================================================
# STEP 5b: License public key bootstrap
# ============================================================================
Write-Step "Step 5b: License Public Key"
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
            Set-EnvValue "LICENSE_PUBLIC_KEY" $pkResp.public_key
            Write-Success "License public key written to $envPath"
            Set-StepComplete "license_bootstrap"
        } else {
            Write-Host "  Response did not contain a public_key field - skipping."
        }
    } catch {
        Write-Host "  Could not reach $licenseServerUrl/api/public-key - skipping."
        Write-Host "  The MDM will start in unlimited free mode."
    }
}

# ============================================================================
# STEP 6: TLS certificates
# ============================================================================
Write-Step "Step 6: TLS Certificates"

$certsReady = $false

if ($tlsMode -eq "proxy") {
    $lanIp = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } |
        Select-Object -First 1).IPAddress
    Write-Host "  External reverse proxy handles TLS - no certificates issued here." -ForegroundColor Cyan
    Write-Host "  Point your proxy at:" -ForegroundColor Cyan
    Write-Host "    HTTPS $apiDomain           -> http://${lanIp}:$serverPort" -ForegroundColor Gray
    Write-Host "    MQTT/TLS ${mqttDomain}:$mqttExternalPort -> ${lanIp}:$mqttDeviceListen (plain TCP)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Forward the real client IP as X-Forwarded-For - TRUST_PROXY is on." -ForegroundColor Gray
} elseif ($tlsMode -eq "existing") {
    if ((Test-Path $tlsCert) -and (Test-Path $tlsKey)) {
        Write-Success "Using supplied certificate: $tlsCert"
        $certsReady = $true
    } else {
        Write-Warn "Supplied certificate files are not present yet:"
        Write-Host "    cert: $tlsCert" -ForegroundColor Yellow
        Write-Host "    key : $tlsKey" -ForegroundColor Yellow
        Write-Host "  Put them in place before starting the server." -ForegroundColor Yellow
    }
} elseif (Test-StepDone "tls") {
    Write-Success "Certificates already issued, skipping"
    $certsReady = (Test-Path $tlsCert) -and (Test-Path $tlsKey)
} else {
    # Posh-ACME is a pure-PowerShell ACME client from the PowerShell Gallery -
    # no binary to download and pin, and it writes PEM files directly, which is
    # exactly what both the Go server and Mosquitto want.
    $certDomains = @($apiDomain, $mqttDomain) | Select-Object -Unique |
        Where-Object { -not (Test-IsIPAddress $_) }

    if ($certDomains.Count -eq 0) {
        Write-Warn "No DNS names to certify (public address is a bare IP)."
        Write-Host "  Let's Encrypt cannot issue certificates for IP addresses." -ForegroundColor Yellow
        Write-Host "  Re-run with a domain name, or use TLS option 2 with your own cert." -ForegroundColor Yellow
    } else {
        Write-Host "  Certifying: $($certDomains -join ', ')"

        # Fixed store location so the SYSTEM-run renewal task sees the same
        # account and orders this interactive install created.
        [Environment]::SetEnvironmentVariable("POSHACME_HOME", $PoshAcmeHome, "Machine")
        $env:POSHACME_HOME = $PoshAcmeHome

        $acmeOk = $true
        if (-not (Get-Module -ListAvailable -Name Posh-ACME)) {
            Write-Host "  Installing the Posh-ACME module from the PowerShell Gallery..."
            try {
                if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
                }
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
                Install-Module -Name Posh-ACME -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
                Write-Success "Posh-ACME installed"
            } catch {
                $acmeOk = $false
                Write-Err "Could not install Posh-ACME: $($_.Exception.Message)"
                Write-Host "  This server needs access to https://www.powershellgallery.com." -ForegroundColor Yellow
                Write-Host "  Install it manually, then re-run:" -ForegroundColor Yellow
                Write-Host "    Install-Module Posh-ACME -Scope AllUsers -Force" -ForegroundColor Gray
                Write-Host "    .\install-windows-cloud.ps1 -ResetStep tls" -ForegroundColor Gray
                Write-Host "  Or re-run and choose TLS option 2 with your own certificate." -ForegroundColor Yellow
            }
        }

        if ($acmeOk) {
            try {
                Import-Module Posh-ACME -Force -ErrorAction Stop
                $acmeServer = if ($Staging) { "LE_STAGE" } else { "LE_PROD" }
                if ($Staging) { Write-Warn "Using the Let's Encrypt STAGING CA - certificates will NOT be trusted." }
                Set-PAServer $acmeServer

                # Free port 80 for the HTTP-01 challenge, then hand it back.
                $w3svcWasRunning = $false
                $w3svc = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
                if ($w3svc -and $w3svc.Status -eq "Running") {
                    Write-Host "  Stopping IIS (W3SVC) to free port 80 for the challenge..."
                    Stop-Service -Name "W3SVC" -Force
                    $w3svcWasRunning = $true
                }

                # Open 80 first - the CA has to reach the temporary listener.
                if (-not (Get-NetFirewallRule -DisplayName "LocalDroid ACME 80/tcp" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -DisplayName "LocalDroid ACME 80/tcp" -Direction Inbound `
                        -Action Allow -Protocol TCP -LocalPort 80 -ErrorAction SilentlyContinue | Out-Null
                }

                Write-Host "  Requesting certificate from Let's Encrypt (HTTP-01 on port 80)..."
                Write-Host "  This takes 15-60 seconds." -ForegroundColor Gray

                # No -Force: if a valid certificate for these names already
                # exists, reuse it. Re-running -ResetStep tls must not burn the
                # Let's Encrypt limit of 5 certificates per domain per week.
                $cert = New-PACertificate -Domain $certDomains -AcceptTOS -Contact $certEmail `
                    -Plugin WebSelfHost -PluginArgs @{ WebSelfHostPort = 80 } `
                    -Install:$false -ErrorAction Stop

                if ($w3svcWasRunning) { Start-Service -Name "W3SVC" }

                if ($cert -and (Test-Path $cert.FullChainFile)) {
                    Copy-Item $cert.FullChainFile (Join-Path $CertDir "fullchain.pem") -Force
                    Copy-Item $cert.KeyFile       (Join-Path $CertDir "privkey.pem")   -Force
                    if ($cert.ChainFile -and (Test-Path $cert.ChainFile)) {
                        Copy-Item $cert.ChainFile (Join-Path $CertDir "chain.pem") -Force
                    }
                    Write-Success "Certificate issued and copied to $CertDir"
                    Write-Host "    Expires: $($cert.NotAfter)" -ForegroundColor Gray
                    $certsReady = $true
                    Set-StepComplete "tls"
                } else {
                    Write-Err "Certificate request returned no usable files."
                }
            } catch {
                if ($w3svcWasRunning) { Start-Service -Name "W3SVC" -ErrorAction SilentlyContinue }
                Write-Err "Certificate issuance failed: $($_.Exception.Message)"
                Write-Host ""
                Write-Host "  Most common causes:" -ForegroundColor Yellow
                Write-Host "    - DNS A-record for $($certDomains -join '/') does not point here" -ForegroundColor Yellow
                Write-Host "    - Port 80/tcp is blocked at the router / cloud security group" -ForegroundColor Yellow
                Write-Host "    - Another process is holding port 80 on this host" -ForegroundColor Yellow
                Write-Host "    - Let's Encrypt rate limit hit (5 certs per domain per week)" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Fix the cause and retry just this step:" -ForegroundColor Yellow
                Write-Host "    .\install-windows-cloud.ps1 -ResetStep tls" -ForegroundColor Gray
                Write-Host "  Rehearse without burning the rate limit:" -ForegroundColor Yellow
                Write-Host "    .\install-windows-cloud.ps1 -ResetStep tls -Staging" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  The rest of the install continues - the server just won't serve" -ForegroundColor Yellow
                Write-Host "  HTTPS until a certificate is in place." -ForegroundColor Yellow
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Renewal task (ACME mode only). Let's Encrypt certs last 90 days; Posh-ACME
# renews inside the last 30. Re-copies the PEMs and bounces both services so
# the new cert is actually picked up.
# ---------------------------------------------------------------------------
if ($tlsMode -eq "acme" -and $certsReady) {
    $renewScript = Join-Path $DataRoot "renew-certs.ps1"
    $renewBody = @'
# LocalDroid certificate renewal - generated by install-windows-cloud.ps1
# Runs daily as SYSTEM. Posh-ACME only renews certificates inside their
# renewal window, so running this every day is cheap and safe.
$ErrorActionPreference = "Stop"
$env:POSHACME_HOME = "__POSHACME_HOME__"
$certDir  = "__CERT_DIR__"
$logFile  = "__LOG_DIR__\cert-renewal.log"

function Write-Log($m) { "$(Get-Date -Format 'u')  $m" | Out-File $logFile -Append -Encoding UTF8 }

try {
    Import-Module Posh-ACME -Force

    # The HTTP-01 challenge needs port 80. The LocalDroid server listens on
    # 443, so 80 is normally free - but stop IIS if it grabbed it.
    $w3svcWasRunning = $false
    $w3svc = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
    if ($w3svc -and $w3svc.Status -eq "Running") {
        Stop-Service -Name "W3SVC" -Force; $w3svcWasRunning = $true
    }

    $before = if (Test-Path "$certDir\fullchain.pem") { (Get-FileHash "$certDir\fullchain.pem").Hash } else { "" }

    Submit-Renewal -AllOrders -ErrorAction Stop | ForEach-Object {
        if ($_.FullChainFile -and (Test-Path $_.FullChainFile)) {
            Copy-Item $_.FullChainFile "$certDir\fullchain.pem" -Force
            Copy-Item $_.KeyFile       "$certDir\privkey.pem"   -Force
            if ($_.ChainFile -and (Test-Path $_.ChainFile)) {
                Copy-Item $_.ChainFile "$certDir\chain.pem" -Force
            }
            Write-Log "Renewed and copied certificate for $($_.MainDomain) (expires $($_.NotAfter))"
        }
    }

    if ($w3svcWasRunning) { Start-Service -Name "W3SVC" }

    $after = if (Test-Path "$certDir\fullchain.pem") { (Get-FileHash "$certDir\fullchain.pem").Hash } else { "" }
    if ($before -ne $after) {
        Write-Log "Certificate changed - restarting Mosquitto and the LocalDroid server"
        Restart-Service -Name "mosquitto" -ErrorAction SilentlyContinue
        Stop-ScheduledTask  -TaskName "__SERVER_TASK__" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Start-ScheduledTask -TaskName "__SERVER_TASK__" -ErrorAction SilentlyContinue
    } else {
        Write-Log "No renewal needed"
    }
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
'@
    $renewBody = $renewBody.
        Replace("__POSHACME_HOME__", $PoshAcmeHome).
        Replace("__CERT_DIR__",      $CertDir).
        Replace("__LOG_DIR__",       $LogDir).
        Replace("__SERVER_TASK__",   $ServerTaskName)
    $renewBody | Out-File -FilePath $renewScript -Encoding UTF8

    try {
        Unregister-ScheduledTask -TaskName $RenewTaskName -Confirm:$false -ErrorAction SilentlyContinue
        $act  = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$renewScript`""
        # 03:17 rather than a round hour - Let's Encrypt asks clients not to all
        # wake on the same minute.
        $trg  = New-ScheduledTaskTrigger -Daily -At "3:17AM"
        $prn  = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $set  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
        Register-ScheduledTask -TaskName $RenewTaskName -Action $act -Trigger $trg `
            -Principal $prn -Settings $set -Description "Renew LocalDroid MDM TLS certificates" | Out-Null
        Write-Success "Certificate auto-renewal scheduled daily at 03:17 (task: $RenewTaskName)"
    } catch {
        Write-Warn "Could not register the renewal task: $($_.Exception.Message)"
        Write-Host "  Run this manually before the cert expires: $renewScript" -ForegroundColor Yellow
    }
}

# Keep .env pointing at whatever we actually ended up with.
Set-EnvValue "TLS_CERT" $tlsCert
Set-EnvValue "TLS_KEY"  $tlsKey

# ============================================================================
# STEP 7: Database migrations
# ============================================================================
Write-Step "Step 7: Database Migrations"

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
        Write-Success "Migrations completed ($($migrations.Count) files)"
    } else {
        Write-Warn "Migrations directory not found: $migrationsDir"
        Set-StepComplete "migrations"
    }
}

# ============================================================================
# STEP 8: Agent binaries (Android APK + Windows EXE)
# ============================================================================
# Bundled seed\ always wins. A thin cloud bundle without seed\ self-provisions
# from the public installers release - never from the private source repo.
Write-Step "Step 8: Device Agents"

$agentStorageDir = Join-Path $serverDir "storage\agent"
New-Item -ItemType Directory -Path $agentStorageDir -Force | Out-Null

if (Test-StepDone "agents") {
    Write-Success "Agents already installed, skipping"
} else {
    function Install-AgentFile {
        param([string]$FileName, [string]$Label, [switch]$Optional)

        $dest = Join-Path $agentStorageDir $FileName
        if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
            Write-Success "$Label already present - leaving it alone"
            return $true
        }

        $candidates = @(
            (Join-Path $ScriptDir "seed\$FileName"),
            (Join-Path $ScriptDir "releases\$FileName")
        )
        $local = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($local) {
            Copy-Item $local $dest -Force
            Write-Success "$Label copied from $local"
            return $true
        }

        Write-Host "  $Label not bundled - downloading from the public release..."
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri "$AgentReleaseBase/$FileName" -OutFile $dest -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = 'Continue'
            Write-Success "$Label downloaded"
            return $true
        } catch {
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
            if ($Optional) {
                Write-Host "  $Label unavailable - continuing." -ForegroundColor Gray
            } else {
                Write-Warn "Could not obtain $Label ($($_.Exception.Message))."
                Write-Host "         Place it at $dest and re-run:" -ForegroundColor Yellow
                Write-Host "           .\install-windows-cloud.ps1 -ResetStep agents" -ForegroundColor Gray
            }
            return $false
        }
    }

    Install-AgentFile -FileName "localdroid-agent.apk" -Label "Android agent APK" | Out-Null
    Install-AgentFile -FileName "localdroid-agent.exe" -Label "Windows agent EXE" | Out-Null

    # APK signing-cert checksum. Zero-Touch enrollment verifies the APK against
    # this value, so an internet-facing install genuinely needs it.
    $apkDest = Join-Path $agentStorageDir "localdroid-agent.apk"
    if (Test-Path $apkDest) {
        $sidecarName = "localdroid-agent.apk.cert-sha256"
        $apkChecksum = ""
        $sidecar = @(
            (Join-Path $ScriptDir "seed\$sidecarName"),
            (Join-Path $ScriptDir "releases\$sidecarName")
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($sidecar) {
            $apkChecksum = (Get-Content $sidecar -Raw).Trim()
            Write-Host "  APK checksum loaded from sidecar: $(Split-Path -Leaf $sidecar)"
        } else {
            try {
                $tmp = Join-Path $env:TEMP $sidecarName
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri "$AgentReleaseBase/$sidecarName" -OutFile $tmp -UseBasicParsing -ErrorAction Stop
                $ProgressPreference = 'Continue'
                $apkChecksum = (Get-Content $tmp -Raw).Trim()
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                Write-Host "  APK checksum downloaded from the public release"
            } catch {
                Write-Warn "No APK signing-cert checksum available."
                Write-Host "         Zero-Touch enrollment will fail until APK_SIGNATURE_CHECKSUM" -ForegroundColor Yellow
                Write-Host "         is set in $envPath. Normal QR enrollment is unaffected." -ForegroundColor Yellow
            }
        }
        if ($apkChecksum) {
            Set-EnvValue "APK_SIGNATURE_CHECKSUM" $apkChecksum
            Write-Success "APK signing-cert checksum set: $apkChecksum"
        }
    }

    Set-StepComplete "agents"
}

# ============================================================================
# STEP 8b: Bundled customer license (optional)
# ============================================================================
Write-Step "Step 8b: Customer License"
if (Test-StepDone "license_seed") {
    Write-Success "License already installed, skipping"
} else {
    $bundledLicense = Join-Path $ScriptDir "license.lic"
    if (Test-Path $bundledLicense) {
        $licenseDest = Join-Path $serverDir "license.lic"
        Copy-Item $bundledLicense $licenseDest -Force
        Set-EnvValue "LOCALDROID_LICENSE_FILE" $licenseDest
        Write-Success "License staged - MDM will auto-activate on first start"
    } else {
        Write-Host "  No bundled license.lic - MDM starts unlicensed (activate later under Settings -> License)." -ForegroundColor Gray
    }
    Set-StepComplete "license_seed"
}

# ============================================================================
# STEP 9: Mosquitto - cloud configuration with per-device authentication
# ============================================================================
# Air-gapped installs run one anonymous LAN listener. A public broker must not:
# anyone who can reach 8883 could otherwise subscribe to every device topic.
# So: the loopback listener stays anonymous for the server's own connection,
# and the public listener requires the per-device credentials the server
# renders from Postgres into MQTT_AUTH_DIR on each enrollment.
Write-Step "Step 9: Mosquitto (cloud, per-device auth)"

if (Test-StepDone "mosquitto") {
    Write-Success "Mosquitto already configured, skipping"
} else {
    # Seed empty auth files so the broker starts before the first enrollment.
    foreach ($f in @("passwd", "acl")) {
        $p = Join-Path $MqttAuthDir $f
        if (-not (Test-Path $p)) { New-Item -ItemType File -Path $p -Force | Out-Null }
    }

    # Mosquitto's config parser treats a backslash as an escape character, so
    # every path in mosquitto.conf uses forward slashes (Windows accepts them).
    $confDataRoot = $DataRoot.Replace('\', '/')
    $confLogDir   = $LogDir.Replace('\', '/')
    $confAuthDir  = $MqttAuthDir.Replace('\', '/')

    $mqttTlsBlock = ""
    $deviceListener = "listener $mqttDeviceListen 0.0.0.0"

    if ($tlsMode -eq "proxy") {
        Write-Host "  External proxy terminates MQTT TLS - device listener is plain on $mqttDeviceListen." -ForegroundColor Cyan
    } elseif ($certsReady) {
        # Point the broker straight at the same PEMs the renewal task keeps up
        # to date, so a renewed cert reaches MQTT without a second copy step.
        $mqttTlsBlock = @"
certfile $($tlsCert.Replace('\','/'))
keyfile  $($tlsKey.Replace('\','/'))
"@
        Write-Host "  MQTT over TLS on $mqttDeviceListen using $tlsCert" -ForegroundColor Cyan
    } else {
        Write-Warn "No certificate available - writing the device listener WITHOUT TLS."
        Write-Host "         Devices will connect unencrypted. Fix the certificate step, then run:" -ForegroundColor Yellow
        Write-Host "           .\install-windows-cloud.ps1 -ResetStep tls" -ForegroundColor Gray
        Write-Host "           .\install-windows-cloud.ps1 -ResetStep mosquitto" -ForegroundColor Gray
    }

    $mosquittoConfBody = @"
# LocalDroid MQTT Configuration (cloud)
# Generated by install-windows-cloud.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')
#
# Per-listener settings: the loopback listener stays anonymous for the
# LocalDroid server while the public listener enforces per-device credentials.
per_listener_settings true

# Global resource limits - a runaway client can't exhaust the broker.
max_queued_messages 200
max_inflight_messages 20
message_size_limit 10485760
max_keepalive 120

persistence true
persistence_location $confDataRoot/mosquitto/
log_dest file $confLogDir/mosquitto.log
log_type error
log_type warning
log_type notice

# --- Loopback listener: the LocalDroid server connects here ---
listener $mqttPort 127.0.0.1
allow_anonymous true

# --- Public listener: devices authenticate with per-device credentials ---
# The server rewrites passwd/acl from Postgres on every enrollment; the
# "$ReloadTaskName" task restarts the broker so it re-reads them.
$deviceListener
$mqttTlsBlock
allow_anonymous false
password_file $confAuthDir/passwd
acl_file $confAuthDir/acl
max_connections 1024
"@

    New-Item -ItemType Directory -Path (Join-Path $DataRoot "mosquitto") -Force | Out-Null
    if (Test-Path $MosquittoConf) {
        Copy-Item $MosquittoConf "$MosquittoConf.localdroid-backup" -Force -ErrorAction SilentlyContinue
    }
    $mosquittoConfBody | Out-File -FilePath $MosquittoConf -Encoding ASCII

    # Mosquitto's installer registers the service but leaves it manual-start.
    $mqSvc = Get-Service -Name "mosquitto" -ErrorAction SilentlyContinue
    if ($mqSvc) {
        Set-Service -Name "mosquitto" -StartupType Automatic
        try {
            Restart-Service -Name "mosquitto" -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            $mqSvc = Get-Service -Name "mosquitto"
            if ($mqSvc.Status -eq "Running") {
                Write-Success "Mosquitto running: 127.0.0.1:$mqttPort (server) + per-device auth on $mqttDeviceListen"
                Set-StepComplete "mosquitto"
            } else {
                Write-Err "Mosquitto did not start. Check $LogDir\mosquitto.log"
            }
        } catch {
            Write-Err "Mosquitto failed to start: $($_.Exception.Message)"
            Write-Host "  Check the config: `"$MosquittoDir\mosquitto.exe`" -c `"$MosquittoConf`" -v" -ForegroundColor Yellow
        }
    } else {
        Write-Warn "Mosquitto service not registered. Registering it now..."
        Start-Process -FilePath (Join-Path $MosquittoDir "mosquitto.exe") -ArgumentList "install" -Wait -ErrorAction SilentlyContinue
        Set-Service -Name "mosquitto" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "mosquitto" -ErrorAction SilentlyContinue
        Set-StepComplete "mosquitto"
    }

    # -- Auth reload watcher ------------------------------------------------
    # Linux SIGHUPs mosquitto when the auth files change. Windows mosquitto has
    # no reload signal, so the equivalent is a service restart. This watcher
    # debounces so a batch of enrollments causes one restart, not twenty.
    $reloadScript = Join-Path $DataRoot "mqtt-auth-reload.ps1"
    $reloadBody = @'
# LocalDroid MQTT auth reload watcher - generated by install-windows-cloud.ps1
# The LocalDroid server rewrites passwd/acl whenever a device enrolls or is
# removed. Mosquitto on Windows has no SIGHUP, so we restart the service.
# Debounced: a burst of enrollments produces a single restart.
$authDir = "__AUTH_DIR__"
$logFile = "__LOG_DIR__\mqtt-reload.log"
$debounceSeconds = 5

function Write-Log($m) {
    "$(Get-Date -Format 'u')  $m" | Out-File $logFile -Append -Encoding UTF8
    # Keep the log from growing forever on a busy fleet.
    if ((Get-Item $logFile -ErrorAction SilentlyContinue).Length -gt 2MB) {
        Get-Content $logFile -Tail 500 | Set-Content $logFile -Encoding UTF8
    }
}

function Get-AuthStamp {
    $parts = @()
    foreach ($f in @("passwd", "acl")) {
        $p = Join-Path $authDir $f
        if (Test-Path $p) {
            $i = Get-Item $p
            $parts += "$($i.Length):$($i.LastWriteTimeUtc.Ticks)"
        } else {
            $parts += "missing"
        }
    }
    return ($parts -join "|")
}

Write-Log "Watcher started on $authDir"
$last = Get-AuthStamp

while ($true) {
    Start-Sleep -Seconds 3
    $current = Get-AuthStamp
    if ($current -eq $last) { continue }

    # Wait for quiet before restarting so bulk enrollments coalesce.
    do {
        $settling = $current
        Start-Sleep -Seconds $debounceSeconds
        $current = Get-AuthStamp
    } while ($current -ne $settling)

    try {
        Restart-Service -Name "mosquitto" -Force -ErrorAction Stop
        Write-Log "MQTT auth files changed - Mosquitto restarted"
    } catch {
        Write-Log "ERROR restarting Mosquitto: $($_.Exception.Message)"
    }
    $last = $current
}
'@
    $reloadBody = $reloadBody.Replace("__AUTH_DIR__", $MqttAuthDir).Replace("__LOG_DIR__", $LogDir)
    $reloadBody | Out-File -FilePath $reloadScript -Encoding UTF8

    try {
        Unregister-ScheduledTask -TaskName $ReloadTaskName -Confirm:$false -ErrorAction SilentlyContinue
        $act = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$reloadScript`""
        $trg = New-ScheduledTaskTrigger -AtStartup
        $prn = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $ReloadTaskName -Action $act -Trigger $trg `
            -Principal $prn -Settings $set -Description "Restart Mosquitto when LocalDroid rewrites MQTT auth files" | Out-Null
        Start-ScheduledTask -TaskName $ReloadTaskName -ErrorAction SilentlyContinue
        Write-Success "MQTT auth reload watcher registered and started"
    } catch {
        Write-Warn "Could not register the MQTT reload watcher: $($_.Exception.Message)"
        Write-Host "  Without it, restart Mosquitto manually after each enrollment:" -ForegroundColor Yellow
        Write-Host "    Restart-Service mosquitto" -ForegroundColor Gray
    }
}

# ============================================================================
# STEP 10: Firewall
# ============================================================================
Write-Step "Step 10: Firewall"

if (Test-StepDone "firewall") {
    Write-Success "Firewall already configured, skipping"
} else {
    $fwRules = @(
        @{ Name = "LocalDroid HTTPS $serverPort/tcp";   Port = $serverPort;        Proto = "TCP" },
        @{ Name = "LocalDroid ACME 80/tcp";             Port = "80";               Proto = "TCP" },
        @{ Name = "LocalDroid MQTT $mqttDeviceListen/tcp"; Port = $mqttDeviceListen; Proto = "TCP" },
        @{ Name = "LocalDroid TURN 3478/tcp";           Port = "3478";             Proto = "TCP" },
        @{ Name = "LocalDroid TURN 3478/udp";           Port = "3478";             Proto = "UDP" },
        @{ Name = "LocalDroid TURN media 49152-49200/udp"; Port = "49152-49200";   Proto = "UDP" }
    )
    foreach ($r in $fwRules) {
        try {
            if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
                    -Protocol $r.Proto -LocalPort $r.Port -ErrorAction Stop | Out-Null
            }
            Write-Success "Firewall: allowed $($r.Proto) $($r.Port)"
        } catch {
            Write-Warn "Could not add firewall rule '$($r.Name)': $($_.Exception.Message)"
        }
    }

    Write-Host ""
    Write-Host "  These rules only cover the Windows firewall on this host." -ForegroundColor Yellow
    Write-Host "  Open the same ports on your router / cloud security group:" -ForegroundColor Yellow
    Write-Host "    $serverPort/tcp  - web console + device API (HTTPS)" -ForegroundColor Gray
    Write-Host "    80/tcp   - certificate issuance and renewal only" -ForegroundColor Gray
    Write-Host "    $mqttDeviceListen/tcp - MQTT device channel" -ForegroundColor Gray
    Write-Host ""
    Set-StepComplete "firewall"
}

# ============================================================================
# STEP 11: Run the server as a background service
# ============================================================================
# An internet-facing MDM has to survive reboots and crashes without anyone
# logged in, so the cloud installer registers a SYSTEM scheduled task rather
# than leaving a .bat you have to keep a console open for. start-server.bat is
# still written for foreground troubleshooting.
Write-Step "Step 11: Background Service"

$serverExe = Join-Path $serverDir "localdroid-server.exe"

if (Test-StepDone "service") {
    Write-Success "Service already registered, skipping"
} else {
    try {
        Unregister-ScheduledTask -TaskName $ServerTaskName -Confirm:$false -ErrorAction SilentlyContinue
        $act = New-ScheduledTaskAction -Execute $serverExe -WorkingDirectory $serverDir
        $trg = New-ScheduledTaskTrigger -AtStartup
        $prn = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $ServerTaskName -Action $act -Trigger $trg `
            -Principal $prn -Settings $set -Description "LocalDroid MDM server (cloud mode)" | Out-Null
        Write-Success "Registered '$ServerTaskName' (starts at boot, restarts on failure)"
    } catch {
        Write-Warn "Could not register the server task: $($_.Exception.Message)"
        Write-Host "  Start the server manually with start-server.bat instead." -ForegroundColor Yellow
    }

    @"
@echo off
REM LocalDroid MDM - foreground start (troubleshooting).
REM Normal operation uses the scheduled task "$ServerTaskName".
echo Stopping the background service so ports are free...
schtasks /End /TN "$ServerTaskName" >nul 2>&1
cd /d "%~dp0server"
echo.
echo LocalDroid MDM - $externalUrl
echo Press Ctrl+C to stop.
echo.
localdroid-server.exe
pause
"@ | Out-File -FilePath (Join-Path $ScriptDir "start-server.bat") -Encoding ASCII
    Write-Success "Created: start-server.bat (foreground troubleshooting)"

    Set-StepComplete "service"
}

# Start (or restart) the server now so the verification below is meaningful.
Write-Host "  Starting the LocalDroid server..."
Stop-ScheduledTask -TaskName $ServerTaskName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $ServerTaskName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 6

$serverProc = Get-Process -Name "localdroid-server" -ErrorAction SilentlyContinue
if ($serverProc) {
    Write-Success "LocalDroid server is running (PID $($serverProc.Id))"
} else {
    Write-Warn "The server process is not running."
    Write-Host "  Run start-server.bat to see why it exited." -ForegroundColor Yellow
}

# ============================================================================
# STEP 12: Verify HTTPS end to end
# ============================================================================
# Zero-Touch enrollment silently fails if TLS is not working end to end, so
# catch it here rather than letting the operator discover it in the field.
Write-Step "Step 12: Verifying HTTPS Reachability"

$healthUrl = "$externalUrl/api/health"
$httpCode = 0
try {
    $resp = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
    $httpCode = [int]$resp.StatusCode
} catch {
    if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
}

if ($httpCode -ge 200 -and $httpCode -lt 500) {
    Write-Success "HTTPS reachable at $externalUrl (HTTP $httpCode) - Zero-Touch enrollment ready"
} else {
    Write-Warn "Could not reach $healthUrl"
    Write-Host "  TLS/HTTPS is not confirmed working. Devices cannot enroll until it is." -ForegroundColor Yellow
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    - server not running       : run start-server.bat to see the error" -ForegroundColor Yellow
    Write-Host "    - certificate missing      : .\install-windows-cloud.ps1 -ResetStep tls" -ForegroundColor Yellow
    Write-Host "    - $serverPort blocked upstream    : check the router / cloud security group" -ForegroundColor Yellow
    Write-Host "    - DNS not propagated       : Resolve-DnsName $apiDomain -Server 1.1.1.1" -ForegroundColor Yellow
    if ($tlsMode -eq "proxy") {
        Write-Host "    - reverse proxy not yet pointed at http://<this host>:$serverPort" -ForegroundColor Yellow
    }
}

# ============================================================================
# COMPLETE
# ============================================================================
$env:PGPASSWORD = ""

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  LocalDroid MDM - Cloud Installation Complete" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Web console  : $externalUrl" -ForegroundColor Cyan
Write-Host "Sign in as   : $adminEmail" -ForegroundColor Cyan
Write-Host "Password     : <the password you entered above>" -ForegroundColor Cyan
Write-Host ""
Write-Host "Device enrollment settings:" -ForegroundColor Yellow
Write-Host "  Server URL : $externalUrl"
Write-Host "  MQTT host  : $mqttExternalHost"
Write-Host "  MQTT port  : $mqttExternalPort  (TLS: $mqttExternalUseTls)"
Write-Host ""
Write-Host "Services:" -ForegroundColor Yellow
Write-Host "  Server     : scheduled task '$ServerTaskName' (SYSTEM, starts at boot)"
Write-Host "  MQTT       : Windows service 'mosquitto' (automatic start)"
Write-Host "  MQTT auth  : scheduled task '$ReloadTaskName'"
if ($tlsMode -eq "acme") {
    Write-Host "  Cert renew : scheduled task '$RenewTaskName' (daily 03:17)"
}
Write-Host ""
Write-Host "Remote control:" -ForegroundColor Yellow
Write-Host "  Windows VNC : relayed over HTTPS - no extra ports needed" -ForegroundColor Green
Write-Host "  Android     : needs a TURN relay (coturn) for internet sessions." -ForegroundColor Yellow
Write-Host "                coturn has no native Windows build - run it on a small" -ForegroundColor Gray
Write-Host "                Linux VPS (apt install coturn):" -ForegroundColor Gray
Write-Host '                  turnserver -n --use-auth-secret \' -ForegroundColor Gray
Write-Host '                    --static-auth-secret=localdroid_turn_secret_2024 \' -ForegroundColor Gray
Write-Host "                    --realm=$apiDomain --min-port=49152 --max-port=49200 \" -ForegroundColor Gray
Write-Host "                    --external-ip=<PUBLIC_IP>" -ForegroundColor Gray
Write-Host "                Keep that secret as-is - it must match the clients." -ForegroundColor Gray
Write-Host ""
Write-Host "Change the admin password at first login." -ForegroundColor Yellow
Write-Host ""
Write-Host "Housekeeping: $StateFile records the answers you gave, including the" -ForegroundColor Yellow
Write-Host "PostgreSQL and admin passwords in plain text, so a re-run can resume." -ForegroundColor Yellow
Write-Host "Once you are happy with the install, delete it:" -ForegroundColor Yellow
Write-Host "  Remove-Item '$StateFile'" -ForegroundColor Gray
Write-Host "(A later re-run then simply asks the questions again.)" -ForegroundColor Gray
Write-Host ""
Write-Host "Files:" -ForegroundColor Gray
Write-Host "  Config       : $envPath" -ForegroundColor Gray
Write-Host "  Certificates : $CertDir" -ForegroundColor Gray
Write-Host "  MQTT auth    : $MqttAuthDir" -ForegroundColor Gray
Write-Host "  Logs         : $LogDir" -ForegroundColor Gray
Write-Host "  Progress     : $StateFile" -ForegroundColor Gray
Write-Host ""
Write-Host "Re-run a step : .\install-windows-cloud.ps1 -ResetStep <step_name>" -ForegroundColor Gray
Write-Host "Start fresh   : .\install-windows-cloud.ps1 -Fresh" -ForegroundColor Gray
Write-Host ""
