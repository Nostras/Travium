#!/usr/bin/env bash
# Travium one-shot installer for Ubuntu 24.04 + CloudPanel v2 + MariaDB 11.4
#set -Eeuo pipefail

#####################################
# helpers
#####################################
log(){ printf "\033[1;34m[*]\033[0m %s\n" "$*"; }
ok(){  printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

require_root(){ [[ ${EUID:-0} -eq 0 ]] || die "Run as root."; }

# randoms
rand_pw(){ tr -dc 'A-Za-z0-9!@#%+=' </dev/urandom | head -c "${1:-24}"; }
rand_hex(){ tr -dc 'A-Fa-f0-9' </dev/urandom | head -c "${1:-32}"; }

#####################################
# parse args
#####################################
DOMAIN=""
SITE_USER=""
RECAPTCHA_PUBLIC=""
RECAPTCHA_PRIVATE=""
DEFAULT_SITE_USER="travium"
DEFAULT_RECAPTCHA_PUBLIC="6LdQ8AIsAAAAAM0SKRYd_JiGqVqxZPTYflrdPOvH"
DEFAULT_RECAPTCHA_PRIVATE="6LdQ8AIsAAAAANlEknjUf9LWLODJrpoDiHXTvPAV"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2;;
    --user) SITE_USER="${2:-}"; shift 2;;
    --recaptchaPublic) RECAPTCHA_PUBLIC="${2:-}"; shift 2;;
    --recaptchaPrivate) RECAPTCHA_PRIVATE="${2:-}"; shift 2;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -n "$DOMAIN" ]] || die "Missing --domain arg."

SITE_USER="${SITE_USER:-$DEFAULT_SITE_USER}"

#####################################
# sanity checks
#####################################
require_root

[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
. /etc/os-release
case "${ID,,}" in
  ubuntu)
    case "${VERSION_ID}" in
      24.04|22.04) : ;;
      *) die "Unsupported Ubuntu ${VERSION_ID}. Supported: 22.04, 24.04";;
    esac
    ;;
  debian)
    case "${VERSION_ID}" in
      13|12|11) : ;;
      *) die "Unsupported Debian ${VERSION_ID}. Supported: 11, 12, 13";;
    esac
    ;;
  *)
    die "Unsupported OS: ${PRETTY_NAME:-unknown}"
    ;;
esac

pick_db_engine() {
  case "${ID,,}:${VERSION_ID}" in
    debian:13)
      echo "MARIADB_11.8"   # Debian 13 requires 11.8 with CloudPanel
      ;;
    ubuntu:24.04|ubuntu:22.04|debian:12|debian:11)
      echo "MARIADB_11.4"
      ;;
    *)
      die "No DB engine mapping for ${ID} ${VERSION_ID}"
      ;;
  esac
}

tpl_platform() {
  local id="${ID,,}"
  local ver="${VERSION_ID}"
  echo "${id}-${ver}"
}

export DEBIAN_FRONTEND=noninteractive
export UCF_FORCE_CONFNEW=1

#####################################
# base packages
#####################################
log "Updating packages and installing prerequisites..."
apt-get -yq update
apt-get -yq -o Dpkg::Options::="--force-confold" dist-upgrade
apt-get -yq install curl wget sudo ca-certificates git lsb-release jq

#####################################
# install CloudPanel CE v2 (MariaDB 11.4)
#####################################
log "Installing CloudPanel CE v2 with MariaDB 11.4 (non-interactive)..."
curl -sS https://installer.cloudpanel.io/ce/v2/install.sh -o /root/clp-install.sh
chmod +x /root/clp-install.sh

DB_ENGINE="$(pick_db_engine)" bash /root/clp-install.sh

# clpctl usually ends up in /usr/sbin
PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

#####################################
# wait for CloudPanel to be up
#####################################
log "Waiting for CloudPanel to answer on https://127.0.0.1:8443/login ..."
for i in {1..60}; do
  if curl -skI --http1.1 https://127.0.0.1:8443/login | grep -qiE 'HTTP/1\.1 (200|302)'; then
    ok "CloudPanel web is up."
    break
  fi
  sleep 2
  [[ $i -eq 60 ]] && die "CloudPanel did not start in time."
