# Bounded capacity verification

The local 1.1.0 smoke passed with 10,000 fictional products, 10,000 stock rows, 11,000 opening/sale ledger rows, 1,000 equivalent invoice records and 1,000 audit records. It then finalized 40 additional sales through the API and reconciled 1,040 invoices, exact gross receipts, and 998,960 stock units. Every fixture belonged to a new disposable PostgreSQL database, which was dropped afterward. Existing demo, acceptance and production databases were untouched.

The measured API ran in a separate Node.js 22.23.5 process on Windows, with an Intel i5-12400 host and 24 GiB RAM. PostgreSQL 17 ran in the dedicated local verification container. HTTP requests used localhost. This measurement excludes TLS, public-network latency, browser rendering and native client bridge costs; it was not performed under the shared-VPS CPU/memory quota.

| Operation                  | Samples | Concurrent requests |   Median | 95th percentile |
| -------------------------- | ------: | ------------------: | -------: | --------------: |
| Existing catalog bootstrap |      20 |                   1 |   199 ms |          291 ms |
| Existing catalog bootstrap |      20 |                   4 |   655 ms |          915 ms |
| Finalize sale              |      20 |                   1 |    29 ms |           39 ms |
| Finalize sale              |      20 |                   4 |    89 ms |          113 ms |
| Sales report               |      20 |                   4 |   266 ms |          296 ms |
| Stock valuation report     |      12 |                   4 | 2,483 ms |        2,558 ms |

The first bootstrap took 400 ms and returned 9,698,845 uncompressed bytes. The API process's sampled peak RSS was 327 MiB; after an explicit end-of-measurement garbage collection, RSS was 308 MiB and used JavaScript heap was 12 MiB. Sampling used response hooks and 50 ms intervals, so this is not a guaranteed allocator peak. Fixture creation and client response objects lived in a separate process. An earlier injection-only run included those objects and is retained as additional evidence, not the API memory estimate.

The first separated-server run identified an avoidable catalog read: bootstrap fetched and parsed an entire persisted catalog snapshot just to check whether it existed. Replacing that query with `SELECT 1` preserved the response and snapshot semantics. Under the same bounded fixture, the subsequent run reduced sampled peak RSS from 433 to 327 MiB and sequential bootstrap median from 278 to 199 ms. These are individual local observations, not guaranteed production improvements.

This verifies the stated bounded workload, not arbitrary scale or a throughput SLA. The production API memory cap was increased to 768 MiB after this review to provide additional headroom; the measurements do not establish a production memory guarantee. Review available VPS resources and monitor memory, response latency and database growth before increasing traffic or history size. The host preflight and service resource caps remain necessary on a shared VPS.

Bootstrap currently sends the entire authorized catalog and history, including invoices and audit records for an owner. Response size grows with history, and each distinct authorized catalog revision is retained for offline reconciliation. Incremental synchronization, history pagination and snapshot-retention policies are not implemented. At larger histories these require a designed API/client change; silently truncating records would break historical lookup and offline expectations. Valuation also performs work across the whole stock/ledger fixture and is slower than checkout.

Raw measurements: [final separate HTTP server](test-results/api-capacity-http.json), [before the snapshot-read optimization](test-results/api-capacity-http-before.json), [injection smoke](test-results/api-capacity.json). The 1,000 historical invoices were inserted as equivalent immutable records; the 40 additional invoices exercised actual API validation, transactions and stock updates.
