#!/bin/bash

# Setup logging and error handling
INSTALL_LOG="/root/install.txt"
STEP_COUNT=0
COMPLETED_STEPS=()

# Get server hostname and set email
DOMAIN=$(hostname -f)
EMAIL_ADDRESS="simpluxsolutions@gmail.com"

# Configuration variables - ONLY DIFFERENCES BETWEEN SCRIPTS
GITHUB_REPO_URL="https://github.com/simpleisp/radius.git"
# Do NOT bump: the SimpleISP panel (Laravel 8) has hardcoded code that breaks
# on PHP > 7.4. The ondrej PPA provides php7.4 on every supported Ubuntu
# release including noble, so 7.4 stays pinned regardless of OS version.
PHP_VERSION="7.4"

# Logging functions
log_info() { echo "ℹ️  INFO: $1" | tee -a "$INSTALL_LOG"; }
log_success() { echo "✅ SUCCESS: $1" | tee -a "$INSTALL_LOG"; }
log_error() { echo "❌ ERROR: $1" | tee -a "$INSTALL_LOG"; }
log_warning() { echo "⚠️  WARNING: $1" | tee -a "$INSTALL_LOG"; }
log_step() { STEP_COUNT=$((STEP_COUNT + 1)); echo "👉 STEP $STEP_COUNT: $1" | tee -a "$INSTALL_LOG"; }

handle_error() {
    log_error "$1"
    echo -e "\nCompleted steps before failure:"
    printf '%s\n' "${COMPLETED_STEPS[@]}"
    echo -e "\nCheck $INSTALL_LOG for more details"
    exit 1
}

# Initialize log file
touch "$INSTALL_LOG" || { echo "Cannot create log file"; exit 1; }
echo "SimpleISP Installation Log - $(date '+%Y-%m-%d %H:%M:%S')" > "$INSTALL_LOG"
echo "----------------------------------------" >> "$INSTALL_LOG"

# Configure system for Valkey (memory overcommit and other optimizations)
log_step "Configuring system for Valkey"

# Enable memory overcommit
if ! grep -q "^vm.overcommit_memory" /etc/sysctl.conf; then
    echo "vm.overcommit_memory = 1" | tee -a /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf
    log_info "Enabled memory overcommit in sysctl"
else
    log_info "Memory overcommit already configured in sysctl"
fi
COMPLETED_STEPS+=("System configured for Valkey")

# Check for cleanup marker file
CLEANUP_MARKER="/root/.simpleisp_cleanup_done"
REINSTALL=false

if [ -f "$CLEANUP_MARKER" ]; then
    log_info "Detected previous cleanup ($(cat $CLEANUP_MARKER))"
    log_info "Forcing reinstallation of critical directories and files"
    REINSTALL=true
    # The marker is removed only at the end of a successful install, so a
    # failed run keeps reinstall mode active for the next attempt.
    log_success "Cleanup marker processed"
fi

# Ensure script runs as root
log_step "Checking root privileges"
if [ "$EUID" -ne 0 ]; then handle_error "Please run as root"; fi
COMPLETED_STEPS+=("Root check passed")

# Get Ubuntu version
log_step "Detecting Ubuntu version"
UBUNTU_VERSION=$(lsb_release -cs) || handle_error "Failed to detect Ubuntu version"
log_info "Detected Ubuntu version: $UBUNTU_VERSION"
COMPLETED_STEPS+=("Ubuntu version detected: $UBUNTU_VERSION")

# Set PHP Repo for Ubuntu 24.04 (Noble)
log_step "Adding PHP repository"
if [ "$UBUNTU_VERSION" = "noble" ]; then
    # Set up PHP repository for Ubuntu 24.04
    gpgKey='B8DC7E53946656EFBCE4C1DD71DAEAAB4AD4CAB6'
    gpgKeyPath='/etc/apt/keyrings/ondrej-ubuntu-php.gpg'
    gpgURL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${gpgKey}"
    
    # Create keyrings directory if it doesn't exist
    install -d -m 0755 /etc/apt/keyrings || handle_error "Failed to create keyrings directory"
    
    # Download and set up GPG key
    curl "${gpgURL}" | gpg --dearmor | tee ${gpgKeyPath} >/dev/null || handle_error "Failed to setup PHP GPG key"
    gpg --dry-run --quiet --import --import-options import-show ${gpgKeyPath}
    
    # Create the sources file for PHP repository
    cat > /etc/apt/sources.list.d/ondrej-ubuntu-php-noble.sources << 'EOL'
Types: deb
URIs: https://ppa.launchpadcontent.net/ondrej/php/ubuntu/
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/ondrej-ubuntu-php.gpg
EOL
else
    # For other Ubuntu versions, use the traditional PPA method
    LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php -y || handle_error "Failed to add PHP repository"
fi
COMPLETED_STEPS+=("PHP repository added")

# Set FreeRADIUS package source. focal/jammy archives only carry FreeRADIUS
# 3.0.x, so they use the NetworkRADIUS vendor repo (config root
# /etc/freeradius). noble+ ships FreeRADIUS 3.2 in the Ubuntu archive with
# security updates; its packaging keeps the config under /etc/freeradius/3.0.
log_step "Configuring FreeRADIUS package source"
if [[ "$UBUNTU_VERSION" == "focal" || "$UBUNTU_VERSION" == "jammy" ]]; then
    install -d -o root -g root -m 0755 /etc/apt/keyrings || handle_error "Failed to create keyrings directory"
    curl -s 'https://packages.networkradius.com/pgp/packages%40networkradius.com' | sudo tee /etc/apt/keyrings/packages.networkradius.com.asc > /dev/null || handle_error "Failed to download NetworkRADIUS PGP key"
    printf 'Package: /freeradius/\nPin: origin "packages.networkradius.com"\nPin-Priority: 999\n' | sudo tee /etc/apt/preferences.d/networkradius > /dev/null || handle_error "Failed to set NetworkRADIUS preferences"
    REPO_URL="http://packages.networkradius.com/freeradius-3.2/ubuntu/${UBUNTU_VERSION} ${UBUNTU_VERSION} main"
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.networkradius.com.asc] $REPO_URL" | sudo tee /etc/apt/sources.list.d/networkradius.list > /dev/null || handle_error "Failed to add NetworkRADIUS repository"
    FREERADIUS_CONF_DIR="/etc/freeradius"
    log_success "NetworkRADIUS repository configured for Ubuntu $UBUNTU_VERSION"
else
    # Ubuntu archive packages; remove NetworkRADIUS leftovers so reruns and
    # migrated servers actually install from the archive.
    rm -f /etc/apt/sources.list.d/networkradius.list /etc/apt/preferences.d/networkradius
    FREERADIUS_CONF_DIR="/etc/freeradius/3.0"
    log_success "Using Ubuntu archive FreeRADIUS packages"
