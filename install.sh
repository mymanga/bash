#!/bin/bash

# Ensure script runs as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Setup logging
INSTALL_LOG="/home/sisp/install.txt"
touch $INSTALL_LOG
exec &> >(tee -a "$INSTALL_LOG")

# Get server hostname and set email
DOMAIN=$(hostname -f)
EMAIL_ADDRESS="simpluxsolutions@gmail.com"

# Set environment variable to avoid interactive prompts
export DEBIAN_FRONTEND=noninteractive

echo "Starting SimpleISP installation for domain: $DOMAIN"

# Update and upgrade system
apt-get update && apt-get upgrade -y

# Install required packages
apt-get install -y \
    nginx \
    python3-certbot-nginx \
    php7.4-fpm \
    php7.4-mysql \
    php7.4-curl \
    php7.4-zip \
    php-common \
    php-gd \
    php-mbstring \
    php-xml \
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
    cron

# Start and enable MariaDB
systemctl start mariadb
systemctl enable mariadb

# Generate random credentials
MYSQL_USER="user_$(openssl rand -hex 3)"
MYSQL_PASSWORD="$(openssl rand -base64 12)"
MYSQL_DATABASE="radius"
DB_CREDENTIALS_FILE="/home/sisp/db.txt"

# Secure MariaDB installation
mysql -e "UPDATE mysql.user SET Password=PASSWORD('$MYSQL_PASSWORD') WHERE User='root';"
mysql -e "DELETE FROM mysql.user WHERE User='';"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -e "DROP DATABASE IF EXISTS test;"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -e "FLUSH PRIVILEGES;"

# Create database and user
mysql -e "CREATE DATABASE $MYSQL_DATABASE;"
mysql -e "CREATE USER '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';"
mysql -e "GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Install Composer
if ! command -v composer &> /dev/null; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --quiet
    rm composer-setup.php
    mv composer.phar /usr/local/bin/composer
    chmod +x /usr/local/bin/composer
fi

# Setup Laravel application
LOCAL_PATH="/var/www/html"
REPO_URL="https://github.com/simpleisp/radius.git"

# Backup existing web root if it exists
if [ -d "$LOCAL_PATH" ]; then
    mv "$LOCAL_PATH" "${LOCAL_PATH}_backup_$(date +%Y%m%d_%H%M%S)"
fi

# Clone the repository
git clone "$REPO_URL" "$LOCAL_PATH"
cd "$LOCAL_PATH"

# Install Laravel dependencies
composer install --no-interaction

# Create and configure .env file
cp .env.example .env
php artisan key:generate --force

# Update .env with database credentials
sed -i "s|DB_HOST=.*|DB_HOST=localhost|" .env
sed -i "s|DB_PORT=.*|DB_PORT=3306|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=$MYSQL_DATABASE|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=$MYSQL_USER|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$MYSQL_PASSWORD|" .env
sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" .env

# Configure FreeRADIUS
SQL_FILE="/etc/freeradius/3.0/mods-available/sql"
if [ -f "$SQL_FILE" ]; then
    sed -i "s|server = .*|server = \"localhost\"|" "$SQL_FILE"
    sed -i "s|port = .*|port = 3306|" "$SQL_FILE"
    sed -i "s|login = .*|login = \"$MYSQL_USER\"|" "$SQL_FILE"
    sed -i "s|password = .*|password = \"$MYSQL_PASSWORD\"|" "$SQL_FILE"
    sed -i "s|radius_db = .*|radius_db = \"$MYSQL_DATABASE\"|" "$SQL_FILE"

    # Comment out TLS configuration
    sed -i '/mysql {/,/^[[:space:]]*}$/c\mysql {\n\t# TLS configuration commented out\n}' "$SQL_FILE"
    
    # Uncomment client_table
    sed -i 's|#[[:space:]]*client_table = "nas"|        client_table = "nas"|' "$SQL_FILE"

    # Enable SQL module in FreeRADIUS
    ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/
fi

# Configure FreeRADIUS default site
DEFAULT_SITE="/etc/freeradius/3.0/sites-available/default"
if [ -f "$DEFAULT_SITE" ]; then
    # Change -sql to sql
    sed -i 's/-sql/sql/g' "$DEFAULT_SITE"
    
    # Comment out detail line
    sed -i 's/^[[:space:]]*detail/#       detail/' "$DEFAULT_SITE"
fi

# Run Laravel migrations and seed the database
php artisan migrate --force
php artisan db:seed --force

# Configure Supervisor for queue worker
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

# Install OpenVPN
export AUTO_INSTALL=y
curl -O https://raw.githubusercontent.com/simpleisp/bash/main/openvpn.sh
chmod +x openvpn.sh
./openvpn.sh

# Configure Nginx
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
        fastcgi_pass unix:/var/run/php/php7.4-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

# Test the Nginx configuration
nginx -t

# If the configuration is OK, reload and restart Nginx
systemctl reload nginx
systemctl restart nginx

# Set correct permissions
chown -R www-data:www-data /var/www/html
chmod -R 775 /var/www/html/storage
chmod -R 775 /var/www/html/bootstrap/cache

# Configure cron job for Laravel scheduler
echo "* * * * * cd /var/www/html && php artisan schedule:run >> /dev/null 2>&1" | crontab -u www-data -

# Update sudoers for www-data user
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

# Save database credentials
echo "MySQL Credentials:" > "$DB_CREDENTIALS_FILE"
echo "DB_HOST=localhost" >> "$DB_CREDENTIALS_FILE"
echo "DB_PORT=3306" >> "$DB_CREDENTIALS_FILE"
echo "DB_DATABASE=$MYSQL_DATABASE" >> "$DB_CREDENTIALS_FILE"
echo "DB_USERNAME=$MYSQL_USER" >> "$DB_CREDENTIALS_FILE"
echo "DB_PASSWORD=$MYSQL_PASSWORD" >> "$DB_CREDENTIALS_FILE"

# Start and enable all services
systemctl start nginx
systemctl enable nginx
systemctl start php7.4-fpm
systemctl enable php7.4-fpm
systemctl start supervisor
systemctl enable supervisor
systemctl start freeradius
systemctl enable freeradius
systemctl start openvpn
systemctl enable openvpn

# Restart all services to ensure proper configuration
systemctl restart nginx
systemctl restart php7.4-fpm
systemctl restart supervisor
systemctl restart freeradius
systemctl restart openvpn

# Configure SSL with Certbot
echo "Configuring SSL certificate for $DOMAIN"
certbot --nginx -d "$DOMAIN" --agree-tos --email "$EMAIL_ADDRESS" --no-eff-email --non-interactive

echo "Installation completed successfully!"
echo "You can find your database credentials in $DB_CREDENTIALS_FILE"
echo "Your SimpleISP installation is available at: https://$DOMAIN"
echo "Installation logs are available at: $INSTALL_LOG"
