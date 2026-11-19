# Magento online store

The POS keeps a Magento 2 store in step with the shop. The POS is the source of truth for parts,
prices and stock; Magento follows it.

## What works now (phase 1)

- **Online store screen** (owners and managers, Settings › Modules › Online store): every part with
  checkboxes, filters (on website, not on website, on order, errors, low stock) and bulk actions:
  publish, unpublish, set price, availability and safety buffer. Tap a part for all its settings,
  including a website description.
- **Prices:** MRP is the POS retail price including tax. The selling price is MRP, a % off MRP, or a
  fixed price (never above MRP). MRP is sent as Magento's *price* and the selling price as its
  *special price*, so the storefront shows MRP struck through next to the discounted price.
- **Availability:** *In stock* (out of stock at 0), *On order* (backorders allowed, "Ships in N days"
  in the short description) or *Hidden when out of stock*.
- **Stock:** the website quantity is the online branch's stock, minus parked sales and the safety
  buffer. Every sale, return, receipt, adjustment, count, move and parked sale in that branch queues
  an update; editing a part updates its name and price.
- **Unpublish** disables the product in Magento; it is never deleted, so order history stays.

## Online orders (phase 2)

- Orders are read from Magento every minute (**Online store › Orders › Check now** reads at once),
  starting from the moment the store was connected.
- **Reserved:** a new order holds its units in the online branch; the counter cannot sell them.
- **Sold:** when Magento invoices an item, its units are taken out of the fullest sellable bins
  (stock ledger reason "Online order #…"). The Magento invoice is the customer's tax invoice; the
  POS does not issue a second one.
- **Awaiting stock:** units invoiced but not in the shop wait; they are taken automatically once
  stock arrives (or with **Fulfil from stock**). **Order missing parts** creates an open purchase
  order per supplier for the shortage, noted "For online order #…".
- **Cancelled / refunded:** cancelled units release their hold; refunded units go back to the bins
  they came from ("Online refund #…").
- Everything is derived from Magento's per-item ordered / invoiced / cancelled / refunded
  quantities, so re-reading an order never counts it twice, and partial invoices and refunds work.
- Items whose SKU is not in the POS are shown as "Unknown parts" and are not guessed.

The quantity sent to Magento does not subtract online orders, because Magento already reserves them
itself. Between POS invoice-time deduction and Magento shipment both may count the same units, which
can only show *less* online stock for a short time, never more.

## Photos and daily comparison (phase 3)

- **Photos:** add up to 8 photos per part (Inventory › Parts › photo icon, or Online store › part ›
  Photos). The app shrinks them to 1600 px JPEGs before upload; they are stored in the POS database
  (so the usual backups include them). The first photo is the main one: it shows at the counter and
  becomes Magento's base, small and thumbnail image. Adding, reordering and deleting photos updates
  Magento; a photo is uploaded once, and one already removed in Magento's admin is not an error.
- **Daily comparison:** once a day (and with **Compare now** on the Online store screen) every
  published part is read back from Magento. Stock, MRP, selling price and status that differ from the
  POS, and products deleted in Magento, are sent again. The result ("all match" or what was
  corrected) is shown on the Online store screen.

## Staging server

`deploy/magento/` sets up Magento 2.4 at shop.cartunez.in as an isolated Docker project with a
staging password; see [deploy/magento/README.md](../deploy/magento/README.md).

## Connect a store

1. In the Magento admin: **System › Extensions › Integrations › Add New Integration**. Name it
   "Cartunez POS"; under **API**, allow *Catalog* (products, inventory), *Sales › Operations › Orders* (view) and *Stores ›
   Settings*; save,
   then **Activate** and copy the **Access Token**.
2. In Magento, set **Stores › Configuration › Sales › Tax › Calculation Settings › Catalog Prices**
   to **Including Tax**, because MRP includes GST.
3. In the POS (owner): **Settings › Modules**, switch on *Online store (Magento)*. Then **Settings ›
   Online store › Connect Magento**: store address (https://…), access token, the branch that sells
   online, and the safety buffer. The connection is tested before it is saved.
4. Open **Online store**, select parts, set prices and availability, and **Publish**.

The token is stored only on the server (never sent to counters or browsers). Products go to the
default attribute set (4) and website (1); change these under *More options* if your store differs.

## How sync works

Requests never call Magento directly. A change writes a queued job in the same database transaction
as the sale or edit. A worker in the API process sends due jobs every 5 seconds with
`PUT /rest/all/V1/products/{sku}` (product, prices and stock item in one call). Failures are shown on
the part ("Error" with Magento's message), retried with growing delays (30 s up to 1 hour), and can be
retried at once with **Retry errors**. A newer change made while a send is in flight is sent next.

Code: `apps/api/src/magento.ts` (rules, worker, routes), `apps/api/src/online-queue.ts` (queueing),
`apps/api/src/magento-orders.ts` (orders), `apps/flutter/lib/ui/screens/online.dart` and
`online_orders.dart` (screens). Tests: `apps/api/test/magento.test.ts` and `magento-orders.test.ts` (fake
Magento), `apps/flutter/visual/online_test.dart` (screen → API → worker → fake Magento).
