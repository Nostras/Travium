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
DEFAULT_RECAPTCHA_PUBLIC="6LdaX54sAAAAAEPryAZCEDLeeZ2GZfCXfNy-hbfX"
DEFAULT_RECAPTCHA_PRIVATE="6LdaX54sAAAAANrV3e3mRN0WGI3La3SuAew09-vg"

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
# Restore pre-existing certs (if provided)
# Before running this script, place your old certs in /root/certs-restore/:
#   /root/certs-restore/LOCALTRAV.key
#   /root/certs-restore/LOCALTRAV.crt
#   /root/certs-restore/<DOMAIN>.key   (filename must match your --domain arg)
#   /root/certs-restore/<DOMAIN>.crt
# CloudPanel just created /etc/nginx/ssl-certificates — safe to restore into it now.
#####################################
RESTORE_DIR="/root/certs-restore"
if [[ -d "$RESTORE_DIR" ]]; then
    log "Found $RESTORE_DIR — restoring certs into /etc/nginx/ssl-certificates/ ..."
    cp "$RESTORE_DIR/LOCALTRAV.key" /etc/nginx/ssl-certificates/
    cp "$RESTORE_DIR/LOCALTRAV.crt" /etc/nginx/ssl-certificates/
    cp "$RESTORE_DIR/${DOMAIN}.key"  /etc/nginx/ssl-certificates/
    cp "$RESTORE_DIR/${DOMAIN}.crt"  /etc/nginx/ssl-certificates/
    chmod 600 /etc/nginx/ssl-certificates/LOCALTRAV.key /etc/nginx/ssl-certificates/${DOMAIN}.key
    ok "Certs restored. Generation step will be skipped later."
else
    log "No $RESTORE_DIR found — certs will be generated fresh."
fi

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
# Add database as well
clpctl firewall:add-rule --label='MYSQL' --port='3306' --protocol='tcp' --address='0.0.0.0/0'

#####################################
# Repo checkout
#####################################
log "Cloning Travium repo..."
HTDOCS="/home/${SITE_USER}/htdocs"
install -d -o "${SITE_USER}" -g "${SITE_USER}" "/home/${SITE_USER}"
rm -rf "$HTDOCS" || true
su - "${SITE_USER}" -c "git clone -b feature/wip --single-branch https://github.com/Nostras/Travium ${HTDOCS}"

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
# Install Travium Update Helper
#####################################
log "Installing update helper from repository..."

UPDATE_SRC="${HTDOCS}/travium-update"
UPDATE_BIN="/usr/local/bin/travium-update"

if [[ -f "$UPDATE_SRC" ]]; then
    # Copy to global bin
    cp "$UPDATE_SRC" "$UPDATE_BIN"
    
    # Patch the SITE_USER variable in the script to match the current installation
    # This ensures it works even if you used a custom --user arg
    sed -i "s/^SITE_USER=.*/SITE_USER=\"${SITE_USER}\"/" "$UPDATE_BIN"
    
    # Set permissions
    chown root:root "$UPDATE_BIN"
    chmod +x "$UPDATE_BIN"
    
    ok "Update helper installed to $UPDATE_BIN"
else
    err "travium-update not found in repository! Skipping helper installation."
fi

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
#####################################
log "Installing systemd units..."

# 1. The Service Template
cat >/etc/systemd/system/travium@.service <<UNIT
[Unit]
Description=Travium engine for %i
After=network.target mysqld.service
# Link instance lifecycle to the main target
PartOf=travium.target

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

# 2. The Main Target (for grouping)
cat >/etc/systemd/system/travium.target <<UNIT
[Unit]
Description=Travium all engines

[Install]
WantedBy=multi-user.target
UNIT

# 3. The Sync Script (Corrected Logic)
install -m 0755 -o root -g root /dev/stdin /usr/local/bin/travium-sync <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

HTDOCS="/home/REPLACE_USER/htdocs"
SERVERS_DIR="$HTDOCS/servers"

# 1. Find directories that have an engine.php
mapfile -t desired < <(find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d -exec test -f "{}/include/engine.php" \; -printf '%f\n' | sort)

# 2. Find currently enabled systemd units for this template
mapfile -t current < <(systemctl list-unit-files "travium@*" --state=enabled --no-legend | awk '{print $1}' | sed -E 's/^travium@(.+)\.service$/\1/' | sort)

