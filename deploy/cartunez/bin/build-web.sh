#!/usr/bin/env bash
set -euo pipefail
umask 022
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run the shared-host build as root.'
[[ $# -eq 1 ]] || die 'Usage: build-web.sh /absolute/source/root'
source_root="$(realpath "$1")"
[[ "$source_root" != / && -f "$source_root/package-lock.json" && -f "$source_root/deploy/cartunez/web-builder.Dockerfile" ]] || die 'Expected a Cartunez source checkout.'
web="$source_root/apps/web"
[[ "$(realpath "$web")" = "$web" && ! -L "$web/out" ]] || die 'Web/output paths must not traverse symlinks.'
python3 - "$source_root/package.json" <<'PY'
import json,sys
if json.load(open(sys.argv[1])).get('name')!='motorline-production':sys.exit('Unexpected source package.')
PY
temporary="$(mktemp -d "$web/.cartunez-out.XXXXXX")"
cleanup() {
  # This is the fresh directory created above, never an arbitrary caller path.
  if [[ -n "${temporary:-}" && "$temporary" = "$web"/.cartunez-out.* && ! -L "$temporary" ]]; then rm -rf -- "$temporary"; fi
}
trap cleanup EXIT
docker build --tag cartunezpos-web-builder:node22 --file "$source_root/deploy/cartunez/web-builder.Dockerfile" "$source_root"
docker run --rm --memory=2g --cpus=1.5 --pids-limit=256 \
  --cap-drop=ALL --security-opt=no-new-privileges:true --tmpfs /tmp:size=128m \
  --mount "type=bind,src=$source_root,dst=/src,readonly" \
  --mount "type=bind,src=$temporary,dst=/out" \
  cartunezpos-web-builder:node22
[[ -s "$temporary/index.html" && -s "$temporary/sw.js" ]] || die 'Frontend build produced incomplete output.'
# Replace only the ignored generated export, after the new build passed.
if [[ -e "$web/out" ]]; then
  [[ -d "$web/out" && "$(realpath "$web/out")" = "$web/out" ]] || die 'Unsafe existing export path.'
  rm -rf -- "$web/out"
fi
mv "$temporary" "$web/out"
temporary=''
printf 'Frontend export built in Docker at %s/out; no host Node installation or source dependency directory was used.\n' "$web"
