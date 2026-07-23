#!/bin/bash
# ---------------------------------------------------------------------------------
# universal2_replaced_complete.sh - Universal autotune & in-place PHP-FPM edits
# - Backups, MariaDB tuning fragment, index ensures, FreeRADIUS tuning
# - PHP-FPM: REPLACE existing pm.* and slowlog/status/catch directives IN-PLACE
# - Removes any existing AUTOTUNE block before edits
# - Safe --dry-run support, lock to avoid concurrent runs
# - Heavily commented where important (you requested comments)
#
# v2 (2026-07-14):
# - No more restart-everything: MariaDB & Valkey tuned LIVE (SET GLOBAL /
#   valkey-cli), PHP-FPM reloaded only if its pool changed (after php-fpm -t),
#   FreeRADIUS restarted only if radiusd.conf changed AND passes -XC validation
# - Backup retention now keeps the newest KEEP runs (was: newest 3 files,
#   which deleted same-run backups and mis-sorted cp -a preserved mtimes)
# - Dropped innodb_buffer_pool_instances (ignored since MariaDB 10.5),
#   max_connections right-sized to observed load, old run logs pruned
#
# v3 (2026-07-14): CAPACITY MODEL - one sizing block scales every component
#   from 2 vCPU / 2 GB to 16 vCPU / 16 GB (~5,000 concurrent users at top
#   tier). Copy this script unchanged to any size server; it self-sizes.
#
# v3.1 (2026-07-17): Step 6b ensures buffered accounting wiring (default
#   site -> detail file -> buffered-sql -> SQL) so accounting survives DB
#   stalls/restarts; validated with -XC, rolled back on failure, restart
#   reuses the changed-only logic. Idempotent on already-wired servers.
#
# v3.2 (2026-07-17): Step 6c appends the /usr/bin systemctl/supervisorctl
#   sudoers entries the panel actually invokes (plus the umbrella
#   "openvpn" unit); validated with visudo -c, restored on failure.
#
# v3.3 (2026-07-23): the buffered-sql site now acknowledges Accounting-On/
#   Off records whose bulk close query fails (a NAS-reboot record could
#   jam the reader's retry loop and silently freeze accounting for hours);
#   Step 6d installs a radacct-watchdog cron that spots a frozen
#   detail.work and auto-applies the unjam (stop, set work file aside,
#   start). Installers updated to write the same buffered-sql site.
#
# v3.3.1 (2026-07-23): sql { fail = 1 } in the buffered-sql accounting
#   section - the default action for a failed module is to return from
#   the section, so the v3.3 if (fail) Accounting-On/Off check was never
#   reached and a NAS reboot jammed the reader again despite the fix.
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

# Prune old per-run logs so /var/log does not fill up over time
find /var/log -maxdepth 1 -name 'universal_*.log' -mtime +30 -delete 2>/dev/null || true

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

