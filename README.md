# Cartunez POS

Automotive spare-parts POS. One Flutter app (`apps/flutter`) runs in the browser at
`pos.cartunez.in`, as a Windows program and as an Android app. All of them use the versioned
TypeScript API (`apps/api`) with PostgreSQL as the single source of truth.

Follow [the Git deployment guide](docs/CARTUNEZ-DEPLOYMENT.md) for first installation, updates, HTTPS, backups, and rollback. The API builds in Docker; the web app is the Flutter build committed at `apps/flutter/release/web`, so the VPS needs neither Node.js nor Flutter. The default deployment uses a dedicated source checkout at `/opt/cartunez-pos-source`, releases at `/opt/cartunez-pos`, Docker project `cartunezpos`, and API bound to `127.0.0.1:18400`.

No application passwords, database files, or signing keys belong in this repository. The server setup generates credentials locally under `/etc/cartunez-pos`. Enter business identity, branch, tax, tender, and receipt preferences in the application Settings. Do not use the demonstration credentials below for production.

The earlier Next.js web app and its Electron and Capacitor wrappers were retired in November 2026 in favour of the Flutter app. The API and internal package names still use the original `motorline` prefix.

## Start a demonstration

Install Node.js 22 or later and run `npm ci` from this folder. In PowerShell, start the development API with `$env:SEED_DEMO='true'; $env:PORT='4100'; $env:PGLITE_PATH='./demo-data'; npm run dev:api`. Then either run the Flutter app (`cd apps/flutter; flutter run -d windows`) or build the web app and serve it with the API on one address: `powershell -File apps/flutter/tool/build_web.ps1`, then `python apps/flutter/tool/serve_web.py 3300 http://127.0.0.1:4100` and open `http://localhost:3300`.

The development command uses embedded PGlite. The deployment uses PostgreSQL in Docker.

Use server API `http://127.0.0.1:4100/api/v1`, organization `demo`, and branch `pune`. The sample owner email is `owner@motorline.local` and its password is `MotorlineDemo123!`. Sample roles also use `manager@motorline.local`, `cashier@motorline.local`, and `inventory@motorline.local` with the same demonstration password. Demo data contains fictional fitment rules and sample prices. Production bootstrap creates an owner from your environment settings.

Open a shift before billing. Scan a barcode or search a part, add it to the sale and take payment. F2 focuses search and F6 opens checkout. Held sales keep their items. Issued invoices are immutable; corrections create audit records and credit notes.

## Deployment and clients

- Follow [CARTUNEZ-DEPLOYMENT.md](docs/CARTUNEZ-DEPLOYMENT.md) for the VPS, and [DEPLOYMENT.md](docs/DEPLOYMENT.md) for a generic Docker Compose installation.
- Read [GO-LIVE-INPUTS.md](docs/GO-LIVE-INPUTS.md) for settings entered directly in the application.
- Follow [apps/flutter/README.md](apps/flutter/README.md) for the web build, the Windows installer and the Android APK.
- Read [MAGENTO.md](docs/MAGENTO.md) to connect a Magento 2 store and publish parts online.
- Read [OFFLINE.md](docs/OFFLINE.md) for how sales are kept when the server is unreachable.
- Read [API.md](docs/API.md) and [api-contract.json](docs/api-contract.json) for API endpoints and examples.

## Build and test

`npm run build:api` compiles the API and `npm run test:api` runs the business acceptance tests. In `apps/flutter`, `flutter test` runs the billing and barcode tests, and `flutter test visual --update-goldens` renders every screen against a demo API on port 4100.

## Operational scope

The release includes catalog and fitment management, racks and bins, stock movements, purchase orders and partial receipts, branch transfers, shifts, split tenders, returns and warranty claims, core-charge refunds, approvals, reporting, CSV exports, barcode labels, and receipt printing. Owner and branch permissions are enforced by the API.

Card and UPI transactions require confirmation from the external payment service. This build records the provider reference manually and retains unconfirmed payments as pending. Payment-provider webhooks require the retailer's provider integration. Windows packages are unsigned. The 1.0 Android package is a test artifact; the 1.1 release package uses a separate persistent release signing key. Retailer publisher certificates, production HTTPS trust, licensed catalog data, camera barcode decoding, and physical printers require the checks listed in the release report.

Settings manages business and branch details, staff access, currency before monetary activity, invoice numbering, tax-inclusive/exclusive pricing, tender permissions, offline policy, and receipt text. Receipts and credits retain the original business/customer/currency/tax snapshots. Optional India GST mode supports ordinary domestic tax components with entered GSTIN, state and HSN/SAC. It does not perform GSTIN verification, IRN/e-invoice submission, e-way bills, filing, reverse charge, cess, exports/SEZ, or GST treatment of refundable core deposits. Confirm the business's required scope before using that mode for real invoices.

The visual design and generated, unbranded product thumbnails are carried forward from the original prototype. GoFrugal's public documentation informed the counter, hold, inventory, and return workflows. This is an independent implementation, with no affiliation with GoFrugal. See [the publication review](docs/PUBLICATION-REVIEW.md) for the source and asset checks.
