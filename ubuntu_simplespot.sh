#!/bin/bash

# Setup logging and error handling
INSTALL_LOG="/root/install.txt"
STEP_COUNT=0
COMPLETED_STEPS=()

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

# Ensure script runs as root
log_step "Checking root privileges"
if [ "$EUID" -ne 0 ]; then
    handle_error "Please run as root"
fi
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

# Set environment variable to avoid interactive prompts
export DEBIAN_FRONTEND=noninteractive

# Update and upgrade system
log_step "Updating system packages"
apt-get update || handle_error "Failed to update package lists"
apt-get upgrade -y || handle_error "Failed to upgrade packages"
COMPLETED_STEPS+=("System packages updated")

# Install required packages
log_step "Installing required packages"
apt-get install -y \
    nginx-full \
    python3-certbot-nginx \
    php8.2-fpm \
    php8.2-mysql \
    php8.2-curl \
    php8.2-zip \
    php8.2-common \
    php8.2-gd \
    php8.2-mbstring \
    php8.2-xml \
    git \
    unzip \
    curl \
    supervisor \
    openssl \
    mariadb-server \
    mariadb-client \
    freeradius \
    freeradius-utils \
    freeradius-mysql \
    freeradius-redis \
    cron \
    easy-rsa \
    redis-tools \
    golang-go \
    software-properties-common || handle_error "Failed to install required packages"
COMPLETED_STEPS+=("Required packages installed")

# Set default timezone
log_step "Setting timezone"
timedatectl set-timezone Africa/Nairobi || handle_error "Failed to set timezone"
COMPLETED_STEPS+=("Timezone set to Africa/Nairobi")

# Set Default PHP Version
log_step "Setting default PHP version"
update-alternatives --set php /usr/bin/php8.2 || handle_error "Failed to set default PHP version"
COMPLETED_STEPS+=("PHP 8.2 set as default")

# Start and enable MariaDB
log_step "Configuring MariaDB"
systemctl start mariadb || handle_error "Failed to start MariaDB"
systemctl enable mariadb || handle_error "Failed to enable MariaDB"
COMPLETED_STEPS+=("MariaDB started and enabled")

# Configure MySQL to allow remote connections
log_step "Configuring MySQL for remote connections"
sed -i 's/^bind-address.*$/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf || handle_error "Failed to update MySQL bind address"

# Restart MariaDB to apply changes
systemctl restart mariadb || handle_error "Failed to restart MariaDB after configuration change"
COMPLETED_STEPS+=("MySQL configured for remote connections")

# Get server hostname and set email
DOMAIN=$(hostname -f)
EMAIL_ADDRESS="simpluxsolutions@gmail.com"

# Generate random credentials
MYSQL_USER="user_$(openssl rand -hex 3)"
MYSQL_PASSWORD="$(openssl rand -base64 12)"
MYSQL_DATABASE="radius"
DB_CREDENTIALS_FILE="/home/sisp/db.txt"

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

# Install DragonflyDB
log_step "Installing DragonflyDB"
wget https://dragonflydb.gateway.scarf.sh/latest/dragonfly_amd64.deb || handle_error "Failed to download DragonflyDB"
dpkg -i dragonfly_amd64.deb || handle_error "Failed to install DragonflyDB"
apt install -fy || handle_error "Failed to install DragonflyDB dependencies"
COMPLETED_STEPS+=("DragonflyDB installed")

# Configure DragonflyDB
log_step "Configuring DragonflyDB"
cat > /etc/dragonfly/dragonfly.conf << 'EOL'
--pidfile=/var/run/dragonfly/dragonfly.pid
--log_dir=/var/log/dragonfly
--dir=/var/lib/dragonfly
--max_log_size=1
--version_check=true
--cache_mode=true  
--snapshot_cron=*/30 * * * * 
--maxmemory=4gb 
--keys_output_limit=12288 
--dbfilename=dump
EOL

chown dfly:dfly /etc/dragonfly/dragonfly.conf || handle_error "Failed to set DragonflyDB config permissions"

# Setup DragonflyDB service
# Default is to not enable the service (0=off, 1=on)
ENABLE_DRAGONFLY=0
log_info "DragonflyDB auto-start is set to: $([ "$ENABLE_DRAGONFLY" -eq 1 ] && echo "ON" || echo "OFF")"

# Always start the service for this session
systemctl start dragonfly.service || handle_error "Failed to start DragonflyDB"

