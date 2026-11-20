#!/usr/bin/env bash
# Checks the Flutter web build committed at apps/flutter/release/web.
# It is built on a developer PC (apps/flutter/tool/build_web.ps1), so the VPS
# needs no Flutter SDK and no build container for the web app.
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 ]] || die 'Usage: build-web.sh /absolute/source/root'
source_root="$(realpath "$1")"
[[ "$source_root" != / && -f "$source_root/package-lock.json" ]] || die 'Expected a Cartunez source checkout.'
python3 - "$source_root/package.json" <<'PY'
import json,sys
if json.load(open(sys.argv[1])).get('name')!='motorline-production':sys.exit('Unexpected source package.')
PY
web="$source_root/apps/flutter/release/web"
[[ -d "$web" && ! -L "$web" && "$(realpath "$web")" = "$web" ]] || die 'Missing apps/flutter/release/web. Build it with apps/flutter/tool/build_web.ps1 and commit it.'
for file in index.html flutter_bootstrap.js main.dart.js sw.js version.json canvaskit/canvaskit.wasm scanner/3.1.6/reader.js scanner/3.1.6/zxing_reader.wasm; do
  [[ -s "$web/$file" ]] || die "Flutter web build is incomplete: $file is missing."
done
if find "$web" -type l | grep -q .; then die 'Flutter web build must not contain symlinks.'; fi
printf 'Flutter web build %s is ready at %s.\n' \
  "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("version","?")+"+"+d.get("build_number","?"))' "$web/version.json")" "$web"
