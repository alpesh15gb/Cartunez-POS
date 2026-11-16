#!/usr/bin/env bash
set -euo pipefail
# Source is mounted read-only. Dependencies and build cache live only in this
# disposable container; the sole writable host mount is the new export folder.
tar -C /src --exclude=node_modules --exclude=.next --exclude=out --exclude=dist \
  --exclude='.env*' --exclude='*.tsbuildinfo' \
  -cf - package.json package-lock.json tsconfig.json packages/contracts apps/web apps/api/package.json |
  tar -C /app -xf -
npm ci --workspace @motorline/web --include-workspace-root --no-audit --no-fund
npm run build --workspace @motorline/web
test -s /app/apps/web/out/index.html
test -s /app/apps/web/out/sw.js
cp -a /app/apps/web/out/. /out/
chmod -R a+rX /out
