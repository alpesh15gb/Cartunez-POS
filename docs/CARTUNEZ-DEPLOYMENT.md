# Cartunez shared-VPS deployment

This runbook adds one isolated POS application to the existing Ubuntu 24.04 VPS. The supplied preflight showed Docker 29.7.2, Compose v5.5, working host Nginx, approximately 92 GB free disk and 10 GiB available RAM. Port 18400 was free, and no `pos.cartunez.in` vhost was present. The existing Nginx protocol-option warnings belong to other sites; these scripts do not change those sites or global Nginx settings. The owner confirmed the static IPv4 address `82.112.236.81` and saved the DNS A record. Check current public DNS and complete certificate issuance on that VPS; the local test environment did not perform a public deployment.

The new Compose project is `cartunezpos`. Its API is published only at `127.0.0.1:18400`, and its PostgreSQL service has no published port. The project owns its own networks and database volume. API and PostgreSQL containers are each limited to 768 MiB, one CPU, and three 10 MiB container log files. Host Nginx continues to own ports 80 and 443. Only the dedicated POS vhost enables level-3 gzip for JSON, JavaScript, CSS and SVG responses above 1 KiB; existing sites retain their own compression policies.

## Paths and prerequisites

| Path | Purpose |
| --- | --- |
| `/opt/cartunez-pos-source` | Dedicated public Git clone used to build releases; separate from all running applications |
| `/opt/cartunez-pos/releases/<release>` | Immutable web export, exact Docker image IDs, runtime scripts and Compose file |
| `/opt/cartunez-pos/current` | Active release symlink; changed only after API health passes |
| `/opt/cartunez-pos/state` | Operation lock and pre-upgrade recovery pointers |
| `/etc/cartunez-pos/config.json` | Root-owned mode-0600 settings and secrets; never put in a source archive |
| `/etc/cartunez-pos/owner-login.txt` | Mode-0600 first-login details, deleted after bootstrap completion |
| `/var/lib/cartunez-pos/backups` | Mode-0700 directory for custom-format PostgreSQL dumps |
| `/var/www/cartunez-pos-acme` | Public ACME challenge files only |
| `/etc/nginx/sites-enabled/cartunezpos.conf` | The only application vhost this workflow manages |

Commands below run as root and work independently of the shell's current directory, including when the current directory is `/opt/safar-crm`. The VPS needs Git, Bash, Docker/Compose, host Nginx, Python 3, OpenSSL, curl, util-linux and coreutils. Certbot is needed only for certificate issuance. No host Node.js installation is required: both API and frontend build in Docker from the committed lockfile. The frontend builder has a 2 GiB memory/1.5 CPU limit, reads source through a read-only mount, and writes only the generated frontend export inside the dedicated source clone. Runtime data and private configuration remain outside Git.

## 1. DNS and read-only checks

Confirm the A record for `pos.cartunez.in` points at `82.112.236.81`. Start with DNS-only mode if using Cloudflare. Remove any conflicting AAAA record unless this VPS has the corresponding working IPv6 routing. Leave existing records for other services unchanged. Public HTTP port 80 must reach host Nginx for the webroot challenge. A prior negative DNS response may remain cached at some recursive resolvers after the authoritative record is correct; verify reachability before invoking ACME instead of repeatedly requesting certificates.

For the first installation, clone the public repository into a new dedicated directory. Do not clone into `/opt/cartunez-pos`, `/opt/safar-crm`, or another application's directory. If `/opt/cartunez-pos-source` already exists, review it and use the upgrade procedure below; the following command deliberately refuses to overwrite it.

```bash
test ! -e /opt/cartunez-pos-source && \
  git clone --branch main --single-branch https://github.com/alpesh15gb/Cartunez-POS.git /opt/cartunez-pos-source
SOURCE=/opt/cartunez-pos-source
BIN="$SOURCE/deploy/cartunez/bin"
bash "$BIN/preflight.sh" pos.cartunez.in 18400
getent ahostsv4 pos.cartunez.in
```

Confirm the resolved IPv4 is the intended VPS, port 18400 is still unused, and the dedicated application paths are absent or empty. The preflight prints only Nginx names/listens/include/certificate paths and selected container metadata; it does not dump container environment variables or full Nginx configuration. It does not install packages or change services.

## 2. Create private settings

