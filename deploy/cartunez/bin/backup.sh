#!/usr/bin/env bash
# shellcheck disable=SC2016 # Variables inside sh -c expand in the container.
source "$(dirname "$0")/common.sh"
load_release "${CARTUNEZ_RELEASE:-$(current_release)}"
[[ "${CARTUNEZ_LOCK_HELD:-}" = 1 ]] || lock
[[ ! -L "$BACKUP_DIR" ]] || die 'Unsafe backup directory.'
mkdir -p "$BACKUP_DIR"
[[ "$(stat -c %u "$BACKUP_DIR")" = 0 ]] || die 'Unsafe backup directory ownership.'
chmod 700 "$BACKUP_DIR"
stamp="$(date -u +%Y%m%dT%H%M%S)-$$"
destination="$BACKUP_DIR/$CARTUNEZ_PROJECT-$stamp.dump"
partial="$destination.partial"
trap 'rm -f -- "$partial"' EXIT
compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-privileges' > "$partial"
[[ -s "$partial" ]] || die 'Empty database backup.'
compose exec -T postgres pg_restore --list < "$partial" >/dev/null
mv "$partial" "$destination"
(cd "$BACKUP_DIR" && sha256sum "$(basename "$destination")") > "$destination.sha256"
printf 'release=%s\napi_image=%s\npostgres_image=%s\ncreated=%s\n' "${CARTUNEZ_BACKUP_LABEL:-$(basename "$RELEASE")}" "$API_IMAGE" "$POSTGRES_IMAGE" "$(date -u +%FT%TZ)" > "$destination.meta"
chmod 600 "$destination" "$destination.sha256" "$destination.meta"
python3 - "$BACKUP_DIR" "$CARTUNEZ_PROJECT" <<'PY'
import pathlib, sys, time
root=pathlib.Path(sys.argv[1]); prefix=sys.argv[2]+'-'
files=sorted((p for p in root.glob(prefix+'*.dump') if p.is_file() and not p.is_symlink()),key=lambda p:p.stat().st_mtime,reverse=True)
# Keep at least seven backups and fourteen days; only this project's known files.
for p in files[7:]:
    if p.stat().st_mtime < time.time()-14*86400:
        for name in [p, pathlib.Path(str(p)+'.sha256'), pathlib.Path(str(p)+'.meta')]:
            if name.is_file() and not name.is_symlink(): name.unlink()
PY
printf '%s\n' "$destination"
