#!/usr/bin/env bash
# shellcheck disable=SC2016 # Variables inside sh -c expand in the container.
source "$(dirname "$0")/common.sh"
[[ $# -eq 2 ]] || die 'Usage: drill.sh /absolute/backup.dump unused-loopback-port'
backup="$(realpath "$1")"; drill_port="$2"
[[ -s "$backup" && "$drill_port" =~ ^[0-9]{4,5}$ ]] || die 'Invalid backup or port.'
((drill_port >= 1024 && drill_port <= 65535)) || die 'Drill port must be between 1024 and 65535.'
verify_backup "$backup"
release_id="$(sed -n 's/^release=//p' "$backup.meta")"; load_release "$release_id"
lock; port_free "$drill_port" || die 'Restore-drill port is occupied.'
CARTUNEZ_PROJECT="${CARTUNEZ_PROJECT}drill$(date +%s)"
export CARTUNEZ_PROJECT API_PORT="$drill_port" BOOTSTRAP_OWNER_PASSWORD=''
cleanup() { compose down --volumes >/dev/null; }
trap cleanup EXIT
compose up -d --wait --wait-timeout 120 postgres
compose exec -T postgres sh -c 'pg_restore --exit-on-error --single-transaction --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$backup"
compose up -d --wait --wait-timeout 180 api
health
compose exec -T postgres sh -c 'psql -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "SELECT (SELECT count(*) FROM records) AS records, (SELECT count(*) FROM stock_ledger) AS stock_movements, (SELECT count(*) FROM transactions) AS idempotency_records;"'
printf 'Restore drill passed in isolated project %s; its disposable containers and volume will now be removed.\n' "$CARTUNEZ_PROJECT"