# ---------------------------------------------------------------
# Legacy cleanup: update_memory_config.sh is no longer part of the
# stack (this script replaces it). Remove its file and cron entry
# if a previous install left them behind. No-op on clean machines.
# ---------------------------------------------------------------
if [ -f /usr/local/bin/update_memory_config.sh ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    rm -f /usr/local/bin/update_memory_config.sh || true
    log "[OK] removed legacy /usr/local/bin/update_memory_config.sh"
  else
    log "[DRY] would remove legacy /usr/local/bin/update_memory_config.sh"
  fi
fi
if crontab -l 2>/dev/null | grep -q 'update_memory_config\.sh'; then
  if [ "$DRY_RUN" -eq 0 ]; then
    crontab -l 2>/dev/null | grep -v 'update_memory_config\.sh' | crontab - || true
    log "[OK] removed legacy update_memory_config.sh cron entry"
  else
    log "[DRY] would remove legacy update_memory_config.sh cron entry"
  fi
fi

# =====================================================================
# CAPACITY MODEL (v3, 2026-07-14) - single source of sizing truth.
# Scales the whole stack from 2 vCPU / 2 GB to 16 vCPU / 16 GB.
# Design target at the top tier: ~5,000 concurrent hotspot users
# (3,500 measured weekend peak + headroom).
#
# RAM budget: OS 12% (min 384M) | InnoDB pool 25% (384M..4G; the radius
# DB is small - worker count, not cache, is the capacity currency here) |
# Valkey 10% (128M..2G) | remainder -> PHP-FPM at ~16 MB per worker.
# Worker RSS (~57MB) is mostly SHARED opcache; measured private cost is
# 8-20 MB. The vendor portal long-polls payment status with usleep()
# (vendor report issue #4), pinning one worker per waiting payer, so
# PHP-FPM workers are the scarce resource under load.
#
# Computed values for the full VM lineup (verify with --dry-run on deploy):
#   TIER      pool   valkey  workers  rad-thr  max_conn  ~users
#   2C/2G     384M   199M      56       12       150      ~350
#   4C/4G     896M   392M     118       24       202     ~1000
#   4C/8G    1920M   794M     231       24       315     ~1500
#   8C/8G    1920M   794M     231       48       339     ~2200
#   8C/12G   2944M  1196M     343       48       451     ~3000
#   12C/12G  2944M  1196M     343       72       475     ~3500
#   12C/16G  3968M  1598M     457       72       589     ~4500
#   16C/16G  3968M  1598M     457       96       613     ~5000
# RAM sets worker count (payment-surge absorption); vCPUs set RADIUS
# threads and query throughput. Asymmetric tiers (4C/8G, 8C/12G,
# 12C/16G) are handled naturally: sleeping pollers cost RAM, not CPU.
# =====================================================================
OS_RESERVE_MB=$(( RAM_MB * 12 / 100 ))
[ "$OS_RESERVE_MB" -lt 384 ] && OS_RESERVE_MB=384

POOL_MB=$(( RAM_MB * 25 / 100 ))
[ "$POOL_MB" -lt 384 ] && POOL_MB=384
[ "$POOL_MB" -gt 4096 ] && POOL_MB=4096
POOL_MB=$(( POOL_MB / 128 * 128 ))                 # 128M granularity
MARIADB_FOOTPRINT_MB=$(( POOL_MB * 13 / 10 ))      # pool + ~30% engine overhead

VALKEY_MB=$(( RAM_MB * 10 / 100 ))
[ "$VALKEY_MB" -lt 128 ] && VALKEY_MB=128
[ "$VALKEY_MB" -gt 2048 ] && VALKEY_MB=2048

PHP_BUDGET_MB=$(( RAM_MB - OS_RESERVE_MB - MARIADB_FOOTPRINT_MB - VALKEY_MB ))
[ "$PHP_BUDGET_MB" -lt 256 ] && PHP_BUDGET_MB=256
WORKER_COST_MB=16
MAX_CHILDREN=$(( PHP_BUDGET_MB / WORKER_COST_MB ))
[ "$MAX_CHILDREN" -lt 32 ] && MAX_CHILDREN=32
[ "$MAX_CHILDREN" -gt 480 ] && MAX_CHILDREN=480

RAD_MAX_SERVERS=$(( VCPUS * 6 ))
[ "$RAD_MAX_SERVERS" -lt 12 ] && RAD_MAX_SERVERS=12
[ "$RAD_MAX_SERVERS" -gt 128 ] && RAD_MAX_SERVERS=128

# Every busy fpm worker + every RADIUS thread can hold one DB connection.
MAX_CONNECTIONS=$(( MAX_CHILDREN + RAD_MAX_SERVERS + 60 ))
[ "$MAX_CONNECTIONS" -lt 150 ] && MAX_CONNECTIONS=150
[ "$MAX_CONNECTIONS" -gt 800 ] && MAX_CONNECTIONS=800

log "[MODEL] os_reserve=${OS_RESERVE_MB}M pool=${POOL_MB}M valkey=${VALKEY_MB}M php_budget=${PHP_BUDGET_MB}M"
log "[MODEL] fpm_max_children=${MAX_CHILDREN} rad_max_servers=${RAD_MAX_SERVERS} max_connections=${MAX_CONNECTIONS}"
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
  # Retain the newest KEEP *runs* (grouped by their _YYYYmmdd_HHMMSS stamp),
  # not the newest KEEP files: each run writes several files, and cp -a
  # preserves source mtimes, so sorting raw files by mtime deleted fresh
  # backups while keeping stale ones. Timestamps sort correctly as strings.
  local dir="$1" stamps keep_list s
  stamps=$(find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
             | grep -oE '[0-9]{8}_[0-9]{6}' | sort -ur || true)
  [ -n "$stamps" ] || return 0
  keep_list=$(printf '%s\n' "$stamps" | head -n "$KEEP")
  for s in $stamps; do
    if ! printf '%s\n' "$keep_list" | grep -qx "$s"; then
      find "$dir" -maxdepth 1 -type f -name "*${s}*" | while read -r old; do
        [ -n "$old" ] || continue
        if [ "$DRY_RUN" -eq 0 ]; then rm -f "$old" || true; fi
        log "[REMOVED] $old"
      done || true
    fi
  done
}

prune_baks() {
  # Keep the newest KEEP "<file>.bak.<TIMESTAMP>" copies written next to a
  # live config. Same string-sort trick as remove_old: the stamp sorts
  # correctly lexically, so the current run's backup is always kept and the
  # FreeRADIUS rollback path can never be pruned away. Without this, the
  # daily + @reboot crons would grow these side-by-side backups unbounded.
  local file="$1" old
  find "$(dirname "$file")" -maxdepth 1 -name "$(basename "$file").bak.*" -printf '%f\n' 2>/dev/null \
    | sort -r | tail -n +"$((KEEP + 1))" | while read -r old; do
      [ -n "$old" ] || continue
      if [ "$DRY_RUN" -eq 0 ]; then rm -f "$(dirname "$file")/$old" || true; fi
      log "[REMOVED] $(dirname "$file")/$old"
    done || true
}

log "========================"
log " Step 3: Backup retention - keep last ${KEEP}"
log "------------------------"
remove_old "${DB_BACKUP_DIR}"
remove_old "${CONF_BACKUP_DIR}"
log ""

# ----------------------------------------------------------------------
# Step 4: Schema adjustments - indexes and safe column modifications
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

# All sizing comes from the CAPACITY MODEL block near the top.
INNODB_BUFFER_POOL_SIZE_MB=$POOL_MB
INNODB_BUFFER_POOL_SIZE_BYTES=$(( POOL_MB * 1024 * 1024 ))

