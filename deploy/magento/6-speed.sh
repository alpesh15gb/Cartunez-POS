#!/usr/bin/env bash
# Stage 6: speed. Run once, then run 4-theme.sh, which rebuilds the shop's files
# with these settings.
#   1. Host Nginx compresses CSS, JavaScript, JSON, SVG and fonts (it compressed
#      only HTML before, so about 3 MB of scripts and styles went out uncompressed).
#   2. Magento minifies CSS, JavaScript and HTML, and moves scripts to the end of
#      the page so the page shows before the scripts run.
#   3. Magento's full-page cache is switched on (if it was off).
# Only the cartunezshop project and its own Nginx site are touched. Every Nginx
# change is tested with nginx -t and undone if the test fails. Safe to run again.
set -Eeuo pipefail
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
ROOT=/opt/cartunez-shop
SITE=/etc/nginx/sites-available/cartunez-shop.conf
SNIPPET=/etc/nginx/snippets/cartunez-shop-speed.conf
INCLUDE='    include snippets/cartunez-shop-speed*.conf;'
cd "$ROOT"
dc() { docker compose -p cartunezshop "$@"; }
inphp() { dc exec -T php "$@"; }
mage() { inphp php -d memory_limit=4G bin/magento "$@"; }

[[ -f "$SITE" ]] || die "Nginx site $SITE not found; run 3-nginx.sh first."
inphp test -f app/etc/env.php || die 'Install Magento first (2-install.sh).'

echo '== 1. Compression in host Nginx'
mkdir -p /etc/nginx/snippets
backup_site="$(mktemp)"; cp -p "$SITE" "$backup_site"
backup_snippet=''
[[ -f "$SNIPPET" ]] && { backup_snippet="$(mktemp)"; cp -p "$SNIPPET" "$backup_snippet"; }
cat > "$SNIPPET" <<'NGINX'
# Car Tunez shop: compress text files (written by deploy/magento/6-speed.sh).
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types text/plain text/css text/xml application/javascript text/javascript application/json application/xml image/svg+xml font/ttf application/vnd.ms-fontobject;
NGINX
if ! grep -qF 'snippets/cartunez-shop-speed' "$SITE"; then
  # Into the HTTPS server block, right after its client_max_body_size line.
  awk -v inc="$INCLUDE" '
    /listen 443/ { in443 = 1 }
    { print }
    in443 && !done && /client_max_body_size/ { print inc; done = 1 }
  ' "$backup_site" > "$SITE"
  grep -qF 'snippets/cartunez-shop-speed' "$SITE" || { cp -p "$backup_site" "$SITE"; die 'Could not find the HTTPS block in the Nginx site; nothing was changed.'; }
fi
if nginx -t 2>/dev/null; then
  systemctl reload nginx
  echo '   Nginx compression on.'
else
  cp -p "$backup_site" "$SITE"
  if [[ -n "$backup_snippet" ]]; then cp -p "$backup_snippet" "$SNIPPET"; else rm -f "$SNIPPET"; fi
  nginx -t || true
  die 'Nginx rejected the change; the previous site was restored and nothing else was touched.'
fi

echo '== 2. Magento minification and script placement'
for setting in dev/css/minify_files dev/js/minify_files dev/template/minify_html dev/js/move_script_to_bottom; do
  mage config:set "$setting" 1 >/dev/null
done
# Magento's own JavaScript bundling makes the first page slower over HTTP/2; keep it off.
mage config:set dev/js/enable_js_bundling 0 >/dev/null
mage config:set dev/js/merge_files 0 >/dev/null

echo '== 3. Full-page cache'
mage cache:enable full_page >/dev/null
mage cache:status | grep -E 'full_page|layout|block_html' || true

css=$(curl -sS -o /dev/null -w '%{size_download}' -H 'Accept-Encoding: gzip' -m 20 --resolve shop.cartunez.in:443:127.0.0.1 \
  "https://shop.cartunez.in/static/frontend/Cartunez/default/en_US/css/cartunez.css" 2>/dev/null || echo '?')
echo "Theme stylesheet now downloads as ${css} bytes (about 6000 expected with compression)."
echo 'Stage 6 done. Now run 4-theme.sh to rebuild the shop files with minification and the new design.'
