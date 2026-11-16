# Go-live inputs for pos.cartunez.in

The operator runs deployment commands on the shared VPS. Do not send SSH keys, passwords, `.env` contents, TLS private keys, database dumps, customer records, or payment credentials in chat. Share only the requested command outcomes with secrets and unrelated tenant details removed. Shop information is entered directly in Settings after the first owner signs in.

## VPS and domain checks

Confirm the Linux distribution, available CPU/RAM/disk, Docker Engine and Compose versions, and the system Nginx service status. Confirm which local port is free for this API and which directory is reserved for this application's static files and Compose project. Existing VPS applications, virtual hosts, containers, volumes, and certificates must retain their own configuration.

Confirm the DNS result for `pos.cartunez.in`: its A record must point to the intended public IPv4 address; publish an AAAA record only if that VPS actually serves this hostname over IPv6. Report DNS success or the record mismatch, without giving us registrar credentials. Confirm that ports 80 and 443 reach system Nginx and that the chosen ACME method can issue and renew the hostname's certificate. After applying the dedicated virtual host, report `nginx -t`, HTTPS health, and renewal-test outcomes. Do not paste private keys or an unredacted full server configuration.

The API should bind to an unused loopback port behind system Nginx. PostgreSQL stays on the application's private Docker network. Keep production `SEED_DEMO=false`, use independent randomly generated database and JWT secrets locally, and set the exact browser origin plus the installed-client origins. Configure the expected proxy-hop count for the actual Nginx path.

## First owner and shop configuration

Choose organization and branch codes before the initial bootstrap; counters use these codes when signing in. Create a strong owner password locally, supply the real owner's email, and remove the one-time bootstrap password from deployment configuration after successful setup. Verify owner login and password rotation before inviting staff. Keep a recovery procedure under the shop owner's control.

Enter the following in Settings, without sending the values to the development chat:

- Trading/shop name, legal name, branch display name, receipt address, phone, and support email.
- Currency, applicable tax registration identifiers, and invoice wording required for the business's jurisdiction.
- Tax-inclusive or tax-exclusive pricing, supported item tax rates, rounding policy, invoice prefix and approved numbering policy.
- Offline authorization duration, allowed offline tenders, session duration, cashier discount limit, and owner/manager approval policies.
- Whether card and UPI are recorded through manual confirmation from an external terminal/provider. This mode records an operator's confirmation and reference; it does not collect, settle, or verify payment through a provider API.

Confirm the receipt preview and a real paper/PDF receipt before the first real transaction. The shop's tax adviser must confirm the required invoice fields and tax treatment for its actual jurisdiction and registration; do not infer this from demo GST-style rates or the default INR currency. If regulated tax splits, place-of-supply rules, HSN/SAC, e-invoicing, or fiscal-device integration are required, confirm that exact scope and implementation before issuing regulated invoices.

## Staff, stock and opening balances

Create staff accounts with named owners, managers, cashiers, and inventory operators and assign only the branches they use. Define the physical sellable, damaged, and warranty bins before receiving stock. Add suppliers and customers through the application. An empty production installation intentionally contains no demo products, supplier records, vehicles, bins, invoices, or opening stock.

Prepare the actual catalog locally: SKU, names, unit/pack size, manufacturer and supplier references, barcodes, cost, retail/wholesale prices, tax category/rate, serial tracking, warranty/core rules, and opening quantity by bin. Establish the opening-stock valuation date and reconcile it to the physical count. Use only fitment data the business has the right to use, with make/model/year/engine/fuel and source; ambiguous fitment must remain unverified. A spreadsheet or data source is an input to an agreed import procedure, not evidence that a product-catalog importer already exists.

## Backups and operation

The operator selected the existing VPS backup system. Confirm its product/job name, schedule, off-server destination, retention, encryption, and failure-alert owner so the POS files and image-inclusive recovery bundle can be included in that existing job. No replacement backup service is installed. Destination credentials stay on the VPS or backup system, never in source control or chat. Record the acceptable data-loss window and recovery time. Automatic copying, retention, monitoring, and failed-backup alerts must be checked; a working manual dump script alone does not establish this maintenance plan.

Perform a restore drill into an isolated database and compare stock, invoices, audit records, and financial totals. Keep the matching application release and configuration recovery instructions. Server backups do not contain unsynchronized sales still held on a counter: keep each counter's local database and reconcile its outbox before reinstalling or retiring it. Confirm daily shift closure and conflict review ownership.

## Client distribution and hardware

Counters use `https://pos.cartunez.in/api/v1` with the production organization and branch codes. Verify that login, enrollment, cached restart, offline sale, reconnect, and conflict handling use that address on each device. A cloud VPS outage or shop internet loss must be included in the offline acceptance exercise.

Windows can be staged internally with the unsigned installer if the organization controls the distribution channel and explicitly accepts the Windows trust prompt. Authenticode signing is strongly recommended for broad or public distribution. For signed packaging, configure the certificate/private-key location and signing-provider access locally; share only non-secret path/configuration results. Do not submit certificate passwords or private keys to the chat.

Android always requires an APK signature for installation. Version 1.1.0 is now packaged as `Motorline-1.1.0-release.apk`, signed with a newly generated stable private application release key. The earlier `Motorline-1.0.0-test.apk` retains its Android Debug signature and remains a test artifact. Follow [Android signing key custody](ANDROID-RELEASE-SIGNING.md) to back up the private keystore and metadata securely before distribution; neither is included in deliverables. A purchased certificate or Play Store listing is not required for private APK distribution. Supply key paths and passwords only in the local build environment. Public store distribution additionally follows that store's signing and publishing process. Preserve the signing identity for upgrades.

Record Windows/Android versions, screen sizes, camera availability, keyboard-wedge scanner models, printer model/connection/paper width, and installed printer drivers or Android print services. Validate a real barcode and receipt on each hardware type. Browser camera permissions, thermal paper size, cash drawer behavior, and vendor-specific printer functions must be checked on that hardware. Do not substitute emulator PDF/scanner-preview checks for physical-device acceptance.

## Evidence to return after operator-run deployment

Return concise success/failure outcomes for DNS, dedicated Nginx configuration test, TLS issuance and renewal, isolated Compose services and health, first-owner login, configured receipt preview, opening-stock reconciliation, physical counter tests, scheduled backup completion, and the restore drill. Include relevant non-secret error messages when a check fails. These outcomes, not access credentials or business data copied into chat, establish readiness for the agreed rollout stage.