fi
COMPLETED_STEPS+=("FreeRADIUS package source configured (config root: ${FREERADIUS_CONF_DIR})")

# Set Valkey package source. Ubuntu ships Valkey in its own archive only from
# noble (24.04, via noble-updates backport) onward; focal/jammy get Percona's
# builds instead, which use different package and service names.
log_step "Configuring Valkey package source"
if [[ "$UBUNTU_VERSION" == "focal" || "$UBUNTU_VERSION" == "jammy" ]]; then
    # Remove conflicting redis packages
    apt-get remove -y redis-tools redis-server || true

    # Install Percona release package and enable its Valkey repository
    curl -fsSL "https://repo.percona.com/apt/percona-release_latest.${UBUNTU_VERSION}_all.deb" -o /tmp/percona-release_latest.deb || handle_error "Failed to download percona-release package"
    dpkg -i /tmp/percona-release_latest.deb || handle_error "Failed to install percona-release package"
    rm -f /tmp/percona-release_latest.deb
    percona-release enable valkey experimental || handle_error "Failed to enable Percona Valkey repository"

    # Percona's valkey postinst runs "systemctl start valkey" itself, so any
    # dpkg configure (fresh install, upgrade, or recovery of a previously
    # failed run) needs the service to be startable. Pre-create the valkey
    # account and writable data/log dirs, and relax a leftover config that
    # hard-requires IPv6, BEFORE any apt operation touches the package.
    getent passwd valkey >/dev/null || useradd --system --user-group --home-dir /var/lib/valkey --no-create-home --shell /usr/sbin/nologin valkey || handle_error "Failed to create valkey user"
    mkdir -p /var/lib/valkey /var/log/valkey || handle_error "Failed to create Valkey data/log directories"
    chown -R valkey:valkey /var/lib/valkey /var/log/valkey || handle_error "Failed to set Valkey directory ownership"
    if [ -f /etc/valkey/valkey.conf ]; then
        sed -i 's/^bind 0\.0\.0\.0 ::0$/bind 0.0.0.0 -::0/' /etc/valkey/valkey.conf || true
    fi

    VALKEY_PACKAGES="valkey valkey-compat"
    VALKEY_SERVICE="valkey"
else
    VALKEY_PACKAGES="valkey-server valkey-tools valkey-redis-compat valkey-sentinel"
    VALKEY_SERVICE="valkey-server"
fi
COMPLETED_STEPS+=("Valkey package source configured (service: ${VALKEY_SERVICE})")

# Set environment variable to avoid interactive prompts
export DEBIAN_FRONTEND=noninteractive

# Update and upgrade system
log_step "Updating system packages"
apt-get update || handle_error "Failed to update package lists"
apt-get upgrade -y || handle_error "Failed to upgrade packages"
COMPLETED_STEPS+=("System packages updated")

# Install required packages (Cleaned virtual PHP packages and freeradius-rest)
log_step "Installing required packages"
INSTALL_PACKAGES="nginx-full python3-certbot-nginx php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-cli php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-common php${PHP_VERSION}-gd php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml php${PHP_VERSION}-dev php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl php${PHP_VERSION}-redis git unzip curl wget software-properties-common apt-transport-https ca-certificates gnupg lsb-release supervisor ${VALKEY_PACKAGES} ufw openvpn easy-rsa freeradius freeradius-mysql freeradius-utils mariadb-server mariadb-client"

if [ "$REINSTALL" = true ]; then
    log_info "Reinstalling packages (forcing configuration file replacement)"
    apt-get install --reinstall -y -o Dpkg::Options::="--force-confmiss" $INSTALL_PACKAGES || handle_error "Failed to reinstall packages"
else
    apt-get install -y $INSTALL_PACKAGES || handle_error "Failed to install packages"
fi
COMPLETED_STEPS+=("Required packages installed")

# Configure Valkey service overrides
log_step "Configuring Valkey service overrides"
VKEY_OVERRIDE_DIR="/etc/systemd/system/${VALKEY_SERVICE}.service.d"
VKEY_OVERRIDE_FILE="${VKEY_OVERRIDE_DIR}/override.conf"

mkdir -p "$VKEY_OVERRIDE_DIR"
cat > "$VKEY_OVERRIDE_FILE" << 'EOF'
[Unit]

[Service]
# Increase timeouts to prevent premature termination
TimeoutStartSec=300
TimeoutStopSec=300

# Ensure service restarts on failure
Restart=always
RestartSec=10s

# Disable OOM killer for Valkey
OOMScoreAdjust=-1000
EOF

# Apply changes and restart Valkey
log_info "Applying Valkey service configuration..."

# Configure Valkey with optimized settings for FreeRADIUS
log_step "Configuring Valkey with optimized settings"

# Calculate optimal memory allocation (Safe 15% of available RAM, capped at 3GB, minimum 1GB)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
MAX_MEMORY_MB=$((TOTAL_RAM_MB * 15 / 100))
if [ "$MAX_MEMORY_MB" -gt 3072 ]; then MAX_MEMORY_MB=3072; fi
if [ "$MAX_MEMORY_MB" -lt 1024 ]; then MAX_MEMORY_MB=1024; fi

log_info "Configuring Valkey with ${MAX_MEMORY_MB}MB memory allocation"

# Create Valkey configuration directory if it doesn't exist
mkdir -p /etc/valkey || handle_error "Failed to create Valkey configuration directory"

# Percona's valkey 8.x package ships /var/lib/valkey and /var/log/valkey owned
# by root while the service runs as user valkey; it must write both (AOF+log).
mkdir -p /var/lib/valkey /var/log/valkey || handle_error "Failed to create Valkey data/log directories"
chown -R valkey:valkey /var/lib/valkey /var/log/valkey || handle_error "Failed to set Valkey directory ownership"

# Configure Valkey with optimized settings for FreeRADIUS
cat > /etc/valkey/valkey.conf << EOL
# Valkey configuration for FreeRADIUS
bind 0.0.0.0 -::0
protected-mode yes
port 6379
tcp-backlog 511
timeout 0
tcp-keepalive 300
daemonize no
supervised systemd
pidfile /var/run/valkey/valkey.pid
loglevel notice
logfile /var/log/valkey/valkey.log
databases 16

# Memory management
maxmemory ${MAX_MEMORY_MB}mb
maxmemory-policy volatile-lru
maxmemory-samples 5

# AOF persistence (enabled for better durability)
appendonly yes
dir /var/lib/valkey
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes
aof-rewrite-incremental-fsync yes

# Performance optimizations
stop-writes-on-bgsave-error no
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb

# Disable RDB snapshots since we're using AOF
save ""

# Security (Reuse the same password as MySQL for simplicity)
requirepass "$MYSQL_PASSWORD"

