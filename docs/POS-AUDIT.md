# Cartunez POS audit

## 20 November 2026 · Live counter reconciliation

The authenticated owner used the production web register running 1.0.2 build 3 and API 1.1.0. The audit opened a zero-float shift and used the barcode entry field with an Enter suffix. Two consecutive entries of GTIN `4006381333931` added two units of `AUDIT-FILTER-01`. Removing the line emptied the cart. Scanning again and taking ₹600 cash produced ₹100 change on invoice `INV-MAIN-3`. Credit note `CR-MAIN-3` refunded ₹500 and returned both units to the original sellable bin.

| Production checkpoint | Sellable units | 30-day gross billed | 30-day refunds | 30-day net |
| --- | ---: | ---: | ---: | ---: |
| Before checkout | 10 | ₹1,000 | ₹750 | ₹250 |
| After checkout | 8 | ₹1,500 | ₹750 | ₹750 |
| After return | 10 | ₹1,500 | ₹1,250 | ₹250 |

The day ended this test with one ₹500 invoice, ₹500 in refunds, ₹0 net and ₹0 drawer variance. The outbox was empty. All 19 report controls in that release ran. Reports without matching transactions displayed their empty state. Inventory created zero-stock part `AUDIT-20261120-01` and found it by its generated code `CTZ-246885734044`. This part remains in the live catalog for the owner’s reset. The current live audit did not exercise removal because that control first ships in build 4.

## 1.0.3 build 4 · Candidate workflows

| Area | Change | Acceptance evidence |
| --- | --- | --- |
| Billing and catalog | Mobile checkout counts units and returns to scanning after the receipt closes. Managers can remove and restore unused items or stop and resume new sales on traded parts. | Two scans, cash change, returned units and zero net margin. Archived codes remain reserved. Prior invoices and returns survive stopping sales. A late offline claim for a stopped part enters review. |
| Bulk catalog | Inventory previews a UTF-8 CSV of up to 1,000 items, identifies invalid rows and duplicate codes, and saves the accepted import in one transaction. | Role and barcode-collision tests, replay and all-or-nothing checks. Opening stock follows a separate stock movement. |
| Purchasing | Dashboard suggests reorder quantities using sellable availability, reservations and outstanding supplier orders. Purchasing can print selected labels from a specific receipt and its destination bin. | Two staff cannot duplicate the same suggested reorder. A split delivery of six and four offers only the units in the selected receipt. A loopback printer verified the label job. |
| Cash and tender reconciliation | Register staff record reasoned cash in and out. Managers compare gross INR Card and UPI receipts to a provider CSV by method, reference, amount and IST date. | Drawer closure and movement history reconcile. Statement tests cover ambiguous and missing references, unmatched amounts and dates. Fees, refunds issued by the provider and bank payouts require separate reconciliation. |
| Physical count | Staff start a count for a part and bin. A manager reviews expected, counted and adjustment quantities. A new movement requires a recount before approval. | Intervening sale and reversal, zero count, repeated confirmation, reserved stock, serial swaps and branch permissions. |
| Reporting | Velocity reports deduct returns and show sold, returned and net units. CSV monetary headings identify the currency and represent rupees with two decimals. Server pages carry the same totals and a revision checked on subsequent pages and full exports. | The live CSV represented ₹500 as `50000`. Build 4 exports `500.00` under `gross (INR)`. Tests cover multi-page results, changed revisions, date limits and CSV scale. Reports still aggregate matching branch data in memory. |

### Release verification

The default PDF sizing failed to decode the shop’s generated Code 128 in a 203 dpi raster. The label planner now measures the encoded symbol, including numeric compression, and the PDF path honors the configured printer resolution. On 50 × 25 mm labels, an independent ZXing reader decoded the EAN-13, UPC-A, EAN-8 and generated Code 128 samples at both 203 and 300 dpi. The UPC read back as its equivalent zero-prefixed EAN-13. The browser camera now loads its pinned decoder and WebAssembly file from the POS host. A loopback-only camera fixture fed the rendered internal label into the compiled Flutter register. Two camera opens added two units of the same ₹250 SKU and the cart showed ₹500. Hardware clearance, contrast and driver scaling still need a printed sample at each counter.

