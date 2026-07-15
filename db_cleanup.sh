#!/bin/bash
# =========================================================================
# db_cleanup.sh (v3) - RADIUS / hotspot database retention & maintenance
#
#  - INTERACTIVE: when run from a terminal it asks, per category, how old
#    records must be before deletion, in shorthand: 12h, 2d, 1w, 3m
#    (hours/days/weeks/months). Enter keeps the default, 's' skips the
#    category. A summary + confirmation is shown before anything deletes.
#  - NON-INTERACTIVE: without a terminal (cron) or with --auto it runs
#    the defaults below, exactly like before. The 04:30 cron needs no flag.
#  - Batched deletes, real error handling (exits non-zero on SQL errors),
#    zombie radacct closer, failed_jobs purge, ANALYZE + conditional
#    OPTIMIZE, flock guard, --dry-run.
#
# Usage: db_cleanup.sh [--dry-run] [--auto] [--ask]
#   --dry-run : show what would be deleted, change nothing
#   --auto    : never prompt, use the defaults below
#   --ask     : force prompts even when stdin is not a terminal
# =========================================================================
set -euo pipefail

# ----------------------------- Configuration -----------------------------
DB_NAME="radius"
DB_USER="root"                       # uses unix_socket auth -> run as root
MYSQL_BIN=$(command -v mysql)
LOG_FILE="/var/log/radius_db_cleanup.log"
LOCK_FILE="/var/lock/db_cleanup.lock"

BATCH_LIMIT=10000                    # rows per DELETE/UPDATE batch
BATCH_SLEEP=0.2                      # pause between batches
OPTIMIZE_THRESHOLD_MB=256            # OPTIMIZE when data_free exceeds this
LOG_MAX_BYTES=5242880                # rotate own log beyond 5 MB

# Default retention ages (shorthand: h=hours, d=days, w=weeks, m=months)
DEF_RADIUS="1w"                      # closed radacct sessions + radpostauth log
DEF_SESSIONS="1w"                    # captive portal sessions (expires_at)
DEF_VOUCHERS="2d"                    # vouchers already marked expired
DEF_PAYMENTS="6m"                    # hotspot_payments + mpesa_stks ledgers
DEF_FAILED="2d"                      # Laravel failed_jobs (poison closure adds ~5K rows/day)

ZOMBIE_AFTER="1 DAY"                 # open radacct sessions silent this long
                                     # get closed as Stale-Session (not prompted)

# radcheck/radreply rows whose voucher no longer exists are still-working
# login credentials (freeloader risk). Swept by default; 's' at the prompt
# skips. Only numeric voucher-shaped usernames are touched and never ones
# with an open session, so hand-created static users are always safe.

# ----------------------------- CLI parsing -------------------------------
DRY_RUN=0
FORCE_AUTO=0
FORCE_ASK=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --auto)    FORCE_AUTO=1 ;;
        --ask)     FORCE_ASK=1 ;;
        *) echo "Usage: $0 [--dry-run] [--auto] [--ask]" >&2; exit 1 ;;
    esac
done

INTERACTIVE=0
if [ "$FORCE_ASK" -eq 1 ]; then
    INTERACTIVE=1
elif [ "$FORCE_AUTO" -eq 0 ] && [ -t 0 ]; then
    INTERACTIVE=1
fi

# ----------------------------- Age parsing -------------------------------
# "12h" -> "12 HOUR", "2d" -> "2 DAY", "1w" -> "1 WEEK", "3m" -> "3 MONTH"
parse_age() {
    local in="$1"
    if [[ "$in" =~ ^([0-9]+)([hdwm])$ ]]; then
        local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
        [ "$n" -eq 0 ] && return 1
        case "$u" in
            h) echo "$n HOUR" ;;
            d) echo "$n DAY" ;;
            w) echo "$n WEEK" ;;
            m) echo "$n MONTH" ;;
        esac
        return 0
    fi
    return 1
}

# Prompt for one category. Echoes "N UNIT" or "SKIP".
ask_age() {
    local label="$1" def="$2" input parsed
    while true; do
        printf "  %-38s [%s] (e.g. 12h/2d/1w/3m, s=skip): " "$label" "$def" > /dev/tty
        IFS= read -r input < /dev/tty || input=""
        input="${input,,}"
        if [ -z "$input" ]; then parse_age "$def"; return; fi
        if [ "$input" = "s" ]; then echo "SKIP"; return; fi
        if parsed=$(parse_age "$input"); then echo "$parsed"; return; fi
        echo "    invalid - use a number + h/d/w/m, like 12h, 2d, 1w, 3m" > /dev/tty
    done
}

