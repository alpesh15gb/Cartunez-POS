#!/usr/bin/env bash
# shellcheck disable=SC2016 # Variables inside sh -c expand in the container.
source "$(dirname "$0")/common.sh"
[[ $# -eq 3 && "$3" = --restore-database ]] || die 'Usage: rollback.sh target-release /absolute/matching-backup.dump --restore-database'
target="$1"; backup="$(realpath "$2")"; load_release "$target"; lock
[[ -s "$backup" && "$(sed -n 's/^release=//p' "$backup.meta")" = "$target" ]] || die 'Backup must match the target release.'
verify_backup "$backup"
touch "$CARTUNEZ_ROOT/maintenance"
compose stop api
# Preserve the current database before replacing it; the API stays stopped on failure.
export CARTUNEZ_LOCK_HELD=1 CARTUNEZ_RELEASE="$target" CARTUNEZ_BACKUP_LABEL=unknown-before-rollback
preserved="$(bash "$RELEASE/bin/backup.sh")"
printf 'Current database preserved at %s\n' "$preserved"
compose exec -T postgres sh -c 'pg_restore --clean --if-exists --exit-on-error --single-transaction --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$backup"
compose up -d --wait --wait-timeout 180 api
health
ln -s "$RELEASE" "$CARTUNEZ_ROOT/current.new"
mv -Tf "$CARTUNEZ_ROOT/current.new" "$CARTUNEZ_ROOT/current"
rm -f -- "$CARTUNEZ_ROOT/maintenance"
printf 'Restored matching database and release %s. Reconcile post-backup receipts and counter outboxes before resuming.\n' "$target"
