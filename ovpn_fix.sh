#!/bin/bash
# ---------------------------------------------------------------------------
# fix-phpfpm-openvpn-sandbox.sh
#
# Problem this fixes:
#   Debian/Ubuntu php-fpm systemd units ship with ProtectSystem=full, which
#   mounts /etc read-only inside the service's mount namespace. Any panel
#   code (SimpleISP OpenVPN setup) that writes /etc/openvpn/server.conf from
#   a PHP-FPM worker then fails with:
#       file_put_contents(/etc/openvpn/server.conf):
#       Failed to open stream: Read-only file system
#   The sandbox only engages on service (re)start, so the failure typically
#   appears right after a php-fpm restart (e.g. after tuning scripts or
#   package upgrades).
#
# What it does:
#   1. Finds every installed phpX.Y-fpm unit (Ubuntu 20.04 / 24.04 / 26.04
#      ship different PHP versions; nothing is hardcoded).
#   2. Also finds any systemd unit running "artisan queue:work|horizon"
#      (Laravel queue workers write configs too and are sandboxed
#      independently of php-fpm).
#   3. Installs a drop-in override:
#         [Service]
#         ReadWritePaths=/etc/openvpn
#      Drop-ins survive package upgrades; editing the packaged unit does not.
#   4. Reloads systemd, restarts the affected units, and VERIFIES from
#      inside each service's mount namespace (nsenter) that /etc/openvpn is
#      actually writable now.
#
# Usage:
#   sudo ./fix-phpfpm-openvpn-sandbox.sh            # apply
#   sudo ./fix-phpfpm-openvpn-sandbox.sh --dry-run  # preview only
#   sudo ./fix-phpfpm-openvpn-sandbox.sh --no-restart  # install drop-ins only
#
# Notes:
#   * Restarting php-fpm briefly recycles workers; on a busy hotspot portal
#     run this in a quiet moment.
#   * Idempotent: safe to run repeatedly; existing correct drop-ins are
#     left untouched.
# ---------------------------------------------------------------------------
set -euo pipefail

RW_PATH="/etc/openvpn"
DROPIN_NAME="openvpn-write.conf"
DRY_RUN=0
DO_RESTART=1
FAILED=0

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--no-restart] [--help]
  --dry-run     Show what would be done without changing anything
  --no-restart  Install drop-ins but do not restart services (changes take
                effect on next restart; verification is skipped)
  --help        Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-restart) DO_RESTART=0; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

log()  { echo "[$(date +'%F %T')] $*"; }
warn() { echo "[$(date +'%F %T')] [WARN] $*" >&2; }
err()  { echo "[$(date +'%F %T')] [ERROR] $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "This script must run as root."
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  err "systemctl not found; this fix only applies to systemd systems."
  exit 1
fi

# ---------------------------------------------------------------------------
# Discover target units
# ---------------------------------------------------------------------------
declare -a TARGET_UNITS=()

# All installed phpX.Y-fpm units (covers 7.4 on 20.04 through whatever
# 26.04 ships), whether currently active or not.
while IFS= read -r unit; do
  [ -n "$unit" ] && TARGET_UNITS+=("$unit")
done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
          | awk '{print $1}' \
          | grep -E '^php[0-9]+(\.[0-9]+)?-fpm\.service$' || true)

if [ "${#TARGET_UNITS[@]}" -eq 0 ]; then
  warn "No php-fpm units found on this host."
fi

# Laravel queue workers / Horizon run in their own units with their own
# sandboxing; if they perform the config write, they need the same override.
while IFS= read -r unit; do
  [ -n "$unit" ] && TARGET_UNITS+=("$unit")
done < <(systemctl list-units --type=service --no-legend --no-pager 2>/dev/null \
          | awk '{print $1}' \
          | while IFS= read -r u; do
              execline=$(systemctl show "$u" -p ExecStart --value 2>/dev/null || true)
              case "$execline" in
                *"artisan queue:work"*|*"artisan horizon"*) echo "$u" ;;
              esac
            done || true)

if [ "${#TARGET_UNITS[@]}" -eq 0 ]; then
  err "Nothing to do: no php-fpm or queue-worker units found."
  exit 1
fi

# De-duplicate
mapfile -t TARGET_UNITS < <(printf '%s\n' "${TARGET_UNITS[@]}" | sort -u)

log "Ubuntu release: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
log "Target units: ${TARGET_UNITS[*]}"
log "ReadWritePaths to grant: ${RW_PATH}"
log "Dry-run: ${DRY_RUN}  Restart: ${DO_RESTART}"
echo

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
needs_fix() {
  # Returns 0 if the unit sandboxes /etc and lacks the RW exception.
  local unit="$1" protect rwpaths
  protect=$(systemctl show "$unit" -p ProtectSystem --value 2>/dev/null || echo "")
  rwpaths=$(systemctl show "$unit" -p ReadWritePaths --value 2>/dev/null || echo "")
  case " $rwpaths " in
    *" ${RW_PATH} "*) return 1 ;;  # already granted
  esac
  case "$protect" in
    full|strict|yes|true) return 0 ;;
    *) return 1 ;;                 # /etc not read-only for this unit
  esac
}

