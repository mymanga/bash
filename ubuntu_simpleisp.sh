#!/bin/bash

# Setup logging and error handling
INSTALL_LOG="/root/install.txt"
STEP_COUNT=0
COMPLETED_STEPS=()

# Configuration variables - ONLY DIFFERENCES BETWEEN SCRIPTS
GITHUB_REPO_URL="https://github.com/simpleisp/radius.git"
PHP_VERSION="7.4"

# Logging functions
log_info() {
    echo "ℹ️  INFO: $1" | tee -a "$INSTALL_LOG"
}

log_success() {
    echo "✅ SUCCESS: $1" | tee -a "$INSTALL_LOG"
}

log_error() {
    echo "❌ ERROR: $1" | tee -a "$INSTALL_LOG"
}

log_step() {
    STEP_COUNT=$((STEP_COUNT + 1))
    echo "👉 STEP $STEP_COUNT: $1" | tee -a "$INSTALL_LOG"
}

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

    # Remove the marker file after handling it
    rm -f "$CLEANUP_MARKER"
    log_success "Cleanup marker processed and removed"
fi

# Ensure script runs as root
log_step "Checking root privileges"
if [ "$EUID" -ne 0 ]; then
    handle_error "Please run as root"
fi
COMPLETED_STEPS+=("Root check passed")

# Set environment variable to avoid interactive prompts
export DEBIAN_FRONTEND=noninteractive
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
    cat > /etc/apt/sources.list.d/ondrej-ubuntu-php-noble.sources << "EOL"
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

# Set NetworkRADIUS PGP public key
log_step "Configuring NetworkRADIUS repository"
install -d -o root -g root -m 0755 /etc/apt/keyrings || handle_error "Failed to create keyrings directory"
curl -s 'https://packages.networkradius.com/pgp/packages%40networkradius.com' | sudo tee /etc/apt/keyrings/packages.networkradius.com.asc > /dev/null || handle_error "Failed to download NetworkRADIUS PGP key"
COMPLETED_STEPS+=("NetworkRADIUS PGP key installed")

# Add NetworkRADIUS APT preferences
printf 'Package: /freeradius/\nPin: origin "packages.networkradius.com"\nPin-Priority: 999\n' | sudo tee /etc/apt/preferences.d/networkradius > /dev/null || handle_error "Failed to set NetworkRADIUS preferences"

# Add NetworkRADIUS repository based on Ubuntu version
case $UBUNTU_VERSION in
    "noble")
        REPO_URL="http://packages.networkradius.com/freeradius-3.2/ubuntu/noble noble main"
        ;;
    "jammy")
        REPO_URL="http://packages.networkradius.com/freeradius-3.2/ubuntu/jammy jammy main"
        ;;
    "focal")
        REPO_URL="http://packages.networkradius.com/freeradius-3.2/ubuntu/focal focal main"
        ;;
    *)
        handle_error "Unsupported Ubuntu version: $UBUNTU_VERSION"
        ;;
esac

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.networkradius.com.asc] $REPO_URL" | sudo tee /etc/apt/sources.list.d/networkradius.list > /dev/null || handle_error "Failed to add NetworkRADIUS repository"
log_success "NetworkRADIUS repository configured for Ubuntu $UBUNTU_VERSION"
COMPLETED_STEPS+=("NetworkRADIUS repository configured")

# Set Valkey Repository
log_step "Adding Valkey repository"
if [[ "$UBUNTU_VERSION" == "focal" || "$UBUNTU_VERSION" == "jammy" ]]; then
    # Remove conflicting redis packages
    apt-get remove -y redis-tools redis-server || true

    # Fetch Percona release package
    wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb

    # Install Percona release package
    dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb

    # Enable Percona repository for Valkey
    percona-release enable valkey experimental

    # Update package list
    apt-get update
fi

COMPLETED_STEPS+=("Valkey repository added")



# Update and upgrade system
log_step "Updating system packages"
apt-get update || handle_error "Failed to update package lists"
apt-get upgrade -y || handle_error "Failed to upgrade packages"
COMPLETED_STEPS+=("System packages updated")