Use your real owner email, an organization code and initial branch code. Codes are stable identifiers: changing a business name later does not require changing a code. Currency, business details, addresses, tax settings, receipt settings, users and operational policies can be configured in the application. The optional initial business/branch names default to neutral `New business` / `Main branch`.

```bash
python3 "$BIN/configure.py" \
  --owner-email 'YOUR_OWNER_EMAIL' \
  --organization-code 'YOUR_ORGANIZATION_CODE' \
  --branch-code 'YOUR_BRANCH_CODE' \
  --currency INR
```

Replace the three uppercase placeholders before running. The currency is an ISO 4217 code; choose the one used by this business. Optional flags include `--business-name`, `--branch-name`, `--owner-name`, `--domain` and `--api-port`. The default infrastructure domain is `pos.cartunez.in`; no retailer identity or catalog is hardcoded into the application.

This command generates independent database, JWT, and initial owner secrets on the VPS. It refuses to overwrite existing configuration and does not print credentials. Read only your private `owner-login.txt` locally when needed; do not paste it into chat. The configuration is not sourced as shell code. Public `installation.json` contains only the HTTPS API URL and organization/branch identifiers.

## 3. Stage and activate the first release

```bash
bash "$BIN/git-release.sh" prepare "$SOURCE" && \
  RELEASE="$(cat /opt/cartunez-pos/state/git-staged-release)" && \
  bash "/opt/cartunez-pos/releases/$RELEASE/bin/activate.sh" "$RELEASE" && \
  bash /opt/cartunez-pos/current/bin/status.sh
```

The Git wrapper checks that the clone is root-owned, clean, on `main`, uses exactly the expected GitHub origin, and matches `origin/main`. It refuses local edits, untracked files, unexpected remotes, detached checkouts, or local-only commits; it never resets, stashes or cleans them. It builds the frontend in Docker, stages a uniquely tagged API image, records full source commit plus exact API/PostgreSQL image IDs, writes public connection defaults, and makes the release files read-only. Release identifiers contain the package version, UTC build time and short commit SHA. Staging does not change a running service.

Activation uses only the `cartunezpos` Compose project and waits for database/API health. The first activation starts an empty business and creates the configured owner. Demo seeding is disabled and rejected by the production API. Keep business settings in the application and secrets in `/etc/cartunez-pos/config.json` so Git updates remain clean.

The release image IDs refer to images retained on this VPS. Do not run global Docker prune commands while these releases are retained. A later PostgreSQL major-version change needs a separate migration plan; this workflow uses PostgreSQL 17.

## 4. Add the dedicated HTTP vhost and certificate

```bash
bash /opt/cartunez-pos/current/bin/nginx.sh render-http
bash /opt/cartunez-pos/current/bin/nginx.sh install-http /etc/nginx/sites-enabled
```

The installer verifies that the directory is already included, rejects a duplicate domain in another vhost, and refuses to replace an unrelated file or symlink. It tests the complete host configuration before reloading. A failing candidate restores the previous dedicated vhost without reloading Nginx. HTTP serves only the ACME challenge; the rest returns setup-in-progress until HTTPS is installed.

Verify a harmless challenge file through public DNS before requesting a certificate:

```bash
install -d -m 755 /var/www/cartunez-pos-acme/.well-known/acme-challenge
printf 'cartunez-acme-ready\n' > /var/www/cartunez-pos-acme/.well-known/acme-challenge/probe
chmod 644 /var/www/cartunez-pos-acme/.well-known/acme-challenge/probe
curl --fail --retry 5 --retry-all-errors http://pos.cartunez.in/.well-known/acme-challenge/probe
```

The response must be `cartunez-acme-ready`. Also check it from outside the VPS; if it does not match, resolve DNS/firewall/proxy routing before invoking ACME.

If Certbot is not installed, install the Ubuntu package without replacing existing Nginx or Docker packages:

```bash
command -v certbot || { apt-get update && apt-get install -y certbot; }
bash /opt/cartunez-pos/current/bin/nginx.sh issue-certificate 'YOUR_CERTIFICATE_ADMIN_EMAIL'
bash /opt/cartunez-pos/current/bin/nginx.sh install-tls /etc/nginx/sites-enabled
curl --fail --retry 5 --retry-all-errors https://pos.cartunez.in/api/v1/health
curl --fail --retry 5 --retry-all-errors https://pos.cartunez.in/installation.json
```

