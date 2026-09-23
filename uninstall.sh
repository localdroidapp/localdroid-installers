#!/usr/bin/env bash
# Remove LocalDroid MDM from a Linux server (Ubuntu/Debian, including Raspberry Pi).
#
#   ./uninstall.sh                          remove the server, keep the database
#   ./uninstall.sh --purge                  also delete the database, the database
#                                           user, and the Mosquitto/nginx/coturn
#                                           configuration LocalDroid wrote
#   ./uninstall.sh --purge --remove-deps    also apt-purge postgresql, mosquitto,
#                                           coturn and nginx: back to a clean machine
#
# Options: --install-dir DIR (default: the folder this script is in, else the
# service's WorkingDirectory), --no-backup, --yes.
#
# A final backup (database dump, .env, license) goes to
# ~/localdroid-final-backup-<time> first, unless --no-backup.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "\n${CYAN}==> $*${NC}"; }
ok()   { echo -e "    ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "    ${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "\n${RED}[FAILED]${NC} $*"; exit 1; }

PURGE=0; REMOVE_DEPS=0; NO_BACKUP=0; YES=0; INSTALL_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --purge) PURGE=1 ;;
        --remove-deps) REMOVE_DEPS=1 ;;
        --no-backup) NO_BACKUP=1 ;;
        --yes|-y) YES=1 ;;
        --install-dir) INSTALL_DIR="$2"; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done
[ "$REMOVE_DEPS" = 1 ] && [ "$PURGE" = 0 ] && die "--remove-deps also removes the database server, so it requires --purge"

SERVICE=localdroid-backend
UNIT=/etc/systemd/system/$SERVICE.service

if [ -z "$INSTALL_DIR" ]; then
    here=$(cd "$(dirname "$0")" && pwd)
    if [ -d "$here/server" ]; then
        INSTALL_DIR=$here
    elif [ -f "$UNIT" ]; then
        wd=$(sed -n 's/^WorkingDirectory=//p' "$UNIT" | head -1)
        [ -n "$wd" ] && INSTALL_DIR=$(dirname "$wd")
    fi
fi
[ -n "$INSTALL_DIR" ] || die "cannot find the install folder; pass --install-dir"
SERVER_DIR="$INSTALL_DIR/server"
ENV_FILE="$SERVER_DIR/.env"

envval() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | head -1 | tr -d '"' || true; }
DB_HOST=$(envval DB_HOST); DB_HOST=${DB_HOST:-localhost}
DB_PORT=$(envval DB_PORT); DB_PORT=${DB_PORT:-5432}
DB_USER=$(envval DB_USER); DB_USER=${DB_USER:-localdroid}
DB_NAME=$(envval DB_NAME); DB_NAME=${DB_NAME:-localdroid}
DB_PASSWORD=$(envval DB_PASSWORD)

echo ""
echo "LocalDroid uninstall"
echo "  Install folder : $INSTALL_DIR"
echo "  Will remove    : the $SERVICE service and the install folder"
if [ "$PURGE" = 1 ]; then
    echo -e "                   ${YELLOW}the '$DB_NAME' database, the '$DB_USER' database user,${NC}"
    echo -e "                   ${YELLOW}and LocalDroid's Mosquitto, nginx and coturn configuration${NC}"
else
    echo "  Will keep      : the '$DB_NAME' database (use --purge to delete it)"
fi
[ "$REMOVE_DEPS" = 1 ] && echo -e "                   ${YELLOW}the postgresql, mosquitto, coturn and nginx packages (ALL their data)${NC}"
[ "$NO_BACKUP" = 1 ] && echo -e "  Final backup   : ${YELLOW}none (--no-backup)${NC}" || echo "  Final backup   : ~/localdroid-final-backup-<time>"
echo ""
if [ "$YES" != 1 ]; then
    read -rp "Type UNINSTALL to continue: " answer
    [ "$answer" = "UNINSTALL" ] || { echo "Cancelled."; exit 0; }
fi

# "sudo true", not "sudo -v": -v asks for a password whenever any sudoers rule
# for the user does, even when a NOPASSWD rule would let the commands run.
sudo true || die "this needs sudo"