# Install required packages
log_step "Installing required packages"
if [ "$REINSTALL" = true ]; then
    log_info "Reinstalling packages (forcing configuration file replacement)"
    apt-get install --reinstall -y -o Dpkg::Options::="--force-confmiss" \
        nginx-full \
        python3-certbot-nginx \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-common \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-dev \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-tokenizer \
        php${PHP_VERSION}-ctype \
        php${PHP_VERSION}-fileinfo \
        php${PHP_VERSION}-json \
        git \
        unzip \
        curl \
        wget \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        supervisor \
        valkey \
        valkey-compat \
        openvpn \
        easy-rsa \
        freeradius \
        freeradius-mysql \
        freeradius-utils \
        mariadb-server \
        mariadb-client || handle_error "Failed to reinstall packages"
else
    apt-get install -y \
        nginx-full \
        python3-certbot-nginx \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-common \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-dev \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-tokenizer \
        php${PHP_VERSION}-ctype \
        php${PHP_VERSION}-fileinfo \
        php${PHP_VERSION}-json \
        git \
        unzip \
        curl \
        wget \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        supervisor \
        valkey \
        valkey-compat \
        openvpn \
        easy-rsa \
        freeradius \
        freeradius-mysql \
        freeradius-utils \
        mariadb-server \
        mariadb-client || handle_error "Failed to install packages"
fi
COMPLETED_STEPS+=("Required packages installed")

# Configure Valkey with optimal settings for FreeRADIUS
log_step "Configuring Valkey with optimized settings"

# Calculate optimal memory allocation (75% of available RAM, capped at 3GB, minimum 1GB)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
MAX_MEMORY_MB=$((TOTAL_RAM_MB * 75 / 100))
if [ "$MAX_MEMORY_MB" -gt 3072 ]; then
    MAX_MEMORY_MB=3072  # Cap at 3GB
fi
if [ "$MAX_MEMORY_MB" -lt 1024 ]; then
    MAX_MEMORY_MB=1024  # Minimum 1GB
fi

log_info "Configuring Valkey with ${MAX_MEMORY_MB}MB memory allocation"

# Create Valkey configuration directory if it doesn't exist
mkdir -p /etc/valkey || handle_error "Failed to create Valkey configuration directory"

# Configure Valkey with optimized settings for FreeRADIUS
cat > /etc/valkey/valkey.conf << EOL
# Valkey configuration for FreeRADIUS

bind 0.0.0.0 ::0
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

# Security
# Reuse the same password as MySQL for simplicity
requirepass "$MYSQL_PASSWORD"

# Network
tcp-keepalive 300
repl-timeout 60
repl-ping-slave-period 10
repl-backlog-size 1mb
repl-backlog-ttl 3600

# Client timeouts
timeout 0
tcp-keepalive 300

# Disable dangerous commands
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command CONFIG ""
rename-command SHUTDOWN ""

# Set the number of threads to serve the requests
io-threads 2
io-threads-do-reads yes

# Set the max number of connected clients at the same time
maxclients 10000

# Set the threshold for keys with an expire set to be considered for deletion
active-expire-effort 1

# Set the threshold for client output buffer limits
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60

# Tune hash data structure
hash-max-ziplist-entries 512
hash-max-ziplist-value 64

# Tune list data structure
list-max-ziplist-size -2

# Tune set data structure
set-max-intset-entries 512

# Tune zset data structure
zset-max-ziplist-entries 128
zset-max-ziplist-value 64

# Tune hll data structure
hll-sparse-max-bytes 3000

# Tune stream data structure
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

# Set proper permissions for Valkey directories
log_step "Setting Valkey directory permissions"
mkdir -p /var/lib/valkey/appendonlydir
chown -R valkey:valkey /var/lib/valkey /var/log/valkey /var/run/valkey
chmod 750 /var/lib/valkey /var/log/valkey /var/run/valkey

# Fix Valkey service
sed -i 's/ConditionPathExists=!\/etc\/valkey\/REDIS_MIGRATION/ConditionPathExists=\/etc\/valkey\/REDIS_MIGRATION/g' /usr/lib/systemd/system/valkey.service

# Restart Valkey to apply new configuration
systemctl daemon-reexec || log_warning "daemon-reexec failed (non-critical)"
systemctl daemon-reload || handle_error "Failed to reload systemd daemon"
systemctl restart valkey || handle_error "Failed to restart Valkey"
systemctl enable valkey || handle_error "Failed to enable Valkey"

