#!/usr/bin/env bash
#
# aisp.sh — SimpleISP -> AISP migration prep
#
#   1. SSH:     root login by public key only, password login for other users
#   2. MariaDB: bind on 0.0.0.0
#   3. MariaDB: read-only user on the `radius` DB, reachable from anywhere
#   4. UFW:     open 3306/tcp
#
# Usage:
#   sudo ./aisp.sh
#   sudo DB_USER=aisp_ro DB_PASS='somepassword' ./aisp.sh
#   sudo ALLOW_CIDR=203.0.113.10/32 ./aisp.sh      # narrow the firewall rule
#
# Credentials are printed and written to /root/aisp.txt (mode 600).
# Override the path with CREDS_FILE=.
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
W=64                      # inner width of the boxes
# ----------------------------

# ---------- presentation ----------
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  CY=$'\033[1;36m'; GR=$'\033[1;32m'; YL=$'\033[1;33m'; RD=$'\033[1;31m'
else
  B=''; DIM=''; R=''; CY=''; GR=''; YL=''; RD=''
fi

STEP=0

LINE="$(printf '─%.0s' $(seq 1 $((W+2))))"

rule() { printf '%s%s%s\n' "$DIM" "$LINE" "$R"; }

# Pad by DISPLAY width, not byte count: printf's %-*s counts bytes, so a
# multi-byte character (→, ·, ✓) silently shortens the line and the box skews.
pad() {
  local s="$1" w="$2" n
  n=$(( w - ${#s} ))            # ${#s} is characters under a UTF-8 locale
  (( n > 0 )) && printf '%s%*s' "$s" "$n" '' || printf '%s' "$s"
}

boxline() { # boxline <color> <style> <text>
  printf '%s│%s %s %s│%s\n' "$1" "$2" "$(pad "$3" "$W")" "$1" "$R"
}
boxtop() { printf '%s╭%s╮%s\n' "$1" "$LINE" "$R"; }
boxmid() { printf '%s├%s┤%s\n' "$1" "$LINE" "$R"; }
boxbot() { printf '%s╰%s╯%s\n' "$1" "$LINE" "$R"; }

banner() {
  printf '\n'
  boxtop "$CY"
  boxline "$CY" "$B" "$1"
  [[ -n "${2:-}" ]] && boxline "$CY" "$DIM" "$2"
  boxbot "$CY"
}

step() { STEP=$((STEP+1)); printf '\n%s[%d/4]%s %s%s%s\n' "$CY" "$STEP" "$R" "$B" "$1" "$R"; }
ok()   { printf '      %s✓%s %s\n' "$GR" "$R" "$*"; }
info() { printf '        %s%s%s\n' "$DIM" "$*" "$R"; }
warn() { printf '      %s!%s %s\n' "$YL" "$R" "$*"; }
die()  { printf '\n      %s✗ %s%s\n\n' "$RD" "$*" "$R" >&2; exit 1; }
kv()   { printf '        %-10s %s\n' "$1" "$2"; }

# Indent a command's output, and never let a non-matching grep kill the run.
quiet() { "$@" 2>/dev/null | sed 's/^/        /' || true; }
# ----------------------------------

[[ $EUID -eq 0 ]] || die "Run as root."

backup() {
  [[ -f "$1" ]] || return 0
  cp -a "$1" "$1.bak-$STAMP"
  info "backup → $(basename "$1").bak-$STAMP"
}

# Box content stays ASCII: under a non-UTF-8 locale ${#s} counts bytes, so a
# multi-byte character inside a padded field would skew the border.
banner "SimpleISP -> AISP migration prep" "host $(hostname)  |  $(date '+%Y-%m-%d %H:%M %Z')"

# ---------- 1. SSH ----------
step "SSH — root by key, password login for everyone else"

[[ -d "$(dirname "$SSHD_CONF")" ]] || die "$(dirname "$SSHD_CONF") does not exist"
backup "$SSHD_CONF"

if [[ ! -s /root/.ssh/authorized_keys ]]; then
  warn "/root/.ssh/authorized_keys is empty or missing."
  warn "Root will NOT be able to log in with a password after this."
  ans=""
  if { : < /dev/tty; } 2>/dev/null; then
    # Read from the terminal, so `curl ... | bash` does not eat the answer.
    read -r -p "        Continue anyway? [y/N] " ans < /dev/tty
  elif [[ -t 0 ]]; then
    read -r -p "        Continue anyway? [y/N] " ans
  else
    die "No terminal to confirm on. Re-run with a TTY, or add a root key first."
  fi
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
ok "wrote $SSHD_CONF"

# sshd honours the FIRST occurrence of a keyword across all included files,
# so a drop-in that sorts earlier (or the main file) can silently win.
# Skip our own timestamped backups.
DUPES="$(grep -rlE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin)' \
          /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
          | grep -vE "(^${SSHD_CONF}$|\.bak-[0-9]{8}-[0-9]{6}$)" || true)"
if [[ -n "$DUPES" ]]; then
  warn "these files also set PasswordAuthentication/PermitRootLogin:"
  printf '        %s\n' $DUPES
  warn "sshd uses the first occurrence it reads — check Include order."
fi

sshd -t || die "sshd config test failed — original is at ${SSHD_CONF}.bak-${STAMP}"
systemctl reload ssh 2>/dev/null || systemctl reload sshd
ok "config valid, sshd reloaded"
sshd -T 2>/dev/null \
  | grep -Ei '^(permitrootlogin|passwordauthentication|pubkeyauthentication)' \
  | sed 's/^/        /' || true

# ---------- 2. MariaDB bind-address ----------
step "MariaDB — listen on all interfaces"

[[ -f "$MY_CONF" ]] || die "$MY_CONF not found"
backup "$MY_CONF"

if grep -qE '^[[:space:]]*#?[[:space:]]*bind-address' "$MY_CONF"; then
  sed -ri 's|^[[:space:]]*#?[[:space:]]*bind-address[[:space:]]*=.*|bind-address            = 0.0.0.0|' "$MY_CONF"
else
  sed -ri '0,/^\[mysqld\]/s||[mysqld]\nbind-address            = 0.0.0.0|' "$MY_CONF"
fi
sed -ri 's|^[[:space:]]*skip-networking|#skip-networking|' "$MY_CONF"
ok "bind-address = 0.0.0.0 in $(basename "$MY_CONF")"

systemctl restart mariadb
ok "mariadb restarted"
quiet ss -lntp | grep ":${DB_PORT}" || info "port ${DB_PORT} not visible in ss output"

# ---------- 3. Read-only DB user ----------
step "Database — read-only user on \`${DB_NAME}\`"

# Read a fixed chunk, THEN filter. A `| head -c N` would SIGPIPE the producer
# and trip `set -o pipefail`, exiting the script with no message at all.
gen_pass() {
  local raw
  raw="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  [[ ${#raw} -ge 28 ]] || die "Could not generate a password from /dev/urandom."
  printf '%s' "${raw:0:28}"
}

if [[ -z "$DB_PASS" ]]; then
  DB_PASS="$(gen_pass)"
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
ok "user '${DB_USER}'@'%' created with SELECT, SHOW VIEW"
quiet mysql -N -e "SHOW GRANTS FOR '${DB_USER}'@'%';"

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
: "${HOST_IP:=<this-host>}"

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
ok "credentials saved to $CREDS_FILE (mode 600)"

# Printed here, not only in the summary: if a later step fails, `set -e` exits
# and the summary never runs.
printf '\n'
boxtop  "$YL"
boxline "$YL" "$B"  "DATABASE CREDENTIALS"
boxmid  "$YL"
boxline "$YL" "$R"  "$(printf '%-10s %s' 'host'     "$HOST_IP")"
boxline "$YL" "$R"  "$(printf '%-10s %s' 'port'     "$DB_PORT")"
boxline "$YL" "$R"  "$(printf '%-10s %s' 'database' "$DB_NAME")"
boxline "$YL" "$R"  "$(printf '%-10s %s' 'username' "$DB_USER")"
boxline "$YL" "$B"  "$(printf '%-10s %s' 'password' "$DB_PASS")"
boxbot  "$YL"
[[ -n "${GENERATED:-}" ]] && info "password generated, 28 chars — also in $CREDS_FILE"
printf '\n'

# ---------- 4. UFW ----------
step "Firewall — open ${DB_PORT}/tcp"

if command -v ufw >/dev/null 2>&1; then
  if [[ "$ALLOW_CIDR" == "any" ]]; then
    ufw allow "${DB_PORT}/tcp" comment 'MariaDB - AISP migration' >/dev/null
    ok "allowed ${DB_PORT}/tcp from anywhere"
    warn "3306 is open to the internet — restrict with ALLOW_CIDR= and close it after"
  else
    ufw allow from "$ALLOW_CIDR" to any port "$DB_PORT" proto tcp \
      comment 'MariaDB - AISP migration' >/dev/null
    ok "allowed ${DB_PORT}/tcp from ${ALLOW_CIDR}"
  fi
  quiet ufw status numbered | grep -E "${DB_PORT}"
else
  warn "ufw not installed — skipping firewall step"
fi

# ---------- summary ----------
rule
printf '\n  %s✓ Done.%s  Connect from the AISP side with:\n\n' "$GR" "$R"
printf '      %smysql -h %s -P %s -u %s -p %s%s\n\n' \
       "$B" "$HOST_IP" "$DB_PORT" "$DB_USER" "$DB_NAME" "$R"
kv "creds"   "$CREDS_FILE"
kv "backups" "${SSHD_CONF}.bak-${STAMP}"
kv ""        "${MY_CONF}.bak-${STAMP}"
printf '\n  %sTear down when the migration is finished:%s\n' "$DIM" "$R"
printf '      ufw status numbered && ufw delete <num>\n'
printf '      mysql -e "DROP USER '"'"'%s'"'"'@'"'"'%%'"'"';"\n' "$DB_USER"
printf '      shred -u %s\n\n' "$CREDS_FILE"