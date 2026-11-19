#!/usr/bin/env bash
# Stage 1: private settings and the Magento containers (database, search, cache, PHP).
# Safe to run on a shared host: it only creates /etc/cartunez-shop, /opt/cartunez-shop
# and the Docker project "cartunezshop", and refuses to continue if any of them exist
# in an unexpected state or if port 18600 is taken.
set -euo pipefail
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT=/opt/cartunez-shop
CONF=/etc/cartunez-shop
PORT=18600

echo '== Checks'
command -v docker >/dev/null || die 'Docker is missing.'
docker compose version >/dev/null || die 'Docker Compose is missing.'
if ss -ltn "( sport = :$PORT )" | grep -q LISTEN; then
  docker ps --format '{{.Names}} {{.Ports}}' | grep -q "cartunezshop-web.*127.0.0.1:$PORT" || die "Port $PORT is used by another program."
fi
[[ "$(sysctl -n vm.max_map_count)" -ge 262144 ]] || die 'vm.max_map_count must be at least 262144 for OpenSearch.'
avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
(( avail_mb > 3500 )) || die "Only ${avail_mb} MB RAM available; Magento needs about 3.5 GB."
echo "RAM available: ${avail_mb} MB. Port $PORT is free for Magento."

echo '== Private settings in /etc/cartunez-shop (root only)'
install -d -m 700 "$CONF"
for name in db_password db_root_password; do
  if [[ ! -s "$CONF/$name" ]]; then
    umask 077; openssl rand -hex 24 > "$CONF/$name"
    echo "created $CONF/$name"
  fi
done
# The database container reads these as Docker secrets (read-only, inside the container).
chmod 644 "$CONF/db_password" "$CONF/db_root_password"
chmod 700 "$CONF"

if [[ ! -s "$CONF/composer-auth.json" ]]; then
  echo 'Magento Marketplace access keys (commercemarketplace.adobe.com > My Profile > Access Keys).'
  read -r -p 'Public key: ' pub
  read -r -s -p 'Private key (hidden): ' priv; echo
  [[ -n "$pub" && -n "$priv" ]] || die 'Both keys are needed.'
  umask 077
  printf '{"http-basic":{"repo.magento.com":{"username":"%s","password":"%s"}}}\n' "$pub" "$priv" > "$CONF/composer-auth.json"
  unset pub priv
  echo "saved $CONF/composer-auth.json (root only)"
fi

echo '== Project files in /opt/cartunez-shop'
install -d -m 755 "$ROOT"
cp "$SRC"/compose.yaml "$SRC"/php.Dockerfile "$SRC"/php.ini "$SRC"/nginx.conf "$ROOT"/
cp "$SRC"/2-install.sh "$SRC"/3-nginx.sh "$ROOT"/

echo '== Containers (no ports published yet)'
cd "$ROOT"
docker compose -p cartunezshop build php
docker compose -p cartunezshop up -d db search cache php
echo 'Waiting for the database and search to be healthy...'
for _ in $(seq 1 60); do
  db=$(docker inspect -f '{{.State.Health.Status}}' cartunezshop-db-1 2>/dev/null || true)
  se=$(docker inspect -f '{{.State.Health.Status}}' cartunezshop-search-1 2>/dev/null || true)
  [[ "$db" == healthy && "$se" == healthy ]] && break
  sleep 5
done
docker compose -p cartunezshop ps
[[ "$db" == healthy && "$se" == healthy ]] || die 'Database or search did not become healthy. See: docker compose -p cartunezshop logs db search'
echo
echo 'Stage 1 done. Next: bash /opt/cartunez-shop/2-install.sh'