# Verify Valkey is running
log_step "Verifying Valkey service status"

# Check service status
if systemctl is-active --quiet valkey; then
    log_success "Valkey service is running"
    COMPLETED_STEPS+=("Valkey configured with ${MAX_MEMORY_MB}MB memory allocation")
else
    # If service is not running, try to get more information
    log_warning "Valkey service is not running as expected. Checking status..."
    systemctl status valkey --no-pager || true
    
    # Try to start the service
    log_info "Attempting to start Valkey service..."
    if systemctl start valkey; then
        log_success "Successfully started Valkey service"
        COMPLETED_STEPS+=("Valkey configured with ${MAX_MEMORY_MB}MB memory allocation")
    else
        # If we still can't start, show detailed error but don't fail the script
        log_error "Failed to start Valkey service. Please check the logs with: journalctl -u valkey -n 50"
        log_warning "Continuing installation despite Valkey service issue..."
        COMPLETED_STEPS+=("Valkey configuration completed but service failed to start")
    fi
fi

# Create Valkey debug script
log_step "Creating Valkey debug script"
cat > /usr/local/bin/valkey-debug.sh << 'EOF'
#!/bin/bash

VALKEY_HOST="127.0.0.1"
VALKEY_PORT="6379"

echo "=== Valkey Status ==="
systemctl status valkey --no-pager -l

echo -e "\n=== Valkey Key Statistics ==="
echo "Total Keys in DB 0: $(valkey-cli -h $VALKEY_HOST -p $VALKEY_PORT dbsize)"

EOF

chmod +x /usr/local/bin/valkey-debug.sh

COMPLETED_STEPS+=("Valkey monitoring configured")

# Add monitoring cron job
log_step "Adding monitoring cron job"
echo "*/5 * * * * /usr/local/bin/valkey-debug.sh" > cronjob || handle_error "Failed to write monitoring cron job to temporary file"
crontab cronjob || handle_error "Failed to install monitoring cron job"
rm cronjob || handle_error "Failed to remove temporary monitoring cron job file"
COMPLETED_STEPS+=("Monitoring cron job added")

# Verify Valkey is working
log_step "Verifying Valkey installation"
if ! systemctl is-active --quiet valkey; then
handle_error "Valkey service is not running"
fi

# Test Valkey connectivity and basic operations
if [ "$(valkey-cli ping)" != "PONG" ]; then
handle_error "Valkey is not responding to ping"
fi

# Test Valkey write operation
if [ "$(valkey-cli set test_key test_value)" != "OK" ]; then
handle_error "Valkey write operation failed"
fi

# Test Valkey read operation
TEST_VALUE=$(valkey-cli get test_key)
if [ "$TEST_VALUE" != "test_value" ]; then
handle_error "Valkey read operation failed"
fi

# Test Valkey delete operation
if [ "$(valkey-cli del test_key)" != "1" ]; then
handle_error "Valkey delete operation failed"
fi

# Check Valkey info for basic stats
if ! valkey-cli info | grep -q "valkey_version"; then
handle_error "Unable to get Valkey server information"
fi

COMPLETED_STEPS+=("Valkey functionality verified")

# Set Default PHP Version
log_step "Setting default PHP version"
update-alternatives --set php /usr/bin/php${PHP_VERSION} || handle_error "Failed to set default PHP version"
COMPLETED_STEPS+=("PHP ${PHP_VERSION} set as default")

# Install and configure ionCube Loader
log_step "Installing ionCube Loader"

# Check if ionCube is already installed
if [ -d "/usr/local/ioncube" ] && [ -f "/usr/local/ioncube/ioncube_loader_lin_${PHP_VERSION}.so" ]; then
    log_info "ionCube Loader already exists, skipping download and installation"
    COMPLETED_STEPS+=("ionCube Loader reused (already exists)")
else
    log_info "ionCube Loader not found, downloading and installing"
    
    # Change to /tmp directory for downloads
    cd /tmp || handle_error "Failed to change to /tmp directory"
    
    # Download and extract ionCube
    wget -O ioncube.zip "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.zip" || handle_error "Failed to download ionCube"
    unzip -q ioncube.zip || handle_error "Failed to extract ionCube"
    
    # Remove existing ionCube directory if it exists
    rm -rf /usr/local/ioncube 2>/dev/null
    
    # Move the ioncube directory to /usr/local
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