# Network
tcp-keepalive 300
repl-timeout 60
repl-ping-slave-period 10
repl-backlog-size 1mb
repl-backlog-ttl 3600
timeout 0
tcp-keepalive 300

# Disable dangerous commands
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command CONFIG ""
rename-command SHUTDOWN ""

# Tune threads and clients
io-threads 2
io-threads-do-reads yes
maxclients 10000

# Tune data structures
active-expire-effort 1
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60
hash-max-ziplist-entries 512
hash-max-ziplist-value 64
list-max-ziplist-size -2
set-max-intset-entries 512
zset-max-ziplist-entries 128
zset-max-ziplist-value 64
hll-sparse-max-bytes 3000
stream-node-max-bytes 4096
stream-node-max-entries 100

# Enable active defragmentation
active-defrag-threshold-lower 10
active-defrag-threshold-upper 100
active-defrag-ignore-bytes 100mb
active-defrag-cycle-min 5
active-defrag-cycle-max 75
active-defrag-max-scan-fields 1000
EOL

# Restart Valkey to apply new configuration
systemctl daemon-reexec || log_warning "daemon-reexec failed (non-critical)"
systemctl daemon-reload || handle_error "Failed to reload systemd daemon"
systemctl restart "$VALKEY_SERVICE" || handle_error "Failed to restart Valkey"
systemctl enable "$VALKEY_SERVICE" || handle_error "Failed to enable Valkey"

# Verify Valkey is running
log_step "Verifying Valkey service status"
if systemctl is-active --quiet "$VALKEY_SERVICE"; then
    log_success "Valkey service is running"
    COMPLETED_STEPS+=("Valkey configured with ${MAX_MEMORY_MB}MB memory allocation")
else
    log_warning "Valkey service is not running as expected. Checking status..."
    systemctl status "$VALKEY_SERVICE" --no-pager || true
    
    log_info "Attempting to start Valkey service..."
    if systemctl start "$VALKEY_SERVICE"; then
        log_success "Successfully started Valkey service"
        COMPLETED_STEPS+=("Valkey configured with ${MAX_MEMORY_MB}MB memory allocation")
    else
        log_error "Failed to start Valkey service. Please check the logs with: journalctl -u ${VALKEY_SERVICE} -n 50"
        log_warning "Continuing installation despite Valkey service issue..."
        COMPLETED_STEPS+=("Valkey configuration completed but service failed to start")
    fi
fi

# Create Valkey debug script
log_step "Creating Valkey debug script"
cat > /usr/local/bin/valkey-debug.sh << EOF
#!/bin/bash

VALKEY_HOST="127.0.0.1"
VALKEY_PORT="6379"

echo "=== Valkey Status ==="
systemctl status ${VALKEY_SERVICE} --no-pager -l

echo -e "\n=== Valkey Key Statistics ==="
echo "Total Keys in DB 0: \$(valkey-cli -h \$VALKEY_HOST -p \$VALKEY_PORT dbsize)"
EOF

chmod +x /usr/local/bin/valkey-debug.sh || handle_error "Failed to make Valkey debug script executable"
COMPLETED_STEPS+=("Valkey monitoring configured")

# Add monitoring cron job (Safe Append Fix)
log_step "Adding monitoring cron job"
(crontab -l 2>/dev/null | grep -v 'valkey-debug\.sh'; echo "*/5 * * * * /usr/local/bin/valkey-debug.sh") | crontab - || handle_error "Failed to install monitoring cron job"
COMPLETED_STEPS+=("Monitoring cron job added")

# Verify Valkey is working
log_step "Verifying Valkey installation"
if ! systemctl is-active --quiet "$VALKEY_SERVICE"; then handle_error "Valkey service is not running"; fi

# Test Valkey connectivity and basic operations
if [ "$(valkey-cli ping)" != "PONG" ]; then handle_error "Valkey is not responding to ping"; fi
if [ "$(valkey-cli set test_key test_value)" != "OK" ]; then handle_error "Valkey write operation failed"; fi
if [ "$(valkey-cli get test_key)" != "test_value" ]; then handle_error "Valkey read operation failed"; fi
if [ "$(valkey-cli del test_key)" != "1" ]; then handle_error "Valkey delete operation failed"; fi
if ! valkey-cli info | grep -q "valkey_version"; then handle_error "Unable to get Valkey server information"; fi
COMPLETED_STEPS+=("Valkey functionality verified")

# Set Default PHP Version
log_step "Setting default PHP version"
update-alternatives --set php /usr/bin/php${PHP_VERSION} || handle_error "Failed to set default PHP version"
COMPLETED_STEPS+=("PHP ${PHP_VERSION} set as default")

# Install and configure ionCube Loader
log_step "Installing ionCube Loader"
if [ -d "/usr/local/ioncube" ] && [ -f "/usr/local/ioncube/ioncube_loader_lin_${PHP_VERSION}.so" ]; then
    log_info "ionCube Loader already exists, skipping download and installation"
    COMPLETED_STEPS+=("ionCube Loader reused (already exists)")
else
    log_info "ionCube Loader not found, downloading and installing"
    cd /tmp || handle_error "Failed to change to /tmp directory"
    wget -O ioncube.zip "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.zip" || handle_error "Failed to download ionCube"
    unzip -q ioncube.zip || handle_error "Failed to extract ionCube"
    rm -rf /usr/local/ioncube 2>/dev/null
    mv ioncube /usr/local/ || handle_error "Failed to move ionCube to /usr/local"
    COMPLETED_STEPS+=("ionCube Loader downloaded and installed")
fi

# Create ionCube ini file with absolute path
cat > /etc/php/${PHP_VERSION}/mods-available/ioncube.ini << EOL
zend_extension = /usr/local/ioncube/ioncube_loader_lin_${PHP_VERSION}.so
EOL

# Enable ionCube for PHP CLI and FPM
ln -sf /etc/php/${PHP_VERSION}/mods-available/ioncube.ini /etc/php/${PHP_VERSION}/cli/conf.d/00-ioncube.ini || handle_error "Failed to enable ionCube for CLI"
ln -sf /etc/php/${PHP_VERSION}/mods-available/ioncube.ini /etc/php/${PHP_VERSION}/fpm/conf.d/00-ioncube.ini || handle_error "Failed to enable ionCube for FPM"
systemctl restart php${PHP_VERSION}-fpm || handle_error "Failed to restart PHP-FPM"

# Verify ionCube installation
if php -v | grep -q "ionCube PHP Loader"; then
    log_success "ionCube Loader installed and enabled successfully"
    COMPLETED_STEPS+=("ionCube Loader installed and configured")
else
    handle_error "ionCube Loader installation verification failed"
fi

