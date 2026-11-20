#!/usr/bin/env bash
# Bash twin of tool/build_web.ps1, used by CI. Builds the web app with every
# resource bundled locally (no Google CDN, no source maps) and writes it to
# release/web, or to the directory given as the first argument.
# Usage (from anywhere):  bash apps/flutter/tool/build_web.sh [output-dir]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/release/web}"
cd "$root"

flutter build web --release --no-web-resources-cdn --no-source-maps

rm -rf "$out"
mkdir -p "$out"
cp -R "$root/build/web/." "$out/"
# Not used: there is no Flutter service worker, and source maps stay private.
rm -f "$out/flutter_service_worker.js" "$out/flutter.js.map"
find "$out" \( -name '*.symbols' -o -name '.last_build_id' \) -type f -delete

# The same completeness check the VPS runs before staging a release.
for f in index.html flutter_bootstrap.js main.dart.js sw.js version.json canvaskit/canvaskit.wasm \
         scanner/3.1.6/reader.js scanner/3.1.6/zxing_reader.wasm; do
  [[ -s "$out/$f" ]] || { echo "Web build is incomplete: $f is missing." >&2; exit 1; }
done
if find "$out" -type l | grep -q .; then echo 'Web build must not contain symlinks.' >&2; exit 1; fi

printf 'Web build ready at %s (%s).\n' "$out" "$(du -sh "$out" | cut -f1)"