# Restart PHP-FPM to load ionCube
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

# Initialize MariaDB system database if not already done
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
# This script is executed by "/etc/init.d/mysql" on every (re)start.

# Exit if the script is not being run by root
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Exit successfully if mysql is not running
if ! /usr/bin/mysqladmin --defaults-file=/etc/mysql/debian.cnf ping > /dev/null 2>&1; then
  exit 0
fi

# Exit successfully
exit 0
EOF
    chmod +x /etc/mysql/debian-start || handle_error "Failed to make debian-start executable"
    log_success "Created /etc/mysql/debian-start script"
fi

COMPLETED_STEPS+=("MariaDB initialized, started and enabled")

# Configure MySQL to allow remote connections and optimize performance
log_step "Configuring MySQL for remote connections and performance"

# Create MariaDB configuration directory if it doesn't exist
mkdir -p /etc/mysql/mariadb.conf.d/

# Configure MariaDB
cat > /etc/mysql/mariadb.conf.d/50-server.cnf << 'EOL'
[mysqld]
user                    = mysql
pid-file                = /run/mysqld/mysqld.pid
socket                  = /run/mysqld/mysqld.sock
port                    = 3306
basedir                 = /usr
datadir                 = /var/lib/mysql
tmpdir                  = /tmp
lc-messages-dir         = /usr/share/mysql
lc-messages             = en_US
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

# Performance optimizations
innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1

[embedded]

[mariadb]

[mariadb-10.6]
EOL

# Restart MariaDB to apply changes
systemctl restart mariadb || handle_error "Failed to restart MariaDB after configuration change"
COMPLETED_STEPS+=("MySQL configured for remote connections")

# Get server hostname and set email
DOMAIN=$(hostname -f)
EMAIL_ADDRESS="simpluxsolutions@gmail.com"

# Generate random credentials or reuse existing ones
DB_CREDENTIALS_FILE="/root/db.txt"

# Check if db.txt exists and contains valid credentials
if [ -f "$DB_CREDENTIALS_FILE" ] && [ -r "$DB_CREDENTIALS_FILE" ]; then
    log_step "Found existing database credentials, reusing them"
    
    # Extract credentials from existing db.txt file
    MYSQL_USER=$(grep "^DB_USERNAME=" "$DB_CREDENTIALS_FILE" | cut -d'=' -f2)
    MYSQL_PASSWORD=$(grep "^DB_PASSWORD=" "$DB_CREDENTIALS_FILE" | cut -d'=' -f2)
    MYSQL_DATABASE=$(grep "^DB_DATABASE=" "$DB_CREDENTIALS_FILE" | cut -d'=' -f2)
    
    # Validate that we got all required credentials
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
mysql -e "CREATE DATABASE $MYSQL_DATABASE;" || handle_error "Failed to create database"

# Create user with access from any host
mysql -e "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" || handle_error "Failed to create database user"

# Grant privileges for all hosts
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


# Setup Laravel application
log_step "Setting up Laravel application"
LOCAL_PATH="/var/www/html"
REPO_URL="$GITHUB_REPO_URL"

# Remove existing web root if it exists (no backup)
if [ -d "$LOCAL_PATH" ]; then
    rm -rf "$LOCAL_PATH" || handle_error "Failed to remove existing web root"
fi

# Clone the repository
git clone "$REPO_URL" "$LOCAL_PATH" || handle_error "Failed to clone repository"
cd "$LOCAL_PATH" || handle_error "Failed to change directory to web root"

# Install Laravel dependencies
log_step "Installing Laravel dependencies"
composer install --no-interaction || handle_error "Failed to install Laravel dependencies"
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


# Restart services
log_step "Restarting services"
systemctl restart mariadb || handle_error "Failed to restart MariaDB"
systemctl restart php${PHP_VERSION}-fpm || handle_error "Failed to restart PHP ${PHP_VERSION} FPM"
systemctl restart supervisor || handle_error "Failed to restart Supervisor"
systemctl restart openvpn || handle_error "Failed to restart OpenVPN"
COMPLETED_STEPS+=("Services restarted")

