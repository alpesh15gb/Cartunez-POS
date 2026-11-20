#!/usr/bin/env bash
# Stage 5: launch settings for shop.cartunez.in.
#   Payments : Cash on delivery / pay at pickup, and UPI or bank transfer (no gateway).
#   Delivery : free pickup at the shop; home delivery Rs 99, free from Rs 1,999 (all India).
#   Email    : order emails and the contact form through Gmail (app password).
#   Launch   : search engines allowed, nightly shop backups, and (last, after
#              you type LIVE) the staging password removed.
# Safe to run again: it asks before changing what you set last time.
# Only the cartunezshop project and its own Nginx site are touched.
set -Eeuo pipefail
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT=/opt/cartunez-shop
CONF=/etc/cartunez-shop
SITE=/etc/nginx/sites-available/cartunez-shop.conf
DELIVERY_FEE="${DELIVERY_FEE:-99}"
FREE_ABOVE="${FREE_ABOVE:-1999}"
cd "$ROOT"
dc() { docker compose -p cartunezshop "$@"; }
inphp() { dc exec -T php "$@"; }
mage() { inphp php -d memory_limit=4G bin/magento "$@"; }
FAILED=()
# A setting this Magento does not know is reported at the end instead of stopping halfway.
set_() { mage config:set "$1" "$2" >/dev/null 2>&1 || { echo "   could not set $1"; FAILED+=("$1"); }; }
sql() { dc exec -T db sh -c 'mariadb -umagento -p"$(cat /run/secrets/db_password)" magento -N -e "$0"' "$1"; }

inphp test -f app/etc/env.php || die 'Install Magento first (2-install.sh).'
touch "$CONF/launch.env"; chmod 600 "$CONF/launch.env"
# shellcheck disable=SC1091
source "$CONF/launch.env"
ask() {   # $1 variable, $2 question; keeps the saved answer when Enter is pressed
  local current="${!1:-}" answer
  read -r -p "$2${current:+ [$current]}: " answer
  answer="${answer:-$current}"
  [[ -n "$answer" ]] || die "$2 is needed."
  printf -v "$1" '%s' "$answer"
}

echo '== Your details (Enter keeps the value in brackets)'
ask UPI_ID 'UPI ID customers pay to (for example cartunez@okhdfcbank)'
ask SHOP_PHONE 'Shop phone / WhatsApp for payment screenshots'
ask MAIL_FROM 'Gmail address that sends order emails'
read -r -s -p 'Gmail app password (16 letters; Enter keeps the saved one): ' MAIL_PASS; echo
MAIL_PASS="${MAIL_PASS// /}"
{ printf 'UPI_ID=%q\nSHOP_PHONE=%q\nMAIL_FROM=%q\n' "$UPI_ID" "$SHOP_PHONE" "$MAIL_FROM"; } > "$CONF/launch.env"

echo '== Payments: cash on delivery / at pickup, and UPI or bank transfer'
set_ payment/checkmo/active 0
set_ payment/cashondelivery/active 1
set_ payment/cashondelivery/title 'Cash on delivery / pay at pickup'
set_ payment/cashondelivery/instructions 'Pay in cash or UPI when the parts reach you or when you collect them at our shop.'
set_ payment/cashondelivery/allowspecific 0
set_ payment/cashondelivery/sort_order 1
set_ payment/banktransfer/active 1
set_ payment/banktransfer/title 'Pay now by UPI'
set_ payment/banktransfer/instructions "Pay the order total by UPI to ${UPI_ID} (Car Tunez) and send the payment screenshot with your order number on WhatsApp to ${SHOP_PHONE}. We dispatch after the payment is confirmed."
set_ payment/banktransfer/allowspecific 0
set_ payment/banktransfer/sort_order 2

