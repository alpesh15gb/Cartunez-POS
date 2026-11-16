# Cartunez POS 1.1.0 deployment readiness

The 1.1.0 source, browser export, Windows package and Android release package are prepared for the operator-run deployment at `pos.cartunez.in`. Local verification is complete for the checks listed below. Public VPS installation, certificate issuance and acceptance on the shop's actual hardware remain operator-run steps; this report does not claim the public site is already live.

## Changes in this release

- Business identity, addresses, tax registration, branch details, tax mode, invoice numbering, tenders, staff access and receipt footer are configurable through Settings. Currency can be selected before monetary records exist; changing accounting currency afterward is rejected to avoid mixing ledger currencies.
- Browser connection defaults come from the deployment's public `installation.json`; installed clients offer an editable HTTPS server address and retain the last connection. Production creates an empty organization and rejects demo seeding and unsafe default secrets.
- Issued invoices and credits retain their original business, customer, branch, currency and tax information. Tax-inclusive pricing uses exact integer arithmetic, and confirmed card/UPI entries require an external payment reference. Unconfirmed payments remain pending.
- Owner access changes revoke existing sessions. Financial ledgers are protected against direct updates/deletion. Releasing a parked sale removes its stock reservation correctly.
- A bounded 60-second pre-enrollment clock tolerance handles small counter/server clock differences without extending the offline authorization expiry. Counter and server clocks still need to be synchronized.
- Dedicated deployment scripts isolate the Docker project, database, volume, loopback port, Nginx vhost and backup units from other applications. They provide immutable releases, checksummed backups, a disposable restore drill and a matching-database rollback.

## Executed verification

| Check | Evidence |
| --- | --- |
| API build, business regression and production hardening suites on PGlite and real PostgreSQL 17 | `API-TEST-RESULTS.md`, `test-results/api.txt`, `test-results/cartunez-deployment.json` |
| Fresh production installation with no demo data, business/branch setup, purchasing and stock, inclusive/exclusive sales, pending/manual UPI confirmation, immutable receipts, owner password change and restart | `test-results/fresh-production.json` |
| Optional ordinary domestic GST setup through the actual browser UI, same-state CGST/SGST and inter-state IGST, historical receipt reprints | `test-results/fresh-gst-ui.json` |
| Browser counter, offline reopening, cashier approvals and two-counter last-unit manager reconciliation | `test-results/browser.txt`, `test-results/cashier-approvals.txt`, `test-results/browser-conflict.json` |
| Windows 1.1 extracted package, SQLite persistence, immediate offline sale/restart/replay, manager reconciliation and retail operations | `test-results/windows-1.1-package.json`, `test-results/windows-core-1.1.json`, `test-results/windows-reconciliation-1.1.json`, `test-results/windows-operations-1.1.txt` |
| Android release signature, version, 40 bundled asset matches, clean emulator install, editable HTTPS endpoint, actual cleartext request rejection, SQLite isolation/3 MiB storage/restart | `test-results/android-release-package.json`, `test-results/android-release-smoke.json`, `test-results/android-release-native.json` |
| Isolated shared-host deployment, HTTPS with a trusted test certificate, backup/restore, upgrade/rollback, backup timer and preservation of existing apps/Nginx files | `test-results/cartunez-deployment.json` |
| Bounded capacity run with 10,000 products/stock rows, 1,000 historical invoice fixtures and 40 real API sales | `test-results/api-capacity-http.json` |

The capacity run used a separate local API process and PostgreSQL database. It is not a VPS throughput guarantee. Bootstrap currently includes all authorized catalog and history; pagination and incremental synchronization are not implemented. Review the measured payload and memory limits against the real catalog and accumulated history before adding substantially more counters or data. The shared-VPS configuration allocates 768 MiB to the API and 768 MiB to PostgreSQL and enables compression in its own Nginx vhost.

The final production dependency audit (`npm audit --omit=dev --audit-level=high`) reported zero known vulnerabilities. This is dependency evidence, not an independent penetration test.

The Windows 1.1 package is unsigned. Its application files are tested separately so that the user's open 1.0 installation and profile are preserved; see the version-specific Windows evidence for the precise installation/runtime scope. The Android 1.1 APK has a stable private release signature and HTTPS-only release policy. Keep that signing key backed up for future upgrades. A release-signed APK cannot update the earlier debug-signed APK in place; reconcile and preserve any old outbox before replacement on a real counter.

## Scope that still requires shop-side verification

Follow [CARTUNEZ-DEPLOYMENT.md](CARTUNEZ-DEPLOYMENT.md) on the actual VPS, then record DNS/HTTPS/renewal, service health, first-owner login, production Settings, backup timer, offsite backup and restore-drill results. Add the actual catalog, licensed/retailer-maintained fitment and physically reconciled opening stock. No real business values or credentials have been invented.

Only Microsoft Print to PDF and OneNote printers were detected on the Windows development computer. No physical thermal printer, drawer or barcode-scanner hardware was available. Exercise the actual counter devices, printing, offline restart and reconnect before using them for real sales.

Payments are manually confirmed from an external terminal/provider; automatic collection, settlement verification and provider webhooks are not integrated. Optional India GST mode covers ordinary domestic components using the configured registration, state and HSN/SAC. GSTIN verification, e-invoice/IRN submission, e-way bills, filing, cess, reverse charge, exports/SEZ and refundable-core deposit GST treatment are outside this implementation. Confirm that the configured operating mode covers the shop's actual requirements before issuing real invoices. See [API.md](API.md) for the enforced behavior and boundaries.

The operator need not share SSH, DNS, database, owner, certificate or signing passwords in chat. Return non-secret command outcomes and confirm that the selected existing VPS backup system includes the POS recovery files. Required details and evidence are listed in [GO-LIVE-INPUTS.md](GO-LIVE-INPUTS.md).