# Run Laravel migrations and seed the database
log_step "Running Laravel migrations and seeding database"
php artisan migrate --force || handle_error "Failed to run Laravel migrations"
php artisan db:seed --force || handle_error "Failed to seed database"
COMPLETED_STEPS+=("Laravel migrations run and database seeded")

# Optimize RADIUS database indexes
log_step "Optimizing RADIUS database indexes"
cat > /tmp/radius_optimize.sql << "EOL"
USE radius;

-- Add indexes to improve query performance

-- radcheck
ALTER TABLE radcheck
  ADD INDEX idx_username (username),
  ADD INDEX idx_attribute (attribute);
ANALYZE TABLE radcheck;

-- radreply
ALTER TABLE radreply
  ADD INDEX idx_username (username),
  ADD INDEX idx_attribute (attribute);
ANALYZE TABLE radreply;

-- radusergroup
ALTER TABLE radusergroup
  ADD INDEX idx_username (username),
  ADD INDEX idx_groupname (groupname);
ANALYZE TABLE radusergroup;

-- radgroupcheck
ALTER TABLE radgroupcheck
  ADD INDEX idx_groupname (groupname),
  ADD INDEX idx_attribute (attribute);
ANALYZE TABLE radgroupcheck;

-- radgroupreply
ALTER TABLE radgroupreply
  ADD INDEX idx_groupname (groupname),
  ADD INDEX idx_attribute (attribute);
ANALYZE TABLE radgroupreply;

-- radacct (very critical for performance)
ALTER TABLE radacct
  ADD INDEX idx_username (username),
  ADD INDEX idx_acctsessionid (acctsessionid),
  ADD INDEX idx_framedipaddress (framedipaddress),
  ADD INDEX idx_acctstarttime (acctstarttime),
  ADD INDEX idx_acctstoptime (acctstoptime),
  ADD INDEX idx_nasipaddress (nasipaddress),
  ADD INDEX idx_calledstationid (calledstationid),
  ADD INDEX idx_callingstationid (callingstationid);
ANALYZE TABLE radacct;

-- radpostauth
ALTER TABLE radpostauth
  ADD INDEX idx_username (username),
  ADD INDEX idx_reply (reply),
  ADD INDEX idx_authdate (authdate);
ANALYZE TABLE radpostauth;

-- hotspot_sessions
ALTER TABLE hotspot_sessions
  ADD INDEX idx_payment_voucher (payment_id, voucher);
ANALYZE TABLE hotspot_sessions;

-- Convert tables to InnoDB and utf8mb4 (recommended for reliability and Unicode support)
ALTER TABLE radcheck ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radreply ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radusergroup ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radgroupcheck ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radgroupreply ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radacct ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE radpostauth ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE hotspot_sessions ENGINE=InnoDB, CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Analyze again after engine/charset conversion
ANALYZE TABLE radcheck;
ANALYZE TABLE radreply;
ANALYZE TABLE radusergroup;
ANALYZE TABLE radgroupcheck;
ANALYZE TABLE radgroupreply;
ANALYZE TABLE radacct;
ANALYZE TABLE radpostauth;
ANALYZE TABLE hotspot_sessions;

EOL

mysql -u root < /tmp/radius_optimize.sql || handle_error "Failed to optimize RADIUS database indexes"
rm -f /tmp/radius_optimize.sql
COMPLETED_STEPS+=("RADIUS database indexes optimized")

# Configure FreeRADIUS
log_step "Configuring FreeRADIUS"

# Enable buffered-sql site
log_step "Enabling buffered-sql site"
# Ensure the sites-enabled directory exists
mkdir -p /etc/freeradius/sites-enabled || handle_error "Failed to create FreeRADIUS sites-enabled directory"
ln -sf /etc/freeradius/sites-available/buffered-sql /etc/freeradius/sites-enabled/buffered-sql || handle_error "Failed to enable buffered-sql site"
COMPLETED_STEPS+=("FreeRADIUS buffered-sql site enabled")

