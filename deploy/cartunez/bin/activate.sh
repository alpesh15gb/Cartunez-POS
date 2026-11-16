#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
[[ $# -eq 1 ]] || die 'Usage: activate.sh release-id'
next="$1"; load_release "$next"; lock
if [[ -L "$CARTUNEZ_ROOT/current" ]]; then
  previous="$(current_release)"
  [[ "$next" != "$previous" ]] || die 'Release is already current.'
  load_release "$previous"
  touch "$CARTUNEZ_ROOT/maintenance"
  compose stop api
  export CARTUNEZ_LOCK_HELD=1 CARTUNEZ_RELEASE="$previous"
  backup="$(bash "$RELEASE/bin/backup.sh")"
  printf 'Previous release %s backed up to %s\n' "$previous" "$backup"
  printf '%s\n%s\n' "$previous" "$backup" > "$CARTUNEZ_ROOT/state/pre-upgrade"
else
  if [[ -f "$CARTUNEZ_ROOT/state/initial-candidate" ]]; then
    [[ "$(cat "$CARTUNEZ_ROOT/state/initial-candidate")" = "$next" ]] || die 'Retry the recorded first release or inspect the incomplete installation before changing candidates.'
  else
    port_free "$API_PORT" || die "Port $API_PORT is occupied; choose a free loopback port before activation."
    if docker ps -aq --filter "label=com.docker.compose.project=$CARTUNEZ_PROJECT" | grep -q .; then
      die 'Project already has containers without a current release; inspect before recovery.'
    fi
    for resource in volume network; do
      if docker "$resource" ls -q --filter "label=com.docker.compose.project=$CARTUNEZ_PROJECT" | grep -q .; then
        die "Project already has $resource resources without a current release; inspect before recovery."
      fi
    done
    if docker volume inspect "${CARTUNEZ_PROJECT}_postgres_data" >/dev/null 2>&1; then
      die 'The initial database volume name is already occupied; it was not attached or changed.'
    fi
    for network in database application; do
      if docker network inspect "${CARTUNEZ_PROJECT}_$network" >/dev/null 2>&1; then
        die 'An initial network name is already occupied; it was not attached or changed.'
      fi
    done
    printf '%s\n' "$next" > "$CARTUNEZ_ROOT/state/initial-candidate"
  fi
fi
load_release "$next"
if ! compose up -d --wait --wait-timeout 180 || ! health; then
  compose stop api
  die 'Candidate failed. API stopped, previous web retained. Inspect project logs and use rollback.sh with the recorded backup; no automatic schema downgrade was attempted.'
fi
ln -s "$RELEASE" "$CARTUNEZ_ROOT/current.new"
mv -Tf "$CARTUNEZ_ROOT/current.new" "$CARTUNEZ_ROOT/current"
if [[ -n "${previous:-}" ]]; then ln -sfn "$CARTUNEZ_ROOT/releases/$previous" "$CARTUNEZ_ROOT/previous"; fi
rm -f -- "$CARTUNEZ_ROOT/maintenance"
rm -f -- "$CARTUNEZ_ROOT/state/initial-candidate"
printf 'Activated %s. Verify the dedicated HTTPS host before opening counters.\n' "$next"
