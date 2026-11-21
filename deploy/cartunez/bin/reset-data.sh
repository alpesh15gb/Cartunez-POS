#!/usr/bin/env bash
# Fresh launch: clear the POS test data. Run as root on the VPS:
#   sudo bash /opt/cartunez-pos/current/bin/reset-data.sh
# Order: preflight, full backup (stops if it fails), counts, type CLEAR POS,
# API stopped, one-transaction reset (apps/api/src/reset.ts), API started again.
# Keeps: organization, branches, owner account(s), bins, customers and suppliers
# (opening balances 0), the Magento connection; settings return to defaults.
# Restore: bin/rollback.sh <current-release> <backup.dump> --restore-database
source "$(dirname "$0")/common.sh"
[[ $# -eq 0 ]] || die 'Usage: reset-data.sh (no arguments; it asks before changing anything)'
[[ -t 0 ]] || die 'Run this from an interactive terminal: it asks for confirmation.'
load_release "${CARTUNEZ_RELEASE:-$(current_release)}"
lock
release_id="$(basename "$RELEASE")"
cli=(node apps/api/dist/reset-cli.js)
# A one-off container from the pinned API image, on the database network, with DATABASE_URL.
run_cli() { compose run --rm --no-deps -T api "${cli[@]}" "$@"; }

printf '== Cartunez POS fresh launch: clear test data ==\nRelease: %s\n' "$release_id"
# ---------- Preflight ----------
compose ps --status running --services | grep -qx postgres || die 'The postgres service is not running.'
health || die 'The API is not healthy. Fix it before resetting.'
run_cli count >/dev/null 2>&1 || die 'This release has no reset tool (apps/api/dist/reset-cli.js). Stage and activate a release that includes it first.'

# ---------- Full backup first ----------
printf 'Taking a full database backup...\n'
export CARTUNEZ_LOCK_HELD=1 CARTUNEZ_RELEASE="$release_id" CARTUNEZ_BACKUP_LABEL="$release_id"
backup="$(bash "$(dirname "$0")/backup.sh")" || die 'Backup failed. Nothing was changed.'
verify_backup "$backup"
# A clearly named copy outside the scheduled-backup retention (which prunes $CARTUNEZ_PROJECT-*.dump).
keep_copy="$BACKUP_DIR/before-reset-$(basename "$backup")"
cp -- "$backup" "$keep_copy"
cp -- "$backup.meta" "$keep_copy.meta"
(cd "$BACKUP_DIR" && sha256sum "$(basename "$keep_copy")") > "$keep_copy.sha256"
chmod 600 "$keep_copy" "$keep_copy.sha256" "$keep_copy.meta"
backup="$keep_copy"
verify_backup "$backup"
printf 'Backup: %s\n\n' "$backup"

# ---------- What will be deleted and kept ----------
counts="$(run_cli count)" || die 'Unable to count the records.'
python3 - "$counts" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print('Organization:', data['organization'])
for side, title in (('delete', 'WILL BE DELETED'), ('keep', 'WILL BE KEPT')):
    print('\n' + title + ':')
    rows = data[side] or {'(nothing)': 0}
    for kind, n in sorted(rows.items()):
        print('  %-28s %8d' % (kind, n))
print('\nSettings return to defaults: number series restart at 1, "Not GST registered".')
print('The Magento connection (address, token, branch) is kept.')
PY
org="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["organization"])' "$counts")"
[[ "$org" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || die 'Unexpected organization code.'

printf '\nKeep the shop name, address, phone, email and invoice prefixes? [Y/n] '
read -r keep
identity=()
case "${keep,,}" in
  ''|y|yes) printf 'Business details will be kept.\n' ;;
  n|no) identity=(--reset-identity); printf 'Business details will be cleared.\n' ;;
  *) die 'Answer y or n. Nothing was changed.' ;;
esac

printf '\nThis permanently deletes the data listed above (the backup above can restore it).\n'
printf 'Type CLEAR POS to continue: '
read -r answer
[[ "$answer" = 'CLEAR POS' ]] || die 'Not confirmed. Nothing was changed.'

# ---------- Reset (one transaction) ----------
touch "$CARTUNEZ_ROOT/maintenance"
compose stop api
if ! result="$(run_cli apply --org "$org" --confirm 'CLEAR POS' "${identity[@]}")"; then
  # The reset is one transaction: on failure nothing was deleted.
  compose up -d --wait --wait-timeout 180 api || true
  rm -f -- "$CARTUNEZ_ROOT/maintenance"
  die "The reset failed and was rolled back; the API was started again. Backup: $backup"
fi
compose up -d --wait --wait-timeout 180 api
health || die "The data was cleared but the API is not healthy. Check: bin/status.sh, docker logs. Restore if needed: bin/rollback.sh $release_id $backup --restore-database"
rm -f -- "$CARTUNEZ_ROOT/maintenance"

python3 - "$result" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print('\nDone. Deleted:', sum(data['deleted'].values()), 'rows. Kept:')
for kind, n in sorted(data['kept'].items()):
    print('  %-28s %8d' % (kind, n))
PY
printf '\nBackup of the data before the reset: %s\n' "$backup"
printf 'Restore it with: bash %s/bin/rollback.sh %s %s --restore-database\n' "$RELEASE" "$release_id" "$backup"
printf 'Next: sign out and in again on every counter. Then run deploy/magento/7-reset-shop.sh for the website.\n'