# ---------------------------------------------------------------- backup
if [ "$NO_BACKUP" != 1 ]; then
    step "Final backup"
    BDIR="$HOME/localdroid-final-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BDIR" && chmod 700 "$BDIR"
    for f in .env license.lic install-manifest.json; do
        [ -f "$SERVER_DIR/$f" ] && cp "$SERVER_DIR/$f" "$BDIR/"
    done
    if command -v pg_dump >/dev/null && PGPASSWORD="$DB_PASSWORD" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
            -Fc -f "$BDIR/localdroid-db.dump" "$DB_NAME" 2>/dev/null; then
        ok "Database dumped to $BDIR/localdroid-db.dump"
    else
        warn "Could not dump the database (it may not exist)."
        if [ "$PURGE" = 1 ] && [ "$YES" != 1 ]; then
            read -rp "Continue and delete the database without a backup? (y/N): " a
            [ "$a" = "y" ] || exit 1
        fi
    fi
    ok "Backup folder: $BDIR"
fi

# ---------------------------------------------------------------- service
step "Stopping and removing the service"
for u in "$SERVICE.service" localdroid-mqtt-reload.path localdroid-mqtt-reload.service; do
    sudo systemctl disable --now "$u" >/dev/null 2>&1 || true
    sudo rm -f "/etc/systemd/system/$u"
done
sudo systemctl daemon-reload
pkill -f "$SERVER_DIR/localdroid-server" 2>/dev/null || true
ok "Service removed"

# ---------------------------------------------------------------- purge
if [ "$PURGE" = 1 ]; then
    step "Deleting the '$DB_NAME' database and '$DB_USER' user"
    if command -v psql >/dev/null; then
        sudo -u postgres psql -X -q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null 2>&1
        sudo -u postgres psql -X -q -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" && ok "Database deleted" || warn "Could not delete the database"
        [ "$DB_USER" != "postgres" ] && sudo -u postgres psql -X -q -c "DROP ROLE IF EXISTS \"$DB_USER\";" >/dev/null 2>&1 && ok "User deleted"
    else
        warn "psql not found; the database was not deleted"
    fi

    step "Removing LocalDroid's Mosquitto, nginx and coturn configuration"
    sudo rm -f /etc/mosquitto/conf.d/localdroid.conf
    sudo rm -rf /etc/mosquitto/localdroid-auth
    sudo rm -f /etc/letsencrypt/renewal-hooks/deploy/localdroid-mosquitto.sh \
               /etc/letsencrypt/renewal-hooks/deploy/localdroid-nginx.sh
    systemctl is-active --quiet mosquitto 2>/dev/null && sudo systemctl restart mosquitto
    if [ -e /etc/nginx/sites-enabled/localdroid ] || [ -e /etc/nginx/sites-available/localdroid ]; then
        sudo rm -f /etc/nginx/sites-enabled/localdroid /etc/nginx/sites-available/localdroid
        sudo nginx -t >/dev/null 2>&1 && sudo systemctl reload nginx 2>/dev/null
        ok "nginx site removed"
    fi
    if [ -f /etc/turnserver.conf ] && grep -q "LocalDroid\|localdroid" /etc/turnserver.conf 2>/dev/null; then
        sudo mv /etc/turnserver.conf /etc/turnserver.conf.localdroid-uninstalled
        ok "coturn config moved aside"
    fi
    if command -v ufw >/dev/null; then
        for r in 3478/tcp 3478/udp 49152:49200/udp; do sudo ufw delete allow "$r" >/dev/null 2>&1 || true; done
    fi
    ok "Configuration removed"
fi

# ---------------------------------------------------------------- files
step "Deleting $INSTALL_DIR"
# The script may live inside the folder it deletes; bash has it in memory.
sudo rm -rf "$INSTALL_DIR" && ok "Deleted" || warn "Could not delete $INSTALL_DIR"

# ---------------------------------------------------------------- packages
if [ "$REMOVE_DEPS" = 1 ]; then
    step "Purging postgresql, mosquitto, coturn and nginx"
    sudo systemctl stop postgresql mosquitto coturn nginx 2>/dev/null || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y 'postgresql*' mosquitto mosquitto-clients coturn nginx nginx-common >/dev/null 2>&1 \
        && ok "Packages purged" || warn "apt-get purge reported a problem"
    sudo apt-get autoremove -y >/dev/null 2>&1 || true
    # Purge leaves data directories behind; a fresh install must not find them.
    sudo rm -rf /var/lib/postgresql /etc/postgresql /etc/mosquitto /var/lib/mosquitto
    ok "Data directories removed"
fi

echo ""
echo -e "${GREEN}LocalDroid has been removed.${NC}"
[ "$PURGE" = 0 ] && echo "  The '$DB_NAME' database was kept. Run again with --purge to delete it."
