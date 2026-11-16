#!/usr/bin/env bash
set -euo pipefail
umask 077
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run this host operation as root.'
export CARTUNEZ_CONFIG="${CARTUNEZ_CONFIG:-/etc/cartunez-pos/config.json}"
settings_exports="$(python3 - "$CARTUNEZ_CONFIG" <<'PY'
import json, os, pathlib, re, shlex, sys
p=pathlib.Path(sys.argv[1]); s=p.stat()
if not p.is_file() or p.is_symlink() or s.st_uid != 0 or s.st_mode & 0o077:
    sys.exit('Host configuration must be a root-owned regular file with mode 0600.')
values=json.loads(p.read_text())
for key in ['CARTUNEZ_ROOT','BACKUP_DIR','ACME_ROOT']:
    path=pathlib.Path(values[key])
    if not re.fullmatch(r'/[A-Za-z0-9/_-]+',str(path)) or path.resolve()!=path or len(path.parts)<3:
        sys.exit('Unsafe runtime directory: '+key)
if not re.fullmatch(r'[a-z0-9][a-z0-9.-]+\.[a-z]{2,}',values['DOMAIN']): sys.exit('Invalid domain')
if not 1024<=int(values['API_PORT'])<=65535: sys.exit('Invalid API port')
for key,value in values.items():
    if not key.replace('_','').isalnum() or not key.isupper(): sys.exit('Invalid setting key')
    print('export '+key+'='+shlex.quote(str(value)))
PY
)" || die 'Unable to load private configuration.'
eval "$settings_exports"
unset settings_exports
[[ "$CARTUNEZ_ROOT" = /* && "$CARTUNEZ_ROOT" != / && ! -L "$CARTUNEZ_ROOT" ]] || die 'Unsafe application root.'
[[ "$CARTUNEZ_PROJECT" =~ ^[a-z][a-z0-9]{2,30}$ ]] || die 'Invalid project.'
release_path() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$ && "$1" != *..* ]] || die 'Invalid release ID.'
  local selected="$CARTUNEZ_ROOT/releases/$1"
  [[ -d "$selected" && ! -L "$selected" && "$(realpath "$selected")" = "$selected" ]] || die 'Release is missing or symlinked.'
  printf '%s' "$selected"
}
load_release() {
  RELEASE="$(release_path "$1")"
  read -r API_IMAGE < "$RELEASE/image-id"
  read -r POSTGRES_IMAGE < "$RELEASE/postgres-image-id"
  [[ "$API_IMAGE" =~ ^sha256:[a-f0-9]{64}$ && "$POSTGRES_IMAGE" =~ ^sha256:[a-f0-9]{64}$ ]] || die 'Invalid pinned release image.'
  export API_IMAGE POSTGRES_IMAGE
}
current_release() { basename "$(readlink -f "$CARTUNEZ_ROOT/current")"; }
compose() { docker compose --env-file /dev/null -p "$CARTUNEZ_PROJECT" -f "$RELEASE/compose.yaml" "$@"; }
health() { curl --noproxy 127.0.0.1 --fail --silent --show-error --max-time 5 "http://127.0.0.1:$API_PORT/api/v1/health" >/dev/null; }
port_free() { ! ss -H -ltn "sport = :$1" | grep -q .; }
verify_backup() {
  local backup="$1" expected actual
  [[ -s "$backup" && -f "$backup.sha256" && -f "$backup.meta" ]] || die 'Backup and its checksum/metadata files are required.'
  read -r expected _ < "$backup.sha256"
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || die 'Invalid backup checksum sidecar.'
  actual="$(sha256sum "$backup")"; actual="${actual%% *}"
  [[ "$expected" = "$actual" ]] || die 'Backup checksum failed.'
}
lock() { mkdir -p "$CARTUNEZ_ROOT/state"; exec 9>"$CARTUNEZ_ROOT/state/operation.lock"; flock -n 9 || die 'Another Cartunez deployment/backup operation is running.'; }
