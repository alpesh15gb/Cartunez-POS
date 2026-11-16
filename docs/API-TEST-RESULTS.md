# API test results

Release 1.1.0: the TypeScript compiler and both API suites passed on Windows with Node.js 22.23.5 and PGlite: 2 tests, 2 passed, 0 failed. The final rebuilt API image also passed both suites against a new empty PostgreSQL 17 database in the isolated Ubuntu WSL Docker verification environment: 2 passed, 0 failed. That final run includes the snapshot existence optimization and enrollment clock-skew regression; raw TAP output is in `docs/test-results/postgresql.txt`.

The suite exercises real HTTP handlers through Fastify injection and the actual SQL persistence adapter. It verifies these workflows with assertions.

- Creating a part, assigning fictional fitment, receiving partial purchase quantities into two bins, and moving stock to a new shelf.
- Compatible, incompatible, and incomplete vehicle matches, cashier rejection without approval, and successful manager-authorized override.
- Exact tax and discount calculation, a cash checkout, immutable issued invoice records, partial returns to sellable and damaged bins, and return limits.
- Retry idempotency for goods receipts, invoices, offline synchronization, and core refunds.
- Authorized catalog snapshots preserving offline price after the live catalog changes.
- Two transactions competing for the last unit, a single immediate acceptance, a manager conflict, and audited acceptance with negative stock.
- Branch restrictions, API role restrictions, cashier cost redaction, and preserved data after migration rerun.
- CSV preview, malformed row errors, import, and duplicate skipping.
- All report endpoints and reconciliation of gross sales, merchandise refunds, core refunds, and net receipts.
- Serial-number receipt, bin movement, sale, return, transfer dispatch, and receipt at the second branch.
- Full void of a combined service, serialized merchandise, and core-charge invoice, exact refund, stock restoration, and prevention of a second core refund.
- Configured invoice rounding and exact credit, online numbering skipping reserved offline device ranges, shortened active session policy, and first-owner bootstrap into a new organization.
- Production startup rejects the development signing secret and demo seeding; bootstrap creates exactly one initial owner and no demo products on repeated startup.
- Login limits distinguish trusted forwarded client addresses. Password updates revoke existing tokens. Only owners receive sanitized user lists; cashier bootstrap contains neither other users nor password hashes.
- Two-decimal currency validation and accounting-currency locking after monetary records; strict quantity validation rejects boolean coercion.
- Configurable inclusive/exclusive tax calculations, multiline address/footer normalization, disabled tender rejection, and mandatory external references for confirmed noncash payments.
- Immutable business, branch, footer, customer, and monetary-policy snapshots for ordinary and delayed offline invoices and their credits.
- Domestic CGST/SGST versus IGST components, odd-paise partial service-credit allocation, original component conservation, signed tax-report components, GSTIN/state format guards, and invoice/credit-number length restrictions.
- Offline customer state/address snapshots survive subsequent customer edits, and fitment effective-date evaluation accepts the original sale date.
- Parked-cart release and finalization actually delete mutable hold records and remove reservations. Financial, audit, stock-ledger, and idempotency records remain append-only after migration reruns.
- Real native/server enrollment clock skew regression: a timestamp 601 ms before enrollment is accepted; 60,001 ms before enrollment, more than five minutes in the future, and one millisecond past device expiry are rejected. The tolerance never extends offline duration.

The detailed test code is `apps/api/test/acceptance.test.ts` and `apps/api/test/production.test.ts`. Run both with `npm run test:api` from the repository root. For PostgreSQL, provide `DATABASE_URL` pointing to an empty disposable test database and start the test runner in development/test mode; the production suite establishes its own isolated production environment. The original fixture deliberately expects a new seed catalog. The suites add records and must run in a dedicated database. Current migrations are 001–003.

The separate fresh-production browser acceptance also passed against the latest compiled API and a dedicated PostgreSQL database: empty installation, Settings and stock setup, USD exclusive/inclusive tax, pending then externally confirmed UPI, immutable historical receipt, currency lock, owner password rotation, old-token rejection, and persistence across API restart. Its evidence is `docs/test-results/fresh-production.json`.

A bounded local HTTP capacity smoke passed with 10,000 products/stock rows, 1,000 historical invoice fixtures and 40 additional real API sales. Final samples at concurrency four showed checkout p95 113 ms, bootstrap p95 915 ms, sales-report p95 296 ms, and valuation p95 2,558 ms. Sampled API-only peak RSS was 327 MiB after removing a redundant full-snapshot existence read. See `docs/CAPACITY.md` for fixture, environment, sample counts and limitations; these numbers are not a production throughput guarantee.

Windows installer, Android emulator, browser UI, Nginx, backup/restore, and physical printer results are tracked in the release verification documentation. This API suite does not establish those client or hardware results.