# Only enable the service if flag is set to 1
if [ "$ENABLE_DRAGONFLY" -eq 1 ]; then
    systemctl enable dragonfly.service || handle_error "Failed to enable DragonflyDB"
    log_success "DragonflyDB service enabled to start on boot"
else
    systemctl disable dragonfly.service || log_info "DragonflyDB service will not start on boot"
    log_success "DragonflyDB started for this session only (not enabled on boot)"
fi
COMPLETED_STEPS+=("DragonflyDB configured")

# Configure Redis modules for FreeRADIUS
log_step "Configuring Redis modules"

# Configure Redis module
if [ -f "/etc/freeradius/mods-available/redis" ]; then
    # Add db = 0 after port configuration
    sed -i '/^[[:space:]]*port[[:space:]]*=.*/ a\        db = 0' /etc/freeradius/mods-available/redis
else
    handle_error "Redis module configuration file not found"
fi

# Enable modules
log_step "Enabling modules"
ln -sf /etc/freeradius/mods-available/redis /etc/freeradius/mods-enabled/ || handle_error "Failed to enable Redis module"
ln -sf /etc/freeradius/mods-available/rediswho /etc/freeradius/mods-enabled/ || handle_error "Failed to enable RedisWho module"
ln -sf /etc/freeradius/mods-available/sql /etc/freeradius/mods-enabled/ || handle_error "Failed to enable SQL module"
COMPLETED_STEPS+=("Freeradius Modules Enabled")

# Setup Redis monitoring
log_step "Setting up Redis monitoring"

# Create monitoring directory
mkdir -p /var/log/freeradius || handle_error "Failed to create monitoring directory"

# Create Redis monitoring script
cat > /usr/local/bin/redis-monitor.sh << 'EOF'
#!/bin/bash

REDIS_HOST="127.0.0.1"
REDIS_PORT="6379"
LOG_FILE="/var/log/freeradius/redis-monitor.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

if ! redis-cli -h $REDIS_HOST -p $REDIS_PORT ping > /dev/null; then
    log "ERROR: DragonflyDB is not responding"
    exit 1
fi

STATS=$(redis-cli -h $REDIS_HOST -p $REDIS_PORT info)
log "Memory Usage: $(echo "$STATS" | grep used_memory_human | cut -d: -f2)"
log "Connected Clients: $(echo "$STATS" | grep connected_clients | cut -d: -f2)"
log "Total Commands: $(echo "$STATS" | grep total_commands_processed | cut -d: -f2)"
log "Cache Hit Rate: $(echo "$STATS" | grep keyspace_hits | cut -d: -f2)"
log "Cache Miss Rate: $(echo "$STATS" | grep keyspace_misses | cut -d: -f2)"
log "Keys in DB 0: $(redis-cli -h $REDIS_HOST -p $REDIS_PORT dbsize)"
EOF

chmod +x /usr/local/bin/redis-monitor.sh

# Add monitoring cron job
log_step "Setting up Redis monitoring cron job"
MONITOR_CRON="*/5 * * * * /usr/local/bin/redis-monitor.sh"
(crontab -l 2>/dev/null | grep -v "redis-monitor"; echo "$MONITOR_CRON") | crontab -

# Create Redis debug script
log_step "Creating Redis debug script"
cat > /usr/local/bin/redis-debug.sh << 'EOF'
#!/bin/bash

REDIS_HOST="127.0.0.1"
REDIS_PORT="6379"

echo "=== DragonflyDB Status ==="
redis-cli -h $REDIS_HOST -p $REDIS_PORT info | grep -E "used_memory_human|connected_clients|total_commands|keyspace"

echo -e "\n=== Redis Key Statistics ==="
echo "Total Keys in DB 0: $(redis-cli -h $REDIS_HOST -p $REDIS_PORT dbsize)"

echo -e "\n=== FreeRADIUS Redis Status ==="
if radiusd -XC | grep -q "rlm_redis"; then
    echo "Redis module loaded successfully"
else
    echo "ERROR: Redis module not loaded"
fi

echo -e "\n=== Recent FreeRADIUS Logs ==="
tail -n 20 /var/log/freeradius/radius.log

echo -e "\n=== Recent Monitoring Logs ==="
tail -n 20 /var/log/freeradius/redis-monitor.log
EOF

chmod +x /usr/local/bin/redis-debug.sh

COMPLETED_STEPS+=("Redis monitoring configured")

