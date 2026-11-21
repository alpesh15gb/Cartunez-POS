#!/usr/bin/env bash
# Stage 4: the Cartunez theme (logo, colours, prices, footer) and the home page.
# Copies deploy/magento/storefront into the shop, checks the PHP files, enables
# the module, selects the theme and rebuilds. The shop shows Magento's
# maintenance page for a few minutes. Only the cartunezshop project is touched.
# Can be run again after changing the theme.
set -Eeuo pipefail   # -E: the error trap also fires inside the helper functions
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
SRC="$(cd "$(dirname "$0")" && pwd)/storefront"
ROOT=/opt/cartunez-shop
cd "$ROOT"
dc() { docker compose -p cartunezshop "$@"; }
inphp() { dc exec -T php "$@"; }
mage() { inphp php -d memory_limit=4G bin/magento "$@"; }

[[ -d "$SRC/app" ]] || die "Theme files not found in $SRC."
inphp test -f app/etc/env.php || die 'Install Magento first (2-install.sh).'

echo '== Copying the theme and storefront module'
# Old copies kept the theme styles as LESS for Magento to compile; that file is gone now.
inphp rm -f app/design/frontend/Cartunez/default/web/css/source/_extend.less
dc cp "$SRC/app/." php:/var/www/magento/app/
dc exec -T -u root php chown -R www-data:www-data app/code/Cartunez app/design/frontend/Cartunez

echo '== Checking PHP files'
inphp sh -c 'for f in $(find app/code/Cartunez app/design/frontend/Cartunez -name "*.php"); do php -l "$f" >/dev/null || { echo "Error in $f"; exit 1; }; done' \
  || die 'A PHP file has an error; nothing was enabled and the shop was not changed.'

echo '== Enabling (maintenance page for a few minutes)'
mage maintenance:enable >/dev/null
trap 'echo; echo "Stopped with an error. The shop is still in maintenance. After fixing, run this script again, or turn maintenance off with:"; echo "  docker compose -p cartunezshop exec -T php php bin/magento maintenance:disable"; docker compose -p cartunezshop start cron >/dev/null 2>&1 || true' ERR
mage module:enable Cartunez_Storefront >/dev/null || true
mage setup:upgrade --keep-generated

theme_id=$(dc exec -T db sh -c 'mariadb -umagento -p"$(cat /run/secrets/db_password)" magento -N -e "SELECT theme_id FROM theme WHERE area=\"frontend\" AND theme_path=\"Cartunez/default\""' | tr -d '[:space:]')
[[ -n "$theme_id" ]] || die 'The Cartunez theme was not registered by Magento.'
echo "Cartunez theme id: $theme_id"
mage config:set design/theme/theme_id "$theme_id" >/dev/null
mage config:set --scope=websites --scope-code=base design/theme/theme_id "$theme_id" >/dev/null
mage config:set --scope=stores --scope-code=default design/theme/theme_id "$theme_id" >/dev/null
mage config:set design/header/welcome 'Get your car rolling in style' >/dev/null
mage config:set design/head/default_title 'Car Tunez' >/dev/null
mage config:set design/head/title_suffix ' | Car Tunez' >/dev/null
si() { mage config:set "general/store_information/$1" "$2" >/dev/null; }
si name 'Car Tunez'
si phone '+91 99496 95030'
si hours 'Mon-Sat 11 am - 10 pm, Sun 11:30 am - 6 pm'
si country_id IN
si city 'Hyderabad'
si postcode 500003
si street_line1 'Shop No. 12 & 13, Veer Hanuman Temple'
si street_line2 'S.P. Road, Secunderabad'
mage config:set design/footer/copyright '© Car Tunez.' >/dev/null
# No wish list on a parts shop (compare links are removed in the theme layout).
mage config:set wishlist/general/active 0 >/dev/null

echo '== Rebuilding code and theme files (5-10 minutes)'
# Magento's cron container writes generated code too; it is paused so the
# rebuild can clear that folder ("Directory not empty" otherwise).
dc stop cron >/dev/null
dc exec -T -u root php sh -c 'rm -rf generated/code/* generated/metadata/*'
mage setup:di:compile
inphp rm -rf pub/static/frontend/Cartunez var/view_preprocessed/pub/static/frontend/Cartunez
mage setup:static-content:deploy -f en_US --jobs 1 --theme Cartunez/default --theme Magento/backend
mage indexer:reindex design_config_grid >/dev/null || true
# PHP keeps compiled code in memory and never re-reads changed files
# (opcache.validate_timestamps=0 in php.ini), so restart it to load the new
# templates, blocks and generated code. Without this, changes did not appear.
echo '== Restarting PHP to load the new code'
dc restart php >/dev/null
for _ in $(seq 1 30); do inphp php -r 'exit(0);' >/dev/null 2>&1 && break; sleep 1; done
mage maintenance:disable >/dev/null
mage cache:flush >/dev/null
dc start cron >/dev/null
trap - ERR

code=$(curl -sS -o /dev/null -w '%{http_code}' -m 20 -H 'Host: shop.cartunez.in' -H 'X-Forwarded-Proto: https' http://127.0.0.1:18600/ 2>&1 || true)
echo "Local check: HTTP $code (200 expected)"
n=$(inphp sh -c 'grep -c cz-slider pub/static/frontend/Cartunez/default/en_US/css/cartunez.css 2>/dev/null' || true)
echo "Theme stylesheet: ${n:-0} slider rules (more than 0 expected)"
echo 'Stage 4 done. Open https://shop.cartunez.in (staging login) and reload with Ctrl+F5.'
