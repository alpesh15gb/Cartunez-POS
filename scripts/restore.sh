#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then printf 'Usage: %s /absolute/path/backup.dump\n' "$0" >&2; exit 2; fi
backup="$(realpath "$1")"
test -s "$backup"
cd "$(dirname "$0")/../deploy"
# API is stopped during replacement so no writes can race the restore.
docker compose stop api
docker compose exec -T postgres sh -c 'pg_restore --clean --if-exists --exit-on-error --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$backup"
docker compose up -d api
printf 'Restore finished. Wait for API health before reopening counters.\n'
