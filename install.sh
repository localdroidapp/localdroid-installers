#!/bin/bash

# LocalDroid MDM Installation Script
# Supports resuming from a failed or cancelled run.
# Re-run the script at any time to pick up where you left off.
# To start over: rm -f .install-state && run again

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.install-state"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# State helpers
step_done()  { [ -f "$STATE_FILE" ] && grep -q "^step_$1=done$" "$STATE_FILE" 2>/dev/null; }
mark_done()  { echo "step_$1=done" >> "$STATE_FILE"; }

save_val() {
    local tmp
    tmp=$(mktemp)
    [ -f "$STATE_FILE" ] && grep -v "^val_$1=" "$STATE_FILE" > "$tmp" || true
    echo "val_$1=$2" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

get_val() {
    [ -f "$STATE_FILE" ] && grep "^val_$1=" "$STATE_FILE" | cut -d= -f2- || echo ""
}

# Prompt helper
prompt_with_default() {
    local result
    read -rp "$1 [$2]: " result
    echo "${result:-$2}"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  LocalDroid MDM Installation Script"
echo "=========================================="

if [ -f "$STATE_FILE" ]; then
    DONE_COUNT=$(grep -c "^step_.*=done$" "$STATE_FILE" 2>/dev/null || echo 0)
    echo -e "${CYAN}Resuming installation ($DONE_COUNT step(s) already completed).${NC}"
    echo -e "${CYAN}Completed steps will be skipped. To start fresh: rm $STATE_FILE${NC}"
fi
echo ""

# ---------------------------------------------------------------------------
# Offline / air-gapped bundle support
# ---------------------------------------------------------------------------
# The "offline" install bundle ships a debs/ folder next to this script holding
# postgresql, mosquitto, adb and all their dependencies as .deb files. When we
# see it (or OFFLINE=1), install everything from there with dpkg — no internet,
# no apt, no SSL. This forces air-gapped mode (plain HTTP + MQTT 1883). Zero-Touch
# enrollment is not available in this mode (no public TLS); use in-app QR enroll.
OFFLINE_MODE=false
if [ "${OFFLINE:-0}" = "1" ] || ls "$SCRIPT_DIR"/debs/*.deb >/dev/null 2>&1; then
    OFFLINE_MODE=true
    # Use the bundled agent binaries (no download) and skip the license-authority
    # fetch — both default to localdroid.app, which is unreachable when air-gapped.
    export AGENT_DOWNLOAD_BASE=""
    export AGENT_RELEASE_BASE=""
    export LICENSE_SERVER_URL=""
    echo -e "${CYAN}Offline bundle detected — air-gapped install, no internet required.${NC}"
    if step_done "offline_deps"; then
        echo -e "${GREEN}[SKIP] Bundled OS packages already installed${NC}"
    elif ls "$SCRIPT_DIR"/debs/*.deb >/dev/null 2>&1; then
        echo ""
        echo "=== Installing bundled OS packages (postgresql, mosquitto, adb + deps) ==="
        # Two passes so dpkg resolves inter-package dependencies regardless of the
        # order the files are listed in (the bundle carries the full closure).
        sudo dpkg -i "$SCRIPT_DIR"/debs/*.deb 2>&1 | tail -3 || true
        sudo dpkg -i "$SCRIPT_DIR"/debs/*.deb 2>&1 | tail -3 || true
        missing=""
        for c in psql mosquitto; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
        if [ -n "$missing" ]; then
            echo -e "${YELLOW}Warning: still missing:$missing — the bundled .deb set may not match this OS release/arch.${NC}"
        else
            echo -e "${GREEN}Bundled packages installed.${NC}"
            mark_done "offline_deps"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# STEP 1: Server Configuration
# ---------------------------------------------------------------------------
if step_done "config"; then
    echo -e "${GREEN}[SKIP] Server configuration already saved${NC}"
    SERVER_HOST=$(get_val SERVER_HOST)
    SERVER_PORT=$(get_val SERVER_PORT)
    SERVER_PUBLIC_IP=$(get_val SERVER_PUBLIC_IP)
    DB_HOST=$(get_val DB_HOST)
    DB_PORT=$(get_val DB_PORT)
    DB_USER=$(get_val DB_USER)
    DB_PASSWORD=$(get_val DB_PASSWORD)
    DB_NAME=$(get_val DB_NAME)
    MQTT_HOST=$(get_val MQTT_HOST)
    MQTT_PORT=$(get_val MQTT_PORT)
    MQTT_EXTERNAL_HOST=$(get_val MQTT_EXTERNAL_HOST)
    MQTT_EXTERNAL_PORT=$(get_val MQTT_EXTERNAL_PORT)
    MQTT_USERNAME=$(get_val MQTT_USERNAME)
    MQTT_PASSWORD=$(get_val MQTT_PASSWORD)
    MQTT_EXTERNAL_USE_TLS=$(get_val MQTT_EXTERNAL_USE_TLS)
    DEPLOYMENT_MODE=$(get_val DEPLOYMENT_MODE)
    EXTERNAL_URL=$(get_val EXTERNAL_URL)
    ENABLE_TLS=$(get_val ENABLE_TLS)
    TLS_CERT=$(get_val TLS_CERT)
    TLS_KEY=$(get_val TLS_KEY)
    LICENSE_SERVER_URL=$(get_val LICENSE_SERVER_URL)
    LOCALDROID_ADMIN_EMAIL=$(get_val LOCALDROID_ADMIN_EMAIL)
    LOCALDROID_ADMIN_PASSWORD=$(get_val LOCALDROID_ADMIN_PASSWORD)
    # New in this revision — default to "true" so resuming an older install
    # (which didn't track this) preserves the previous behavior.
    INSTALL_LOCAL_NGINX=$(get_val INSTALL_LOCAL_NGINX)
    [ -z "$INSTALL_LOCAL_NGINX" ] && INSTALL_LOCAL_NGINX="true"
else
    echo "This script will configure LocalDroid MDM for your environment."
    echo ""

    DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || hostname)
    echo -e "${GREEN}Detected server IP: $DETECTED_IP${NC}"
    echo ""

    # --- Deployment mode first so subsequent prompts can be context-aware ---
    echo "=== Deployment Mode ==="
    echo "  1. Air-Gapped / Local Network"
    echo "     Devices are on the same local network as this server."
    echo "     Typically used for schools, warehouses, and internal fleets."
    echo ""
    echo "  2. Internet Connected (Cloud)"
    echo "     Devices connect over the internet. Requires a public IP address"
    echo "     or a domain name pointing to this server."
    echo ""
    if $OFFLINE_MODE; then
        DEPLOY_MODE=1
        echo -e "${CYAN}Offline bundle — using Air-Gapped / Local Network mode (plain HTTP, no SSL).${NC}"
    else
        read -rp "Select deployment mode (1 or 2) [1]: " DEPLOY_MODE
        DEPLOY_MODE=${DEPLOY_MODE:-1}
    fi

    if [ "$DEPLOY_MODE" = "1" ]; then
        echo -e "${CYAN}Air-Gapped / Local Network mode selected.${NC}"
        DEPLOYMENT_MODE="airgapped"
    else
        echo -e "${CYAN}Internet Connected (Cloud) mode selected.${NC}"
        DEPLOYMENT_MODE="cloud"
        echo ""
        echo -e "${YELLOW}=== Cloud mode prerequisites (read before continuing) ===${NC}"
        echo "This mode obtains real Let's Encrypt certificates for HTTPS and MQTT TLS."
        echo "For that to succeed, BEFORE you continue you must have:"
        echo ""
        echo -e "  1. A ${CYAN}public domain name${NC} for this server (used for both the web/API"
        echo "     and MQTT, or a separate hostname for each)."
        echo -e "  2. A ${CYAN}public DNS A-record${NC} for that domain pointing at THIS server's"
        echo "     PUBLIC IP. It must resolve publicly — a LAN-only / split-horizon"
        echo "     record is not enough; Let's Encrypt validates from the internet."
        echo -e "  3. ${CYAN}Port 80/tcp reachable from the internet${NC} during install — the"
        echo "     certificate challenge runs an HTTP check on port 80 (the installer"
        echo "     frees it temporarily). Open it on the host AND any router/cloud firewall."
        echo -e "  4. ${CYAN}Ports 443/tcp${NC} (HTTPS) and ${CYAN}8883/tcp${NC} (MQTT over TLS) open for"
        echo "     day-to-day device connections."
        echo ""
        echo "If any of these aren't ready, press Ctrl+C, fix them, and re-run — the"
        echo "installer resumes where it left off. (Certificates that can't be issued"
        echo "will cause MQTT/HTTPS TLS steps to be skipped.)"
        echo ""
        read -rp "Press Enter to confirm these are in place and continue... " _
    fi

    # --- Server address with mode-specific guidance ---
    echo ""
    echo "=== Server Address ==="
    if [ "$DEPLOYMENT_MODE" = "airgapped" ]; then
        echo "Enter the IP address or hostname that Android devices will use to reach"
        echo "this server. Since devices are on your local network, this is typically"
        echo "the local IP address of this machine."
        echo ""
        echo -e "  Examples: ${CYAN}192.168.1.100${NC}  |  ${CYAN}10.0.0.5${NC}  |  ${CYAN}mdm.local${NC}"
        echo ""
        SERVER_PUBLIC_IP=$(prompt_with_default "Local IP address or hostname for devices" "$DETECTED_IP")
    else
        echo "Enter the domain name or public IP address that Android devices will use"
        echo "to reach this server over the internet. Both are supported:"
        echo ""
        echo -e "  Domain name : ${CYAN}cloud.localdroid.app${NC}  or  ${CYAN}mdm.yourcompany.com${NC}"
        echo -e "  Public IP   : ${CYAN}203.0.113.10${NC}"
        echo ""
        echo "If you have a domain name, use it — it is required for HTTPS/TLS and"
        echo "makes it easier to swap servers without reconfiguring devices."
        echo ""
        SERVER_PUBLIC_IP=$(prompt_with_default "Domain name or public IP for devices" "$DETECTED_IP")
    fi

    # --- Server bind / port ---
    echo ""
    echo "=== Server Listen Configuration ==="
    echo "The bind address controls which network interface the server listens on."
    echo "Use 0.0.0.0 to accept connections on all interfaces (recommended)."
    SERVER_HOST=$(prompt_with_default "Server bind address" "0.0.0.0")

    if [ "$DEPLOYMENT_MODE" = "cloud" ]; then
        echo ""
        echo "=== Reverse Proxy / TLS ==="
        echo "How is TLS/HTTPS handled for this server?"
        echo ""
        echo "  1. Reverse proxy (nginx, Apache, Caddy) — TLS is terminated at the proxy."
        echo "     The Go server listens on a plain HTTP port (e.g. 8080) behind it."
        echo "     This is the most common cloud setup."
        echo ""
        echo "  2. Direct TLS — the Go server handles TLS itself using a certificate."
        echo "     The Go server listens on 443 directly (no proxy in front)."
        echo ""
        read -rp "Select option (1 or 2) [1]: " TLS_MODE
        TLS_MODE=${TLS_MODE:-1}

        if [ "$TLS_MODE" = "1" ]; then
            # Reverse proxy — Go server runs on plain HTTP backend port
            SERVER_PORT=$(prompt_with_default "Backend port Go server listens on" "8080")
            ENABLE_TLS="false"
            TLS_CERT=""
            TLS_KEY=""

            echo ""
            echo "Where does the reverse proxy run?"
            echo ""
            echo "  1. On THIS machine — install.sh will install nginx and request"
            echo "     Let's Encrypt certs here. Common single-box cloud setup."
            echo ""
            echo "  2. On a SEPARATE machine — you already have nginx (or Caddy,"
            echo "     HAProxy, etc.) running elsewhere on your network or in front"
            echo "     of it. install.sh will NOT touch nginx or certs here; the"
            echo "     Go server just listens on the backend port and your"
            echo "     external proxy handles TLS + the public hostname."
            echo ""
            read -rp "Select option (1 or 2) [1]: " PROXY_LOCATION
            PROXY_LOCATION=${PROXY_LOCATION:-1}
            if [ "$PROXY_LOCATION" = "2" ]; then
                INSTALL_LOCAL_NGINX="false"
                echo -e "${CYAN}External reverse proxy: nginx + Let's Encrypt steps will be skipped on this box.${NC}"
                echo -e "${CYAN}  Point your external proxy at http://$(hostname -I 2>/dev/null | awk '{print $1}'):$SERVER_PORT${NC}"
            else
                INSTALL_LOCAL_NGINX="true"
                echo -e "${CYAN}Reverse proxy mode: Go server on port $SERVER_PORT, local nginx will terminate TLS.${NC}"
            fi
        else
            # Direct TLS — no nginx, certs go to the Go server directly
            SERVER_PORT=$(prompt_with_default "Server port" "443")
            ENABLE_TLS="true"
            TLS_CERT=$(prompt_with_default "Path to TLS certificate (fullchain.pem)" "/etc/letsencrypt/live/$SERVER_PUBLIC_IP/fullchain.pem")
            TLS_KEY=$(prompt_with_default "Path to TLS private key (privkey.pem)" "/etc/letsencrypt/live/$SERVER_PUBLIC_IP/privkey.pem")
            INSTALL_LOCAL_NGINX="false"
            echo -e "${CYAN}Direct TLS mode: Go server on port $SERVER_PORT with certificate, no nginx.${NC}"
        fi
    else
        SERVER_PORT=$(prompt_with_default "Server port" "80")
        ENABLE_TLS="false"
        TLS_CERT=""
        TLS_KEY=""
    fi

    if [ "$SERVER_PORT" -lt 1024 ] 2>/dev/null && [ "$EUID" -ne 0 ] && [ "$ENABLE_TLS" = "true" ]; then
        echo -e "${YELLOW}Warning: Port $SERVER_PORT requires root or a systemd capability setting.${NC}"
    fi

    # --- External URL (cloud only) ---
    if [ "$DEPLOYMENT_MODE" = "cloud" ]; then
        echo ""
        echo "=== External URL ==="
        echo "This is the public URL that Android devices use to reach the API."
        echo "It should be the domain your reverse proxy (or this server) is serving."
        echo "Always use the public domain, not the backend port."
        echo ""
        echo -e "  Examples: ${CYAN}https://api.localdroid.app${NC}  |  ${CYAN}https://mdm.yourcompany.com${NC}"
        echo ""
        EXTERNAL_URL=$(prompt_with_default "External API URL" "https://$SERVER_PUBLIC_IP")
        # Auto-prefix scheme if user entered a bare domain (e.g., api.example.com).
        # Without a scheme, the server defaults to http:// in QR codes, and nginx
        # then 301-redirects devices to https:// — which Android's HttpURLConnection
        # refuses to follow, silently breaking enrollment.
        if [[ "$EXTERNAL_URL" != http://* && "$EXTERNAL_URL" != https://* ]]; then
            EXTERNAL_URL="https://$EXTERNAL_URL"
            echo -e "  ${YELLOW}No scheme provided \u2014 assuming HTTPS: $EXTERNAL_URL${NC}"
        fi
    else
        EXTERNAL_URL="http://$SERVER_PUBLIC_IP:$SERVER_PORT"
    fi

    # --- Database ---
    echo ""
    echo "=== Database Configuration ==="
    echo "LocalDroid requires a PostgreSQL database. The installer will attempt to"
    echo "create the database and user automatically in a later step."
    DB_HOST=$(prompt_with_default "PostgreSQL host" "localhost")
    DB_PORT=$(prompt_with_default "PostgreSQL port" "5432")
    DB_USER=$(prompt_with_default "PostgreSQL user" "localdroid")
    DB_PASSWORD=$(prompt_with_default "PostgreSQL password" "localdroid")
    DB_NAME=$(prompt_with_default "PostgreSQL database name" "localdroid")

    # --- MQTT ---
    echo ""
    echo "=== MQTT Configuration ==="
    echo "MQTT is used for real-time communication with Android devices."
    MQTT_HOST=$(prompt_with_default "MQTT broker host (local address this server connects to)" "localhost")
    MQTT_PORT=$(prompt_with_default "MQTT broker port (local)" "1883")

    if [ "$DEPLOYMENT_MODE" = "cloud" ]; then
        echo ""
        echo "Cloud MQTT settings — what Android devices use to connect:"
        echo "  The hostname is typically your MQTT broker's public domain."
        echo "  Port 8883 = TLS/encrypted (recommended for internet).  Port 1883 = unencrypted."
        echo ""
        MQTT_EXTERNAL_HOST=$(prompt_with_default "MQTT hostname for devices (public)" "$SERVER_PUBLIC_IP")
        MQTT_EXTERNAL_PORT=$(prompt_with_default "MQTT port for devices" "8883")

        # Auto-detect TLS from port (this controls what *devices* use, not the server's
        # loopback connection to the local broker — that is always plain text).
        if [ "$MQTT_EXTERNAL_PORT" = "8883" ]; then
            MQTT_EXTERNAL_USE_TLS="true"
        else
            MQTT_EXTERNAL_USE_TLS="false"
        fi

        echo ""
        echo "=== MQTT Authentication ==="
        echo "Cloud MQTT brokers should require a username and password."
        echo "Leave blank if your broker allows anonymous connections."
        MQTT_USERNAME=$(prompt_with_default "MQTT username" "")
        MQTT_PASSWORD=$(prompt_with_default "MQTT password" "")
    else
        MQTT_EXTERNAL_HOST="$SERVER_PUBLIC_IP"
        MQTT_EXTERNAL_PORT=$(prompt_with_default "MQTT port for devices (external)" "1883")
        MQTT_EXTERNAL_USE_TLS="false"
        MQTT_USERNAME=""
        MQTT_PASSWORD=""
    fi

    echo ""
    echo "=== Licensing ==="
    # Portal at localdroid.app is the canonical license authority. Signed
    # license files always verify offline against the baked-in public key;
    # this URL is only used during online activation of a raw license key.
    # Override by exporting LICENSE_SERVER_URL=... before running (set to
    # empty string for fully air-gapped operation).
    LICENSE_SERVER_URL="${LICENSE_SERVER_URL-https://localdroid.app}"
    if [ -n "$LICENSE_SERVER_URL" ]; then
        echo -e "${GREEN}License authority: $LICENSE_SERVER_URL${NC}"
    else
        echo -e "${YELLOW}License authority: <none> — air-gapped mode${NC}"
    fi

    echo ""
    echo "=== Administrator Login ==="
    echo "Initial admin user for the MDM web UI. The server seeds this on"
    echo "first boot via LOCALDROID_ADMIN_* env vars in .env, then bcrypt-"
    echo "hashes the password. Re-running with the same values is idempotent;"
    echo "changing them resets the admin on next restart."
    LOCALDROID_ADMIN_EMAIL=$(prompt_with_default "Admin email" "admin@localdroid.app")
    while :; do
        read -rsp "Admin password (min 8 chars, will not echo): " LOCALDROID_ADMIN_PASSWORD
        echo ""
        if [ ${#LOCALDROID_ADMIN_PASSWORD} -lt 8 ]; then
            echo -e "${YELLOW}Password must be at least 8 characters. Try again.${NC}"
            continue
        fi
        read -rsp "Confirm admin password: " ADMIN_PASSWORD_CONFIRM
        echo ""
        if [ "$LOCALDROID_ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
            echo -e "${YELLOW}Passwords don't match. Try again.${NC}"
            continue
        fi
        unset ADMIN_PASSWORD_CONFIRM
        break
    done
    echo -e "${GREEN}Admin login configured: $LOCALDROID_ADMIN_EMAIL${NC}"

    # Save all config values
    save_val SERVER_HOST        "$SERVER_HOST"
    save_val SERVER_PORT        "$SERVER_PORT"
    save_val SERVER_PUBLIC_IP   "$SERVER_PUBLIC_IP"
    save_val DB_HOST            "$DB_HOST"
    save_val DB_PORT            "$DB_PORT"
    save_val DB_USER            "$DB_USER"
    save_val DB_PASSWORD        "$DB_PASSWORD"
    save_val DB_NAME            "$DB_NAME"
    save_val MQTT_HOST          "$MQTT_HOST"
    save_val MQTT_PORT          "$MQTT_PORT"
    save_val MQTT_EXTERNAL_HOST "$MQTT_EXTERNAL_HOST"
    save_val MQTT_EXTERNAL_PORT "$MQTT_EXTERNAL_PORT"
    save_val MQTT_USERNAME      "$MQTT_USERNAME"
    save_val MQTT_PASSWORD      "$MQTT_PASSWORD"
    save_val MQTT_EXTERNAL_USE_TLS "$MQTT_EXTERNAL_USE_TLS"
    save_val DEPLOYMENT_MODE    "$DEPLOYMENT_MODE"
    save_val EXTERNAL_URL       "$EXTERNAL_URL"
    save_val ENABLE_TLS         "$ENABLE_TLS"
    save_val TLS_CERT           "$TLS_CERT"
    save_val TLS_KEY            "$TLS_KEY"
    save_val LICENSE_SERVER_URL "$LICENSE_SERVER_URL"
    save_val LOCALDROID_ADMIN_EMAIL    "$LOCALDROID_ADMIN_EMAIL"
    save_val LOCALDROID_ADMIN_PASSWORD "$LOCALDROID_ADMIN_PASSWORD"
    save_val INSTALL_LOCAL_NGINX       "${INSTALL_LOCAL_NGINX:-true}"
    mark_done "config"
fi

# ---------------------------------------------------------------------------
# STEP 2: Create .env file
# ---------------------------------------------------------------------------
ENV_FILE="$SCRIPT_DIR/server/.env"

if step_done "env"; then
    echo -e "${GREEN}[SKIP] Configuration file already created${NC}"
else
    echo ""
    echo "=== Security Configuration ==="
    JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || \
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)
    echo -e "${GREEN}Generated JWT secret${NC}"

    echo ""
    echo "Creating configuration: $ENV_FILE"
    mkdir -p "$(dirname "$ENV_FILE")"

    if [ "$DEPLOYMENT_MODE" = "cloud" ]; then
        cat > "$ENV_FILE" << EOF
# LocalDroid MDM Server Configuration - CLOUD MODE
# Generated by install.sh on $(date)

# Server
SERVER_HOST=$SERVER_HOST
SERVER_PORT=$SERVER_PORT
PUBLIC_URL=$EXTERNAL_URL
EXTERNAL_URL=$EXTERNAL_URL
# CORS allowlist — needs to include EXTERNAL_URL so browsers on that origin
# can call /api/*. Empty → preflights fail (System Health flags this).
ALLOWED_ORIGINS=$EXTERNAL_URL

# TLS/SSL (required for Zero-Touch enrollment over internet)
ENABLE_TLS=$ENABLE_TLS
TLS_CERT=$TLS_CERT
TLS_KEY=$TLS_KEY

# Database
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
DB_SSLMODE=disable
DB_MAX_CONNS=50

# MQTT — local connection (server to broker)
MQTT_HOST=$MQTT_HOST
MQTT_PORT=$MQTT_PORT

# MQTT — server-to-broker (loopback) is always plain text on this host.
# Do NOT set MQTT_USE_TLS=true here even if devices use TLS externally —
# the Go server uses MQTT_USE_TLS for its own connection to MQTT_HOST:MQTT_PORT,
# and Mosquitto's loopback listener (127.0.0.1:1883) is plain text.
MQTT_USE_TLS=false

# MQTT — what devices connect to (public hostname/port)
MQTT_EXTERNAL_HOST=$MQTT_EXTERNAL_HOST
MQTT_EXTERNAL_PORT=$MQTT_EXTERNAL_PORT
MQTT_EXTERNAL_USE_TLS=$MQTT_EXTERNAL_USE_TLS
MQTT_USERNAME=$MQTT_USERNAME
MQTT_PASSWORD=$MQTT_PASSWORD

# JWT
JWT_SECRET=$JWT_SECRET
JWT_ACCESS_EXPIRY=60
JWT_REFRESH_EXPIRY=168
JWT_ISSUER=localdroid-cloud

# Cloud mode flags
DEPLOYMENT_MODE=cloud
CLOUD_MODE=true
ALLOW_REMOTE_ENROLLMENT=true

# Trust X-Forwarded-For from the reverse proxy (nginx). Required so the
# login brute-force limiter sees real client IPs instead of 127.0.0.1.
# Only enable when the server is actually behind a single trusted proxy.
TRUST_PROXY=true

# Storage
STORAGE_PATH=./storage
MAX_FILE_SIZE=500

# APK for Zero-Touch enrollment
APK_SIGNATURE_CHECKSUM=

# Licensing — LICENSE_PUBLIC_KEY is populated by the license_bootstrap step.
# With no public key, the MDM runs in unlimited free mode. Once a key is set,
# paste a signed license file at /license to upgrade to a paid tier.
LICENSE_SERVER_URL=$LICENSE_SERVER_URL
LICENSE_PUBLIC_KEY=
EOF
    else
        cat > "$ENV_FILE" << EOF
# LocalDroid MDM Server Configuration - AIR-GAPPED MODE
# Generated by install.sh on $(date)

# Server
SERVER_HOST=$SERVER_HOST
SERVER_PORT=$SERVER_PORT
EXTERNAL_URL=$EXTERNAL_URL
# CORS allowlist — needs to include EXTERNAL_URL so browsers on that origin
# can call /api/*. Empty → preflights fail (System Health flags this).
ALLOWED_ORIGINS=$EXTERNAL_URL

# Database
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
DB_SSLMODE=disable

# MQTT
MQTT_HOST=$MQTT_HOST
MQTT_PORT=$MQTT_PORT
MQTT_EXTERNAL_HOST=$MQTT_EXTERNAL_HOST
MQTT_EXTERNAL_PORT=$MQTT_EXTERNAL_PORT

# JWT
JWT_SECRET=$JWT_SECRET
JWT_EXPIRES_HOURS=24

# Deployment
DEPLOYMENT_MODE=airgapped

# Zero-Touch enrollment requires HTTPS and a public internet connection.
# Air-gapped installs run on a local network without TLS, so it is disabled.
ALLOW_REMOTE_ENROLLMENT=false

# Storage
STORAGE_PATH=./storage

# APK for Zero-Touch enrollment
APK_SIGNATURE_CHECKSUM=

# Licensing — the LocalDroid license-authority public key ships as the
# default so signed license.lic files verify out of the box, including on
# air-gapped servers (the key is public: it can only VERIFY licenses, never
# create them). Cloud installs still refresh it from the portal below.
LICENSE_SERVER_URL=$LICENSE_SERVER_URL
LICENSE_PUBLIC_KEY=woL+6yGOhnbu9E+iALVqMzIx1Uez7Rk2kP8pEXIQDDc=
EOF
    fi

    # Append admin credentials via printf so a literal $ in the password
    # can't be re-interpreted by the shell. The server's bootstrap reads
    # these on startup, bcrypt-hashes the password, and upserts the admin
    # user row (see server/cmd/server/main.go bootstrapAdminUser).
    {
        printf '\n# Administrator credentials — seeded into the users table on first boot.\n'
        printf '# Setting LOCALDROID_ADMIN_PASSWORD here is authoritative: changing it\n'
        printf '# resets the admin password on the next restart. Comment both lines\n'
        printf '# out after first login if you prefer to manage the admin from the UI.\n'
        printf 'LOCALDROID_ADMIN_EMAIL=%s\n'    "$LOCALDROID_ADMIN_EMAIL"
        printf 'LOCALDROID_ADMIN_PASSWORD=%s\n' "$LOCALDROID_ADMIN_PASSWORD"
    } >> "$ENV_FILE"

    # Display time zone for the dashboard. Seeded into the database on first
    # boot; after that it is changed in Settings -> System and upgrades keep it.
    DETECTED_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "")
    echo ""
    echo "Time zone the dashboard shows dates in (an IANA name such as America/Chicago)."
    echo "Leave blank to show each viewer's own browser time zone."
    read -rp "Display time zone [${DETECTED_TZ:-blank}]: " LOCALDROID_TIMEZONE
    LOCALDROID_TIMEZONE=${LOCALDROID_TIMEZONE:-$DETECTED_TZ}
    if [ -n "$LOCALDROID_TIMEZONE" ] && [ ! -e "/usr/share/zoneinfo/$LOCALDROID_TIMEZONE" ]; then
        echo -e "${YELLOW}'$LOCALDROID_TIMEZONE' is not a known time zone; leaving it blank (set it later in Settings -> System).${NC}"
        LOCALDROID_TIMEZONE=""
    fi
    printf '\n# Dashboard display time zone, seeded on first boot (Settings -> System changes it).\nLOCALDROID_TIMEZONE=%s\n' "$LOCALDROID_TIMEZONE" >> "$ENV_FILE"

    echo -e "${GREEN}Configuration file created!${NC}"
    mark_done "env"
fi

# ---------------------------------------------------------------------------
# STEP 2b: License public key bootstrap
# ---------------------------------------------------------------------------
# Fetch the Ed25519 public key from the LocalDroid portal so this MDM can
# verify signed license files. Skipped if LICENSE_SERVER_URL is blank or the
# fetch fails — the MDM then stays in unlimited free mode until you paste a
# key into LICENSE_PUBLIC_KEY manually.
if step_done "license_bootstrap"; then
    echo -e "${GREEN}[SKIP] License public key already configured${NC}"
elif [ -z "$LICENSE_SERVER_URL" ]; then
    echo -e "${YELLOW}[skip] LICENSE_SERVER_URL is blank — MDM will run in unlimited free mode.${NC}"
    mark_done "license_bootstrap"
else
    echo ""
    echo "=== Fetching license public key ==="
    echo "  source: $LICENSE_SERVER_URL/api/public-key"
    PK_JSON=$(curl -fsSL --max-time 10 "$LICENSE_SERVER_URL/api/public-key" 2>/dev/null || true)
    PK_VALUE=$(echo "$PK_JSON" | grep -oE '"public_key"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"public_key"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    if [ -n "$PK_VALUE" ]; then
        # Replace LICENSE_PUBLIC_KEY=... in the .env (line is empty by default)
        if grep -q "^LICENSE_PUBLIC_KEY=" "$ENV_FILE"; then
            sed -i.bak "s|^LICENSE_PUBLIC_KEY=.*|LICENSE_PUBLIC_KEY=$PK_VALUE|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
        else
            echo "LICENSE_PUBLIC_KEY=$PK_VALUE" >> "$ENV_FILE"
        fi
        echo -e "${GREEN}  License public key written to $ENV_FILE${NC}"
        mark_done "license_bootstrap"
    else
        echo -e "${YELLOW}  Could not reach $LICENSE_SERVER_URL/api/public-key — skipping.${NC}"
        echo -e "${YELLOW}  The MDM will start in unlimited free mode. To enable license${NC}"
        echo -e "${YELLOW}  verification later, set LICENSE_PUBLIC_KEY in $ENV_FILE and${NC}"
        echo -e "${YELLOW}  run: sudo systemctl restart localdroid-backend${NC}"
        # Don't mark done — re-running the script will retry the fetch
    fi
fi

# ---------------------------------------------------------------------------
# STEP 2c: Install Android Debug Bridge (adb)
# ---------------------------------------------------------------------------
# The MDM server's /api/adb/* endpoints use the `adb` binary for network ADB
# pairing/connect and device-owner setup. Without it those endpoints fail at
# runtime. Required in BOTH cloud and air-gapped modes. We install the
# Debian/RHEL `adb` (android-tools) package for this.
if step_done "adb_install"; then
    echo -e "${GREEN}[SKIP] adb already installed${NC}"
elif command -v adb &>/dev/null; then
    echo -e "${GREEN}[SKIP] adb already on PATH ($(adb version 2>&1 | head -1))${NC}"
    mark_done "adb_install"
else
    echo ""
    echo "=== Installing Android Debug Bridge ==="
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y adb 2>&1 | grep -E "Setting up|already" || true
    elif command -v yum &>/dev/null; then
        # On RHEL/CentOS the package is android-tools
        sudo yum install -y android-tools 2>&1 | grep -E "Installing|already" || true
    elif command -v apk &>/dev/null; then
        sudo apk add --no-cache android-tools 2>&1 | tail -3
    else
        echo -e "${YELLOW}No supported package manager found. Install adb manually:${NC}"
        echo "  Ubuntu/Debian : sudo apt install adb"
        echo "  RHEL/CentOS   : sudo yum install android-tools"
        echo "  Alpine        : sudo apk add android-tools"
    fi
    if command -v adb &>/dev/null; then
        echo -e "${GREEN}adb installed: $(adb version 2>&1 | head -1)${NC}"
        mark_done "adb_install"
    else
        echo -e "${YELLOW}adb is still not on PATH. /api/adb/* endpoints will fail until you install it.${NC}"
        # Don't mark done so a re-run retries.
    fi
fi

# ---------------------------------------------------------------------------
# STEP 3: SSL Certificates  (cloud mode only)
# ---------------------------------------------------------------------------
# Skipped for air-gapped deployments. Also skipped when the reverse proxy
# lives on a SEPARATE machine (INSTALL_LOCAL_NGINX=false + ENABLE_TLS=false)
# — that external proxy has its own cert and we'd just fail Let's Encrypt's
# port-80 challenge from inside the LAN.
if [ "$DEPLOYMENT_MODE" != "cloud" ]; then
    : # skip for air-gapped
elif [ "$INSTALL_LOCAL_NGINX" = "false" ] && [ "$ENABLE_TLS" = "false" ]; then
    echo ""
    echo -e "${CYAN}[SKIP] SSL: external reverse proxy handles TLS — no local certs needed.${NC}"
elif step_done "ssl_certs"; then
    echo -e "${GREEN}[SKIP] SSL certificates already configured${NC}"
else
    echo ""
    echo "=== SSL Certificate Setup ==="

    # Parse domains from config
    API_DOMAIN=$(echo "$EXTERNAL_URL" | sed 's|https://||;s|http://||' | cut -d/ -f1 | cut -d: -f1)
    MQTT_DOMAIN=$(echo "$MQTT_EXTERNAL_HOST" | cut -d: -f1)

    echo "API domain  : $API_DOMAIN"
    echo "MQTT domain : $MQTT_DOMAIN"
    echo ""

    # Install certbot if missing
    if ! command -v certbot &>/dev/null; then
        echo "Installing certbot..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y certbot python3-certbot-nginx 2>&1 | grep -E "Setting up|already"
        elif command -v yum &>/dev/null; then
            sudo yum install -y certbot 2>&1 | grep -E "Installing|already"
        else
            echo -e "${RED}Cannot auto-install certbot. Install it manually and re-run.${NC}"
            echo "  https://certbot.eff.org"
            exit 1
        fi
    fi

    read -rp "Email address for Let's Encrypt renewal notices: " CERT_EMAIL
    CERT_EMAIL=${CERT_EMAIL:-"admin@$API_DOMAIN"}
    save_val CERT_EMAIL "$CERT_EMAIL"

    # Helper: request a cert via standalone (stops/starts nginx around it)
    request_cert() {
        local domain="$1"
        # Check if cert already exists and is valid
        if sudo certbot certificates 2>/dev/null | grep -q "Domains:.*$domain"; then
            echo -e "  ${GREEN}Certificate for $domain already exists${NC}"
            return 0
        fi

        echo "  Requesting certificate for $domain..."
        NGINX_RUNNING=false
        if systemctl is-active --quiet nginx 2>/dev/null; then
            sudo systemctl stop nginx
            NGINX_RUNNING=true
        fi

        sudo certbot certonly --standalone --non-interactive --agree-tos \
            -m "$CERT_EMAIL" -d "$domain" 2>&1 | grep -E "Congratulations|error|Error|failed|Cert"
        CERT_RC=${PIPESTATUS[0]}

        $NGINX_RUNNING && sudo systemctl start nginx
        return $CERT_RC
    }

    CERT_ERRORS=0

    # API cert (only needed for direct TLS mode; reverse proxy uses its own cert)
    if [ "$ENABLE_TLS" = "true" ]; then
        request_cert "$API_DOMAIN" || CERT_ERRORS=$((CERT_ERRORS+1))
        if [ $CERT_ERRORS -eq 0 ]; then
            # Update .env with real cert paths
            CERT_PATH="/etc/letsencrypt/live/$API_DOMAIN"
            sed -i "s|^TLS_CERT=.*|TLS_CERT=$CERT_PATH/fullchain.pem|" "$ENV_FILE"
            sed -i "s|^TLS_KEY=.*|TLS_KEY=$CERT_PATH/privkey.pem|"     "$ENV_FILE"
            echo -e "  ${GREEN}TLS cert paths updated in .env${NC}"
        fi
    fi

    # MQTT cert (always needed for cloud mode)
    if [ "$MQTT_DOMAIN" != "localhost" ] && [ "$MQTT_DOMAIN" != "127.0.0.1" ]; then
        request_cert "$MQTT_DOMAIN" || {
            echo -e "  ${YELLOW}Could not get cert for $MQTT_DOMAIN.${NC}"
            echo "  Make sure port 80 is reachable and DNS is pointing to this server."
            echo "  Re-run this script after fixing DNS/firewall to retry."
            CERT_ERRORS=$((CERT_ERRORS+1))
        }
    fi

    if [ $CERT_ERRORS -gt 0 ]; then
        echo -e "${YELLOW}Some certificates could not be obtained. Fix the issues above and re-run.${NC}"
        # Don't exit — allow the rest of the install to continue
    else
        echo -e "${GREEN}SSL certificates ready.${NC}"
        mark_done "ssl_certs"
    fi
fi

# ---------------------------------------------------------------------------
# STEP 4: Mosquitto Setup
# ---------------------------------------------------------------------------
# Air-gapped : one plain, anonymous listener on the LAN (1883, no TLS/auth) —
#              devices share the local network.
# Cloud      : per-device authentication. The Go server renders one
#              "<user>:<hash>" line per enrolled device (plus an ACL) from
#              Postgres into MQTT_AUTH_DIR on every enrollment; a systemd path
#              unit SIGHUPs mosquitto so it re-reads them. The loopback 1883
#              listener stays anonymous for the server's own connection; the
#              public listener requires the per-device credentials.
if step_done "mosquitto_setup"; then
    echo -e "${GREEN}[SKIP] Mosquitto already configured${NC}"
else
    echo ""
    echo "=== Mosquitto MQTT Broker Setup ==="
    MOSQUITTO_CONF="/etc/mosquitto/conf.d/localdroid.conf"

    # Install Mosquitto if missing (offline bundles already installed it via debs)
    if ! command -v mosquitto &>/dev/null; then
        echo "Installing Mosquitto..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y mosquitto mosquitto-clients 2>&1 | grep -E "Setting up|already"
        elif command -v yum &>/dev/null; then
            sudo yum install -y mosquitto 2>&1 | grep -E "Installing|already"
        else
            echo -e "${RED}Cannot auto-install Mosquitto. Install it manually and re-run.${NC}"
            exit 1
        fi
    fi

    if [ "$DEPLOYMENT_MODE" != "cloud" ]; then
        # ---- Air-gapped: plain anonymous LAN broker ----
        # The broker itself needs no auth files, but the server still renders
        # per-device credentials on enrollment and defaults to the Docker path
        # /mosquitto/auth if unset — which fails and logs a confusing error.
        # Point it at a valid (unused) dir so the render succeeds quietly.
        MQTT_AUTH_DIR="/etc/mosquitto/localdroid-auth"
        SERVICE_USER=$(whoami)
        sudo mkdir -p "$MQTT_AUTH_DIR"
        sudo chown "$SERVICE_USER":"$SERVICE_USER" "$MQTT_AUTH_DIR"
        sudo chmod 755 "$MQTT_AUTH_DIR"
        if grep -q "^MQTT_AUTH_DIR=" "$ENV_FILE"; then
            sed -i "s|^MQTT_AUTH_DIR=.*|MQTT_AUTH_DIR=$MQTT_AUTH_DIR|" "$ENV_FILE"
        else
            printf '\n# Where the server renders per-device MQTT auth files (unused by\n# the anonymous air-gapped broker, but keeps the render step from erroring).\nMQTT_AUTH_DIR=%s\n' "$MQTT_AUTH_DIR" >> "$ENV_FILE"
        fi

        echo "Writing $MOSQUITTO_CONF (air-gapped: plain anonymous LAN listener) ..."
        sudo tee "$MOSQUITTO_CONF" > /dev/null << EOF
# LocalDroid MQTT Configuration (air-gapped) — generated by install.sh on $(date)
# Devices are on the local network, so the broker is plain and anonymous.
listener 1883 0.0.0.0
allow_anonymous true

# Resource limits — a runaway client can't exhaust the broker or flood the LAN.
max_queued_messages 200
message_size_limit 10485760
max_keepalive 120
max_connections 1024
EOF
        sudo systemctl enable mosquitto 2>/dev/null
        sudo systemctl restart mosquitto
        if systemctl is-active --quiet mosquitto; then
            LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
            echo -e "${GREEN}Mosquitto running: 0.0.0.0:1883 (plain, anonymous, LAN-reachable at ${LAN_IP}:1883).${NC}"
            mark_done "mosquitto_setup"
        else
            echo -e "${RED}Mosquitto failed to start. Check: sudo journalctl -u mosquitto -n 20${NC}"
            exit 1
        fi
    else
        # ---- Cloud: per-device authentication ----
        MQTT_DOMAIN=$(echo "$MQTT_EXTERNAL_HOST" | cut -d: -f1)
        MQTT_CERT_SRC="/etc/letsencrypt/live/$MQTT_DOMAIN"
        MQTT_CERT_DIR="/etc/mosquitto/certs"

        # Directory the server writes per-device passwd + acl into. Kept under
        # /etc/mosquitto so any mosquitto AppArmor profile permits reading it,
        # and owned by the service user so the (non-root) server can write it.
        MQTT_AUTH_DIR="/etc/mosquitto/localdroid-auth"
        SERVICE_USER=$(whoami)
        sudo mkdir -p "$MQTT_AUTH_DIR"
        # Owner = service user (server writes here); group = mosquitto with setgid
        # so the server-rendered passwd/acl inherit group mosquitto and the broker
        # can read them 0640 (not world-readable — mosquitto refuses those).
        sudo chown "$SERVICE_USER":mosquitto "$MQTT_AUTH_DIR"
        sudo chmod 2750 "$MQTT_AUTH_DIR"
        # Seed empty files so mosquitto starts before the first device enrolls.
        sudo -u "$SERVICE_USER" touch "$MQTT_AUTH_DIR/passwd" "$MQTT_AUTH_DIR/acl"
        sudo chmod 640 "$MQTT_AUTH_DIR/passwd" "$MQTT_AUTH_DIR/acl"

        # Tell the server where to render them (overrides the Docker-era default
        # /mosquitto/auth). Without this, RenderAuthFiles fails and no enrolled
        # device can authenticate to the broker.
        if grep -q "^MQTT_AUTH_DIR=" "$ENV_FILE"; then
            sed -i "s|^MQTT_AUTH_DIR=.*|MQTT_AUTH_DIR=$MQTT_AUTH_DIR|" "$ENV_FILE"
        else
            printf '\n# Per-device MQTT auth files (server-rendered from Postgres).\nMQTT_AUTH_DIR=%s\n' "$MQTT_AUTH_DIR" >> "$ENV_FILE"
        fi

        # Decide the device-facing listener.
        WRITE_CONFIG=true
        DEVICE_LISTEN=""     # the "listener ..." line
        DEVICE_TLS=""        # cafile/certfile/keyfile lines (direct-TLS only)
        PROXY_NOTE=""
        if [ "$INSTALL_LOCAL_NGINX" = "false" ]; then
            # External proxy terminates TLS and forwards plain to this host. Use
            # a dedicated plain port (1884) so it never collides with the
            # anonymous loopback on 1883.
            DEVICE_LISTEN="listener 1884 0.0.0.0"
            LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
            PROXY_NOTE="External proxy: forward ${MQTT_EXTERNAL_PORT}/tcp (TLS) -> ${LAN_IP}:1884 (plain)."
        elif ! sudo test -d "$MQTT_CERT_SRC"; then
            echo -e "${YELLOW}Let's Encrypt cert for $MQTT_DOMAIN not found — skipping Mosquitto TLS config.${NC}"
            echo "  Re-run this script after the SSL cert step succeeds."
            WRITE_CONFIG=false
        else
            echo "Copying certs to $MQTT_CERT_DIR ..."
            sudo mkdir -p "$MQTT_CERT_DIR"
            sudo cp "$MQTT_CERT_SRC/fullchain.pem" "$MQTT_CERT_DIR/"
            sudo cp "$MQTT_CERT_SRC/privkey.pem"   "$MQTT_CERT_DIR/"
            sudo cp "$MQTT_CERT_SRC/chain.pem"     "$MQTT_CERT_DIR/"
            sudo chown -R mosquitto:mosquitto "$MQTT_CERT_DIR"
            sudo chmod 644 "$MQTT_CERT_DIR"/*.pem
            sudo chmod 600 "$MQTT_CERT_DIR/privkey.pem"
            DEVICE_LISTEN="listener $MQTT_EXTERNAL_PORT"
            DEVICE_TLS="cafile   $MQTT_CERT_DIR/chain.pem
certfile $MQTT_CERT_DIR/fullchain.pem
keyfile  $MQTT_CERT_DIR/privkey.pem"

            # Cert renewal hook — re-copy renewed certs and restart mosquitto.
            RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/localdroid-mosquitto.sh"
            sudo tee "$RENEWAL_HOOK" > /dev/null << HOOK
#!/bin/bash
# Auto-copy renewed Let's Encrypt certs for Mosquitto — LocalDroid
cp /etc/letsencrypt/live/$MQTT_DOMAIN/fullchain.pem $MQTT_CERT_DIR/
cp /etc/letsencrypt/live/$MQTT_DOMAIN/privkey.pem   $MQTT_CERT_DIR/
cp /etc/letsencrypt/live/$MQTT_DOMAIN/chain.pem     $MQTT_CERT_DIR/
chown -R mosquitto:mosquitto $MQTT_CERT_DIR
chmod 644 $MQTT_CERT_DIR/*.pem
chmod 600 $MQTT_CERT_DIR/privkey.pem
systemctl restart mosquitto
HOOK
            sudo chmod +x "$RENEWAL_HOOK"
            echo -e "  ${GREEN}Cert renewal hook installed${NC}"
        fi

        if [ "$WRITE_CONFIG" = "true" ]; then
            echo "Writing $MOSQUITTO_CONF (cloud, per-device auth) ..."
            sudo tee "$MOSQUITTO_CONF" > /dev/null << EOF
# LocalDroid MQTT Configuration (cloud) — generated by install.sh on $(date)
# Per-listener settings: the loopback stays anonymous for the server while the
# public listener enforces per-device credentials + ACLs.
per_listener_settings true

# Global resource limits — a runaway client can't exhaust the broker.
max_queued_messages 200
message_size_limit 10485760
max_keepalive 120

# Loopback listener — the Go server connects here (localhost only, anonymous).
listener 1883 127.0.0.1
allow_anonymous true

# Public listener — devices authenticate with per-device credentials. The server
# rewrites \$MQTT_AUTH_DIR/{passwd,acl} from Postgres on every enrollment, and
# localdroid-mqtt-reload.path SIGHUPs mosquitto so it re-reads them.
$DEVICE_LISTEN
$DEVICE_TLS
allow_anonymous false
password_file $MQTT_AUTH_DIR/passwd
acl_file $MQTT_AUTH_DIR/acl
max_connections 1024
EOF

            # Reloader: watch the auth dir and SIGHUP mosquitto when the server
            # rewrites passwd/acl. Runs as root via systemd, so the non-root
            # server never needs permission to signal the broker.
            sudo tee /etc/systemd/system/localdroid-mqtt-reload.service > /dev/null << 'UNIT'
[Unit]
Description=Reload Mosquitto after LocalDroid rewrites its MQTT auth files

[Service]
Type=oneshot
ExecStart=/bin/systemctl reload mosquitto
UNIT
            sudo tee /etc/systemd/system/localdroid-mqtt-reload.path > /dev/null << UNIT
[Unit]
Description=Watch LocalDroid MQTT auth files and reload Mosquitto on change

[Path]
PathModified=$MQTT_AUTH_DIR

[Install]
WantedBy=multi-user.target
UNIT
            sudo systemctl daemon-reload
            sudo systemctl enable --now localdroid-mqtt-reload.path 2>/dev/null

            sudo systemctl enable mosquitto 2>/dev/null
            sudo systemctl restart mosquitto
            if systemctl is-active --quiet mosquitto; then
                echo -e "${GREEN}Mosquitto running: 127.0.0.1:1883 (server) + per-device auth on the public listener.${NC}"
                [ -n "$PROXY_NOTE" ] && echo -e "${CYAN}$PROXY_NOTE${NC}"
                mark_done "mosquitto_setup"
            else
                echo -e "${RED}Mosquitto failed to start. Check: sudo journalctl -u mosquitto -n 20${NC}"
                exit 1
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# STEP 4b: coturn (TURN/STUN) Setup  (cloud mode only)
# ---------------------------------------------------------------------------
# Android remote control uses WebRTC. On a flat LAN the peers connect via host
# candidates, but over the internet (cellular, strict NAT) they need a TURN
# relay to punch through. coturn provides that relay. Windows remote control
# uses VNC relayed through the Go server over WebSocket and does NOT need this.
#
# The agent + web admin clients authenticate to coturn with the "TURN REST API"
# scheme (use-auth-secret): username "<expiry>:<id>", credential
# base64(HMAC-SHA1(secret, username)). The shared secret is baked into the
# compiled clients, so coturn MUST use the same value. Changing it requires
# rebuilding both the APK and the web bundle — don't randomize it here.
TURN_SECRET="${TURN_SECRET:-localdroid_turn_secret_2024}"

if [ "$DEPLOYMENT_MODE" != "cloud" ]; then
    : # air-gapped LAN: WebRTC uses host candidates, no TURN relay needed
elif step_done "coturn_setup"; then
    echo -e "${GREEN}[SKIP] coturn already configured${NC}"
else
    echo ""
    echo "=== coturn (TURN/STUN) Setup — Android remote control over the internet ==="

    # Install coturn if missing
    if ! command -v turnserver &>/dev/null; then
        echo "Installing coturn..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y coturn 2>&1 | grep -E "Setting up|already" || true
        elif command -v yum &>/dev/null; then
            sudo yum install -y coturn 2>&1 | grep -E "Installing|already" || true
        elif command -v apk &>/dev/null; then
            sudo apk add --no-cache coturn 2>&1 | tail -1 || true
        else
            echo -e "${YELLOW}Cannot auto-install coturn. Install it manually and re-run this step.${NC}"
        fi
    fi

    if ! command -v turnserver &>/dev/null; then
        echo -e "${YELLOW}coturn not available — skipping. Android remote control will work only on a flat LAN.${NC}"
        echo -e "${YELLOW}  Install coturn later and re-run: rm marker via the state file, or set it up manually.${NC}"
        mark_done "coturn_setup"
    else
        # --- external-ip: coturn must advertise the box's PUBLIC IP for relay
        # candidates. Try the saved address (if it's already an IP), else
        # auto-detect via an external echo service.
        TURN_EXTERNAL_IP=""
        if [[ "$SERVER_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            TURN_EXTERNAL_IP="$SERVER_PUBLIC_IP"
        fi
        if [ -z "$TURN_EXTERNAL_IP" ]; then
            TURN_EXTERNAL_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
            [ -z "$TURN_EXTERNAL_IP" ] && TURN_EXTERNAL_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)
        fi
        TURN_EXTERNAL_IP=$(prompt_with_default "Public IP for TURN relay candidates (external-ip)" "${TURN_EXTERNAL_IP:-$SERVER_PUBLIC_IP}")

        # --- realm: the public hostname devices use (cosmetic but required).
        TURN_REALM=$(echo "$EXTERNAL_URL" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##')
        [ -z "$TURN_REALM" ] && TURN_REALM="$SERVER_PUBLIC_IP"

        echo "Writing /etc/turnserver.conf ..."
        sudo tee /etc/turnserver.conf > /dev/null << EOF
# LocalDroid coturn (TURN/STUN) — generated by install.sh on $(date)
#
# TURN REST API auth: clients send username "<expiry>:<id>" and
# base64(HMAC-SHA1(static-auth-secret, username)). The secret below MUST match
# the value compiled into the Android APK and web bundle.
listening-port=3478
listening-ip=0.0.0.0
external-ip=$TURN_EXTERNAL_IP
min-port=49152
max-port=49200
fingerprint
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=$TURN_REALM
# Plain UDP/TCP relay only — the WebRTC media is already DTLS-SRTP encrypted
# end to end, so coturn itself doesn't need its own TLS listener.
no-tls
no-dtls
# Disable the telnet/CLI admin port (5766) — not needed, smaller surface.
no-cli
# Don't relay to private/loopback ranges — prevents the relay being abused to
# reach internal services.
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
EOF

        # Enable the daemon (Debian/Ubuntu ship it disabled by default).
        if [ -f /etc/default/coturn ]; then
            if grep -q '^#*\s*TURNSERVER_ENABLED' /etc/default/coturn; then
                sudo sed -i 's/^#*\s*TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
            else
                echo 'TURNSERVER_ENABLED=1' | sudo tee -a /etc/default/coturn > /dev/null
            fi
        fi

        # --- Open the firewall (only if ufw is installed AND active) ---
        if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
            echo "Opening TURN ports in ufw..."
            sudo ufw allow 3478/tcp >/dev/null 2>&1 || true
            sudo ufw allow 3478/udp >/dev/null 2>&1 || true
            sudo ufw allow 49152:49200/udp >/dev/null 2>&1 || true
            echo -e "  ${GREEN}ufw: 3478/tcp, 3478/udp, 49152-49200/udp opened${NC}"
        fi

        sudo systemctl enable coturn 2>/dev/null || true
        sudo systemctl restart coturn 2>/dev/null || true
        if systemctl is-active --quiet coturn; then
            echo -e "${GREEN}coturn running — TURN relay on $TURN_EXTERNAL_IP:3478 (realm $TURN_REALM)${NC}"
        else
            echo -e "${YELLOW}coturn installed but not active. Check: sudo journalctl -u coturn -n 30${NC}"
        fi

        echo -e "${CYAN}NOTE: open these on your cloud/provider firewall too (not just ufw):${NC}"
        echo -e "${CYAN}  3478/tcp, 3478/udp, and 49152-49200/udp inbound.${NC}"
        echo -e "${CYAN}  If a reverse proxy / NAT fronts this box, forward those ports to it.${NC}"
        mark_done "coturn_setup"
    fi
fi

# ---------------------------------------------------------------------------
# STEP 5: Nginx Setup  (cloud + reverse proxy mode only)
# ---------------------------------------------------------------------------
# Three skip conditions:
#   - Air-gapped deployments don't need a reverse proxy.
#   - Direct-TLS mode terminates TLS in the Go server itself, no nginx.
#   - External reverse proxy (INSTALL_LOCAL_NGINX=false) — the customer
#     already has nginx/Caddy/HAProxy on another box, install.sh must NOT
#     touch nginx here. (This is the case that previously broke when the
#     installer wrote to /etc/nginx/sites-enabled/localdroid and stomped on
#     an existing proxy config.)
if [ "$DEPLOYMENT_MODE" != "cloud" ] || [ "$ENABLE_TLS" != "false" ]; then
    : # skip — direct-TLS or air-gapped
elif [ "$INSTALL_LOCAL_NGINX" = "false" ]; then
    echo ""
    echo -e "${CYAN}[SKIP] Nginx: external reverse proxy will handle this — not installing nginx here.${NC}"
    echo -e "${CYAN}      Point your external proxy at: http://$(hostname -I 2>/dev/null | awk '{print $1}'):$SERVER_PORT${NC}"
elif step_done "nginx_setup"; then
    echo -e "${GREEN}[SKIP] Nginx already configured${NC}"
else
    echo ""
    echo "=== Nginx Reverse Proxy Setup ==="

    API_DOMAIN=$(echo "$EXTERNAL_URL" | sed 's|https://||;s|http://||' | cut -d/ -f1 | cut -d: -f1)

    # Install nginx if missing
    if ! command -v nginx &>/dev/null; then
        echo "Installing nginx..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y nginx 2>&1 | grep -E "Setting up|already"
        elif command -v yum &>/dev/null; then
            sudo yum install -y nginx 2>&1 | grep -E "Installing|already"
        fi
    fi

    NGINX_CONF="/etc/nginx/sites-available/localdroid"
    NGINX_ENABLED="/etc/nginx/sites-enabled/localdroid"

    if [ -f "$NGINX_CONF" ]; then
        echo -e "${GREEN}Nginx config already exists at $NGINX_CONF — skipping write.${NC}"
    else
        echo "Writing nginx config for $API_DOMAIN → 127.0.0.1:$SERVER_PORT ..."

        # Get cert for API domain if not already done
        if ! sudo certbot certificates 2>/dev/null | grep -q "Domains:.*$API_DOMAIN"; then
            CERT_EMAIL=$(get_val CERT_EMAIL)
            echo "Getting SSL certificate for $API_DOMAIN ..."
            sudo systemctl stop nginx 2>/dev/null
            sudo certbot certonly --standalone --non-interactive --agree-tos \
                -m "$CERT_EMAIL" -d "$API_DOMAIN" 2>&1 | grep -E "Congratulations|error|Error"
            sudo systemctl start nginx 2>/dev/null
        fi

        sudo tee "$NGINX_CONF" > /dev/null << EOF
# LocalDroid nginx config — generated by install.sh on $(date)

server {
    listen 80;
    server_name $API_DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $API_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$API_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$API_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    location / {
        proxy_pass         http://127.0.0.1:$SERVER_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        client_max_body_size 500M;
        # Keep WebSocket connections alive for VNC remote control sessions
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
    }
}
EOF

        sudo ln -sf "$NGINX_CONF" "$NGINX_ENABLED"
        # Remove default site if present
        sudo rm -f /etc/nginx/sites-enabled/default
    fi

    # Install certbot renewal hook for nginx
    RENEWAL_HOOK_NGINX="/etc/letsencrypt/renewal-hooks/deploy/localdroid-nginx.sh"
    if [ ! -f "$RENEWAL_HOOK_NGINX" ]; then
        sudo tee "$RENEWAL_HOOK_NGINX" > /dev/null << 'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
        sudo chmod +x "$RENEWAL_HOOK_NGINX"
    fi

    sudo nginx -t 2>&1 && sudo systemctl enable nginx && sudo systemctl reload nginx
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}Nginx running — $API_DOMAIN proxying to 127.0.0.1:$SERVER_PORT${NC}"
        mark_done "nginx_setup"
    else
        echo -e "${RED}Nginx failed to start. Check: sudo nginx -t${NC}"
        exit 1
    fi
fi


# ---------------------------------------------------------------------------
# STEP 6: PostgreSQL Database Setup
# ---------------------------------------------------------------------------
if step_done "db_setup"; then
    echo -e "${GREEN}[SKIP] Database setup already completed${NC}"
else
    echo ""
    echo "=== PostgreSQL Database Setup ==="
    echo "Configuring database: $DB_NAME on $DB_HOST:$DB_PORT"
    echo ""

    if ! command -v psql &>/dev/null; then
        echo -e "${YELLOW}psql not found in PATH. Install PostgreSQL client tools first:${NC}"
        echo "  Ubuntu/Debian : sudo apt install postgresql-client"
        echo "  RHEL/CentOS   : sudo yum install postgresql"
        echo ""
        echo "Then create the database manually before continuing:"
        echo "  sudo -u postgres psql -c \"CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';\""
        echo "  sudo -u postgres psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER;\""
        echo "  sudo -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\""
        echo "  sudo -u postgres psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\""
        echo ""
        read -rp "Press Enter once the database is ready, or Ctrl+C to abort..."
        mark_done "db_setup"
    else
        # Check if we can already connect with the configured credentials
        if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
                -d "$DB_NAME" -c '\q' 2>/dev/null; then
            echo -e "${GREEN}Connected to database '$DB_NAME' successfully.${NC}"
            mark_done "db_setup"
        else
            echo "Cannot connect to '$DB_NAME' with the configured credentials."
            echo "Attempting to create the database and user automatically..."
            echo ""

            DB_CREATED=false

            # Try via the local postgres superuser. First non-interactively in
            # case the sudo session is still cached, then explicitly interactive
            # so the operator can re-auth if 15 minutes have passed since the
            # last sudo earlier in the script (very easy to hit on slow
            # installs). The previous version silenced stderr on the second
            # attempt, which made the failure look like "no access" instead of
            # "sudo timed out, give me your password."
            SUDO_PG_OK=false
            if sudo -n -u postgres psql -c '\q' 2>/dev/null; then
                SUDO_PG_OK=true
            else
                echo ""
                echo "I need sudo to create the postgres user and database."
                echo "Enter your sudo password if prompted:"
                if sudo -u postgres psql -c '\q'; then
                    SUDO_PG_OK=true
                fi
            fi
            if [ "$SUDO_PG_OK" = "true" ]; then
                echo "Using postgres superuser to create database objects..."

                sudo -u postgres psql -v ON_ERROR_STOP=0 << SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER') THEN
        CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';
        RAISE NOTICE 'User $DB_USER created.';
    ELSE
        RAISE NOTICE 'User $DB_USER already exists.';
    END IF;
END
\$\$;
SQL

                # Create database if it doesn't exist (cannot use IF NOT EXISTS in older PG)
                DB_EXISTS=$(sudo -u postgres psql -tAc \
                    "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';" 2>/dev/null)
                if [ "$DB_EXISTS" != "1" ]; then
                    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null \
                        && echo -e "${GREEN}Database '$DB_NAME' created.${NC}"
                else
                    echo "Database '$DB_NAME' already exists."
                fi

                sudo -u postgres psql -c \
                    "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;" 2>/dev/null || true
                sudo -u postgres psql -d "$DB_NAME" -c \
                    "GRANT ALL ON SCHEMA public TO $DB_USER;" 2>/dev/null || true

                DB_CREATED=true
            fi

            if $DB_CREATED; then
                if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
                        -d "$DB_NAME" -c '\q' 2>/dev/null; then
                    echo -e "${GREEN}Database connection verified.${NC}"
                    mark_done "db_setup"
                else
                    echo -e "${RED}Database was created but connection still fails.${NC}"
                    echo "Check that PostgreSQL is running and that pg_hba.conf allows"
                    echo "password authentication for user '$DB_USER'."
                    exit 1
                fi
            else
                echo -e "${YELLOW}Automatic setup failed (no postgres superuser access).${NC}"
                echo ""
                echo "Create the database manually then re-run this script:"
                echo "  sudo -u postgres psql -c \"CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';\""
                echo "  sudo -u postgres psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER;\""
                echo "  sudo -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\""
                echo "  sudo -u postgres psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\""
                exit 1
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# STEP 7: Database Migrations
# ---------------------------------------------------------------------------
MIGRATIONS_DIR="$SCRIPT_DIR/server/migrations"

if step_done "migrations"; then
    echo -e "${GREEN}[SKIP] Database migrations already applied${NC}"
else
    echo ""
    echo "=== Running Database Migrations ==="

    if ! command -v psql &>/dev/null; then
        echo -e "${YELLOW}psql not found — skipping automatic migrations.${NC}"
        echo "Run migrations manually after installing postgresql-client:"
        echo "  for f in \$(ls $MIGRATIONS_DIR/*.sql | sort); do"
        echo "    PGPASSWORD='$DB_PASSWORD' psql -h $DB_HOST -p $DB_PORT \\"
        echo "      -U $DB_USER -d $DB_NAME -f \"\$f\""
        echo "  done"
        mark_done "migrations"
    elif [ ! -d "$MIGRATIONS_DIR" ]; then
        echo -e "${YELLOW}Migrations directory not found at $MIGRATIONS_DIR — skipping.${NC}"
        mark_done "migrations"
    else
        # Create migration tracking table
        PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
            -d "$DB_NAME" -c "
            CREATE TABLE IF NOT EXISTS schema_migrations (
                filename   TEXT        PRIMARY KEY,
                checksum   TEXT        NOT NULL DEFAULT '',
                applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );
            -- Same shape the server uses (server/internal/migrate); older
            -- installs created the table without checksum.
            ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS checksum TEXT NOT NULL DEFAULT '';" > /dev/null 2>&1 || {
            echo -e "${RED}Could not create schema_migrations table. Is the database accessible?${NC}"
            exit 1
        }

        MIGRATION_ERRORS=0
        MIGRATION_APPLIED=0
        MIGRATION_SKIPPED=0

        for MIGRATION_FILE in $(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | sort); do
            MIGRATION_NAME=$(basename "$MIGRATION_FILE")

            # Check whether this migration has already been applied
            ALREADY_APPLIED=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" \
                -U "$DB_USER" -d "$DB_NAME" -tAc \
                "SELECT COUNT(*) FROM schema_migrations WHERE filename='$MIGRATION_NAME';" 2>/dev/null)

            if [ "$ALREADY_APPLIED" = "1" ]; then
                echo -e "  ${GREEN}[skip]${NC} $MIGRATION_NAME"
                MIGRATION_SKIPPED=$((MIGRATION_SKIPPED + 1))
                continue
            fi

            printf "  Applying %-50s" "$MIGRATION_NAME ..."
            ERR_OUTPUT=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" \
                -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
                -f "$MIGRATION_FILE" 2>&1)
            if [ $? -eq 0 ]; then
                PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" \
                    -U "$DB_USER" -d "$DB_NAME" -c \
                    "INSERT INTO schema_migrations (filename) VALUES ('$MIGRATION_NAME')
                     ON CONFLICT DO NOTHING;" > /dev/null 2>&1
                echo -e "${GREEN}done${NC}"
                MIGRATION_APPLIED=$((MIGRATION_APPLIED + 1))
            else
                echo -e "${RED}FAILED${NC}"
                echo "$ERR_OUTPUT" | head -15 | sed 's/^/    /'
                MIGRATION_ERRORS=$((MIGRATION_ERRORS + 1))
            fi
        done

        echo ""
        if [ $MIGRATION_ERRORS -gt 0 ]; then
            echo -e "${RED}$MIGRATION_ERRORS migration(s) failed. Fix the errors above and re-run.${NC}"
            exit 1
        else
            echo -e "${GREEN}Migrations complete: $MIGRATION_APPLIED applied, $MIGRATION_SKIPPED already up to date.${NC}"
            mark_done "migrations"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# STEP 9: Install agent binaries  (Android APK + Windows EXE, local-only)
# ---------------------------------------------------------------------------
# Both binaries get copied from bundled locations into server/storage/agent/
# where the Go server expects to serve them from. The bundle ships them in
# seed/ (canonical layout produced by scripts/build-native-bundle.sh); legacy
# hand-rolled deployments may have them in releases/. Developers building the
# Android APK from source get a fallback for android-agent/.
#
# If no local copy is found, we fall back to downloading over HTTPS — first from
# the operator's OWN public mirror (AGENT_DOWNLOAD_BASE, default
# https://localdroid.app/agent), then from the public installers repo's latest
# GitHub release (AGENT_RELEASE_BASE). Neither is the private source repo — both
# host the same binaries the bundle ships, so a "thin" bundle (no seed/) can
# still self-provision. The GitHub release is the canonical home for the Windows
# EXE (the localdroid.app mirror only carries the APK), so it's a required
# fallback, not a nicety. Local seed/ always wins; the network is only a backstop.
# Override: AGENT_DOWNLOAD_BASE=https://your.mirror/agent ./install.sh
# Disable both (force local-only / air-gapped): set them to "".
AGENT_DOWNLOAD_BASE="${AGENT_DOWNLOAD_BASE-https://localdroid.app/agent}"
AGENT_RELEASE_BASE="${AGENT_RELEASE_BASE-https://github.com/localdroidapp/localdroid-installers/releases/latest/download}"
AGENT_STORAGE="$SCRIPT_DIR/server/storage/agent"
mkdir -p "$AGENT_STORAGE"

# Generic seeder. Copies the named agent file from the first existing
# candidate path into server/storage/agent/. Returns 0 on success, 1 on miss.
seed_agent_binary() {
    local filename="$1"
    local label="$2"
    local dest="$AGENT_STORAGE/$filename"

    # If the operator has already placed (or built) the file at the
    # destination, leave it alone — re-runs should never clobber.
    if [ -s "$dest" ]; then
        local size=$(du -h "$dest" | cut -f1)
        echo -e "${GREEN}$label agent already at $dest ($size) — leaving it alone${NC}"
        return 0
    fi

    # Priority order: seed/ (canonical) → releases/ (legacy hand-rolled).
    # APK-specific extras come from the legacy filename and dev source build.
    local -a candidates=(
        "$SCRIPT_DIR/seed/$filename"
        "$SCRIPT_DIR/releases/$filename"
    )
    if [ "$filename" = "localdroid-agent.apk" ]; then
        candidates+=(
            "$SCRIPT_DIR/releases/localdroid-agent-v1.0.0.apk"
            "$SCRIPT_DIR/android-agent/app/build/outputs/apk/release/app-release.apk"
        )
    fi

    local src
    for src in "${candidates[@]}"; do
        if [ -f "$src" ]; then
            cp "$src" "$dest"
            local size=$(du -h "$dest" | cut -f1)
            echo -e "${GREEN}$label agent installed: $src → $dest ($size)${NC}"
            return 0
        fi
    done

    # Fallback: download over HTTPS. Try the operator mirror first, then the
    # public installers-repo GitHub release. Only the APK/EXE — never source.
    # Also pulls the .cert-sha256 sidecar (APK) so Zero-Touch enrollment has its
    # checksum without apksigner on this box.
    if command -v curl &>/dev/null; then
        local base url
        for base in "$AGENT_DOWNLOAD_BASE" "$AGENT_RELEASE_BASE"; do
            [ -z "$base" ] && continue
            url="${base%/}/$filename"
            echo "No local $label agent — trying: $url"
            if curl -fSL --connect-timeout 10 --retry 2 -o "$dest.partial" "$url" 2>/dev/null \
               && [ -s "$dest.partial" ]; then
                mv "$dest.partial" "$dest"
                local size=$(du -h "$dest" | cut -f1)
                echo -e "${GREEN}$label agent downloaded: $url → $dest ($size)${NC}"
                # Best-effort: grab the cert sidecar alongside the APK.
                if [ "$filename" = "localdroid-agent.apk" ]; then
                    curl -fsSL --connect-timeout 10 -o "$AGENT_STORAGE/$filename.cert-sha256" \
                        "${base%/}/$filename.cert-sha256" 2>/dev/null \
                        && echo "  fetched cert sidecar for checksum" || true
                fi
                return 0
            fi
            rm -f "$dest.partial"
            echo -e "${YELLOW}  Not available at $url${NC}"
        done
        echo -e "${YELLOW}  Download failed from all sources (offline or 404).${NC}"
    fi

    echo -e "${YELLOW}No $label agent ($filename) found locally or online.${NC}"
    echo "  Searched:"
    local c
    for c in "${candidates[@]}"; do
        echo "    $c"
    done
    [ -n "$AGENT_DOWNLOAD_BASE" ] && echo "    $AGENT_DOWNLOAD_BASE/$filename (mirror)"
    [ -n "$AGENT_RELEASE_BASE" ]  && echo "    $AGENT_RELEASE_BASE/$filename (GitHub release)"
    echo -e "${YELLOW}  Drop a copy at $dest then re-run, or place $filename in seed/.${NC}"
    return 1
}

if step_done "agents_seed"; then
    echo -e "${GREEN}[SKIP] Agent binaries already installed${NC}"
else
    echo ""
    echo "=== Installing Agent Binaries ==="

    seed_agent_binary "localdroid-agent.apk" "Android"
    APK_OK=$?
    seed_agent_binary "localdroid-agent.exe" "Windows"
    EXE_OK=$?

    # APK signing certificate checksum (base64-urlsafe sha256 of the signer
    # cert) — Android Setup Wizard uses this during Zero-Touch to verify the
    # APK it downloaded was signed by the key we expect. If this doesn't match
    # the cert the APK is actually signed with, enrollment fails with the
    # opaque "Something went wrong" message.
    #
    # Source priority:
    #   1. seed/localdroid-agent.apk.cert-sha256 — sidecar produced by
    #      scripts/build-native-bundle.sh at bundle time. No apksigner needed
    #      on the customer box.
    #   2. apksigner against the seeded APK — for dev installs or hand-rolled
    #      deployments where the sidecar wasn't shipped.
    #   3. Leave .env empty + loud warning — better than baking in a wrong
    #      value that silently bricks every enrollment attempt.
    #
    # We always recompute on every install.sh run (not just first-time): if
    # the operator drops in a re-signed APK and re-runs install.sh, the .env
    # must follow.
    if [ $APK_OK -eq 0 ]; then
        APK_CHECKSUM=""
        # 1. Sidecar from bundle build (seed/ or releases/) or one downloaded
        #    alongside the APK from the mirror (lands next to the APK in storage).
        for s in "$SCRIPT_DIR/seed/localdroid-agent.apk.cert-sha256" \
                 "$SCRIPT_DIR/releases/localdroid-agent.apk.cert-sha256" \
                 "$AGENT_STORAGE/localdroid-agent.apk.cert-sha256"; do
            if [ -s "$s" ]; then
                APK_CHECKSUM=$(tr -d '[:space:]' < "$s")
                echo "APK checksum loaded from sidecar: $(basename "$s")"
                break
            fi
        done
        # 2. Recompute from the seeded APK. python3 (Ubuntu base) is used for
        # hex → base64-urlsafe so we don't depend on xxd being present.
        if [ -z "$APK_CHECKSUM" ] && command -v apksigner &>/dev/null && command -v python3 &>/dev/null; then
            APK_CERT_HEX=$(apksigner verify --print-certs "$AGENT_STORAGE/localdroid-agent.apk" 2>/dev/null \
                | grep "SHA-256 digest" | head -n1 | awk -F: '{print $NF}' | tr -d ' \t\r\n')
            if [ -n "$APK_CERT_HEX" ]; then
                APK_CHECKSUM=$(python3 -c "import base64, sys; print(base64.urlsafe_b64encode(bytes.fromhex(sys.argv[1])).decode().rstrip('='))" "$APK_CERT_HEX" 2>/dev/null)
                [ -n "$APK_CHECKSUM" ] && echo "APK checksum computed via apksigner"
            fi
        fi
        # 3. Apply or warn
        if [ -n "$APK_CHECKSUM" ]; then
            CURRENT_CHECKSUM=$(grep "^APK_SIGNATURE_CHECKSUM=" "$ENV_FILE" | cut -d= -f2-)
            if [ "$CURRENT_CHECKSUM" != "$APK_CHECKSUM" ]; then
                sed -i "s|^APK_SIGNATURE_CHECKSUM=.*|APK_SIGNATURE_CHECKSUM=$APK_CHECKSUM|" "$ENV_FILE"
                echo -e "${GREEN}APK signature checksum set: $APK_CHECKSUM${NC}"
            else
                echo -e "${GREEN}APK signature checksum already correct${NC}"
            fi
        else
            echo -e "${YELLOW}WARNING: could not determine APK signing-cert checksum.${NC}"
            echo -e "${YELLOW}  Zero-Touch enrollment will fail until APK_SIGNATURE_CHECKSUM is set in:${NC}"
            echo -e "${YELLOW}    $ENV_FILE${NC}"
            echo -e "${YELLOW}  Install 'apksigner' (sudo apt install apksigner) and re-run, or${NC}"
            echo -e "${YELLOW}  drop seed/localdroid-agent.apk.cert-sha256 from the bundle.${NC}"
        fi
    fi

    # Always mark the step done even if a binary is missing — the operator
    # can drop it in later and the diagnostics page will guide them. We don't
    # want a missing EXE to block a Linux MDM install (and vice versa).
    if [ $APK_OK -eq 0 ] && [ $EXE_OK -eq 0 ]; then
        echo -e "${GREEN}Both agent binaries installed.${NC}"
    else
        echo -e "${YELLOW}One or more agents missing — diagnostics page will flag them.${NC}"
    fi
    mark_done "agents_seed"
fi

# ---------------------------------------------------------------------------
# STEP 9b: Baked-in customer license (optional)
# ---------------------------------------------------------------------------
# If the bundle shipped a license.lic (scripts/build-native-bundle.sh with
# LICENSE_FILE set), install it next to the server and point
# LOCALDROID_LICENSE_FILE at it. The server reads that env var on first boot
# and auto-activates the license — the customer never pastes anything. The
# signature is verified against LICENSE_PUBLIC_KEY (set by STEP 2b), so the
# box needs to have reached the license server once, or have the key baked in.
if step_done "license_seed"; then
    echo -e "${GREEN}[SKIP] License already installed${NC}"
elif [ -f "$SCRIPT_DIR/license.lic" ]; then
    echo ""
    echo "=== Installing bundled customer license ==="
    LICENSE_DEST="$SCRIPT_DIR/server/license.lic"
    cp "$SCRIPT_DIR/license.lic" "$LICENSE_DEST"
    if grep -q "^LOCALDROID_LICENSE_FILE=" "$ENV_FILE"; then
        sed -i "s|^LOCALDROID_LICENSE_FILE=.*|LOCALDROID_LICENSE_FILE=$LICENSE_DEST|" "$ENV_FILE"
    else
        printf '\n# Signed license auto-activated on first boot (see server main.go).\nLOCALDROID_LICENSE_FILE=%s\n' "$LICENSE_DEST" >> "$ENV_FILE"
    fi
    echo -e "${GREEN}License staged at $LICENSE_DEST — MDM will auto-activate on first start.${NC}"
    if ! grep -q "^LICENSE_PUBLIC_KEY=.\+" "$ENV_FILE"; then
        echo -e "${YELLOW}  Note: LICENSE_PUBLIC_KEY is empty. The license can't be verified until${NC}"
        echo -e "${YELLOW}  the server fetches the key from $LICENSE_SERVER_URL (needs internet once).${NC}"
    fi
    mark_done "license_seed"
else
    mark_done "license_seed"
fi

# ---------------------------------------------------------------------------
# STEP 10: Build Web UI
# ---------------------------------------------------------------------------
if step_done "web_build"; then
    echo -e "${GREEN}[SKIP] Web UI already built${NC}"
elif [ -f "$SCRIPT_DIR/server/web/dist/index.html" ] || [ -f "$SCRIPT_DIR/web/dist/index.html" ]; then
    # Prebuilt bundle path: customer ran a release tarball that already has
    # the minified web assets. No npm needed on the target host.
    echo -e "${GREEN}[SKIP] Web UI dist/ already present (prebuilt bundle)${NC}"
    # Make sure server/web/dist exists where the Go binary expects to find it.
    if [ ! -f "$SCRIPT_DIR/server/web/dist/index.html" ] && [ -f "$SCRIPT_DIR/web/dist/index.html" ]; then
        mkdir -p "$SCRIPT_DIR/server/web"
        cp -r "$SCRIPT_DIR/web/dist" "$SCRIPT_DIR/server/web/"
    fi
    mark_done "web_build"
else
    echo ""
    echo "=== Building Web UI ==="
    WEB_DIR="$SCRIPT_DIR/web"
    if [ ! -d "$WEB_DIR" ]; then
        echo -e "${YELLOW}Web directory not found at $WEB_DIR - skipping${NC}"
        mark_done "web_build"
    else
        cd "$WEB_DIR"
        echo "Installing npm dependencies..."
        if ! npm install 2>&1; then
            echo -e "${YELLOW}npm install failed, trying clean install...${NC}"
            rm -rf node_modules package-lock.json
            npm install 2>&1 || { echo -e "${RED}npm install failed${NC}"; exit 1; }
        fi
        echo "Building production bundle..."
        npm run build 2>&1 || { echo -e "${RED}npm run build failed${NC}"; exit 1; }
        cd "$SCRIPT_DIR"

        # Copy dist to server/web/dist
        DIST_SRC="$WEB_DIR/dist"
        DIST_DST="$SCRIPT_DIR/server/web"
        mkdir -p "$DIST_DST"
        cp -r "$DIST_SRC" "$DIST_DST/"
        echo -e "${GREEN}Web UI built and copied to server/web/dist${NC}"
        mark_done "web_build"
    fi
fi

# ---------------------------------------------------------------------------
# STEP 11: Build Go Server
# ---------------------------------------------------------------------------
if step_done "server_build"; then
    echo -e "${GREEN}[SKIP] Go server already built${NC}"
elif [ -x "$SCRIPT_DIR/server/localdroid-server" ]; then
    # Prebuilt bundle path: tarball already shipped the compiled binary, no
    # Go toolchain needed on the target host.
    echo -e "${GREEN}[SKIP] Prebuilt server binary present at server/localdroid-server${NC}"
    mark_done "server_build"
else
    echo ""
    echo "=== Building Go Server ==="
    SERVER_DIR="$SCRIPT_DIR/server"
    if [ ! -d "$SERVER_DIR" ]; then
        echo -e "${YELLOW}Server directory not found at $SERVER_DIR - skipping${NC}"
        mark_done "server_build"
    else
        cd "$SERVER_DIR"
        echo "Downloading Go module dependencies..."
        go mod download 2>&1 || true
        echo "Compiling server..."
        go build -o localdroid-server ./cmd/server 2>&1 || { echo -e "${RED}go build failed${NC}"; exit 1; }
        cd "$SCRIPT_DIR"
        echo -e "${GREEN}Server built: server/localdroid-server${NC}"
        mark_done "server_build"
    fi
fi

# ---------------------------------------------------------------------------
# STEP 12: Systemd Service
# ---------------------------------------------------------------------------
# Not skipped on a re-run: re-writing the unit is idempotent, and a re-run must
# be able to correct a stale one (like the Windows installer's scheduled task).
#
# The unit below is the exact text the server itself installs when it repairs
# auto-start (linuxUnit in server/internal/upgrade/service.go). Keep the two
# identical, or Settings -> System reports the service as needing repair.
# ExecStartPre runs the supervisor hook the server writes at boot; the leading
# "-" lets the very first start succeed before that file exists.
echo ""
echo "=== Systemd Service Setup ==="
read -rp "Install the systemd service so the server starts at boot? (y/n) [y]: " CREATE_SERVICE
CREATE_SERVICE=${CREATE_SERVICE:-y}

if [ "$CREATE_SERVICE" = "y" ]; then
    SERVICE_USER=$(whoami)
    SERVICE_NAME="localdroid-backend"
    SERVICE_FILE="/tmp/$SERVICE_NAME.service"
    SERVER_DIR="$SCRIPT_DIR/server"

    {
        printf '[Unit]\nDescription=LocalDroid MDM Backend\nAfter=network.target postgresql.service mosquitto.service\n\n'
        printf '[Service]\nType=simple\nUser=%s\nWorkingDirectory=%s\nEnvironmentFile=%s/.env\n' \
            "$SERVICE_USER" "$SERVER_DIR" "$SERVER_DIR"
        if [ "$SERVER_PORT" -lt 1024 ] 2>/dev/null; then
            printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\n'
        fi
        printf 'ExecStartPre=-/bin/sh %s/localdroid-supervisor.sh\nExecStart=%s/localdroid-server\n' \
            "$SERVER_DIR" "$SERVER_DIR"
        printf 'Restart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n'
    } > "$SERVICE_FILE"

    if sudo install -m 0644 "$SERVICE_FILE" "/etc/systemd/system/$SERVICE_NAME.service" \
        && sudo systemctl daemon-reload \
        && sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
        # restart, not start: a re-run after rebuilding the server must load the new binary.
        if sudo systemctl restart "$SERVICE_NAME"; then
            echo -e "${GREEN}Service '$SERVICE_NAME' installed, enabled at boot, and started.${NC}"
        else
            echo -e "${YELLOW}Service installed but did not start. See: sudo journalctl -u $SERVICE_NAME -n 50${NC}"
        fi
        rm -f "$SERVICE_FILE"
    else
        echo -e "${YELLOW}Could not install the service automatically. Run:${NC}"
        echo -e "${YELLOW}  sudo install -m 0644 $SERVICE_FILE /etc/systemd/system/$SERVICE_NAME.service${NC}"
        echo -e "${YELLOW}  sudo systemctl daemon-reload${NC}"
        echo -e "${YELLOW}  sudo systemctl enable --now $SERVICE_NAME${NC}"
    fi
fi
mark_done "systemd"

# ---------------------------------------------------------------------------
# STEP 13: TLS reachability check  (cloud mode only)
# ---------------------------------------------------------------------------
# Confirms that EXTERNAL_URL is reachable over HTTPS before declaring success.
# Zero-Touch enrollment will silently fail if TLS is not working end-to-end,
# so we catch it here rather than letting the operator discover it later.
if [ "$DEPLOYMENT_MODE" = "cloud" ]; then
    echo ""
    echo "=== Verifying HTTPS reachability ==="
    # Give the server a moment to come up if it was just started
    TLS_CHECK_URL="${EXTERNAL_URL%/}/api/health"
    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 \
        --connect-timeout 5 "$TLS_CHECK_URL" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "000" ]; then
        echo -e "${YELLOW}WARNING: Could not reach $TLS_CHECK_URL${NC}"
        echo -e "${YELLOW}  TLS/HTTPS is not confirmed working. Zero-Touch enrollment will fail${NC}"
        echo -e "${YELLOW}  until the server is running and HTTPS is reachable at $EXTERNAL_URL.${NC}"
        echo -e "${YELLOW}  Common causes:${NC}"
        echo -e "${YELLOW}    - nginx not running  : sudo systemctl status nginx${NC}"
        echo -e "${YELLOW}    - server not started : cd server && ./localdroid-server${NC}"
        echo -e "${YELLOW}    - firewall blocking 443: check cloud provider security group rules${NC}"
        echo -e "${YELLOW}    - DNS not propagated : nslookup $(echo "$EXTERNAL_URL" | sed -E 's#^https?://##; s#/.*$##')${NC}"
    elif [[ "$HTTP_CODE" =~ ^[2345] ]]; then
        echo -e "${GREEN}HTTPS reachable at $EXTERNAL_URL (HTTP $HTTP_CODE) — Zero-Touch enrollment ready.${NC}"
    else
        echo -e "${YELLOW}HTTPS check returned unexpected code $HTTP_CODE — verify TLS is working before enrolling devices.${NC}"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Installation Complete"
echo "=========================================="
echo ""
if [ "$DEPLOYMENT_MODE" = "cloud" ]; then
    echo -e "Web UI / API : ${GREEN}$EXTERNAL_URL${NC}"
else
    echo -e "Web UI / API : ${GREEN}http://$SERVER_PUBLIC_IP:$SERVER_PORT${NC}"
fi
echo -e "MQTT broker  : ${GREEN}$MQTT_HOST:$MQTT_PORT${NC} (local)"
echo -e "Database     : ${GREEN}$DB_HOST:$DB_PORT/$DB_NAME${NC}"
echo ""
echo "Sign in with:"
echo -e "  Email       : ${CYAN}$LOCALDROID_ADMIN_EMAIL${NC}"
echo -e "  Password    : ${CYAN}<the password you entered above>${NC}"
echo ""
echo "Android device enrollment settings:"
echo -e "  Server URL  : ${CYAN}$EXTERNAL_URL${NC}"
echo -e "  MQTT host   : ${CYAN}$MQTT_EXTERNAL_HOST${NC}"
echo -e "  MQTT port   : ${CYAN}$MQTT_EXTERNAL_PORT${NC}"
echo ""
if [ "$DEPLOYMENT_MODE" = "cloud" ]; then
    echo "Remote control:"
    echo -e "  Windows VNC : ${GREEN}relayed over HTTPS — no extra ports${NC}"
    if systemctl is-active --quiet coturn 2>/dev/null; then
        echo -e "  Android     : ${GREEN}TURN relay (coturn) active on :3478${NC}"
        echo -e "                ${CYAN}open 3478/tcp+udp and 49152-49200/udp on your provider firewall${NC}"
    else
        echo -e "  Android     : ${YELLOW}no TURN relay — works on LAN only until coturn is running${NC}"
    fi
    echo ""
fi
echo "Server service (starts at boot, restarts if it stops):"
echo "  sudo systemctl status localdroid-backend"
echo "  sudo journalctl -u localdroid-backend -f     # live log"
echo ""
echo "Upgrades: Settings -> System -> Updates in the dashboard."
echo ""
echo -e "${CYAN}Progress saved to : $STATE_FILE${NC}"
echo -e "${CYAN}To start fresh    : rm $STATE_FILE && ./install.sh${NC}"
echo ""