The 16 API tests and 41 Flutter unit and widget tests passed. Desktop and phone walkthroughs, cashier checkout and return, network Zebra and simulated Magento UI tests passed. Seven scenarios also ran on PostgreSQL 17, including register acceptance, fresh production setup, cash reconciliation, provider comparison, catalog import, sale suspension and physical counts. A dump from the fixture restored into a separate empty database with the same 126 business records, 45 stock ledger entries, net 225 stock units and migration version 6. The packaged browser imported, removed and restored an unused SKU with its original barcode, retail price and cost.

### Competitor evidence

REA captured the rendered Zoho POS session guide (`ev_9659587df85b0f18d02e21b2e6a4f1a2b9906a0f3a962e089162e31c422a9c6e`) and item-actions guide (`ev_08c545586cd6c374c0954eafd337d27296fe66a02ca258bc1f32d03b5dda31c1`). They document drawer movements and session summaries, as well as marking an item inactive and active again. The catalog import and archive controls address those tasks in the Cartunez inventory while preserving its part history. [Zoho sessions](https://www.zoho.com/en-in/pos/retail/resources/help/sessions.html) · [Zoho item actions](https://www.zoho.com/en-in/pos/retail/resources/help/actions-on-items.html) · [Zoho item entry and import](https://www.zoho.com/en-in/pos/retail/resources/help/adding-items.html)

GoFrugal operator guides describe selecting purchased items for barcode printing, reserving stock on a held bill, and cashier bank drops. A fourth guide documents reviewing transactions made during stock counting. The evidence covers public operator documentation. Authenticated competitor registers were unavailable. [GoFrugal sources and capture IDs](GOFRUGAL-BENCHMARK.md)

## Earlier 20 November 2026 · Preparing v1.0.2 build 3

The public installation served v1.0.1 build 2 during this audit. An expired owner session still displayed a cached daily report. The new client clears the previous session's screen and rejects late responses from that session. All financial tests for this release used isolated fixtures.

| Workflow | Change and verification |
| --- | --- |
| Counter sale | Exact barcode search works in Billing and Inventory. Two scans of a ₹250 part posted one ₹500 invoice, accepted ₹600 cash, and produced ₹100 change. A full ₹500 return restored both units. The margin report contained a sale and a reversing credit with zero net margin. |
| Payment interruption | The cashier reviews a changed quote before charging. A retry after a simulated 503 reused the saved transaction ID and amount. Logout and a second cashier's refresh were exercised during an in-flight request. Card and UPI keep separate references on a split tender. |
| Browser register | An existing cart and pending payment migrated to IndexedDB, survived reopening, and remained readable alongside a 6 MiB catalog in the browser. Windows and browsers supporting Web Locks prevent two windows using the same register simultaneously. Connected checkout is required. |
| Inventory and purchasing | Multi-line orders and receipts support part scans and receiving into bins. The receipt test received two parts and applied freight once. Transfers receive against the selected dispatch line. Services cannot acquire physical stock. |
| Reports and receipts | Margin details include credit notes. Product filters use the invoice line at the time of sale. Purchasing filters use the receipt supplier. Bootstrap and reports read a consistent snapshot. Invoice and credit documents expose tender, customer, serial and applicable tax details. |
| Magento | Order polling and shortage ordering have regression coverage for multiple pages, repeat reads and branch identity. Damaged and warranty stock are excluded from publishing. Record inspected physical returns in Inventory. Sell serialized products at the counter. |

The 11 API tests, 32 Flutter unit and widget tests, PostgreSQL 17 retail acceptance test, and desktop and phone layout walkthroughs passed. The network label test reached a simulated printer. The packaged web register reached sign-in in a browser. The web bundle and unsigned Windows installer were built locally. Physical counter equipment, Android release packaging, the production payment provider and a restore of the shop's production backup still need operator verification.

## Live walkthrough

On 18 November 2026, the owner account was used to walk the published web app through initial part, bin and supplier setup, stock adjustment, barcode lookup, cash checkout, receipt review, a partial return, shift close, sales reporting, purchase ordering and receiving. A keyboard-entry scan with an Enter suffix added the oil filter, and a repeated scan increased the quantity. The two-unit ₹500 test invoice accepted ₹600 and showed ₹100 change. The ₹250 credit note restored one unit to the sellable bin. The shift closed with ₹250 expected and counted, and the sales report showed ₹250 net. The purchase order received one more unit into the same bin.

The live audit created the `AUDIT TEST` part, supplier and bin, invoice `INV-MAIN-1`, credit note `CR-MAIN-1`, a completed shift and a received test purchase order. These are test records for the owner’s reset.

## Release verification

The 1.0.1 web release and Windows x64 portable package were built locally. The Flutter unit suite, API suites and the retail acceptance suite against PostgreSQL 17 passed. The rebuilt web client was exercised at desktop and phone sizes, including UPC/EAN equivalence, GS1 Digital Link, checkout, part and bin scan selection, a negative inventory adjustment, camera-error fallback and CSV export. Native hardware and the production rollout remain pending.

## Fixed in 1.0.1

| Area | Change |
| --- | --- |
| First-run workflows | Billing links directly to shifts and parts. Inventory and purchasing show the prerequisites for a stock operation or purchase. |
| Billing | A scan adds one unit immediately when there is one suitable bin and the item needs no serial number or fitment approval. Repeated scans respect remaining stock. Forms and checkout prevent concurrent submission. |
| Barcode capture | Keyboard-mode USB and Bluetooth, manual entry, and supported cameras share a capture flow. Staff can use scans to choose parts and bins in inventory and purchasing. |
| Barcode identity | Exact private codes preserve punctuation. Valid UPC and EAN representations share a GTIN identity. Recognized GS1 element strings and Digital Links extract the product GTIN. The server rejects new catalog collisions. New internal labels use Code 128, and older labels stay resolvable. |
| Stock and labels | Negative adjustments work through the form. Label generation reserves quiet zones and identifies unprintable codes. Inventory and shift tables have room for status and amounts. |
| Reporting | INR reports use IST days. Daily sales, tender movements and GST components reconcile against posted records. Reports read a consistent database snapshot, expose applicable filters, paginate displayed results and export all matching rows. |

## Remaining rollout work

1. Verify physical USB and Bluetooth scanners, Android and browser cameras, and 50 × 30 mm thermal labels with the actual hardware at each counter. The desktop Windows build uses keyboard-mode scanners. Windows users can use the web app for webcam scanning. A browser test verified the camera-error fallback and keyboard capture. The Android release build needs the SDK command-line tools, NDK 28.2 and license acceptance on the build machine.
2. Configure and review the actual business, branch, tax profile and receipt layout. Cartunez calculates supported GST components and issues linked credit notes. If the business needs IRN, signed QR codes, e-way bills or GST filing, those need a provider integration and accountant validation. [CBIC invoice rules](https://cbic-gst.gov.in/gst-invoice-rules.html) · [Zoho e-invoicing](https://www.zoho.com/in/invoice/gst-einvoicing/)
3. Reconcile provider fees, bank payouts and externally issued refunds against real merchant statements. Build 4 compares gross INR Card and UPI receipts and records till cash movements. [Square reconciliation and payment reports](https://squareup.com/help/us/en/article/5381-in-app-summaries-and-reports)
4. Capacity-test reports with representative branch history and concurrent registers before a high-volume rollout. Stock valuation currently uses catalog cost. Historical valuation, landed-cost costing, batch tracking and consolidated branch reporting require additional ledger and reporting work.
5. Decide which supplier labels need more than product identification. GS1 lot, expiry, serial and variable-weight fields require dedicated rules before they can drive receiving or billing. [GS1 retail POS barcode guideline](https://ref.gs1.org/guidelines/2d-in-retail/)