done

#####################################
# create CloudPanel admin user
#####################################
log "Creating CloudPanel admin user..."
BASE_URL="https://127.0.0.1:8443"
FORM_URL="$BASE_URL/admin/user/creation"

ADMIN_FIRST="Travium"
ADMIN_LAST="Admin"
ADMIN_EMAIL="admin@travium.net"
ADMIN_USER="traviumadmin"
ADMIN_PASS="$(rand_pw 16)"

cookie_jar="$(mktemp)"
resp_html="$(mktemp)"
resp_headers="$(mktemp)"
cleanup_admin(){ rm -f "$cookie_jar" "$resp_html" "$resp_headers"; }
trap cleanup_admin EXIT

curl_common=(-k -sS --http1.1 -A "curl/CloudPanel-setup" -H "Accept-Language: en" -H "Connection: keep-alive")

curl "${curl_common[@]}" -c "$cookie_jar" -L "$FORM_URL" -o "$resp_html"
TOKEN="$(grep -Po 'name="user_admin_user_creation\[_token\]"\s+value="([^"]+)"' "$resp_html" | sed -E 's/.*value="([^"]+)".*/\1/' || true)"
[[ -n "${TOKEN:-}" ]] || die "Failed to extract CSRF token for admin creation."

TZ_ID="$(grep -Po '<option value="\K[0-9]+(?=">Europe/London</option>)' "$resp_html" || true)"
[[ -n "${TZ_ID:-}" ]] || TZ_ID="337"

HTTP_CODE="$(
  curl "${curl_common[@]}" -b "$cookie_jar" -c "$cookie_jar" \
    -D "$resp_headers" -o /dev/null -w "%{http_code}" \
    -L -X POST "$FORM_URL" \
    --data-urlencode "user_admin_user_creation[firstName]=$ADMIN_FIRST" \
    --data-urlencode "user_admin_user_creation[lastName]=$ADMIN_LAST" \
    --data-urlencode "user_admin_user_creation[userName]=$ADMIN_USER" \
    --data-urlencode "user_admin_user_creation[email]=$ADMIN_EMAIL" \
    --data-urlencode "user_admin_user_creation[plainPassword]=$ADMIN_PASS" \
    --data-urlencode "user_admin_user_creation[timezone]=$TZ_ID" \
    --data-urlencode "user_admin_user_creation[acceptLicenseTermsPrivacyPolicy]=1" \
    --data-urlencode "user_admin_user_creation[submit]=Create User" \
    --data-urlencode "user_admin_user_creation[_token]=$TOKEN"
)"
[[ "$HTTP_CODE" =~ ^2|3 ]] || die "Admin creation failed. HTTP $HTTP_CODE"

ok "CloudPanel admin created."

#####################################
# CloudPanel site + DB
#####################################
log "Creating vhost template + site + database..."
SITE_PASS="$(rand_pw 20)"
DB_PASS="$(rand_pw 24)"
TPL_DISTRO="$(tpl_platform)"

clpctl vhost-template:add --name='Travium' --file="https://init.travium.net/gettpl.php?domain=${DOMAIN}&user=${SITE_USER}&distro=${TPL_DISTRO}"
clpctl site:add:php --domainName="${DOMAIN}" --phpVersion=7.3 --vhostTemplate='Travium' --siteUser="${SITE_USER}" --siteUserPassword="${SITE_PASS}"
clpctl db:add --domainName="${DOMAIN}" --databaseName=maindb --databaseUserName=maindb --databaseUserPassword="${DB_PASS}"

#####################################
# Repo checkout
#####################################
log "Cloning Travium repo..."
HTDOCS="/home/${SITE_USER}/htdocs"
install -d -o "${SITE_USER}" -g "${SITE_USER}" "/home/${SITE_USER}"
rm -rf "$HTDOCS" || true
su - "${SITE_USER}" -c "git clone https://github.com/Travium/Travium ${HTDOCS}"

