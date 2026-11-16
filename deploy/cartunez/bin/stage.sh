#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
[[ $# -eq 2 ]] || die 'Usage: stage.sh /absolute/source/root release-id'
source_root="$(realpath "$1")"; release_id="$2"
[[ "$release_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ && "$release_id" != *..* ]] || die 'Invalid release ID.'
[[ -f "$source_root/apps/web/out/index.html" && -f "$source_root/deploy/api.Dockerfile" ]] || die 'Build/export the web app in the source root first.'
lock
mkdir -p "$CARTUNEZ_ROOT/releases"
chmod 755 "$CARTUNEZ_ROOT/releases"
destination="$CARTUNEZ_ROOT/releases/$release_id"
[[ ! -e "$destination" ]] || die 'Release already exists; use a new immutable release ID.'
image_tag="$CARTUNEZ_PROJECT-api:$release_id"
docker build --tag "$image_tag" --file "$source_root/deploy/api.Dockerfile" "$source_root"
docker image inspect postgres:17-alpine >/dev/null 2>&1 || docker pull postgres:17-alpine
mkdir -m 755 "$destination"
cp -a "$source_root/apps/web/out" "$destination/web"
python3 - "$destination/web/installation.json" <<'PY'
import json, os, sys
with open(sys.argv[1], 'w') as f:
    json.dump(dict(apiUrl='https://'+os.environ['DOMAIN']+'/api/v1',
                   organizationId=os.environ['BOOTSTRAP_ORG_ID'],
                   branchId=os.environ['BOOTSTRAP_BRANCH_ID']), f)
PY
cp "$source_root/deploy/cartunez/compose.yaml" "$destination/compose.yaml"
mkdir "$destination/bin"
cp "$source_root/deploy/cartunez/bin/"*.sh "$source_root/deploy/cartunez/bin/"*.py "$destination/bin/"
docker image inspect --format '{{.Id}}' "$image_tag" > "$destination/image-id"
docker image inspect --format '{{.Id}}' postgres:17-alpine > "$destination/postgres-image-id"
date -u +%FT%TZ > "$destination/staged-at"
if [[ -n "${CARTUNEZ_SOURCE_COMMIT:-}" ]]; then
  [[ "$CARTUNEZ_SOURCE_COMMIT" =~ ^[a-f0-9]{40}$|^[a-f0-9]{64}$ ]] || die 'Invalid source commit identifier.'
  printf '%s\n' "$CARTUNEZ_SOURCE_COMMIT" > "$destination/source-commit"
fi
chmod -R a+rX,u-w,go-w "$destination"
chmod a+rx "$destination/bin/"*.sh
load_release "$release_id"
compose config --quiet
printf 'Staged immutable release %s. No running service was changed.\n' "$release_id"
