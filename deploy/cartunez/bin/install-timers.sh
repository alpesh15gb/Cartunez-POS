#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
[[ -d /run/systemd/system ]] || die 'This installer requires systemd.'
[[ -L "$CARTUNEZ_ROOT/current" ]] || die 'Activate a release first.'
unit="/etc/systemd/system/$CARTUNEZ_PROJECT-backup"
for suffix in service timer; do
  if [[ -e "$unit.$suffix" ]]; then
    grep -Fx "# Managed exclusively by $CARTUNEZ_PROJECT" "$unit.$suffix" >/dev/null || die 'Existing unrelated systemd unit will not be replaced.'
  fi
done
cat > "$unit.service" <<EOF
# Managed exclusively by $CARTUNEZ_PROJECT
[Unit]
Description=Cartunez POS PostgreSQL backup
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
User=root
UMask=0077
Environment=CARTUNEZ_CONFIG=$CARTUNEZ_CONFIG
ExecStart=/bin/bash $CARTUNEZ_ROOT/current/bin/backup.sh
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=30min
EOF
cat > "$unit.timer" <<EOF
# Managed exclusively by $CARTUNEZ_PROJECT
[Unit]
Description=Nightly Cartunez POS database backup
[Timer]
OnCalendar=*-*-* 03:15:00
RandomizedDelaySec=20m
Persistent=true
[Install]
WantedBy=timers.target
EOF
chmod 644 "$unit.service" "$unit.timer"
systemd-analyze verify "$unit.service" "$unit.timer"
systemctl daemon-reload
systemctl enable --now "$CARTUNEZ_PROJECT-backup.timer"
hook="/etc/letsencrypt/renewal-hooks/deploy/$CARTUNEZ_PROJECT-reload-nginx"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
if [[ -e "$hook" ]]; then grep -Fx "# Managed exclusively by $CARTUNEZ_PROJECT" "$hook" >/dev/null || die 'Existing certificate hook will not be replaced.'; fi
cat > "$hook" <<EOF
#!/usr/bin/env bash
# Managed exclusively by $CARTUNEZ_PROJECT
set -euo pipefail
if [[ "\${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/$DOMAIN ]]; then nginx -t && systemctl reload nginx; fi
EOF
chmod 755 "$hook"
printf 'Installed dedicated backup timer and domain-specific successful-renewal hook.\n'