# ----------------------------- Preflight ---------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (MySQL '$DB_USER' uses unix_socket auth)" >&2
    exit 1
fi

if [ "$INTERACTIVE" -eq 1 ] && [ ! -e /dev/tty ]; then
    echo "ERROR: --ask requires a terminal (/dev/tty unavailable)" >&2
    exit 1
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another db_cleanup run is already in progress" >&2
    exit 1
fi

# Rotate our own log so it cannot grow unbounded (keep one generation)
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.old"
fi
touch "$LOG_FILE"

log_message() {
    local message="$1"
    echo "$message"
    echo "$message" >> "$LOG_FILE"
}

ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT

if ! "$MYSQL_BIN" -u "$DB_USER" "$DB_NAME" -N -e "SELECT 1" >/dev/null 2>"$ERRF"; then
    echo "ERROR: cannot connect to MySQL as '$DB_USER': $(tail -n1 "$ERRF")" >&2
    exit 1
fi

# ----------------------------- Choose ages -------------------------------
if [ "$INTERACTIVE" -eq 1 ]; then
    echo "Delete records OLDER than... (Enter = default shown in brackets)" > /dev/tty
    KEEP_RADIUS=$(ask_age  "RADIUS logs (radacct + radpostauth)" "$DEF_RADIUS")
    KEEP_SESSIONS=$(ask_age "Portal sessions (hotspot_sessions)"  "$DEF_SESSIONS")
    KEEP_VOUCHERS=$(ask_age "Expired vouchers"                    "$DEF_VOUCHERS")
    KEEP_PAYMENTS=$(ask_age "Payment ledgers (payments + STKs)"   "$DEF_PAYMENTS")
    KEEP_FAILED=$(ask_age   "Laravel failed_jobs"                 "$DEF_FAILED")
    printf "  %-38s [Y/s] (auth leftovers of deleted vouchers): " "Orphaned radcheck/radreply rows" > /dev/tty
    IFS= read -r oans < /dev/tty || oans=""
    if [ "${oans,,}" = "s" ]; then CLEAN_ORPHANS="SKIP"; else CLEAN_ORPHANS="n/a"; fi
    echo > /dev/tty
    ORPH_SHOW="clean"; [ "$CLEAN_ORPHANS" = "SKIP" ] && ORPH_SHOW="skip"
    echo "  Chosen: radius=[$KEEP_RADIUS] sessions=[$KEEP_SESSIONS] vouchers=[$KEEP_VOUCHERS] payments=[$KEEP_PAYMENTS] failed_jobs=[$KEEP_FAILED] orphans=[$ORPH_SHOW]" > /dev/tty
    [ "$DRY_RUN" -eq 1 ] && echo "  (dry-run: nothing will actually be deleted)" > /dev/tty
    printf "  Proceed? [y/N]: " > /dev/tty
    IFS= read -r confirm < /dev/tty || confirm=""
    if [ "${confirm,,}" != "y" ]; then
        echo "Aborted - nothing deleted." > /dev/tty
        exit 0
    fi
else
    KEEP_RADIUS=$(parse_age "$DEF_RADIUS")
    KEEP_SESSIONS=$(parse_age "$DEF_SESSIONS")
    KEEP_VOUCHERS=$(parse_age "$DEF_VOUCHERS")
    KEEP_PAYMENTS=$(parse_age "$DEF_PAYMENTS")
    KEEP_FAILED=$(parse_age "$DEF_FAILED")
    CLEAN_ORPHANS="n/a"
fi

log_message "========================================================="
log_message "Starting Database Maintenance Run: $(date)"
[ "$DRY_RUN" -eq 1 ] && log_message "*** DRY-RUN MODE: no rows will be modified ***"
log_message "Ages: radius=$KEEP_RADIUS sessions=$KEEP_SESSIONS vouchers=$KEEP_VOUCHERS payments=$KEEP_PAYMENTS failed=$KEEP_FAILED orphans=$([ "$CLEAN_ORPHANS" = "SKIP" ] && echo skip || echo clean)"
log_message "========================================================="