# NOTE: innodb_buffer_pool_instances was removed here - MariaDB 10.5+
# uses a single buffer pool and silently ignores that variable.
# NOTE: this 10.11 build refuses to GROW the pool via SET GLOBAL (warning,
# value unchanged); shrinking works. Growth applies at the next restart.

LOG_FILE_SIZE_BYTES=$(( INNODB_BUFFER_POOL_SIZE_BYTES / 4 ))
MAX_LOG_BYTES=$((1 * 1024 * 1024 * 1024))
if [ "$LOG_FILE_SIZE_BYTES" -gt "$MAX_LOG_BYTES" ]; then LOG_FILE_SIZE_BYTES=$MAX_LOG_BYTES; fi
ROUND_16MB=$((16 * 1024 * 1024))
INNODB_LOG_FILE_SIZE_BYTES=$(( (LOG_FILE_SIZE_BYTES / ROUND_16MB) * ROUND_16MB ))
[ "$INNODB_LOG_FILE_SIZE_BYTES" -lt $((96 * 1024 * 1024)) ] && INNODB_LOG_FILE_SIZE_BYTES=$((96 * 1024 * 1024))
INNODB_LOG_FILE_SIZE_MB=$(( INNODB_LOG_FILE_SIZE_BYTES / 1024 / 1024 ))

TMP_TABLE_SIZE_MB=$(( INNODB_BUFFER_POOL_SIZE_MB / 8 ))
if [ "$TMP_TABLE_SIZE_MB" -lt 32 ]; then TMP_TABLE_SIZE_MB=32; fi
if [ "$TMP_TABLE_SIZE_MB" -gt 512 ]; then TMP_TABLE_SIZE_MB=512; fi

INNODB_IO_THREADS=$(( VCPUS < 4 ? 4 : VCPUS ))
INNODB_READ_IO_THREADS=$INNODB_IO_THREADS
INNODB_WRITE_IO_THREADS=$INNODB_IO_THREADS

log "[INFO] Buffer pool size: ${INNODB_BUFFER_POOL_SIZE_MB}M"
log "[INFO] Log file size: ${INNODB_LOG_FILE_SIZE_MB}M"
log "[INFO] Max connections: ${MAX_CONNECTIONS}"
log "[INFO] tmp_table_size/max_heap_table_size: ${TMP_TABLE_SIZE_MB}M"
log "[INFO] InnoDB IO threads (read/write): ${INNODB_READ_IO_THREADS}/${INNODB_WRITE_IO_THREADS}"

if [ -f "${MARIADB_FRAG}" ]; then
  log "[RUN] backup existing MariaDB fragment -> ${MARIADB_FRAG}.bak.${TIMESTAMP}"
  [ "$DRY_RUN" -eq 0 ] && cp -a "${MARIADB_FRAG}" "${MARIADB_FRAG}.bak.${TIMESTAMP}"
  prune_baks "${MARIADB_FRAG}"
fi

MARIADB_FRAG_TMP="${MARIADB_FRAG}.tmp"
cat > "${MARIADB_FRAG_TMP}" <<EOF
# universal generated - ${TIMESTAMP}
[mysqld]
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE_MB}M
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

  # Apply the tunables live: on MariaDB 10.11 every one of these is dynamic
  # (including online buffer pool and redo log resize), so a restart -- and
  # the cold-cache morning that follows it -- is unnecessary. The fragment
  # above only guarantees persistence across the next natural restart.
  if "${MYSQL_CMD[@]}" -e "
      SET GLOBAL innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE_BYTES};
      SET GLOBAL innodb_log_file_size = ${INNODB_LOG_FILE_SIZE_BYTES};
      SET GLOBAL max_connections = ${MAX_CONNECTIONS};
      SET GLOBAL tmp_table_size = $(( TMP_TABLE_SIZE_MB * 1024 * 1024 ));
      SET GLOBAL max_heap_table_size = $(( TMP_TABLE_SIZE_MB * 1024 * 1024 ));
      SET GLOBAL innodb_flush_log_at_trx_commit = 2;
  " 2>>"${LOG}"; then
    log "[OK] dynamic MariaDB settings applied live -- no restart required"
  else
    log "[WARN] live SET GLOBAL failed; settings apply at next MariaDB restart"
  fi
  log "[INFO] innodb_read/write_io_threads are static and apply at the next planned restart"
else
  log "[DRY] would write MariaDB config fragment -> ${MARIADB_FRAG}"
  log "[DRY] would apply dynamic settings live via SET GLOBAL (no restart)"
  rm -f "${MARIADB_FRAG_TMP}" || true
fi

log ""

# -----------------------------------------------------
# Step 5b: Compute and apply Valkey tuning
# -----------------------------------------------------
log "========================"
log " Step 5b: Valkey tuning (maxmemory & volatile-lru)"
log "------------------------"

