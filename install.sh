#!/bin/bash

# Install MariaDB without a password
export DEBIAN_FRONTEND=noninteractive
sudo debconf-set-selections <<< "mariadb-server-10.3 mysql-server/root_password password ''"
sudo debconf-set-selections <<< "mariadb-server-10.3 mysql-server/root_password_again password ''"
sudo apt-get install -y mariadb-server

# Change the root user's authentication plugin to unix_socket
sudo mysql -e "USE mysql; UPDATE user SET plugin='unix_socket' WHERE User='root'; FLUSH PRIVILEGES;"

# Generate random MySQL username and password
MYSQL_USER="user_$(openssl rand -hex 3)"
MYSQL_PASSWORD="$(openssl rand -base64 12)"

# Login to MariaDB and setup
sudo mysql -e "
CREATE DATABASE radius;
CREATE USER '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON radius.* TO '${MYSQL_USER}'@'localhost';
GRANT CREATE ROUTINE, ALTER ROUTINE ON radius.* TO '${MYSQL_USER}'@'localhost';
FLUSH PRIVILEGES;
"

# Set the MySQL timezone for the 'radius' database
# sudo mysql -e "USE radius; SET GLOBAL time_zone = '+03:00'; SET time_zone = '+03:00';"
sudo mysql -e "SET GLOBAL time_zone = '+03:00'; SET time_zone = '+03:00';"

# Nginx Installation

# Step 1: Update the system
sudo apt update

# Step 2: Install Nginx
sudo apt install -y nginx

# Adjusting the firewall
sudo ufw allow http
sudo ufw allow https

# Step 3: Prompt user for domain name
read -p "Enter your domain name (e.g., example.com): " domain_name

# Step 4: Configure Nginx for Laravel
sudo bash -c 'cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    listen [::]:80;

    root /var/www/html/public;
    index index.php index.html index.htm index.nginx-debian.html;

    server_name '"$domain_name"';

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
EOF'

# Test the configuration
sudo nginx -t

# If the configuration is OK, reload Nginx
sudo systemctl reload nginx

# Finally, if you want to restart Nginx
sudo systemctl restart nginx

sudo apt-get install -y php-common php-gd php-curl php-mysql php-fpm php-zip php-mbstring php-xml


# Git clone laravel app

# Set the remote repository URL
REPO_URL="https://github.com/simpleisp/radius.git"

# Set the path to the local Laravel application directory
LOCAL_PATH="/var/www/html"

# Set the branch or tag to checkout
BRANCH="main"

# Check if Composer is installed, and if not, install it
if ! command -v composer &> /dev/null; then
    echo "Composer not found. Installing Composer..."
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --quiet
    rm composer-setup.php
    mv composer.phar /usr/local/bin/composer
    chmod +x /usr/local/bin/composer
fi

# Proceed with the clone only if the /var/www/html/public directory doesn't exist or the index.php file is not present inside it
if [ ! -d "$LOCAL_PATH/public" ] || [ ! -f "$LOCAL_PATH/public/index.php" ]; then
    # Move the existing /var/www/html to a temporary location
    TEMP_PATH="/tmp/var_www_html_backup"
    if [ -d "$LOCAL_PATH" ]; then
        mv "$LOCAL_PATH" "$TEMP_PATH"
    fi

    # Clone the repository into the local Laravel application directory
    git clone "$REPO_URL" "$LOCAL_PATH" || { echo "Cloning failed. Restoring original /var/www/html and exiting."; mv "$TEMP_PATH" "$LOCAL_PATH"; exit 1; }

    # Remove the temporary backup directory if it exists
    if [ -d "$TEMP_PATH" ]; then
        rm -rf "$TEMP_PATH"
    fi

    # Generate a new application key
    php "$LOCAL_PATH"/artisan key:generate --force

    # Clear application cache
    php "$LOCAL_PATH"/artisan cache:clear

    # Clear route cache
    php "$LOCAL_PATH"/artisan route:clear

    # Clear config cache
    php "$LOCAL_PATH"/artisan config:clear

    # Clear compiled views cache
    php "$LOCAL_PATH"/artisan view:clear

    # # Optimize the application
    # php "$LOCAL_PATH"/artisan optimize

