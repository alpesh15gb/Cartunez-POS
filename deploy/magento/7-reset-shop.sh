#!/usr/bin/env bash
# Stage 7 (fresh launch): clear the shop's test data. Run as root, AFTER the POS
# reset (deploy/cartunez/bin/reset-data.sh), which forgets the POS side's Magento
# product and category ids so the next publish creates the products again.
#   bash /opt/cartunez-shop-source/deploy/magento/7-reset-shop.sh
# Deletes: all products (and their photos, URL rewrites, MSI stock and reservations),
# all orders, invoices, shipments, credit memos, carts and their grids (order,
# invoice, shipment and credit memo numbers start again), all customers and their
# addresses, and every category except the catalog root (1) and the store root (2).
# Keeps: CMS pages and blocks, the theme, configuration, admin users, the POS
# integration token, tax, payment and shipping settings.
# A full backup (deploy/magento/backup.sh) is taken first; restore steps are in README.md.
set -Eeuo pipefail
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
[[ $# -eq 0 ]] || die 'Usage: 7-reset-shop.sh (no arguments; it asks before changing anything)'
[[ -t 0 ]] || die 'Run this from an interactive terminal: it asks for confirmation.'
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT=/opt/cartunez-shop
cd "$ROOT"
dc() { docker compose -p cartunezshop "$@"; }
inphp() { dc exec -T php "$@"; }
mage() { inphp php -d memory_limit=4G bin/magento "$@"; }
# SQL on the shop database (stdin or -e), stopping at the first error.
sql() { dc exec -T db sh -c 'exec mariadb -umagento -p"$(cat /run/secrets/db_password)" magento "$@"' sh "$@"; }
value() { sql -N -B -e "$1" | tr -d '\r'; }

echo '== Cartunez shop fresh launch: clear test data'
# ---------- Preflight ----------
for service in db php; do
  dc ps --status running --services | grep -qx "$service" || die "The $service container is not running."
done
inphp test -f app/etc/env.php || die 'Magento is not installed here.'
[[ "$(value 'SELECT 1')" = 1 ]] || die 'Cannot reach the shop database.'
roots="$(value 'SELECT GROUP_CONCAT(DISTINCT root_category_id) FROM store_group WHERE group_id > 0')"
[[ "$roots" = 2 ]] || die "Expected every store to use root category 2, found: $roots. Nothing was changed."
[[ "$(value 'SELECT COUNT(*) FROM catalog_category_entity WHERE entity_id IN (1,2)')" = 2 ]] \
  || die 'The root categories 1 and 2 are missing. Nothing was changed.'
mapfile -t tables < <(value "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'")
declare -A have=()
for t in "${tables[@]}"; do have["$t"]=1; done
for t in catalog_product_entity catalog_category_entity sales_order quote customer_entity url_rewrite; do
  [[ -n "${have[$t]:-}" ]] || die "Table $t is missing: is this a Magento 2.4 database? Nothing was changed."
done

# ---------- Full backup first ----------
echo '== Full backup (database, photos, app/etc)'
if [[ -f "$HERE/backup.sh" ]]; then backup_script="$HERE/backup.sh"; else backup_script=/usr/local/sbin/cartunez-shop-backup; fi
[[ -f "$backup_script" ]] || die 'backup.sh was not found. Nothing was changed.'
before="$(date +%s)"
bash "$backup_script" || die 'The backup failed. Nothing was changed.'
db_backup="$(find /var/backups/cartunez-shop -maxdepth 1 -name 'db-*.sql.gz' -newermt "@$((before - 1))" -size +1k | sort | tail -n 1)"
files_backup="$(find /var/backups/cartunez-shop -maxdepth 1 -name 'files-*.tar.gz' -newermt "@$((before - 1))" | sort | tail -n 1)"
[[ -n "$db_backup" && -n "$files_backup" ]] || die 'The new backup files were not found. Nothing was changed.'
gzip -t "$db_backup" || die "The database backup $db_backup is damaged. Nothing was changed."
# Clearly named copies that the 14-day clean-up does not remove.
cp -- "$db_backup" "/var/backups/cartunez-shop/before-reset-$(basename "$db_backup" .gz).gz.keep"
cp -- "$files_backup" "/var/backups/cartunez-shop/before-reset-$(basename "$files_backup" .gz).gz.keep"
db_backup="/var/backups/cartunez-shop/before-reset-$(basename "$db_backup" .gz).gz.keep"
files_backup="/var/backups/cartunez-shop/before-reset-$(basename "$files_backup" .gz).gz.keep"
printf 'Backup: %s\n        %s\n' "$db_backup" "$files_backup"

# ---------- What will be deleted and kept ----------
count() { if [[ -n "${have[$1]:-}" ]]; then value "SELECT COUNT(*) FROM \`$1\`${2:+ WHERE $2}"; else echo 0; fi; }
echo
echo 'WILL BE DELETED:'
printf '  %-34s %8s\n' \
  'products' "$(count catalog_product_entity)" \
  'categories (Brands, Sale, POS ones)' "$(count catalog_category_entity 'entity_id NOT IN (1,2)')" \
  'orders' "$(count sales_order)" \
  'invoices' "$(count sales_invoice)" \
  'shipments' "$(count sales_shipment)" \
  'credit memos' "$(count sales_creditmemo)" \
  'carts (quotes)' "$(count quote)" \
  'customers' "$(count customer_entity)" \
  'customer addresses' "$(count customer_address_entity)" \
  'product/category URL rewrites' "$(count url_rewrite "entity_type IN ('product','category')")" \
  'MSI source items' "$(count inventory_source_item)" \
  'MSI reservations' "$(count inventory_reservation)" \
  'product photo files' "$(inphp sh -c 'find pub/media/catalog/product -type f ! -path "*/placeholder/*" 2>/dev/null | wc -l' | tr -d '[:space:]')"
echo 'WILL BE KEPT:'
printf '  %-34s %8s\n' \
  'CMS pages' "$(count cms_page)" \
  'CMS blocks' "$(count cms_block)" \
  'admin users' "$(count admin_user)" \
  'integrations (POS token)' "$(count integration)" \
  'root categories (1, 2)' 2
echo '  plus the theme, configuration, tax, payment and shipping settings.'
echo
printf 'This permanently deletes the data listed above (the backup above can restore it).\n'
printf 'Type CLEAR SHOP to continue: '
read -r answer
[[ "$answer" = 'CLEAR SHOP' ]] || die 'Not confirmed. Nothing was changed.'

# ---------- Reset ----------
echo '== Maintenance on, cron paused'
mage maintenance:enable >/dev/null
dc stop cron >/dev/null
trap 'echo; echo "STOPPED WITH AN ERROR. The shop is still in maintenance and cron is paused."; echo "The database part runs as one transaction: if it failed, nothing in the database was deleted."; echo "Backup: $db_backup and $files_backup (restore steps: deploy/magento/README.md, Fresh launch)."; echo "To reopen the shop as it is now:"; echo "  docker compose -p cartunezshop start cron"; echo "  docker compose -p cartunezshop exec -T php php bin/magento maintenance:disable"' ERR

# Delete only from tables this Magento has, children before parents, so foreign keys hold.
del() { local t; for t in "$@"; do [[ -z "${have[$t]:-}" ]] || printf 'DELETE FROM `%s`;\n' "$t"; done; }
{
  echo 'SET SESSION innodb_lock_wait_timeout = 300;'
  echo 'START TRANSACTION;'
  # Sales: payments, documents, orders, grids and report aggregates.
  del sales_payment_transaction sales_order_tax_item sales_order_tax \
      sales_creditmemo_comment sales_creditmemo_item sales_creditmemo sales_creditmemo_grid \
      sales_invoice_comment sales_invoice_item sales_invoice sales_invoice_grid \
      sales_shipment_comment sales_shipment_track sales_shipment_item sales_shipment sales_shipment_grid \
      inventory_shipment_source inventory_source_selection_item inventory_order_notification \
      downloadable_link_purchased_item downloadable_link_purchased \
      sales_order_status_history sales_order_payment sales_order_address sales_order_item sales_order sales_order_grid \
      sales_order_aggregated_created sales_order_aggregated_updated \
      sales_invoiced_aggregated sales_invoiced_aggregated_order \
      sales_refunded_aggregated sales_refunded_aggregated_order \
      sales_shipping_aggregated sales_shipping_aggregated_order \
      sales_bestsellers_aggregated_daily sales_bestsellers_aggregated_monthly sales_bestsellers_aggregated_yearly \
      paypal_billing_agreement_order paypal_billing_agreement
  # Carts.
  del quote_id_mask quote_item_option quote_shipping_rate quote_address_item quote_address quote_payment quote_item quote
  # Customers and their addresses (the POS integration token belongs to no customer and stays).
  del customer_grid_flat customer_visitor customer_log persistent_session product_alert_price product_alert_stock \
      wishlist_item_option wishlist_item wishlist vault_payment_token_order_payment_link vault_payment_token \
      login_as_customer login_as_customer_assistance_allowed
  [[ -z "${have[oauth_token]:-}" ]] || echo 'DELETE FROM `oauth_token` WHERE customer_id IS NOT NULL;'
  [[ -z "${have[newsletter_subscriber]:-}" ]] || echo 'DELETE FROM `newsletter_subscriber`;'
  del customer_address_entity customer_entity
  # Products: links, MSI stock, gallery, then the products (their EAV values cascade).
  del catalog_url_rewrite_product_category catalog_category_product catalog_compare_item report_viewed_product_index report_compared_product_index \
      inventory_reservation inventory_source_item inventory_low_stock_notification_configuration \
      cataloginventory_stock_status cataloginventory_stock_item \
      catalog_product_entity_media_gallery_value_video catalog_product_entity_media_gallery_value \
      catalog_product_entity_media_gallery_value_to_entity catalog_product_entity_media_gallery \
      catalog_product_entity
  [[ -z "${have[url_rewrite]:-}" ]] || echo "DELETE FROM \`url_rewrite\` WHERE entity_type IN ('product','category');"
  # Categories except the catalog root (1) and the store root (2).
  echo 'DELETE FROM `catalog_category_entity` WHERE entity_id NOT IN (1,2) ORDER BY level DESC;'
  echo 'UPDATE `catalog_category_entity` SET children_count = 1 WHERE entity_id = 1;'
  echo 'UPDATE `catalog_category_entity` SET children_count = 0 WHERE entity_id = 2;'
  echo 'COMMIT;'
} > "/tmp/cartunez-shop-reset-$$.sql"
trap 'rm -f "/tmp/cartunez-shop-reset-$$.sql"' EXIT
echo '== Deleting (one database transaction)'
sql < "/tmp/cartunez-shop-reset-$$.sql"

# Order, invoice, shipment and credit memo numbers start again (outside the transaction:
# TRUNCATE resets the counter; these tables hold only the counters).
echo '== Restarting the document numbers'
mapfile -t sequences < <(value "SELECT sequence_table FROM sales_sequence_meta WHERE entity_type IN ('order','invoice','shipment','creditmemo')")
for t in "${sequences[@]}"; do
  [[ "$t" =~ ^sequence_(order|invoice|shipment|creditmemo)_[0-9]+$ ]] || die "Unexpected sequence table $t."
  if [[ -n "${have[$t]:-}" ]]; then sql -e "TRUNCATE TABLE \`$t\`"; fi
done

echo '== Removing product photos (the placeholder stays)'
inphp sh -c 'cd pub/media/catalog/product 2>/dev/null || exit 0; find . -mindepth 1 -maxdepth 1 ! -name placeholder -exec rm -rf {} +'

echo '== Reindexing and clearing caches'
mage indexer:reset >/dev/null
mage indexer:reindex
mage cache:flush >/dev/null
dc start cron >/dev/null
mage maintenance:disable >/dev/null
trap - ERR

echo
echo '== Done. The shop now has:'
printf '  %-14s %6s\n' \
  products "$(count catalog_product_entity)" \
  categories "$(count catalog_category_entity)" \
  orders "$(count sales_order)" \
  customers "$(count customer_entity)" \
  'CMS pages' "$(count cms_page)" \
  'CMS blocks' "$(count cms_block)"
printf 'Backup of the shop before the reset:\n  %s\n  %s\n' "$db_backup" "$files_backup"
echo 'Next: publish the parts again from the POS (Online store); they are created as new products.'