# Enable buffered-sql site
ln -sf /etc/freeradius/sites-available/buffered-sql /etc/freeradius/sites-enabled/ || handle_error "Failed to enable buffered-sql site"
COMPLETED_STEPS+=("Buffered SQL site enabled")

# Setup Laravel application
log_step "Setting up Laravel application"
LOCAL_PATH="/var/www/html"
REPO_URL="https://github.com/simpleisp/simplespot.git"

# Backup existing web root if it exists
if [ -d "$LOCAL_PATH" ]; then
    mv "$LOCAL_PATH" "${LOCAL_PATH}_backup_$(date +%Y%m%d_%H%M%S)" || handle_error "Failed to backup existing web root"
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
COMPLETED_STEPS+=(".env file updated with database credentials")

# Configure FreeRADIUS
log_step "Configuring FreeRADIUS"
SQL_FILE="/etc/freeradius/mods-available/sql"
if [ -f "$SQL_FILE" ]; then
    # Configure SQL driver and dialect
    sed -i 's/[# ]*driver = "rlm_sql_null"/        driver = "rlm_sql_mysql"/' "$SQL_FILE" || handle_error "Failed to update driver in FreeRADIUS SQL configuration"
    sed -i 's/[# ]*dialect = "mysql"/        dialect = "mysql"/' "$SQL_FILE" || handle_error "Failed to update dialect in FreeRADIUS SQL configuration"

    # Update only the connection info section
    sed -i 's/^#*[[:space:]]*server[[:space:]]*=.*$/        server = "localhost"/' "$SQL_FILE" || handle_error "Failed to update server in FreeRADIUS SQL configuration"
    sed -i 's/^#*[[:space:]]*port[[:space:]]*=.*$/        port = 3306/' "$SQL_FILE" || handle_error "Failed to update port in FreeRADIUS SQL configuration"
    sed -i "s/^#*[[:space:]]*login[[:space:]]*=.*$/        login = \"$MYSQL_USER\"/" "$SQL_FILE" || handle_error "Failed to update login in FreeRADIUS SQL configuration"
    sed -i "s/^#*[[:space:]]*password[[:space:]]*=.*$/        password = \"$MYSQL_PASSWORD\"/" "$SQL_FILE" || handle_error "Failed to update password in FreeRADIUS SQL configuration"
    sed -i "s/^#*[[:space:]]*radius_db[[:space:]]*=.*$/        radius_db = \"$MYSQL_DATABASE\"/" "$SQL_FILE" || handle_error "Failed to update radius_db in FreeRADIUS SQL configuration"

    # Comment out TLS configuration
    sed -i '/mysql {/,/^[[:space:]]*}$/c\mysql {\n        # TLS configuration commented out' "$SQL_FILE" || handle_error "Failed to comment out TLS configuration in FreeRADIUS SQL configuration"

    # Uncomment client_table
    sed -i 's/[# ]*client_table = "nas"/        client_table = "nas"/' "$SQL_FILE" || handle_error "Failed to uncomment client_table in FreeRADIUS SQL configuration"

    # Enable SQL module in FreeRADIUS
    ln -sf /etc/freeradius/mods-available/sql /etc/freeradius/mods-enabled/ || handle_error "Failed to enable SQL module in FreeRADIUS"
fi
COMPLETED_STEPS+=("FreeRADIUS configured")

# Configure FreeRADIUS default site
log_step "Configuring FreeRADIUS default site"
DEFAULT_SITE="/etc/freeradius/sites-enabled/default"
if [ -f "$DEFAULT_SITE" ]; then
    # Change -sql to sql
    sed -i 's/-sql/sql/g' "$DEFAULT_SITE" || handle_error "Failed to update -sql to sql in FreeRADIUS default site configuration"

    # Comment out detail line
    sed -i 's/^[[:space:]]*detail/#       detail/' "$DEFAULT_SITE" || handle_error "Failed to comment out detail line in FreeRADIUS default site configuration"
fi

# Update default site to use Redis modules
log_step "Configuring Redis in sites"
DEFAULT_SITE="/etc/freeradius/sites-enabled/default"

# Add rediswho to authorize section after sql (commented out)
if [ -f "$DEFAULT_SITE" ]; then
    sed -i '/^[[:space:]]*sql[[:space:]]*$/a\        #rediswho' "$DEFAULT_SITE" || handle_error "Failed to add rediswho to default site authorize section"
