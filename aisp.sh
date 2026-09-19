#!/usr/bin/env bash
#
# aisp.sh
# Prepares a host for SimpleISP -> AISP migration:
#   1. SSH: root login by public key only, password login allowed for other users
#   2. MariaDB: bind on 0.0.0.0
#   3. MariaDB: read-only user on the `radius` DB, reachable from anywhere
#   4. UFW: open 3306/tcp
#
# Usage:
#   sudo ./aisp.sh
#   sudo DB_USER=aisp_ro DB_PASS='somepassword' ./aisp.sh
#   sudo ALLOW_CIDR=203.0.113.10/32 ./aisp.sh   # narrow the firewall rule
#
# Credentials are written to /root/aisp.txt (mode 600); override with CREDS_FILE=.
#
set -euo pipefail

# ---------- config ----------
SSHD_CONF="/etc/ssh/sshd_config.d/60-cloudimg-settings.conf"
MY_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
DB_NAME="${DB_NAME:-radius}"
DB_USER="${DB_USER:-aisp_ro}"
DB_PASS="${DB_PASS:-}"
DB_PORT="${DB_PORT:-3306}"
ALLOW_CIDR="${ALLOW_CIDR:-any}"
CREDS_FILE="${CREDS_FILE:-/root/aisp.txt}"
STAMP="$(date +%Y%m%d-%H%M%S)"
# ----------------------------

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."

backup() {
  [[ -f "$1" ]] && cp -a "$1" "$1.bak-$STAMP" && log "Backed up $1 -> $1.bak-$STAMP"
}

# ---------- 1. SSH ----------
log "Configuring SSH"

[[ -d "$(dirname "$SSHD_CONF")" ]] || die "$(dirname "$SSHD_CONF") does not exist"
backup "$SSHD_CONF"

# Confirm root actually has a key before locking password auth for root
if [[ ! -s /root/.ssh/authorized_keys ]]; then
  warn "/root/.ssh/authorized_keys is empty or missing."
  warn "After this runs, root will NOT be able to log in with a password."
  read -r -p "Continue anyway? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || die "Aborted."
fi

cat > "$SSHD_CONF" <<'EOF'
# Managed by aisp.sh
# Root: key-based login only (no password).
PermitRootLogin prohibit-password

# Everyone else: password login permitted.
PasswordAuthentication yes

PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF

# sshd honours the FIRST occurrence of a keyword across all included files,
# so a drop-in that sorts earlier (or the main file) can silently win.
DUPES="$(grep -rlE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin)' \
          /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
          | grep -v "^${SSHD_CONF}$" || true)"
if [[ -n "$DUPES" ]]; then
  warn "These files also set PasswordAuthentication/PermitRootLogin:"
  printf '      %s\n' $DUPES
  warn "sshd uses the first occurrence it reads — check Include order in /etc/ssh/sshd_config."
fi

sshd -t || die "sshd config test failed — original is at ${SSHD_CONF}.bak-${STAMP}"
systemctl reload ssh 2>/dev/null || systemctl reload sshd
log "SSH reloaded. Effective settings:"
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|pubkeyauthentication)' | sed 's/^/      /'

# ---------- 2. MariaDB bind-address ----------
log "Setting MariaDB bind-address to 0.0.0.0"

[[ -f "$MY_CONF" ]] || die "$MY_CONF not found"
backup "$MY_CONF"

if grep -qE '^[[:space:]]*#?[[:space:]]*bind-address' "$MY_CONF"; then
  sed -ri 's|^[[:space:]]*#?[[:space:]]*bind-address[[:space:]]*=.*|bind-address            = 0.0.0.0|' "$MY_CONF"
else
  sed -ri '0,/^\[mysqld\]/s||[mysqld]\nbind-address            = 0.0.0.0|' "$MY_CONF"
fi

# skip-networking would defeat the whole point
sed -ri 's|^[[:space:]]*skip-networking|#skip-networking|' "$MY_CONF"

grep -nE '^[[:space:]]*bind-address' "$MY_CONF" | sed 's/^/      /'

systemctl restart mariadb
log "MariaDB restarted"

# ---------- 3. Read-only DB user ----------
log "Creating read-only user '${DB_USER}'@'%' on \`${DB_NAME}\`"

if [[ -z "$DB_PASS" ]]; then
  DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28)"
  GENERATED=1
elif [[ "$DB_PASS" =~ [\'\\\"\`] ]]; then
  die "DB_PASS must not contain quotes or backslashes (it is interpolated into SQL)."
fi

mysql <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT, SHOW VIEW ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

mysql -e "SHOW GRANTS FOR '${DB_USER}'@'%';" | sed 's/^/      /'

# ---------- 3b. Record credentials ----------
log "Writing credentials to ${CREDS_FILE}"

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
: "${HOST_IP:=<this-host>}"

# Fresh file per run, root-only
install -m 600 /dev/null "$CREDS_FILE"
cat > "$CREDS_FILE" <<EOF
# AISP migration — read-only database access
# Written by aisp.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')

DB_HOST=${HOST_IP}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

# Grants: SELECT, SHOW VIEW on ${DB_NAME}.* from '%'
# Connect:
#   mysql -h ${HOST_IP} -P ${DB_PORT} -u ${DB_USER} -p ${DB_NAME}
#
# Revoke when the migration is done:
#   mysql -e "DROP USER '${DB_USER}'@'%';"
EOF
chmod 600 "$CREDS_FILE"
ls -l "$CREDS_FILE" | sed 's/^/      /'

# ---------- 4. UFW ----------
if command -v ufw >/dev/null 2>&1; then
  log "Opening ${DB_PORT}/tcp in UFW (source: ${ALLOW_CIDR})"
  if [[ "$ALLOW_CIDR" == "any" ]]; then
    ufw allow "${DB_PORT}/tcp" comment 'MariaDB - AISP migration'
  else
    ufw allow from "$ALLOW_CIDR" to any port "$DB_PORT" proto tcp comment 'MariaDB - AISP migration'
  fi
  ufw status numbered | grep -E "(^Status|${DB_PORT})" | sed 's/^/      /'
else
  warn "ufw not installed — skipping firewall step"
fi

# ---------- summary ----------
echo
log "Done."
cat <<EOF

  Connect from the AISP side with:

    mysql -h ${HOST_IP} -P ${DB_PORT} -u ${DB_USER} -p ${DB_NAME}

  User:     ${DB_USER}
  Password: ${DB_PASS}$( [[ -n "${GENERATED:-}" ]] && echo "   <-- generated" )
  Grants:   SELECT, SHOW VIEW on ${DB_NAME}.* from any host
  Saved to: ${CREDS_FILE} (mode 600)

  Backups:  ${SSHD_CONF}.bak-${STAMP}
            ${MY_CONF}.bak-${STAMP}

  Tear down when the migration is finished:
    ufw status numbered && ufw delete <num>
    mysql -e "DROP USER '${DB_USER}'@'%';"

EOF