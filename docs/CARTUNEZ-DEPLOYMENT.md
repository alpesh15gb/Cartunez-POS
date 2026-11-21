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

Commands below run as root and work independently of the shell's current directory, including when the current directory is `/opt/safar-crm`. The VPS needs Git, Bash, Docker/Compose, host Nginx, Python 3, OpenSSL, curl, util-linux and coreutils. Certbot is needed only for certificate issuance. No host Node.js or Flutter installation is required: the API builds in Docker from the committed lockfile, and the web app is either the Flutter build committed at `apps/flutter/release/web` or the bundle CI published for the same commit (see [Web bundle from CI](#web-bundle-from-ci)), copied into each release unchanged. Runtime data and private configuration remain outside Git.

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

The Git wrapper checks that the clone is root-owned, clean, on `main`, uses exactly the expected GitHub origin, and matches `origin/main`. It refuses local edits, untracked files, unexpected remotes, detached checkouts, or local-only commits; it never resets, stashes or cleans them. It checks the Flutter web build (committed, or fetched from CI for the same commit), stages a uniquely tagged API image, records full source commit plus exact API/PostgreSQL image IDs, writes public connection defaults, and makes the release files read-only. Release identifiers contain the package version, UTC build time and short commit SHA. Staging does not change a running service.

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

Build the next release while the current one continues serving. Run the updater from the immutable current release; it validates the dedicated clone, executes `git pull --ff-only origin main`, checks the web build, builds the API, and stages the resulting commit. It does not run `git pull` in the shell's current directory and does not change other checkouts.

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

## Fresh launch: clear test data

Use this once, before opening for real, to remove everything entered while testing. Run both resets, **POS first, then the shop**, from an interactive root terminal on the VPS. Pause every counter first (close the app on each till; finish or send any offline sales). The POS reset needs a release that includes `apps/api/dist/reset-cli.js`; activate the latest release first if it stops with a message about that.

```bash
# 1. POS. Takes a backup, shows the counts, asks for CLEAR POS.
bash /opt/cartunez-pos/current/bin/reset-data.sh
# 2. Website. Takes a backup, shows the counts, asks for CLEAR SHOP.
bash /opt/cartunez-shop-source/deploy/magento/7-reset-shop.sh
```

**POS (`reset-data.sh`).** It checks the API and database are healthy, then takes a full `pg_dump` with `bin/backup.sh`. If the backup fails, it stops. The backup is copied to `/var/lib/cartunez-pos/backups/before-reset-cartunezpos-<time>.dump`, with `.sha256` and `.meta` files, under a name the nightly clean-up never removes. It prints what will be deleted and what will be kept, then asks whether to keep the business details (default yes), then asks you to type `CLEAR POS`. It stops the API and runs the reset in one database transaction (`apps/api/src/reset.ts`, in a one-off container from the same image). Then it starts the API again and waits for health. If the reset fails, the transaction rolls back, nothing is deleted, and the API is started again.

- Kept: the organization and branch records, the owner account(s) (all other staff accounts are removed; add them again in Settings), bins/locations, customers and suppliers, and the Magento connection (store address, token, online branch). Customers and suppliers keep their details, but their opening balances go to 0 and their vehicle links are cleared.
- Settings go back to a new shop's defaults. The invoice, credit note, estimate and job numbers restart at 1. The tax setting becomes **Not GST registered**. Module switches are kept. If you keep the business details (the default), the shop name, legal name, address, phone, email, state, UPI ID, receipt footer, label design and number prefixes stay. The GSTIN is cleared. If you choose not to keep them, those go back to blank defaults.
- Deleted: parts, stock and the stock ledger, serials, invoices, returns and credit notes, holds, shifts, cash movements, approvals, purchase orders, receipts, bills and returns, party payments, attachments and product images, job cards, estimates, customer vehicles, the vehicle list, online listings, orders, jobs, queues and cursors, the Magento category cache, devices and PIN keys, idempotency records, and the audit trail. One new audit entry records the reset.
- Afterwards: sign in again on every counter and enroll devices again. Because the online listings and category cache are gone, the next publish creates new products and categories on the website. That is why the shop reset comes next.

**Shop (`7-reset-shop.sh`).** It checks that the containers are running and that every store uses root category 2. Then it runs `deploy/magento/backup.sh` (database, `pub/media`, `app/etc`) and keeps copies named `/var/backups/cartunez-shop/before-reset-db-<time>.sql.gz.keep` and `before-reset-files-<time>.tar.gz.keep`, which the 14-day clean-up skips. It prints the counts and asks you to type `CLEAR SHOP`. It then turns maintenance on, pauses cron and deletes everything in one database transaction, respecting foreign keys:

- All products, with their URL rewrites, MSI source items and reservations, stock rows and media gallery.
- All orders, invoices, shipments, credit memos and carts, with their grids and report tables.
- All customers and their addresses, wishlists and newsletter subscriptions.
- Every category except the catalog root (1) and the store root (2). This removes Brands, Sale and the POS-made categories.

