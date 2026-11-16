#!/usr/bin/env bash
# Read-only inventory. Intentionally does not dump nginx -T, docker inspect, or env values.
set -euo pipefail
domain="${1:-pos.cartunez.in}"
port="${2:-18400}"
[[ "$domain" =~ ^[a-z0-9.-]+$ && "$port" =~ ^[0-9]+$ ]] || exit 2
printf 'OS\n'; cat /etc/os-release
printf '\nTool versions\n'
for command in docker nginx openssl curl python3 ss; do command -v "$command" || true; done
docker version --format 'Docker client {{.Client.Version}}, server {{.Server.Version}}' 2>/dev/null || true
docker compose version 2>/dev/null || true
nginx -v 2>&1 || true
printf '\nNginx configuration test\n'; nginx -t 2>&1 || true
printf '\nExisting Nginx names/listens/includes/certificate paths (values only)\n'
nginx -T 2>/dev/null | sed -nE '/^[[:space:]]*(server_name|listen|include|ssl_certificate)[[:space:]]/p' || true
printf '\nExisting Compose projects and published ports\n'
docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}' 2>/dev/null || true
printf '\nRequested API port %s\n' "$port"; ss -H -ltn "sport = :$port"
printf '\nDNS for %s\n' "$domain"; getent ahosts "$domain" || true
printf '\nDisk and memory\n'; df -h /opt /var; free -h
printf '\nExisting application paths\n'
for target in /opt/cartunez-pos /etc/cartunez-pos /var/lib/cartunez-pos; do [[ ! -e "$target" ]] || stat -c '%A %U:%G %n' "$target"; done
printf '\nExisting certificate names\n'
find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null || true
