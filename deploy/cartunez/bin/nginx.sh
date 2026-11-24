#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal dollar variables belong to Nginx.
source "$(dirname "$0")/common.sh"
command="${1:-}"; directory="${2:-/etc/nginx/sites-enabled}"
render() {
  local mode="$1"
  local security_headers='add_header X-Content-Type-Options nosniff always;
add_header Referrer-Policy same-origin always;
add_header X-Frame-Options DENY always;'
  local server_headers="    ${security_headers//$'\n'/$'\n    '}"
  local location_headers="        ${security_headers//$'\n'/$'\n        '}"
  cat <<EOF
# Managed exclusively by $CARTUNEZ_PROJECT; other vhosts are not modified.
server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; try_files \$uri =404; }
EOF
  if [[ "$mode" = tls ]]; then
    printf '    location / { return 301 https://%s$request_uri; }\n}\n' "$DOMAIN"
    cat <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $CARTUNEZ_ROOT/current/web;
    index index.html;
    client_max_body_size 10m;
    gzip on;
    gzip_types application/json application/javascript text/css image/svg+xml;
    gzip_comp_level 3;
    gzip_min_length 1024;
    gzip_vary on;
    access_log /var/log/nginx/$CARTUNEZ_PROJECT-access.log;
    error_log /var/log/nginx/$CARTUNEZ_PROJECT-error.log;
$server_headers
    if (-f $CARTUNEZ_ROOT/maintenance) { return 503; }
    location /api/ {
        proxy_pass http://127.0.0.1:$API_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
    # A location that sets Cache-Control needs its own security headers on older Nginx versions.
    location = /sw.js {
$location_headers
        add_header Cache-Control "no-store";
    }
    location = /installation.json {
$location_headers
        add_header Cache-Control "no-store";
    }
    location /_next/static/ {
$location_headers
        add_header Cache-Control "public, max-age=31536000, immutable";
    }
    location / {
        try_files \$uri \$uri.html \$uri/ /index.html;
$location_headers
        add_header Cache-Control "no-cache";
    }
    location ~ /\. { deny all; }
}
EOF
  else
    printf '    location / { default_type text/plain; return 503 "POS setup in progress.\\n"; }\n}\n'
  fi
}
case "$command" in
  render-http) render http; exit ;;
  render-tls) render tls; exit ;;
  issue-certificate)
    email="${2:-}"
    [[ "$email" = *@*.* ]] || die 'Usage: nginx.sh issue-certificate administrator@email'
    command -v certbot >/dev/null || die 'Install the Ubuntu certbot package first.'
    certbot certonly --webroot --webroot-path "$ACME_ROOT" --cert-name "$DOMAIN" -d "$DOMAIN" --email "$email" --agree-tos --non-interactive
    exit ;;
  install-http) mode=http ;;
  install-tls)
    mode=tls
    openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -checkhost "$DOMAIN" >/dev/null || die 'A valid matching domain certificate must exist first.'
    openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -checkend 86400 >/dev/null || die 'Certificate expires within 24 hours.'
    ;;
  *) die 'Usage: nginx.sh render-http|render-tls|install-http|install-tls [included-vhost-directory] OR issue-certificate email' ;;
esac
lock
[[ "$directory" = /etc/nginx/sites-enabled || "$directory" = /etc/nginx/conf.d ]] || die 'Choose an existing standard host vhost include directory.'
[[ -d "$directory" ]] || die 'The selected vhost directory does not exist.'
nginx -t
nginx -T 2>/dev/null | grep -F "include $directory/" >/dev/null || die 'Selected directory is not directly included by Nginx; review host configuration manually.'
target="$directory/$CARTUNEZ_PROJECT.conf"
if [[ -e "$target" || -L "$target" ]]; then
  [[ ! -L "$target" ]] || die 'Refusing to replace a symlinked existing vhost.'
  grep -Fx "# Managed exclusively by $CARTUNEZ_PROJECT; other vhosts are not modified." "$target" >/dev/null || die 'Refusing to replace a vhost not managed by this application.'
fi
# Check exact server_name tokens, without printing unrelated configuration values.
nginx -T 2>/dev/null | DOMAIN="$DOMAIN" OWN="$target" python3 -c '
import os,sys
own=os.environ["OWN"];domain=os.environ["DOMAIN"];current=""
for line in sys.stdin:
 if line.startswith("# configuration file "): current=line[len("# configuration file "):].strip().rstrip(":")
 if line.strip().startswith("server_name ") and domain in line.strip().rstrip(";").split()[1:] and current != own:
  sys.exit("Domain already belongs to a different Nginx vhost; nothing changed.")
'
temporary="$(mktemp "$directory/.$CARTUNEZ_PROJECT.XXXXXX")"
render "$mode" > "$temporary"; chmod 644 "$temporary"
previous=""
if [[ -f "$target" ]]; then previous="$(mktemp "$CARTUNEZ_ROOT/state/nginx-previous.XXXXXX")"; cp "$target" "$previous"; fi
mv "$temporary" "$target"
if ! nginx -t; then
  if [[ -n "$previous" ]]; then cp "$previous" "$target"; else rm -f -- "$target"; fi
  die 'Candidate Nginx config rejected. Prior vhost restored; Nginx was not reloaded.'
fi
if ! systemctl reload nginx; then
  if [[ -n "$previous" ]]; then cp "$previous" "$target"; else rm -f -- "$target"; fi
  die 'Nginx reload failed. The previous dedicated vhost was restored; no service restart was attempted.'
fi
printf 'Installed only %s and reloaded Nginx after a passing config test.\n' "$target"