# ----------------------------- SQL helpers -------------------------------
ERRORS=0
LAST_ERR=""
RESULT=0

# Run a modifying statement; print affected-row count, or "ERR" on failure
# (LAST_ERR then holds the MySQL error). Never kills the script by itself.
run_sql_count() {
    local query="$1" out
    if ! out=$("$MYSQL_BIN" -u "$DB_USER" "$DB_NAME" -N -e "${query}; SELECT ROW_COUNT();" 2>"$ERRF"); then
        LAST_ERR=$(tail -n1 "$ERRF" 2>/dev/null || echo "unknown mysql error")
        echo "ERR"
        return 0
    fi
    out=$(printf '%s\n' "$out" | tail -n1)
    if [[ "$out" =~ ^-?[0-9]+$ ]]; then
        echo "$out"
    else
        LAST_ERR="unexpected output: $out"
        echo "ERR"
    fi
}

# Run a scalar SELECT; print the value, or "ERR" on failure.
run_scalar() {
    local query="$1" out
    if ! out=$("$MYSQL_BIN" -u "$DB_USER" "$DB_NAME" -N -e "$query" 2>"$ERRF"); then
        LAST_ERR=$(tail -n1 "$ERRF" 2>/dev/null || echo "unknown mysql error")
        echo "ERR"
        return 0
    fi
    echo "$out"
}

# Apply one retention rule in batches until no rows remain.
#   $1 label   $2 keep-age ("N UNIT" or "SKIP")
#   $3 modifying SQL template with __AGE__ placeholder (embeds LIMIT)
#   $4 COUNT(*) SQL template with __AGE__ placeholder (for --dry-run)
# Total affected rows land in $RESULT ("skipped" when skipped).
apply_batched() {
    local label="$1" age="$2" sql_tpl="$3" count_tpl="$4" sql count_sql rows suffix=""
    RESULT=0

    if [ "$age" = "SKIP" ]; then
        RESULT="skipped"
        log_message "  -> $label: skipped by operator"
        return 0
    fi
    [ "$age" != "n/a" ] && suffix=" (older than $age)"
    sql="${sql_tpl//__AGE__/$age}"
    count_sql="${count_tpl//__AGE__/$age}"

    if [ "$DRY_RUN" -eq 1 ]; then
        rows=$(run_scalar "$count_sql")
        if [ "$rows" = "ERR" ]; then
            log_message "  [ERROR] $label: $LAST_ERR"
            ERRORS=$((ERRORS + 1))
            return 0
        fi
        RESULT="$rows"
        log_message "  [DRY] $label$suffix: $rows row(s) would be affected"
        return 0
    fi

    while true; do
        rows=$(run_sql_count "$sql")
        if [ "$rows" = "ERR" ]; then
            log_message "  [ERROR] $label: $LAST_ERR (rule aborted after $RESULT rows)"
            ERRORS=$((ERRORS + 1))
            return 0
        fi
        if [ "$rows" -le 0 ]; then
            break
        fi
        RESULT=$((RESULT + rows))
        sleep "$BATCH_SLEEP"
    done
    log_message "  -> $label$suffix: $RESULT row(s) affected"
}

# ---------------------------------------------------------
# 1. Zombie radacct sessions (open, but silent too long)
# ---------------------------------------------------------
log_message "Closing zombie radacct sessions (no update for > ${ZOMBIE_AFTER})..."
apply_batched "radacct zombies closed" "$ZOMBIE_AFTER" \
    "UPDATE radacct SET acctstoptime = COALESCE(acctupdatetime, acctstarttime), acctterminatecause = 'Stale-Session' WHERE acctstoptime IS NULL AND COALESCE(acctupdatetime, acctstarttime) < NOW() - INTERVAL __AGE__ LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM radacct WHERE acctstoptime IS NULL AND COALESCE(acctupdatetime, acctstarttime) < NOW() - INTERVAL __AGE__"
TOTAL_ZOMBIES=$RESULT

# ---------------------------------------------------------
# 2. RADIUS AAA operational tables
# ---------------------------------------------------------
log_message "Cleaning core RADIUS operational logs..."
apply_batched "radacct (closed sessions)" "$KEEP_RADIUS" \
    "DELETE FROM radacct WHERE acctstoptime IS NOT NULL AND acctstoptime < NOW() - INTERVAL __AGE__ LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM radacct WHERE acctstoptime IS NOT NULL AND acctstoptime < NOW() - INTERVAL __AGE__"
