# Cartunez POS

Automotive spare-parts POS with browser, Windows, and Android clients. Release 1.1.0 includes configurable business settings and deployment for `pos.cartunez.in` on a shared Ubuntu VPS with system Nginx and Docker. The source packages retain their internal Motorline names; shop identity is configured in Settings.

Follow [the Git deployment guide](docs/CARTUNEZ-DEPLOYMENT.md) for first installation, updates, HTTPS, backups, and rollback. Builds run in Docker; host Node.js is unnecessary. The default deployment uses a dedicated source checkout at `/opt/cartunez-pos-source`, releases at `/opt/cartunez-pos`, Docker project `cartunezpos`, and API bound to `127.0.0.1:18400`. It adds only the POS Nginx site after validating the complete Nginx configuration.

No application passwords, database files, or signing keys belong in this repository. The server setup generates credentials locally under `/etc/cartunez-pos`. Enter business identity, branch, tax, tender, and receipt preferences in the application Settings. Do not use the demonstration credentials below for production.

The current release evidence and remaining shop-side checks are recorded in [CARTUNEZ-RELEASE.md](docs/CARTUNEZ-RELEASE.md). The earlier release report remains available for the 1.0 baseline.

Motorline brings the automotive counter layout from the original prototype into a shared Next.js application, a versioned TypeScript API, a Windows Electron application, and an Android Capacitor application. PostgreSQL is authoritative for each installation. IndexedDB stores the browser workspace. Both installed clients bundle the web assets and store their local workspace and pending sales in SQLite.

## Start a demonstration

Install Node.js 22 or later and run `npm ci` from this folder. In PowerShell, start the development API with `$env:SEED_DEMO='true'; $env:PGLITE_PATH='./demo-data'; npm run dev:api`. In a second terminal, run `npm run dev --workspace @motorline/web` and open `http://localhost:3000`.

The development command uses embedded PGlite. The deployment described below uses PostgreSQL in Docker and has been exercised against real PostgreSQL 17.12.

Use server API `http://127.0.0.1:4000/api/v1`, organization `demo`, and branch `pune`. The sample owner email is `owner@motorline.local` and its password is `MotorlineDemo123!`. Sample roles also use `manager@motorline.local`, `cashier@motorline.local`, and `inventory@motorline.local` with the same demonstration password. Demo data contains fictional fitment rules and sample prices. Production bootstrap creates an owner from your environment settings.

Open a shift before billing. Choose a vehicle, scan a barcode or search a part, confirm the physical bin picked, and record payment. F2 focuses search and F6 opens checkout. Parked sales reserve stock. Recalled bills retain their items. Issued invoices are immutable and corrections create audit records and credits.

## Deployment and clients

- Follow [DEPLOYMENT.md](docs/DEPLOYMENT.md) for Docker Compose, private PostgreSQL, host Nginx HTTPS, migration, backup, restore, and LAN operation.
- Read [GO-LIVE-INPUTS.md](docs/GO-LIVE-INPUTS.md) for settings entered directly in the application and the operator-run checks remaining on the real VPS and counter hardware.
- Follow [CLIENT-BUILDS.md](docs/CLIENT-BUILDS.md) for the Windows installer and Android APK. Installed clients bundle their workspace UI for offline startup.
- Read [OFFLINE.md](docs/OFFLINE.md) for enrollment, session expiry, invoice ranges, retry policy, and last-unit reconciliation.
- Read [API.md](docs/API.md) and [api-contract.json](docs/api-contract.json) for API endpoints and examples.
- Read [RELEASE-VERIFICATION.md](docs/RELEASE-VERIFICATION.md) and [API-TEST-RESULTS.md](docs/API-TEST-RESULTS.md) for actual tested environments and remaining hardware or deployment verification.

## Build and test

`npm run build:api` compiles the API. `npm run test:api` runs business acceptance tests. `npm run build --workspace @motorline/web` checks TypeScript, exports the browser assets, and creates the PWA asset cache manifest. `npm run typecheck --workspace @motorline/web` checks the web application independently.

`node tests/browser-acceptance.cjs` exercises the web interface against an already running API and static web server. Set `BROWSER_PATH` to a Chromium browser executable when Edge is installed elsewhere. Native scripts under `scripts/` and `tests/` exercise the installed clients, SQLite restart, and the shared business operations. Their environment settings are documented with the client build instructions and release report.

`node tests/browser-conflict.cjs` exercises simultaneous last-unit submissions from two enrolled counters, then resolves the conflict through the manager interface and verifies the audit and idempotent replay. `node tests/cashier-approvals.cjs` checks the cashier discount allowance and approved return. These checks create fictional transactions and require the seeded demonstration database.

## Operational scope

The release includes catalog and fitment management, validated fitment CSV import, racks and bins, stock movements, purchase orders and partial receipts, branch transfers, shifts, split tenders, returns and warranty claims, core-charge refunds, approvals, reporting, CSV exports, barcode labels, and receipt printing. Owner and branch permissions are enforced by the API.

Card and UPI transactions require confirmation from the external payment service. This build records the provider reference manually and retains unconfirmed payments as pending. Payment-provider webhooks require the retailer's provider integration. Windows packages are unsigned. The 1.0 Android package is a test artifact; the 1.1 release package uses a separate persistent release signing key. Retailer publisher certificates, production HTTPS trust, licensed catalog data, camera barcode decoding, and physical printers require the checks listed in the release report.

Settings manages business and branch details, staff access, currency before monetary activity, invoice numbering, tax-inclusive/exclusive pricing, tender permissions, offline policy, and receipt text. Receipts and credits retain the original business/customer/currency/tax snapshots. Optional India GST mode supports ordinary domestic tax components with entered GSTIN, state and HSN/SAC. It does not perform GSTIN verification, IRN/e-invoice submission, e-way bills, filing, reverse charge, cess, exports/SEZ, or GST treatment of refundable core deposits. Confirm the business's required scope before using that mode for real invoices.

The visual design and generated, unbranded product thumbnails are carried forward from the original prototype. GoFrugal's public documentation informed the counter, hold, inventory, and return workflows. This is an independent implementation, with no affiliation with GoFrugal. See [the publication review](docs/PUBLICATION-REVIEW.md) for the source and asset checks.