VALKEY_CONF="/etc/valkey/valkey.conf"
if [ -f "$VALKEY_CONF" ]; then
  # VALKEY_MB comes from the CAPACITY MODEL block.
  log "[INFO] Valkey maxmemory: ${VALKEY_MB}M"
  
  if [ "$DRY_RUN" -eq 0 ]; then
    cp -a "$VALKEY_CONF" "${VALKEY_CONF}.bak.${TIMESTAMP}"
    prune_baks "$VALKEY_CONF"
    sed -i -E "s/^#?maxmemory .*/maxmemory ${VALKEY_MB}mb/" "$VALKEY_CONF"
    if ! grep -q "^maxmemory-policy" "$VALKEY_CONF"; then
      echo "maxmemory-policy volatile-lru" >> "$VALKEY_CONF"
    fi
    log "[OK] Valkey configured with maxmemory ${VALKEY_MB}mb and volatile-lru"

    # Apply live via valkey-cli so no restart (and no cache flush) is needed;
    # the config file edit above keeps the value across future restarts.
    # NOTE: valkey-cli exits 0 even when the server replies ERR (this box
    # rename-disables CONFIG), so verify the live value via INFO instead of
    # trusting the exit code.
    if command -v valkey-cli >/dev/null 2>&1; then
      valkey-cli CONFIG SET maxmemory "${VALKEY_MB}mb" >/dev/null 2>&1 || true
      valkey-cli CONFIG SET maxmemory-policy volatile-lru >/dev/null 2>&1 || true
      LIVE_MM=$(valkey-cli INFO memory 2>/dev/null | tr -d '\r' | awk -F: '/^maxmemory:/{print $2}')
      TARGET_MM=$(( VALKEY_MB * 1024 * 1024 ))
      if [ "${LIVE_MM:-0}" = "${TARGET_MM}" ]; then
        log "[OK] Valkey live maxmemory verified at ${VALKEY_MB}mb -- no restart required"
      else
        log "[WARN] Valkey live maxmemory=${LIVE_MM:-unknown} (target ${TARGET_MM}); CONFIG is disabled here -- new value applies at next Valkey restart"
      fi
    fi
  else
    log "[DRY] would tune Valkey maxmemory to ${VALKEY_MB}mb and volatile-lru (live via valkey-cli, no restart)"
  fi
else
  log "[WARN] Valkey config not found at $VALKEY_CONF, skipping"
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

RADIUS_CHANGED=0
if [ -z "${RADIUS_CONF}" ]; then
  log "[WARN] radiusd.conf not found in common paths; skipping thread-pool edit."
else
  START_SERVERS=$(( VCPUS / 2 )); [ "$START_SERVERS" -lt 2 ] && START_SERVERS=2
  MAX_SERVERS=$RAD_MAX_SERVERS   # from the CAPACITY MODEL ([12..128])
  MIN_SPARE=$(( VCPUS / 2 )); [ "$MIN_SPARE" -lt 2 ] && MIN_SPARE=2
  MAX_SPARE=$(( VCPUS * 2 )); [ "$MAX_SPARE" -lt "$MIN_SPARE" ] && MAX_SPARE=$MIN_SPARE

  log "[RUN] Using radiusd.conf: ${RADIUS_CONF}"
  [ "$DRY_RUN" -eq 0 ] && cp -a "${RADIUS_CONF}" "${RADIUS_CONF}.bak.${TIMESTAMP}"
  prune_baks "${RADIUS_CONF}"
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
    if cmp -s "${RADIUS_CONF}" "${TMP_RAD}"; then
      # Nothing to do -- values already match; avoids a pointless restart.
      rm -f "${TMP_RAD}" || true
      log "[OK] radiusd.conf thread pool already tuned; no change, no restart needed"
    else
      mv -f "${TMP_RAD}" "${RADIUS_CONF}"
      # Validate BEFORE deciding to restart; a broken config must never
      # reach a running RADIUS service. Roll back on validation failure.
      RAD_BIN="$(command -v freeradius || command -v radiusd || true)"
      if [ -n "${RAD_BIN}" ] && ! "${RAD_BIN}" -XC >/dev/null 2>&1; then
        log "[ERROR] new radiusd.conf FAILED validation (${RAD_BIN} -XC); restoring backup, skipping restart"
        cp -a "${RADIUS_CONF}.bak.${TIMESTAMP}" "${RADIUS_CONF}"
      else
        RADIUS_CHANGED=1
        log "[OK] radiusd.conf thread pool updated and validated (backup: ${RADIUS_CONF}.bak.${TIMESTAMP})"
      fi
    fi
  else
    rm -f "${TMP_RAD}" || true
    log "[DRY] would update radiusd.conf thread pool (validated with -XC, restart only if changed)"
  fi
fi

log ""

# ----------------------------------------------------------------------
# Step 6b: Ensure buffered accounting wiring (detail -> buffered-sql).
# The default site writes accounting to a local detail file and the
# buffered-sql virtual server replays it into SQL, so records survive
# MariaDB stalls/restarts. Mirrors the installers; idempotent, so
# already-wired servers see no change and no restart.
# ----------------------------------------------------------------------
log "========================"
log " Step 6b: Buffered accounting wiring (detail -> buffered-sql)"
log "------------------------"

if [ -z "${RADIUS_CONF}" ]; then
  log "[WARN] radiusd.conf not found; skipping buffered accounting wiring."
else
  RAD_ROOT="$(dirname "${RADIUS_CONF}")"
  BUFSQL_CHANGED=0
  BUFSQL_TOUCHED=()   # files backed up this run, restored on failed validation
  BUFSQL_NEW_LINKS=() # symlinks created this run, removed on failed validation

  # Desired detail module: a single-file writer buffered-sql can consume
  # (stock writes per-NAS/per-day files the reader ignores).
  DETAIL_MOD="${RAD_ROOT}/mods-available/detail"
  DETAIL_TMP="${DETAIL_MOD}.new"
  cat > "${DETAIL_TMP}" << 'EOF'