Replace the certificate email. Certbot uses `certonly --webroot` and does not edit Nginx or stop the shared web server. TLS installation requires a matching certificate that is valid for more than 24 hours. It adds a dedicated HTTPS server and redirects only this domain's HTTP requests. It does not add a default server, rewrite another site's redirects, change existing HTTP/2 configuration, or alter the VPS firewall.

After reload, allow a moment for the new worker configuration. Check the web page in a normal browser, verify the trusted certificate chain, and confirm an unrelated existing site still responds. If Cloudflare proxying is enabled later, review its TLS/real-IP configuration separately; these scripts deliberately trust only the single local Nginx hop and overwrite incoming forwarded headers.

## 5. Complete first login and protect bootstrap credentials

Open `https://pos.cartunez.in` and use the private owner login. The browser should obtain this installation's API, organization and branch defaults automatically. Configure the business in Settings before transactions: business identity and address, tax registration, currency, tax rates/mode, receipt numbering/footer, branch details, users and permissions. Add real suppliers, bins, products, opening stock and licensed compatibility data; no demo products are loaded.

Change the initial owner password and verify a fresh login. Then remove the bootstrap secret from the host configuration and API container:

```bash
bash /opt/cartunez-pos/current/bin/finish-bootstrap.sh --owner-login-verified
```

This preserves the owner account and database, removes the initial password file, and recreates only the API container with an empty bootstrap password. Installed Windows/Android clients should use `https://pos.cartunez.in/api/v1` and the same organization/branch identifiers. Enroll counters online before allowing offline transactions.

## 6. Backups, restore drill and scheduled operations

```bash
BACKUP=$(bash /opt/cartunez-pos/current/bin/backup.sh)
bash /opt/cartunez-pos/current/bin/drill.sh "$BACKUP" 18401
bash /opt/cartunez-pos/current/bin/install-timers.sh
systemctl start cartunezpos-backup.service
systemctl list-timers cartunezpos-backup.timer
systemctl show cartunezpos-backup.service -p Result -p ExecMainStatus
certbot renew --cert-name pos.cartunez.in --dry-run
```

The drill requires an unused loopback port; choose another if 18401 is occupied. It checks the dump checksum, restores into a uniquely named disposable project/volume, starts the matching API image, checks health and record counts, then removes only the drill resources. The live database remains online. Dumps use PostgreSQL's transaction-consistent `pg_dump -Fc`, have mode 0600, and include SHA-256 and matching-release metadata. Keep all three files together.

The backup check should report `Result=success` and `ExecMainStatus=0`. This is a one-shot service: being inactive after successful completion is normal. The dedicated systemd timer runs nightly at 03:15 in the VPS timezone with up to 20 minutes of randomized delay. Backup retention keeps at least seven backups and all backups from the last fourteen days. The renewal deploy hook reloads Nginx only after this domain's certificate was successfully renewed. Verify the existing Certbot renewal timer is enabled (`systemctl list-timers '*certbot*'`); if the Ubuntu package timer exists but is disabled, enable `certbot.timer`.

Create a complete private recovery bundle using [COLD-RECOVERY.md](COLD-RECOVERY.md), then include that bundle and subsequent matching dump/checksum/metadata sets in the operator's selected existing VPS/offsite backup workflow. The bundle contains exact Docker image bytes, the full immutable release and private configuration so a clean replacement host does not depend on cached images or the public Git repository. Treat it as secret and store it in an access-controlled encrypted destination. These scripts do not replace or reconfigure another backup product. Offsite storage and alerts require the operator's destination/credentials and are not silently configured. Monitor failed backup units, disk space, certificate expiry and API health. Host Nginx logs under `/var/log/nginx/*.log` use Ubuntu's existing Nginx logrotate policy; verify that policy covers the two new log files.

## Upgrades and rollback

Build the next release while the current one continues serving. Run the updater from the immutable current release; it validates the dedicated clone, executes `git pull --ff-only origin main`, builds the frontend and API, and stages the resulting commit. It does not run `git pull` in the shell's current directory and does not change other checkouts.

```bash
bash /opt/cartunez-pos/current/bin/git-release.sh update /opt/cartunez-pos-source
```

