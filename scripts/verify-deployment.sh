#!/usr/bin/env bash
set -euo pipefail
origin="${1:-https://pos.shop.local}"
curl --fail --silent --show-error "$origin/api/v1/health"
curl --fail --silent --show-error "$origin/" > /dev/null
curl --fail --silent --show-error "$origin/manifest.webmanifest" > /dev/null
cd "$(dirname "$0")/../deploy"
docker compose ps
docker compose exec -T postgres sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