# Start and enable MariaDB
log_step "Configuring MariaDB"
if [ ! -d "/var/lib/mysql/mysql" ]; then
    log_info "Initializing MariaDB system database"
    mysql_install_db --user=mysql --datadir=/var/lib/mysql || handle_error "Failed to initialize MariaDB"
fi

systemctl start mariadb || handle_error "Failed to start MariaDB"
systemctl enable mariadb || handle_error "Failed to enable MariaDB"

# Ensure debian-start script exists (recreate if missing)
if [ ! -f "/etc/mysql/debian-start" ]; then
    log_info "Creating missing /etc/mysql/debian-start script"
    cat > /etc/mysql/debian-start << 'EOF'
#!/bin/bash
if [ "$(id -u)" != "0" ]; then echo "This script must be run as root" 1>&2; exit 1; fi
if ! /usr/bin/mysqladmin --defaults-file=/etc/mysql/debian.cnf ping > /dev/null 2>&1; then exit 0; fi
exit 0
EOF
    chmod +x /etc/mysql/debian-start || handle_error "Failed to make debian-start executable"
    log_success "Created /etc/mysql/debian-start script"
fi
COMPLETED_STEPS+=("MariaDB initialized, started and enabled")

# Configure MySQL to allow remote connections
log_step "Configuring MySQL for remote connections"
mkdir -p /etc/mysql/mariadb.conf.d/ || handle_error "Failed to create MariaDB conf directory"

cat > /etc/mysql/mariadb.conf.d/50-server.cnf << 'EOL'
[server]
# [mysqld] is read by every MariaDB version; [mariadbd] only exists from
# 10.4.6, so focal's MariaDB 10.3 would silently ignore this whole block.
[mysqld]
user                    = mysql
pid-file                = /run/mysqld/mysqld.pid
basedir                 = /usr
datadir                 = /var/lib/mysql
tmpdir                  = /tmp
skip-external-locking
bind-address            = 0.0.0.0
key_buffer_size         = 16M
max_allowed_packet      = 16M
thread_stack            = 192K
thread_cache_size       = 8
myisam-recover-options  = BACKUP
query_cache_limit       = 1M
query_cache_size        = 16M
expire_logs_days        = 10
max_binlog_size        = 100M
character-set-server    = utf8mb4
collation-server        = utf8mb4_general_ci
innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1
[embedded]
[mariadb]
EOL

systemctl restart mariadb || handle_error "Failed to restart MariaDB after configuration change"
COMPLETED_STEPS+=("MySQL configured for remote connections")

# Generate random credentials or reuse existing ones
DB_CREDENTIALS_FILE="/root/db.txt"
if [ -f "$DB_CREDENTIALS_FILE" ] && [ -r "$DB_CREDENTIALS_FILE" ]; then
    log_step "Found existing database credentials, reusing them"
    MYSQL_USER=$(grep "^DB_USERNAME=" "$DB_CREDENTIALS_FILE" | cut -d'=' -f2)
    MYSQL_PASSWORD=$(grep "^DB_PASSWORD=" "$DB_CREDENTIALS_FILE" | cut -d'=' -f2)
    MYSQL_DATABASE=$(grep "^DB_DATABASE=" "$DB_CREDENTIALS_FILE" | cut -d'=' -f2)
    
    if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ] && [ -n "$MYSQL_DATABASE" ]; then
        log_info "Reusing existing database credentials: User=$MYSQL_USER, Database=$MYSQL_DATABASE"
        COMPLETED_STEPS+=("Database credentials reused from existing file")
    else
        log_info "Existing db.txt file is incomplete, generating new credentials"
        MYSQL_USER="user_$(openssl rand -hex 3)"
        MYSQL_PASSWORD="$(openssl rand -base64 12)"
        MYSQL_DATABASE="radius"
        COMPLETED_STEPS+=("New database credentials generated (existing file was incomplete)")
    fi
else
    log_step "No existing database credentials found, generating new ones"
    MYSQL_USER="user_$(openssl rand -hex 3)"
    MYSQL_PASSWORD="$(openssl rand -base64 12)"
    MYSQL_DATABASE="radius"
    COMPLETED_STEPS+=("New database credentials generated")
fi

# Save database credentials
log_step "Saving database credentials"
echo "MySQL Credentials:" > "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_HOST=localhost" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_PORT=3306" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_DATABASE=$MYSQL_DATABASE" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_USERNAME=$MYSQL_USER" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_PASSWORD=$MYSQL_PASSWORD" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
COMPLETED_STEPS+=("Database credentials saved")

# Secure MariaDB installation
log_step "Securing MariaDB installation"
mysql -e "DELETE FROM mysql.user WHERE User='';" || handle_error "Failed to delete anonymous MariaDB user"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" || handle_error "Failed to delete remote MariaDB root user"
mysql -e "DROP DATABASE IF EXISTS test;" || handle_error "Failed to delete test database"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" || handle_error "Failed to delete test database"
mysql -e "FLUSH PRIVILEGES;" || handle_error "Failed to flush MariaDB privileges"
COMPLETED_STEPS+=("MariaDB installation secured")

# Create database and user
log_step "Creating database and user"
mysql -e "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE;" || handle_error "Failed to create database"
mysql -e "CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" || handle_error "Failed to create database user"
mysql -e "ALTER USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" || handle_error "Failed to set database user password"
mysql -e "GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'%';" || handle_error "Failed to grant database privileges"
mysql -e "FLUSH PRIVILEGES;" || handle_error "Failed to flush MariaDB privileges"
COMPLETED_STEPS+=("Database and user created with full access")

# Install Composer
log_step "Installing Composer"
if ! command -v composer &> /dev/null; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || handle_error "Failed to download Composer installer"
    php composer-setup.php --quiet || handle_error "Failed to install Composer"
    rm composer-setup.php || handle_error "Failed to remove Composer installer"
    mv composer.phar /usr/local/bin/composer || handle_error "Failed to move Composer to /usr/local/bin"
    chmod +x /usr/local/bin/composer || handle_error "Failed to make Composer executable"
fi
COMPLETED_STEPS+=("Composer installed")

# Configure Nginx
log_step "Configuring Nginx"
if [ -f /etc/nginx/sites-available/default ]; then
    mv /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak || handle_error "Failed to backup default Nginx site"
fi
touch /etc/nginx/sites-available/default || handle_error "Failed to create new Nginx site"
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default || handle_error "Failed to symlink Nginx site"