else
    handle_error "Default site configuration file not found"
fi

COMPLETED_STEPS+=("FreeRADIUS default site configured")

# Restart services
log_step "Restarting services"
systemctl restart dragonfly || handle_error "Failed to restart DragonflyDB"
systemctl restart freeradius || handle_error "Failed to restart FreeRADIUS"
COMPLETED_STEPS+=("Services restarted")

# Verify Redis is working
log_step "Verifying Redis installation"
if ! systemctl is-active --quiet dragonfly; then
    handle_error "DragonflyDB service is not running"
fi

# Test Redis connectivity and basic operations
if [ "$(redis-cli ping)" != "PONG" ]; then
    handle_error "Redis is not responding to ping"
fi

# Test Redis write operation
if [ "$(redis-cli set test_key test_value)" != "OK" ]; then
    handle_error "Redis write operation failed"
fi

# Test Redis read operation
TEST_VALUE=$(redis-cli get test_key)
if [ "$TEST_VALUE" != "test_value" ]; then
    handle_error "Redis read operation failed"
fi

# Test Redis delete operation
if [ "$(redis-cli del test_key)" != "1" ]; then
    handle_error "Redis delete operation failed"
fi

# Check Redis info for basic stats
if ! redis-cli info | grep -q "redis_version"; then
    handle_error "Unable to get Redis server information"
fi

COMPLETED_STEPS+=("Redis functionality verified")

# Test FreeRADIUS configuration
log_step "Testing FreeRADIUS configuration"
if ! freeradius -XC 2>&1 | grep -q "Configuration appears to be OK"; then
    handle_error "FreeRADIUS configuration test failed"
fi
COMPLETED_STEPS+=("FreeRADIUS configuration tested")

# Run Laravel migrations and seed the database
log_step "Running Laravel migrations and seeding database"
php artisan migrate --force || handle_error "Failed to run Laravel migrations"
php artisan db:seed --force || handle_error "Failed to seed database"
COMPLETED_STEPS+=("Laravel migrations run and database seeded")

# Optimize RADIUS database indexes
log_step "Optimizing RADIUS database indexes"
cat > /tmp/radius_optimize.sql << EOL
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

# Configure Supervisor for queue worker
log_step "Configuring Supervisor for queue worker"
cat > /etc/supervisor/conf.d/queue-worker.conf << EOL
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
        chmod -R 750 /etc/openvpn || handle_error "Failed to set permissions of OpenVPN configuration directory"
        chmod -R 700 /etc/openvpn/easy-rsa || handle_error "Failed to set permissions of OpenVPN easy-rsa directory"
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
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL
COMPLETED_STEPS+=("Nginx configured")

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
cat >> /etc/sudoers << EOL
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
systemctl start php8.2-fpm || handle_error "Failed to start PHP 8.2 FPM"
systemctl enable php8.2-fpm || handle_error "Failed to enable PHP 8.2 FPM"
systemctl start supervisor || handle_error "Failed to start Supervisor"
systemctl enable supervisor || handle_error "Failed to enable Supervisor"
systemctl start freeradius || handle_error "Failed to start FreeRADIUS"
systemctl enable freeradius || handle_error "Failed to enable FreeRADIUS"
systemctl start openvpn || handle_error "Failed to start OpenVPN"
systemctl enable openvpn || handle_error "Failed to enable OpenVPN"
COMPLETED_STEPS+=("All services started and enabled")

# Restart all services to ensure proper configuration
log_step "Restarting all services"
systemctl restart nginx || handle_error "Failed to restart Nginx"
systemctl restart php8.2-fpm || handle_error "Failed to restart PHP 8.2 FPM"
systemctl restart supervisor || handle_error "Failed to restart Supervisor"
systemctl restart freeradius || handle_error "Failed to restart FreeRADIUS"
systemctl restart openvpn || handle_error "Failed to restart OpenVPN"
COMPLETED_STEPS+=("All services restarted")

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
certbot --nginx -d "$DOMAIN" --agree-tos --email "$EMAIL_ADDRESS" --no-eff-email --non-interactive --redirect || handle_error "Failed to configure SSL with Certbot"
COMPLETED_STEPS+=("SSL configured with Certbot")

log_success "Installation completed successfully!"
echo "You can find your database credentials in $DB_CREDENTIALS_FILE"
echo "Your SimpleISP installation is available at: https://$DOMAIN"
echo "Installation logs are available at: $INSTALL_LOG"