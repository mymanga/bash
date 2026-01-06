#!/usr/bin/env bash
# ---------------------------------------------------------------------------------
# universal2_replaced_complete.sh — Universal autotune & in-place PHP-FPM edits
# - Backups, MariaDB tuning fragment, index ensures, FreeRADIUS tuning
# - PHP-FPM: REPLACE existing pm.* and slowlog/status/catch directives IN-PLACE
# - Removes any existing AUTOTUNE block before edits
# - Safe --dry-run support, lock to avoid concurrent runs
# - Heavily commented where important (you requested comments)
# ---------------------------------------------------------------------------------
set -euo pipefail

# ----------------------------
# Global configuration section
# ----------------------------
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG="/var/log/universal_${TIMESTAMP}.log"
BACKUP_BASE="/var/backups/universal"
DB_BACKUP_DIR="${BACKUP_BASE}/db"
CONF_BACKUP_DIR="${BACKUP_BASE}/conf"
KEEP=3

DB_NAME="radius"
MYSQL_USER="root"
MYSQL_BIN="$(command -v mysql || true)"
MYSQLDUMP_BIN="$(command -v mysqldump || true)"
MYSQL_CMD=("${MYSQL_BIN}" -u "${MYSQL_USER}")
MYSQL_DB_CMD=("${MYSQL_BIN}" -u "${MYSQL_USER}" -D "${DB_NAME}")
MYSQLDUMP_CMD=("${MYSQLDUMP_BIN}" -u "${MYSQL_USER}")

PTOSC="$(command -v pt-online-schema-change || true)"

PHPFPM_SUGGESTION_FILE="/root/phpfpm_tune_suggestion.txt"
PM_MAX_REQUESTS=500
REQUEST_SLOWLOG_TIMEOUT="5s"
CATCH_WORKERS_OUTPUT="yes"
STATUS_PATH="/status"
FPM_USER="www-data"
FPM_GROUP="www-data"

MARIADB_FRAG="/etc/mysql/mariadb.conf.d/99-universal-autotune.cnf"

DRY_RUN=0
DO_ARCHIVE=0

# -----------------
# Usage and parsing
# -----------------
usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--help]
  --dry-run  : preview actions without applying changes, no restarts
  --help     : show this help message and exit
Environment:
  MYSQL_PWD  : set to the MySQL root password if required
  PHP_VER_OVERRIDE : force a specific PHP version (e.g., 7.4, 8.2)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

# ----------------------
# Locking, logging, prep
# ----------------------
mkdir -p "${DB_BACKUP_DIR}" "${CONF_BACKUP_DIR}" "$(dirname "${LOG}")"
exec 3>&1 1>>"${LOG}" 2>&1

# Acquire an exclusive lock to avoid concurrent runs
LOCK_FD=200
LOCK_FILE="/var/lock/universal.lock"
eval "exec ${LOCK_FD}>\"${LOCK_FILE}\""
if ! flock -n "${LOCK_FD}"; then
  echo "ERROR: another run in progress (lock: ${LOCK_FILE})" >&2
  exit 2
fi

log() { echo "[$(date +'%F %T')] $*" | tee /dev/fd/3; }
die() { echo "ERROR: $*" >&2; exit 1; }

if [ -z "${MYSQL_BIN}" ] || [ -z "${MYSQLDUMP_BIN}" ]; then
  die "mysql or mysqldump binary not found in PATH"
fi

