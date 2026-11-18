# Motorline API v1

The base path is `/api/v1`. The service listens on port 4000 behind host Nginx. Monetary amounts use integer minor units. INR 285.00 is represented by `28500`. Tax rates use basis points, so 18% is `1800`. Quantities are whole units. Product pack size is metadata for the selling unit.

## Authentication and installation

`POST /auth/login` accepts `organizationId`, `email`, `password`, and `branchId`. Its response contains a bearer `token`, `user`, `organizationId`, `branchId`, and `expiresAt`. Subsequent requests send the bearer token in the `Authorization` header. Active status and branch assignments are reread for every request. Passwords are salted with a random per-user salt and hashed using scrypt. Login has a separate rate limit.

Demo setup uses `SEED_DEMO=true`. The fictional organization is `demo`, with branches `pune` and `mumbai`. Demo users are `owner@motorline.local`, `manager@motorline.local`, `cashier@motorline.local`, and `inventory@motorline.local`. The seed password is `MotorlineDemo123!`, overridden by `DEMO_PASSWORD` before seeding. The demo cashier has access to Pune.

A fresh production installation creates its first owner through `BOOTSTRAP_OWNER_PASSWORD` (16–256 characters), `BOOTSTRAP_OWNER_EMAIL`, `BOOTSTRAP_ORG_ID`, `BOOTSTRAP_ORG_NAME`, `BOOTSTRAP_BRANCH_ID`, `BOOTSTRAP_BRANCH_NAME`, and `BOOTSTRAP_CURRENCY`. `BOOTSTRAP_OWNER_NAME` is optional. Organization and branch codes are stable lowercase slugs, at most 64 characters. Bootstrap runs only when that organization is absent, checks again inside the database transaction, and never resets an existing owner. Remove bootstrap secrets from the running environment after provisioning. Complete the legal business name and address in Settings before the first production invoice; an incomplete profile returns HTTP 409.

Production startup requires `DATABASE_URL`, a unique random `JWT_SECRET` of at least 32 characters, and an exact HTTPS shop origin in `CORS_ORIGINS`. It rejects demo seeding and recognizable/default/low-diversity secrets before connecting to the database. The seed CLI also rejects production mode. `TRUST_PROXY_HOPS` defaults to zero and accepts zero through four; the provided shared-VPS deployment uses one trusted Nginx hop, overwrites the forwarded client address, and binds the API host port to loopback. Do not expose that port directly with proxy trust enabled.

`GET /health` is public and checks database connectivity; release 1.1.0 retains API version `/api/v1`. `GET /bootstrap` supplies the authorized branch workspace, current catalog revision, settings, bins, stock availability, records, and current user role. Only owners receive the organization `users` list, with password hashes removed; other roles receive `users: []`. Cashier responses recursively remove cost fields, including direct sale, credit, and synchronization results. Transaction-specific receipts retain their issued snapshots in the authoritative database.

Tokens use HS256 and include expiry, issue time, and the user's access version. Every request rereads active status, role, branch assignment, access version, and current session policy. Editing a user, including password rotation, revokes that user's existing tokens. Reducing `sessionHours` also applies immediately to existing sessions.

## Operation contracts

The companion `api-contract.json` contains example request bodies and bootstrap record shapes. All POST mutations accept a stable `transactionId` for safe retries. Sales, merchandise returns, core returns, goods receipts, and offline sync require it. Reuse the entire request body unchanged when retrying. A transaction ID reused with a different body receives HTTP 409. Approvals use `transactionId` to identify the transaction being approved, so issuing an approval does not consume its transaction ID.

