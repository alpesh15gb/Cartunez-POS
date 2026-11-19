#!/usr/bin/env bash
# Stage 3: one new host Nginx site for shop.cartunez.in, a Let's Encrypt
# certificate for that name only, and a staging password. Every change is
# checked with "nginx -t" before a graceful reload; on failure the new file is
# removed and Nginx is left exactly as it was. No other site is edited.
set -euo pipefail
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
DOMAIN=shop.cartunez.in
SITE=/etc/nginx/sites-available/cartunez-shop.conf
LINK=/etc/nginx/sites-enabled/cartunez-shop.conf
ACME=/var/www/cartunez-shop-acme
CONF=/etc/cartunez-shop
# Nginx workers (www-data) cannot open /etc/cartunez-shop (root only), so the
# staging password file lives next to the Nginx configuration instead.
HTPASSWD=/etc/nginx/cartunez-shop.htpasswd
UPSTREAM=127.0.0.1:18600

nginx -t >/dev/null 2>&1 || die 'Nginx configuration already has errors; fix them before adding a site.'
others=$(grep -rlE "server_name[^;]*[[:space:]]$DOMAIN([[:space:];]|$)" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | grep -v 'cartunez-shop.conf' || true)
[[ -z "$others" ]] || die "Another Nginx site already uses $DOMAIN: $others"
curl -s -o /dev/null -m 5 "http://$UPSTREAM/" || die "Magento is not answering on $UPSTREAM. Run 2-install.sh first."

apply() {   # $1 = new site content
  local backup=""
  [[ -e "$SITE" ]] && backup="$(mktemp)" && cp "$SITE" "$backup"
  printf '%s\n' "$1" > "$SITE"
  ln -sfn "$SITE" "$LINK"
  if nginx -t; then
    systemctl reload nginx
  else
    if [[ -n "$backup" ]]; then cp "$backup" "$SITE"; else rm -f "$SITE" "$LINK"; fi
    die 'nginx -t failed; the change was undone and Nginx was not reloaded.'
  fi
}

echo '== Step A: HTTP site for the certificate challenge'
install -d -m 755 "$ACME"
if [[ ! -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
  apply "server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root $ACME; default_type text/plain; try_files \$uri =404; }
    location / { return 503; }
}"
  read -r -p "Email for Let's Encrypt expiry notices: " email
  certbot certonly --webroot -w "$ACME" -d "$DOMAIN" --email "$email" --agree-tos --non-interactive
fi

echo '== Staging password (keeps the shop private until launch)'
if [[ ! -s "$CONF/htpasswd" ]]; then
  pass="$(openssl rand -base64 12 | tr -d '/+=')"
  printf 'preview:%s\n' "$(openssl passwd -apr1 "$pass")" > "$CONF/htpasswd"
  chmod 640 "$CONF/htpasswd"; chgrp www-data "$CONF/htpasswd"
  umask 077; printf 'Staging login for https://%s\nUser: preview\nPassword: %s\n' "$DOMAIN" "$pass" > "$CONF/staging-login.txt"
  unset pass
  echo "Saved $CONF/staging-login.txt (root only)."
fi
install -m 640 -o root -g www-data "$CONF/htpasswd" "$HTPASSWD"

echo '== Step B: HTTPS site'
proxy="proxy_pass http://$UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;"
apply "server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root $ACME; default_type text/plain; try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    client_max_body_size 32m;

    # Staging: private and hidden from search engines. Remove these three lines at launch.
    add_header X-Robots-Tag \"noindex, nofollow\" always;
    auth_basic \"Cartunez shop (staging)\";
    auth_basic_user_file $HTPASSWD;

    # The POS talks to Magento's REST API with its own token, so no staging password here.
    location /rest/ {
        auth_basic off;
        $proxy
    }
    location / {
        $proxy
    }
}"

echo '== Checks'
# Checks report problems instead of stopping the script.
check() { curl -sS -o /dev/null -w '%{http_code}' -m 15 "$@" 2>&1 || true; }
echo "https://$DOMAIN/ without password: $(check "https://$DOMAIN/") (401 expected while in staging)"
echo "REST API without token: $(check "https://$DOMAIN/rest/V1/store/storeConfigs") (401 expected: Magento asks for a token)"
echo "Same checks through this server's own Nginx: $(check --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/") / $(check --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/rest/V1/store/storeConfigs")"
echo
echo "Done. Staging login: cat $CONF/staging-login.txt   Admin login: cat $CONF/admin-login.txt"