detail {
	filename = ${radacctdir}/detail
	header = "%t"
	permissions = 0600
	locking = yes
}
EOF

  # Desired buffered-sql site: tail the detail file, replay into SQL.
  BUFSQL_SITE="${RAD_ROOT}/sites-available/buffered-sql"
  BUFSQL_TMP="${BUFSQL_SITE}.new"
  cat > "${BUFSQL_TMP}" << 'EOF'
server buffered-sql {
	listen {
		type = detail
		filename = "${radacctdir}/detail"
		load_factor = 10
		track = yes
	}

	preacct {
		preprocess
	}

	accounting {
		#  fail = 1 overrides the default action for a failed sql
		#  (return), which would exit the section before the check
		#  below ever runs.
		sql {
			fail = 1
		}

		#  Accounting-On/Off makes sql run a bulk close-all-sessions
		#  query for the NAS. If that one query fails, the reader
		#  retries the record forever and jams every record queued
		#  behind it, so acknowledge and drop just these two types.
		#  Session records keep retrying until SQL accepts them -
		#  that is the point of the buffer.
		if (fail) {
			if (&Acct-Status-Type == Accounting-On || &Acct-Status-Type == Accounting-Off) {
				ok
			}
		}
	}
}
EOF

  # Desired default site, matching the installers exactly: -sql refs
  # enabled and the accounting section writing to detail only (SQL happens
  # in buffered-sql). Generated from the currently EFFECTIVE config -
  # sites-enabled/default if present (older installers left an edited
  # regular file there), else sites-available/default. Regeneration is
  # stable, so cmp below makes this a no-op on already-converted servers.
  RAD_DEFAULT_AVAIL="${RAD_ROOT}/sites-available/default"
  RAD_DEFAULT_LINK="${RAD_ROOT}/sites-enabled/default"
  RAD_DEFAULT_TMP=""
  if [ -f "${RAD_DEFAULT_LINK}" ]; then
    RAD_DEFAULT_SRC="${RAD_DEFAULT_LINK}"
  elif [ -f "${RAD_DEFAULT_AVAIL}" ]; then
    RAD_DEFAULT_SRC="${RAD_DEFAULT_AVAIL}"
  else
    RAD_DEFAULT_SRC=""
    log "[WARN] default site not found under ${RAD_ROOT}; accounting section left untouched"
  fi
  if [ -n "${RAD_DEFAULT_SRC}" ]; then
    RAD_DEFAULT_TMP="${RAD_DEFAULT_AVAIL}.new"
    sed 's/-sql/sql/g' "${RAD_DEFAULT_SRC}" | awk '
    BEGIN { skip = 0 }
    /^accounting[ \t]*{/ {
      print "accounting {"
      print "detail"
      print "exec"
      print "attr_filter.accounting_response"
      print "}"
      skip = 1; next
    }
    /^[ \t]*}/ { if (skip) { skip = 0; next } }
    !skip { print }
    ' > "${RAD_DEFAULT_TMP}" || true
  fi

  bufsql_install_if_changed() {
    # $1 = live file, $2 = desired temp file. Returns 0 if a change was
    # made (or would be, under --dry-run), 1 if already up to date.
    local live="$1" tmp="$2"
    if [ -f "${live}" ] && cmp -s "${live}" "${tmp}"; then
      rm -f "${tmp}" || true
      return 1
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
      if [ -f "${live}" ]; then
        cp -a "${live}" "${live}.bak.${TIMESTAMP}"
        prune_baks "${live}"
        BUFSQL_TOUCHED+=("${live}")
      fi
      mv -f "${tmp}" "${live}"
      log "[OK] updated ${live} (backup: ${live}.bak.${TIMESTAMP})"
    else
      rm -f "${tmp}" || true
      log "[DRY] would update ${live}"
    fi
    return 0
  }

  if bufsql_install_if_changed "${DETAIL_MOD}" "${DETAIL_TMP}"; then BUFSQL_CHANGED=1; fi
  if bufsql_install_if_changed "${BUFSQL_SITE}" "${BUFSQL_TMP}"; then BUFSQL_CHANGED=1; fi
  if [ -n "${RAD_DEFAULT_TMP}" ]; then
    if bufsql_install_if_changed "${RAD_DEFAULT_AVAIL}" "${RAD_DEFAULT_TMP}"; then BUFSQL_CHANGED=1; fi
    # Normalize sites-enabled/default back to the packaged symlink layout:
    # older installers replaced the symlink with an edited regular file.
    # The content now lives (converted) in sites-available/default.
    if [ ! -L "${RAD_DEFAULT_LINK}" ]; then
      if [ "$DRY_RUN" -eq 0 ]; then
        if [ -f "${RAD_DEFAULT_LINK}" ]; then
          cp -a "${RAD_DEFAULT_LINK}" "${RAD_DEFAULT_LINK}.bak.${TIMESTAMP}"
          prune_baks "${RAD_DEFAULT_LINK}"
          BUFSQL_TOUCHED+=("${RAD_DEFAULT_LINK}")
          rm -f "${RAD_DEFAULT_LINK}"
        else
          BUFSQL_NEW_LINKS+=("${RAD_DEFAULT_LINK}")
        fi
        ln -sf "${RAD_DEFAULT_AVAIL}" "${RAD_DEFAULT_LINK}"
        log "[OK] normalized ${RAD_DEFAULT_LINK} to a symlink -> ${RAD_DEFAULT_AVAIL}"
      else
        log "[DRY] would normalize ${RAD_DEFAULT_LINK} to a symlink -> ${RAD_DEFAULT_AVAIL}"
      fi
      BUFSQL_CHANGED=1
    fi
  fi

  # Enable the detail module and buffered-sql site if not already enabled.
  for pair in "mods-available/detail:mods-enabled/detail" "sites-available/buffered-sql:sites-enabled/buffered-sql"; do
    BUFSQL_SRC="${RAD_ROOT}/${pair%%:*}"
    BUFSQL_DST="${RAD_ROOT}/${pair##*:}"
    if [ ! -e "${BUFSQL_DST}" ]; then
      if [ "$DRY_RUN" -eq 0 ]; then
        ln -sf "${BUFSQL_SRC}" "${BUFSQL_DST}"
        BUFSQL_NEW_LINKS+=("${BUFSQL_DST}")
        log "[OK] enabled ${BUFSQL_DST}"
      else
        log "[DRY] would enable ${BUFSQL_DST}"
      fi
      BUFSQL_CHANGED=1
    fi
  done

  if [ "${BUFSQL_CHANGED}" -eq 0 ]; then
    log "[OK] buffered accounting already wired; no change, no restart"
  elif [ "$DRY_RUN" -eq 0 ]; then
    # Queue directory must exist before validation/first write.
    mkdir -p /var/log/freeradius/radacct 2>/dev/null || true
    if id freerad >/dev/null 2>&1; then
      chown freerad:freerad /var/log/freeradius/radacct 2>/dev/null || true
    fi

    # Validate BEFORE the restart at the end of the run; roll everything
    # back on failure so a broken config never reaches the service.
    RAD_BIN="$(command -v freeradius || command -v radiusd || true)"
    if [ -n "${RAD_BIN}" ] && ! "${RAD_BIN}" -XC >/dev/null 2>&1; then
      log "[ERROR] buffered accounting config FAILED validation (${RAD_BIN} -XC); rolling back"
      for f in "${BUFSQL_TOUCHED[@]}"; do
        # rm first: if the live path became a symlink this run, cp -a onto
        # it would write through the link instead of replacing it.
        if [ -f "${f}.bak.${TIMESTAMP}" ]; then rm -f "${f}"; cp -a "${f}.bak.${TIMESTAMP}" "${f}"; fi
      done
      for l in "${BUFSQL_NEW_LINKS[@]}"; do rm -f "${l}" || true; done
    else
      log "[OK] buffered accounting wiring applied and validated"
      RADIUS_CHANGED=1  # reuse the existing end-of-run FreeRADIUS restart
    fi
  else
    log "[DRY] would validate with -XC and restart FreeRADIUS if valid"
  fi