# Enable SQL module for FreeRADIUS
log_step "Enabling SQL module"
# Ensure the mods-enabled directory exists
mkdir -p /etc/freeradius/mods-enabled || handle_error "Failed to create FreeRADIUS mods-enabled directory"
ln -sf /etc/freeradius/mods-available/sql /etc/freeradius/mods-enabled/sql || handle_error "Failed to enable SQL module"
COMPLETED_STEPS+=("FreeRADIUS SQL module enabled")

# Configure FreeRADIUS REST module
log_step "Configuring FreeRADIUS REST module"
REST_CONFIG="/etc/freeradius/mods-available/rest"

# REST module disabled for SimpleISP to avoid connection errors during configuration test
#rm /etc/freeradius/mods-enabled/rest || handle_error "Failed to disable REST module"

if [ -f "$REST_CONFIG" ]; then
    # Update connect_uri to use domain/api instead of localhost
    sed -i 's|connect_uri = "http://127.0.0.1/"|connect_uri = "https://'$DOMAIN'/api"|g' "$REST_CONFIG" || handle_error "Failed to configure REST module connect_uri"
    # Also handle the commented version
    sed -i 's|# connect_uri = "http://127.0.0.1/"|connect_uri = "https://'$DOMAIN'/api"|g' "$REST_CONFIG" || true
fi

COMPLETED_STEPS+=("FreeRADIUS REST module configured (disabled for SimpleISP)")

# Ensure FreeRADIUS configuration files exist (restore if missing)
log_step "Checking FreeRADIUS radiusd.conf"
if [ ! -f "/etc/freeradius/radiusd.conf" ]; then
    log_info "FreeRADIUS configuration files missing, reinstalling and reconfiguring FreeRADIUS package"
    
    # Purge and reinstall FreeRADIUS to ensure clean configuration
    apt-get purge -y freeradius freeradius-common freeradius-config 2>/dev/null || echo "FreeRADIUS not installed"
    apt-get autoremove -y 2>/dev/null
    apt-get install -y freeradius freeradius-mysql freeradius-utils || handle_error "Failed to reinstall FreeRADIUS"
    
    # Reconfigure the package to ensure configuration files are created
    dpkg-reconfigure -f noninteractive freeradius-config 2>/dev/null || echo "Reconfigure not needed"
    
    # Verify configuration file was created
    if [ ! -f "/etc/freeradius/radiusd.conf" ]; then
        # Create a minimal radiusd.conf if still missing
        log_info "Creating minimal radiusd.conf configuration"
        mkdir -p /etc/freeradius
        cat > /etc/freeradius/radiusd.conf << 'EOF'
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
        chmod 644 /etc/freeradius/radiusd.conf
        log_success "Created minimal radiusd.conf configuration"
    fi
    
    # Re-enable modules after reinstallation
    if [ -f "/etc/freeradius/mods-available/sql" ]; then
        ln -sf /etc/freeradius/mods-available/sql /etc/freeradius/mods-enabled/ || handle_error "Failed to re-enable SQL module"
    fi
    if [ -f "/etc/freeradius/mods-available/rest" ]; then
        # REST module disabled for SimpleISP to avoid connection errors during configuration test
        # ln -sf /etc/freeradius/mods-available/rest /etc/freeradius/mods-enabled/rest || handle_error "Failed to re-enable REST module"
        log_info "REST module configuration skipped for SimpleISP"
    fi
    log_success "FreeRADIUS configuration files restored"
fi

COMPLETED_STEPS+=("Completed checking radiusd.conf")

# Write new FreeRADIUS SQL module
log_step "Writing new FreeRADIUS SQL module"

SQL_FILE="/etc/freeradius/mods-available/sql"

# Backup if it exists
[ -f "$SQL_FILE" ] && cp "$SQL_FILE" "${SQL_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

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
DEFAULT_SITE="/etc/freeradius/sites-enabled/default"
if [ -f "$DEFAULT_SITE" ]; then
    # Change -sql to sql
    sed -i 's/-sql/sql/g' "$DEFAULT_SITE" || handle_error "Failed to update -sql to sql in FreeRADIUS default site configuration"

    # Comment out detail line
    sed -i 's/^[[:space:]]*detail/#       detail/' "$DEFAULT_SITE" || handle_error "Failed to comment out detail line in FreeRADIUS default site configuration"
fi