# 3. Enable and START missing services
for w in "${desired[@]}"; do
    # Enable if not enabled
    if ! systemctl is-enabled --quiet "travium@${w}.service" 2>/dev/null; then
        echo "Enabling travium@${w}.service"
        systemctl enable "travium@${w}.service"
    fi
    
    # Start if not running (Fixes the 'inactive dead' issue)
    if [[ $(systemctl is-active "travium@${w}.service") != "active" ]]; then
        echo "Starting travium@${w}.service"
        systemctl start "travium@${w}.service"
    fi
done

# 4. Disable and STOP removed services
for w in "${current[@]}"; do
    if [[ ! -d "$SERVERS_DIR/$w" ]]; then
        echo "Stopping and disabling defunct service: travium@${w}.service"
        systemctl disable --now "travium@${w}.service" || true
    fi
done
SCRIPT

# Inject real user path into travium-sync
sed -i "s|/home/REPLACE_USER/htdocs|/home/${SITE_USER}/htdocs|g" /usr/local/bin/travium-sync

# 4. The Sync Service (triggered by the Path unit)
cat >/etc/systemd/system/travium-sync.service <<UNIT
[Unit]
Description=Sync Travium instances with /servers
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/travium-sync
UNIT

# 5. The Path Monitor
cat >/etc/systemd/system/travium-sync.path <<UNIT
[Unit]
Description=Watch /home/${SITE_USER}/htdocs/servers for changes

[Path]
# Trigger when a folder is created, deleted, or moved
PathChanged=/home/${SITE_USER}/htdocs/servers

[Install]
WantedBy=multi-user.target
UNIT

# 6. Activation
chmod +x /usr/local/bin/travium-sync
systemctl daemon-reload
systemctl enable --now travium-sync.path
systemctl enable travium.target
# Run once immediately to catch existing folders
systemctl start travium-sync.service


#####################################
# Regenerate faulty certs
#####################################
SSL_DIR="/etc/nginx/ssl-certificates"
CA_NAME="LOCALTRAV"

# If all four cert files are already present (copied in from a previous install),
# skip generation entirely so existing device trust is preserved.
# Files to copy from the old VM before running this script:
#   /etc/nginx/ssl-certificates/LOCALTRAV.key
#   /etc/nginx/ssl-certificates/LOCALTRAV.crt
#   /etc/nginx/ssl-certificates/<DOMAIN>.key
#   /etc/nginx/ssl-certificates/<DOMAIN>.crt
if [[ -f "$SSL_DIR/$CA_NAME.key" && \
      -f "$SSL_DIR/$CA_NAME.crt" && \
      -f "$SSL_DIR/$DOMAIN.key"  && \
      -f "$SSL_DIR/$DOMAIN.crt" ]]; then
    ok "Existing certs found in $SSL_DIR — skipping cert generation."
else
    log "One or more cert files missing — generating fresh certs..."

    # --- STEP 1: Create the Root CA (The "Boss") ---
    # This is the file you install on Windows/Android.
    if [ ! -f "$SSL_DIR/$CA_NAME.key" ]; then
        echo "Generating New Root CA..."
        openssl genrsa -out "$SSL_DIR/$CA_NAME.key" 2048
        openssl req -x509 -new -nodes -key "$SSL_DIR/$CA_NAME.key" -sha256 -days 3650 \
            -out "$SSL_DIR/$CA_NAME.crt" \
            -subj "/C=US/ST=State/L=Locality/O=Development/CN=$CA_NAME"
    fi

    # --- STEP 2: Generate Domain Key & CSR ---
    openssl genrsa -out "$SSL_DIR/$DOMAIN.key" 2048
    openssl req -new -key "$SSL_DIR/$DOMAIN.key" -out "$SSL_DIR/$DOMAIN.csr" \
        -subj "/C=US/ST=State/L=Locality/O=Organization/OU=Unit/CN=*.$DOMAIN"

    # --- STEP 3: Create the Config with SAN and CA:FALSE ---
    cat > /tmp/openssl.cnf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
EOF

    # --- STEP 4: Sign the Domain Cert with the Root CA ---
    openssl x509 -req -in "$SSL_DIR/$DOMAIN.csr" \
        -CA "$SSL_DIR/$CA_NAME.crt" -CAkey "$SSL_DIR/$CA_NAME.key" \
        -CAcreateserial -out "$SSL_DIR/$DOMAIN.crt" \
        -days 825 -sha256 -extfile /tmp/openssl.cnf

    echo "Done! Install $CA_NAME.crt on your devices."
fi

# Reload Nginx regardless — needed whether certs are new or restored
systemctl reload nginx

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

ok "This is your cert, save this as a .crt file and load it in your OS"
cat "/etc/nginx/ssl-certificates/$DOMAIN.crt"