# --------------------------
# System resource introspection
# --------------------------
RAM_MB=$(awk '/MemTotal/ {printf("%d",$2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)
VCPUS=$(nproc --all 2>/dev/null || awk '/model name/ {c++} END{print c+0}' /proc/cpuinfo 2>/dev/null || echo 2)
RAM_MB=${RAM_MB:-4096}
VCPUS=${VCPUS:-2}

log ""
log "========================"
log " Server resources detected"
log "------------------------"
log "Detected RAM: ${RAM_MB} MB"
log "Detected vCPUs: ${VCPUS}"
log "Dry-run mode: ${DRY_RUN}"
log "Backups retention (keep): ${KEEP}"
log ""

# -------------------------------------------
# Step 2: Backups (DB, FreeRADIUS, PHP-FPM, MariaDB)
# -------------------------------------------
FULL_DB_FILE="${DB_BACKUP_DIR}/${DB_NAME}_full_${TIMESTAMP}.sql.gz"
SCHEMA_DB_FILE="${DB_BACKUP_DIR}/${DB_NAME}_schema_${TIMESTAMP}.sql.gz"

log "========================"
log " Step 2: Create backups (radius DB full + schema, configs)"
log "------------------------"

if [ "$DRY_RUN" -eq 0 ]; then
  log "[RUN] dump full ${DB_NAME} DB -> ${FULL_DB_FILE}"
  if "${MYSQLDUMP_CMD[@]}" "${DB_NAME}" --single-transaction --routines --events | gzip -c > "${FULL_DB_FILE}"; then
    log "[OK] full DB dump created"
  else
    log "[ERROR] full DB dump failed (check MySQL access)"
  fi

  log "[RUN] dump ${DB_NAME} schema only -> ${SCHEMA_DB_FILE}"
  if "${MYSQLDUMP_CMD[@]}" "${DB_NAME}" --no-data --routines --events | gzip -c > "${SCHEMA_DB_FILE}"; then
    log "[OK] schema-only dump created"
  else
    log "[ERROR] schema-only dump failed"
  fi
else
  log "[DRY] would create full DB dump -> ${FULL_DB_FILE}"
  log "[DRY] would create schema-only dump -> ${SCHEMA_DB_FILE}"
fi

# Backup freeradius conf
RADDIR_CANDIDATES=(/etc/freeradius /etc/freeradius/3.0 /etc/freeradius/3.2 /etc/raddb)
RAD_BACKUP="${CONF_BACKUP_DIR}/freeradius_conf_${TIMESTAMP}.tar.gz"
FOUND_RAD=0
for d in "${RADDIR_CANDIDATES[@]}"; do
  if [ -d "$d" ]; then
    log "[RUN] backup freeradius conf (${d}) -> ${RAD_BACKUP}"
    if [ "$DRY_RUN" -eq 0 ]; then
      tar -C / -czf "${RAD_BACKUP}" "${d#/}" || true
    fi
    log "[OK] freeradius conf backup attempted"
    FOUND_RAD=1
    break
  fi
done
if [ "$FOUND_RAD" -eq 0 ]; then
  log "[WARN] freeradius config directory not found, skipped"
fi

# Backup php-fpm pool dirs
PHP_FPM_BACKUP="${CONF_BACKUP_DIR}/phpfpm_pools_${TIMESTAMP}.tar.gz"
log "[RUN] backup php-fpm pool confs -> ${PHP_FPM_BACKUP}"
PHP_POOL_DIRS=(/etc/php/*/fpm/pool.d)
exists=()
for p in ${PHP_POOL_DIRS[@]}; do
  if compgen -G "$p" >/dev/null; then
    exists+=("$p")
  fi
done
if [ "${#exists[@]}" -gt 0 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    tar -czf "${PHP_FPM_BACKUP}" "${exists[@]}" 2>/dev/null || true
  fi
  log "[OK] php-fpm pool backup processed"
else
  log "[WARN] no php-fpm pool dirs found, skipped"
fi

# Backup MariaDB config files
MARIADB_BACKUP="${CONF_BACKUP_DIR}/mariadb_conf_${TIMESTAMP}.tar.gz"
MARIADB_CAND=(/etc/mysql /etc/mysql/mariadb.conf.d /etc/mysql/conf.d /etc/my.cnf /etc/mysql/my.cnf)
log "[RUN] backup mariadb configs -> ${MARIADB_BACKUP}"
to_tar=()
for p in "${MARIADB_CAND[@]}"; do
  [ -e "$p" ] && to_tar+=( "$p" )
done
if [ "${#to_tar[@]}" -gt 0 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    tar -czf "${MARIADB_BACKUP}" "${to_tar[@]}" 2>/dev/null || true
  fi
  log "[OK] mariadb config backup processed"
else
  log "[WARN] no mariadb config files found to backup"
fi

log ""

# -------------------------------------------------------
# Step 3: Enforce backup retention policy (keep last N)
# -------------------------------------------------------
remove_old() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -n | awk -v keep="$KEEP" '{files[NR]=$2} END{n=NR; for(i=1;i<=n-keep;i++){ if(i>0 && i<=n){ print files[i] }}}' | while read -r old; do
    [ -n "$old" ] || continue
    if [ "$DRY_RUN" -eq 0 ]; then rm -f "$old" || true; fi
    log "[REMOVED] $old"
  done || true
}

log "========================"
log " Step 3: Backup retention — keep last ${KEEP}"
log "------------------------"
remove_old "${DB_BACKUP_DIR}"
remove_old "${CONF_BACKUP_DIR}"
log ""

# ----------------------------------------------------------------------
# Step 4: Schema adjustments — indexes and safe column modifications
# ----------------------------------------------------------------------
log "========================"
log " Step 4: Ensure required indexes & column sizes on radius/vouchers"
log "------------------------"

column_exists() {
  local table="$1" col="$2"
  col=$(echo "$col" | sed -E 's/\(.+$//')
  "${MYSQL_BIN}" -u "${MYSQL_USER}" -sN -e "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table}' AND COLUMN_NAME='${col}';" 2>/dev/null | grep -q '^1$'
}

index_exists() {
  local table="$1" idx="$2"
  "${MYSQL_BIN}" -u "${MYSQL_USER}" -sN -e "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table}' AND INDEX_NAME='${idx}';" 2>/dev/null | grep -q '^1$'
}

index_on_columns_exists() {
  local table="$1" cols="$2" normalized cols_no_spaces existing
  normalized=$(echo "$cols" | sed -E 's/\([^)]+\)//g; s/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]*,[[:space:]]*/,/g')
  cols_no_spaces=$(echo "$normalized" | tr -d ' ')
  existing=$("${MYSQL_BIN}" -u "${MYSQL_USER}" -sN -e "\
    SELECT INDEX_NAME\
    FROM information_schema.STATISTICS\
    WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table}'\
    GROUP BY INDEX_NAME\
    HAVING REPLACE(GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','), ' ', '') = '${cols_no_spaces}'\
    LIMIT 1;" 2>/dev/null || echo "")
  [ -n "$existing" ] && echo "$existing" || echo ""
}

ensure_index() {
  local table="$1" idx="$2" cols="$3" sql
  IFS=',' read -ra colarr <<< "$cols"
  for c in "${colarr[@]}"; do
    local rawc
    rawc=$(echo "$c" | sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\(.+$//')
    if ! column_exists "$table" "$rawc"; then
      log "[WARN] ${table} missing column '${rawc}'; skipping index ${idx} (requires ${cols})"
      return 0
    fi
  done

  if index_exists "$table" "$idx"; then
    log "[OK] index ${idx} exists on ${table}; skipping"
    return 0
  fi

  local covering
  covering=$(index_on_columns_exists "$table" "$cols")
  if [ -n "$covering" ]; then
    log "[OK] index '${covering}' already covers columns (${cols}) on ${table}; skipping duplicate"
    return 0
  fi

  sql="ALTER TABLE \`${DB_NAME}\`.\`${table}\` ADD INDEX \`${idx}\` (${cols});"
  log "[RUN] create index ${idx} on ${table} cols (${cols})"
  log "$sql"
  if [ "$DRY_RUN" -eq 0 ]; then
    set +e
    "${MYSQL_DB_CMD[@]}" -e "$sql" 2>&1
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      if [ -n "${PTOSC}" ]; then
        log "[INFO] direct ALTER failed; trying pt-online-schema-change for ${table}.${idx}"
        set +e
        ${PTOSC} --alter "ADD INDEX \`${idx}\` (${cols})" D=${DB_NAME},t=${table} --execute
        local pt_rc=$?
        set -e
        if [ $pt_rc -ne 0 ]; then
          log "[ERROR] pt-online-schema-change failed for ${table}.${idx} (exit ${pt_rc})."
        else
          log "[OK] pt-online-schema-change created ${idx} on ${table}."
        fi
      else
        log "[ERROR] ALTER TABLE failed and Percona Toolkit not available; consider maintenance window for index ${idx} on ${table}."
      fi
    else
      log "[OK] index ${idx} created on ${table}"
    fi
  else
    log "[DRY] would run: $sql"
  fi
}

declare -a IDX_SPECS=(
  "radacct|idx_acctuniqueid|acctuniqueid"
  "radacct|idx_radacct_user_time|username(50),acctstarttime"
  "radacct|idx_radacct_nas_ip|nasipaddress"
  "radacct|idx_radacct_framed|framedipaddress"
  "radpostauth|idx_authdate|authdate"
  "radcheck|idx_username|username"
  "radreply|idx_username_attr|username,attribute"
  "hotspot_sessions|idx_payment_voucher|payment_id,voucher"
  "hotspot_sessions|idx_mac|mac"
  "hotspot_sessions|idx_voucher|voucher"
  "hotspot_sessions|idx_created_at|created_at"
  "vouchers|idx_vouchers_expiration|expiration_time"
  "vouchers|idx_vouchers_status_exp|status,expiration_time"
  "vouchers|idx_vouchers_plan_status|plan_id,status"
  "vouchers|idx_vouchers_location|location_id"
  "vouchers|idx_vouchers_phone|phone"
  "vouchers|idx_code|code"
  "vouchers|idx_created_at|created_at"
  "vouchers|idx_status|status"
  "vouchers|idx_phone|phone"
  "vouchers|idx_expiration_time|expiration_time"
)

for spec in "${IDX_SPECS[@]}"; do
  IFS='|' read -r tbl idx cols <<< "$spec"
  ensure_index "$tbl" "$idx" "$cols"
done

log "[RUN] Analyze tables to refresh optimizer stats"
for t in radacct radpostauth hotspot_sessions vouchers; do
  if [ "$DRY_RUN" -eq 0 ]; then
    "${MYSQL_DB_CMD[@]}" -e "ANALYZE TABLE \`${DB_NAME}\`.\`${t}\`;" 2>>"${LOG}" || log "[WARN] ANALYZE TABLE ${t} failed or not necessary"
  else
    log "[DRY] would run: ANALYZE TABLE ${DB_NAME}.${t}"
  fi
done
log "[OK] Table analysis requested for radacct, radpostauth, hotspot_sessions, vouchers"

log "[RUN] ensure radacct.nasportid VARCHAR(255)"
if [ "$DRY_RUN" -eq 0 ]; then
  set +e
  "${MYSQL_BIN}" -u "${MYSQL_USER}" -sN -e "SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='radacct' AND COLUMN_NAME='nasportid';" 2>/dev/null | awk '{print $1}' | grep -q '^255$'
  col_is_255=$?
  set -e
  if [ $col_is_255 -ne 0 ]; then
    if ! "${MYSQL_DB_CMD[@]}" -e "ALTER TABLE \`${DB_NAME}\`.radacct MODIFY nasportid VARCHAR(255) DEFAULT NULL;" 2>>"${LOG}"; then
      log "[ERROR] Failed to resize nasportid column; it may already be correct or error occurred."
    else
      log "[OK] Column nasportid resized to VARCHAR(255)"
    fi
  else
    log "[OK] Column nasportid already VARCHAR(255); no change"
  fi
else
  log "[DRY] would run: ALTER TABLE ${DB_NAME}.radacct MODIFY nasportid VARCHAR(255) DEFAULT NULL;"
fi

log ""

# -----------------------------------------------------
# Step 5: Compute and apply enhanced MariaDB tuning
# -----------------------------------------------------
log "========================"
log " Step 5: Enhanced MariaDB InnoDB tuning (buffer/log/conn/tmp)"
log "------------------------"

TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo $((RAM_MB*1024)))
TOTAL_MEM_BYTES=$((TOTAL_MEM_KB * 1024))
MIN_POOL_BYTES=$((1 * 1024 * 1024 * 1024))
CALC_POOL_BYTES=$(awk -v m="$TOTAL_MEM_BYTES" 'BEGIN{printf("%d", m*0.50)}')
INNODB_BUFFER_POOL_SIZE_BYTES=$(( CALC_POOL_BYTES < MIN_POOL_BYTES ? MIN_POOL_BYTES : CALC_POOL_BYTES ))
ROUND_128MB=$((128 * 1024 * 1024))
INNODB_BUFFER_POOL_SIZE_BYTES=$(( (INNODB_BUFFER_POOL_SIZE_BYTES / ROUND_128MB) * ROUND_128MB ))
if [ "$INNODB_BUFFER_POOL_SIZE_BYTES" -lt "$MIN_POOL_BYTES" ]; then INNODB_BUFFER_POOL_SIZE_BYTES=$MIN_POOL_BYTES; fi
INNODB_BUFFER_POOL_SIZE_MB=$(( INNODB_BUFFER_POOL_SIZE_BYTES / 1024 / 1024 ))

INNODB_BUFFER_POOL_INSTANCES=$(( INNODB_BUFFER_POOL_SIZE_MB / 1024 ))
if [ "$INNODB_BUFFER_POOL_INSTANCES" -lt 1 ]; then INNODB_BUFFER_POOL_INSTANCES=1; fi
if [ "$INNODB_BUFFER_POOL_INSTANCES" -gt 8 ]; then INNODB_BUFFER_POOL_INSTANCES=8; fi

LOG_FILE_SIZE_BYTES=$(( INNODB_BUFFER_POOL_SIZE_BYTES / 4 ))
MAX_LOG_BYTES=$((1 * 1024 * 1024 * 1024))
if [ "$LOG_FILE_SIZE_BYTES" -gt "$MAX_LOG_BYTES" ]; then LOG_FILE_SIZE_BYTES=$MAX_LOG_BYTES; fi
ROUND_16MB=$((16 * 1024 * 1024))
INNODB_LOG_FILE_SIZE_BYTES=$(( (LOG_FILE_SIZE_BYTES / ROUND_16MB) * ROUND_16MB ))
INNODB_LOG_FILE_SIZE_MB=$(( INNODB_LOG_FILE_SIZE_BYTES / 1024 / 1024 ))

MAX_CONNECTIONS=$(( VCPUS * 150 ))
if [ "$MAX_CONNECTIONS" -gt 2000 ]; then MAX_CONNECTIONS=2000; fi

TMP_TABLE_SIZE_MB=$(( INNODB_BUFFER_POOL_SIZE_MB / 8 ))
if [ "$TMP_TABLE_SIZE_MB" -lt 64 ]; then TMP_TABLE_SIZE_MB=64; fi
if [ "$TMP_TABLE_SIZE_MB" -gt 1024 ]; then TMP_TABLE_SIZE_MB=1024; fi

INNODB_IO_THREADS=$(( VCPUS < 4 ? 4 : VCPUS ))
INNODB_READ_IO_THREADS=$INNODB_IO_THREADS
INNODB_WRITE_IO_THREADS=$INNODB_IO_THREADS

log "[INFO] Buffer pool size: ${INNODB_BUFFER_POOL_SIZE_MB}M"
log "[INFO] Buffer pool instances: ${INNODB_BUFFER_POOL_INSTANCES}"
log "[INFO] Log file size: ${INNODB_LOG_FILE_SIZE_MB}M"
log "[INFO] Max connections: ${MAX_CONNECTIONS}"
log "[INFO] tmp_table_size/max_heap_table_size: ${TMP_TABLE_SIZE_MB}M"
log "[INFO] InnoDB IO threads (read/write): ${INNODB_READ_IO_THREADS}/${INNODB_WRITE_IO_THREADS}"

if [ -f "${MARIADB_FRAG}" ]; then
  log "[RUN] backup existing MariaDB fragment -> ${MARIADB_FRAG}.bak.${TIMESTAMP}"
  [ "$DRY_RUN" -eq 0 ] && cp -a "${MARIADB_FRAG}" "${MARIADB_FRAG}.bak.${TIMESTAMP}"
fi

MARIADB_FRAG_TMP="${MARIADB_FRAG}.tmp"
cat > "${MARIADB_FRAG_TMP}" <<EOF
# universal generated - ${TIMESTAMP}
[mysqld]
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE_MB}M
innodb_buffer_pool_instances = ${INNODB_BUFFER_POOL_INSTANCES}
innodb_log_file_size = ${INNODB_LOG_FILE_SIZE_MB}M
innodb_read_io_threads = ${INNODB_READ_IO_THREADS}
innodb_write_io_threads = ${INNODB_WRITE_IO_THREADS}
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1
max_connections = ${MAX_CONNECTIONS}
tmp_table_size = ${TMP_TABLE_SIZE_MB}M
max_heap_table_size = ${TMP_TABLE_SIZE_MB}M
join_buffer_size = 2048K
query_cache_type = 0
query_cache_size = 0
# Tuned by universal_replaced_complete.sh - adjust as needed
EOF

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$(dirname "${MARIADB_FRAG}")"
  mv -f "${MARIADB_FRAG_TMP}" "${MARIADB_FRAG}"
  log "[OK] MariaDB config fragment written to ${MARIADB_FRAG}"
else
  log "[DRY] would write MariaDB config fragment -> ${MARIADB_FRAG}"
  rm -f "${MARIADB_FRAG_TMP}" || true
fi

log ""

# ------------------------------------------------------------------
# Step 6: FreeRADIUS thread pool tuning in radiusd.conf (backup first)
# ------------------------------------------------------------------
log "========================"
log " Step 6: Update radiusd.conf thread pool values"
log "------------------------"

RADIUS_PATHS=(/etc/freeradius/radiusd.conf /etc/freeradius/3.0/radiusd.conf /etc/raddb/radiusd.conf /etc/freeradius/3.2/radiusd.conf)
RADIUS_CONF=""
for p in "${RADIUS_PATHS[@]}"; do
  if [ -f "$p" ]; then
    RADIUS_CONF="$p"
    break
  fi
done

if [ -z "${RADIUS_CONF}" ]; then
  log "[WARN] radiusd.conf not found in common paths; skipping thread-pool edit."
else
  START_SERVERS=$(( VCPUS / 2 )); [ "$START_SERVERS" -lt 2 ] && START_SERVERS=2
  MAX_SERVERS=$(( VCPUS * 6 ))
  MIN_SPARE=$(( VCPUS / 2 )); [ "$MIN_SPARE" -lt 2 ] && MIN_SPARE=2
  MAX_SPARE=$(( VCPUS * 2 )); [ "$MAX_SPARE" -lt "$MIN_SPARE" ] && MAX_SPARE=$MIN_SPARE

  log "[RUN] Using radiusd.conf: ${RADIUS_CONF}"
  [ "$DRY_RUN" -eq 0 ] && cp -a "${RADIUS_CONF}" "${RADIUS_CONF}.bak.${TIMESTAMP}"
  TMP_RAD="${RADIUS_CONF}.new"
  awk -v s="${START_SERVERS}" -v m="${MAX_SERVERS}" -v minsp="${MIN_SPARE}" -v maxsp="${MAX_SPARE}" '
    BEGIN{inblock=0}
    {
      if($0 ~ /thread pool[[:space:]]*{/) { print; inblock=1; next }
      if(inblock && $0 ~ /^[[:space:]]*start_servers[[:space:]]*=/) { printf "    start_servers = %s\n", s; next }
      if(inblock && $0 ~ /^[[:space:]]*max_servers[[:space:]]*=/) { printf "    max_servers = %s\n", m; next }
      if(inblock && $0 ~ /^[[:space:]]*min_spare_servers[[:space:]]*=/) { printf "    min_spare_servers = %s\n", minsp; next }
      if(inblock && $0 ~ /^[[:space:]]*max_spare_servers[[:space:]]*=/) { printf "    max_spare_servers = %s\n", maxsp; next }
      if(inblock && $0 ~ /^}/) { inblock=0; print; next }
      print
    }
  ' "${RADIUS_CONF}" > "${TMP_RAD}" || true

  if [ "$DRY_RUN" -eq 0 ]; then
    mv -f "${TMP_RAD}" "${RADIUS_CONF}"
    log "[OK] radiusd.conf thread pool updated (backup: ${RADIUS_CONF}.bak.${TIMESTAMP})"
  else
    rm -f "${TMP_RAD}" || true
    log "[DRY] would update radiusd.conf thread pool"
  fi
fi

log ""

# ---------------------------------------------------------------------
# Step 7: PHP-FPM detection, tuning, slowlog setup, and IN-PLACE edits
# ---------------------------------------------------------------------
log "========================"
log " Step 7: PHP-FPM replacement (REPLACE existing directives in-place)"
log "------------------------"

PHP_VER_DETECTED="${PHP_VER_OVERRIDE:-}"
DETECTION_METHOD=""

detect_active_php_via_systemctl() {
  local svc_list svc_name ver
  svc_list=$(systemctl list-units --type=service --no-pager --no-legend | awk '{print $1}' | grep -E '^php[0-9]+(\.[0-9]+)?-fpm\.service$' || true)
  for svc_name in $svc_list; do
    # strip .service suffix
    local svc_clean="${svc_name%.service}"
    if systemctl is-active --quiet "$svc_clean"; then
      ver=$(echo "$svc_clean" | sed -E 's/^php([0-9]+(\.[0-9]+)?)-fpm$/\1/')
      echo "$ver"
      return 0
    fi
  done
  return 1
}

detect_php_via_cli_if_pool_exists() {
  if ! command -v php >/dev/null 2>&1; then
    return 1
  fi
  local cli_ver pool major pool_alt
  cli_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
  [ -z "$cli_ver" ] && return 1
  pool="/etc/php/${cli_ver}/fpm/pool.d/www.conf"
  if [ -f "$pool" ]; then
    echo "$cli_ver"; return 0
  fi
  major=$(echo "$cli_ver" | cut -d. -f1)
  pool_alt="/etc/php/${major}/fpm/pool.d/www.conf"
  if [ -f "$pool_alt" ]; then
    echo "$cli_ver"; return 0
  fi
  return 1
}

if [ -z "${PHP_VER_DETECTED}" ]; then
  if ver=$(detect_active_php_via_systemctl); then
    PHP_VER_DETECTED="$ver"; DETECTION_METHOD="systemctl-active"
  fi
fi
if [ -z "${PHP_VER_DETECTED}" ]; then
  if ver=$(detect_php_via_cli_if_pool_exists); then
    PHP_VER_DETECTED="$ver"; DETECTION_METHOD="cli-fallback-with-pool-check"
  fi
fi

if [ -z "${PHP_VER_DETECTED}" ]; then
  log "[WARN] Could not detect PHP-FPM version; set PHP_VER_OVERRIDE or start phpX.Y-fpm. Skipping PHP-FPM edit."
else
  POOL_CONF="/etc/php/${PHP_VER_DETECTED}/fpm/pool.d/www.conf"
  PHPFPM_SERVICE="php${PHP_VER_DETECTED}-fpm"
  SLOWLOG_PATH="/var/log/php${PHP_VER_DETECTED}-fpm/www-slow.log"
  if [ ! -f "$POOL_CONF" ]; then
    major=$(echo "$PHP_VER_DETECTED" | cut -d. -f1)
    alt_pool="/etc/php/${major}/fpm/pool.d/www.conf"
    alt_service="php${major}-fpm"
    alt_slowlog="/var/log/php${major}-fpm/www-slow.log"
    if [ -f "$alt_pool" ]; then
      POOL_CONF="$alt_pool"; PHPFPM_SERVICE="$alt_service"; SLOWLOG_PATH="$alt_slowlog"
    fi
  fi

  log "[INFO] Detected PHP version: ${PHP_VER_DETECTED} (method: ${DETECTION_METHOD:-unknown})"
  log "[INFO] Using POOL_CONF: ${POOL_CONF}"
  log "[INFO] Using PHPFPM_SERVICE: ${PHPFPM_SERVICE}"
  log "[INFO] Using SLOWLOG_PATH: ${SLOWLOG_PATH}"

  # Ensure slowlog file exists and has safe perms
  SLOWLOG_DIR="$(dirname "$SLOWLOG_PATH")"
  if [ "$DRY_RUN" -eq 0 ]; then
    [ -d "$SLOWLOG_DIR" ] || mkdir -p "$SLOWLOG_DIR"
    [ -f "$SLOWLOG_PATH" ] || touch "$SLOWLOG_PATH"
    if id -u "$FPM_USER" >/dev/null 2>&1; then
      chown -R "$FPM_USER":"$FPM_GROUP" "$SLOWLOG_DIR" || true
    fi
    chmod 750 "$SLOWLOG_DIR" || true
    chmod 640 "$SLOWLOG_PATH" || true
  else
    log "[DRY] would ensure slowlog dir/file and set perms"
  fi

  # Backup existing pool file
  PHPFPM_POOL_BAK="${CONF_BACKUP_DIR}/www.conf.bak.${TIMESTAMP}"
  if [ -f "$POOL_CONF" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then cp -a "$POOL_CONF" "$PHPFPM_POOL_BAK"; fi
    log "[OK] Backed up pool config -> ${PHPFPM_POOL_BAK}"
  else
    log "[WARN] PHP-FPM pool file not found at ${POOL_CONF}; skipping pm.* replacement"
  fi

  # -------------------------
  # Remove existing AUTOTUNE block (if present)
  # -------------------------
  if [ -f "$POOL_CONF" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      if command -v perl >/dev/null 2>&1; then
        # Remove inclusive block between lines containing AUTOTUNE BEGIN/END (handles leading ; or #)
        perl -0777 -pe 's/^[\t ]*[;#]*[\t ]*=== AUTOTUNE BEGIN ===.*?^[\t ]*[;#]*[\t ]*=== AUTOTUNE END ===\s*\n?//gms' -i "$POOL_CONF" \
          && log "[OK] removed existing AUTOTUNE block from ${POOL_CONF} (if present)"
      else
        # Fallback using awk/sed: remove lines between markers (less flexible but works for typical cases)
        awk 'BEGIN{skip=0}
          {
            if($0 ~ /^[[:space:]]*[;#]*[[:space:]]*=== AUTOTUNE BEGIN ===/) { skip=1; next }
            if($0 ~ /^[[:space:]]*[;#]*[[:space:]]*=== AUTOTUNE END ===/) { skip=0; next }
            if(!skip) print
          }' "$POOL_CONF" > "${POOL_CONF}.noautotune" && mv -f "${POOL_CONF}.noautotune" "$POOL_CONF" \
          && log "[OK] removed AUTOTUNE block (fallback) from ${POOL_CONF} (if present)"
      fi
    else
      log "[DRY] would remove existing AUTOTUNE block from ${POOL_CONF} (if present)"
    fi
  fi

  # If pool file exists, compute values and do in-place replacements
  if [ -f "$POOL_CONF" ]; then
    # Compute recommended values
    CPU_CORES=$(nproc --all 2>/dev/null || echo 1)
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    RESERVE_BY_PERCENT=$(awk -v r="$TOTAL_RAM_MB" 'BEGIN{printf "%.0f", r*0.15}')
    RESERVE_MB=$(( RESERVE_BY_PERCENT + CPU_CORES*200 ))
    [ "$RESERVE_MB" -lt 1024 ] && RESERVE_MB=1024
    AVAILABLE_FOR_PHP_MB=$(( TOTAL_RAM_MB - RESERVE_MB ))
    [ "$AVAILABLE_FOR_PHP_MB" -lt 256 ] && AVAILABLE_FOR_PHP_MB=256

    # Determine avg worker RSS (best-effort)
    PHPFPM_PROCNAMES=("php-fpm${PHP_VER_DETECTED}" "php${PHP_VER_DETECTED}-fpm" "php-fpm" "php7.4-fpm" "php8.1-fpm" "php8.2-fpm")
    FOUND_PROCNAME=""
    for pn in "${PHPFPM_PROCNAMES[@]}"; do
      if pgrep -x "$pn" >/dev/null 2>&1; then FOUND_PROCNAME="$pn"; break; fi
    done
    AVG_RSS_KB=0
    if [ -n "$FOUND_PROCNAME" ]; then
      AVG_RSS_KB=$(ps --no-headers -o rss -C "$FOUND_PROCNAME" 2>/dev/null | awk '{s+=$1;n++}END{if(n)printf "%.0f",s/n;else print 0}')
    fi
    if [ -z "${AVG_RSS_KB}" ] || [ "$AVG_RSS_KB" -le 0 ]; then
      AVG_RSS_MB=50
      AVG_RSS_KB=$((AVG_RSS_MB * 1024))
    else
      AVG_RSS_MB=$(( (AVG_RSS_KB + 1023) / 1024 ))
    fi

    MAX_CHILDREN=$(( AVAILABLE_FOR_PHP_MB / AVG_RSS_MB ))
    [ "$MAX_CHILDREN" -lt 2 ] && MAX_CHILDREN=2
    [ "$MAX_CHILDREN" -gt 1000 ] && MAX_CHILDREN=1000
    PM_START=$(( MAX_CHILDREN * 20 / 100 ))
    PM_MIN=$(( MAX_CHILDREN * 10 / 100 ))
    PM_MAX=$(( MAX_CHILDREN * 30 / 100 ))
    [ "$PM_START" -lt 2 ] && PM_START=2
    [ "$PM_MIN" -lt 1 ] && PM_MIN=1
    [ "$PM_MAX" -lt 2 ] && PM_MAX=2

    # -------------------------
    # In-place replacement API
    # -------------------------
    ensure_directive() {
      local file="$1" key="$2" val="$3" anchor="$4"
      local val_esc
      val_esc=$(printf '%s' "$val" | sed -e 's|[\/&]|\\&|g')
      # Replace any existing line (commented or not)
      if grep -qE "^[[:space:]]*[;#]?[[:space:]]*${key}[[:space:]]*=" "$file"; then
        if [ "$DRY_RUN" -eq 0 ]; then
          sed -i -E "s|^[[:space:]]*[;#]?[[:space:]]*(${key})[[:space:]]*=.*|\1 = ${val_esc}|" "$file"
          log "[OK] replaced ${key} in ${file}"
        else
          log "[DRY] would replace ${key} = ${val} in ${file}"
        fi
      else
        # No existing line — insert after anchor (anchor is anchor key, e.g., 'pm' for 'pm = dynamic')
        if [ -n "$anchor" ] && grep -qE "^[[:space:]]*${anchor}[[:space:]]*=" "$file"; then
          if [ "$DRY_RUN" -eq 0 ]; then
            awk -v a="$anchor" -v newline="${key} = ${val}" '{
              print;
              if(!inserted && $0 ~ "^[[:space:]]*"a"[[:space:]]*="){ print newline; inserted=1 }
            } END{ if(!inserted) print newline }' "$file" > "${file}.tmp" && mv -f "${file}.tmp" "$file"
            log "[OK] inserted ${key} after ${anchor} in ${file}"
          else
            log "[DRY] would insert ${key} = ${val} after ${anchor} in ${file}"
          fi
        else
          if [ "$DRY_RUN" -eq 0 ]; then
            echo "${key} = ${val}" >> "$file"
            log "[OK] appended ${key} to ${file}"
          else
            log "[DRY] would append ${key} = ${val} to ${file}"
          fi
        fi
      fi
    }

    # Remove commented duplicates of pm.* and slowlog/status lines (clean up leftovers)
    if [ "$DRY_RUN" -eq 0 ]; then
      sed -i -E '/^[[:space:]]*[;#][[:space:]]*(pm\.max_children|pm\.start_servers|pm\.min_spare_servers|pm\.max_spare_servers|pm\.max_requests|request_slowlog_timeout|slowlog|pm\.status_path|catch_workers_output)[[:space:]]*=.*$/d' "$POOL_CONF" || true
    else
      log "[DRY] would remove commented duplicates of pm.* and slowlog lines in ${POOL_CONF}"
    fi

    # Ensure directives in-place, using anchor "pm" to insert near pm = dynamic if needed
    ensure_directive "$POOL_CONF" "pm" "dynamic" ""
    ensure_directive "$POOL_CONF" "pm.max_children" "${MAX_CHILDREN}" "pm"
    ensure_directive "$POOL_CONF" "pm.start_servers" "${PM_START}" "pm"
    ensure_directive "$POOL_CONF" "pm.min_spare_servers" "${PM_MIN}" "pm"
    ensure_directive "$POOL_CONF" "pm.max_spare_servers" "${PM_MAX}" "pm"
    ensure_directive "$POOL_CONF" "pm.max_requests" "${PM_MAX_REQUESTS}" "pm"
    ensure_directive "$POOL_CONF" "request_slowlog_timeout" "${REQUEST_SLOWLOG_TIMEOUT}" "pm"
    ensure_directive "$POOL_CONF" "slowlog" "${SLOWLOG_PATH}" "pm"
    ensure_directive "$POOL_CONF" "pm.status_path" "${STATUS_PATH}" "pm"
    ensure_directive "$POOL_CONF" "catch_workers_output" "${CATCH_WORKERS_OUTPUT}" "pm"

    if [ "$DRY_RUN" -eq 0 ]; then
      chmod 640 "$POOL_CONF" || true
      log "[OK] PHP-FPM pool file updated in-place (max_children=${MAX_CHILDREN})"
    else
      log "[DRY] would update pool file in-place (max_children=${MAX_CHILDREN})"
    fi

    # Reload/restart php-fpm
    if [ "$DRY_RUN" -eq 0 ]; then
      if systemctl reload "$PHPFPM_SERVICE" >/dev/null 2>&1; then
        log "[OK] Reloaded $PHPFPM_SERVICE successfully."
      else
        log "[WARN] Reload failed; attempting restart..."
        if systemctl restart "$PHPFPM_SERVICE" >/dev/null 2>&1; then
          log "[OK] Restarted $PHPFPM_SERVICE successfully."
        else
          log "[ERROR] Restart failed, please check $PHPFPM_SERVICE and logs manually."
        fi
      fi
    else
      log "[DRY] would reload/restart $PHPFPM_SERVICE"
    fi

    # Write suggestion report
    cat > "$PHPFPM_SUGGESTION_FILE" <<EOF
PHP-FPM replacement report — $(date)
----------------------------------
Detection method  : ${DETECTION_METHOD:-unknown}
PHP-FPM service   : ${PHPFPM_SERVICE}
Detected process  : ${FOUND_PROCNAME:-unknown}
Detected PHP ver  : ${PHP_VER_DETECTED}
CPU cores         : ${CPU_CORES}
Total RAM         : ${TOTAL_RAM_MB} MB
Reserved (OS/etc) : ${RESERVE_MB} MB
Available for PHP : ${AVAILABLE_FOR_PHP_MB} MB
Avg worker RSS    : ${AVG_RSS_MB} MB
pm.max_children   : ${MAX_CHILDREN}
start/min/max     : ${PM_START} / ${PM_MIN} / ${PM_MAX}
pm.max_requests   : ${PM_MAX_REQUESTS}
Slowlog path      : ${SLOWLOG_PATH}
Status path       : ${STATUS_PATH}

Notes:
- This script REPLACES existing pm.* and slowlog/status lines in-place (no AUTOTUNE block).
- Existing AUTOTUNE markers (=== AUTOTUNE BEGIN === / END ===) are removed prior to edits.
- If a directive did not exist it was added after the "pm = dynamic" anchor where possible.
EOF
    [ "$DRY_RUN" -eq 0 ] && chmod 600 "$PHPFPM_SUGGESTION_FILE"
    log "[OK] Wrote suggestion file to $PHPFPM_SUGGESTION_FILE"
  fi
fi

log ""

# -------------------------------------------------------------
# Step 8: Restart services (MariaDB/mysql, FreeRADIUS, php-fpm)
# -------------------------------------------------------------
log "========================"
log " Step 8: Restart services to apply changes"
log "------------------------"

restart_and_check() {
  local svc="$1"
  local present=0
  local restarted=0

  if systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -qi "^${svc}.service$"; then
    present=1
  fi

  log "[RUN] restart ${svc} (present=${present})"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY] would restart ${svc}"
    return 0
  fi

  if systemctl restart "${svc}" >/dev/null 2>&1; then
    restarted=1
  else
    if command -v service >/dev/null 2>&1; then
      if service "${svc}" restart >/dev/null 2>&1; then
        restarted=1
      fi
    fi
  fi

  if [ "$restarted" -eq 1 ]; then
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
      log "[OK] ${svc} is active"
    else
      if command -v service >/dev/null 2>&1 && service "${svc}" status >/dev/null 2>&1; then
        log "[OK] ${svc} status reports running via SysV"
      else
        log "[WARN] ${svc} restarted but status not confirmed; check: journalctl -u ${svc} -n 200 --no-pager"
      fi
    fi
    return 0
  else
    log "[ERROR] failed to restart ${svc} via systemctl and service; verify service name and packaging"
    return 1
  fi
}

MARIADB_RESTARTED=0
for candidate in mariadb mysql mysqld; do
  if restart_and_check "$candidate"; then
    MARIADB_RESTARTED=1
    break
  fi
done
if [ "$MARIADB_RESTARTED" -eq 0 ]; then
  log "[WARN] MariaDB/MySQL restart not confirmed; ensure correct service name (mariadb/mysql/mysqld)"
fi

RAD_RESTARTED=0
for candidate in freeradius radiusd; do
  if restart_and_check "$candidate"; then
    RAD_RESTARTED=1
    break
  fi
done
if [ "$RAD_RESTARTED" -eq 0 ]; then
  log "[WARN] FreeRADIUS restart not confirmed; check OS packaging (freeradius or radiusd)"
fi

if [ -n "${PHPFPM_SERVICE:-}" ]; then
  restart_and_check "$PHPFPM_SERVICE"
fi

PHP_FPM_UNITS=$(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' || true)
if [ -n "$PHP_FPM_UNITS" ]; then
  for u in $PHP_FPM_UNITS; do
    svcname="${u%.service}"
    restart_and_check "$svcname"
  done
else
  for ver in 8.2 8.1 8.0 7.4 7.3; do
    restart_and_check "php${ver}-fpm"
  done
fi

log ""

# ----------------------------------
# Step 9: Summary and logs
# ----------------------------------
log "========================"
log " Summary"
log "------------------------"
log "1) MariaDB config fragment: ${MARIADB_FRAG}"
log "2) radiusd.conf updated at: ${RADIUS_CONF:-<not-found>}"
log "3) php-fpm pool edited in-place: ${POOL_CONF:-<not-found>}"
log "4) Backups directory: ${BACKUP_BASE}"
log "5) Run log: ${LOG}"
log ""
log "Completed universal_replaced_complete run. Review the log and service journals if any step reported warnings or errors."
# release lock implicitly on script exit
exit 0