After the transaction, it resets the order, invoice, shipment and credit memo number sequences. It deletes the product photo files except the placeholder, reindexes everything, flushes the cache, starts cron and turns maintenance off. CMS pages and blocks, the theme, configuration, admin users, the POS integration token, and the tax, payment and shipping settings are kept. If any step fails, the shop stays in maintenance and the script prints how to reopen it. A failure in the database step deletes nothing.

Then publish the parts again from the POS (Online store).

**Restore the POS** from its backup (this stops the API, saves the current database as an emergency dump and restores the old one in one transaction):

```bash
bash /opt/cartunez-pos/current/bin/rollback.sh "$(basename "$(readlink -f /opt/cartunez-pos/current)")" \
  /var/lib/cartunez-pos/backups/before-reset-cartunezpos-TIME.dump --restore-database
```

**Restore the shop** from its backup:

```bash
cd /opt/cartunez-shop
docker compose -p cartunezshop exec -T php php bin/magento maintenance:enable
docker compose -p cartunezshop stop cron
gunzip -c /var/backups/cartunez-shop/before-reset-db-TIME.sql.gz.keep | \
  docker compose -p cartunezshop exec -T db sh -c 'mariadb -umagento -p"$(cat /run/secrets/db_password)" magento'
docker compose -p cartunezshop exec -T php sh -c 'rm -rf pub/media/catalog/product/*'
docker compose -p cartunezshop exec -T php tar -C /var/www/magento -xzf - pub/media < /var/backups/cartunez-shop/before-reset-files-TIME.tar.gz.keep
docker compose -p cartunezshop exec -T php php -d memory_limit=4G bin/magento indexer:reindex
docker compose -p cartunezshop exec -T php php bin/magento cache:flush
docker compose -p cartunezshop start cron
docker compose -p cartunezshop exec -T php php bin/magento maintenance:disable
```

Restore both or neither. A restored shop with a reset POS (or the reverse) leaves the POS's remembered Magento ids out of step with the shop.

## Web bundle from CI

The VPS has no Flutter SDK. The web app it serves comes from one of two places, chosen by the optional `WEB_BUNDLE` key in `/etc/cartunez-pos/config.json`:

| `WEB_BUNDLE` | Web build staged by `git-release.sh` |
| --- | --- |
| absent or `committed` | `apps/flutter/release/web` committed in the checkout (the original behaviour) |
| `auto` | The CI bundle for the exact commit being released; if none is usable, the committed copy with a warning |
| `ci` | The CI bundle for the exact commit; staging stops with an error if it is missing. No fallback |

On every push to `main`, the `Build and test` workflow runs the API tests, the encoding check, `flutter analyze` and `flutter test`, then builds the web app with `apps/flutter/tool/build_web.sh` (the same flags as `build_web.ps1`: `--no-web-resources-cdn --no-source-maps`, scanner files from `web/scanner`). If every job passes it publishes the GitHub Release `web-<full commit SHA>` (a pre-release, never marked latest) with `cartunez-web.tar.gz` and `cartunez-web.tar.gz.sha256`. The archive holds `web/` and `build-info.json` naming the commit. Releases are never overwritten. The workflow keeps the newest 60 and deletes older `web-*` releases and their tags. Pull-request runs build the bundle as a 14-day workflow artifact only.

`deploy/cartunez/bin/fetch-web.sh` downloads the release for the commit `git-release.sh` is staging. It checks the SHA-256 sidecar, GitHub's recorded asset digest, that the archive holds only regular files under `web/`, and that `build-info.json` names the same commit. `build-web.sh` then runs its usual completeness check, and the release records where its web build came from in `releases/<release>/web-source`, which `status.sh` prints. If CI has not published the bundle yet (a run takes about 10 minutes after the push), staging stops before anything changes. `update` has already pulled, so wait for the workflow to finish, then run `bash /opt/cartunez-pos/current/bin/git-release.sh prepare /opt/cartunez-pos-source`.

**Private repository.** A public repository needs no token. If the repository is made private, the VPS needs read access for both `git pull` and the release download. Create a fine-grained personal access token limited to this one repository with only **Contents: Read-only**, and give it an expiry you will track. Store it on the VPS, root-only:

```bash
install -m 600 -o root -g root /dev/null /etc/cartunez-pos/github-token
nano /etc/cartunez-pos/github-token   # paste the token on one line, save
```

`fetch-web.sh` refuses the file unless it is root-owned with mode 0600, and sends it only as a request header to `api.github.com`. Curl drops it when GitHub redirects the download to its storage host. It never appears on a command line. For `git pull` of a private repository, add a credential store outside the checkout's working tree, so the guarded origin URL stays unchanged:

```bash
install -m 600 -o root -g root /dev/null /etc/cartunez-pos/git-credentials
printf 'https://x-access-token:%s@github.com\n' "$(tr -d '[:space:]' < /etc/cartunez-pos/github-token)" > /etc/cartunez-pos/git-credentials
git -C /opt/cartunez-pos-source config credential.helper 'store --file=/etc/cartunez-pos/git-credentials'
```

Replace both files when the token is rotated. Keep them out of recovery bundles that leave the host. The CI side needs no secret: it publishes with the workflow's own `GITHUB_TOKEN`.

