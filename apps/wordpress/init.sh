update_config() {
  wp config set --allow-root --skip-plugins --skip-themes DB_NAME "${WORDPRESS_DB_NAME}"
  wp config set --allow-root --skip-plugins --skip-themes DB_USER "${WORDPRESS_DB_USER}"
  wp config set --allow-root --skip-plugins --skip-themes DB_PASSWORD "${WORDPRESS_DB_PASSWORD}"
  wp config set --allow-root --skip-plugins --skip-themes DB_HOST "${WORDPRESS_DB_HOST}"
}

create_config() {
  if [ ! -f "wp-config.php" ]; then
    wp config create --allow-root --skip-plugins --skip-themes --skip-check --dbhost="${WORDPRESS_DB_HOST}" \
          --dbname="${WORDPRESS_DB_NAME}" --dbuser="${WORDPRESS_DB_USER}" --dbpass="${WORDPRESS_DB_PASSWORD}" \
          --extra-php <<'PHP'
if(isset($_SERVER['HTTP_X_FORWARDED_PROTO'])) {
  if (strpos( $_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false) {
    $_SERVER['HTTPS']='on';
  }
};
PHP
  fi
}


install_wordpress() {
#  wp core install --allow-root --skip-plugins --skip-themes --skip-email --url="{{.Domain}}" --title="{{.Title}}" \
#    --admin_user=admin --admin_password="{{.AdminPassword}}" --admin_email="{{.AdminEmail}}"
  for p in ${WORDPRESS_PLUGINS}; do
    wp plugin install --allow-root "${p}" --activate
  done
  wp theme install --allow-root "${WORDPRESS_THEME}" --activate
}

main() {
 update_config
 create_config

 install_wordpress
}

main