install_dropin() {
  local unit="$1"
  local dir="/etc/systemd/system/${unit}.d"
  local file="${dir}/${DROPIN_NAME}"

  if [ -f "$file" ] && grep -q "^ReadWritePaths=.*${RW_PATH}" "$file"; then
    log "[SKIP] ${unit}: drop-in already present at ${file}"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY] ${unit}: would write ${file} with ReadWritePaths=${RW_PATH}"
    return 0
  fi

  mkdir -p "$dir"
  cat > "$file" <<EOF
# Installed by fix-phpfpm-openvpn-sandbox.sh on $(date +%F)
# Allows this service to write OpenVPN configs despite ProtectSystem=full.
[Service]
ReadWritePaths=${RW_PATH}
EOF
  log "[OK] ${unit}: drop-in written to ${file}"
}

verify_unit() {
  # Confirm from inside the unit's mount namespace that RW_PATH is writable.
  local unit="$1" pid testfile
  pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null || echo 0)
  if [ -z "$pid" ] || [ "$pid" -eq 0 ]; then
    warn "${unit}: no main PID (service not running?); cannot verify namespace."
    return 1
  fi
  if ! command -v nsenter >/dev/null 2>&1; then
    warn "nsenter not available; skipping in-namespace verification."
    return 0
  fi
  testfile="${RW_PATH}/.rwtest.$$"
  if nsenter -t "$pid" -m -- /bin/sh -c "touch '${testfile}' && rm -f '${testfile}'" 2>/dev/null; then
    log "[VERIFIED] ${unit}: ${RW_PATH} is writable inside the service namespace"
    return 0
  else
    err "${unit}: ${RW_PATH} is STILL read-only inside the service namespace"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
declare -a CHANGED_UNITS=()

for unit in "${TARGET_UNITS[@]}"; do
  protect=$(systemctl show "$unit" -p ProtectSystem --value 2>/dev/null || echo "")
  rwpaths=$(systemctl show "$unit" -p ReadWritePaths --value 2>/dev/null || echo "<none>")
  log "${unit}: ProtectSystem=${protect:-<unset>} ReadWritePaths=${rwpaths:-<none>}"

  if needs_fix "$unit"; then
    install_dropin "$unit"
    CHANGED_UNITS+=("$unit")
  else
    # Still ensure a drop-in exists for units already carrying the path
    # via our own previous run; otherwise nothing to do.
    case " $(systemctl show "$unit" -p ReadWritePaths --value 2>/dev/null) " in
      *" ${RW_PATH} "*) log "[SKIP] ${unit}: already has ${RW_PATH} in ReadWritePaths" ;;
      *) log "[SKIP] ${unit}: /etc is not sandboxed for this unit (ProtectSystem=${protect:-unset})" ;;
    esac
  fi
done

if [ "${#CHANGED_UNITS[@]}" -eq 0 ]; then
  log "No changes needed on this host."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "[DRY] would run: systemctl daemon-reload && systemctl restart ${CHANGED_UNITS[*]}"
  exit 0
fi

systemctl daemon-reload
log "[OK] systemd daemon reloaded"

if [ "$DO_RESTART" -eq 0 ]; then
  warn "Restart skipped (--no-restart); the override takes effect on each unit's next restart."
  exit 0
fi

for unit in "${CHANGED_UNITS[@]}"; do
  log "[RUN] restarting ${unit}"
  if systemctl restart "$unit"; then
    if systemctl is-active --quiet "$unit"; then
      log "[OK] ${unit} restarted and active"
    else
      err "${unit} restarted but is not active; check: journalctl -u ${unit} -n 100"
      FAILED=1
      continue
    fi
  else
    err "failed to restart ${unit}"
    FAILED=1
    continue
  fi
  verify_unit "$unit" || FAILED=1
done

# For queue workers managed by supervisor rather than systemd, remind the
# operator: supervisor does not sandbox, but workers cache code/config.
if command -v supervisorctl >/dev/null 2>&1; then
  warn "supervisord detected: if Laravel queue workers run under supervisor,"
  warn "run 'php artisan queue:restart' so workers pick up fresh state."
fi

echo
if [ "$FAILED" -eq 0 ]; then
  log "All done. PHP-FPM (and any queue-worker units) can now write ${RW_PATH}."
else
  err "Completed with errors on one or more units - review output above."
  exit 1
fi