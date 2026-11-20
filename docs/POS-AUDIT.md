# Cartunez POS audit

## 20 November 2026 · v1.0.2 build 3

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
3. Add automated Card and UPI settlement imports, refund-provider references, and register paid-in/paid-out entries. Current tender reports reconcile POS entries. Provider payout reconciliation and cash movements such as safe drops need their own records. [Square reconciliation and payment reports](https://squareup.com/help/us/en/article/5381-in-app-summaries-and-reports) · [Shopify cash tracking](https://help.shopify.com/en/manual/sell-in-person/shopify-pos/cash-register-management)
4. Add a validated bulk product import and server-side report pagination before high-volume rollout. Stock valuation currently uses catalog cost. Historical valuation, landed-cost costing, batch tracking and consolidated branch reporting require additional ledger and reporting work. [GoFrugal RetailEasy](https://www.gofrugal.com/cloud/retail-pos.html)
5. Decide which supplier labels need more than product identification. GS1 lot, expiry, serial and variable-weight fields require dedicated rules before they can drive receiving or billing. [GS1 retail POS barcode guideline](https://ref.gs1.org/guidelines/2d-in-retail/)