echo "== Delivery: free pickup; home delivery Rs ${DELIVERY_FEE}, free from Rs ${FREE_ABOVE}; India only"
set_ general/country/allow IN
set_ general/country/default IN
set_ shipping/origin/country_id IN
set_ shipping/origin/city Hyderabad
set_ shipping/origin/postcode 500003
set_ shipping/origin/street_line1 'Shop No. 12 & 13, Veer Hanuman Temple'
set_ shipping/origin/street_line2 'S.P. Road, Secunderabad'
set_ carriers/flatrate/active 0
set_ carriers/freeshipping/active 1
set_ carriers/freeshipping/title 'Store pickup'
set_ carriers/freeshipping/name 'Collect from our Secunderabad shop (free)'
set_ carriers/freeshipping/free_shipping_subtotal 0
set_ carriers/freeshipping/showmethod 0
set_ carriers/freeshipping/sort_order 2
set_ carriers/tablerate/active 1
set_ carriers/tablerate/title 'Home delivery'
set_ carriers/tablerate/name "Courier (free from Rs ${FREE_ABOVE})"
set_ carriers/tablerate/condition_name package_value_with_discount
set_ carriers/tablerate/include_virtual_price 1
set_ carriers/tablerate/sallowspecific 0
set_ carriers/tablerate/sort_order 1
website=$(sql "SELECT website_id FROM store_website WHERE code='base'" | tr -d '[:space:]')
[[ -n "$website" ]] || die 'The main website was not found.'
sql "START TRANSACTION;
DELETE FROM shipping_tablerate WHERE website_id=${website};
INSERT INTO shipping_tablerate (website_id,dest_country_id,dest_region_id,dest_zip,condition_name,condition_value,price,cost) VALUES
 (${website},'IN',0,'*','package_value_with_discount',0,${DELIVERY_FEE},0),
 (${website},'IN',0,'*','package_value_with_discount',${FREE_ABOVE},0,0);
COMMIT;"

echo "== Email through Gmail as ${MAIL_FROM}"
set_ system/smtp/disable 0
set_ system/smtp/transport smtp
set_ system/smtp/host smtp.gmail.com
# Magento's "ssl tls" is implicit TLS (SMTPS), which Gmail serves on port 465.
set_ system/smtp/port 465
set_ system/smtp/auth login
set_ system/smtp/ssl tls
set_ system/smtp/username "$MAIL_FROM"
if [[ -n "$MAIL_PASS" ]]; then
  # config:set runs Magento's encrypted-field handling, so the password is stored encrypted.
  set_ system/smtp/password "$MAIL_PASS"
fi
unset MAIL_PASS
for ident in general sales support custom1 custom2; do
  set_ "trans_email/ident_${ident}/email" "$MAIL_FROM"
  set_ "trans_email/ident_${ident}/name" 'Car Tunez'
done
set_ contact/email/recipient_email "$MAIL_FROM"
# The shop gets a copy of every order and invoice email.
set_ sales_email/order/copy_to "$MAIL_FROM"
set_ sales_email/order/copy_method bcc
set_ sales_email/invoice/copy_to "$MAIL_FROM"
set_ sales_email/invoice/copy_method bcc

echo '== Store details and search engines'
set_ general/store_information/name 'Car Tunez'
set_ general/store_information/phone "$SHOP_PHONE"
set_ design/search_engine_robots/default_robots 'INDEX,FOLLOW'
set_ checkout/options/guest_checkout 1
mage cache:flush >/dev/null

echo '== Nightly shop backup (database, photos, settings) at 02:30'
install -m 755 "$HERE/backup.sh" /usr/local/sbin/cartunez-shop-backup
printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin\n30 2 * * * root /usr/local/sbin/cartunez-shop-backup >>/var/log/cartunez-shop-backup.log 2>&1\n' > /etc/cron.d/cartunez-shop-backup
chmod 644 /etc/cron.d/cartunez-shop-backup
/usr/local/sbin/cartunez-shop-backup || die 'The first backup failed; see the message above.'

echo
if grep -q 'auth_basic_user_file' "$SITE"; then
  echo 'Last step: open the shop to everyone (removes the staging password and the noindex header).'
  read -r -p 'Type LIVE to open the shop now, or press Enter to stay private: ' go
  if [[ "$go" == LIVE ]]; then
    cp "$SITE" "$CONF/nginx-staging.conf.bak"
    sed -i -e '/X-Robots-Tag "noindex, nofollow"/d' -e '/auth_basic "Cartunez shop (staging)"/d' \
      -e '/auth_basic_user_file /d' -e '/# Staging: private/d' "$SITE"
    if nginx -t; then
      systemctl reload nginx
      # Remembered so 3-nginx.sh never puts the staging password back.
      touch "$CONF/live"
      echo 'The shop is open to everyone: https://shop.cartunez.in'
    else
      cp "$CONF/nginx-staging.conf.bak" "$SITE"
      die 'nginx -t failed; the staging site was put back and Nginx was not reloaded.'
    fi
  else
    echo 'Still private. Run this script again and type LIVE when ready.'
  fi
else
  echo 'The shop is already open to everyone.'
fi
code=$(curl -sS -o /dev/null -w '%{http_code}' -m 20 https://shop.cartunez.in/ 2>&1 || true)
echo "https://shop.cartunez.in/ : HTTP $code (200 = open, 401 = still private)"
if (( ${#FAILED[@]} )); then echo "Settings that need a look in the admin: ${FAILED[*]}"; fi
echo 'Stage 5 done. Place a test order (store pickup + cash on delivery) and check that the email arrives.'