else
    echo "The /var/www/html/public directory exists and contains index.php. Skipping clone and setup."
fi

# Install FreeRADIUS and FreeRADIUS-MySQL
sudo apt-get install -y freeradius freeradius-mysql freeradius-utils

# # Specify the path to the FreeRADIUS SQL file
sql_file="/etc/freeradius/3.0/mods-available/sql"


# Replace files
sed -i "s/login = .*/login = \"$MYSQL_USER\"/" "$sql_file"
sed -i "s/password = .*/password = \"$MYSQL_PASSWORD\"/" "$sql_file"
# sed -i "s/read_clients = .*/read_clients = yes/" "$sql_file"

# # Enable SQL module and configure FreeRADIUS to use it
sudo ln -s /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/

# # Enable & Restart FreeRADIUS service
systemctl enable freeradius.service
sudo systemctl restart freeradius.service

# Install OpenVPN
sudo apt-get update

# Set the environment variable
export AUTO_INSTALL=y

# Download the openvpn.sh script
curl -O https://raw.githubusercontent.com/simpleisp/bash/main/openvpn.sh

# Make the openvpn.sh script executable
chmod +x openvpn.sh

# Run the openvpn.sh script
./openvpn.sh

# Add an OpenVPN configuration file if needed, e.g.:
# sudo cp /path/to/your/openvpn/config.ovpn /etc/openvpn/

# Enable and start OpenVPN service
sudo systemctl enable openvpn
sudo systemctl start openvpn
sudo apt install -y easy-rsa

# Set permissions for /etc/openvpn
sudo chmod -R 777 /etc/openvpn
sudo chmod -R 777 /etc/openvpn/easy-rsa
sudo ufw allow 1194/tcp

# Install Php imap
apt install -y php-imap

# Supervisor Installation

# Step 1: Install Supervisor
sudo apt-get install -y supervisor

# Step 2: Configure Supervisor
sudo bash -c "cat > /etc/supervisor/conf.d/queue-worker.conf << EOL
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
stdout_logfile=/var/www/html/storage/logs/queue.log
stopwaitsecs=3600
EOL"

# Step 3: Start Supervisor
sudo systemctl start supervisor
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start queue-worker:*

# Update sudoers file to allow www-data user to restart and check the status of OpenVPN without a password
sudo bash -c "cat >> /etc/sudoers << EOL
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
EOL"

# Set permissions 
sudo chown -R www-data:www-data /var/www
sudo chown -R www-data:www-data /var/www/html
sudo chmod -R 777 /var/www/html/storage 
sudo chmod -R 777 /var/www/html/bootstrap/cache 
sudo chown -R www-data:www-data /var/www/html/bootstrap/cache
sudo timedatectl set-timezone Africa/Nairobi
sudo ufw allow 1812:1813/udp

# Make script executable
chmod +x /var/www/html/sh/set_permissions.sh
chmod +x /var/www/html/sh/restart-services.sh

# Install cron
# Write cron job entry to a temporary file
echo "* * * * * php /var/www/html/artisan schedule:run >> /dev/null 2>&1" > cronjob

# Install the cron job from the temporary file
crontab cronjob

# Clean up the temporary file
rm cronjob

# Step 5: Prompt user for email address and install Certbot
read -p "Enter your email address for certificate management: " email_address

# Install Certbot 
sudo apt install python3-certbot-nginx -y


# Run Certbot for the given domain
sudo certbot --nginx -d $domain_name --agree-tos --email $email_address --no-eff-email --non-interactive

# Install Composer dependencies (initial setup) without human interaction
cd "$LOCAL_PATH"
composer install --no-interaction



echo "MariaDB setup completed"
echo "ssl certificate issued"
echo "FreeRADIUS setup completed"
# Display the message to copy the details
echo ""
echo "**********************************************************"
echo "IMPORTANT: Please copy these details. You will need them to continue to the next step."
echo "**********************************************************"
echo ""
echo "Database name: radius"
echo "Generated MySQL username: ${MYSQL_USER}"
echo "Generated MySQL password: ${MYSQL_PASSWORD}"
echo ""
echo "**********************************************************"
echo "Installation completed."
echo "Please access the following link to finalize the setup:"
echo "https://$domain_name/install"
echo "**********************************************************"
echo ""
