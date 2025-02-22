#!/usr/bin/env bash

# WordPress Installer and Configuration Script
#
# This script automates the process of installing and configuring WordPress.
# It includes functions for downloading WordPress, setting up the configuration,
# installing necessary plugins, and configuring SSL.

#######################################
# Downloads and sets up WordPress core files
# Globals:
#   APP_DOCROOT
#   WORDPRESS_VERSION
# Arguments:
#   None
#######################################
function wordpress_install() {
  echo "================================================================="
  echo "WordPress Installer"
  echo "================================================================="

  # Ensure that the document root directory exists
  mkdir -p "${APP_DOCROOT}"
  cd "${APP_DOCROOT}" || exit

  # Download wp-cli
  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x wp-cli.phar
  mv wp-cli.phar /usr/bin/wp

  # Download the WordPress core files
  wp --allow-root core download --version="${WORDPRESS_VERSION}" --path="${APP_DOCROOT}"

  # Set the correct permissions on the files
  chown -R www-data:www-data "${APP_DOCROOT}"
}

#######################################
# Configures WordPress and installs necessary plugins
# Globals:
#   APP_DOCROOT
#   WORDPRESS_DB_NAME
#   WORDPRESS_DB_USER
#   WORDPRESS_DB_PASSWORD
#   WORDPRESS_DB_HOST
#   NGINX_SERVER_NAME
#   WORDPRESS_ADMIN
#   WORDPRESS_ADMIN_PASSWORD
#   WORDPRESS_ADMIN_EMAIL
# Arguments:
#   None
#######################################

# Function to generate fallback salts if the API fails