| Operation                             | Endpoint                                                        | Authorized roles                                                  |
| ------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------- |
| Catalog creation and update           | `POST /products`                                                | Owner, manager, inventory                                         |
| Customer creation and update          | `POST /customers`                                               | Owner, manager, cashier                                           |
| Supplier creation and update          | `POST /suppliers`                                               | Owner, manager, inventory                                         |
| Location creation and rename          | `POST /locations`                                               | Owner, manager, inventory                                         |
| Manual fitment and matching           | `POST /fitments`, `POST /fitments/check`                        | Editing requires owner, manager, or inventory                     |
| Fitment CSV preview and commit        | `POST /fitments/import/preview`, `POST /fitments/import`        | Owner, manager, inventory                                         |
| Bin movement, adjustment, count       | `POST /inventory/move`, `/inventory/adjust`, `/inventory/count` | Owner, manager, inventory, with adjustment approval when required |
| Purchase order and partial receipt    | `POST /purchase-orders`, `/purchase-orders/:id/receive`         | Owner, manager, inventory                                         |
| Transfer dispatch and partial receipt | `POST /transfers`, `/transfers/:id/receive`                     | Owner, manager, inventory with authorized branch access           |
| Shift opening and closeout            | `POST /shifts/open`, `/shifts/:id/close`                        | Owner, manager, cashier                                           |
| Park and release cart                 | `POST /holds`, `DELETE /holds/:id`                              | Owner, manager, cashier                                           |
| Finalize sale                         | `POST /invoices`                                                | Owner, manager, cashier                                           |
| Merchandise credit note               | `POST /invoices/:id/returns`                                    | Owner, manager, approved cashier                                  |
| Audited full invoice void             | `POST /invoices/:id/void`                                       | Owner, manager                                                    |
| Warranty claim and status update      | `POST /warranty-claims`                                         | Owner, manager, inventory                                         |
| Core refund                           | `POST /core-returns`                                            | Owner, manager                                                    |
| Privileged approval                   | `POST /approvals`                                               | Owner, manager                                                    |
| Offline enrollment and renewal        | `POST /devices/enroll`, `/devices/:id`                          | Owner, manager                                                    |
| Offline outbox synchronization        | `POST /sync`                                                    | Owner, manager, cashier                                           |
| Conflict reconciliation               | `POST /conflicts/:id/resolve`                                   | Owner, manager                                                    |
| Users, branches and configuration     | `POST /users`, `POST /branches`, `POST /settings`               | Owner                                                             |

Approval actions are `fitment`, `discount`, `return`, and `adjustment`. An approval records its manager, reason, branch, transaction ID, and 15-minute expiry. A cashier supplies `approvalId`, with a separate `discountApprovalId` when a sale needs both fitment and discount approval. Owner and manager execution is itself recorded in the audit trail. Inventory adjustments accept approval bound to their stable transaction ID.

Serial-tracked receipts, picks, returns, movements, adjustments, and transfers require a `serials` array with one unique serial per unit. Returns identify an original `lineId` to distinguish the same SKU picked from multiple bins. Transfer receipts similarly accept `lineId`. Returned serials must belong to the original invoice and are moved to the specified condition and destination bin.

## Settings and receipt profiles

`POST /settings` accepts partial updates. Business fields are `business: {legalName, tradingName, address, taxRegistrationId, stateCode, phone, email}`. Current branch fields are `branchName`, `branchAddress`, and `branchStateCode`. `POST /branches` creates or updates `{id, name, address, stateCode}` and grants the acting owner access to a newly created branch. Addresses and `receiptFooter` accept LF or CRLF text, normalize CRLF to LF, and reject other control characters.

Financial configuration includes `currency`, `invoicePrefix`, `creditNotePrefix`, `nextInvoice`, `taxDisplayName`, `taxMode: "inclusive" | "exclusive"`, `taxScheme: "general" | "india-gst"`, `localTaxName: "SGST" | "UTGST"`, `taxRates` (basis points), `roundingIncrement` (minor units), and `tenderTypes` (a nonempty subset of Cash/Card/UPI). `nextInvoice` may only move forward; online numbering skips reserved device ranges. Credit-note numbers use a separate monotonic counter. The accounting currency must have two minor-unit decimal places and cannot change after a shift, purchase, sale, or credit exists; another accounting currency needs a separate organization. There is no exchange-rate conversion.