TOTAL_RADACCT=$RESULT

apply_batched "radpostauth" "$KEEP_RADIUS" \
    "DELETE FROM radpostauth WHERE authdate < NOW() - INTERVAL __AGE__ LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM radpostauth WHERE authdate < NOW() - INTERVAL __AGE__"
TOTAL_RADPOSTAUTH=$RESULT

# ---------------------------------------------------------
# 3. Captive portal sessions & expired vouchers
# ---------------------------------------------------------
log_message "Cleaning captive portal records and expired vouchers..."
apply_batched "hotspot_sessions" "$KEEP_SESSIONS" \
    "DELETE FROM hotspot_sessions WHERE expires_at < NOW() - INTERVAL __AGE__ LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM hotspot_sessions WHERE expires_at < NOW() - INTERVAL __AGE__"
TOTAL_HOTSPOT_SESSIONS=$RESULT

apply_batched "vouchers (expired)" "$KEEP_VOUCHERS" \
    "DELETE FROM vouchers WHERE status = 'expired' AND expiration_time < NOW() - INTERVAL __AGE__ LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM vouchers WHERE status = 'expired' AND expiration_time < NOW() - INTERVAL __AGE__"
TOTAL_VOUCHERS_EXPIRED=$RESULT

# ---------------------------------------------------------
# 4. Application payment ledgers
# ---------------------------------------------------------
log_message "Cleaning payment transactions older than retention..."
apply_batched "hotspot_payments" "$KEEP_PAYMENTS" \
    "DELETE FROM hotspot_payments WHERE created_at < NOW() - INTERVAL __AGE__ LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM hotspot_payments WHERE created_at < NOW() - INTERVAL __AGE__"
TOTAL_HOTSPOT_PAYMENTS=$RESULT

apply_batched "mpesa_stks" "$KEEP_PAYMENTS" \
    "DELETE FROM mpesa_stks WHERE created_at < NOW() - INTERVAL __AGE__ LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM mpesa_stks WHERE created_at < NOW() - INTERVAL __AGE__"
TOTAL_MPESA_STKS=$RESULT

# ---------------------------------------------------------
# 5. Laravel queue: failed_jobs
# ---------------------------------------------------------
log_message "Cleaning Laravel failed_jobs..."
apply_batched "failed_jobs" "$KEEP_FAILED" \
    "DELETE FROM failed_jobs WHERE failed_at < NOW() - INTERVAL __AGE__ LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM failed_jobs WHERE failed_at < NOW() - INTERVAL __AGE__"
TOTAL_FAILED_JOBS=$RESULT

# ---------------------------------------------------------
# 5b. Orphaned RADIUS auth rows (voucher deleted, credentials remain)
# ---------------------------------------------------------
log_message "Sweeping orphaned radcheck/radreply rows..."
apply_batched "radcheck orphans" "$CLEAN_ORPHANS" \
    "DELETE FROM radcheck WHERE username REGEXP '^[0-9]{6,10}$' AND NOT EXISTS (SELECT 1 FROM vouchers v WHERE v.code = radcheck.username) AND NOT EXISTS (SELECT 1 FROM radacct r WHERE r.username = radcheck.username AND r.acctstoptime IS NULL) LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM radcheck WHERE username REGEXP '^[0-9]{6,10}$' AND NOT EXISTS (SELECT 1 FROM vouchers v WHERE v.code = radcheck.username) AND NOT EXISTS (SELECT 1 FROM radacct r WHERE r.username = radcheck.username AND r.acctstoptime IS NULL)"
TOTAL_RADCHECK_ORPHANS=$RESULT

apply_batched "radreply orphans" "$CLEAN_ORPHANS" \
    "DELETE FROM radreply WHERE username REGEXP '^[0-9]{6,10}$' AND NOT EXISTS (SELECT 1 FROM vouchers v WHERE v.code = radreply.username) AND NOT EXISTS (SELECT 1 FROM radacct r WHERE r.username = radreply.username AND r.acctstoptime IS NULL) LIMIT $BATCH_LIMIT" \
    "SELECT COUNT(*) FROM radreply WHERE username REGEXP '^[0-9]{6,10}$' AND NOT EXISTS (SELECT 1 FROM vouchers v WHERE v.code = radreply.username) AND NOT EXISTS (SELECT 1 FROM radacct r WHERE r.username = radreply.username AND r.acctstoptime IS NULL)"