cat > /etc/nginx/sites-available/default << EOL
server {
    listen 80;
    listen [::]:80;
    
    root /var/www/html/public;
    index index.php index.html index.htm index.nginx-debian.html;

    server_name $DOMAIN;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL
COMPLETED_STEPS+=("Nginx configured")

# Configure SSL with Certbot
log_step "Configuring SSL with Certbot"
echo "Configuring SSL certificate for $DOMAIN"

# One non-interactive call covers both cases: with --keep-until-expiring
# certbot reinstalls an existing valid certificate into the fresh nginx
# config (no reissue, no rate-limit usage) and only requests a new one
# when none exists.
certbot --nginx -d "$DOMAIN" --agree-tos --email "$EMAIL_ADDRESS" --no-eff-email --non-interactive --redirect --keep-until-expiring || handle_error "Failed to configure SSL with Certbot"
COMPLETED_STEPS+=("SSL configured with Certbot")

# Test the Nginx configuration (Graceful restart applied)
log_step "Restarting Nginx"
nginx -t || handle_error "Nginx configuration failed"
systemctl restart nginx || handle_error "Failed to restart Nginx"
COMPLETED_STEPS+=("Nginx restarted gracefully")

# Setup Laravel application
log_step "Setting up Laravel application"
LOCAL_PATH="/var/www/html"
REPO_URL="$GITHUB_REPO_URL"

if [ -d "$LOCAL_PATH" ]; then
    rm -rf "$LOCAL_PATH" || handle_error "Failed to remove existing web root"
fi

git clone "$REPO_URL" "$LOCAL_PATH" || handle_error "Failed to clone repository"
cd "$LOCAL_PATH" || handle_error "Failed to change directory to web root"

# Install Laravel dependencies
log_step "Installing Laravel dependencies"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --no-security-blocking --prefer-dist || handle_error "Failed to install Laravel dependencies"
COMPLETED_STEPS+=("Laravel dependencies installed")

# Create and configure .env file
log_step "Configuring .env file"
cp .env.example .env || handle_error "Failed to copy .env.example to .env"
php artisan key:generate --force || handle_error "Failed to generate Laravel key"
COMPLETED_STEPS+=(".env file configured")

# Update .env with database credentials
sed -i "s|DB_HOST=.*|DB_HOST=localhost|" .env || handle_error "Failed to update DB_HOST in .env"
sed -i "s|DB_PORT=.*|DB_PORT=3306|" .env || handle_error "Failed to update DB_PORT in .env"
sed -i "s|DB_DATABASE=.*|DB_DATABASE=$MYSQL_DATABASE|" .env || handle_error "Failed to update DB_DATABASE in .env"
sed -i "s|DB_USERNAME=.*|DB_USERNAME=$MYSQL_USER|" .env || handle_error "Failed to update DB_USERNAME in .env"
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$MYSQL_PASSWORD|" .env || handle_error "Failed to update DB_PASSWORD in .env"
sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" .env || handle_error "Failed to update APP_URL in .env"
sed -i "s|APP_NAME=.*|APP_NAME=\"$DOMAIN\"|" .env || handle_error "Failed to update APP_NAME in .env"
COMPLETED_STEPS+=(".env file updated with database credentials")

# Run Laravel migrations and seed the database
log_step "Running Laravel migrations and seeding database"
php artisan migrate --force || handle_error "Failed to run Laravel migrations"
php artisan db:seed --force || handle_error "Failed to seed database"
COMPLETED_STEPS+=("Laravel migrations run and database seeded")

# Set correct www permissions
log_step "Setting correct www permissions"
chown -R www-data:www-data /var/www/html || handle_error "Failed to set ownership of web root"
chmod -R 775 /var/www/html/storage || handle_error "Failed to set permissions of storage directory"
chmod -R 775 /var/www/html/bootstrap/cache || handle_error "Failed to set permissions of cache directory"

# Make the scripts executable
chmod +x /var/www/html/sh/set_permissions.sh || handle_error "Failed to make permissions script executable"
chmod +x /var/www/html/sh/restart-services.sh || handle_error "Failed to make services script executable"

# Run the script once to apply initial configuration
/var/www/html/sh/set_permissions.sh || handle_error "Failed to run permissions script"
/var/www/html/sh/restart-services.sh || handle_error "Failed to run services script"
COMPLETED_STEPS+=("Correct www permissions set")

# Optimize RADIUS database indexes
log_step "Optimizing RADIUS database indexes"
cat > /tmp/radius_optimize.sql << "EOL"
USE radius;
ALTER TABLE radcheck ADD INDEX idx_username (username), ADD INDEX idx_attribute (attribute);
ANALYZE TABLE radcheck;
ALTER TABLE radreply ADD INDEX idx_username (username), ADD INDEX idx_attribute (attribute);
ANALYZE TABLE radreply;
ALTER TABLE radusergroup ADD INDEX idx_username (username), ADD INDEX idx_groupname (groupname);
ANALYZE TABLE radusergroup;
ALTER TABLE radgroupcheck ADD INDEX idx_groupname (groupname), ADD INDEX idx_attribute (attribute);
ANALYZE TABLE radgroupcheck;
ALTER TABLE radgroupreply ADD INDEX idx_groupname (groupname), ADD INDEX idx_attribute (attribute);
ANALYZE TABLE radgroupreply;
ALTER TABLE radacct ADD INDEX idx_username (username), ADD INDEX idx_acctsessionid (acctsessionid), ADD INDEX idx_framedipaddress (framedipaddress), ADD INDEX idx_acctstarttime (acctstarttime), ADD INDEX idx_acctstoptime (acctstoptime), ADD INDEX idx_nasipaddress (nasipaddress), ADD INDEX idx_calledstationid (calledstationid), ADD INDEX idx_callingstationid (callingstationid);
ANALYZE TABLE radacct;
ALTER TABLE radpostauth ADD INDEX idx_username (username), ADD INDEX idx_reply (reply), ADD INDEX idx_authdate (authdate);
ANALYZE TABLE radpostauth;
ALTER TABLE radcheck ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radreply ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radusergroup ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radgroupcheck ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radgroupreply ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radacct ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radpostauth ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ANALYZE TABLE radcheck;
ANALYZE TABLE radreply;
ANALYZE TABLE radusergroup;
ANALYZE TABLE radgroupcheck;
ANALYZE TABLE radgroupreply;
ANALYZE TABLE radacct;
ANALYZE TABLE radpostauth;
EOL

mysql -u root < /tmp/radius_optimize.sql || handle_error "Failed to optimize RADIUS database indexes"
rm -f /tmp/radius_optimize.sql || handle_error "Failed to remove radius optimization sql file"
COMPLETED_STEPS+=("RADIUS database indexes optimized")

# Configure Supervisor for queue worker (Pre-created log dir fix)
log_step "Configuring Supervisor for queue worker"
# clean_server.sh wipes /etc/supervisor; restore the package config if a
# failed run already consumed the reinstall marker.
if [ ! -f /etc/supervisor/supervisord.conf ]; then
    apt-get install --reinstall -y -o Dpkg::Options::="--force-confmiss" supervisor || handle_error "Failed to restore supervisor configuration"
fi
mkdir -p /etc/supervisor/conf.d || handle_error "Failed to create supervisor conf.d directory"
mkdir -p /var/www/html/storage/logs || handle_error "Failed to create Laravel logs directory"
cat > /etc/supervisor/conf.d/queue-worker.conf << "EOL"
[program:queue-worker]
process_name=%(program_name)s_%(process_num)02d
command=php /var/www/html/artisan queue:work --tries=3
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=5
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/queue-worker.log
EOL
COMPLETED_STEPS+=("Supervisor configured for queue worker")

# Install OpenVPN based on Ubuntu version
log_step "Installing OpenVPN"
case $UBUNTU_VERSION in
    "focal"|"jammy"|"noble")
        echo "Installing OpenVPN for Ubuntu $UBUNTU_VERSION"
        export AUTO_INSTALL=y
        curl -O https://raw.githubusercontent.com/mymanga/bash/main/openvpn.sh || handle_error "Failed to download OpenVPN installer"
        chmod +x openvpn.sh || handle_error "Failed to make OpenVPN installer executable"
        ./openvpn.sh || handle_error "Failed to install OpenVPN"

        # Set more secure permissions for OpenVPN
        chown -R root:root /etc/openvpn || handle_error "Failed to set ownership of OpenVPN configuration directory"
        chmod -R 777 /etc/openvpn || handle_error "Failed to set permissions of OpenVPN configuration directory"
        chmod -R 777 /etc/openvpn/easy-rsa || handle_error "Failed to set permissions of OpenVPN easy-rsa directory"
        ;;
    *)
        handle_error "Unsupported Ubuntu version for OpenVPN installation"
        ;;