Access policy fields are `offlineHours` (0–168), `offlineTenders` (Cash only), `sessionHours` (1–168), and `cashierDiscountLimit`. Catalog products accept optional `hsnSac`. Customers and suppliers accept `address`, `taxRegistrationId`, and `stateCode`, with syntactically validated email addresses.

Each invoice freezes business and branch profiles, currency, tax mode/scheme/display label, footer, customer, place of supply, and each line's unit and HSN/SAC. Credit notes reuse the issued invoice's profile even after Settings or customer records change. General scheme is the default. No external registry or tax classification lookup is performed.

## Checkout and synchronization

The server calculates authorized retail or wholesale prices, line discount allocation, tax, core charges, invoice rounding, and change. It validates stock, selected bins, serials, customer, shift, fitment, and approvals within the same transaction that writes invoice and stock ledger entries. PostgreSQL serializes stock mutations using a locked installation row. Issued invoice and return records, core refunds, audit entries, stock ledger rows, and completed idempotency records reject UPDATE and DELETE. Ordinary parked-cart records remain removable; completing or releasing a parked cart clears its reservation.

After proportional discount allocation, exclusive tax is `round(net * rate / 10000)` and the line total is `net + tax + core`. Inclusive tax is `net - round(net * 10000 / (10000 + rate))`, with line total `net + core`. Integer arithmetic and BigInt ratios avoid floating-point monetary errors. Invoice rounding is attached to the final line. Partial credits use cumulative proportional rounding, so returning all units refunds the exact original merchandise/service amount and rounding.

Full invoice voids issue an immutable credit note, return merchandise to its original picked bins, restore serial availability, and cancel refundable core charges through separate core-refund records. Service lines receive a credit without stock movements. A full void requires an invoice with no prior return or core refund. Existing partial corrections continue through line credit notes. The void response includes `coreRefundTotal` and `totalRefund`, while reports preserve merchandise and core refunds separately.

Each offline transaction includes `offline: true`, `deviceId`, a number inside the enrolled `rangeStart` and `rangeEnd`, `occurredAt`, `catalogRevision`, its stable `transactionId`, and the ordinary sale body. `catalogRevision` identifies the branch snapshot previously issued by bootstrap. Offline finalization uses frozen products, customers, business/branch profiles, invoice prefix, tax policy, and rounding. Fitment effective dates are evaluated at the recorded sale date. Later edits cannot silently reprice a paid offline transaction or rewrite its receipt. A different current accounting currency causes a conflict. Current access, tender policy, device authorization, and stock checks still apply.

The device permits only configured offline tenders. The default and currently supported offline tender is cash. Card and UPI are external payment records. The cashier records external confirmation and its reference. A transaction marked unconfirmed is rejected for finalization and stays pending in the client. Payment provider SDKs and authenticated provider webhooks require a shop-specific integration.

## Optional domestic GST components

India GST mode requires INR, a business GSTIN matching the configured two-digit state code, registered name/address, and 4-, 6-, or 8-digit product HSN/SAC input. GSTIN checks are format/state checks, not live registration or checksum verification. This organization supports one registration state; branches in another registration state require a separate organization. The owner chooses SGST or UTGST as applicable.

Checkout sends `placeOfSupply` as a two-digit domestic state code. A selected customer's state is the only fallback; the server does not infer the legal place of supply from a vehicle or cashier location. Same-state transactions split each line's tax into `CGST = round(tax / 2)` and the remaining SGST/UTGST. Other-state transactions use IGST. Lines freeze `taxComponents: [{name, rate, amount}]`, with rates in basis points. Invoices and credits expose totals as `taxComponents: [{name, amount}]`. Partial credits conserve both total tax and original component amounts, including odd-paise rounding. Tax report rows carry signed component amounts.

