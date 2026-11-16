#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
load_release "$(current_release)"
compose ps
health
printf 'Loopback API healthy. Current release: %s\n' "$(basename "$RELEASE")"
[[ ! -f "$CARTUNEZ_ROOT/maintenance" ]] || printf 'Maintenance marker is active.\n'