fi

log ""

# ----------------------------------------------------------------------
# Step 6c: Ensure the www-data sudoers entries the panel actually uses.
# The panel invokes systemctl by bare name (sudo's secure_path resolves
# it to /usr/bin/systemctl) and checks the umbrella "openvpn" unit; older
# installs only granted /bin/systemctl + openvpn@server, so the panel's
# status checks were denied and OpenVPN showed as stopped while running.
# Mirrors the installers' second sudoers block; idempotent.
# ----------------------------------------------------------------------
log "========================"
log " Step 6c: Panel sudoers entries (www-data)"
log "------------------------"

if grep -qF '/usr/bin/systemctl status openvpn' /etc/sudoers; then
  log "[OK] sudoers already has the /usr/bin entries; no change"
elif [ "$DRY_RUN" -eq 0 ]; then
  cp -a /etc/sudoers "/etc/sudoers.bak.${TIMESTAMP}"
  prune_baks /etc/sudoers
  cat >> /etc/sudoers << 'EOF'
www-data ALL=NOPASSWD: /usr/bin/systemctl start openvpn@server
www-data ALL=NOPASSWD: /usr/bin/systemctl stop openvpn@server
www-data ALL=NOPASSWD: /usr/bin/systemctl restart openvpn@server
www-data ALL=NOPASSWD: /usr/bin/systemctl status openvpn@server
www-data ALL=NOPASSWD: /usr/bin/systemctl reload openvpn@server
www-data ALL=NOPASSWD: /usr/bin/systemctl enable openvpn@server
www-data ALL=NOPASSWD: /usr/bin/systemctl disable openvpn@server
www-data ALL=NOPASSWD: /bin/systemctl start openvpn
www-data ALL=NOPASSWD: /bin/systemctl stop openvpn
www-data ALL=NOPASSWD: /bin/systemctl restart openvpn
www-data ALL=NOPASSWD: /bin/systemctl status openvpn
www-data ALL=NOPASSWD: /usr/bin/systemctl start openvpn
www-data ALL=NOPASSWD: /usr/bin/systemctl stop openvpn
www-data ALL=NOPASSWD: /usr/bin/systemctl restart openvpn
www-data ALL=NOPASSWD: /usr/bin/systemctl status openvpn
www-data ALL=NOPASSWD: /usr/bin/systemctl start freeradius
www-data ALL=NOPASSWD: /usr/bin/systemctl stop freeradius
www-data ALL=NOPASSWD: /usr/bin/systemctl restart freeradius
www-data ALL=NOPASSWD: /usr/bin/systemctl status freeradius
www-data ALL=NOPASSWD: /usr/bin/systemctl reload freeradius
www-data ALL=NOPASSWD: /usr/bin/systemctl enable freeradius
www-data ALL=NOPASSWD: /usr/bin/systemctl disable freeradius
www-data ALL=NOPASSWD: /usr/bin/supervisorctl stop all
www-data ALL=NOPASSWD: /usr/bin/supervisorctl reread
www-data ALL=NOPASSWD: /usr/bin/supervisorctl update
www-data ALL=NOPASSWD: /usr/bin/supervisorctl start all
www-data ALL=NOPASSWD: /usr/bin/supervisorctl restart all
www-data ALL=NOPASSWD: /usr/bin/supervisorctl status
www-data ALL=NOPASSWD: /usr/bin/systemctl restart supervisor
www-data ALL=NOPASSWD: /usr/bin/systemctl status ssh
EOF
  if visudo -c >/dev/null 2>&1; then
    log "[OK] appended /usr/bin sudoers entries for www-data (visudo -c validated; backup: /etc/sudoers.bak.${TIMESTAMP})"
  else
    cp -a "/etc/sudoers.bak.${TIMESTAMP}" /etc/sudoers
    log "[ERROR] sudoers FAILED visudo validation after append; restored backup"
  fi