esac
COMPLETED_STEPS+=("OpenVPN installed")

# Configure Systemd sandbox overrides for OpenVPN writes
log_step "Configuring Systemd sandbox overrides for OpenVPN writes"
mkdir -p /etc/systemd/system/php${PHP_VERSION}-fpm.service.d || handle_error "Failed to create PHP systemd override directory"
cat > /etc/systemd/system/php${PHP_VERSION}-fpm.service.d/override.conf << 'EOF'
[Service]
ReadWritePaths=/etc/openvpn
EOF

mkdir -p /etc/systemd/system/supervisor.service.d || handle_error "Failed to create Supervisor systemd override directory"
cat > /etc/systemd/system/supervisor.service.d/override.conf << 'EOF'
[Service]
ReadWritePaths=/etc/openvpn
EOF
COMPLETED_STEPS+=("Systemd sandbox overrides configured")

# Install Laravel cron (Safe Append Fix)
log_step "Installing cron"
(crontab -l 2>/dev/null | grep -v 'artisan schedule:run'; echo "* * * * * php /var/www/html/artisan schedule:run >> /dev/null 2>&1") | crontab - || handle_error "Failed to install Laravel cron job"
COMPLETED_STEPS+=("Cron job installed")

# Update sudoers for www-data user (Updated openvpn explicit target)
log_step "Updating sudoers for www-data user"
# Append only once - retries and reinstalls must not duplicate the block
if ! grep -qF 'www-data ALL=NOPASSWD: /var/www/html/sh/restart-services.sh' /etc/sudoers; then
cat >> /etc/sudoers << 'EOL'
www-data ALL=NOPASSWD: /bin/systemctl start openvpn@server
www-data ALL=NOPASSWD: /bin/systemctl stop openvpn@server
www-data ALL=NOPASSWD: /bin/systemctl restart openvpn@server
www-data ALL=NOPASSWD: /bin/systemctl status openvpn@server
www-data ALL=NOPASSWD: /bin/systemctl reload openvpn@server
www-data ALL=NOPASSWD: /bin/systemctl enable openvpn@server
www-data ALL=NOPASSWD: /bin/systemctl disable openvpn@server
www-data ALL=NOPASSWD: /bin/systemctl start freeradius
www-data ALL=NOPASSWD: /bin/systemctl stop freeradius
www-data ALL=NOPASSWD: /bin/systemctl restart freeradius
www-data ALL=NOPASSWD: /bin/systemctl status freeradius
www-data ALL=NOPASSWD: /bin/systemctl reload freeradius
www-data ALL=NOPASSWD: /bin/systemctl enable freeradius
www-data ALL=NOPASSWD: /bin/systemctl disable freeradius
www-data ALL=NOPASSWD: /bin/supervisorctl stop all
www-data ALL=NOPASSWD: /bin/supervisorctl reread
www-data ALL=NOPASSWD: /bin/supervisorctl update
www-data ALL=NOPASSWD: /bin/supervisorctl start all
www-data ALL=NOPASSWD: /bin/supervisorctl restart all
www-data ALL=NOPASSWD: /bin/supervisorctl status
www-data ALL=NOPASSWD: /bin/systemctl restart supervisor
www-data ALL=NOPASSWD: /bin/systemctl status ssh
www-data ALL=NOPASSWD: /var/www/html/sh/set_permissions.sh
www-data ALL=NOPASSWD: /var/www/html/sh/restart-services.sh
EOL
fi

# The panel also invokes systemctl by bare name (sudo resolves that via
# secure_path to /usr/bin/systemctl) and checks the umbrella "openvpn"
# unit - neither matches the /bin/... openvpn@server entries above, which
# made the panel show OpenVPN as stopped. Separate guard so existing
# servers gain these lines on rerun.
if ! grep -qF '/usr/bin/systemctl status openvpn' /etc/sudoers; then
cat >> /etc/sudoers << 'EOL'
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
EOL
fi
COMPLETED_STEPS+=("Sudoers updated for www-data user")

# Open Firewall Ports and enable ufw
log_step "Opening firewall ports and enabling ufw"
ufw allow ssh || handle_error "Failed to allow SSH through firewall"
ufw allow 9080/tcp || handle_error "Failed to allow port 9080 through firewall"
ufw allow http || handle_error "Failed to allow HTTP through firewall"
ufw allow https || handle_error "Failed to allow HTTPS through firewall"
ufw allow 1194/tcp || handle_error "Failed to allow OpenVPN through firewall"
ufw allow 1812:1813/udp || handle_error "Failed to allow FreeRADIUS through firewall"
ufw reload || handle_error "Failed to reload firewall rules"
yes | ufw enable || handle_error "Failed to enable firewall"
COMPLETED_STEPS+=("Firewall ports opened and ufw enabled")

# Test FreeRADIUS configuration
log_step "Checking FreeRADIUS files"

