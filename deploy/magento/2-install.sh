#!/usr/bin/env bash
# Stage 2: download and install Magento into the "code" volume, set it up for India
# (INR, IST, prices including GST), production mode, then start cron and the web
# container on 127.0.0.1:18600. Does not touch Nginx (that is stage 3).
set -euo pipefail
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
ROOT=/opt/cartunez-shop
CONF=/etc/cartunez-shop
VERSION="${MAGENTO_VERSION:-2.4.8}"
cd "$ROOT"
dc() { docker compose -p cartunezshop "$@"; }
inphp() { dc exec -T php "$@"; }
# Magento commands get a generous memory limit whatever the PHP defaults are.
mage() { inphp php -d memory_limit=4G bin/magento "$@"; }

[[ -s "$CONF/composer-auth.json" ]] || die 'Run 1-prepare.sh first.'

if ! inphp test -f bin/magento; then
  echo "== Downloading Magento $VERSION (several minutes)"
  inphp sh -c 'test -z "$(ls -A /var/www/magento)"' || die 'The code volume is not empty but has no Magento. Inspect it before continuing.'
  dc exec -T -e COMPOSER_AUTH="$(cat "$CONF/composer-auth.json")" php \
    composer create-project --no-interaction --no-progress \
      --repository-url=https://repo.magento.com/ "magento/project-community-edition=$VERSION" /var/www/magento
fi

echo "== PHP settings: memory_limit $(inphp php -r 'echo ini_get("memory_limit");') (Magento commands run with 4G)"
inphp php --ini | sed 's/^/   /'

# Installed = settings file present and the database complete. A half-finished
# install (for example one that ran out of memory) is redone from a clean database.
installed=0
if inphp test -f app/etc/env.php && mage setup:db:status >/dev/null 2>&1; then installed=1; fi
if [[ $installed -eq 0 ]]; then
  echo '== Installing Magento'
  if inphp test -f app/etc/env.php; then
    echo 'A previous install did not finish; starting again with a clean database.'
    inphp rm -f app/etc/env.php
  fi
  read -r -p 'Admin email address: ' admin_email
  [[ "$admin_email" == *@*.* ]] || die 'Enter a valid email address.'
  admin_user="cartunez-$(openssl rand -hex 3)"
  admin_pass="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)A1!"
  admin_path="admin_$(openssl rand -hex 4)"
  mage setup:install --cleanup-database \
    --base-url=https://shop.cartunez.in/ --base-url-secure=https://shop.cartunez.in/ \
    --use-secure=1 --use-secure-admin=1 --use-rewrites=1 \
    --db-host=db --db-name=magento --db-user=magento --db-password="$(cat "$CONF/db_password")" \
    --admin-firstname=Cartunez --admin-lastname=Admin --admin-email="$admin_email" \
    --admin-user="$admin_user" --admin-password="$admin_pass" --backend-frontname="$admin_path" \
    --language=en_US --currency=INR --timezone=Asia/Kolkata \
    --search-engine=opensearch --opensearch-host=search --opensearch-port=9200 \
    --session-save=redis --session-save-redis-host=cache --session-save-redis-db=2 \
    --cache-backend=redis --cache-backend-redis-server=cache --cache-backend-redis-db=0 \
    --page-cache=redis --page-cache-redis-server=cache --page-cache-redis-db=1
  umask 077
  printf 'Admin URL: https://shop.cartunez.in/%s\nUser: %s\nPassword: %s\nEmail: %s\n' \
    "$admin_path" "$admin_user" "$admin_pass" "$admin_email" > "$CONF/admin-login.txt"
  unset admin_pass
  echo "Admin login saved in $CONF/admin-login.txt (root only). It is not printed here."
fi

echo '== India settings: INR, prices include GST, default country India'
for setting in \
  'general/country/default IN' \
  'general/locale/timezone Asia/Kolkata' \
  'currency/options/base INR' 'currency/options/default INR' 'currency/options/allow INR' \
  'tax/calculation/price_includes_tax 1' 'tax/calculation/shipping_includes_tax 1' \
  'tax/display/type 2' 'tax/display/shipping 2' \
  'tax/cart_display/price 2' 'tax/cart_display/subtotal 2' 'tax/cart_display/shipping 2' \
  'tax/sales_display/price 2' 'tax/sales_display/subtotal 2' 'tax/sales_display/shipping 2' \
  'web/secure/offloader_header X-Forwarded-Proto' \
  'web/seo/use_rewrites 1' \
  'cataloginventory/options/show_out_of_stock 1' ; do
  # shellcheck disable=SC2086
  mage config:set $setting >/dev/null
done

# Admin two-factor sign-in needs outgoing email, which is not set up on staging.
# Turn it back on (Google Authenticator) before going live.
mage module:disable Magento_AdminAdobeImsTwoFactorAuth Magento_TwoFactorAuth >/dev/null 2>&1 || true

echo '== Production mode (compiles code and static files; 5-15 minutes)'
# Run the steps one by one (each with the memory limit) instead of letting
# deploy:mode:set start its own PHP processes.
mage maintenance:enable >/dev/null
mage setup:upgrade --keep-generated >/dev/null
mage setup:di:compile
mage setup:static-content:deploy -f en_US --jobs 1
mage deploy:mode:set production --skip-compilation --no-interaction
mage maintenance:disable >/dev/null
mage indexer:set-mode schedule >/dev/null
mage cache:flush >/dev/null

echo '== Starting cron and the web container on 127.0.0.1:18600'
dc up -d cron web
sleep 3
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: shop.cartunez.in' -H 'X-Forwarded-Proto: https' http://127.0.0.1:18600/)
echo "Local check: HTTP $code (200 or 302 is good)"
dc ps
echo
echo 'Stage 2 done. Next: bash /opt/cartunez-shop/3-nginx.sh'