else
  log "[DRY] would append /usr/bin systemctl/supervisorctl sudoers entries for www-data"
fi

log ""

# ----------------------------------------------------------------------
# Step 6d: radacct watchdog (auto-unjam a stalled detail reader).
# A healthy buffered-sql reader either has no detail.work (idle: the
# file is deleted once fully replayed) or keeps touching it as it marks
# processed entries (track = yes). A detail.work mtime frozen while
# FreeRADIUS is up means the reader is wedged (a record SQL keeps
# rejecting, or an unclean shutdown) and accounting silently stops
# reaching the panel. The watchdog applies the manual fix: stop, set
# the work file aside for post-mortem, start. Loss is bounded to that
# file - open sessions are rebuilt by their next interim update.
# Idempotent.
# ----------------------------------------------------------------------
log "========================"
log " Step 6d: radacct watchdog (auto-unjam stalled detail reader)"
log "------------------------"

if [ -z "${RADIUS_CONF}" ]; then
  log "[WARN] radiusd.conf not found; skipping radacct watchdog."
else
  WATCHDOG_BIN="/usr/local/sbin/radacct-watchdog.sh"
  WATCHDOG_CRON="/etc/cron.d/radacct-watchdog"
  WATCHDOG_CHANGED=0

  WATCHDOG_TMP="${WATCHDOG_BIN}.new"
  cat > "${WATCHDOG_TMP}" << 'WDOG'
#!/bin/bash
# Installed by universal.sh (Step 6d). Unjams the FreeRADIUS
# buffered-sql detail reader: a detail.work whose mtime is frozen for
# STALE_MIN minutes while the service is up means the reader is wedged
# and no accounting is reaching SQL. Stop, set the work file aside
# (kept for post-mortem), start; the reader resumes on a fresh queue
# and open sessions reappear on their next interim update.
set -u

WORK="/var/log/freeradius/radacct/detail.work"
WLOG="/var/log/radacct-watchdog.log"
STALE_MIN=15

exec 9>"/var/lock/radacct-watchdog.lock"
flock -n 9 || exit 0

SVC=""
for s in freeradius radiusd; do
  if systemctl is-active --quiet "$s" 2>/dev/null; then SVC="$s"; break; fi
done
[ -n "$SVC" ] || exit 0   # service stopped on purpose is not a jam
[ -f "$WORK" ] || exit 0  # no work file: reader idle and healthy

# find prints the path only when mtime is older than the cutoff
find "$WORK" -mmin "+${STALE_MIN}" 2>/dev/null | grep -q . || exit 0

TS="$(date +%Y%m%d_%H%M%S)"
echo "[$(date '+%F %T')] detail.work frozen >${STALE_MIN}m; unjamming (kept: ${WORK}.stuck.${TS})" >> "$WLOG"
systemctl stop "$SVC"
mv "$WORK" "${WORK}.stuck.${TS}"
systemctl start "$SVC"
echo "[$(date '+%F %T')] ${SVC} restarted; reader resumed on a fresh queue" >> "$WLOG"

# keep a week of post-mortem files
find "$(dirname "$WORK")" -maxdepth 1 -name 'detail.work.stuck.*' -mtime +7 -delete 2>/dev/null || true
WDOG

  WATCHDOG_CRON_TMP="${WATCHDOG_CRON}.new"
  cat > "${WATCHDOG_CRON_TMP}" << 'EOF'