if [ ! -f "${FREERADIUS_CONF_DIR}/radiusd.conf" ]; then
    log_info "FreeRADIUS configuration files missing, reinstalling and reconfiguring FreeRADIUS package"
    apt-get purge -y freeradius freeradius-common freeradius-config 2>/dev/null || echo "FreeRADIUS not installed"
    apt-get autoremove -y 2>/dev/null
    apt-get install -y freeradius freeradius-mysql freeradius-config || handle_error "Failed to reinstall FreeRADIUS"
    dpkg-reconfigure -f noninteractive freeradius-config 2>/dev/null || echo "Reconfigure not needed"
fi

if [ ! -f "${FREERADIUS_CONF_DIR}/radiusd.conf" ]; then
    log_info "Creating minimal radiusd.conf configuration"
    mkdir -p "${FREERADIUS_CONF_DIR}" || handle_error "Failed to create freeradius config dir"
    cat > "${FREERADIUS_CONF_DIR}/radiusd.conf" << 'EOF'
prefix = /usr
exec_prefix = ${prefix}
sysconfdir = /etc
localstatedir = /var
sbindir = ${exec_prefix}/sbin
logdir = /var/log/freeradius
raddbdir = /etc/freeradius
radacctdir = ${logdir}/radacct

name = freeradius
confdir = ${raddbdir}
modconfdir = ${confdir}/mods-config
certdir = ${confdir}/certs
cadir   = ${confdir}/certs
run_dir = ${localstatedir}/run/${name}

db_dir = ${raddbdir}
libdir = /usr/lib/freeradius
pidfile = ${run_dir}/${name}.pid

correct_escapes = true
max_request_time = 30
cleanup_delay = 5
max_requests = 16384
hostname_lookups = no

log {
destination = files
colourise = yes
file = ${logdir}/radius.log
syslog_facility = daemon
stripped_names = no
auth = no
auth_badpass = no
auth_goodpass = no
msg_denied = "You are already logged in - access denied"
}

checkrad = ${sbindir}/checkrad

security {
allow_core_dumps = no
max_attributes = 200
reject_delay = 1
status_server = yes
}

proxy_requests  = yes
$INCLUDE proxy.conf
$INCLUDE clients.conf

thread pool {
start_servers = 5
max_servers = 32
min_spare_servers = 3
max_spare_servers = 10
max_requests_per_server = 0
auto_limit_acct = no
}

$INCLUDE sites-enabled/
$INCLUDE mods-enabled/

policy {
$INCLUDE policy.d/
}

instantiate {
}
EOF
    # The heredoc is quoted (it contains FreeRADIUS's own ${var} syntax), so
    # patch raddbdir to the packaging-specific config root afterwards.
    sed -i "s|^raddbdir = .*|raddbdir = ${FREERADIUS_CONF_DIR}|" "${FREERADIUS_CONF_DIR}/radiusd.conf" || handle_error "Failed to set raddbdir"
    chmod 644 "${FREERADIUS_CONF_DIR}/radiusd.conf" || handle_error "Failed to set radiusd.conf permissions"
    log_success "Created minimal radiusd.conf configuration"
fi

if [ -f "${FREERADIUS_CONF_DIR}/mods-available/sql" ]; then
    ln -sf "${FREERADIUS_CONF_DIR}/mods-available/sql" "${FREERADIUS_CONF_DIR}/mods-enabled/" || handle_error "Failed to re-enable SQL module"
fi
COMPLETED_STEPS+=("Completed checking FreeRADIUS files")

# Write and enable the buffered-sql site. Accounting packets are written to
# a local detail file by the default site (fast, survives DB stalls); this
# virtual server tails that file and replays the records into SQL.
log_step "Enabling FreeRADIUS buffered-sql site"
mkdir -p "${FREERADIUS_CONF_DIR}/sites-available" "${FREERADIUS_CONF_DIR}/sites-enabled" || handle_error "Failed to create FreeRADIUS sites directories"
cat > "${FREERADIUS_CONF_DIR}/sites-available/buffered-sql" << 'EOF'
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
ln -sf "${FREERADIUS_CONF_DIR}/sites-available/buffered-sql" "${FREERADIUS_CONF_DIR}/sites-enabled/buffered-sql" || handle_error "Failed to enable buffered-sql site"
COMPLETED_STEPS+=("FreeRADIUS buffered-sql site enabled")

# Configure the detail module as a single-file writer that buffered-sql can
# consume (the stock module writes per-NAS/per-day files the reader ignores).
log_step "Configuring FreeRADIUS detail module"
cat > "${FREERADIUS_CONF_DIR}/mods-available/detail" << 'EOF'
detail {
	filename = ${radacctdir}/detail
	header = "%t"
	permissions = 0600
	locking = yes
}
EOF
ln -sf "${FREERADIUS_CONF_DIR}/mods-available/detail" "${FREERADIUS_CONF_DIR}/mods-enabled/detail" || handle_error "Failed to enable detail module"
COMPLETED_STEPS+=("FreeRADIUS detail module configured")

# Enable SQL module for FreeRADIUS
log_step "Enabling SQL module"
mkdir -p "${FREERADIUS_CONF_DIR}/mods-enabled" || handle_error "Failed to create FreeRADIUS mods-enabled directory"
ln -sf "${FREERADIUS_CONF_DIR}/mods-available/sql" "${FREERADIUS_CONF_DIR}/mods-enabled/sql" || handle_error "Failed to enable SQL module"
COMPLETED_STEPS+=("FreeRADIUS SQL module enabled")

# Write new FreeRADIUS SQL module
log_step "Writing new FreeRADIUS SQL module"
SQL_FILE="${FREERADIUS_CONF_DIR}/mods-available/sql"
cat > "$SQL_FILE" <<EOF
# -*- text -*-
sql {
	dialect = "mysql"
	driver = "rlm_sql_mysql"

	mysql {
		warnings = auto
	}

	radius_db = "$MYSQL_DATABASE"
	server = "localhost"
	port = 3306
	login = "$MYSQL_USER"
	password = "$MYSQL_PASSWORD"

	acct_table1 = "radacct"
	acct_table2 = "radacct"
	postauth_table = "radpostauth"
	authcheck_table = "radcheck"
	groupcheck_table = "radgroupcheck"
	authreply_table = "radreply"
	groupreply_table = "radgroupreply"
	usergroup_table = "radusergroup"

	delete_stale_sessions = yes

	pool {
		start = \${thread[pool].start_servers}
		min = \${thread[pool].min_spare_servers}
		max = \${thread[pool].max_servers}
		spare = \${thread[pool].max_spare_servers}
		uses = 0
		retry_delay = 30
		lifetime = 0
		idle_timeout = 60
		max_retries = 5
	}

	read_clients = yes
	client_table = "nas"
	group_attribute = "SQL-Group"

	\$INCLUDE \${modconfdir}/\${.:name}/main/mysql/queries.conf
}
EOF
log_success "FreeRADIUS SQL module written to $SQL_FILE"
COMPLETED_STEPS+=("FreeRADIUS SQL module written with database credentials")