COMPLETED_STEPS+=("FreeRADIUS default site configured")

# Start and enable FreeRADIUS now that database tables are ready
log_step "Starting and enabling FreeRADIUS"
systemctl start freeradius || handle_error "Failed to start FreeRADIUS"
systemctl enable freeradius || handle_error "Failed to enable FreeRADIUS"
systemctl restart freeradius || handle_error "Failed to restart FreeRADIUS"
COMPLETED_STEPS+=("FreeRADIUS started and enabled")

# Configure Supervisor for queue worker
log_step "Configuring Supervisor for queue worker"
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
        curl -O https://raw.githubusercontent.com/simpleisp/bash/main/openvpn.sh || handle_error "Failed to download OpenVPN installer"
        chmod +x openvpn.sh || handle_error "Failed to make OpenVPN installer executable"
        ./openvpn.sh || handle_error "Failed to install OpenVPN"

        # Enable and start OpenVPN service
        systemctl enable openvpn || handle_error "Failed to enable OpenVPN service"
        systemctl start openvpn || handle_error "Failed to start OpenVPN service"

        # Set more secure permissions for OpenVPN
        chown -R root:root /etc/openvpn || handle_error "Failed to set ownership of OpenVPN configuration directory"
        chmod -R 777 /etc/openvpn || handle_error "Failed to set permissions of OpenVPN configuration directory"
        chmod -R 777 /etc/openvpn/easy-rsa || handle_error "Failed to set permissions of OpenVPN easy-rsa directory"
        ;;
    *)
        handle_error "Unsupported Ubuntu version for OpenVPN installation: $UBUNTU_VERSION"
        ;;
esac
COMPLETED_STEPS+=("OpenVPN installed")

# Configure Nginx
log_step "Configuring Nginx"
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

# Enable the default site
log_step "Enabling Nginx default site"
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default || handle_error "Failed to enable Nginx default site"
COMPLETED_STEPS+=("Nginx default site enabled")

# Test the Nginx configuration
log_step "Testing Nginx configuration"
nginx -t || handle_error "Failed to test Nginx configuration"
COMPLETED_STEPS+=("Nginx configuration tested")

# If the configuration is OK, reload and restart Nginx
log_step "Reloading and restarting Nginx"
systemctl reload nginx || handle_error "Failed to reload Nginx"
systemctl restart nginx || handle_error "Failed to restart Nginx"
COMPLETED_STEPS+=("Nginx reloaded and restarted")

# Set correct permissions
log_step "Setting correct permissions"
chown -R www-data:www-data /var/www/html || handle_error "Failed to set ownership of web root"
chmod -R 775 /var/www/html/storage || handle_error "Failed to set permissions of storage directory"
chmod -R 775 /var/www/html/bootstrap/cache || handle_error "Failed to set permissions of cache directory"
COMPLETED_STEPS+=("Correct permissions set")

# Install cron
log_step "Installing cron"
# Write cron job entry to a temporary file
echo "* * * * * php /var/www/html/artisan schedule:run >> /dev/null 2>&1" > cronjob || handle_error "Failed to write cron job to temporary file"

# Install the cron job from the temporary file
crontab cronjob || handle_error "Failed to install cron job"
COMPLETED_STEPS+=("Cron job installed")

# Clean up the temporary file
rm cronjob || handle_error "Failed to remove temporary cron job file"
COMPLETED_STEPS+=("Temporary cron job file removed")

# Update sudoers for www-data user
log_step "Updating sudoers for www-data user"
cat >> /etc/sudoers << "EOL"
www-data ALL=NOPASSWD: /bin/systemctl start openvpn
www-data ALL=NOPASSWD: /bin/systemctl stop openvpn
www-data ALL=NOPASSWD: /bin/systemctl restart openvpn
www-data ALL=NOPASSWD: /bin/systemctl status openvpn
www-data ALL=NOPASSWD: /bin/systemctl reload openvpn
www-data ALL=NOPASSWD: /bin/systemctl enable openvpn
www-data ALL=NOPASSWD: /bin/systemctl disable openvpn
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
COMPLETED_STEPS+=("Sudoers updated for www-data user")

