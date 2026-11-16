#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../deploy"
destination="${1:-../backups/motorline-$(date -u +%Y%m%dT%H%M%SZ).dump}"
mkdir -p "$(dirname "$destination")"
umask 077
temporary="$destination.partial"
trap 'rm -f "$temporary"' EXIT
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$temporary"
test -s "$temporary"
mv "$temporary" "$destination"
sha256sum "$destination" > "$destination.sha256"
printf 'Backup saved to %s\n' "$destination"