# Configure FreeRADIUS default site
log_step "Configuring FreeRADIUS default site"
DEFAULT_SITE_AVAIL="${FREERADIUS_CONF_DIR}/sites-available/default"
DEFAULT_SITE="${FREERADIUS_CONF_DIR}/sites-enabled/default"

# Older installers edited sites-enabled/default in place, replacing the
# packaged symlink with a regular file; recover that content if needed, then
# always edit sites-available/default and re-link (the packaged layout).
if [ ! -f "$DEFAULT_SITE_AVAIL" ] && [ -f "$DEFAULT_SITE" ] && [ ! -L "$DEFAULT_SITE" ]; then
    mv "$DEFAULT_SITE" "$DEFAULT_SITE_AVAIL" || handle_error "Failed to recover default site into sites-available"
fi

if [ -f "$DEFAULT_SITE_AVAIL" ]; then
    sed -i 's/-sql/sql/g' "$DEFAULT_SITE_AVAIL" || handle_error "Failed to update -sql to sql"
    log_step "Replacing accounting section in FreeRADIUS default site"
    # Session records queue to the local detail file only; the buffered-sql
    # virtual server replays them into SQL (survives DB stalls/restarts).
    # Accounting-On/Off go to sql synchronously instead: NAS-reboot records
    # crash the detail reader thread and freeze the queue, so they must
    # never enter it.
    cat << 'EOF' > /tmp/new_accounting_block
accounting {
if (&Acct-Status-Type == Accounting-On || &Acct-Status-Type == Accounting-Off) {
sql {
fail = 1
}
ok
}
else {
detail
}
exec
attr_filter.accounting_response
}
EOF
    # Brace-counting skip (comments stripped): the replaced section can be
    # the nested block above on re-runs, where "end at first }" corrupts it.
    awk '
    BEGIN { skip = 0; depth = 0 }
    /^accounting[ \t]*{/ { print_file("/tmp/new_accounting_block"); skip = 1; depth = 1; next }
    skip {
        s = $0; sub(/#.*/, "", s)
        depth += gsub(/{/, "{", s) - gsub(/}/, "}", s)
        if (depth <= 0) skip = 0
        next
    }
    { print }
    function print_file(file) {
        while ((getline line < file) > 0) print line;
        close(file)
    }
    ' "$DEFAULT_SITE_AVAIL" > /tmp/tmp_site && mv /tmp/tmp_site "$DEFAULT_SITE_AVAIL"
    ln -sf "$DEFAULT_SITE_AVAIL" "$DEFAULT_SITE" || handle_error "Failed to enable default site"
else
    handle_error "Default site configuration file not found"
fi
COMPLETED_STEPS+=("FreeRADIUS default site configured")

# Validate the FreeRADIUS configuration now so wiring mistakes fail loudly
# here instead of at the service restart later.
log_step "Validating FreeRADIUS configuration"
RAD_BIN="$(command -v freeradius || command -v radiusd)" || handle_error "FreeRADIUS binary not found"
if ! "$RAD_BIN" -XC > /dev/null 2>&1; then
    "$RAD_BIN" -XC 2>&1 | tail -n 20
    handle_error "FreeRADIUS configuration validation failed (freeradius -XC)"
fi
COMPLETED_STEPS+=("FreeRADIUS configuration validated")

# Apply Systemd Sandbox changes from the overrides
systemctl daemon-reload || handle_error "Failed to reload systemd daemon"

# Enable and start all services (Consolidated Block)
log_step "Enabling and restarting all services"

SERVICES=(nginx php${PHP_VERSION}-fpm supervisor openvpn@server freeradius "$VALKEY_SERVICE")
for service in "${SERVICES[@]}"; do
    systemctl enable "$service" || handle_error "Failed to enable $service"
    systemctl restart "$service" || handle_error "Failed to restart $service"
done
COMPLETED_STEPS+=("All services enabled and restarted")

# Install maintenance scripts (autotune, DB cleanup, OpenVPN sandbox fix)
log_step "Installing maintenance scripts to /var/www/html/sh"
for s in universal.sh db_cleanup.sh ovpn_fix.sh; do
    curl -fsSL "https://raw.githubusercontent.com/mymanga/bash/main/${s}" -o "/var/www/html/sh/${s}" || handle_error "Failed to download ${s}"
    chmod +x "/var/www/html/sh/${s}" || handle_error "Failed to make ${s} executable"
done
COMPLETED_STEPS+=("Maintenance scripts installed to /var/www/html/sh")

# Schedule maintenance (Safe Append Fix): autotune daily at 3 AM and on every
# reboot (delayed so MariaDB/Valkey/PHP-FPM are up before live tuning starts).
# db_cleanup.sh is intentionally NOT scheduled - run it manually when needed.
log_step "Scheduling maintenance cron jobs"
(crontab -l 2>/dev/null | grep -v 'universal\.sh'; echo "0 3 * * * /var/www/html/sh/universal.sh"; echo "@reboot sleep 120; /var/www/html/sh/universal.sh") | crontab - || handle_error "Failed to schedule universal.sh cron jobs"
COMPLETED_STEPS+=("Maintenance cron jobs scheduled (universal.sh 3AM + reboot)")

# Run the autotune once to apply the initial configuration
log_step "Running initial system autotune (universal.sh)"
/var/www/html/sh/universal.sh || handle_error "Failed to run initial autotune (universal.sh)"
COMPLETED_STEPS+=("Initial autotune applied (universal.sh)")

# Verify PHP-FPM/queue workers can write /etc/openvpn despite systemd sandboxing.
# Idempotent: no-ops where the static overrides above already grant access, and
# catches any additional php-fpm versions or queue-worker units.
log_step "Verifying OpenVPN write access for PHP-FPM (ovpn_fix.sh)"
/var/www/html/sh/ovpn_fix.sh || log_warning "ovpn_fix.sh reported issues; review the output above and re-run /var/www/html/sh/ovpn_fix.sh manually"
COMPLETED_STEPS+=("OpenVPN sandbox write access verified (ovpn_fix.sh)")

# Final verification
log_step "Verifying all services are running"
for service in nginx mariadb freeradius "$VALKEY_SERVICE" php${PHP_VERSION}-fpm; do
    if ! systemctl is-active --quiet $service; then
        log_warning "$service is not running"
        systemctl status $service
    else
        log_success "$service is running"
    fi
done

# Install finished: clear the reinstall marker only now, so failed runs
# before this point keep reinstall mode for the next attempt.
rm -f "$CLEANUP_MARKER"

# Complete installation message
log_success "Installation completed successfully!"
echo "You can find your database credentials in $DB_CREDENTIALS_FILE"
echo "Your SimpleISP installation is available at: https://$DOMAIN"
