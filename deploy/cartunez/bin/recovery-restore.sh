#!/usr/bin/env bash
# Independent of common.sh: a clean host does not have its target config yet.
set -euo pipefail
umask 077
exec python3 "$(dirname "$0")/recovery.py" restore "$@"
