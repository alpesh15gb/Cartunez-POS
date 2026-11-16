#!/usr/bin/env bash
# Build a complete private cold-recovery bundle without changing scheduled retention.
source "$(dirname "$0")/common.sh"
[[ $# -le 1 ]] || die 'Usage: recovery-export.sh [/absolute/matching-backup.dump]'
load_release "${CARTUNEZ_RELEASE:-$(current_release)}"
lock
if [[ $# -eq 1 ]]; then
  backup="$(realpath "$1")"
else
  CARTUNEZ_RELEASE="$(basename "$RELEASE")"
  export CARTUNEZ_LOCK_HELD=1 CARTUNEZ_RELEASE
  backup="$(bash "$(dirname "$0")/backup.sh")"
fi
verify_backup "$backup"
python3 "$(dirname "$0")/recovery.py" export --config "$CARTUNEZ_CONFIG" --release "$RELEASE" --dump "$backup"
