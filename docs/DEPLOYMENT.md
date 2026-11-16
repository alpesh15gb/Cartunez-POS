# Shop server deployment

Motorline serves a static Next.js application through host Nginx. The TypeScript API and PostgreSQL run in Docker Compose. Counters on the shop LAN use the shop server's HTTPS address. PostgreSQL has no published host port. Its volume persists across container recreation.

## Prerequisites

Use a Linux shop server with Docker Engine, Compose v2, and Nginx installed on the host. Reserve a LAN address and DNS name for the server. Provision a certificate trusted by every Windows and Android counter for that name. A trusted certificate also enables camera scanning and PWA installation in browsers. Keep a backup outside the shop server.

## Configure and build

1. Copy `deploy/.env.example` to `deploy/.env`. Generate independent secrets with `openssl rand -hex 32` and place them in `POSTGRES_PASSWORD` and `JWT_SECRET`. Use URL-safe characters for the database password. Set `CORS_ORIGINS` to your exact HTTPS origin plus `motorline://app,https://localhost` for the installed clients.
2. Set `BOOTSTRAP_OWNER_EMAIL`, a strong `BOOTSTRAP_OWNER_PASSWORD` of at least 16 characters, and the organization and branch IDs. Startup creates this owner only when the organization is absent. Remove the bootstrap password after initial setup. Run `npm ci` in the source root, then `npm run build --workspace @motorline/web`. Copy `apps/web/out/` into `/srv/motorline/web/`.
3. From `deploy`, run `docker compose up -d --build`. Database migrations run when the API starts. Production rejects `SEED_DEMO=true`; keep it false. Run fictional demo fixtures only through the local development workflow. Set the owner/branch names and ISO currency explicitly in the environment file.
4. Copy `deploy/nginx.conf` into the host's Nginx configuration. Replace `pos.shop.local` with the shop hostname. Place the trusted certificate and private key at the configured paths. Keep the private key readable only by the Nginx service administrator.
5. Run `sudo nginx -t`, then `sudo systemctl reload nginx`. Run `bash scripts/verify-deployment.sh https://your-shop-host` from the source root. Check that the API health endpoint, web page, manifest, and PostgreSQL readiness all pass.
6. Point each installed client at `https://your-shop-host/api/v1`. Open the web app from the same shop hostname. Enroll each counter while the API is reachable, select its authorized branch, and synchronize before operating offline.

Docker publishes the API on `127.0.0.1:4000` only. Host Nginx owns ports 80 and 443. PostgreSQL is on the internal Compose network. Restrict inbound shop-server traffic to the shop network as appropriate for the installation.

## Backups and restore

Run `bash scripts/backup.sh /absolute/backup/location/motorline.dump`. The command uses PostgreSQL's consistent custom-format dump and writes a SHA-256 sidecar. Copy both files to the backup destination. This backs up server business records, audit records, and enrollment state. Pending counter transactions remain on their enrolled devices until synchronization.

To restore a clean installation, provision the same schema-compatible release and empty PostgreSQL service, then run `bash scripts/restore.sh /absolute/backup/location/motorline.dump`. The command stops API writes, restores in one transaction, and restarts the API. Verify health and check invoice, stock-ledger, and report totals against the backup's recorded counts before reopening counters. Keep the device databases when reinstalling clients so their outboxes remain available.

## Upgrades

Take and verify a backup first. Build the release, stop the API during deployment, and start the new API image so migrations complete before counters reconnect. Retain the previous web build and image until smoke checks pass. Issued invoices and movement records are retained by migrations. A schema rollback requires restoring the matching database backup.

## Installed clients

The Windows installer bundles the static web app and stores the workspace in `workspace.sqlite` under the application's user-data folder. Electron exposes a narrow storage bridge and disables renderer Node.js access. The database is atomically replaced only after the new SQLite snapshot has been written and flushed. Only one instance of the desktop app may use a profile.

The Android APK bundles the same web assets. Android SQLite stores the scoped workspace and outbox. After initial enrollment, both clients can reopen their installed workspace without fetching the web application.

Use organization and branch scoped workspace keys. Re-enrollment or a branch switch must not reuse another branch's catalog or pending transactions. Keep outstanding outboxes attached to their original device and branch until reconciled.

## Receipt and thermal printing

The browser print view can print to a configured Windows printer or save a PDF. Electron also provides a native print dialog and PDF export through its preload bridge. For 80 mm thermal printers, install the manufacturer's Windows driver, select the matching paper size, disable browser headers/footers, and verify the receipt width against an actual print. Android uses the Android print framework or a configured vendor print service. A Bluetooth or USB printer requires the matching Android print-service application or a future vendor SDK adapter. Physical printer output must be verified on the retailer's printer before rollout.

## Operational checks

Confirm the current server status and last synchronization time at the start of a shift. During an API outage, local stock is a snapshot and offline transactions remain pending until the server accepts them. Managers must review stock conflicts after connectivity returns. Offline tender permissions and enrollment expiry apply on every local checkout. Complete shift reconciliation after pending payments and transactions synchronize.
