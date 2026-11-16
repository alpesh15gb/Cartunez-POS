# Builds the web app and refreshes apps/flutter/release/web, which the VPS
# release copies as the site. Commit the result together with the source change.
# Usage (from apps\flutter):  powershell -ExecutionPolicy Bypass -File tool\build_web.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").ProviderPath
Set-Location $root

flutter build web --release --no-web-resources-cdn --no-source-maps
if ($LASTEXITCODE -ne 0) { throw 'flutter build web failed' }

$out = Join-Path $root 'release\web'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item -Recurse -Force "$root\build\web\*" $out
# Not used: there is no Flutter service worker, and source maps stay private.
Remove-Item -Force -ErrorAction SilentlyContinue "$out\flutter_service_worker.js", "$out\flutter.js.map"
Get-ChildItem -Recurse -Force $out -Include '*.symbols', '.last_build_id' | Remove-Item -Force

$size = (Get-ChildItem -Recurse $out | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Web build ready at {0} ({1:N1} MB). Commit apps/flutter/release/web." -f $out, $size)