log "Running composer install as ${SITE_USER}..."
if [[ -f "${HTDOCS}/composer.json" ]]; then
  su - "${SITE_USER}" -s /bin/bash -c "
    set -e
    export COMPOSER_MEMORY_LIMIT=-1
    export COMPOSER_HOME=\"/home/${SITE_USER}/.composer\"
    cd \"${HTDOCS}\"
    /usr/bin/php7.3 /usr/local/bin/composer install \
      --no-interaction --prefer-dist --optimize-autoloader
  "
  ok "Composer install finished."
else
  log "No composer.json found in ${HTDOCS}; skipping composer install."
fi

# ensure ownership
chown -R "${SITE_USER}:${SITE_USER}" "${HTDOCS}"

#####################################
# Import DB
#####################################
log "Importing database maindb..."
[[ -f "${HTDOCS}/maindb.sql" ]] || die "Missing ${HTDOCS}/maindb.sql"
mysql -u maindb -p"${DB_PASS}" maindb < "${HTDOCS}/maindb.sql"

#####################################
# Patch config & frontend keys
#####################################
log "Patching config and frontend keys..."
INSTALLER_SECRET="$(rand_hex 32)"
VOTING_SECRET="$(rand_hex 16)"
RECAPTCHA_PUBLIC_EFFECTIVE="${RECAPTCHA_PUBLIC:-$DEFAULT_RECAPTCHA_PUBLIC}"
RECAPTCHA_PRIVATE_EFFECTIVE="${RECAPTCHA_PRIVATE:-$DEFAULT_RECAPTCHA_PRIVATE}"

SAMPLE_CONFIG_FILE="${HTDOCS}/config.sample.php"
CONFIG_FILE="${HTDOCS}/config.php"
cp ${SAMPLE_CONFIG_FILE} ${CONFIG_FILE}
chown "${SITE_USER}:${SITE_USER}" "${CONFIG_FILE}"

[[ -f "$CONFIG_FILE" ]] || die "Expected ${CONFIG_FILE} to exist."

sed -i \
  -e "s/INIT_RECAPTCHA_PUBLIC_KEY/${RECAPTCHA_PUBLIC_EFFECTIVE//\//\\/}/g" \
  -e "s/INIT_RECAPTCHA_PRIVATE_KEY/${RECAPTCHA_PRIVATE_EFFECTIVE//\//\\/}/g" \
  -e "s/INIT_DOMAIN/${DOMAIN//\//\\/}/g" \
  -e "s/INIT_MAIN_DB_PASSWORD/${DB_PASS//\//\\/}/g" \
  -e "s/INIT_INSTALLER_SECRET_KEY/${INSTALLER_SECRET//\//\\/}/g" \
  -e "s/INIT_SECRET_TOKEN/${VOTING_SECRET//\//\\/}/g" \
  "$CONFIG_FILE"

# Some builds obfuscate the bundle name. Hit every homepage JS under /homepage/
find "${HTDOCS}/homepage" -type f -name "*.js" -print0 2>/dev/null \
  | xargs -0 -I {} sed -i "s/INIT_RECAPTCHA_PUBLIC_KEY/${RECAPTCHA_PUBLIC_EFFECTIVE//\//\\/}/g" {} || true

#####################################
# systemd units + travium-sync
# IMPORTANT NOTE honored: we keep file names and the TRAVIUM_UNDER_SYSTEMD variable.
#####################################
log "Installing systemd units..."
install -d /etc/systemd/system/travium.target.wants/

cat >/etc/systemd/system/travium@.service <<UNIT
[Unit]
Description=Travium engine for %i
After=network.target mysqld.service

[Service]
User=${SITE_USER}
WorkingDirectory=/home/${SITE_USER}/htdocs
ExecStart=/usr/bin/env TRAVIUM_UNDER_SYSTEMD=1 /usr/bin/php7.3 /home/${SITE_USER}/htdocs/servers/%i/include/engine.php
Type=simple
Restart=on-failure
RestartSec=2
KillMode=control-group
StandardOutput=journal
StandardError=journal
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/travium.target <<UNIT
[Unit]
Description=Travium all engines

