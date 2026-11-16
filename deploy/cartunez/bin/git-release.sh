#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
[[ $# -eq 2 && ( "$1" = prepare || "$1" = update ) ]] || die 'Usage: git-release.sh prepare|update /opt/cartunez-pos-source'
action="$1"; source_root="$(realpath "$2")"
[[ "$source_root" != "$CARTUNEZ_ROOT" && "$source_root" != "$CARTUNEZ_ROOT/"* && "$source_root" != /opt/safar-crm && "$source_root" != /opt/safar-crm/* ]] || die 'Use a dedicated source clone outside live application directories.'
[[ -d "$source_root/.git" && ! -L "$source_root/.git" && "$(stat -c %u "$source_root")" = 0 ]] || die 'Source must be a root-owned standalone Git clone.'
[[ "$(git -C "$source_root" rev-parse --show-toplevel)" = "$source_root" ]] || die 'Pass the root of the intended Git checkout.'
exec 8>"$source_root/.git/cartunez-release.lock"
flock -n 8 || die 'Another build/update is using this source clone.'
remote="$(git -C "$source_root" remote get-url origin)"
[[ "$remote" = https://github.com/alpesh15gb/Cartunez-POS.git || "$remote" = https://github.com/alpesh15gb/Cartunez-POS ]] || die 'Unexpected origin; refusing to build or pull a different repository.'
[[ "$(git -C "$source_root" branch --show-current)" = main ]] || die 'Use the published main branch, not a detached or different branch.'
[[ -z "$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)" ]] || die 'Source has local changes or untracked files. Review them; this script never resets, stashes, or cleans them.'
if [[ "$action" = update ]]; then git -C "$source_root" pull --ff-only origin main; fi
commit="$(git -C "$source_root" rev-parse HEAD)"
[[ "$commit" = "$(git -C "$source_root" rev-parse refs/remotes/origin/main)" ]] || die 'Local HEAD differs from published origin/main; review local commits before deployment.'
[[ -z "$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)" ]] || die 'Source changed during the update.'
version="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$source_root/package.json")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || die 'Package version is not safe for a release identifier.'
release="$version-$(date -u +%Y%m%dT%H%M%SZ)-${commit:0:12}"
bash "$source_root/deploy/cartunez/bin/build-web.sh" "$source_root"
[[ "$(git -C "$source_root" rev-parse HEAD)" = "$commit" && -z "$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)" ]] || die 'Tracked source changed during the build; no release staged.'
export CARTUNEZ_SOURCE_COMMIT="$commit"
bash "$source_root/deploy/cartunez/bin/stage.sh" "$source_root" "$release"
mkdir -p "$CARTUNEZ_ROOT/state"
printf '%s\n' "$release" > "$CARTUNEZ_ROOT/state/git-staged-release"
printf '\nStaged commit %s as %s. Running services were not changed.\n' "$commit" "$release"
printf 'Activate with: bash %s/releases/%s/bin/activate.sh %s\n' "$CARTUNEZ_ROOT" "$release" "$release"
