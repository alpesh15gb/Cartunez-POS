#!/usr/bin/env bash
# Checks a Flutter web build before it is staged. The VPS has no Flutter SDK, so
# the build comes either from CI (fetch-web.sh, selected by WEB_BUNDLE in the
# host configuration) or from the copy committed at apps/flutter/release/web
# (built on a developer PC with apps/flutter/tool/build_web.ps1).
# With one argument it checks the committed copy; a second argument names the
# directory to check instead.
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 || $# -eq 2 ]] || die 'Usage: build-web.sh /absolute/source/root [/absolute/web/dir]'
source_root="$(realpath "$1")"
[[ "$source_root" != / && -f "$source_root/package-lock.json" ]] || die 'Expected a Cartunez source checkout.'
python3 - "$source_root/package.json" <<'PY'
import json,sys
if json.load(open(sys.argv[1])).get('name')!='motorline-production':sys.exit('Unexpected source package.')
PY
if [[ $# -eq 2 ]]; then web="$2"; else web="$source_root/apps/flutter/release/web"; fi
[[ "$web" = /* ]] || die 'The web directory must be an absolute path.'
[[ -d "$web" && ! -L "$web" && "$(realpath "$web")" = "$web" ]] || die "Missing Flutter web build at $web. Use the CI bundle (WEB_BUNDLE=ci in the host configuration) or build it with apps/flutter/tool/build_web.ps1 and commit it."
for file in index.html flutter_bootstrap.js main.dart.js sw.js version.json canvaskit/canvaskit.wasm scanner/3.1.6/reader.js scanner/3.1.6/zxing_reader.wasm; do
  [[ -s "$web/$file" ]] || die "Flutter web build is incomplete: $file is missing."
done
if find "$web" -type l | grep -q .; then die 'Flutter web build must not contain symlinks.'; fi
printf 'Flutter web build %s is ready at %s.\n' \
  "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("version","?")+"+"+d.get("build_number","?"))' "$web/version.json")" "$web"