Review the printed release ID and complete any application-specific checks. If Git reports local changes or divergent history, investigate them; do not use reset/clean/force-pull to bypass the guard. Pause counters and reconcile pending outboxes before switching the running release:

```bash
RELEASE="$(cat /opt/cartunez-pos/state/git-staged-release)"
bash "/opt/cartunez-pos/releases/$RELEASE/bin/activate.sh" "$RELEASE" && \
  bash /opt/cartunez-pos/current/bin/status.sh && \
  curl --fail --retry 5 --retry-all-errors https://pos.cartunez.in/api/v1/health
```

Only activate the ID printed by a successful update. Activation stops this API, makes a backup of the previous release's database, records its location in `/opt/cartunez-pos/state/pre-upgrade`, starts the candidate and waits for health, then atomically switches the static web symlink. A short maintenance response protects the domain during changes. Other Compose projects and Nginx vhosts are not restarted. Web/API updates do not reinstall Nginx, alter the vhost, remove volumes, or globally prune Docker resources.

If the candidate fails, its API is stopped and the old web pointer is retained; the maintenance response remains active. Database migrations may already have run, so the script deliberately does not start an older image against an unknown newer schema. Inspect this project's logs without dumping secrets, then restore the recorded matching backup:

```bash
# Use the exact old release and backup path recorded in state/pre-upgrade.
bash /opt/cartunez-pos/current/bin/rollback.sh OLD_RELEASE /var/lib/cartunez-pos/backups/MATCHING.dump --restore-database
```

Rollback verifies the backup checksum/release match, stops the API, preserves the current database as an emergency dump, restores the matching prior database in one transaction, starts the matching image, waits for health and switches the web pointer. It stays in maintenance on failure. Post-backup sales and counter outboxes must be reconciled before reopening; restoring a database is not a way to merge later financial records. The emergency dump is marked `unknown-before-rollback` so it cannot be mistaken for a known schema-compatible release.

Keep at least the previous release and its Docker images. Do not use `docker compose down --volumes` on `cartunezpos`. The only automated volume deletion in these scripts is for a newly created, explicitly named disposable restore-drill project.

## Appendix: deployment archive instead of Git

The archive workflow remains available. Upload the delivered deployment archive and checksum file to a new directory such as `/root/cartunez-upload`, verify its checksum and extract it there. Set `SOURCE` to the extracted application root. Configure private settings as above on a first installation. An archive containing the tested `apps/web/out` needs no frontend rebuild. A source-only archive can build its frontend with the same Docker helper:

```bash
SOURCE=/root/cartunez-upload/motorline
# Run this only when using a source-only archive without apps/web/out:
bash "$SOURCE/deploy/cartunez/bin/build-web.sh" "$SOURCE"

RELEASE=1.1.0-archive-1
bash "$SOURCE/deploy/cartunez/bin/stage.sh" "$SOURCE" "$RELEASE" && \
  bash "/opt/cartunez-pos/releases/$RELEASE/bin/activate.sh" "$RELEASE"
```

Use a new immutable release ID for every archive release. The dedicated Nginx, backups, rollback and private-setting procedures are identical. An archive is not a Git clone; the guarded Git updater intentionally refuses to operate on it. To move an archive installation to Git, clone the repository into `/opt/cartunez-pos-source`, use `git-release.sh prepare` from that clone to stage its first Git release, and activate after the normal backup/health checks.

## Basis and verification

Project scoping follows [Docker Compose project naming](https://docs.docker.com/compose/how-tos/project-name/). Container memory, CPU and log settings use the [Compose service specification](https://docs.docker.com/reference/compose-file/services/). The dedicated hostname configuration follows [Nginx request selection](https://nginx.org/en/docs/http/request_processing.html). Certificate provisioning uses Certbot's [webroot and renewal deploy-hook workflow](https://eff-certbot.readthedocs.io/en/stable/using.html). The updater uses Git's documented [fast-forward-only pull behavior](https://git-scm.com/docs/git-pull) and [porcelain status output](https://git-scm.com/docs/git-status).

Local shared-host checks and their limits are recorded in `docs/test-results/cartunez-deployment.json`. A local test certificate does not establish that public DNS, Let's Encrypt issuance, offsite backups, the retailer's real devices, or the public VPS are live. Complete the checks above on the actual VPS and record their outputs without secrets.