[Install]
WantedBy=multi-user.target
UNIT

install -m 0755 -o root -g root /dev/stdin /usr/local/bin/travium-sync <<'SCRIPT'
#!/usr/bin/env bash
systemctl daemon-reload
set -euo pipefail
HTDOCS="/home/REPLACE_USER/htdocs"
SERVERS_DIR="$HTDOCS/servers"
TARGET_WANTS_DIR="/etc/systemd/system/travium.target.wants"
mkdir -p "$TARGET_WANTS_DIR"
mapfile -t desired < <(find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
mapfile -t current < <(find "$TARGET_WANTS_DIR" -maxdepth 1 -type l -name 'travium@*.service' -printf '%f\n' | sed -E 's/^travium@(.+)\.service$/\1/' | sort)
for w in "${desired[@]}"; do
  if [[ -f "$SERVERS_DIR/$w/include/engine.php" ]]; then
    if ! systemctl is-enabled --quiet "travium@${w}.service"; then
      echo "Enabling travium@${w}.service"
      systemctl enable --now "travium@${w}.service"
      ln -sf "/etc/systemd/system/travium@.service" "$TARGET_WANTS_DIR/travium@${w}.service"
    fi
  fi
done
for w in "${current[@]}"; do
  if [[ ! -d "$SERVERS_DIR/$w" ]]; then
    echo "Disabling travium@${w}.service"
    systemctl disable --now "travium@${w}.service" || true
    rm -f "$TARGET_WANTS_DIR/travium@${w}.service"
  fi
done
systemctl daemon-reload
SCRIPT

# inject real user path into travium-sync
sed -i "s|/home/REPLACE_USER/htdocs|/home/${SITE_USER}/htdocs|g" /usr/local/bin/travium-sync

cat >/etc/systemd/system/travium-sync.service <<UNIT
[Unit]
Description=Sync Travium instances with /servers
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/travium-sync
UNIT

cat >/etc/systemd/system/travium-sync.path <<UNIT
[Unit]
Description=Watch /home/${SITE_USER}/htdocs/servers for changes

[Path]
PathModified=/home/${SITE_USER}/htdocs/servers
PathChanged=/home/${SITE_USER}/htdocs/servers

[Install]
WantedBy=multi-user.target
UNIT

chmod +x /usr/local/bin/travium-sync
systemctl daemon-reload
systemctl start travium-sync.service
systemctl enable --now travium-sync.path
systemctl enable travium.target || true

#####################################
# summary
#####################################
PUBLIC_IP="$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')"
LOGIN_URL="https://${PUBLIC_IP}:8443/login"
INSTALL_URL="https://install.${DOMAIN}/?key=${INSTALLER_SECRET}"

ok "All done."

cat <<OUT

===== CloudPanel =====
URL:        ${LOGIN_URL}
Admin user: ${ADMIN_USER}
Password:   ${ADMIN_PASS}

===== Installer =====
Install URL: ${INSTALL_URL}

Systemd target: travium.target
Sync watcher:   travium-sync.path

OUT

# persist details for later
SETUP_CONF="/home/${SITE_USER}/setup.conf"
cat >"$SETUP_CONF" <<CONF
CLOUDPANEL_URL=${LOGIN_URL}
CLOUDPANEL_ADMIN_USER=${ADMIN_USER}
CLOUDPANEL_ADMIN_PASS=${ADMIN_PASS}
DOMAIN=${DOMAIN}
SITE_USER=${SITE_USER}
SITE_PASS=${SITE_PASS}
DB_NAME=maindb
DB_USER=maindb
DB_PASS=${DB_PASS}
INSTALLER_SECRET=${INSTALLER_SECRET}
INSTALL_URL=${INSTALL_URL}
CONF
chown "${SITE_USER}:${SITE_USER}" "$SETUP_CONF"
chmod 600 "$SETUP_CONF"

ok "Saved secrets to $SETUP_CONF (600). Guard it."
