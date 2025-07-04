#!/bin/bash

# Cleanup script for SimpleISP/SimpleSpot
# This script will uninstall all software installed by the SimpleISP/SimpleSpot installer
# and clean the server for reinstallation

echo "[$(date)] Starting cleanup process..."

# Function to handle errors
handle_error() {
    echo "[$(date)] ERROR: $1"
    exit 1
}

# Function to log steps
log_step() {
    echo "[$(date)] STEP: $1"
}

# Confirm before proceeding
echo "WARNING: This will remove ALL software installed by SimpleISP/SimpleSpot and delete all data."
echo "This action CANNOT be undone!"
read -p "Are you sure you want to proceed? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

# Detect PHP version (try common versions)
PHP_VERSION=""
for version in 8.2 8.1 8.0 7.4; do
    if command -v php${version} &> /dev/null; then
        PHP_VERSION=$version
        break
    fi
done

if [ -z "$PHP_VERSION" ]; then
    echo "Warning: Could not detect PHP version, using 8.2 as default"
    PHP_VERSION="8.2"
fi

echo "[$(date)] Detected PHP version: $PHP_VERSION"

# Stop services
log_step "Stopping services"
systemctl stop nginx freeradius mariadb valkey-server valkey php${PHP_VERSION}-fpm supervisor openvpn || echo "Could not stop all services"

# Remove web files
log_step "Removing web files"
rm -rf /var/www/html/* 2>/dev/null
rm -rf /var/www/html/.* 2>/dev/null

# Remove configuration directories
log_step "Removing configuration directories"
rm -rf /etc/nginx/sites-available/default 2>/dev/null
rm -rf /etc/nginx/sites-enabled/default 2>/dev/null
# Preserve FreeRADIUS base configuration, only remove application-specific configs
if [ -d "/etc/freeradius" ]; then
    # Remove application-specific FreeRADIUS configurations but preserve base system configs
    rm -f /etc/freeradius/mods-enabled/sql 2>/dev/null
    rm -f /etc/freeradius/mods-enabled/rest 2>/dev/null
    # Remove any custom site configurations but preserve default
    find /etc/freeradius/sites-enabled/ -name "*" ! -name "default" -delete 2>/dev/null
fi
rm -rf /etc/openvpn 2>/dev/null
rm -rf /etc/supervisor 2>/dev/null

# Remove valkey data
# log_step "Removing valkey data"
# rm -rf /var/lib/valkey/* 2>/dev/null
# rm -rf /var/lib/valkey/.* 2>/dev/null

# Remove MySQL/MariaDB data and users
log_step "Removing MySQL/MariaDB data and users"
systemctl stop mariadb 2>/dev/null || echo "MariaDB was not running"
mysql -e "DROP USER IF EXISTS 'simpleisp'@'%';" 2>/dev/null || echo "Could not remove simpleisp user"
mysql -e "DROP USER IF EXISTS 'radius'@'%';" 2>/dev/null || echo "Could not remove radius user"
mysql -e "DROP DATABASE IF EXISTS radius;" 2>/dev/null || echo "Could not remove radius database"
mysql -e "FLUSH PRIVILEGES;" 2>/dev/null

# Remove MySQL/MariaDB files
log_step "Removing MySQL/MariaDB files"
systemctl stop mariadb 2>/dev/null || echo "MariaDB already stopped"
rm -rf /var/lib/mysql 2>/dev/null
mkdir -p /var/lib/mysql
chown mysql:mysql /var/lib/mysql
rm -rf /run/mysqld 2>/dev/null
rm -f /root/.my.cnf 2>/dev/null
rm -f /root/.mysql_history 2>/dev/null

# Remove any remaining MySQL/MariaDB files (preserve essential system files)
find /etc/mysql/conf.d/ -name "*laravel*" -delete 2>/dev/null
find /etc/mysql/conf.d/ -name "*radius*" -delete 2>/dev/null
find /etc/mysql/conf.d/ -name "*simpleisp*" -delete 2>/dev/null
find /etc/mysql/conf.d/ -name "*simplespot*" -delete 2>/dev/null
# Preserve essential MariaDB system files like debian-start, debian.cnf, etc.
# Only remove application-specific configuration files

# Remove log files
log_step "Removing log files"
rm -f /var/log/nginx/access.log 2>/dev/null
rm -f /var/log/nginx/error.log 2>/dev/null
rm -f /var/log/freeradius/radius.log 2>/dev/null

# Remove SSL certificates
log_step "Preserving SSL certificates (not removing for reuse on reinstall)"
# rm -rf /etc/letsencrypt/live/* 2>/dev/null
# rm -rf /etc/letsencrypt/archive/* 2>/dev/null
# rm -rf /etc/letsencrypt/renewal/* 2>/dev/null

# Remove application-specific files
log_step "Removing application-specific files"
# Preserve db.txt for credential reuse on reinstall
# rm -f /root/db.txt 2>/dev/null
rm -f /etc/cron.d/laravel-scheduler 2>/dev/null

# Remove ionCube files
log_step "Removing ionCube files"
rm -f /etc/php/${PHP_VERSION}/mods-available/ioncube.ini 2>/dev/null
rm -f /etc/php/${PHP_VERSION}/cli/conf.d/00-ioncube.ini 2>/dev/null
rm -f /etc/php/${PHP_VERSION}/fpm/conf.d/00-ioncube.ini 2>/dev/null
# Preserve ionCube installation for reuse on reinstall
# rm -rf /usr/local/ioncube 2>/dev/null
find /usr/lib/php/ -name "*ioncube*" -delete 2>/dev/null

# Remove temporary files
log_step "Removing temporary files"
rm -rf /tmp/ioncube* 2>/dev/null
rm -f /tmp/*.zip 2>/dev/null
rm -f /tmp/*.tar.gz 2>/dev/null

# Create cleanup marker
log_step "Creating cleanup marker"
date '+%Y-%m-%d %H:%M:%S' > "/root/.simpleisp_cleanup_done"
echo "[$(date)] Cleanup completed. Marker created at /root/.simpleisp_cleanup_done"

echo "[$(date)] Cleanup completed. The server is now clean and ready for reinstallation."
