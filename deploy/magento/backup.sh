#!/usr/bin/env bash
# Backs up the Cartunez shop: database, product photos and app/etc (which holds
# the key that decrypts saved passwords). Keeps 14 days in /var/backups/cartunez-shop.
# Installed by 5-launch.sh as /usr/local/sbin/cartunez-shop-backup (cron 02:30).
# Copy this folder off the server regularly: a backup on the same disk does not
# survive losing the server.
set -euo pipefail
DIR=/var/backups/cartunez-shop
KEEP_DAYS="${KEEP_DAYS:-14}"
cd /opt/cartunez-shop
dc() { docker compose -p cartunezshop "$@"; }
umask 077
mkdir -p "$DIR"
ts=$(date +%Y%m%d-%H%M)
dc exec -T db sh -c 'mariadb-dump -umagento -p"$(cat /run/secrets/db_password)" --single-transaction --quick --routines --triggers magento' \
  | gzip > "$DIR/db-$ts.sql.gz.part"
mv "$DIR/db-$ts.sql.gz.part" "$DIR/db-$ts.sql.gz"
dc exec -T php tar -C /var/www/magento -czf - --exclude=pub/media/catalog/product/cache pub/media app/etc > "$DIR/files-$ts.tar.gz.part"
mv "$DIR/files-$ts.tar.gz.part" "$DIR/files-$ts.tar.gz"
find "$DIR" -name '*.gz' -mtime +"$KEEP_DAYS" -delete
echo "$(date '+%F %T') backup ok: $(du -sh "$DIR/db-$ts.sql.gz" | cut -f1) database, $(du -sh "$DIR/files-$ts.tar.gz" | cut -f1) files"
