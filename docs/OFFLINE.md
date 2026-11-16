# Offline operation

## Shop LAN

The shop server can host Docker PostgreSQL and the API on its LAN, with Nginx on the host. Internet loss does not interrupt counters that can still reach that server. A server outage activates the local checkout policy below.

## Enrollment and expiry

A manager enrolls a counter while connected. Enrollment records the branch, offline authorization deadline, permitted tender types, and a dedicated invoice-number range. Settings control maximum offline hours and session duration. Cash is the supported offline tender. Checkout checks the cached session, role, enrollment deadline, invoice range, and open shift. An expired session or enrollment requires reconnection. The current last-sync time, connection state, and pending count appear in the header, including on Android.

The workspace key contains the API installation address, organization, branch, and signed-in user. Device-range state is shared by authorized users of the same installed counter and branch. Using another server address creates a separate local workspace. Keep the server address stable when working with pending sales.

## Durable transactions

A sale receives a stable transaction UUID before transmission. Local storage durably writes the pending sale before checkout attempts the API. Offline invoices draw from the enrolled device's number range. A shared browser lock serializes outbox and range changes. Windows allows a single running instance per profile. Android uses SQLite transactions.

Reconnect processing uses each transaction's original device ID, including after a later enrollment. The API checks the request's identity and payload and commits invoice, stock ledger, and idempotency result in one database transaction. Retries return the existing result. Local pending transactions are removed only after server acceptance or creation of a server reconciliation record. The authorized catalog revision preserves sale-time prices and fitment data across catalog updates.

Current in-progress carts also persist locally. Browser assets are cached by a service worker after initial setup. Windows and Android contain the assets in their installers. The browser requires HTTPS or localhost for PWA service workers.

## Stock conflicts

The counter visibly identifies offline stock as a snapshot. Locally pending quantities reduce availability displayed on that counter. Different offline counters can sell the same last unit because they cannot consult each other. The first accepted server transaction consumes the available stock. A later conflicting sale becomes a manager reconciliation item with its payment and original transaction details retained.

A manager may accept a sale after investigating physical stock, recording a reason and an audited negative stock variance. A rejected sale retains a refund-required record for manual resolution. Serial-number constraints continue to apply. Every decision remains in the audit trail. This policy prevents silent duplicate invoices and preserves both counters' recorded activity.

## Payments, reports, and shifts

Cash sales may be completed offline. Transactions requiring provider confirmation remain locally pending until the confirmation and reference are recorded while connected. Server reports contain confirmed server transactions. The dashboard and reconciliation page show pending local activity separately. Close shifts after synchronizing outstanding counter sales and resolving pending payment activity.

Backups cover server records, stock, audit, idempotency transactions, and enrollment records. Each counter's unsynchronized outbox resides on that counter. Keep its SQLite database or browser profile until pending activity is synchronized. Signing out retains that user's scoped pending queue for the next sign-in.