function generate_fallback_salts() {
    local keys=("AUTH" "SECURE_AUTH" "LOGGED_IN" "NONCE")
    local salt=""
    local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-={}[]|:;<>,.?~` '
    
    for key in "${keys[@]}"; do
        # Generate KEY with exact WordPress format
        local random_string=$(for i in {1..64}; do echo -n "${chars:RANDOM%${#chars}:1}"; done)
        salt+="define('${key}_KEY',         '${random_string}');\n"
        
        # Generate SALT with exact WordPress format
        random_string=$(for i in {1..64}; do echo -n "${chars:RANDOM%${#chars}:1}"; done)
        salt+="define('${key}_SALT',        '${random_string}');\n"
    done
    
    echo -e "$salt"
}

function wordpress_config() {
  echo "================================================================="
  echo "WordPress Configuration"
  echo "================================================================="

  MAX_RETRIES=3
  RETRY_DELAY=5
  SALT_URL="https://api.wordpress.org/secret-key/1.1/salt/"

  local retries=0
  local success=false
  local wp_salts=""

  echo "Fetching WordPress salts..."

  while [ $retries -lt $MAX_RETRIES ] && [ "$success" = false ]; do
        # Try to fetch salts using curl if available, otherwise wget
        if command -v curl &>/dev/null; then
            wp_salts=$(curl -s -f "$SALT_URL")
        elif command -v wget &>/dev/null; then
            wp_salts=$(wget -qO - "$SALT_URL")
        fi

        if [ $? -eq 0 ] && [ ! -z "$wp_salts" ]; then
            success=true
            echo "Successfully fetched WordPress salts"
        else
            retries=$((retries + 1))
            if [ $retries -lt $MAX_RETRIES ]; then
                echo "Attempt $retries failed. Retrying in $RETRY_DELAY seconds..."
                sleep $RETRY_DELAY
            else
                echo "Error: Failed to fetch WordPress salts after $MAX_RETRIES attempts"
                wp_salts=$(generate_fallback_salts)
                echo "Generated fallback salts"
                success=true
            fi
        fi
  done

  echo "$wp_salts"

  cd "${APP_DOCROOT}" || exit

  # Create wp-config.php file
  cat <<EOF > ./wp-config.php
<?php

define('DB_NAME', '${WORDPRESS_DB_NAME}');
define('DB_USER', '${WORDPRESS_DB_USER}');
define('DB_PASSWORD', '${WORDPRESS_DB_PASSWORD}');
define('DB_HOST', '${WORDPRESS_DB_HOST}');
define('DB_CHARSET', 'utf8');
define('DB_COLLATE', '');

// Performance
define('WP_CACHE', true); 
define('WP_MEMORY_LIMIT', '3072M'); 
define('WP_MAX_MEMORY_LIMIT', '4096M'); 
define('CONCATENATE_SCRIPTS', true);
define('AUTOSAVE_INTERVAL', 600); 
define('WP_POST_REVISIONS', 10);
define('WP_REDIS_DISABLED', false);

// Insert the salts directly
$wp_salts

\$table_prefix = 'wp_';

define('WP_DEBUG', false);

// Modified HTTPS detection
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
} elseif (isset(\$_SERVER['HTTPS']) && \$_SERVER['HTTPS'] === 'on') {
    // HTTPS is already set correctly
} else {
    // Default to HTTP
    \$_SERVER['HTTPS'] = 'off';
}

define('FORCE_SSL_ADMIN', true);
define('DISALLOW_FILE_EDIT', false);
define('RT_WP_NGINX_HELPER_CACHE_PATH', '/var/cache');
define('WP_REDIS_HOST', '${REDIS_UPSTREAM_HOST:-redis}');           // Specify Redis host
define('WP_REDIS_PORT', ${REDIS_UPSTREAM_PORT:-6379});              // Ensure port is defined
define('WP_REDIS_DATABASE', 1);                                     // Optional: Specify Redis database
define('WP_REDIS_PREFIX', 'wp_cache:');                             // Optional: Define a prefix to prevent key collisions
define('FS_METHOD', 'direct');

if (!defined('ABSPATH')) {
    define('ABSPATH', dirname(__FILE__) . '/');
}

require_once(ABSPATH . 'wp-settings.php');
EOF

  # Configure the site with wp-cli
  echo -e "\n\033[1;34m=================================================================\033[0m"
  echo -e "\033[1;32mInstalling WordPress Core...\033[0m"
  echo -e "\033[1;33minstall.sh - NOT wp-install-script-app.sh\033[0m"
  echo -e "\033[1;34m=================================================================\033[0m\n"

  wp --allow-root --path="${APP_DOCROOT}" core install --url="https://${NGINX_SERVER_NAME}" \
    --title="${NGINX_SERVER_NAME}" --admin_user="${WORDPRESS_ADMIN}" \
    --admin_password="${WORDPRESS_ADMIN_PASSWORD}" \
    --admin_email="${WORDPRESS_ADMIN_EMAIL}"

  echo -e "\n\033[1;34m=================================================================\033[0m"
  echo -e "\033[1;32mSetting WordPress User...\033[0m"
  echo -e "\033[1;34m=================================================================\033[0m\n"

  wp --allow-root --path="${APP_DOCROOT}" user update "${WORDPRESS_ADMIN}" \
    --user_pass="${WORDPRESS_ADMIN_PASSWORD}"

  echo -e "\n\033[1;34m=================================================================\033[0m"
  echo -e "\033[1;32mDeleting WordPress Default Plugins...\033[0m"
  echo -e "\033[1;34m=================================================================\033[0m\n"

  wp --allow-root --path="${APP_DOCROOT}" plugin delete akismet hello
  
  echo -e "\n\033[1;34m=================================================================\033[0m"
  echo -e "\033[1;32mDeleting WordPress Default Themes...\033[0m"
  echo -e "\033[1;34m=================================================================\033[0m\n"
  
  wp --allow-root --path="${APP_DOCROOT}" theme delete twentytwentythree twentytwentyfour

  echo -e "\n\033[1;34m=================================================================\033[0m"
  echo -e "\033[1;32mSetting WordPress Permalink Structure to postname...\033[0m"
  echo -e "\033[1;34m=================================================================\033[0m\n"

  wp --allow-root --path="${APP_DOCROOT}" rewrite structure '/%postname%/' --hard

  echo -e "\n\033[1;34m=================================================================\033[0m"
  echo -e "\033[1;32mSetting WordPress Media Settings...\033[0m"
  echo -e "\033[1;34m=================================================================\033[0m\n"
  
  wp --allow-root --path="${APP_DOCROOT}" option update thumbnail_crop 0
  wp --allow-root --path="${APP_DOCROOT}" option update thumbnail_size_w 640
  wp --allow-root --path="${APP_DOCROOT}" option update thumbnail_size_h 360
  wp --allow-root --path="${APP_DOCROOT}" option update medium_size_w 1280
  wp --allow-root --path="${APP_DOCROOT}" option update medium_size_h 720
  wp --allow-root --path="${APP_DOCROOT}" option update large_size_w 1920
  wp --allow-root --path="${APP_DOCROOT}" option update large_size_h 1080
  wp --allow-root --path="${APP_DOCROOT}" media regenerate --yes

  echo -e "\n\033[1;34m=================================================================\033[0m"
  echo -e "\033[1;32mInstalling and Activating WordPress Plugins:\033[0m"
  echo -e "\033[1;33mamp, antispam-bee, nginx-helper, wp-mail-smtp, redis-cache\033[0m"
  echo -e "\033[1;34m=================================================================\033[0m\n"
  
  wp --allow-root --path="${APP_DOCROOT}" plugin install amp antispam-bee nginx-helper wp-mail-smtp redis-cache --activate

  echo -e "\n\033[1;34m=================================================================\033[0m"
  echo -e "\033[1;32mCopying Object Cache File...\033[0m"
  echo -e "\033[1;33mOnly if the redis-cache plugin is installed and the file object-cache.php exists\033[0m"
  echo -e "\033[1;34m=================================================================\033[0m\n"

  if [[ -f ${APP_DOCROOT}/wp-content/plugins/redis-cache/includes/object-cache.php ]]; then
    echo -e "\n\033[1;32mThe object-cache.php file exists. Copying to wp-content folder...\033[0m\n"

    cp "${APP_DOCROOT}/wp-content/plugins/redis-cache/includes/object-cache.php" \
      "${APP_DOCROOT}/wp-content/"
  else
    echo -e "\n\033[1;31mobject-cache.php not found. Skipping file copy.\033[0m\n"
  fi

  echo -e "\n\033[1;34m=================================================================\033[0m"
  echo -e "\033[1;32mInstallation is complete. Your credentials are listed below.\033[0m"
  echo -e "\033[1;34m=================================================================\033[0m\n"
  
  echo -e "\033[1;33mUsername: ${WORDPRESS_ADMIN}\033[0m"
  echo -e "\033[1;33mPassword: ${WORDPRESS_ADMIN_PASSWORD}\033[0m\n"

  echo -e "\033[1;34m=================================================================\033[0m\n\n\n"

  echo "Username: ${WORDPRESS_ADMIN} | Password: ${WORDPRESS_ADMIN_PASSWORD}" > /home/creds.txt

  echo -e "\033[1;34m=================================================================\033[0m\n\n\n"
}

#######################################
# Configures SSL for WordPress
# Globals:
#   NGINX_SERVER_NAME
#   APP_DOCROOT
# Arguments:
#   None
#######################################
function wordpress_ssl() {
  # We need to invoke the page prior to including the SSL connection information
  curl -v -k --resolve "nginx:443:172.19.0.6" "https://nginx/wp-login.php"

  # Add SSL connection to config
  sed -i "/\/\* That's all, stop editing! Happy publishing. \*\//i \
define('FORCE_SSL_ADMIN', true); \n\
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https') { \n\
    \$_SERVER['HTTPS'] = 'on'; \n\
}" "${APP_DOCROOT}/wp-config.php"
}

#######################################
# Cleans up after installation
# Globals:
#   APP_DOCROOT
# Arguments:
#   None
#######################################
function cleanup() {
  # Correct file and directory permissions
  find "${APP_DOCROOT}" ! -user www-data -exec chown www-data:www-data {} \;
  find "${APP_DOCROOT}" -type d ! -perm 755 -exec chmod 755 {} \;
  find "${APP_DOCROOT}" -type f ! -perm 644 -exec chmod 644 {} \;

  # Clear cache
  rm -rf /var/cache/*
}

#######################################
# Main function to run the WordPress installation
# Globals:
#   APP_DOCROOT
# Arguments:
#   None
#######################################
function run() {
  if [[ ! -f ${APP_DOCROOT}/wp-config.php ]]; then
    wordpress_install
    wordpress_config
    wordpress_ssl
    cleanup
  else
    echo "OK: Wordpress already seems to be installed."
  fi
}

# Execute the main function
run

exit 0