Invoice and credit numbers enforce the 16-character alphanumeric/hyphen/slash format. Numbering and ordinary domestic component choices follow the structural rules described in [CBIC Rule 46](https://taxinformation.cbic.gov.in/content-page/explore-rules/1000136/1000001) and [CBIC's tax component FAQ](https://cbic-gst.gov.in/hindi/sectoral-faq.html?ld=SDINSOADirect).

This mode is not a complete GST compliance or filing service. It does not provide IRN/e-invoicing, signed QR codes, e-way bills, returns filing, cess, reverse charge, exports/SEZ handling, statutory eligibility/threshold determinations, or registration verification. The business must validate applicability, rates, classification, customer details, and required documents with its accountant before live GST use. GST sales with refundable core charges are rejected because the deposit's tax treatment has not been configured. General-scheme core tracking remains available.

`POST /sync` returns `results` containing each transaction ID and `accepted`, `conflict`, or `rejected`, plus an invoice or conflict ID when applicable. A last-unit sale that reaches the server first finalizes. A later sale becomes a manager conflict. Accepting the conflict explicitly permits negative stock and records the variance and reason. Rejecting it records `refundRequired` for the manager to handle. Repeated synchronization cannot finalize a second copy. Offline sales require a valid device authorization at their recorded sale time and an open, authorized shift.

`POST /devices/:id` can change `offlineAllowed` or renew with `renewHours`, plus a required reason. Clients must refresh device policy after reconnecting. An outage authorization is limited by both the logged-in session expiry and the device expiry. Manager review is required when a delayed transaction cannot meet the server's validation rules.

Device and server clocks must remain synchronized. The server allows up to 60 seconds of timestamp skew immediately before enrollment and rejects timestamps more than five minutes in the future. This compensates for small native/server clock differences; it does not add time to `offlineUntil`, whose upper bound remains exact.

## Reporting

`GET /reports/:name` supports `sales`, `returns`, `discounts`, `margin`, `shifts`, `tenders`, `valuation`, `stock-by-bin`, `stock-movement`, `low-stock`, `fast-moving`, `slow-moving`, `aging`, `purchase-receipts`, `tax`, `warranty`, `cores`, and `fitment`. Responses contain `rows`, report-specific `totals`, `confirmedOnly`, `pendingConflicts`, and `generatedAt`. The `format=csv` query exports the selected rows.

Optional filters are `dateFrom`, `dateTo`, `branchId`, `cashier`, `category`, `supplierId`, `sku`, and `paymentType` where relevant. Branch selection must match the authenticated branch. Sales, returns, tax, and margin use finalized invoice and credit-note snapshots. Net receipts subtract merchandise and core refunds. Shift cash subtracts refunds recorded in that shift, including core refunds. Inventory valuation uses current catalog cost, and aging consumes historical bin ledger receipts FIFO to show the age of remaining units. A bin transfer starts the destination bin's receipt age.

Date bounds are inclusive business dates in `YYYY-MM-DD`. Reports use `Asia/Kolkata` for INR and UTC for other currencies. `daily-sales` groups invoice activity, credit notes and core refunds by their own transaction dates. `tenders` reports collected, refunded and net amounts for each payment type. It rejects product filters because split tenders are recorded at invoice level. Report totals and rows come from the same read snapshot. CSV exports contain amounts in minor currency units.

## Deployment and error behavior

`CORS_ORIGINS` adds exact allowed browser origins. Configure the shop HTTPS hostname, such as `https://pos.shop.local`. Desktop `motorline://app` and Android `https://localhost` are included. No wildcard origin is used. PostgreSQL stays on the Compose private network. Nginx proxies `/api/` and serves the static web export.

Validation errors return HTTP 400, expired sessions 401, permission failures 403, inaccessible records 404, and transaction or stock conflicts 409. Responses use `{ "error": "message" }`. Unexpected server errors return a generic message. Monetary arithmetic uses safe integer inputs and BigInt intermediate proportional calculation. API startup reruns the idempotent migration before accepting requests.

Development can run on PGlite, with persistent files at `PGLITE_PATH` or `apps/api/motorline-data` under the default workspace command. Production requires PostgreSQL. The test suite explicitly selects an isolated in-memory PGlite instance when `DATABASE_URL` is absent.