### Cutover from the committed web build

Production keeps working on the committed build until you finish step 4. Each step can be reversed by setting `WEB_BUNDLE` back to `committed`, up to step 6.

1. Merge this change to `main`. Wait for `Build and test` to pass and check that the Releases page shows `web-<that commit SHA>`.
2. Do a normal update and activation as in **Upgrades and rollback**, with `WEB_BUNDLE` still absent. This puts `fetch-web.sh` and the new `git-release.sh` into the current release. `status.sh` should print `Web build: committed`.
3. Private repository only: create `/etc/cartunez-pos/github-token` and the Git credential store as above.
4. Check the download without staging anything. Compare its file list with the committed copy:
   ```bash
   SOURCE=/opt/cartunez-pos-source
   bash "$SOURCE/deploy/cartunez/bin/fetch-web.sh" "$(git -C "$SOURCE" rev-parse HEAD)" /root/web-check && \
     diff <(cd /root/web-check && find . -type f | sort) <(cd "$SOURCE/apps/flutter/release/web" && find . -type f | sort) && \
     echo 'Same files'
   rm -rf /root/web-check /root/web-check.sha256
   ```
   File contents can differ because the build machine differs. The file list should match.
5. Set `WEB_BUNDLE` to `auto`, keeping the file root-owned with mode 0600:
   ```bash
   python3 - auto <<'PY'
   import json, os, pathlib, sys
   p = pathlib.Path('/etc/cartunez-pos/config.json'); c = json.loads(p.read_text()); c['WEB_BUNDLE'] = sys.argv[1]
   t = p.with_name('.config.json.tmp'); fd = os.open(t, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
   with os.fdopen(fd, 'w') as f: json.dump(c, f, indent=2); f.write('\n')
   os.replace(t, p)
   PY
   ```
   On the next update, check `cat /opt/cartunez-pos/releases/$RELEASE/web-source` before activating. It must start with `ci web-`. After activation, open the site, sign in, make a test bill and try camera scanning in a browser.
6. Run the same command with `ci` in place of `auto`. From now on a missing CI bundle stops staging instead of falling back.
7. Stop committing the build. On the developer PC, in a commit on `main`:
   ```bash
   git rm -r --cached apps/flutter/release/web
   ```
   In `.gitignore`, delete the two lines `# The committed Flutter web build that VPS releases copy as the site.` and `!apps/flutter/release/`, so `release/` is ignored again. Commit and push. Wait for CI, then update the VPS as usual. `git pull` removes the old copy from the checkout. Releases already staged keep their own web copy, so `rollback.sh` is unaffected.

After step 7, `WEB_BUNDLE=committed` no longer works, because no committed copy exists. To recover from a missing or bad CI bundle, re-run the workflow on `main` from the Actions tab (`workflow_dispatch` also publishes). You can also roll back to a retained release. The repository history is not rewritten, so the old bundles stay in Git history; shrinking the clone would need a separate, coordinated history rewrite.

## Appendix: deployment archive instead of Git

The archive workflow remains available. Upload the delivered deployment archive and checksum file to a new directory such as `/root/cartunez-upload`, verify its checksum and extract it there. Set `SOURCE` to the extracted application root. Configure private settings as above on a first installation. The web app is the committed Flutter build in `apps/flutter/release/web`; it needs no build on the server. `build-web.sh` only checks that it is complete:

```bash
SOURCE=/root/cartunez-upload/motorline
bash "$SOURCE/deploy/cartunez/bin/build-web.sh" "$SOURCE"

RELEASE=1.1.0-archive-1
bash "$SOURCE/deploy/cartunez/bin/stage.sh" "$SOURCE" "$RELEASE" && \
  bash "/opt/cartunez-pos/releases/$RELEASE/bin/activate.sh" "$RELEASE"
```

Use a new immutable release ID for every archive release. The dedicated Nginx, backups, rollback and private-setting procedures are identical. An archive is not a Git clone; the guarded Git updater intentionally refuses to operate on it. To move an archive installation to Git, clone the repository into `/opt/cartunez-pos-source`, use `git-release.sh prepare` from that clone to stage its first Git release, and activate after the normal backup/health checks.

## Basis and verification

Project scoping follows [Docker Compose project naming](https://docs.docker.com/compose/how-tos/project-name/). Container memory, CPU and log settings use the [Compose service specification](https://docs.docker.com/reference/compose-file/services/). The dedicated hostname configuration follows [Nginx request selection](https://nginx.org/en/docs/http/request_processing.html). Certificate provisioning uses Certbot's [webroot and renewal deploy-hook workflow](https://eff-certbot.readthedocs.io/en/stable/using.html). The updater uses Git's documented [fast-forward-only pull behavior](https://git-scm.com/docs/git-pull) and [porcelain status output](https://git-scm.com/docs/git-status).

Local shared-host checks and their limits are recorded in `docs/test-results/cartunez-deployment.json`. A local test certificate does not establish that public DNS, Let's Encrypt issuance, offsite backups, the retailer's real devices, or the public VPS are live. Complete the checks above on the actual VPS and record their outputs without secrets.
