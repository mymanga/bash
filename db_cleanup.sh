#!/bin/bash

# Configuration
DB_NAME="radius"
DB_USER="root"
MYSQL_BIN=$(which mysql)
LOG_FILE="/var/log/radius_db_cleanup.log"

# Ensure log file exists and is writable
touch "$LOG_FILE" 2>/dev/null

# Logging function to guarantee clean output to screen and file
log_message() {
    local message="$1"
    echo "$message"                  
    echo "$message" >> "$LOG_FILE"   
}

log_message "========================================================="
log_message "Starting Database Maintenance Run: $(date)"
log_message "========================================================="

# Initialize dynamic counter variables for reporting
TOTAL_RADACCT=0
TOTAL_RADPOSTAUTH=0
TOTAL_HOTSPOT_SESSIONS=0
TOTAL_VOUCHERS_EXPIRED=0
TOTAL_HOTSPOT_PAYMENTS=0
TOTAL_MPESA_STKS=0

# NEW: Unified helper function to delete and count in the exact same session
execute_and_count() {
    local query="$1"
    local result
    
    # Run the query and append SELECT ROW_COUNT() in the same transaction
    result=$($MYSQL_BIN -u "$DB_USER" "$DB_NAME" -N -e "$query; SELECT ROW_COUNT();" 2>/dev/null)
    
    # Ensure the result is a valid number, otherwise return 0
    if [[ ! "$result" =~ ^[0-9]+$ ]]; then
        echo 0
    else
        echo "$result"
    fi
}

# ---------------------------------------------------------
# 1. RADIUS AAA Operational Tables (1-Week Window)
# ---------------------------------------------------------
log_message "Cleaning up core RADIUS operational logs older than 1 week..."

RADACCT_QUERY="DELETE FROM radacct WHERE acctstoptime IS NOT NULL AND acctstoptime < NOW() - INTERVAL 1 WEEK LIMIT 10000"

while true; do
    ROWS=$(execute_and_count "$RADACCT_QUERY")
    if [ "$ROWS" -le 0 ]; then break; fi
    TOTAL_RADACCT=$((TOTAL_RADACCT + ROWS))
    sleep 0.2
done
log_message "  -> radacct processing complete."

RADPOSTAUTH_QUERY="DELETE FROM radpostauth WHERE authdate < NOW() - INTERVAL 1 WEEK LIMIT 10000"

while true; do
    ROWS=$(execute_and_count "$RADPOSTAUTH_QUERY")
    if [ "$ROWS" -le 0 ]; then break; fi
    TOTAL_RADPOSTAUTH=$((TOTAL_RADPOSTAUTH + ROWS))
    sleep 0.2
done
log_message "  -> radpostauth processing complete."


# ---------------------------------------------------------
# 2. Hotspot App Sessions & Depleted Vouchers (2-Day Window)
# ---------------------------------------------------------
log_message "Cleaning up captive portal records and depleted vouchers..."

HOTSPOT_SESSION_QUERY="DELETE FROM hotspot_sessions WHERE expires_at < NOW() - INTERVAL 1 WEEK LIMIT 5000"

while true; do
    ROWS=$(execute_and_count "$HOTSPOT_SESSION_QUERY")
    if [ "$ROWS" -le 0 ]; then break; fi
    TOTAL_HOTSPOT_SESSIONS=$((TOTAL_HOTSPOT_SESSIONS + ROWS))
    sleep 0.1
done
log_message "  -> hotspot_sessions processing complete."

VOUCHER_STATUS_CLEANUP="DELETE FROM vouchers WHERE status = 'expired' AND expiration_time < NOW() - INTERVAL 2 DAY"
ROWS=$(execute_and_count "$VOUCHER_STATUS_CLEANUP")
TOTAL_VOUCHERS_EXPIRED=$((TOTAL_VOUCHERS_EXPIRED + ROWS))
log_message "  -> Vouchers expired/depleted for more than 2 days cleared."


# ---------------------------------------------------------
# 3. Application Payment Ledgers (6-Month Retention Window)
# ---------------------------------------------------------
log_message "Cleaning up payment transactions older than 6 months..."

PAYMENT_CLEANUP_QUERY="DELETE FROM hotspot_payments WHERE created_at < NOW() - INTERVAL 6 MONTH LIMIT 5000"

while true; do
    ROWS=$(execute_and_count "$PAYMENT_CLEANUP_QUERY")
    if [ "$ROWS" -le 0 ]; then break; fi
    TOTAL_HOTSPOT_PAYMENTS=$((TOTAL_HOTSPOT_PAYMENTS + ROWS))
    sleep 0.1
done
log_message "  -> hotspot_payments processing complete."

STK_CLEANUP_QUERY="DELETE FROM mpesa_stks WHERE created_at < NOW() - INTERVAL 6 MONTH"
ROWS=$(execute_and_count "$STK_CLEANUP_QUERY")
TOTAL_MPESA_STKS=$((TOTAL_MPESA_STKS + ROWS))
log_message "  -> mpesa_stks processing complete."


# ---------------------------------------------------------
# 4. Final Maintenance Summary Dashboard
# ---------------------------------------------------------
log_message ""
log_message "========================================================="
log_message "           MAINTENANCE CLEANUP SUMMARY REPORT            "
log_message "========================================================="
log_message "Execution Timestamp : $(date)"
log_message "Target Database     : $DB_NAME"
log_message "---------------------------------------------------------"
LINE=$(printf "%-25s | %-15s | %-15s" "Table Name" "Retention Pol" "Records Cleared")
log_message "$LINE"
log_message "---------------------------------------------------------"
LINE=$(printf "%-25s | %-15s | %-15s" "radacct" "1 Week" "$TOTAL_RADACCT")
log_message "$LINE"
LINE=$(printf "%-25s | %-15s | %-15s" "radpostauth" "1 Week" "$TOTAL_RADPOSTAUTH")
log_message "$LINE"
LINE=$(printf "%-25s | %-15s | %-15s" "hotspot_sessions" "1 Week" "$TOTAL_HOTSPOT_SESSIONS")
log_message "$LINE"
LINE=$(printf "%-25s | %-15s | %-15s" "vouchers (Status=Expired)" "2 Days" "$TOTAL_VOUCHERS_EXPIRED")
log_message "$LINE"
LINE=$(printf "%-25s | %-15s | %-15s" "hotspot_payments" "6 Months" "$TOTAL_HOTSPOT_PAYMENTS")
log_message "$LINE"
LINE=$(printf "%-25s | %-15s | %-15s" "mpesa_stks" "6 Months" "$TOTAL_MPESA_STKS")
log_message "$LINE"
log_message "========================================================="
log_message "Database Maintenance Completed Successfully."
log_message "========================================================="