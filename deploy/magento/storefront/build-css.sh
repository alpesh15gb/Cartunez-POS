#!/usr/bin/env bash
# Rebuilds the theme stylesheet from styles/cartunez.less (needs Node.js).
set -euo pipefail
cd "$(dirname "$0")"
npx -y less@4.2.0 styles/build.less app/design/frontend/Cartunez/default/web/css/cartunez.css
echo "Built app/design/frontend/Cartunez/default/web/css/cartunez.css"