# Save database credentials
log_step "Saving database credentials"
echo "MySQL Credentials:" > "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_HOST=localhost" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_PORT=3306" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_DATABASE=$MYSQL_DATABASE" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_USERNAME=$MYSQL_USER" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
echo "DB_PASSWORD=$MYSQL_PASSWORD" >> "$DB_CREDENTIALS_FILE" || handle_error "Failed to write database credentials to file"
COMPLETED_STEPS+=("Database credentials saved")

# Start and enable all services
log_step "Starting and enabling all services"
systemctl start nginx || handle_error "Failed to start Nginx"
systemctl enable nginx || handle_error "Failed to enable Nginx"
systemctl start php${PHP_VERSION}-fpm || handle_error "Failed to start PHP ${PHP_VERSION} FPM"
systemctl enable php${PHP_VERSION}-fpm || handle_error "Failed to enable PHP ${PHP_VERSION} FPM"
systemctl start supervisor || handle_error "Failed to start Supervisor"
systemctl enable supervisor || handle_error "Failed to enable Supervisor"
systemctl start openvpn || handle_error "Failed to start OpenVPN"
systemctl enable openvpn || handle_error "Failed to enable OpenVPN"
COMPLETED_STEPS+=("Core services started and enabled")

# Restart all services to ensure proper configuration
log_step "Restarting all services"
systemctl restart nginx || handle_error "Failed to restart Nginx"
systemctl restart php${PHP_VERSION}-fpm || handle_error "Failed to restart PHP ${PHP_VERSION} FPM"
systemctl restart supervisor || handle_error "Failed to restart Supervisor"
systemctl restart openvpn || handle_error "Failed to restart OpenVPN"
COMPLETED_STEPS+=("Services restarted")

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

# Configure SSL with Certbot
log_step "Configuring SSL with Certbot"
echo "Configuring SSL certificate for $DOMAIN"

# Check if SSL certificate already exists for this domain
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    log_info "SSL certificate already exists for $DOMAIN, configuring it in Nginx"
    # Configure existing certificate in Nginx
    certbot --nginx -d "$DOMAIN" --agree-tos --email "$EMAIL_ADDRESS" --no-eff-email --non-interactive --redirect || handle_error "Failed to configure existing SSL certificate in Nginx"
    COMPLETED_STEPS+=("SSL certificate configured in Nginx (existing certificate)")
else
    log_info "No existing SSL certificate found for $DOMAIN, requesting new certificate"
    certbot --nginx -d "$DOMAIN" --agree-tos --email "$EMAIL_ADDRESS" --no-eff-email --non-interactive --redirect || handle_error "Failed to configure SSL with Certbot"
    COMPLETED_STEPS+=("SSL configured with Certbot")
fi

# Create cleanup script for uninstalling all software
log_step "Creating cleanup script"
cat > /root/clean_server.sh << 'EOL'
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
systemctl stop nginx freeradius mariadb valkey php${PHP_VERSION}-fpm supervisor openvpn || echo "Could not stop all services"

# Remove web files
log_step "Removing web files"
rm -rf /var/www/html/* 2>/dev/null
rm -rf /var/www/html/.* 2>/dev/null

# Remove configuration directories
log_step "Removing configuration directories"
rm -rf /etc/nginx/sites-available/default 2>/dev/null
rm -rf /etc/nginx/sites-enabled/default 2>/dev/null
rm -rf /etc/freeradius 2>/dev/null
rm -rf /etc/openvpn 2>/dev/null
rm -rf /etc/supervisor 2>/dev/null

# Remove Redis data
log_step "Removing Redis data"
rm -rf /var/lib/redis/* 2>/dev/null
rm -rf /var/lib/redis/.* 2>/dev/null

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
EOL

# Make the cleanup script executable
chmod +x /root/clean_server.sh || handle_error "Failed to make cleanup script executable"
log_success "Cleanup script created at /root/clean_server.sh"
COMPLETED_STEPS+=("Cleanup script created at /root/clean_server.sh")

log_success "Installation completed successfully!"
echo "You can find your database credentials in $DB_CREDENTIALS_FILE"
echo "Your SimpleISP installation is available at: https://$DOMAIN"
echo "Installation logs are available at: $INSTALL_LOG"
echo "To uninstall everything and clean the server, run: /root/clean_server.sh"