# Installed by universal.sh (Step 6d): auto-unjam a stalled buffered-sql reader.
*/5 * * * * root /usr/local/sbin/radacct-watchdog.sh
EOF

  watchdog_install_if_changed() {
    # $1 = live file, $2 = desired temp file, $3 = mode. Returns 0 if a
    # change was made (or would be, under --dry-run), 1 if up to date.
    local live="$1" tmp="$2" mode="$3"
    if [ -f "${live}" ] && cmp -s "${live}" "${tmp}"; then
      rm -f "${tmp}" || true
      chmod "${mode}" "${live}" 2>/dev/null || true
      return 1
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
      mv -f "${tmp}" "${live}"
      chmod "${mode}" "${live}"
      log "[OK] installed ${live}"
    else
      rm -f "${tmp}" || true
      log "[DRY] would install ${live}"
    fi
    return 0
  }

  if watchdog_install_if_changed "${WATCHDOG_BIN}" "${WATCHDOG_TMP}" 0755; then WATCHDOG_CHANGED=1; fi
  if watchdog_install_if_changed "${WATCHDOG_CRON}" "${WATCHDOG_CRON_TMP}" 0644; then WATCHDOG_CHANGED=1; fi

  if [ "${WATCHDOG_CHANGED}" -eq 0 ]; then
    log "[OK] radacct watchdog already installed; no change"
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
    # Worker count comes from the CAPACITY MODEL block near the top
    # (MAX_CHILDREN = PHP_BUDGET_MB / WORKER_COST_MB, clamped [32..480]).
    # Do NOT size from measured RSS: worker RSS (~57MB) is mostly shared
    # opcache and undercounts capacity ~4x. The vendor portal long-polls
    # payment status with usleep() (vendor report issue #4), pinning one
    # worker per waiting payer - worker count IS the capacity currency.
    CPU_CORES=$VCPUS
    TOTAL_RAM_MB=$RAM_MB
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
        # No existing line - insert after anchor (anchor is anchor key, e.g., 'pm' for 'pm = dynamic')
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
    # Deeper accept queue for login bursts (default 511 drops under spikes)
    ensure_directive "$POOL_CONF" "listen.backlog" "1024" "pm"

    if [ "$DRY_RUN" -eq 0 ]; then
      chmod 640 "$POOL_CONF" || true
      log "[OK] PHP-FPM pool file updated in-place (max_children=${MAX_CHILDREN})"
    else
      log "[DRY] would update pool file in-place (max_children=${MAX_CHILDREN})"
    fi

    # Reload php-fpm ONLY if the pool file actually changed, and only after
    # php-fpm's own config test passes. A failed test restores the backup.
    if [ "$DRY_RUN" -eq 0 ]; then
      if [ -f "$PHPFPM_POOL_BAK" ] && cmp -s "$POOL_CONF" "$PHPFPM_POOL_BAK"; then
        log "[OK] pool config unchanged; skipping php-fpm reload"
      else
        FPM_BIN="$(command -v "php-fpm${PHP_VER_DETECTED}" || true)"
        if [ -n "$FPM_BIN" ] && ! "$FPM_BIN" -t >/dev/null 2>&1; then
          log "[ERROR] php-fpm config test FAILED; restoring ${PHPFPM_POOL_BAK}, skipping reload"
          cp -a "$PHPFPM_POOL_BAK" "$POOL_CONF"
        elif systemctl reload "$PHPFPM_SERVICE" >/dev/null 2>&1; then
          log "[OK] Reloaded $PHPFPM_SERVICE successfully (config test passed)."
        else
          log "[WARN] Reload failed; attempting restart..."
          if systemctl restart "$PHPFPM_SERVICE" >/dev/null 2>&1; then
            log "[OK] Restarted $PHPFPM_SERVICE successfully."
          else
            log "[ERROR] Restart failed, please check $PHPFPM_SERVICE and logs manually."
          fi
        fi
      fi
    else
      log "[DRY] would config-test and reload $PHPFPM_SERVICE only if pool file changed"
    fi

    # Write suggestion report
    cat > "$PHPFPM_SUGGESTION_FILE" <<EOF
PHP-FPM replacement report (capacity model v3) - $(date)
----------------------------------
Detection method  : ${DETECTION_METHOD:-unknown}
PHP-FPM service   : ${PHPFPM_SERVICE}
Detected PHP ver  : ${PHP_VER_DETECTED}
CPU cores         : ${CPU_CORES}
Total RAM         : ${TOTAL_RAM_MB} MB
OS reserve        : ${OS_RESERVE_MB} MB
MariaDB footprint : ${MARIADB_FOOTPRINT_MB} MB (pool ${POOL_MB}M x1.3)
Valkey cap        : ${VALKEY_MB} MB
PHP budget        : ${PHP_BUDGET_MB} MB @ ${WORKER_COST_MB} MB/worker
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
# Step 8: Conditional service application
#   MariaDB : tuned live via SET GLOBAL in Step 5 - never restarted here
#   Valkey  : tuned live via valkey-cli in Step 5b - never restarted here
#   PHP-FPM : reloaded in Step 7 only if its pool config changed
#   FreeRADIUS: restarted below only if radiusd.conf changed AND validated
# -------------------------------------------------------------
log "========================"
log " Step 8: Apply service changes (only what actually changed)"
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

log "[OK] MariaDB: dynamic settings already applied live (Step 5); no restart"
log "[OK] Valkey: settings already applied live (Step 5b); no restart"
log "[OK] PHP-FPM: reload handled in Step 7 (only when pool config changed)"

if [ "${RADIUS_CHANGED:-0}" -eq 1 ]; then
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
else
  log "[OK] FreeRADIUS: config unchanged (or rolled back); no restart"
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