TOTAL_RADREPLY_ORPHANS=$RESULT

# ---------------------------------------------------------
# 6. Post-maintenance: refresh stats, reclaim disk when worth it
# ---------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    log_message "Refreshing table statistics / reclaiming free space..."
    for t in radacct radpostauth hotspot_sessions vouchers radcheck radreply hotspot_payments mpesa_stks failed_jobs; do
        if ! "$MYSQL_BIN" -u "$DB_USER" "$DB_NAME" -e "ANALYZE TABLE \`$t\`;" >/dev/null 2>"$ERRF"; then
            log_message "  [WARN] ANALYZE $t failed: $(tail -n1 "$ERRF")"
            continue
        fi
        free_mb=$(run_scalar "SELECT COALESCE(ROUND(data_free/1048576),0) FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name='$t'")
        if [[ "$free_mb" =~ ^[0-9]+$ ]] && [ "$free_mb" -gt "$OPTIMIZE_THRESHOLD_MB" ]; then
            log_message "  -> $t carries ${free_mb} MB reclaimable space; running OPTIMIZE..."
            if ! "$MYSQL_BIN" -u "$DB_USER" "$DB_NAME" -e "OPTIMIZE TABLE \`$t\`;" >/dev/null 2>"$ERRF"; then
                log_message "  [WARN] OPTIMIZE $t failed: $(tail -n1 "$ERRF")"
            else
                log_message "  -> $t optimized."
            fi
        fi
    done
else
    log_message "[DRY] would ANALYZE tables and OPTIMIZE any with > ${OPTIMIZE_THRESHOLD_MB} MB free space"
fi

# ---------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------
log_message ""
log_message "========================================================="
log_message "           MAINTENANCE CLEANUP SUMMARY REPORT            "
log_message "========================================================="
log_message "Execution Timestamp : $(date)"
log_message "Target Database     : $DB_NAME"
[ "$DRY_RUN" -eq 1 ] && log_message "Mode                : DRY-RUN (nothing was modified)"
log_message "---------------------------------------------------------"
log_message "$(printf "%-28s | %-12s | %-12s" "Rule" "Older than" "Rows")"
log_message "---------------------------------------------------------"
log_message "$(printf "%-28s | %-12s | %-12s" "radacct zombies closed" "$ZOMBIE_AFTER" "$TOTAL_ZOMBIES")"
log_message "$(printf "%-28s | %-12s | %-12s" "radacct" "$KEEP_RADIUS" "$TOTAL_RADACCT")"
log_message "$(printf "%-28s | %-12s | %-12s" "radpostauth" "$KEEP_RADIUS" "$TOTAL_RADPOSTAUTH")"
log_message "$(printf "%-28s | %-12s | %-12s" "hotspot_sessions" "$KEEP_SESSIONS" "$TOTAL_HOTSPOT_SESSIONS")"
log_message "$(printf "%-28s | %-12s | %-12s" "vouchers (expired)" "$KEEP_VOUCHERS" "$TOTAL_VOUCHERS_EXPIRED")"
log_message "$(printf "%-28s | %-12s | %-12s" "hotspot_payments" "$KEEP_PAYMENTS" "$TOTAL_HOTSPOT_PAYMENTS")"
log_message "$(printf "%-28s | %-12s | %-12s" "mpesa_stks" "$KEEP_PAYMENTS" "$TOTAL_MPESA_STKS")"
log_message "$(printf "%-28s | %-12s | %-12s" "failed_jobs" "$KEEP_FAILED" "$TOTAL_FAILED_JOBS")"
log_message "$(printf "%-28s | %-12s | %-12s" "radcheck orphans" "$CLEAN_ORPHANS" "$TOTAL_RADCHECK_ORPHANS")"
log_message "$(printf "%-28s | %-12s | %-12s" "radreply orphans" "$CLEAN_ORPHANS" "$TOTAL_RADREPLY_ORPHANS")"
log_message "========================================================="
if [ "$ERRORS" -gt 0 ]; then
    log_message "Database Maintenance completed WITH $ERRORS ERROR(S) - see above."
    exit 1
fi
log_message "Database Maintenance Completed Successfully."
log_message "========================================================="
